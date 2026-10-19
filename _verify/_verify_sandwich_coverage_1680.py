"""Verify the Status table's sandwich-variance coverage.

The table says: "**15 / 22** expose the scalar `sandwich_se` /
`cluster_sandwich_se` / `bias_corrected_coef`; **4** more
(`DoubleMLAPOS`, `DoubleMLDIDCS`, `DoubleMLDIDMulti`, `DoubleMLQTE`)
expose per-cell variants `sandwich_se_at` / `..._at_idx`; **3** expose
none (`DoubleMLBLP`, `DoubleMLPolicyTree`, `DoubleMLRDD`)".

15 + 4 + 3 = 22, so the arithmetic is right. What is NOT checked by
arithmetic is whether the SETS are right -- that is read from the source
here: which estimator files expose a sandwich accessor at all, and which
of those expose a per-cell one.
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
LIB = os.path.join(ROOT, "moonbit_doubleML")
readme = io.open(os.path.join(ROOT, "README.mbt.md"), encoding="utf-8").read()

# estimator -> (has_scalar, has_percell)
estimators = {}
for name in sorted(os.listdir(LIB)):
    if not name.endswith(".mbt"):
        continue
    src = io.open(os.path.join(LIB, name), encoding="utf-8", errors="replace").read()
    for est in re.findall(r"pub fn (DoubleML\w+)::", src):
        if est.endswith("Data"):
            continue
        estimators.setdefault(est, {"scalar": False, "percell": False})
        if re.search(r"pub fn %s::(sandwich_se|cluster_sandwich_se|bias_corrected_coef)\(" % est, src):
            estimators[est]["scalar"] = True
        if re.search(r"pub fn %s::\w*sandwich\w*_at(_idx)?\(" % est, src):
            estimators[est]["percell"] = True

scalar = sorted(e for e, v in estimators.items() if v["scalar"])
percell_only = sorted(e for e, v in estimators.items() if v["percell"] and not v["scalar"])
none = sorted(e for e, v in estimators.items() if not v["scalar"] and not v["percell"])

print("estimators with a sandwich accessor: %d" % len(estimators))
print("  scalar  (%d): %s" % (len(scalar), ", ".join(scalar)))
print("  per-cell only (%d): %s" % (len(percell_only), ", ".join(percell_only)))
print("  none     (%d): %s" % (len(none), ", ".join(none)))
print("")

fails = []


def check(label, cond, detail=""):
    print("  %-56s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s %s" % (label, detail))


row = re.search(r"\| Sandwich-variance coverage \|(.*?)\|", readme)
check("the Status table has a sandwich-variance row", row is not None)
if row:
    body = row.group(1)
    m = re.search(r"\*\*(\d+) / (\d+)\*\*", body)
    check("the table states 15 / 22", m is not None and m.group(1) == "15"
          and m.group(2) == "22", body[:80])
    check("the source agrees on the scalar count",
          m is not None and int(m.group(1)) == len(scalar),
          "table=%s source=%d" % (m.group(1) if m else "?", len(scalar)))
    m2 = re.search(r"\*\*(\d+)\*\* more \(([^)]*)\)", body)
    check("the table states 4 more", m2 is not None and m2.group(1) == "4",
          body[:120])
    if m2:
        named = re.findall(r"`(DoubleML\w+)`", m2.group(2))
        check("the table's per-cell names match the source",
              sorted(named) == percell_only,
              "table=%s source=%s" % (sorted(named), percell_only))
    m3 = re.search(r"\*\*(\d+)\*\* expose none \(([^)]*)\)", body)
    check("the table states 3 expose none", m3 is not None and m3.group(1) == "3",
          body[-120:])
    if m3:
        named = re.findall(r"`(DoubleML\w+)`", m3.group(2))
        check("the table's 'none' names match the source",
              sorted(named) == none,
              "table=%s source=%s" % (sorted(named), none))

print("")
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
