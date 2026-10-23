"""Mutation harness for the v0.144.0 DoubleMLPLR sensitivity fix.

A new gate that has never failed is not evidence. This harness re-imposes the
PRE-FIX semantics on `DoubleMLPLR::sensitivity_analysis` -- `nu2 = mean(v^4)`
and `sigma2 = mean((y - l_hat)^2)`, which is exactly what
`irm_style_sensitivity(coef, y - l_hat, psi_a, ...)` produced, because
`psi_a = -v^2` and that helper squares its third argument -- and then requires
the v0.144.0 gates to FAIL.

Two mutations, run independently, so a gate that only detects one of the two
corrections is visible as such:

  M1  nu2 reverts to mean(v^4)          (defeats GATE 1, 4)
  M2  sigma2 reverts to mean((y-l)^2)   (defeats GATE 2, 6)

Both mutations must be rejected. A mutation that still compiles but passes the
suite is a gate that does not discriminate.

Restores the original file in a finally block, so an interrupted run cannot
leave the tree mutated.
"""
import io
import os
import re
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(REPO, "moonbit_doubleML")
PLR = os.path.join(PKG, "plr.mbt")

# The two lines the fix replaced, verbatim from plr.mbt.
NEW = """  let n_d = n.to_double()
  let nu2 = 1.0 / (ss_v2 / n_d)
  let sigma2 = ss_resid / n_d
  sensitivity_from_variance_baselines(theta, sigma2, nu2, n, cf_y, cf_d)"""

M1 = """  let n_d = n.to_double()
  let mut ss_v4 = 0.0
  for i = 0; i < n; i = i + 1 {
    let vv = self.data.d[i] - m_hat[i]
    ss_v4 = ss_v4 + vv * vv * vv * vv
  }
  let nu2 = ss_v4 / n_d
  let sigma2 = ss_resid / n_d
  sensitivity_from_variance_baselines(theta, sigma2, nu2, n, cf_y, cf_d)"""

M2 = """  let n_d = n.to_double()
  let nu2 = 1.0 / (ss_v2 / n_d)
  let mut ss_un = 0.0
  for i = 0; i < n; i = i + 1 {
    let uu = self.data.y[i] - l_hat[i]
    ss_un = ss_un + uu * uu
  }
  let sigma2 = ss_un / n_d
  sensitivity_from_variance_baselines(theta, sigma2, nu2, n, cf_y, cf_d)"""

MUTANTS = [("M1 nu2 -> mean(v^4)", M1), ("M2 sigma2 -> mean((y-l)^2)", M2)]


def run_tests():
    p = subprocess.run(
        "moon test --target native --filter *plr_sensitivity*",
        cwd=PKG, shell=True, capture_output=True, text=True,
        encoding="utf-8", errors="replace", timeout=1800,
    )
    out = (p.stdout or "") + (p.stderr or "")
    # Match the per-test failure line only: `[pkg] test file ("name") failed:`.
    # A naive `" failed:" in line` also matches the SUMMARY line
    # `Total tests: 10, passed: 10, failed: 0.` -- which is how the first run of
    # this harness declared a green baseline to be failing.
    failed = re.findall(r'\("([^"]+)"\) failed:', out)
    tail = [l.strip() for l in out.splitlines() if "Total tests:" in l]
    return p.returncode, failed, (tail[-1] if tail else "(no total line)")


original = io.open(PLR, encoding="utf-8", newline="").read()
assert original.count(NEW) == 1, "anchor for the fix is not unique: %d" % original.count(NEW)
print("anchor found exactly once in plr.mbt\n")

# Baseline: unmutated must be GREEN, or the whole exercise proves nothing.
rc, failed, total = run_tests()
print("BASELINE (unmutated): rc=%d  %s" % (rc, total))
if failed:
    print("  !! baseline is already failing:")
    for f in failed:
        print("     " + f)
    sys.exit(1)

all_killed = True
try:
    for name, mutant in MUTANTS:
        mutated = original.replace(NEW, mutant)
        assert mutated != original
        io.open(PLR, "w", encoding="utf-8", newline="").write(mutated)
        rc, failed, total = run_tests()
        print("\n%s" % name)
        print("  rc=%d  %s" % (rc, total))
        if rc == 0 or not failed:
            all_killed = False
            print("  !! SURVIVED -- the gates did not notice this regression")
        else:
            for f in failed:
                print("  killed by: %s" % f)
        io.open(PLR, "w", encoding="utf-8", newline="").write(original)
finally:
    io.open(PLR, "w", encoding="utf-8", newline="").write(original)

# Confirm the tree really is restored.
rc, failed, total = run_tests()
print("\nRESTORED: rc=%d  %s" % (rc, total))
print("RESULT: %s" % ("all mutants killed" if all_killed else "AT LEAST ONE MUTANT SURVIVED"))
sys.exit(0 if all_killed and rc == 0 and not failed else 1)