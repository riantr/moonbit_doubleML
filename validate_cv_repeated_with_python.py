"""Repeated cross-validation, checked against an independent OLS in CPython.

WHAT THIS USED TO BE
====================
The old file was a prose explanation of why averaging over repeats should
reduce variance, ending in `print("Variance reduction principle: PASS")`. It
computed four numbers with sklearn's `KFold`, printed them, and never ran
MoonBit. It described a principle rather than testing the port.

WHAT IT IS NOW
==============
It runs `examples/parity` (section `cv_repeated`) and compares against an OLS
of `y` on `[1, d, c0, c1]` computed in CPython. There is no unobserved
confounding in this DGP, so that OLS `d` coefficient estimates the same causal
effect the IRM is estimating, by a different route. It is a real second
opinion, not a restatement.

WHY THE COVARIATES ARE NOT ZEROS
================================
An earlier revision passed a 300x2 matrix of zeros, which is rank-deficient.
The estimate was then whatever the ridge produced and no CPython reference
could be built against it. The covariates are now real deterministic columns,
and the noise is a closed form, so CPython rebuilds the dataset rather than
trusting the copy it was handed.

A CLAIM THIS FILE DELIBERATELY DOES NOT MAKE
============================================
"Trying more repeats should not increase the standard error" was the old
file's thesis. On this DGP it is FALSE: measured, `n_rep1_se` is
0.007128227045985734 and `n_rep8_se` is 0.007413328826514422. Averaging over
repeats averages the SE estimate too, and here that raises it slightly.

Asserting a direction the numbers do not support would be asserting a hope.
So this file asserts only what is measured: both estimates recover the truth,
both SEs are positive, and both agree with the independent OLS. The
n_rep = 1 vs n_rep = 8 comparison is reported, not gated on.

RUN
===
    python validate_cv_repeated_with_python.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import parity_helper as ph  # noqa: E402

import numpy as np  # noqa: E402

N = 300
TRUE_ATT = 2.0

# Measured gaps on this dataset (MoonBit vs the CPython OLS reference):
#     n_rep1_coef  vs OLS  0.0017
#     n_rep8_coef  vs OLS  0.0009
# Both sit within 0.001 of the true 2.0. The tolerance is 0.02 -- an order of
# magnitude over the measured deviation, and still 100x tighter than the old
# file's effective "close enough to 2.0".
COEF_TOL = 0.02


def build_dgp():
    """Rebuild the closed-form DGP. Identical operations, so bit-identical."""
    c0 = np.empty(N)
    c1 = np.empty(N)
    d = np.empty(N)
    y = np.empty(N)
    for i in range(N):
        c0[i] = ((i * 7919) % 1000) / 500.0 - 1.0
        c1[i] = ((i * 6271) % 997) / 498.5 - 1.0
        noise = ((i * 37) % 101) / 101.0 - 0.5
        d[i] = 1.0 if i % 3 == 0 else 0.0
        y[i] = d[i] * 2.0 + 0.8 * c0[i] - 0.5 * c1[i] + 0.2 * noise
    return c0, c1, d, y


def main() -> int:
    sec = ph.section("cv_repeated")
    c0, c1, d, y = build_dgp()

    rows = []
    for name, want in (("cv_c0", c0), ("cv_c1", c1), ("cv_y", y), ("cv_d", d)):
        got = ph.data(sec, name)
        same = len(got) == want.size and all(a == b for a, b in zip(got, want))
        rows.append(("data " + name, len(got), want.size, same))

    # Independent reference: OLS of y on [1, d, c0, c1]. The `d` coefficient is
    # an estimate of the same causal effect, by a different route.
    x = np.column_stack([np.ones(N), d, c0, c1])
    beta = np.linalg.solve(x.T @ x, x.T @ y)
    ols_att = float(beta[1])

    rep1 = ph.val(sec, "n_rep1_coef")
    rep8 = ph.val(sec, "n_rep8_coef")
    se1 = ph.val(sec, "n_rep1_se")
    se8 = ph.val(sec, "n_rep8_se")

    rows += [
        ("n_rep1_coef vs OLS", rep1, ols_att, abs(rep1 - ols_att) <= COEF_TOL),
        ("n_rep8_coef vs OLS", rep8, ols_att, abs(rep8 - ols_att) <= COEF_TOL),
        ("n_rep1_coef vs 2.0", rep1, TRUE_ATT, abs(rep1 - TRUE_ATT) <= COEF_TOL),
        ("n_rep8_coef vs 2.0", rep8, TRUE_ATT, abs(rep8 - TRUE_ATT) <= COEF_TOL),
        ("n_rep1_se > 0", se1, "> 0", se1 > 0.0),
        ("n_rep8_se > 0", se8, "> 0", se8 > 0.0),
    ]

    print("python OLS reference (y ~ 1 + d + c0 + c1):")
    print("  intercept %.10g   d %.10g   c0 %.10g   c1 %.10g" % tuple(beta))
    print("true ATT = %.2f" % TRUE_ATT)
    print()
    print("repeats change the estimate, and by how much:")
    print("  n_rep=1  coef %.15g  se %.15g  |coef - 2| = %.3g"
          % (rep1, se1, abs(rep1 - TRUE_ATT)))
    print("  n_rep=8  coef %.15g  se %.15g  |coef - 2| = %.3g"
          % (rep8, se8, abs(rep8 - TRUE_ATT)))
    print("  se(n_rep=8) - se(n_rep=1) = %+.6g"
          % (se8 - se1))
    print("  ^ POSITIVE here. The old validator's premise -- that averaging over")
    print("    repeats cannot increase the SE -- does not hold on this DGP, so it")
    print("    is reported rather than asserted. See the module docstring.")
    print()

    return ph.report("repeated cross-validation parity", rows, ok=True)


if __name__ == "__main__":
    sys.exit(main())
