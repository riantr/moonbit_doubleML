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

import itertools
import re
import subprocess
import sys

import numpy as np
from sklearn.isotonic import isotonic_regression

# Elementwise tolerance. Both sides compute the same minimiser in
# a different summation order, so this is rounding, not slack.
TOL = 1e-12

# ---------------------------------------------------------------------- #
# THE ANALYTIC ORACLE
# ---------------------------------------------------------------------- #
# Agreeing with sklearn proves the port matches a particular implementation.
# It does not prove the port solves the PROBLEM. The oracle below does the
# latter, and it is worth having both because they fail differently: a shared
# misunderstanding of the specification passes the first and fails the second.
#
# `pava` is weighted isotonic regression -- the unique minimiser of
#
#     F(z) = sum_i w_i (y_i - z_i)^2    subject to   z_1 <= z_2 <= ... <= z_n
#
# and that problem has a COMPLETE characterisation, not merely a reference
# implementation. A vector z is the minimiser if and only if:
#
#   (F1) z is non-decreasing                       (feasible)
#   (F2) z is constant on each maximal block, and
#        that constant is the weighted mean of y over the block
#   (F3) at every block boundary j, the cumulative weighted residual
#              S_j = sum_{i<=j} w_i (y_i - z_i)   is  >= 0
#
# (F3) is the KKT condition on the order constraints. Without it a block-equal
# feasible point need not be the MINIMUM -- it could be a local plateau -- so
# it is the half that distinguishes "the answer" from "a plausible answer".
# (F1)+(F2)+(F3) together are necessary AND sufficient for the unique optimum.
#
# On top of that, the OPTIMUM is computed independently by brute force over
# every partition of the index set (2^(n-1) of them, and n <= 7 here), so the
# check does not rest on my reading of the KKT conditions alone.
#
# THE CONTROL ARM: sklearn's own output must pass the same oracle. If the
# oracle rejected sklearn it would be the oracle that is wrong, not sklearn --
# so a disagreement is reported as "the oracle is broken", and the run fails
# loudly instead of blaming the port for a bug in the checker.

def _wmean(y, w, i, j):
    """Weighted mean of y[i:j+1]."""
    num = sum(w[k] * y[k] for k in range(i, j + 1))
    den = sum(w[k] for k in range(i, j + 1))
    return num / den


def brute_force_optimum(y, w):
    """The exact optimum, by enumerating EVERY FEASIBLE partition.

    Deliberately exhaustive rather than a DP recurrence: at n <= 7 this is
    64 partitions, and an exhaustive search has no off-by-one indexing to get
    wrong. A DP would be faster and would need its own test.

    FEASIBLE is the part that is easy to get wrong. Every partition of the
    index set gives a block-mean vector and an objective, but a partition
    whose block means DECREASE is not a point in the feasible set -- the order
    constraint is violated. Minimising over all partitions without filtering
    returns the all-singleton partition, whose block means are exactly `y` and
    whose objective is exactly 0, for every input. The first version of this
    function did that, and reported the optimum as 0.000 against sklearn's
    0.3875 on v0.

    That is not a hypothetical: it is what happened, and the control arm --
    sklearn's own output through this same oracle -- is what caught it, in one
    run, before it could be blamed on the port.

    Returns (objective, block_means, blocks).
    """
    n = len(y)
    if n > 16:
        raise ValueError("brute force is only for small n; got %d" % n)
    best = None
    considered = 0
    for cuts in itertools.product([0, 1], repeat=max(n - 1, 0)):
        blocks, start = [], 0
        for k, c in enumerate(cuts, start=1):
            if c:
                blocks.append((start, k - 1))
                start = k
        blocks.append((start, n - 1))
        means = [_wmean(y, w, i, j) for (i, j) in blocks]
        # The order constraint: block means must be non-decreasing. Without
        # this filter the all-singleton partition wins at objective 0.
        if any(means[t + 1] < means[t] - 1e-12 for t in range(len(means) - 1)):
            continue
        considered += 1
        z = np.empty(n)
        for (i, j), m in zip(blocks, means):
            z[i:j + 1] = m
        obj = float(sum(w[k] * (y[k] - z[k]) ** 2 for k in range(n)))
        if best is None or obj < best[0]:
            best = (obj, z.copy(), list(blocks))
    if best is None:
        raise ValueError("no feasible partition exists, which cannot happen")
    return best[0], best[1], best[2], considered


def objective(y, z, w):
    return float(sum(w[k] * (y[k] - z[k]) ** 2 for k in range(len(y))))


def kkt_violations(y, z, w):
    """Every block boundary where the cumulative weighted residual goes < 0."""
    bad = []
    run = 0.0
    for k in range(len(y)):
        run += w[k] * (y[k] - z[k])
        # `k` is a boundary exactly when the fit changes at k+1.
        if k + 1 < len(y) and abs(z[k + 1] - z[k]) > 1e-12:
            if run < -1e-9:
                bad.append((k, run))
    return bad


