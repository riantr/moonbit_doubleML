"""The SZ2020 comparison is currently vacuous: the coefficient is 0.063 while
the fold-noise sd is 0.0347, and PERMUTING the treatment moves it by 0.0007 --
i.e. the dataset's true effect is ~0 and the whole coefficient is noise.

A fixture like that passes whether the estimator is correct or returns zero.

So: sweep seeds and sample sizes, and pick a configuration where the signal
clears the noise. The statistic that matters is the effect size relative to
the fold-assignment spread, not the raw coefficient.
"""
import sys
import os
import warnings

warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import numpy as np
import pandas as pd
from sklearn.linear_model import LinearRegression, LogisticRegression
import doubleml as dml
from doubleml.did.datasets import make_did_SZ2020


def fit(df, seed):
    obj = dml.DoubleMLDIDData(df, "y", "d")
    np.random.seed(seed)
    m = dml.DoubleMLDID(obj, LinearRegression(), LogisticRegression(),
                        n_folds=2, n_rep=1)
    m.fit()
    return float(np.asarray(m.coef).ravel()[0])


print("n_obs  dgp_seed  coef(42)   fold_sd(10 seeds)   |coef|/sd")
for n_obs in (500, 2000):
    for dseed in (42, 7, 123, 2024):
        np.random.seed(dseed)
        df = make_did_SZ2020(n_obs=n_obs, return_type="DataFrame")
        base = fit(df, 42)
        vals = np.array([fit(df, 500 + k) for k in range(10)])
        sd = vals.std(ddof=1)
        print("%5d  %7d  %+9.5f  %-19.5f %.2f"
              % (n_obs, dseed, base, sd, abs(base) / sd if sd > 0 else float("inf")))
