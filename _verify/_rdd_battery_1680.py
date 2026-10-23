"""Mutation battery for pyexample_rdd.py.

A gate that has never been seen to fail is not known to discriminate. Each arm
mutates the EMITTER, runs the gate, and asserts the exit code. Every mutation is
asserted to be on disk before the run and removed after it, so a stale file
cannot be mistaken for a passing arm.
"""
import io
import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "examples", "parity", "main.mbt")
GATE = os.path.join(REPO, "pyexample_rdd.py")

ORIG_TAU_BC = '  val("tau_bc", homo.tau_bc())\n'
ORIG_SE_RB = '  val("tau_bc_se_rb", homo.tau_bc_se_rb())\n'
ORIG_SUM_Y = '  val("sum_y", wsum(y))\n'

ARMS = [
    ("C0 control", [], "PASS",
     "no mutation -- establishes that the arm set can produce green"),
    ("M1 tau_bc * (1+1e-9)", [(ORIG_TAU_BC,
                              '  val("tau_bc", homo.tau_bc() * (1.0 + 1.0e-9))\n')],
     "FAIL",
     "relative 1e-9 on the gated point estimate is 100x the 1e-11 bound"),
    ("M2 tau_bc_se_rb * (1+1e-9)", [(ORIG_SE_RB,
                                     '  val("tau_bc_se_rb", homo.tau_bc_se_rb() * '
                                     '(1.0 + 1.0e-9))\n')],
     "FAIL",
     "same, on the gated robust SE"),
    ("M3 tau_bc * (1+1e-13)", [(ORIG_TAU_BC,
                               '  val("tau_bc", homo.tau_bc() * (1.0 + 1.0e-13))\n')],
     "PASS",
     "BELOW the bound -- a gate that failed here would be a tripwire, not a "
     "measurement"),
    ("M4 sum_y + 1e-6", [(ORIG_SUM_Y, '  val("sum_y", wsum(y) + 1.0e-6)\n')],
     "FAIL",
     "proves the design fingerprint actually discriminates, so a green gate "
     "is not a gate that skipped step 1"),
    ("M6 tau_bc row removed", [(ORIG_TAU_BC, "")],
     "FAIL",
     "fails CLOSED on a missing row -- the gate must not silently skip an "
     "absent quantity"),
]


def read():
    with io.open(SRC, encoding="utf-8", newline="") as fh:
        return fh.read()


def write(s):
    with io.open(SRC, "w", encoding="utf-8", newline="") as fh:
        fh.write(s)


def run_gate():
    t0 = time.time()
    r = subprocess.run([sys.executable, GATE, "--check"], cwd=REPO,
                       capture_output=True, text=True, timeout=3600)
    verdict = "?"
    for line in r.stdout.splitlines():
        if line.startswith("RESULT:"):
            verdict = "PASS" if "PASS" in line else "FAIL"
    if verdict == "?":
        # A crash and a red gate both exit 1. Scoring only the exit code would
        # call a traceback a pass, so the missing verdict is its own outcome.
        verdict = "CRASH"
    return r.returncode, verdict, time.time() - t0, r.stdout + r.stderr


def main():
    base = read()
    for name, orig in (("tau_bc", ORIG_TAU_BC), ("tau_bc_se_rb", ORIG_SE_RB),
                       ("sum_y", ORIG_SUM_Y)):
        if base.count(orig) != 1:
            print("ABORT: anchor %r occurs %d times in main.mbt, expected 1"
                  % (name, base.count(orig)))
            return 2
    print("anchors verified: each occurs exactly once\n")

    results = []
    try:
        for label, subs, want, why in ARMS:
            write(base)
            for old, new in subs:
                s = read()
                assert s.count(old) == 1, "anchor vanished before mutation"
                write(s.replace(old, new))
            # Assert the mutation is ON DISK before trusting the run.
            on_disk = read()
            for old, new in subs:
                if new:
                    if on_disk.count(new) != 1:
                        print("ABORT: mutation for %s is not on disk" % label)
                        return 2
                elif on_disk.count(old) != 0:
                    print("ABORT: removal for %s is not on disk" % label)
                    return 2
            rc, verdict, secs, out = run_gate()
            good = (verdict == want)
            results.append((label, want, verdict, good, secs))
            print("%-28s expect %-4s got %-4s exit=%d  %5.0fs   %s"
                  % (label, want, verdict, rc, secs, "OK" if good else "**WRONG**"))
            print("    %s" % why)
            if not good:
                print("\n--- emitter output ---")
                print(out[-3000:])
                print("------------------------")
    finally:
        write(base)
        assert read() == base, "restore failed: main.mbt is not byte-identical"

    n_ok = sum(1 for r in results if r[3])
    print("\nbattery: %d/%d arms behaved as specified" % (n_ok, len(results)))
    return 0 if n_ok == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
