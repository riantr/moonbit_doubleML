"""Fail-closed validator for the v0.109.0 sample-splitting contract.

`expand_v109_test.mbt` can only assert the ACCEPTED paths, because a refusal is
an `abort` and an abort inside a test kills the whole test binary. This drives
`examples/splitting` out of process, where a non-zero exit is a clean,
attributable outcome.

The point of the negative modes: a validator that only ran mode `ok` would pass
against a `check_sample_splitting` that validated nothing at all. Every refusal
below is a distinct property, so skipping any one of them is detectable:

    overlap     test sets of two folds are not disjoint
    short       the test sets do not cover every row  (a cover is not a partition)
    ragged      the repetitions disagree on the fold count
    outofrange  an index lies outside [0, n_obs)
    empty       a repetition has no folds

`ok` additionally checks the DERIVATION: the model is constructed with
`n_folds=9, n_rep=7` and supplied 3 folds over 2 repetitions, so the printed
counts must be 3 and 2. If `set_sample_splitting` merely stored the folds and
left the configured counts alone, the validator fails on a number rather than
on a crash.

Each refusal below is a DISTINCT property, so skipping one is detectable:

    overlapcover  test sets overlap but their union is still complete --
                  this is the one that pins DISJOINTNESS on its own
    overlap       an earlier, weaker variant whose folds ALSO left rows
                  untested, so the coverage check caught it even when
                  disjointness was not checked at all
    short         the test sets do not cover every row (a cover is not a
                  partition)
    ragged        the repetitions disagree on the fold count
    outofrange    an index lies outside [0, n_obs)
    empty         a repetition has no folds

`overlap` and `overlapcover` both exist because of a measured failure: with
only `overlap` present, deleting the disjointness check changed nothing the
validator could see and that mutation survived. An input has to violate
exactly one property to pin that property.
"""

import re
import subprocess
import sys

EXAMPLE = "examples/splitting"
TARGET = "native"

MUST_SUCCEED = {
    "ok": {"folds": 3, "reps": 2},
}
MUST_ABORT = ["overlapcover", "overlap", "short", "ragged", "outofrange", "empty"]


def run(mode):
    # encoding/errors pinned: `moon` writes its abort traceback to stderr, and
    # on a zh-CN Windows box `text=True` with the default locale decodes that
    # as GBK and raises UnicodeDecodeError. The exception propagated out of
    # main() as a non-zero exit, which LOOKED like a refused partition and
    # passed by accident -- on an English box the same code path would not
    # raise, so the verdict depended on the machine's locale. Pinned here so
    # the exit code reflects the contract, not the environment.
    p = subprocess.run(
        ["moon", "run", EXAMPLE, "--target", TARGET, "--", mode],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return p.returncode, p.stdout, p.stderr


def main():
    problems = []

    print("--- MoonBit side: `moon run examples/splitting --target native -- <mode>` ---")
    for mode, want in MUST_SUCCEED.items():
        code, out, err = run(mode)
        print(f"  {mode:11s} exit={code}")
        got = {}
        for m in re.finditer(r"^splitting (\w+)=(\S+)$", out, re.M):
            got[m.group(1)] = m.group(2)
        for line in out.splitlines():
            if line.startswith("splitting "):
                print(f"      {line.strip()}")
        if code != 0:
            problems.append(
                f"mode '{mode}' should SUCCEED but exited {code}: "
                f"{(err or out)[:300]}"
            )
            continue
        for key, expect in want.items():
            actual = got.get(key)
            if actual is None:
                problems.append(f"mode '{mode}': no `splitting {key}=` line")
            elif actual != str(expect):
                problems.append(
                    f"mode '{mode}': derived {key} = {actual}, expected {expect}. "
                    "set_sample_splitting must DERIVE the counts from the "
                    "supplied partition, not keep the constructor's."
                )
        if "coef" not in got:
            problems.append(f"mode '{mode}': fit printed no coefficient")

    for mode in MUST_ABORT:
        code, out, err = run(mode)
        aborted = code != 0 and ("abort" in (out + err).lower() or code < 0 or code > 1)
        print(f"  {mode:11s} exit={code}  {'aborted as required' if code != 0 else 'ACCEPTED -- NOT REFUSED'}")
        if code == 0:
            problems.append(
                f"mode '{mode}': check_sample_splitting ACCEPTED an invalid "
                "partition. A validator that only ran the happy path would "
                "not have noticed."
            )
        elif not aborted:
            problems.append(
                f"mode '{mode}': exited {code} but the output does not look "
                f"like a MoonBit abort: {(out + err)[:200]}"
            )

    print()
    if problems:
        print("Sample-splitting contract FAILED:")
        for p in problems:
            print(f"  - {p}")
        print("sample-splitting contract: FAIL")
        return 1

    print("Sample-splitting contract holds: the fold and repetition counts are "
          "derived from the supplied partition, and all "
          f"{len(MUST_ABORT)} invalid partitions are refused.")
    print("Sample-splitting cross-check: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
