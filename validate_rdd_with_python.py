"""Sharp and fuzzy RD, checked against an independent local-linear WLS in CPython.

WHAT THIS USED TO BE
====================
The old file contained, in full:

    print("sharp local-linear intercept jump = 2.000000")
    assert abs(2.0 - 2) < 1e-12
    assert abs(.6 - .6) < 1e-12
    print("RDD reference checks PASS")

`abs(2.0 - 2)` is `abs(0.0)`. Both asserts compare a literal to itself, so they
cannot fail, nothing ran MoonBit, and CI grepped the `PASS`. It also called the
fuzzy estimate a "Wald ratio" of 0.6 while the port returned the raw outcome
jump of 0.12 -- the file described an estimator it never observed.

WHAT IT IS NOW
==============
It runs `examples/parity` (section `rdd`) and rebuilds the local-polynomial
estimator from its definition in `rdd.mbt`, in plain Python:

    rows       : |u| <= h, and u < 0 (left) or u >= 0 (right)
    design     : [1, u, z]          -- intercept added by fit_weighted
    weight     : 1 - |u|/h          -- Triangular, the default kernel
    solve      : (X'WX + 1e-10 I) b = X'W y, by Cholesky
    sharp      : c = b_right[0] - b_left[0]
    fuzzy      : c = (jump_y) / (jump_d)

Two independent things are then compared:

1. **The data**, bit-for-bit. The DGP is closed-form, so CPython regenerates
   `u`, `z`, `d`, `y` itself. MoonBit's `Double::to_string` is
   shortest-round-trip (same as Python `repr`), so string equality here is
   IEEE-754 bit equality, not a 1e-9 approximation.

2. **The estimates**, to a measured numerical tolerance.

ON THE TOLERANCE
================
The point estimates are exact in exact arithmetic -- the DGP is linear in
(1, u, z) on each side, so WLS recovers the coefficients with zero bias. What
is left is float accumulation over a 300-row weighted solve. Both sides compute
the same mathematical object by different operation orders, so they differ at
the level of the accumulated rounding, not at the level of the answer.

CPython solves the same normal equations TWICE -- its own Cholesky and
`numpy.linalg.solve` -- and the script fails unless those two agree. Without
that, a CPython bug and a MoonBit bug are indistinguishable in the output.

RUN
===
    python validate_rdd_with_python.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402

import parity_helper as ph  # noqa: E402

N = 600
BANDWIDTH = 0.5
CUTOFF = 0.0
RIDGE = 1.0e-10

TRUE_SHARP_JUMP = 2.0     # 1[u >= 0] with coefficient 2
TRUE_FUZZY_RATIO = 0.6    # outcome jump 0.12 / treatment jump 0.20

# Measured, not guessed. On this DGP MoonBit and CPython agree to:
#     sharp_coef  2.0000000000241958 vs 2.0000000000242006   gap 4.8e-15
#     fuzzy_coef  0.6000000001610712 vs 0.6000000001610685   gap 2.7e-15
# Both sides also sit 2.4e-11 away from the true 2.0, and they sit there
# TOGETHER -- that offset is the `1e-10` ridge shrinking the intercept, not
# disagreement between the implementations. 1e-9 leaves ~6 orders of headroom
# over the measured gap while still being far tighter than the 2.4e-11 bias
# it is not meant to police.
COEF_TOL = 1e-9
SELF_CONSISTENCY_TOL = 1e-9


def build_dgp():
    """Rebuild the closed-form DGP. Identical operations, so bit-identical."""
    u = np.empty(N)
    z = np.empty(N)
    ds = np.empty(N)
    ys = np.empty(N)
    df = np.empty(N)
    yf = np.empty(N)
    for i in range(N):
        uu = (i + 0.5) / 300.0 - 1.0
        zz = (i % 17) / 8.0 - 1.0
        u[i] = uu
        z[i] = zz
        ds[i] = 1.0 if uu >= 0.0 else 0.0
        ys[i] = 2.0 + uu + 0.5 * zz + 2.0 * ds[i]
        df[i] = 0.7 if uu >= 0.0 else 0.5
        yf[i] = uu + 0.5 * zz + 0.6 * df[i]
    return u, z, ds, ys, df, yf


def cholesky_solve(a, b):
    """Lower-triangular Cholesky, mirroring `solve_normal_eqs` in linear.mbt."""
    n = a.shape[0]
    l = np.zeros((n, n))
    for i in range(n):
        for j in range(i + 1):
            s = a[i, j] - sum(l[i, k] * l[j, k] for k in range(j))
            if i == j:
                l[i, j] = np.sqrt(s)
            else:
                l[i, j] = s / l[j, j]
    y = np.zeros(n)
    for i in range(n):
        y[i] = (b[i] - sum(l[i, k] * y[k] for k in range(i))) / l[i, i]
    out = np.zeros(n)
    for i in range(n - 1, -1, -1):
        out[i] = (y[i] - sum(l[k, i] * out[k] for k in range(i + 1, n))) / l[i, i]
    return out


def jumps(u, z, y, h, cutoff, solver):
    """(right intercept - left intercept, rows kept on either side).

    The bandwidth restriction is part of the row filter, not a weight. Applying
    it as a weight alone lets `1 - |u|/h` go NEGATIVE for the observations
    beyond the bandwidth, which makes X'WX indefinite and the Cholesky pivot
    negative. `rdd_design` drops those rows before weighting; so must this.

    `n_kept` is the TOTAL on both sides, matching `n_local`'s documented
    meaning ("the count of outcome observations that fall inside the bandwidth
    on both sides of the cutoff").
    """
    near = np.abs(u - cutoff) <= h
    left = near & ((u - cutoff) < 0.0)
    right = near & ((u - cutoff) >= 0.0)
    out = []
    for mask in (left, right):
        uu = u[mask] - cutoff
        zz = z[mask]
        w = 1.0 - np.abs(uu) / h
        x = np.column_stack([np.ones(uu.size), uu, zz])
        xtwx = x.T @ (x * w[:, None])
        xtwy = x.T @ (w * y[mask])
        xtwx = xtwx + RIDGE * np.eye(3)
        out.append(solver(xtwx, xtwy))
    return out[1][0] - out[0][0], int(left.sum()) + int(right.sum())


def main() -> int:
    sec = ph.section("rdd")
    u, z, ds, ys, df, yf = build_dgp()

    # --- 1. the data, bit-for-bit ------------------------------------------ #
    data_rows = []
    for name, want in (("u", u), ("z", z), ("y_sharp", ys), ("d_sharp", ds),
                       ("y_fuzzy", yf), ("d_fuzzy", df)):
        got = ph.data(sec, name)
        same = len(got) == want.size and all(a == b for a, b in zip(got, want))
        data_rows.append(("data " + name, len(got), want.size, same))

    # --- 2. CPython solves it twice; if those two disagree, stop ------------ #
    np_solve = lambda a, b: np.linalg.solve(a, b)  # noqa: E731
    sharp_np, n_np = jumps(u, z, ys, BANDWIDTH, CUTOFF, np_solve)
    sharp_ch, n_ch = jumps(u, z, ys, BANDWIDTH, CUTOFF, cholesky_solve)
    yj_np, _ = jumps(u, z, yf, BANDWIDTH, CUTOFF, np_solve)
    yj_ch, _ = jumps(u, z, yf, BANDWIDTH, CUTOFF, cholesky_solve)
    dj_np, _ = jumps(u, z, df, BANDWIDTH, CUTOFF, np_solve)
    dj_ch, _ = jumps(u, z, df, BANDWIDTH, CUTOFF, cholesky_solve)
    ratio_np, ratio_ch = yj_np / dj_np, yj_ch / dj_ch

    for label, a, b in (("sharp jump", sharp_np, sharp_ch),
                        ("fuzzy outcome jump", yj_np, yj_ch),
                        ("fuzzy treatment jump", dj_np, dj_ch),
                        ("fuzzy ratio", ratio_np, ratio_ch)):
        gap = abs(a - b)
        # `not (gap <= tol)` rather than `gap > tol`: a NaN gap must FAIL this
        # guard. `nan > tol` is False, so the `>` form waves a NaN straight
        # through -- which is exactly what happened the first time this ran.
        if not gap <= SELF_CONSISTENCY_TOL:
            print("CPython's two solves disagree on %s: %.17g vs %.17g "
                  "(gap %.3g). Fix the Python side before reading anything "
                  "below." % (label, a, b, gap))
            return 1
        if not np.isfinite(a):
            print("CPython's solve produced a non-finite %s: %r" % (label, a))
            return 1
    print("CPython self-consistency: both solvers agree to %.3g on all four "
          "quantities" % SELF_CONSISTENCY_TOL)

    # --- 3. the estimates -------------------------------------------------- #
    mb_sharp = ph.val(sec, "sharp_coef")
    mb_fuzzy = ph.val(sec, "fuzzy_coef")
    mb_n_local = ph.val(sec, "n_local")
    mb_fuzzy_n = ph.val(sec, "fuzzy_n_local")

    rows = list(data_rows)
    rows += [
        ("sharp_coef", mb_sharp, sharp_ch, abs(mb_sharp - sharp_ch) <= COEF_TOL),
        ("sharp vs true 2.0", mb_sharp, TRUE_SHARP_JUMP,
         abs(mb_sharp - TRUE_SHARP_JUMP) <= COEF_TOL),
        ("fuzzy_coef", mb_fuzzy, ratio_ch, abs(mb_fuzzy - ratio_ch) <= COEF_TOL),
        ("fuzzy vs true 0.6", mb_fuzzy, TRUE_FUZZY_RATIO,
         abs(mb_fuzzy - TRUE_FUZZY_RATIO) <= COEF_TOL),
        ("n_local", mb_n_local, float(n_ch), mb_n_local == n_ch),
        ("fuzzy_n_local", mb_fuzzy_n, float(n_ch), mb_fuzzy_n == n_ch),
    ]

    print("python sharp jump=%.17g  fuzzy ratio=%.17g  rows in bandwidth=%d"
          % (sharp_ch, ratio_ch, n_ch))
    print("coefficient tolerance %g; measured gaps: sharp %.3g, fuzzy %.3g"
          % (COEF_TOL, abs(sharp_np - sharp_ch), abs(ratio_np - ratio_ch)))
    print()

    rc = ph.report("sharp / fuzzy RD parity", rows, ok=True)
    ok = (rc == 0) and all(r[3] for r in data_rows)
    # SE has no external reference; a non-positive one means the influence
    # function collapsed.
    for label in ("sharp_se", "fuzzy_se"):
        s = ph.val(sec, label)
        print("  %-6s %-22s moonbit=%-24s %s"
              % ("MATCH " if s > 0.0 else "DIFFER", label, repr(s),
                 "(must be > 0)"))
        ok = ok and s > 0.0
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
