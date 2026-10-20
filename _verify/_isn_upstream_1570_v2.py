"""ROW M oracle arm, SECOND PASS -- deterministic.

WHY THIS RE-RUN EXISTS
----------------------
The first pass (`_isn_upstream_1570.py`) produced numbers that did NOT survive
being re-run and written to disk. First pass vs artifact:

    quantity                      first pass (terminal)      artifact (.txt)
    max dcoef_over_se_false       3.17079585643772           2.87440314141338
    mean_se_false / mean_se_true  0.998401573532664          0.97564392679077
    sd_false / sd_true            0.602473589986838          1.11495555398457

The sd ratio swung from 0.60 to 1.11 -- i.e. the sign of the headline claim
("upstream's True is the lower-variance arm") was NOISE.

CAUSE: the estimator is stochastic and nothing in the first pass seeded it.
`make_did_SZ2020(seed=s)` seeds the DATA, but `DoubleMLDIDCS` draws its own
cross-fitting split (`draw_sample_splitting=True` by default) from an unseeded
stream. This is the same class of bug as the LPLR split draw recorded in
project memory: seeding the data is not seeding the estimator.

FIX: `np.random.seed(s)` must be set BEFORE `DoubleMLDIDCS(...)` is CONSTRUCTED,
not before `fit()`. Established by `_isn_determinism_1570.py`, which isolated
three placements:

    H1 seed before fit only            NOT reproducible (max|diff| 0.214 / 0.270)
    H2 seed before construction        REPRODUCIBLE    (max|diff| = 0)
    H3 seed at the very top            REPRODUCIBLE    (max|diff| = 0)

Pass 2 of this script used H1, which is why its False arm drifted; the True arm
agreeing across passes there was coincidence, not determinism.

Then run the WHOLE grid twice and print both, so determinism is demonstrated
rather than assumed -- a number from an instrument whose reproducibility was
never checked is not a result.

Also: the first pass ran `run(False)` / `run(True)` twice (once for the per-arm
tables, once for the contrast), so the contrast was computed from a DIFFERENT
pair of fits than the table above it. Here each arm is fitted exactly once and
reused for both the table and the contrast.
"""
import warnings
warnings.filterwarnings("ignore")
import inspect
import numpy as np

import doubleml
from doubleml.did import DoubleMLDIDCS
from doubleml.did.datasets.dgp_did_SZ2020 import make_did_SZ2020
from sklearn.linear_model import LinearRegression, LogisticRegression

print("doubleml", doubleml.__version__)
print("DIDCS default in_sample_normalization =",
      inspect.signature(DoubleMLDIDCS.__init__).parameters["in_sample_normalization"].default)

THETA = 1.0
SEEDS = [11, 22, 33, 44, 55, 66, 77, 88, 99, 110, 121, 132]


def run(isn, n_obs=1600):
    """Fit each seed ONCE. np.random.seed(s) goes BEFORE construction (H2)."""
    coefs, ses = [], []
    for s in SEEDS:
        np.random.seed(s)          # <- must precede construction, not fit
        dml_data = make_did_SZ2020(
            n_obs=n_obs, cross_sectional_data=True,
            return_type="DoubleMLDIDData", theta=THETA, seed=s,
        )
        est = DoubleMLDIDCS(dml_data, ml_g=LinearRegression(),
                            ml_m=LogisticRegression(),
                            n_folds=2, n_rep=1,
                            in_sample_normalization=isn)
        est.fit()
        coefs.append(float(np.asarray(est.coef).ravel()[0]))
        ses.append(float(np.asarray(est.se).ravel()[0]))
    return np.array(coefs), np.array(ses)


def report(cf, sf, ct, st, tag):
    print("\n--- %s ---" % tag)
    for s, a, b, c, d in zip(SEEDS, cf, sf, ct, st):
        print("seed=%-4d coef_f=%-21.15g coef_t=%-21.15g se_f=%.15g se_t=%.15g"
              % (s, a, c, b, d))
    print("false: mean=%-21.15g sd=%-21.15g mean_se=%-21.15g" % (cf.mean(), cf.std(ddof=1), sf.mean()))
    print("true : mean=%-21.15g sd=%-21.15g mean_se=%-21.15g" % (ct.mean(), ct.std(ddof=1), st.mean()))
    print("ARM CONTRAST")
    print("  max |dcoef|                = %.15g" % np.abs(cf - ct).max())
    print("  mean |dcoef|               = %.15g" % np.abs(cf - ct).mean())
    print("  mean_se_false / mean_se_true = %.15g" % (sf.mean() / st.mean()))
    print("  max dcoef_over_se_false    = %.15g" % (np.abs(cf - ct) / sf).max())
    print("  sd_false / sd_true         = %.15g" % (cf.std(ddof=1) / ct.std(ddof=1)))
    print("  bitwise identical coefs?   = %s" % bool(np.array_equal(cf, ct)))


print("\nEXAMINED=%d EXPECTED=%d  true_theta=%g" % (len(SEEDS), len(SEEDS), THETA))

# Pass 1
f1, s1 = run(False)
t1, u1 = run(True)
report(f1, s1, t1, u1, "PASS 1 (deterministic)")

# Pass 2 -- identical inputs, to PROVE the instrument is now reproducible.
f2, s2 = run(False)
t2, u2 = run(True)

print("\n=== DETERMINISM CHECK (pass 1 vs pass 2, same seeds) ===")
print("false coefs bit-identical = %s" % bool(np.array_equal(f1, f2)))
print("true  coefs bit-identical = %s" % bool(np.array_equal(t1, t2)))
print("false ses  bit-identical = %s" % bool(np.array_equal(s1, s2)))
print("true  ses  bit-identical = %s" % bool(np.array_equal(u1, u2)))
print("max |f1-f2| = %.15g" % np.abs(f1 - f2).max())
print("max |t1-t2| = %.15g" % np.abs(t1 - t2).max())