"""The SZ2020 gate's two fold-noise constants, measured on the SHIPPED fixture.

`pyexample_did.py` gates on two bands:

    COEF_SD = 0.01128   # upstream coef, sd over 10 fold seeds at 2000/7
    SE_SD   = 0.000865  # upstream se,   sd over 10 fold seeds at 2000/7

The coefficient one is produced by `_verify/_seed_sweep_1660.py`, which sweeps
(n_obs, dgp_seed) and prints the fold sd beside each. The STANDARD ERROR one
had no script at all: `_verify/_se_ratio.py` (untracked scratch) hard-codes
0.000865 as the denominator of "in fold sd", and the gate's own comment calls
it "upstream se, sd over 10 fold seeds at 2000/7" without anyone being able to
re-derive it.

This script is that derivation. It is the same measurement as the seed sweep,
extended to the standard error, on the same fixture and the same ten fold
seeds, so both constants now come from ONE place:

    upstream DoubleMLDID, LinearRegression/LogisticRegression, n_folds=2,
    n_rep=1, on make_did_SZ2020(n_obs=2000, dgp_seed=7)

    fold seeds 500..509 (upstream draws its folds from the process-global
    RandomState, so the seed is re-issued immediately before each fit)

If this script's numbers stop matching the constants, the gate's band is
sized on a stale measurement and the band -- not the docstring -- is what
needs to change.
"""
import os
import sys
import warnings

warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import numpy as np
from sklearn.linear_model import LinearRegression, LogisticRegression
import doubleml as dml
from doubleml.did.datasets import make_did_SZ2020

N_OBS = 2000
DGP_SEED = 7
N_FOLDS, N_REP = 2, 1
N_SEEDS = 10
FOLD_SEEDS = [500 + k for k in range(N_SEEDS)]


def fit(df, seed):
    obj = dml.DoubleMLDIDData(df, "y", "d")
    np.random.seed(seed)
    m = dml.DoubleMLDID(obj, LinearRegression(), LogisticRegression(),
                        n_folds=N_FOLDS, n_rep=N_REP)
    m.fit()
    return (float(np.asarray(m.coef).ravel()[0]),
            float(np.asarray(m.se).ravel()[0]))


np.random.seed(DGP_SEED)
df = make_did_SZ2020(n_obs=N_OBS, return_type="DataFrame")

coefs, ses = [], []
for s in FOLD_SEEDS:
    c, se = fit(df, s)
    coefs.append(c)
    ses.append(se)
coefs = np.array(coefs)
ses = np.array(ses)

print("n_obs=%d dgp_seed=%d  fold seeds %d..%d" %
      (N_OBS, DGP_SEED, FOLD_SEEDS[0], FOLD_SEEDS[-1]))
for name, arr in (("coef", coefs), ("se", ses)):
    sd = arr.std(ddof=1)
    print("%-5s upstream over %d fold seeds: min %.6f max %.6f sd %.6f  3sd %.6f"
          % (name, N_SEEDS, arr.min(), arr.max(), sd, 3 * sd))

# The two constants the gate uses, and whether they still hold.
GATE_COEF_SD = 0.01128
GATE_SE_SD = 0.000865
for name, arr, gate_sd in (("coef", coefs, GATE_COEF_SD), ("se", ses, GATE_SE_SD)):
    sd = arr.std(ddof=1)
    print("%-5s gate constant %.6f vs measured %.8f  (ratio %.4f)"
          % (name, gate_sd, sd, gate_sd / sd if sd else float("inf")))
