"""Audit the README's upstream-provenance claims against the real sdist.

The README says: "Those provenance labels are re-measured against the published
`doubleml` 0.11.4 sdist, not asserted -- see the estimator table below."

So the table's three labels must match the sdist:
  * 20 rows marked *(upstream)*        -> a name-identical class exists
  * `DoubleMLRDD` marked *(upstream, renamed)* -> upstream calls it `RDFlex`
  * `DoubleMLDIDCrossSection` marked *(no upstream counterpart)* -> no such class

The sdist is at `_verify/doubleml-0.11.4.tar.gz` (a local copy of the
published `doubleml` 0.11.4).
"""
import io
import os
import re
import sys
import tarfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
SDIST = os.path.join(ROOT, "_verify", "doubleml-0.11.4.tar.gz")
README = os.path.join(ROOT, "README.mbt.md")
readme = io.open(README, encoding="utf-8").read()

if not os.path.isfile(SDIST):
    print("no sdist at %s" % SDIST)
    sys.exit(1)

print("sdist: %s (%d bytes)" % (SDIST, os.path.getsize(SDIST)))

# ---- collect the upstream class names -------------------------------------
# The estimators are NOT all under plm/: upstream splits them across
# doubleml/irm/, doubleml/did/, doubleml/plm/, doubleml/rdd/ and
# doubleml/irm/... -- so scan every .py in the sdist.
classes = set()
modules = []
with tarfile.open(SDIST, "r:gz") as tf:
    for m in tf.getmembers():
        if not m.isfile() or not m.name.endswith(".py"):
            continue
        if "/tests/" in m.name:
            continue
        modules.append(m.name)
        src = tf.extractfile(m).read().decode("utf-8", "replace")
        for c in re.findall(r"^class\s+(\w+)", src, re.M):
            classes.add(c)

print("upstream python modules scanned: %d" % len(modules))
print("upstream classes found         : %d" % len(classes))
print()

fails = []


def check(label, cond, detail=""):
    print("  %-58s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s -- %s" % (label, detail))


# ---- the README's table ---------------------------------------------------
rows = re.findall(r"^\|\s*`(DoubleML\w+)`\s*\|\s*([^|]+?)\s*\|\s*(.*?)\s*\|\s*$",
                   readme, re.M)
model_rows = [(n, sc, d) for n, sc, d in rows
               if "upstream" in d or "port-only" in d]
plain = [n for n, _, d in model_rows
         if "*(upstream)*" in d and "renamed" not in d and "no upstream" not in d]
renamed = [n for n, _, d in model_rows if "upstream, renamed" in d]
portonly = [n for n, _, d in model_rows if "no upstream counterpart" in d]

print("README table: %d *(upstream)*, %d renamed, %d port-only"
      % (len(plain), len(renamed), len(portonly)))
print()

# every *(upstream)* row must have a name-identical upstream class
missing = [n for n in plain if n not in classes]
check("all 20 *(upstream)* rows have a name-identical upstream class",
      not missing, "missing: %s" % missing)

# the renamed one: upstream calls it RDFlex
check("upstream has RDFlex", "RDFlex" in classes)
check("upstream does NOT have DoubleMLRDD (it is renamed)",
      "DoubleMLRDD" not in classes,
      "upstream classes: %s" % sorted(c for c in classes if "RDD" in c or "Flex" in c))
check("the README says upstream calls it RDFlex",
      "upstream `RDFlex`" in readme or "upstream calls it `RDFlex`" in readme)

# the port-only one
check("upstream has no DoubleMLDIDCrossSection",
      "DoubleMLDIDCrossSection" not in classes,
      "upstream DID classes: %s" % sorted(c for c in classes if "DID" in c))

# and print the upstream DID classes for context
print()
print("  upstream classes containing 'DID': %s"
      % ", ".join(sorted(c for c in classes if "DID" in c)))

# the three that were "extra" before
for n in ("DoubleMLDIDCSBinary", "DoubleMLLPLR", "DoubleMLPLPR"):
    check("%s ships upstream" % n, n in classes)

print("")
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
