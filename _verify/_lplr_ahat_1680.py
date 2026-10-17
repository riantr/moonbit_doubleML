"""Measure the `a_hat` double-cross-fit gap (evidence doc section 14c).

Upstream's `a_hat`, used in

    r_hat["preds"] = t_hat["preds"] - beta * a_hat["preds"]   (lplr.py:345)

comes from `_double_dml_cv_predict(..., smpls=smpls, smpls_inner=...)` and
is a full `n`-vector: a row inside an outer fold's TRAINING set gets an INNER
out-of-fold prediction, a row in its test set gets the outer model's.

The port's `a_pred` (lplr.mbt:836) is a plain outer cross-fit, so every row
gets an outer-model prediction. The machinery to fix it already exists --
`a_inner_per_fold` (:801) is ml_m's inner OOF per outer fold, and
`double_cross_fit_predict` returns a vector of length `len(train_idx)` per
fold (kfold.mbt:757) -- so the combine is:

    a_pred[outer[fi].train_idx[k]] = a_inner_per_fold[fi][k]

run AFTER the plain outer cross-fit, which supplies the test rows.

Arms, selected by argv:
    a    -- a_hat fix only, Newton clamp KEPT
    b    -- a_hat fix + unclamped Newton
    ab   -- same as b

Arm `b` is the decisive one for the clamp question: the premise of the
clamp is that the port diverges because its inputs differ from upstream's.
If closing this gap lets the unclamped Newton survive, the premise holds.
If it does not, the clamp stays and the premise is wrong.

MUTATION probe: restores byte-for-byte in a `finally`. A compile failure is
DOES NOT COMPILE and is never a result.
"""

import io
import os
import shutil
import subprocess
import sys

REPO = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
LPLR = os.path.join(REPO, "moonbit_doubleML", "lplr.mbt")
BACKUP = os.path.join(REPO, "_verify", "_ahat_backup.mbt")

AHAT_OLD = "        a_pred = cross_fit_predict_dispatch(ml_m, x, d, outer)\n"
AHAT_NEW = (
    "        a_pred = cross_fit_predict_dispatch(ml_m, x, d, outer)\n"
    "        for fi_a = 0; fi_a < outer.length(); fi_a = fi_a + 1 {\n"
    "          let ti_a = outer[fi_a].train_idx\n"
    "          for k = 0; k < ti_a.length(); k = k + 1 {\n"
    "            a_pred[ti_a[k]] = a_inner_per_fold[fi_a][k]\n"
    "          }\n"
    "        }\n"
)

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


def run(cmd, timeout=2400):
    r = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def main():
    arm = sys.argv[1] if len(sys.argv) > 1 else "a"
    if arm not in ("a", "b", "ab"):
        raise SystemExit("arm must be a | b | ab")
    base = read(LPLR)
    if base.count(AHAT_OLD) != 1:
        raise SystemExit("a_hat anchor matched %d times" % base.count(AHAT_OLD))
    if base.count(CLAMP_OLD) != 1:
        raise SystemExit("clamp anchor matched %d times" % base.count(CLAMP_OLD))

    shutil.copyfile(LPLR, BACKUP)
    try:
        out = base.replace(AHAT_OLD, AHAT_NEW)
        if arm in ("b", "ab"):
            out = out.replace(CLAMP_OLD, CLAMP_NEW)
        write(LPLR, out)
        on = read(LPLR)
        # AHAT_NEW *contains* AHAT_OLD as its first line, so the old anchor
        # legitimately survives once inside the inserted block. The real test
        # is that the combine loop landed exactly once.
        assert on.count(AHAT_NEW) == 1, "a_hat fix did not land"
        assert on.count("a_pred[ti_a[k]] = a_inner_per_fold[fi_a][k]") == 1, \
            "combine loop missing"
        if arm in ("b", "ab"):
            assert on.count(CLAMP_OLD) == 0, "clamp survived"
        else:
            assert on.count(CLAMP_OLD) == 1, "clamp removed in arm a"
        print("arm=%s; mutations on disk: True" % arm)

        rc, o = run(["moon", "check", "--target", "native", "--deny-warn"])
        if rc != 0:
            print("DOES NOT COMPILE -- not a measurement")
            print(o[-1200:])
            return 2
        print("compiles clean under --deny-warn")

        rc, o = run(["moon", "run", "examples/fuzz", "--target", "native"])
        print("--- fuzz exit %d ---" % rc)
        for line in o.splitlines():
            if "FUZZ FAIL" in line or "ALL FUZZ SURFACES PASSED" in line:
                print(line.strip())
        fuzz_ok = "ALL FUZZ SURFACES PASSED" in o
        if not fuzz_ok:
            print("\n".join(o.splitlines()[-6:]))

        rc, o = run([sys.executable, "_lplr_gap_probe_1680.py"], timeout=3600)
        print("--- parity exit %d ---" % rc)
        print("--- parity tail (last 45 lines) ---")
        for line in o.splitlines()[-45:]:
            print(line.rstrip())
        print("VERDICT arm=%s fuzz=%s" % (arm, "GREEN" if fuzz_ok else "RED"))
        return 0
    finally:
        shutil.copyfile(BACKUP, LPLR)
        print("restored byte-for-byte:", read(LPLR) == base)
        os.remove(BACKUP)


if __name__ == "__main__":
    sys.exit(main())
