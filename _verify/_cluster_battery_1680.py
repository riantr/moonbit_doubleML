"""Mutation battery for the new upstream pin in plpr_test.mbt.

THE PROBE, AND WHY THE FIRST VERSION OF IT WAS WORTHLESS
========================================================
`moon test` prints `test <file>:<line> ("<name>") failed:` for FAILING tests
only. A passing test is never named. So the first version of this battery,
which looked for the test's name and reported "PASS" when it appeared without
the word `failed`, could not distinguish:

  * the test passing, from
  * a build error whose output happened to mention the name, from
  * a completely different failure.

Its control arm came back ABSENT and it reported 0/3. That is the probe being
wrong, not the subject. The instrument below is therefore stated in terms of
what `moon test` actually reports:

  control  -> zero failures overall, and the pinned test NOT in the failed list
  mutant   -> at least one failure overall, AND the pinned test IS named

Both halves matter: a mutant that turns something else red without turning
THIS test red has not shown that this pin discriminates.

M1 drops the square off the gamma accumulator (`s*s` -> `s`): a different
estimator, still well-typed.
M2 drops the `1/m` weight on the Jacobian analogue (`w*sd` -> `sd`): also
well-typed. An earlier M2 divided by `n_units`, which is a COMPILE error --
a build failure proves nothing about whether the assertion discriminates.
"""
import io
import os
import re
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "moonbit_doubleML", "plpr.mbt")

MY_TEST = "plpr_var_est_cluster_matches_upstream_var_one_way_cluster"

ORIG_GAMMA = "        gamma = gamma + w * s * s\n"
ORIG_JHAT = "        j_hat = j_hat + w * sd\n"

ARMS = [
    ("C0 control", [], False,
     "no mutation; the battery must be able to produce green"),
    ("M1 drop the square", [(ORIG_GAMMA, "        gamma = gamma + w * s\n")], True,
     "the gamma meat is sum S_g^2; s alone is a different estimator"),
    ("M2 drop the 1/m weight", [(ORIG_JHAT, "        j_hat = j_hat + sd\n")], True,
     "the Jacobian analogue is weighted by 1/m per fold, not unweighted"),
]


def read():
    with io.open(SRC, encoding="utf-8", newline="") as fh:
        return fh.read()


def write(s):
    with io.open(SRC, "w", encoding="utf-8", newline="") as fh:
        fh.write(s)


def run_tests():
    # text=True would decode with the locale codec, which is GBK on this box and
    # dies on the first non-ASCII byte moon emits. Decode explicitly.
    r = subprocess.run(["moon", "test", "--deny-warn"], cwd=REPO,
                       capture_output=True, text=True, timeout=3600,
                       encoding="utf-8", errors="replace")
    out = (r.stdout or "") + (r.stderr or "")
    # `moon test` names failures as: test <file>:<line> ("<name>") failed: ...
    failed_names = set(re.findall(r'\("([^"]+)"\)\s*failed', out))
    totals = re.findall(
        r"Total tests: (\d+), passed: (\d+), failed: (\d+)", out)
    n_failed = max((int(t[2]) for t in totals), default=-1)
    return failed_names, n_failed, out


def main():
    base = read()
    for name, anchor in (("gamma", ORIG_GAMMA), ("j_hat", ORIG_JHAT)):
        if base.count(anchor) != 1:
            print(f"ABORT: anchor {name!r} occurs {base.count(anchor)} times,"
                  " expected 1")
            return 2
    print("anchors verified\n")

    results = []
    try:
        for label, subs, want_red, why in ARMS:
            write(base)
            for old, new in subs:
                s = read()
                assert s.count(old) == 1, "anchor vanished"
                write(s.replace(old, new))
            on_disk = read()
            for old, new in subs:
                if on_disk.count(new) != 1:
                    print(f"ABORT: mutation for {label} is not on disk")
                    return 2
            t0 = time.time()
            failed_names, n_failed, out = run_tests()
            mine_failed = MY_TEST in failed_names
            # A build error reports no totals at all. That is not a red test.
            if n_failed < 0:
                print(f"{label}: NO TEST TOTALS -- the mutation broke the build, "
                      "which proves nothing about the assertion")
                print("\n".join(out.splitlines()[-25:]))
                return 2
            got_red = n_failed > 0 and mine_failed
            good = got_red == want_red
            results.append((label, good))
            print(f"{label:<24} failed={n_failed:<4} "
                  f"pin-named={'yes' if mine_failed else 'NO ':<4} "
                  f"expect_red={str(want_red):<5} got_red={str(got_red):<5} "
                  f"{time.time() - t0:>4.0f}s  {'OK' if good else '**WRONG**'}")
            print(f"    {why}")
            if not good:
                print(f"    first few failures: {sorted(failed_names)[:6]}")
    finally:
        write(base)
        assert read() == base, "restore failed: plpr.mbt is not byte-identical"

    n_ok = sum(1 for _, g in results if g)
    print(f"\nbattery: {n_ok}/{len(results)} arms behaved as specified")
    return 0 if n_ok == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
