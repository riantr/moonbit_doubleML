"""D1 + unclamped Newton, tested against the DIVERGENCE criterion.

Section 13 of `_verify/LPLR_GATE_BLINDNESS_1680.md` recorded the conclusion
that removing the Newton clamp does not ship, because the port diverges on
designs where upstream stays finite -- and that the divergence is an input,
not the solver. The known input gap is `m_pred = a_pred`: upstream's score
uses `d_tilde = d - m_hat["preds"]`, where `m_hat` is ml_M = E[Y | D, X]
(`plm/lplr.py:403`), while the port aliases `m_pred` to `a_pred`, which is
ml_m's OUTER OOF of E[D | X].

D1 was implemented once before and reverted at 903e5ce, because the n=500
gate got worse. That gate is the one design point where LPLR was never
wrong, so "it got worse there" is not evidence about this. This probe
therefore does NOT use the n=500 gap as its criterion. It asks a question
with a sharp pass/fail:

    Does D1 + unclamped Newton keep the port FINITE where upstream is
    finite?

Upstream's own measurement is 0 non-finite SE over 300 draws of this repo's
binary DGP. If the faithful input makes the unguarded Newton safe, the port
should reach 0/300 too. If it does not, the input is not the cause and the
clamp has to stay for a reason I have not found yet.

This is a MUTATION probe: it patches a tracked file and restores it
byte-for-byte in a `finally`. Compile failure is reported as DOES NOT
COMPILE and is never counted as a result.
"""

import io
import os
import shutil
import subprocess
import sys

REPO = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
LPLR = os.path.join(REPO, "moonbit_doubleML", "lplr.mbt")
BACKUP = os.path.join(REPO, "_verify", "_d1_backup.mbt")

D1_OLD = "        m_pred = a_pred\n"
D1_NEW = "        m_pred = cross_fit_predict_dispatch(ml_m, xd, y, outer)\n"

CLAMP_OLD = """        let raw_delta = s / sd
        let mut theta_new = theta - raw_delta
        if theta_new.abs() > 5.0 || (theta_new - theta).abs() > 1.0 {
          let step = if raw_delta.abs() < 0.25 { raw_delta } else { 0.25 }
          theta_new = theta - step * (if s > 0.0 { 1.0 } else { -1.0 })
        }
        if (theta_new - theta).abs() < 1.0e-9 {
"""
CLAMP_NEW = """        let raw_delta = s / sd
        let theta_new = theta - raw_delta
        if (theta_new - theta).abs() < 1.0e-9 {
"""


def read(p):
    with io.open(p, encoding="utf-8", newline="") as f:
        return f.read()


def write(p, t):
    with io.open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(t)


def main():
    base = read(LPLR)
    for label, anchor in (("d1", D1_OLD), ("clamp", CLAMP_OLD)):
        n = base.count(anchor)
        if n != 1:
            raise SystemExit("anchor %r matched %d times; probe would "
                             "measure nothing" % (label, n))
    shutil.copyfile(LPLR, BACKUP)
    try:
        write(LPLR, base.replace(D1_OLD, D1_NEW).replace(CLAMP_OLD, CLAMP_NEW))
        on = read(LPLR)
        # Assert BOTH mutations are on disk before running anything.
        assert on.count(D1_OLD) == 0, "D1 did not apply"
        assert on.count(D1_NEW) == 1, "D1 did not land"
        assert on.count(CLAMP_OLD) == 0, "clamp survived"
        assert "theta_new = theta - step *" not in on, "fallback survived"
        print("both mutations on disk: True")

        chk = subprocess.run(["moon", "check", "--target", "native"],
                             cwd=REPO, capture_output=True, text=True,
                             encoding="utf-8", errors="replace")
        if chk.returncode != 0:
            print("DOES NOT COMPILE -- not a measurement")
            print(((chk.stdout or "") + (chk.stderr or ""))[-1200:])
            return 2
        print("compiles")

        f = subprocess.run(["moon", "run", "examples/fuzz", "--target", "native"],
                           cwd=REPO, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        out = (f.stdout or "") + (f.stderr or "")
        print("--- fuzz exit %d ---" % f.returncode)
        for line in out.splitlines():
            if "FUZZ FAIL" in line or "ALL FUZZ SURFACES PASSED" in line:
                print(line.strip())
        if "ALL FUZZ SURFACES PASSED" not in out:
            print("--- tail ---")
            print("\n".join(out.splitlines()[-20:]))
        return 0
    finally:
        shutil.copyfile(BACKUP, LPLR)
        print("restored byte-for-byte:", read(LPLR) == base)
        os.remove(BACKUP)


if __name__ == "__main__":
    sys.exit(main())
