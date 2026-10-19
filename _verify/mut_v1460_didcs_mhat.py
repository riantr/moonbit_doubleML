"""Mutation harness for v0.146.0 stage 1a (did_cs panel-wide m_hat).

Six gates are only worth their runtime if they fail when the thing they cover
breaks. Four mutations, each isolating one claim:

  M1  m_hat replaced by the raw treatment indicator  -> the value stops being a
      FIT and becomes an input. Kills the validity gate.
  M2  m_hat replaced by a constant                  -> the value stops varying,
      so it is a placeholder rather than a nuisance. Kills the fittedness gate.
  M3  fold count inflated by one                    -> the partition is no
      longer the one the estimator claims. Kills the cross-fitting gate.
  M4  computation left unpropagated into the struct -> "computed but not
      persisted", the classic wiring bug. Kills everything except GATE 5.

DECLARED CONTROLS. GATE 5 (no estimate moves) and GATE 6 (empty before fit)
are expected to SURVIVE M1-M3: stage 1a is additive by construction, so
corrupting the new nuisance cannot move an old estimate. GATE 1 survives M1-M3
as well, because they all preserve the array's length. That asymmetry is the
point of the declaration -- an unexplained survivor is a gate nobody
understood, which is how the v0.138.0 GATE 5 problem happened.

Restores did_cs.mbt in a finally block.
"""
import io
import os
import re
import subprocess
import sys

REPO = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
PKG = os.path.join(REPO, "moonbit_doubleML")
DIDCS = os.path.join(PKG, "did_cs.mbt")

FIT_ANCHOR = """    let m_hat_long = cross_fit_predict_dispatch(
      ml_m, self.data.x, self.data.d, panel_folds,
    )"""

M1 = """    let m_hat_long = self.data.d"""

M2 = """    let m_hat_long : Array[Double] = Array::make(n, 0.5625)"""

FOLD_ANCHOR = """    let panel_folds = kfold_stratified(
      n, panel_strata, self.n_folds, self.seed,
    )"""

M3 = """    let panel_folds = kfold_stratified(
      n, panel_strata, self.n_folds + 1, self.seed,
    )"""

PROP_ANCHOR = """      m_hat_long: m_hat_long,
      panel_folds: panel_folds,"""

M4 = """      m_hat_long: [],
      panel_folds: [],"""

MUTANTS = [
    ("M1 m_hat -> raw treatment indicator", FIT_ANCHOR, M1),
    ("M2 m_hat -> constant", FIT_ANCHOR, M2),
    ("M3 fold count inflated by one", FOLD_ANCHOR, M3),
    ("M4 computed but never propagated to the struct", PROP_ANCHOR, M4),
]


def run_tests():
    p = subprocess.run(
        "moon test --target native --filter *didcs_*",
        cwd=PKG, shell=True, capture_output=True, text=True,
        encoding="utf-8", errors="replace", timeout=3600,
    )
    out = (p.stdout or "") + (p.stderr or "")
    failed = re.findall(r'\("([^"]+)"\) failed:', out)
    tail = [l.strip() for l in out.splitlines() if "Total tests:" in l]
    return p.returncode, failed, (tail[-1] if tail else "(no total line)")


original = io.open(DIDCS, encoding="utf-8", newline="").read()
for _, anchor, _m in MUTANTS:
    n = original.count(anchor)
    assert n == 1, "anchor not unique (%d): %s" % (n, anchor[:60])
print("all 4 anchors found exactly once\n")

rc, failed, total = run_tests()
print("BASELINE (unmutated): rc=%d  %s" % (rc, total))
if failed or rc != 0:
    print("  !! baseline not green")
    for f in failed:
        print("     " + f)
    sys.exit(1)

all_killed = True
try:
    for name, anchor, mutant in MUTANTS:
        mutated = original.replace(anchor, mutant)
        assert mutated != original
        io.open(DIDCS, "w", encoding="utf-8", newline="").write(mutated)
        rc, failed, total = run_tests()
        print("\n%s" % name)
        print("  rc=%d  %s" % (rc, total))
        if rc == 0 or not failed:
            all_killed = False
            print("  !! SURVIVED")
        else:
            for f in failed:
                print("  killed by: %s" % f)
        io.open(DIDCS, "w", encoding="utf-8", newline="").write(original)
finally:
    io.open(DIDCS, "w", encoding="utf-8", newline="").write(original)

rc, failed, total = run_tests()
print("\nRESTORED: rc=%d  %s" % (rc, total))
print("RESULT: %s" % ("all mutants killed" if all_killed else "A MUTANT SURVIVED"))
sys.exit(0 if all_killed and rc == 0 and not failed else 1)