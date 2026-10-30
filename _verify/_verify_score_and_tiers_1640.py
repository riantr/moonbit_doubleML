"""Check the Models table's Score column and the parity-tier split.

Two claims this round found to be wrong:

1. `DoubleMLRDD`'s score was listed as "observational", which is the DID
   score's name. RDD is a local-polynomial (kernel-weighted) estimator --
   `rdd.mbt`: "Local-polynomial RD estimator. The port uses a triangular
   kernel and a fixed bandwidth" -- and the table's own `DoubleMLLPQ` row
   says "local polynomial". The DID family is the "observational" one.

2. "Behaviour-level parity check via the 24 Python reference scripts:
   `within-tolerance equivalence` rather than bit-exact re-implementation"
   was wrong for one of the 24: `validate_bitexact_with_python.py` compares
   IEEE-754 bit patterns. The split is 23 tolerance-based + 1 bit-exact.
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "moonbit_doubleML")
README = os.path.join(ROOT, "README.mbt.md")
readme = io.open(README, encoding="utf-8").read()

fails = []


def check(label, cond, detail=""):
    print("  %-58s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


# ------------------------------------------------------- the Score column
rows = re.findall(r"^\|\s*`(DoubleML\w+)`\s*\|\s*([^|]+?)\s*\|\s*(.*?)\s*\|\s*$",
                   readme, re.M)
score = {n: sc.strip() for n, sc, d in rows
         if "upstream" in d or "port-only" in d}
print("Models table rows with a score: %d" % len(score))
print()

observational = sorted(n for n, sc in score.items() if sc == "observational")
print("  'observational': %s" % ", ".join(observational))
print("  'local polynomial': %s"
      % ", ".join(sorted(n for n, sc in score.items() if sc == "local polynomial")))
print()

DID_FAMILY = ["DoubleMLDID", "DoubleMLDIDBinary", "DoubleMLDIDCS",
              "DoubleMLDIDCSBinary", "DoubleMLDIDCrossSection", "DoubleMLDIDMulti"]
check("the 'observational' rows are exactly the DID family",
      observational == DID_FAMILY, "got %s" % observational)
check("DoubleMLRDD's score is 'local polynomial', not 'observational'",
      score.get("DoubleMLRDD") == "local polynomial",
      "got %r" % score.get("DoubleMLRDD"))
check("DoubleMLLPQ's score is 'local polynomial' too",
      score.get("DoubleMLLPQ") == "local polynomial",
      "got %r" % score.get("DoubleMLLPQ"))

# the source agrees: RDD is a local-polynomial kernel estimator
rdd = io.open(os.path.join(LIB, "rdd.mbt"), encoding="utf-8", errors="replace").read()
check("the source calls RDD a local-polynomial estimator",
      "Local-polynomial RD estimator" in rdd)
check("the source gives RDD a kernel",
      "kernel" in rdd and "RDDKernel" in rdd)

# ------------------------------------------------------ the parity tiers
validators = sorted(f for f in os.listdir(ROOT)
                    if re.match(r"^validate_\w+_with_python\.py$", f))
print()
print("validators on disk: %d" % len(validators))

# The discriminator: the tier label lives in the file's own header, within its
# first 6 lines. The earlier heuristic ("mentions bit-exact AND does not say
# tolerance near the top") misfired -- validate_bitexact_with_python.py says
# "tolerance" in its own docstring, so it was classified as the tolerance tier
# and the bit-exact tier came out empty. A tier label in the header is the
# thing we are actually classifying on.
bitexact = []
for v in validators:
    s = io.open(os.path.join(ROOT, v), encoding="utf-8", errors="replace").read()
    head6 = "\n".join(s.splitlines()[:6])
    if "BIT-EXACT" in head6:
        bitexact.append(v)
print("bit-exact tier: %s" % (", ".join(bitexact) or "(none found)"))
print()

check("there are 24 validators", len(validators) == 24, "got %d" % len(validators))
check("exactly one of them is the bit-exact tier",
      len(bitexact) == 1, "got %d: %s" % (len(bitexact), bitexact))
check("it is validate_bitexact_with_python.py",
      bitexact == ["validate_bitexact_with_python.py"], "got %s" % bitexact)
check("the README says 23 compare under a per-validator numeric tolerance",
      re.search(r"23\s+compare under a \*\*per-validator numeric tolerance\*\*",
                readme) is not None)
check("the README names the bit-exact one",
      "`validate_bitexact_with_python.py`" in readme)
check("the old blanket claim is gone",
      "rather than bit-exact re-implementation" not in readme)

print("")
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
