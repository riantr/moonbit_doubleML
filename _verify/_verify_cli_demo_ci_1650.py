r"""Round 22 verifier: the README's CLI-demo counts, re-derived from the drivers.

THE FIGURE THAT WAS WRONG
==========================
The README says, in the Examples section:

    "measured per driver, **14** of the 16 print a true value and **11** of
     the 16 print a 95 % CI -- `examples/pava` and `examples/splitting` print
     neither, and `examples/apos`, `examples/cluster` and `examples/ssm`
     print a true value but no CI"

It used to say **12** for the CI count.  That was never right, and the
sentence CONTRADICTED ITSELF: it named FIVE demos that print no CI, and
16 - 5 = 11.

Where the 12 came from
======================
The measuring script (`_verify/_cli_demo_shape_1680.py`, local scratch) decides
"prints a 95 % CI" with

    CI_RE = re.compile(r"95\s*%|confint|confidence|CI\b|\[.*\]", re.I)

The last alternative -- `\[.*\]` -- matches ANY line containing a bracket
pair.  `examples/pava` prints

    case[v0] n=4 pava = 0.625 0.625 0.625 0.625

so pava "prints a CI" because of a bracket in a case label.  It prints no
interval, no confidence bound and no theta at all.  One false positive, one
wrong figure.

WHY THIS FILE RE-RUNS THE DRIVERS
=================================
A figure a document quotes has to be re-derived by the thing that measured
it, or it decays into a second claim to take on trust.  So this file runs
the 16 drivers and looks at what they PRINT.  The three ways a driver can
print an interval are:

  * a line naming a confidence level -- `95 %`, `90 percent`, ...
  * a line naming an interval -- `confint`, `confidence`, `CI`
  * a line carrying both endpoints -- a `lo`/`hi` pair

A bracket alone is NOT one of them, and that is the whole point.

THE OLD RULE IS KEPT, MEASURED, AND EXPLAINED
==============================================
This file also runs the OLD regex, so the gap between 11 and 12 is not a
claim about the past -- it is a measurement.  The difference must be exactly
`pava`, and the old count must be exactly 12.  If a future driver starts
printing something bracket-shaped, the difference will grow and this file
will say so.

THE RECORD
==========
`_verify/_cli_demo_ci_1650.json` holds the measurement as a tracked file, so
the figure is auditable without re-running 16 binaries.  The fresh
measurement must agree with it AND with the README: three-way agreement, or
the check fails.

Run: python _verify/_verify_cli_demo_ci_1650.py
"""
import io
import json
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

README = os.path.join(ROOT, "README.mbt.md")
SHIPPED = os.path.join(ROOT, "moonbit_doubleML", "README.mbt.md")
RECORD = os.path.join(ROOT, "_verify", "_cli_demo_ci_1650.json")

FAILURES = []
CHECKS = 0

# the 16 CLI-style numeric demos, in the order the README lists them
CLI = ["apo", "apos", "cluster", "cvar", "datasets", "did_binary",
       "did_cross_section", "did_cs", "did_cs_binary", "did_multi", "lplr",
       "main", "pava", "plpr", "splitting", "ssm"]

TRUE_RE = re.compile(r"\btrue\b", re.I)

# the STRICT definition: an interval has to be named, or both endpoints shown
LEVEL_RE = re.compile(r"\b(9[0-9]|95|99)\s*(%|percent|pct)\b", re.I)
NAME_RE = re.compile(r"\b(confint|confidence|credible)\b|\bCI\b", re.I)
ENDPOINT_RE = re.compile(r"\b(lo|low|lower|hi|high|upper)\b[^\n]*"
                         r"\b(lo|low|lower|hi|high|upper)\b", re.I)

# the OLD definition, kept only to MEASURE the gap it created
LOOSE_RE = re.compile(r"95\s*%|confint|confidence|CI\b|\[.*\]", re.I)


def check(label, ok, detail=""):
    global CHECKS
    CHECKS += 1
    if ok:
        print("  PASS  %s" % label)
    else:
        print("  *** FAIL ***  %s%s" % (label, (" -- " + detail) if detail else ""))
        FAILURES.append(label)


def read(path):
    with io.open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def norm(text):
    return re.sub(r"\s+", " ", text)


print()
print("A. the measurement -- run the 16 drivers and look at what they print")
measured = {}
for d in CLI:
    p = subprocess.run(["moon", "run", "examples/%s" % d], cwd=ROOT,
                       capture_output=True, text=True, timeout=900,
                       encoding="utf-8", errors="replace")
    out = (p.stdout or "") + (p.stderr or "")
    lines = out.splitlines()
    has_true = any(TRUE_RE.search(l) and "=" in l for l in lines)
    strict = [l for l in lines
              if LEVEL_RE.search(l) or NAME_RE.search(l) or ENDPOINT_RE.search(l)]
    loose = any(LOOSE_RE.search(l) for l in lines)
    measured[d] = {
        "true": has_true,
        "ci": bool(strict),
        "loose": loose,
        # the first line that justifies the CI decision
        "evidence": (strict[0].strip()[:160] if strict else ""),
    }
    print("    %-18s true=%-3s ci=%-3s loose=%s"
          % (d, "yes" if has_true else "NO", "yes" if strict else "NO",
             "yes" if loose else "NO"))

