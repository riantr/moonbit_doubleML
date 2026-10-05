"""v0.104.0: exact cross-check of the MoonBit isotonic-regression
core against `sklearn.isotonic.isotonic_regression`.

WHAT THIS REPLACED, and why it matters. Through v0.103.0 this
file imported `subprocess` and defined two MoonBit drivers --
`run_moonbit_pava` and `moonbit_isotonic_via_psprocessor` -- both
of which did nothing but `raise NotImplementedError` and were
never called. `reference_check` then printed sklearn's numbers
for a human to compare by hand against a markdown file, and the
file ended in a hard-coded

    PAVA cross-check PASS

with no assertion anywhere. A validator whose verdict cannot
change is decoration, and this one was wearing the label of a
gate: v0.103.0's audit classified it as "imports subprocess,
never runs it".

WHY THIS CHECK IS SHARP WHERE THE OTHERS ARE LOOSE. Every other
cross-check in this repository has to allow for Monte-Carlo
error, because the MoonBit side draws from `chacha8_rng` and the
Python side from `numpy.random.default_rng` and the two streams
cannot be aligned. PAVA has no sampling in it. The isotonic fit
of a sorted vector is the unique minimiser of the weighted sum of
squared residuals subject to monotonicity, so feeding both sides
the same literal `y` gives the same number to rounding. The
tolerance below is 1e-12, not the `max(MODEL_TOL, 2*se)` style
bounds the MC checks need.

The example `examples/pava` prints one line per case; the vectors
below are duplicated from `examples/pava/main.mbt`, and a
mismatch in the case LABELS is itself a failure so the two files
cannot silently drift apart.
"""

import re
import subprocess
import sys

import numpy as np
from sklearn.isotonic import isotonic_regression

# Elementwise tolerance. Both sides compute the same minimiser in
# a different summation order, so this is rounding, not slack.
TOL = 1e-12

# (label, y already sorted by x, sample_weight or None).
# Mirrors examples/pava/main.mbt. The comments there explain what
# each vector is for; the short version is that v2 is the cascade
# case (3,2,1 pools down, 5,4 pools up, and the trailing 6 must
# not drag the 4.5 block up) and v4 is the only weighted one, so
# a bug that drops the weights changes v4 alone.
CASES = [
    ("v0", [0.9, 0.7, 0.8, 0.1], None),
    ("v1", [0.1, 0.3, 0.3, 0.7], None),
    ("v2", [3.0, 2.0, 1.0, 5.0, 4.0, 6.0], None),
    ("v3", [0.01, 0.02, 0.03, 0.9, 0.4, 0.5, 0.6], None),
    ("v4", [0.2, 0.5, 0.1, 0.8], [1.0, 1.0, 0.25, 1.0]),
]


def run_moonbit():
    """Spawn `moon run examples/pava` and parse the case lines.

    Returns {label: [floats]}. Raises on any failure -- the
    caller turns that into FAIL, because a skipped MoonBit side
    is exactly the hole this file was written to close.
    """
    result = subprocess.run(
        ["moon", "run", "examples/pava", "--target", "native"],
        capture_output=True,
        text=True,
        timeout=900,
    )
    if result.returncode != 0:
        # `stderr` is not guaranteed to be a string -- a build that
        # dies before the toolchain attaches leaves it as None, and
        # slicing it here would raise a TypeError that masks the
        # real cause. Coerce first.
        err = result.stderr or ""
        raise RuntimeError(
            f"moon run examples/pava exited {result.returncode}: "
            f"{err[:400]}"
        )
    out = result.stdout or ""
    out = {}
    for m in re.finditer(
        r"^case\[(\w+)\]\s+n=(\d+)\s+pava\s*=\s*([-\d.eE+ ]+)$",
        result.stdout,
        re.MULTILINE,
    ):
        label, n_declared, payload = m.group(1), int(m.group(2)), m.group(3)
        values = [float(v) for v in payload.split()]
        if len(values) != n_declared:
            raise RuntimeError(
                f"case[{label}]: header says n={n_declared} but "
                f"{len(values)} values follow"
            )
        out[label] = values
    if not out:
        raise RuntimeError(
            "no `case[...]` lines in example output:\n" + result.stdout[:600]
        )
    return out


def main():
    print("=" * 70)
    print("MoonBit PAVA vs sklearn.isotonic.isotonic_regression")
    print("=" * 70)

    print("\n--- sklearn reference (fixed inputs, no sampling) ---")
    expected = {}
    for label, y, w in CASES:
        ref = isotonic_regression(
            np.asarray(y, dtype=float),
            sample_weight=(
                None if w is None else np.asarray(w, dtype=float)
            ),
        )
        expected[label] = np.asarray(ref, dtype=float)
        print(f"  case[{label}] n={len(y)} ref = {np.round(ref, 12).tolist()}")

    print("\n--- MoonBit: `moon run examples/pava` ---")
    try:
        got = run_moonbit()
    except Exception as exc:  # noqa: BLE001 - any failure is a FAIL
        print(f"could not obtain the MoonBit output: {exc}")
        print("")
        print("PAVA cross-check FAIL")
        sys.exit(1)

    missing = [label for label, _, _ in CASES if label not in got]
    extra = [label for label in got if label not in expected]
    if missing or extra:
        print(f"case labels disagree: missing={missing} extra={extra}")
        print("  (the vector tables in this file and in "
              "examples/pava/main.mbt have drifted apart)")
        print("")
        print("PAVA cross-check FAIL")
        sys.exit(1)

    ok_all = True
    print("")
    print("--- checks ---")
    for label, y, w in CASES:
        got_arr = np.asarray(got[label], dtype=float)
        ref_arr = expected[label]
        if got_arr.shape != ref_arr.shape:
            print(f"  case[{label}] FAIL: length {got_arr.shape} vs "
                  f"{ref_arr.shape}")
            ok_all = False
            continue
        worst = float(np.max(np.abs(got_arr - ref_arr)))
        ok = worst < TOL
        ok_all = ok_all and ok
        print(
            f"  case[{label}] max|moonbit - sklearn| = {worst:.3e} "
            f"< {TOL:.0e} -> {'PASS' if ok else 'FAIL'}"
        )
        if not ok:
            print(f"    moonbit = {got_arr.tolist()}")
            print(f"    sklearn = {ref_arr.tolist()}")

    # A monotone result is a property, not a comparison, so it is
    # worth stating on its own: every case must come back
    # non-decreasing. An implementation that returned its input
    # unchanged would match `isotonic_regression` on v1 and fail
    # everywhere else, but this catches the case where sklearn
    # were also wrong -- cheap, and it documents the contract.
    monotone = True
    for label in expected:
        arr = np.asarray(got[label], dtype=float)
        if np.any(np.diff(arr) < 0):
            print(f"  case[{label}] FAIL: output is not non-decreasing")
            monotone = False
    print(f"  all outputs non-decreasing -> {'PASS' if monotone else 'FAIL'}")

    ok_all = ok_all and monotone
    print("")
    print("PAVA cross-check " + ("PASS" if ok_all else "FAIL"))
    if not ok_all:
        sys.exit(1)


if __name__ == "__main__":
    main()
