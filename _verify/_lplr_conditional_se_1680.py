"""Arm (b) + a SHARPER fuzz invariant, as a 2-file scripted mutation.

Two measurements in one run:

1. Does the unclamped Newton satisfy "SE is finite UNLESS the solver did not
   converge"? Upstream's own algebra supports this: at a root psi = 0 so
   gamma = 0 and sigma2 = 0/(J^2 n) = 0, a finite SE. Away from a root, psi^2
   and J^2 can both overflow to Inf and sigma2 = Inf/Inf = NaN. So non-finite
   SE should coincide with non-convergence rather than being free-standing.

2. How far the absolute ceiling can be relaxed, if (1) holds.

The old fuzz check was `se == se && se >= 0 && se < 1e10` -- an unconditional
demand for a finite SE. Upstream has no guard that supplies one: its variance
is `scaling * mean(psi^2)` with `scaling = 1/(n J^2)`
(`doubleml/utils/_estimation.py:362-418`), which is Inf/Inf = NaN at the same
iterate, and its root finder is a plain Newton with no step cap
(scipy 1.18 `_zeros_py.newton`). So that check asserts a property upstream does
not have.

THIS IS A MUTATION PROBE, NOT A SHIP. It patches two tracked files and restores
both byte-for-byte in a `finally`. A compile failure is reported as
DOES NOT COMPILE and is never counted as a fuzz result.
"""

import io
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LPLR = os.path.join(REPO, "moonbit_doubleML", "lplr.mbt")
FUZZ = os.path.join(REPO, "examples", "fuzz", "main.mbt")
BACKUP_DIR = os.path.join(REPO, "_verify", "_ab2_backup")

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

SE_CHECK_OLD = """    check(
      se == se && se >= 0.0 && se < 1.0e10,
      "lplr non-negative finite se (trial=\\{trial}, se=\\{se}, th=\\{th})",
    )
"""
SE_CHECK_NEW = """    let n_warn = model.warnings().length()
    check(
      (se == se && se >= 0.0 && se < 1.0e10) || n_warn > 0,
      "lplr se finite unless the solver warned (trial=\\{trial}, se=\\{se}, th=\\{th}, warn=\\{n_warn})",
    )
"""


def read(p):
    with io.open(p, encoding="utf-8", newline="") as f:
        return f.read()


def write(p, t):
    with io.open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(t)


def main():
    base_lplr = read(LPLR)
    base_fuzz = read(FUZZ)
    if os.path.isdir(BACKUP_DIR):
        raise SystemExit("stale backup dir: %s" % BACKUP_DIR)
    os.makedirs(BACKUP_DIR)
    shutil.copyfile(LPLR, os.path.join(BACKUP_DIR, "lplr.mbt"))
    shutil.copyfile(FUZZ, os.path.join(BACKUP_DIR, "fuzz_main.mbt"))
    try:
        for label, src, old in (
            ("clamp", base_lplr, CLAMP_OLD),
            ("se-check", base_fuzz, SE_CHECK_OLD),
        ):
            if src.count(old) != 1:
                raise SystemExit("anchor %r matched %d times"
                                 % (label, src.count(old)))
        write(LPLR, base_lplr.replace(CLAMP_OLD, CLAMP_NEW))
        write(FUZZ, base_fuzz.replace(SE_CHECK_OLD, SE_CHECK_NEW))

        on_lplr = read(LPLR)
        on_fuzz = read(FUZZ)
        assert on_lplr != base_lplr and on_lplr.count(CLAMP_OLD) == 0
        assert on_fuzz != base_fuzz and on_fuzz.count(SE_CHECK_OLD) == 0
        assert "theta_new = theta - step *" not in on_lplr
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
            if ("FUZZ FAIL" in line or "ALL FUZZ SURFACES PASSED" in line
                    or "warned" in line or "finite_se" in line):
                print(line.strip())
        if "ALL FUZZ SURFACES PASSED" not in out:
            print("--- tail ---")
            print("\n".join(out.splitlines()[-30:]))
        return 0
    finally:
        shutil.copyfile(os.path.join(BACKUP_DIR, "lplr.mbt"), LPLR)
        shutil.copyfile(os.path.join(BACKUP_DIR, "fuzz_main.mbt"), FUZZ)
        ok_l = read(LPLR) == base_lplr
        ok_f = read(FUZZ) == base_fuzz
        print("restored lplr byte-for-byte:", ok_l)
        print("restored fuzz byte-for-byte:", ok_f)
        shutil.rmtree(BACKUP_DIR)


if __name__ == "__main__":
    sys.exit(main())
