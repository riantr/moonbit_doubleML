"""Test arm (b) -- unclamped Newton -- ON TOP of the shipped arm (a).

Supersedes `_lplr_ab_fuzz_1680.py`, which was written against the pre-D4
baseline: its first two anchors renamed `_beta_start` -> `beta_start` and
swapped the return to `(beta_start, true)`. Both are already committed in
`df049c2`, so those anchors match zero times and the probe aborts before it
patches anything. Measuring 0 anchors would have been reported as "probe
broken", not as a property of the clamp.

What remains untested is the single thing the earlier fuzz failure was
attributed to. That failure was measured on arm (b) ALONE -- unclamped but
still starting from the ad-hoc OLS scale, which is O(10) away from the root on
the small-n designs. With `mean(beta)` as the start (now shipped) the Newton
no longer begins far from the root, so the leap that blew the variance up at
fuzz trial 7 may not occur.

This is a MUTATION arm applied on top of a committed HEAD, so the restore in
the `finally` is a byte-for-byte copy of the file as found -- not a
`git checkout`, which would also discard the arm under test.

A crash is not a measurement: `moon check` failure exits 2 and is reported as
DOES NOT COMPILE, never as a fuzz result.
"""

import io
import os
import shutil
import subprocess
import sys

REPO = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML"
LPLR = os.path.join(REPO, "moonbit_doubleML", "lplr.mbt")
BACKUP = os.path.join(REPO, "_verify", "_clamp_backup.mbt")

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
    n = base.count(CLAMP_OLD)
    if n != 1:
        raise SystemExit("clamp anchor matched %d times; probe would measure "
                         "nothing" % n)
    shutil.copyfile(LPLR, BACKUP)
    try:
        write(LPLR, base.replace(CLAMP_OLD, CLAMP_NEW))
        on_disk = read(LPLR)
        # Assert the mutation is really on disk BEFORE running anything that
        # could be mistaken for a measurement of the unmutated code.
        assert on_disk != base, "patch did not change the file"
        assert on_disk.count(CLAMP_OLD) == 0, "old clamp survived the patch"
        assert on_disk.count("theta_new = theta - step *") == 0, \
            "descent fallback survived the patch"
        print("mutation on disk: True")

        chk = subprocess.run(["moon", "check", "--target", "native"],
                             cwd=REPO, capture_output=True, text=True,
                             encoding="utf-8", errors="replace")
        if chk.returncode != 0:
            print("DOES NOT COMPILE -- not a measurement")
            print(((chk.stdout or "") + (chk.stderr or ""))[-800:])
            return 2
        print("compiles")

        f = subprocess.run(["moon", "run", "examples/fuzz", "--target", "native"],
                           cwd=REPO, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        out = (f.stdout or "") + (f.stderr or "")
        print("--- fuzz exit %d ---" % f.returncode)
        for line in out.splitlines():
            if ("FUZZ FAIL" in line or "ALL FUZZ SURFACES PASSED" in line
                    or "WARN" in line):
                print(line.strip())
        if "ALL FUZZ SURFACES PASSED" not in out:
            print("--- tail ---")
            print("\n".join(out.splitlines()[-25:]))
        return 0
    finally:
        shutil.copyfile(BACKUP, LPLR)
        print("restored byte-for-byte:", read(LPLR) == base)
        os.remove(BACKUP)


if __name__ == "__main__":
    sys.exit(main())
