"""Check the README's copy-pasteable API snippets against the real signatures.

The "Library Use" block is what a reader pastes into their own project:

    let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)
    let fitted = @moonbit_doubleML.DoubleMLPLR::new(data, n_folds=2, n_rep=1, seed=3141).fit()
    let coef = fitted.coef()
    let se   = fitted.se()
    let (lo, hi) = fitted.confint()

and it then says "Same shape for every other estimator -- e.g.
`DoubleMLIRM::new(data, ml_g?, ml_m?, n_folds?, n_rep?, seed?).fit()`,
`DoubleMLDID::new(data, ml_g?, ml_m?, ...)`.fit()`."

A wrong parameter name in that block is a compile error in the reader's
project, so each name the README uses is checked against the real
signature.
"""
import io
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
LIB = os.path.join(ROOT, "moonbit_doubleML")
readme = io.open(os.path.join(ROOT, "README.mbt.md"), encoding="utf-8").read()

fails = []


def check(label, cond, detail=""):
    print("  %-56s %s" % (label, "OK" if cond else "*** FAIL ***"))
    if not cond:
        fails.append("%s %s" % (label, detail))


def signature(estimator):
    """The parameter list of `DoubleMLX::new(` as written in the source."""
    for name in sorted(os.listdir(LIB)):
        if not name.endswith(".mbt"):
            continue
        src = io.open(os.path.join(LIB, name), encoding="utf-8", errors="replace").read()
        m = re.search(r"pub fn %s::new\(\s*(.*?)\n\) ->" % re.escape(estimator), src, re.S)
        if m:
            # a parameter is `name : Type` with an optional `~` marker; the
            # TYPE may itself contain commas, so only the name is captured
            params = re.findall(r"(\w+)~?\s*:", m.group(1))
            return params, m.group(0)
    return None, None


print("== the Library Use snippet ==")
params, raw = signature("DoubleMLData")
check("DoubleMLData::new exists", params is not None)
if params:
    for p in ("x", "y", "d"):
        check("DoubleMLData::new takes %r" % p, p in params, str(params))
    check("DoubleMLData::new's 3rd positional is d, not z",
          params[:3] == ["x", "y", "d"], str(params))

params, raw = signature("DoubleMLPLR")
check("DoubleMLPLR::new exists", params is not None)
if params:
    for p in ("data", "n_folds", "n_rep", "seed"):
        check("DoubleMLPLR::new takes %r" % p, p in params, str(params))
    check("n_folds default is 2", "n_folds~ : Int32 = 2" in raw, raw)
    check("n_rep default is 1", "n_rep~ : Int32 = 1" in raw, raw)
    check("seed default is 3141", "seed~ : Int32 = 3141" in raw, raw)

plr = io.open(os.path.join(LIB, "plr.mbt"), encoding="utf-8", errors="replace").read()
for acc in ("coef", "se", "confint"):
    check("DoubleMLPLR::%s() exists" % acc,
          ("pub fn DoubleMLPLR::%s(" % acc) in plr)
check("confint() returns (Double, Double)",
      re.search(r"pub fn DoubleMLPLR::confint\([^)]*\)\s*->\s*\(Double, Double\)", plr) is not None)

print("")
print("== the 'same shape for every other estimator' sentence ==")
m = re.search(r"`@moonbit_doubleML\.(DoubleML\w+)::new\(([^)]*)\)", readme)
seen = set()
for mm in re.finditer(r"`@moonbit_doubleML\.(DoubleML\w+)::new\(([^)]*)\)", readme):
    est, arglist = mm.group(1), mm.group(2)
    if est in seen:
        continue
    seen.add(est)
    params, raw = signature(est)
    check("%s::new exists" % est, params is not None)
    if not params:
        continue
    named = re.findall(r"(\w+)\?", arglist)
    for p in named:
        check("%s::new takes %r" % (est, p), p in params, str(params))
    # every PARAMETER the README shows must be one the constructor accepts
    ok = all(p in params for p in named)
    check("%s::new accepts every name the README shows" % est, ok, str(params))

print("")
print("checks failed: %d" % len(fails))
for f in fails:
    print("  - %s" % f)
print("VERDICT: %s" % ("PASS" if not fails else "FAIL"))
sys.exit(1 if fails else 0)
