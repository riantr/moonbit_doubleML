"""Round 21 verifier: the README's propensity-margin figures, checked against
the measurement they claim to report.

WHAT THIS IS FOR
----------------
The README tells a user that a classifier propensity is not a detail but a
requirement, and it backs that with numbers: how far the default recovers,
how far an OLS propensity misses, and how many times worse the miss is.
Those numbers are MEASUREMENTS, and a measurement that nobody re-derives is a
number that rots.

Round 21 found three that had already rotted, and that is what this file
exists to prevent:

    "default recovers within `0.198`"   the bias is 0.19828 -- the bound was
                                        false by 0.00028
    "misses by at least `72.8`"         the smallest miss is 72.7973 -- the
                                        bound was false by 0.0027
    "a 366x separation"                the separation is 367.15x
    "a 300x separation" (APO)          the separation is 320.03x

The 366x had been copied through the v0.132.0 CHANGELOG entry, the v0.132.0
gate's comment, the v0.134.0 gate's comment, the README and the ledger, and
nobody noticed, because "the number is in the document" was being treated as
"the number is true".

THE SHAPE OF THE CHECK
----------------------
The measurement lives in `_verify/_hazard_margins_1650.json`, at full
precision, with the fixture and the gate that produced it.  This file does NOT
store the figures the README should contain.  It recomputes them from the raw
per-seed arms, rounds them the way the document rounds them, and compares:

  * every figure the prose quotes is the correctly-rounded rendering of the
    measured value -- so a number cannot drift away from its measurement;
  * the separation the document states is DERIVABLE from the two numbers the
    reader can see -- 72.797 / 0.1983 = 367.06, so "367x" is what a reader
    who divides will get, not a separate claim to take on trust;
  * the margin paragraph contains NO number other than the measured ones, so
    a figure cannot be added without a witness;
  * the withdrawn renderings are ABSENT -- a corrected number that survives
    beside the correction is not a correction.

It exits non-zero on any failure.  It reads the README, not the ledger: the
ledger is a snapshot of what v0.164.11 published, and a snapshot is allowed
to be wrong about a measurement it froze.

Run: python _verify/_verify_hazard_margins_1650.py
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

RECORD = os.path.join("_verify", "_hazard_margins_1650.json")
README = "README.mbt.md"
SHIPPED = os.path.join("moonbit_doubleML", "README.mbt.md")

FAILURES = []
CHECKS = 0


def check(label, ok, detail=""):
    global CHECKS
    CHECKS += 1
    if ok:
        print("  PASS  %s" % label)
    else:
        # The marker goes ON the check line, not only in the summary: a
        # dry-run counts the failing lines to prove the verifier still bites,
        # and a marker that only appears once at the end cannot be counted.
        print("  *** FAIL ***  %s%s" % (label, (" -- " + detail) if detail else ""))
        FAILURES.append(label)


def read(path):
    with io.open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def flat(text):
    """Whitespace-normalised, so a re-wrap of the prose is not a change."""
    return re.sub(r"\s+", " ", text)


# A number worth checking: a decimal, or an integer of at least 10.  Bare
# single digits in the paragraph are structure ("D=1", "1 / m_hat"), not
# measurements, and the rule is stated here so the set comparison below is
# reproducible rather than a matter of taste.
#
# The trailing lookahead is "not a digit or a dot", NOT "not a word
# character": a figure is often written with a unit right after it ("367x",
# "10x", "1e6"), and a rule that cannot see those would quietly drop the
# separation claims from the very comparison meant to police them.
NUM = re.compile(r"(?<![\w.])(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)(?![\d]|\.\d)")


def numbers_in(text):
    out = set()
    for n in NUM.findall(text):
        if "." in n or float(n) >= 10:
            out.add(float(n))
    return out


def render(value, decimals):
    """The figure as the document writes it."""
    if decimals == 0:
        return "%d" % int(round(value))
    return ("%." + str(decimals) + "f") % value


# --------------------------------------------------------------------- input
print()
print("A. the measurement record")
record = json.loads(read(RECORD))
tracked = subprocess.run(["git", "ls-files"], capture_output=True, text=True,
                         encoding="utf-8", errors="replace").stdout.split()
check("the measurement record is TRACKED -- the README names it, so a path "
      "in prose is a promise", RECORD.replace("\\", "/") in tracked)
check("the record names the round and the date it was measured",
      bool(record.get("round")) and bool(record.get("measured_on")))
check("the record names the tree it was measured against",
      bool(record.get("measured_against_commit")))

estimates = record.get("estimates", {})
check("the record holds both estimators the README quotes",
      set(estimates) == {"DoubleMLIRM", "DoubleMLAPO"},
      "got %s" % sorted(estimates))

readme = read(README)
doc = flat(readme)

# ------------------------------------------------------- the derived figures
# Recomputed from the raw per-seed arms.  The record carries no summary, so a
# summary cannot be wrong here: there is nothing to be wrong.
derived = {}
for name, est in estimates.items():
    default = est["arms"]["default"]
    ols = est["arms"]["ols"]
    worst_default = max(a["absbias"] for a in default)
    best_ols = min(a["absbias"] for a in ols)
    d = {"worst_default_absbias": worst_default,
         "best_ols_absbias": best_ols,
         "separation_x": best_ols / worst_default}
    if any("se" in a for a in default):
        d["worst_default_se"] = max(a["se"] for a in default)
        d["best_ols_se"] = min(a["se"] for a in ols)
        d["se_separation_x"] = d["best_ols_se"] / d["worst_default_se"]
    # the true value is a measurement too: it is the number the bias is
    # measured against
    d["true_value"] = est["true_value"]
    derived[name] = d

print()
print("B. the figures the document quotes are the measured ones")
for name, est in estimates.items():
    figs = est["readme_figures"]["prose"]
    for key, decimals in sorted(figs.items()):
        value = derived[name][key]
        want = render(value, decimals)
        if key.endswith("_x"):
            # the separations are written with an "x": "a 367x separation",
            # "only ~10x".  A boundary check, so that "1900x" is not read as
            # "10x" and "300x" is not read as "00x".
            needle = r"(?<![\w.])%sx(?![\d]|\.\d)" % re.escape(want)
            ok = re.search(needle, doc) is not None
        else:
            needle = "`%s`" % want
            ok = needle in doc
        check("%s: the README quotes %s for %s" % (name, want, key),
              ok,
              "expected the literal %r" % needle)

print()
print("B2. the hazard table carries the same measurement, at table precision")
# The prose quotes the margins at the precision a reader needs to divide
# them; the hazard TABLE summarises the same measurement at three decimals.
# Both renderings come from the same record, so the two cannot drift apart.
# (An estimator with no table figures has a table row that reports a
# different fixture -- `DoubleMLIRM`'s row is the (800, 3, 31) propensity
# fixture, not this one -- and says so by having no table figures here.)
for name, est in estimates.items():
    figs = est["readme_figures"].get("table", {})
    if not figs:
        print("  SKIP  %s: its table row reports a different fixture" % name)
        continue
    marker = "| `%s` |" % name
    # anchor on the hazard table's OWN header, so the estimator catalogue
    # above it cannot be mistaken for the hazard row
    head = doc.find("| Estimator | OLS default | Evidence |")
    check("the hazard table has a header", head > 0)
    seg = doc[head:head + 4000] if head > 0 else ""
    i = seg.find(marker)
    check("the hazard table has a row for %s" % name, i > 0)
    if i < 0:
        continue
    row = seg[i:i + 220]
    for key, decimals in sorted(figs.items()):
        want = render(derived[name][key], decimals)
        check("%s: the hazard table quotes %s for %s" % (name, want, key),
              ("`%s`" % want) in row,
              "the row does not contain `%s`" % want)

print()
print("C. the separations are DERIVABLE from the numbers the reader can see")
# Take each pair AS THE DOCUMENT PRINTS IT -- re-rendered from the
# measurement at the documented precision -- and check that the ratio a reader
# would compute by dividing is the ratio the document states.  Nothing here is
# remembered: every figure comes from the record.
pairs = [
    ("IRM coefficient separation", "DoubleMLIRM",
     "best_ols_absbias", "worst_default_absbias", "separation_x"),
    ("APO coefficient separation", "DoubleMLAPO",
     "best_ols_absbias", "worst_default_absbias", "separation_x"),
    ("APO standard-error separation", "DoubleMLAPO",
     "best_ols_se", "worst_default_se", "se_separation_x"),
]
for label, name, nk, dk, sk in pairs:
    figs = estimates[name]["readme_figures"]["prose"]
    numerator = float(render(derived[name][nk], figs[nk]))
    denominator = float(render(derived[name][dk], figs[dk]))
    stated = int(round(derived[name][sk]))
    got = int(round(numerator / denominator))
    check("%s: %s / %s = %dx, and the document states %dx"
          % (label, numerator, denominator, got, stated),
          got == stated,
          "the printed numbers give %dx, the document says %dx" % (got, stated))

print()
print("D. the margin paragraph carries no number without a witness")
# The window is the two margin sentences.  Its bounds are structural
# phrases that are not themselves measurements.
start = doc.find("saturated-propensity fixture (true `ATE = 1.5`)")
end = doc.find("because the mechanism")
check("the margin paragraph is where the document says it is", start > 0 and end > start)
if start > 0 and end > start:
    window = doc[start:end]
    got = numbers_in(window)
    expected = set()
    for name, est in estimates.items():
        for key, decimals in est["readme_figures"]["prose"].items():
            expected.add(float(render(derived[name][key], decimals)))
        expected.add(float(est["true_value"]))
    check("every number in the margin paragraph is a measured one",
          got == expected,
          "unexpected: %s / missing: %s"
          % (sorted(got - expected), sorted(expected - got)))

print()
print("E. the withdrawn renderings are absent")
for stale in record.get("withdrawn_renderings", []):
    check("the README does not say %r" % stale, stale not in doc)
# "366x" and "300x" on their own, with a word boundary, so that "1900x"
# and "3000x" are not caught by accident
for token in ("366x", "300x"):
    check("the README contains no standalone %r" % token,
          not re.search(r"(?<![\w.])%s(?![\d]|\.\d)" % token, doc))

print()
print("F. the shipped copy")
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
