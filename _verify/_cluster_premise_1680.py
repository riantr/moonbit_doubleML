"""Is the cluster decision's premise still true?

The evidence doc `_verify/CLUSTER_UPSTREAM_PARITY_1680.md` concluded that
upstream has NO working one-way cluster reference, because `cluster_vars`
produces n_samples=1 upstream. It was measured on doubleml 0.11.4. If upstream
has since fixed that, the premise of "switch the default to upstream's
cluster-average" changes completely -- so check the installed version and
re-run the decisive route.
"""
import importlib.metadata as md

import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestRegressor  # noqa: E402
from sklearn.linear_model import LinearRegression, LogisticRegression  # noqa: E402

print("doubleml", md.version("doubleml"))
from doubleml import DoubleMLData, DoubleMLPLR  # noqa: E402

rng = np.random.default_rng(0)
n = 400
x = rng.standard_normal((n, 2))
y = x[:, 0] + 0.5 * x[:, 1] + rng.standard_normal(n)
d = (rng.random(n) < 0.5).astype(float)
# 20 clusters of 20 -- repeated observations WITHIN a cluster, which is the case
# the evidence doc says upstream cannot fit at all.
cl = np.repeat(np.arange(20), 20)

ml_l = LinearRegression()
ml_m = LogisticRegression()

base = {"y": y, "d": d, "x0": x[:, 0], "x1": x[:, 1]}

CASES = [
    ("no clustering at all", None),
    ("cluster_cols = int", cl),
    ("cluster_cols = float", cl.astype(float)),
    ("cluster_cols = str", cl.astype(str)),
]

print("\nDoubleMLPLR, n_folds=2, 20 clusters x 20 obs (repeated obs within a "
      "cluster):")
for label, ccol in CASES:
    try:
        df = pd.DataFrame(dict(base))
        if ccol is None:
            data = DoubleMLData(df, "y", "d", ["x0", "x1"])
        else:
            df["cl"] = ccol
            data = DoubleMLData(df, "y", "d", ["x0", "x1"], cluster_cols=["cl"])
        est = DoubleMLPLR(data, ml_l=ml_l, ml_m=ml_m, n_folds=2)
        est.fit()
        ratio = est.se[0] / est._se[0]
        print("  %-26s coef %.6f  se %.8f  cluster/row %.4f  %s"
              % (label, est.coef[0], est.se[0], ratio,
                 "<-- clustering is a NO-OP" if abs(ratio - 1.0) < 1e-3 else ""))
    except Exception as exc:  # noqa: BLE001
        msg = str(exc).replace("\n", " ")[:120]
        print("  %-26s FAILS: %s" % (label, msg))

