"""Is the upstream False arm reproducible when the seed is set at the TOP?

The previous pass put `np.random.seed(s)` immediately before `est.fit()`. Under
that, the True arm reproduced exactly (max |t1-t2| = 0) and the False arm did
not (max |f1-f2| = 0.185). No `default_rng`/`Generator` appears anywhere in the
installed doubleml, so the unseeded draw is most likely happening at
CONSTRUCTION or at DGP-build time -- earlier than the point I was seeding.

This isolates WHERE the seed has to go, one hypothesis at a time, on a single
seed rather than the whole grid, so the answer is unambiguous.

H1  seed before fit only        (what pass 2 did)
H2  seed before construction and fit
H3  seed at the very top, before make_did_SZ2020 as well

For each: run twice, report max |diff|.
"""
import warnings
warnings.filterwarnings("ignore")
import numpy as np
from doubleml.did import DoubleMLDIDCS
from doubleml.did.datasets.dgp_did_SZ2020 import make_did_SZ2020
from sklearn.linear_model import LinearRegression, LogisticRegression

S = 11


def build():
    return make_did_SZ2020(n_obs=1600, cross_sectional_data=True,
                           return_type="DoubleMLDIDData", theta=1.0, seed=S)


def coef_of(dml_data, isn):
    est = DoubleMLDIDCS(dml_data, ml_g=LinearRegression(),
                        ml_m=LogisticRegression(),
                        n_folds=2, n_rep=1, in_sample_normalization=isn)
    est.fit()
    return float(np.asarray(est.coef).ravel()[0])


def h1(isn):
    d = build()
    np.random.seed(S)
    return coef_of(d, isn)


def h2(isn):
    np.random.seed(S)
    d = build()
    return coef_of(d, isn)


def h3(isn):
    np.random.seed(S)
    d = build()
    return coef_of(d, isn)


for name, fn in [("H1 seed-before-fit-only", h1),
                 ("H2 seed-before-construction", h2),
                 ("H3 seed-at-top", h3)]:
    for isn in (False, True):
        a = fn(isn)
        b = fn(isn)
        d = abs(a - b)
        print("%-30s isn=%-5s coef=%.15g  coef2=%.15g  max|diff|=%.15g  %s"
              % (name, str(isn), a, b, d, "REPRODUCIBLE" if d == 0.0 else "NOT reproducible"))
    print()