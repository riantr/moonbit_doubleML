"""Derive the set of production `adjust_ps` call sites, and which forward `cv`.

The README says (v0.121.0 retrospective):

    "The five remaining `adjust_ps` call sites (`apo.mbt:320`, `did.mbt:628`,
     `did_cross_section.mbt:615`, `did_cs_binary.mbt:374`, `cvar.mbt:736` and
     `:1005`) still do not forward `cv`."

The list has SIX entries. Either "five" counts the FILES, or the count is
wrong. This derives the truth from the source: every `.adjust_ps(` call in a
PRODUCTION file, with the argument list parsed far enough to see whether it
passes `cv=`.

Deriving it (rather than reading it) is the point: a count that a reader
cannot re-derive is a count that rots.

v0.164.3: this file was the round-7 DIAGNOSTIC -- it asserted the PRE-fix
claims ("six remaining", six sites), so it could only ever fail once the
README was corrected. It now asserts the corrected truth and therefore
guards it:
  * the eight call sites that do NOT forward `cv`, named by the line the
    `.adjust_ps(` call starts on;
  * the count word "eight" and the "seven files" it is qualified with;
  * the two that DO forward `cv`, named by the line the `cv=` ARGUMENT is on
    -- which is the convention the README uses ("`cv=` is passed at
    `irm.mbt:430` and `iivm.mbt:525`"), and NOT the line the call starts on
    (427 and 522). Getting that convention wrong is what made this file
    report a defect that was not there.
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "moonbit_doubleML")

fails = []


def check(label, cond, detail=""):
    print("  %-62s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


# production files only: a call site inside a *_test.mbt is a test, and the
# README's claim is about the estimators.
prod = sorted(f for f in os.listdir(LIB)
              if f.endswith(".mbt") and not f.endswith("_test.mbt"))

CALL = re.compile(r"\.adjust_ps\(")

sites = []
for f in prod:
    src = io.open(os.path.join(LIB, f), encoding="utf-8", errors="replace").read()
    lines = src.splitlines()
    for i, line in enumerate(lines, 1):
        if not CALL.search(line):
            continue
        # the call may span lines: take the text from the call to the closing
        # paren of the argument list
        buf = line
        j = i
        depth = buf.count("(") - buf.count(")")
        while depth > 0 and j < len(lines):
            j += 1
            buf += " " + lines[j - 1]
            depth = buf.count("(") - buf.count(")")
        # A line that is only a COMMENT quoting upstream's call is not a call
        # site -- the first version of this scanner counted three of those
        # (cvar.mbt:997, did.mbt:139, did_cs_binary.mbt:339) and produced a
        # nine-site set that does not exist.
        stripped = line.lstrip()
        if stripped.startswith("//") or stripped.startswith("///"):
            continue
        has_cv = re.search(r"\bcv\s*=", buf) is not None
        # the line the `cv=` ARGUMENT is on -- the convention the README uses
        cv_line = None
        if has_cv:
            for k in range(i - 1, min(j, len(lines))):
                if re.search(r"\bcv\s*=", lines[k]):
                    cv_line = k + 1
                    break
        sites.append((f, i, has_cv, cv_line, buf.strip()[:90]))

print("=== production `adjust_ps` call sites ===")
for f, i, has_cv, cv_line, snippet in sites:
    extra = "" if not has_cv else "  (cv= on L%d)" % cv_line
    print("  %-24s L%-5d cv=%-4s | %s%s" % (f, i, "YES" if has_cv else "no", snippet, extra))
print()

no_cv = [(f, i) for f, i, c, _, _ in sites if not c]
with_cv = [(f, cl) for f, i, c, cl, _ in sites if c and cl]
print("  total %d   with cv %d   without cv %d"
      % (len(sites), len(with_cv), len(no_cv)))
print("  without cv: %s" % ", ".join("%s:%d" % s for s in no_cv))
print("  with cv   : %s" % ", ".join("%s:%d" % s for s in with_cv))
print()

readme = io.open(os.path.join(ROOT, "README.mbt.md"), encoding="utf-8").read()

EXPECTED_NO_CV = {"apo.mbt:320", "cvar.mbt:736", "cvar.mbt:1005", "did.mbt:628",
                  "did_cross_section.mbt:615", "did_cs_binary.mbt:374",
                  "quantile.mbt:217", "ssm.mbt:671"}
EXPECTED_WITH_CV = {"irm.mbt:430", "iivm.mbt:525"}

check("the README's list names every call site that does not forward cv",
      set("%s:%d" % s for s in no_cv) == EXPECTED_NO_CV,
      "derived %s" % sorted("%s:%d" % s for s in no_cv))
check("there is no call site the README forgot",
      len(no_cv) == 8, "derived %d" % len(no_cv))
check("the count word in the README matches the list",
      "do not forward `cv` are **eight**, in seven" in readme,
      "the README no longer says 'eight, in seven files'")
check("the README names every one of the eight sites",
      all(("`%s`" % s) in readme for s in EXPECTED_NO_CV),
      "missing %s" % sorted(s for s in EXPECTED_NO_CV if ("`%s`" % s) not in readme))
check("the two cv-forwarding sites are the ones the README names",
      set("%s:%d" % s for s in with_cv) == EXPECTED_WITH_CV,
      "derived %s" % sorted("%s:%d" % s for s in with_cv))
check("the README names the cv= lines, not the call lines",
      all(("`%s`" % s) in readme for s in EXPECTED_WITH_CV),
      "missing %s" % sorted(s for s in EXPECTED_WITH_CV if ("`%s`" % s) not in readme))

print()
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
