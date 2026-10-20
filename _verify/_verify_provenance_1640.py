"""Audit the README's upstream-provenance claims against the real sdist.

The README says: "Those provenance labels are re-measured against the published
`doubleml` 0.11.4 sdist, not asserted -- see the estimator table below."

So the table's labels must match the sdist:
  * rows marked *(upstream)*          -> a name-identical class exists
  * rows marked *(upstream, renamed)* -> an upstream class exists under the
    name the row gives
  * rows marked *(no upstream counterpart)* -> no upstream class implements it

**RE-AUDITED 2026-10-20.** This file used to assert "20 rows marked
*(upstream)*" and that `DoubleMLDIDCrossSection` was marked
*(no upstream counterpart)*. Both were the README's own belief, checked by a
**name scan** -- and a name scan cannot establish that no upstream estimator
implements a design, only that no upstream class carries a given NAME.
Upstream's `DoubleMLDIDCS` is the *repeated cross-sections* estimator, which
is the counterpart of the port's `DoubleMLDIDCrossSection`; the port's
`DoubleMLDIDCS` is the panel estimator, whose upstream counterpart is
`DoubleMLDIDMulti`. The grouping is now **19 name-identical + 3 renamed + 0
port-only**, and the counts below are DERIVED from the table rather than
written down. The estimator-level evidence is in
`_verify/_verify_estimator_census_1680.py` (design markers read from both
sides) and `_verify/_verify_round15_defaults_1650.py`.

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
check("every *(upstream)* row has a name-identical upstream class",
      not missing, "missing: %s (of %d rows)" % (missing, len(plain)))

# every *(upstream, renamed)* row must name an upstream class that exists
renamed_missing = []
for n, _s, d in model_rows:
    if "upstream, renamed" not in d:
        continue
    m = re.search(r"upstream `(\w+)`", d)
    if not m:
        renamed_missing.append("%s: names no upstream class" % n)
    elif m.group(1) not in classes:
        renamed_missing.append("%s: upstream `%s` is not in the sdist" % (n, m.group(1)))
check("every *(upstream, renamed)* row names an upstream class that exists",
      not renamed_missing, "; ".join(renamed_missing))

# the renamed one: upstream calls it RDFlex
check("upstream has RDFlex", "RDFlex" in classes)
check("upstream does NOT have DoubleMLRDD (it is renamed)",
      "DoubleMLRDD" not in classes,
      "upstream classes: %s" % sorted(c for c in classes if "RDD" in c or "Flex" in c))
check("the README says upstream calls it RDFlex",
      "upstream `RDFlex`" in readme or "upstream calls it `RDFlex`" in readme)

# the port-only one: there is none, and the README says so
check("upstream has no class NAMED DoubleMLDIDCrossSection",
      "DoubleMLDIDCrossSection" not in classes,
      "upstream DID classes: %s" % sorted(c for c in classes if "DID" in c))
check("the README marks no row *(no upstream counterpart)*",
      not portonly, "marked: %s" % portonly)
check("the README states there is no port-only estimator",
      re.search(r"\*\*no\*\*\s*\n?\s*port-only estimator", readme) is not None)

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
