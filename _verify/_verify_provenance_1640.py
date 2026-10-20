"""Audit the README's upstream-provenance claims against the REAL upstream.

The README's estimator table labels every row with how it relates to
upstream's `doubleml-for-py`:

  * rows marked *(upstream)*                  -> a name-identical class exists
  * rows marked *(upstream, renamed)*         -> an upstream class exists under
    the name the row gives
  * rows marked *(upstream design, no 1:1 class)* -> the port estimator has no
    1:1 upstream counterpart

**RE-AUDITED 2026-10-20 (round 15).** This file used to assert "20 rows
marked *(upstream)*" and that `DoubleMLDIDCrossSection` was marked
*(no upstream counterpart)*. Both were the README's own belief, checked by a
**name scan** -- and a name scan cannot establish that no upstream estimator
implements a design, only that no upstream class carries a given NAME.

**RE-AUDITED 2026-10-20 (round 16).** Round 15's own correction was still
wrong, in a way its rule could not see: it matched the port's
`DoubleMLDIDCS` to upstream's `DoubleMLDIDMulti` on a shared design marker,
while ALSO matching the port's `DoubleMLDIDMulti` to upstream's
`DoubleMLDIDMulti` by name -- one upstream class, two port estimators. A 1:1
map cannot express that, so the README's labels were not checkable.

The decisive test is a **distinguishing parameter**, not a family
signature, and then the **1:1 constraint**: an upstream class may be the
counterpart of at most one port estimator. The derivation lives in
`_verify/_audit_r16_provenance_1650.py` and is the only one in the tree.

THIS FILE READS THE INSTALLED PACKAGE, not the sdist.  The previous version
read `_verify/doubleml-0.11.4.tar.gz`, which is **not tracked** -- so the
verifier could only ever run on the machine that had it.  A tracked verifier
that depends on an untracked artefact is a promise nobody can keep.
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
README = os.path.join(ROOT, "README.mbt.md")
readme = io.open(README, encoding="utf-8").read()

sys.path.insert(0, os.path.join(ROOT, "_verify"))
import _audit_r16_provenance_1650 as audit

derived = audit.derive()
pkg = derived["upstream_package"]
print("upstream package: %s" % pkg)
print()

# the upstream class names, read from the installed package
classes = set()
modules = []
for dp, dn, fns in os.walk(pkg):
    if os.sep + "tests" in dp:
        continue
    for fn in sorted(fns):
        if not fn.endswith(".py"):
            continue
        modules.append(fn)
        src = io.open(os.path.join(dp, fn), encoding="utf-8", errors="replace").read()
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
         if "*(upstream)*" in d and "renamed" not in d and "no upstream" not in d
         and "no 1:1" not in d]
renamed = [n for n, _, d in model_rows if "upstream, renamed" in d]
variant = [n for n, _, d in model_rows if "no 1:1 class" in d]

print("README table: %d *(upstream)*, %d renamed, %d no-1:1-class"
      % (len(plain), len(renamed), len(variant)))
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
        renamed_missing.append("%s: upstream `%s` is not in the package"
                               % (n, m.group(1)))
check("every *(upstream, renamed)* row names an upstream class that exists",
      not renamed_missing, "; ".join(renamed_missing))

# upstream calls the RDD estimator RDFlex
check("upstream has RDFlex", "RDFlex" in classes)
check("upstream does NOT have DoubleMLRDD (it is renamed)",
      "DoubleMLRDD" not in classes,
      "upstream classes: %s" % sorted(c for c in classes if "RDD" in c or "Flex" in c))
check("the README says upstream calls it RDFlex",
      "upstream `RDFlex`" in readme or "upstream calls it `RDFlex`" in readme)

# ---- the row with no 1:1 upstream class -----------------------------------
check("upstream has no class NAMED DoubleMLDIDCrossSection",
      "DoubleMLDIDCrossSection" not in classes,
      "upstream DID classes: %s" % sorted(c for c in classes if "DID" in c))
check("exactly one row is marked *(no 1:1 class)*",
      len(variant) == 1, "marked: %s" % variant)
check("the *(no 1:1 class)* row is the derived one",
      sorted(variant) == derived["no_upstream_class"],
      "README: %s / derived: %s" % (sorted(variant), derived["no_upstream_class"]))
check("the README states the count of rows with no 1:1 upstream class",
      re.search(r"\*\*1\*\*,?\s*`?DoubleMLDIDCS`?,?\s*has\s+\*\*no 1:1 upstream", readme)
      is not None
      or "**1** are upstream estimators under a different name" in readme
      or "no 1:1 upstream\nclass" in readme,
      "the README must not claim there is no such estimator")

# ---- THE decisive check: the correspondence is one-to-one ------------------
# An upstream class claimed by two port rows is the defect this round exists
# to repair, so it is checked directly against the README's own rows.
claimed = {}
for n, _s, d in model_rows:
    m = re.search(r"upstream `(\w+)`", d)
    if m:
        claimed.setdefault(m.group(1), []).append(n)
dupes = {u: v for u, v in claimed.items() if len(v) > 1}
check("no upstream class is claimed by two rows of the table",
      not dupes, "claimed twice: %s" % dupes)

# and the derived map agrees with the table
check("the derived map claims no upstream class twice",
      derived["upstream_class_claimed_twice"] == [],
      "claimed twice: %s" % derived["upstream_class_claimed_twice"])
check("the table's groups are the derived groups",
      sorted(plain) == derived["plain"]
      and sorted(renamed) == sorted(derived["renamed"])
      and sorted(variant) == derived["no_upstream_class"],
      "table: %d/%d/%d / derived: %d/%d/%d"
      % (len(plain), len(renamed), len(variant),
         len(derived["plain"]), len(derived["renamed"]),
         len(derived["no_upstream_class"])))

# ---- the DID facts the labels rest on -------------------------------------
up_params = derived["upstream_params"]
port_params = derived["port_params"]
multi_carriers = sorted(p for p, ps in port_params.items()
                        if "gt_combinations" in ps)
check("gt_combinations is a parameter of upstream's DoubleMLDIDMulti",
      "gt_combinations" in up_params.get("DoubleMLDIDMulti", []))
check("gt_combinations is a parameter of NO other upstream DID class",
      [c for c in ("DoubleMLDID", "DoubleMLDIDBinary", "DoubleMLDIDCS",
                   "DoubleMLDIDCSBinary") if "gt_combinations" in up_params.get(c, [])] == [],
      "the DID classes carrying it: %s"
      % [c for c in up_params if "gt_combinations" in up_params[c]])
check("on the port side only DoubleMLDIDMulti carries gt_combinations",
      multi_carriers == ["DoubleMLDIDMulti"], "carried by: %s" % multi_carriers)
check("the port's DoubleMLDIDCS does NOT carry gt_combinations",
      "gt_combinations" not in port_params.get("DoubleMLDIDCS", []))
check("the port's DoubleMLDIDMulti is the 1:1 counterpart of upstream's",
      derived["upstream_class_of"].get("DoubleMLDIDMulti") == "DoubleMLDIDMulti")
check("the port's DoubleMLDIDCrossSection is upstream's DoubleMLDIDCS",
      derived["upstream_class_of"].get("DoubleMLDIDCrossSection") == "DoubleMLDIDCS")

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