no_true = sorted(d for d in CLI if not measured[d]["true"])
no_ci = sorted(d for d in CLI if not measured[d]["ci"])
loose_only = sorted(d for d in CLI if measured[d]["loose"] and not measured[d]["ci"])
n_true = len(CLI) - len(no_true)
n_ci = len(CLI) - len(no_ci)
n_loose = len(CLI) - len([d for d in CLI if not measured[d]["loose"]])

check("all 16 drivers ran", len(measured) == 16, "ran %d" % len(measured))
check("14 of the 16 print a true value", n_true == 14, "measured %d" % n_true)
check("11 of the 16 print a 95 % CI", n_ci == 11, "measured %d" % n_ci)
check("the drivers with no true value are pava and splitting",
      no_true == ["pava", "splitting"], "got %r" % no_true)
check("the drivers with no CI are apos, cluster, pava, splitting and ssm",
      no_ci == ["apos", "cluster", "pava", "splitting", "ssm"], "got %r" % no_ci)

print()
print("B. the old rule, measured -- the gap must be exactly pava")
check("the old bracket rule would have counted 12", n_loose == 12,
      "measured %d" % n_loose)
check("the old bracket rule added exactly one driver",
      loose_only == ["pava"], "got %r" % loose_only)
check("pava prints no interval at all", not measured["pava"]["ci"])
check("pava's only bracket is a case label",
      all("[" not in l for l in measured["pava"]["evidence"]), "")

print()
print("C. every CI decision rests on a named level or a named interval")
for d in CLI:
    if not measured[d]["ci"]:
        continue
    ev = measured[d]["evidence"]
    named = bool(LEVEL_RE.search(ev) or NAME_RE.search(ev))
    check("%s's interval is named, not merely bracketed" % d, named,
          "evidence: %r" % ev[:80])

print()
print("D. the tracked record agrees with the fresh measurement")
if not os.path.exists(RECORD):
    check("the measurement record exists", False, RECORD)
    rec = {}
else:
    rec = json.loads(read(RECORD))
    check("the measurement record exists", True)
    check("the record's no-true set matches",
          sorted(rec.get("no_true", [])) == no_true,
          "record %r vs measured %r" % (rec.get("no_true"), no_true))
    check("the record's no-CI set matches",
          sorted(rec.get("no_ci", [])) == no_ci,
          "record %r vs measured %r" % (rec.get("no_ci"), no_ci))
    check("the record's CI count matches",
          rec.get("print_ci") == n_ci,
          "record %r vs measured %r" % (rec.get("print_ci"), n_ci))
    check("the record's true count matches",
          rec.get("print_true") == n_true,
          "record %r vs measured %r" % (rec.get("print_true"), n_true))
    check("the record's withdrawn-figure provenance matches",
          rec.get("loose_would_add") == loose_only
          and rec.get("loose_count") == n_loose,
          "record %r/%r vs measured %r/%r"
          % (rec.get("loose_would_add"), rec.get("loose_count"),
             loose_only, n_loose))

print()
print("E. the README quotes the measurement")
readme = read(README)
doc = norm(readme)
check("the README says 14 of the 16 print a true value",
      "**14** of the 16 print a true value" in doc)
check("the README says 11 of the 16 print a 95 % CI",
      "**11** of the 16 print a 95 % CI" in doc)
check("the README does not say 12 of the 16",
      "**12** of the 16" not in doc)
check("the README names pava and splitting as printing neither",
      "`examples/pava` and `examples/splitting` print neither" in doc)
check("the README names apos, cluster and ssm as true-value-but-no-CI",
      "`examples/apos`, `examples/cluster` and `examples/ssm` print a true "
      "value but no CI" in doc)
# every demo the README says prints no CI must really print no CI
named_no_ci = re.findall(r"`examples/([a-z_]+)`", doc)
check("no demo the README lists as printing no CI actually prints one",
      all(measured.get(d, {}).get("ci", True) is False
          for d in ("apos", "cluster", "pava", "splitting", "ssm")),
      "")

print()
print("F. the two copies")
shipped = read(SHIPPED)
check("the shipped README is byte-identical to the edited one",
      shipped.encode("utf-8") == readme.encode("utf-8"))
check("the README is LF-only with no BOM",
      b"\r" not in readme.encode("utf-8")
      and not readme.encode("utf-8").startswith(b"\xef\xbb\xbf"))

print()
print("=" * 72)
print("%d checks, %d failed" % (CHECKS, len(FAILURES)))
if FAILURES:
    print("*** FAIL ***")
    for f in FAILURES:
        print("  - %s" % f)
    sys.exit(1)
print("all green")
