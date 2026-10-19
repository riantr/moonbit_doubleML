"""Measure the fold-to-fold spread of BOTH coef and se upstream, so the gate's
tolerances are numbers rather than guesses."""
import sys
import os
import warnings

warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import numpy as np
from sklearn.linear_model import LinearRegression, LogisticRegression
import doubleml as dml
from doubleml.did.datasets import make_did_SZ2020

np.random.seed(42)
df = make_did_SZ2020(n_obs=500, return_type="DataFrame")
coefs, ses = [], []
for s in range(20):
    np.random.seed(1000 + s)
    m = dml.DoubleMLDID(dml.DoubleMLDIDData(df, "y", "d"),
                        LinearRegression(), LogisticRegression(),
                        n_folds=2, n_rep=1)
    m.fit()
    coefs.append(float(np.asarray(m.coef).ravel()[0]))
    ses.append(float(np.asarray(m.se).ravel()[0]))
coefs = np.array(coefs)
ses = np.array(ses)
PORT_C, PORT_S = 0.083893902916250457, 0.13835043175681036
for name, arr, port in (("coef", coefs, PORT_C), ("se", ses, PORT_S)):
    sd = arr.std(ddof=1)
    print("%-5s upstream over 20 fold seeds: min %.6f max %.6f sd %.6f"
          % (name, arr.min(), arr.max(), sd))
    print("      port %.17g -> z = %.2f sd, inside range: %s"
          % (port, abs(port - arr.mean()) / sd, bool(arr.min() <= port <= arr.max())))
    print("      3*sd = %.6f  2*sd = %.6f" % (3 * sd, 2 * sd))