def check_optimum(label, y, w, z):
    """-> (list of failure strings, list of evidence strings)."""
    fails, notes = [], []
    n = len(y)

    # (F1) feasible
    if np.any(np.diff(z) < -1e-12):
        fails.append("%s: fitted vector is not non-decreasing" % label)

    # (F3) KKT, evaluated on THIS vector with no reference to any other
    # implementation. This is the half a block-mean check alone would miss.
    bad = kkt_violations(y, z, w)
    if bad:
        fails.append("%s: KKT violated at boundary %s (S_j = %s)"
                     % (label, [b[0] for b in bad],
                        ["%.3e" % b[1] for b in bad]))
    else:
        notes.append("%s: KKT sign conditions hold at every boundary" % label)

    # (F2)+(optimum) exact brute-force comparison
    opt_obj, opt_z, blocks, considered = brute_force_optimum(y, w)
    got_obj = objective(y, z, w)
    if got_obj > opt_obj + 1e-9:
        fails.append("%s: objective %.12g exceeds the optimum %.12g by %.3e"
                     % (label, got_obj, opt_obj, got_obj - opt_obj))
    else:
        notes.append("%s: objective %.12g == brute-force optimum %.12g "
                     "(%d of 2^%d partition(s) feasible)"
                     % (label, got_obj, opt_obj, considered, n - 1))
    worst = float(np.max(np.abs(np.asarray(z) - opt_z)))
    if worst > 1e-9:
        fails.append("%s: fitted vector differs from the optimal one by %.3e"
                     % (label, worst))
    return fails, notes


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
    print("     + an analytic optimality oracle (KKT + brute-force partitions)")
    print("=" * 70)

    # ------------------------------------------------------------------ #
    # The oracle's OWN negative controls, before anything is measured.
    # ------------------------------------------------------------------ #
    # This file's stated reason for existing is that a validator whose verdict
    # cannot change is decoration. An oracle that only ever sees correct input
    # is exactly that, so it is handed three deliberately WRONG vectors first
    # and must reject all three. A cheap positive control is not enough: the
    # interesting question is whether each individual condition can fail.
    print()
    print("--- oracle self-test: it must REJECT three wrong answers ---")
    yv = np.array([3.0, 2.0, 1.0, 5.0, 4.0, 6.0])
    wv = np.ones(6)
    _opt_obj, _opt_z, _blocks, _c = brute_force_optimum(yv, wv)
    bad_cases = [
        ("not monotone (F1)", np.array([0.0, 5.0, 1.0, 2.0, 3.0, 4.0])),
        ("feasible + block-equal, but not the MINIMUM (F3)",
         np.full(6, 3.0)),
        ("the optimum with one element nudged off it (F2)",
         np.array([_opt_z[0] + 0.5] + list(_opt_z[1:]))),
    ]
    oracle_sane = True
    for why, zbad in bad_cases:
        f, _n = check_optimum("selftest", yv, wv, zbad)
        if f:
            print("  rejects %-48s -> PASS" % why)
        else:
            print("  ACCEPTS %-48s -> THE ORACLE IS BLIND TO IT" % why)
            oracle_sane = False
    # And one positive control, so a blanket "always fail" oracle is caught too.
    f, _n = check_optimum("selftest", yv, wv, _opt_z)
    if f:
        print("  rejects the TRUE optimum -> THE ORACLE ALWAYS FAILS")
        oracle_sane = False
    else:
        print("  accepts the true optimum                            -> PASS")
    if not oracle_sane:
        print("")
        print("PAVA cross-check FAIL")
        sys.exit(1)

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

    # ------------------------------------------------------------------ #
    # The analytic oracle.
    # ------------------------------------------------------------------ #
    # Run against BOTH sides, and the sklearn arm runs FIRST and is reported
    # separately. If the oracle rejected sklearn, the oracle is what is
    # broken -- so that outcome is named as such instead of showing up as
    # "the port disagrees with the reference", which is the accusation this
    # whole file exists to avoid making falsely.
    print()
    print("--- analytic oracle: is this THE minimiser, not just A fit? ---")
    oracle_fails, oracle_notes = [], []

    print("control arm -- sklearn's own output through the same oracle:")
    ctrl_fails = []
    for label, y, w in CASES:
        ww = np.ones(len(y)) if w is None else np.asarray(w, dtype=float)
        f, _ = check_optimum("sklearn/%s" % label,
                             np.asarray(y, dtype=float), ww, expected[label])
        ctrl_fails += f
    if ctrl_fails:
        print("  the ORACLE IS BROKEN -- sklearn's own output fails it:")
        for f in ctrl_fails:
            print("    %s" % f)
        print("")
        print("PAVA cross-check FAIL")
        sys.exit(1)
    print("  sklearn passes the oracle on all %d case(s) -> oracle is sane"
          % len(CASES))

    print()
    for label, y, w in CASES:
        ww = np.ones(len(y)) if w is None else np.asarray(w, dtype=float)
        f, notes = check_optimum("moonbit/%s" % label,
                                 np.asarray(y, dtype=float), ww,
                                 np.asarray(got[label], dtype=float))
        oracle_fails += f
        oracle_notes += notes
        print("  case[%s] %s" % (label, "PASS" if not f else "FAIL"))
        for note in notes:
            print("      %s" % note)
        for bad in f:
            print("      %s" % bad)

    print()
    print("  analytic optimality -> %s"
          % ("PASS" if not oracle_fails else "FAIL"))
    ok_all = ok_all and monotone and not oracle_fails
    print("")
    print("PAVA cross-check " + ("PASS" if ok_all else "FAIL"))
    if not ok_all:
        sys.exit(1)


if __name__ == "__main__":
    main()
