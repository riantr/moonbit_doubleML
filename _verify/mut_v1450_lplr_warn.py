"""Mutation harness for the v0.145.0 LPLR non-convergence diagnostic.

A warning channel that has never been observed to fire is indistinguishable
from no warning channel at all. This harness degrades the diagnostic three ways
and requires the v0.145.0 gates to notice each one:

  M1  the warning push is removed entirely   -> the pre-fix `let _ = converged`
                                              behaviour, silently
  M2  the message loses the stop reason      -> a constant string, which is what
                                              a bare boolean flag amounts to
  M3  the message loses "not a solution"     -> the caller can no longer tell
                                              that coef/se are meaningless

M1 is the important one: it is exactly the state the package shipped in until
this release, so it is the regression these gates exist to prevent.

Restores lplr.mbt in a finally block.
"""
import io
import os
import re
import subprocess
import sys

REPO = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
PKG = os.path.join(REPO, "moonbit_doubleML")
LPLR = os.path.join(PKG, "lplr.mbt")

ANCHOR = """      if !converged {
        warnings.push(
          "rep " + r.to_string() + ": LPLR Newton solver did not converge (" +
          stop_reason + "); coef and se were computed at theta = " +
          theta.to_string() +
          ", which is not a solution of the estimating equation",
        )
      }"""

M1 = """      if !converged {
        let _ = converged
      }"""

M2 = """      if !converged {
        warnings.push("rep " + r.to_string() + ": LPLR Newton solver did not converge")
      }"""

M3 = """      if !converged {
        warnings.push(
          "rep " + r.to_string() + ": LPLR Newton solver did not converge (" +
          stop_reason + ")",
        )
      }"""

MUTANTS = [
    ("M1 warning removed (the pre-fix silent behaviour)", M1),
    ("M2 stop reason dropped (constant message)", M2),
    ("M3 'not a solution' dropped (no statement of meaning)", M3),
]


def run_tests():
    p = subprocess.run(
        "moon test --target native --filter *lplr_warn*",
        cwd=PKG, shell=True, capture_output=True, text=True,
        encoding="utf-8", errors="replace", timeout=3600,
    )
    out = (p.stdout or "") + (p.stderr or "")
    failed = re.findall(r'\("([^"]+)"\) failed:', out)
    tail = [l.strip() for l in out.splitlines() if "Total tests:" in l]
    return p.returncode, failed, (tail[-1] if tail else "(no total line)")


original = io.open(LPLR, encoding="utf-8", newline="").read()
assert original.count(ANCHOR) == 1, "anchor not unique: %d" % original.count(ANCHOR)
print("anchor found exactly once in lplr.mbt\n")

rc, failed, total = run_tests()
print("BASELINE (unmutated): rc=%d  %s" % (rc, total))
if failed or rc != 0:
    print("  !! baseline not green:")
    for f in failed:
        print("     " + f)
    sys.exit(1)

all_killed = True
try:
    for name, mutant in MUTANTS:
        mutated = original.replace(ANCHOR, mutant)
        assert mutated != original, "mutant identical to original: " + name
        io.open(LPLR, "w", encoding="utf-8", newline="").write(mutated)
        rc, failed, total = run_tests()
        print("\n%s" % name)
        print("  rc=%d  %s" % (rc, total))
        if rc == 0 or not failed:
            all_killed = False
            print("  !! SURVIVED")
        else:
            for f in failed:
                print("  killed by: %s" % f)
        io.open(LPLR, "w", encoding="utf-8", newline="").write(original)
finally:
    io.open(LPLR, "w", encoding="utf-8", newline="").write(original)

rc, failed, total = run_tests()
print("\nRESTORED: rc=%d  %s" % (rc, total))
print("RESULT: %s" % ("all mutants killed" if all_killed else "A MUTANT SURVIVED"))
sys.exit(0 if all_killed and rc == 0 and not failed else 1)