"""ROW M oracle arm: upstream doubleml 0.11.4, in_sample_normalization True vs False.

The port's claim (did.mbt:164-169) is that the two weightings are
"equivalent asymptotically but differ in finite samples".  The MoonBit arm
measured up to 0.97 SE of movement on DIDCS and a 3.3x SE ratio, which is not
what "finite-sample noise" usually means.  This runs BOTH arms on upstream's OWN
DGP, so the comparison is on upstream's ground rather than on a port fixture.

Uses make_did_SZ2020(cross_sectional_data=True), which returns a ready
DoubleMLDIDData and has a KNOWN true theta -- the port fixture used in the
MoonBit arm does not state its true ATT, which is one reason that arm could
report a mean but not a bias.

Version split, as recorded elsewhere in _verify: installed doubleml is 0.11.4,
vendored tree is 0.11.4.  This runs the installed 0.11.4.
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
G = LinearRegression()
M = LogisticRegression()

SEEDS = [11, 22, 33, 44, 55, 66, 77, 88, 99, 110, 121, 132]


def run(isn, n_obs=1600):
    coefs, ses = [], []
    for s in SEEDS:
        dml_data = make_did_SZ2020(
            n_obs=n_obs,
            cross_sectional_data=True,
            return_type="DoubleMLDIDData",
            theta=THETA,
            seed=s,
        )
        est = DoubleMLDIDCS(dml_data, ml_g=G, ml_m=M,
                            n_folds=2, n_rep=1,
                            in_sample_normalization=isn)
        est.fit()
        c = np.asarray(est.coef).ravel()
        se = np.asarray(est.se).ravel()
        # first treated-cell coefficient
        coefs.append(float(c[0]))
        ses.append(float(se[0]))
    return np.array(coefs), np.array(ses)


print("\nEXAMINED=%d EXPECTED=%d  true_theta=%g" % (len(SEEDS), len(SEEDS), THETA))

res = {}
for isn in (False, True):
    cf, sf = run(isn)
    res[isn] = (cf, sf)
    print("\n--- in_sample_normalization=%s ---" % isn)
    for s, a, b in zip(SEEDS, cf, sf):
        print("seed=%-4d coef=%-22.15g se=%.15g" % (s, a, b))
    print("mean coef       = %.15g" % cf.mean())
    print("bias  (mean-theta) = %.15g" % (cf.mean() - THETA))
    print("sd   coef       = %.15g" % cf.std(ddof=1))
    print("mean se         = %.15g" % sf.mean())
    print("rmse            = %.15g" % np.sqrt(((cf - THETA) ** 2).mean()))

cf_f, sf_f = res[False]
cf_t, sf_t = res[True]
print("\n=== ARM CONTRAST (same seeds, same propensities) ===")
print("max |dcoef|              = %.15g" % np.abs(cf_f - cf_t).max())
print("mean |dcoef|             = %.15g" % np.abs(cf_f - cf_t).mean())
print("mean_se_false / mean_se_true = %.15g" % (sf_f.mean() / sf_t.mean()))
print("max dcoef_over_se_false  = %.15g" % (np.abs(cf_f - cf_t) / sf_f).max())
print("sd_false / sd_true       = %.15g" % (cf_f.std(ddof=1) / cf_t.std(ddof=1)))
print("bitwise identical coefs? = %s" % bool(np.array_equal(cf_f, cf_t)))