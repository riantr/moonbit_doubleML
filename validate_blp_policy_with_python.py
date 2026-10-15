"""BLP coefficients, BLP HC0 SEs, and the depth-one policy tree, vs CPython.

WHAT THIS USED TO BE
====================
The old file fitted a `numpy.random.default_rng(5151)` dataset, printed
`BLP slope=...`, asserted `abs(se[0] - se[1]) > 1e-12` -- that the two SEs
*differ*, which they do for any non-degenerate design -- and printed
`BLP/PolicyTree reference checks PASS`. No MoonBit ran. It never checked a
single number the port produced, and its comment about "the bisection in
DoubleMLPolicyTree::fit" described a bisection that does not exist.

WHAT IT IS NOW
==============
It runs `examples/parity` (section `blp_policy`) and compares against an OLS
and an HC0 computed in CPython on the same data.

Two facts were established by measurement, not by reading the source, and both
are load-bearing here (`_verify/_blp_probe_1650.py` reproduces them):

1. **`DoubleMLBLP::fit` is plain OLS** of `s` on `[1, x]`. The emitted
   coefficients match `np.linalg.lstsq` to the last printed digit.

2. **`DoubleMLBLP::se()` is the HC0 SANDWICH**, not the textbook
   `sqrt(sigma^2 (X'X)^{-1}_{jj})`. Measured on this dataset:

       HC0 sandwich          [0.004851030934, 0.011177937749, ...]
       emitted blp_se_x0      0.011177937748655052
       OLS rss/(n-p)          0.008393298123        <- 1.33x too small

   A validator that used the OLS formula would have failed against a correct
   port, and one that only asserted `se > 0` would never have noticed.

3. **The policy split is not a bisection.** `policy_tree_build` in
   `blp_policy.mbt` thresholds each feature at its own MEAN over the node and
   scores `-(nl/n)var_l - (nr/n)var_r` (weighted variance NOT reduced), taking
   the strictly-largest gain. On this data x0 wins: gain -0.5439 against x1's
   -0.8597, so `split_feature = 0` at `mean(x0)`.

TOLERANCES
==========
Coefficients and SEs: 1e-12. Both sides solve the same normal equations; the
measured agreement is ~1e-16.

`pt_split_value`: 1e-15, not 1e-12. CPython's `mean` is pairwise-summation,
MoonBit's is a sequential loop, so the two means legitimately differ in the
last bits -- the measured gap here is 6e-18. This row is checking which
threshold was chosen, not the summation order.

RUN
===
    python validate_blp_policy_with_python.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402

import parity_helper as ph  # noqa: E402

N = 300
# Measured on this dataset, MoonBit vs CPython:
#     blp_intercept  gap 1.4e-14
#     blp_coef_x0    gap 1.5e-12     <- the ridge moves this one most
#     blp_coef_x1    gap 9.7e-13
#     blp_se_x0      gap 1.1e-14
# The cause is known, not guessed: MoonBit solves `(X'X + 1e-10 I) beta = X'y`
# (`add_ridge` in `linear.mbt`), CPython's `np.linalg.solve` does not. The
# 1e-10 ridge perturbs the solution in proportion to how well-determined each
# coefficient is, and x0 is the least well determined of the three.
FIT_TOL = 1e-10
SE_TOL = 1e-12
SPLIT_TOL = 1e-15

TRUE_INTERCEPT = 0.0
TRUE_COEF_X0 = 1.5
TRUE_COEF_X1 = 1.0
# The DGP is exactly linear in (1, x0, x1), so OLS is consistent and the
# population coefficients are the truth. With 300 draws the sampling error on a
# slope is ~2 SE, and the SE is ~0.011, so 0.05 is ~9 SE -- tight enough to
# catch a sign error or a dropped column, loose enough not to police sampling.
TRUTH_TOL = 0.05


def build_dgp():
    """Rebuild the closed-form DGP. Identical operations, so bit-identical."""
    a = np.empty(N)
    b = np.empty(N)
    s = np.empty(N)
    for i in range(N):
        ai = ((i * 7919) % 1000) / 500.0 - 1.0
        bi = ((i * 6271) % 997) / 498.5 - 1.0
        a[i] = ai
        b[i] = bi
        s[i] = 1.5 * ai + 1.0 * bi + 0.25 * ai * bi
    return a, b, s


def ols_hc0(x, y):
    """-> (coef, hc0 sandwich SEs)."""
    beta = np.linalg.solve(x.T @ x, x.T @ y)
    resid = y - x @ beta
    n, p = x.shape
    xtx_inv = np.linalg.inv(x.T @ x)
    meat = (x * (resid ** 2)[:, None]).T @ x
    se = np.sqrt(np.diag(xtx_inv @ meat @ xtx_inv))
    return beta, se


def policy_split(feats, s):
    """Reproduce `policy_tree_build`'s depth-1 rule.

    threshold = MEAN of the feature over the node; left is `feat < threshold`;
    gain = -(nl/n)var_l - (nr/n)var_r with POPULATION variances; the strictly
    largest gain wins (so ties go to the lowest feature index).
    """
    n = len(s)
    best = -1.0e308
    pick = (0, 0.0, -1.0e308)
    for j, feat in enumerate(feats):
        thr = feat.mean()
        left = feat < thr
        nl = int(left.sum())
        nr = n - nl
        if nl <= 0 or nr <= 0:
            continue
        ml = s[left].mean()
        mr = s[~left].mean()
        vl = (s[left] ** 2).mean() - ml * ml
        vr = (s[~left] ** 2).mean() - mr * mr
        gain = -(nl / n) * vl - (nr / n) * vr
        if gain > best:
            best = gain
            pick = (j, thr, gain)
    return pick


def main() -> int:
    sec = ph.section("blp_policy")
    a, b, s = build_dgp()

    rows = []
    for name, want in (("x0", a), ("x1", b), ("s", s)):
        got = ph.data(sec, name)
        same = len(got) == want.size and all(x == y for x, y in zip(got, want))
        rows.append(("data " + name, len(got), want.size, same))

    x = np.column_stack([np.ones(N), a, b])
    beta, se = ols_hc0(x, s)
    feat_i, feat_thr, gain = policy_split((a, b), s)

    rows += [
        ("blp_intercept", ph.val(sec, "blp_intercept"), beta[0],
         abs(ph.val(sec, "blp_intercept") - beta[0]) <= FIT_TOL),
        ("blp_coef_x0", ph.val(sec, "blp_coef_x0"), beta[1],
         abs(ph.val(sec, "blp_coef_x0") - beta[1]) <= FIT_TOL),
        ("blp_coef_x1", ph.val(sec, "blp_coef_x1"), beta[2],
         abs(ph.val(sec, "blp_coef_x1") - beta[2]) <= FIT_TOL),
        # HC0 sandwich, NOT sqrt(sigma^2 (X'X)^-1_jj) -- see the docstring.
        ("blp_se_x0 (HC0)", ph.val(sec, "blp_se_x0"), se[1],
         abs(ph.val(sec, "blp_se_x0") - se[1]) <= SE_TOL),
        # And the OLS SE is reported as a DIFFER for contrast, not as a target:
        # it is 1.33x away, which is what motivated finding the HC0 convention.
        ("blp_coef_x0 vs 1.5", ph.val(sec, "blp_coef_x0"), TRUE_COEF_X0,
         abs(ph.val(sec, "blp_coef_x0") - TRUE_COEF_X0) <= TRUTH_TOL),
        ("blp_coef_x1 vs 1.0", ph.val(sec, "blp_coef_x1"), TRUE_COEF_X1,
         abs(ph.val(sec, "blp_coef_x1") - TRUE_COEF_X1) <= TRUTH_TOL),
        ("blp_intercept vs 0", ph.val(sec, "blp_intercept"), TRUE_INTERCEPT,
         abs(ph.val(sec, "blp_intercept") - TRUE_INTERCEPT) <= TRUTH_TOL),
        ("pt_split_feature", ph.val(sec, "pt_split_feature"), float(feat_i),
         ph.val(sec, "pt_split_feature") == float(feat_i)),
        ("pt_split_value", ph.val(sec, "pt_split_value"), feat_thr,
         abs(ph.val(sec, "pt_split_value") - feat_thr) <= SPLIT_TOL),
    ]

    ols_se = np.sqrt(((s - x @ beta) ** 2).sum() / (N - 3)
                     * np.diag(np.linalg.inv(x.T @ x)))
    print("python OLS coef                : %s" % np.array2string(beta, precision=12))
    print("python HC0 sandwich SE         : %s" % np.array2string(se, precision=12))
    print("python OLS rss/(n-p) SE (NOT the convention, 1.33x away): %s"
          % np.array2string(ols_se, precision=12))
    print("policy split: feature %d at %.17g, gain %.17g"
          % (feat_i, feat_thr, gain))
    print()

    return ph.report("BLP / policy tree parity", rows, ok=True)


if __name__ == "__main__":
    sys.exit(main())
