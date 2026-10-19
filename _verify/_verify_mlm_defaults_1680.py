"""Keep the README's `ml_m` default list honest, mechanically.

The README names, in prose, which estimators still default `ml_m` to
`linear_regression()` and which were migrated to a classifier. That list
went stale by two releases: `DoubleMLLPLR` was migrated to a classifier
(commit 4775218, first shipped in v0.163.3 -- v0.163.1 and v0.163.2 were
tagged but their publish runs went red) and the README still counted it as
OLS-defaulting, so the count was nine instead of eight.

Reading a DEFAULT VALUE out of prose is exactly the kind of claim that
rots, so this derives the sets from the source and compares.
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
LIB = os.path.join(ROOT, "moonbit_doubleML")
README = os.path.join(ROOT, "README.mbt.md")
readme = io.open(README, encoding="utf-8").read()

ML_M = re.compile(
    r"ml_m~\s*:\s*LearnerDispatch\s*=\s*LearnerDispatch::(\w+)")
NEW = re.compile(r"pub fn (DoubleML\w+)::new\(")

ols, clf = [], []
for name in sorted(os.listdir(LIB)):
    if not name.endswith(".mbt"):
        continue
    src = io.open(os.path.join(LIB, name), encoding="utf-8", errors="replace").read()
    # the estimator a `::new` belongs to: the one whose ::new encloses the
    # ml_m default. Take the LAST `::new` before the ml_m default.
    for m in ML_M.finditer(src):
        owners = NEW.findall(src[:m.start()])
        owner = owners[-1] if owners else "(unknown in %s)" % name
        (ols if m.group(1) == "linear_regression" else clf).append(owner)

ols = sorted(set(ols))
clf = sorted(set(clf))
print("ml_m defaults to linear_regression (%d):" % len(ols))
for o in ols:
    print("   %s" % o)
print("ml_m defaults to a classifier (%d):" % len(clf))
for c in clf:
    print("   %s" % c)
print("")

fails = []


def check(label, cond, detail=""):
    print("  %-56s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s %s" % (label, detail))


# the README's sentence
m = re.search(r"\*\*(\w+) structs still default `ml_m` to `linear_regression\(\)`\*\*:\s*"
              r"((?:`DoubleML\w+`(?:,\s*)?)+)\.", readme)
if not m:
    check("the README's 'still default' sentence is findable", False)
    print()
    print("VERDICT: FAIL")
    sys.exit(1)

claimed_nine = m.group(1)
claimed = re.findall(r"`(DoubleML\w+)`", m.group(2))

check("the README says 'Eight' (there are %d)" % len(ols),
      claimed_nine.lower() == ("eight" if len(ols) == 8 else claimed_nine.lower()),
      "README says %r, source says %d" % (claimed_nine, len(ols)))
check("the README's list matches the source exactly",
      sorted(claimed) == ols,
      "README: %s / source: %s" % (sorted(claimed), ols))
check("DoubleMLLPLR is NOT in the OLS list",
      "DoubleMLLPLR" not in claimed,
      "it defaults to %s" % next((c for c in clf if "LPLR" in c), "?"))
check("DoubleMLLPLR IS in the classifier list",
      any("LPLR" in c for c in clf))

# the migration sentence must name LPLR
mig = re.search(r"\*\*`DoubleMLIRM` was migrated in v0\.132\.0\*\*,(.*?):", readme, re.S)
check("the migration sentence names DoubleMLLPLR",
      mig is not None and "DoubleMLLPLR" in mig.group(1),
      (mig.group(1)[-120:] if mig else "(not found)"))

print("")
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
