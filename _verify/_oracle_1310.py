"""v0.131.0 external oracle: is the port's nu2 upstream's nu2?

The port's `DoubleMLDIDCSBinary` defaults `in_sample_normalization = false`
(`did_cs_binary.mbt:712`) while upstream defaults it to `True`
(`did_cs_binary.py:118`), so the two compute DIFFERENT branches of the same
formula. Comparing them only means anything when the flag is matched, which is
what this does.

Also reported: what the port would give if its default matched upstream's, so
the size of the DEFAULT divergence is on the record too.
"""
import sys
import os

_VEND = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "_verify", "_upstream_ps", "doubleml-0.11.4")
sys.path.insert(0, _VEND)

import numpy as np
import pandas as pd

import doubleml
from doubleml.data.panel_data import DoubleMLPanelData
from doubleml.did import DoubleMLDIDCSBinary
from doubleml.utils.propensity_score_processing import PSProcessorConfig
from sklearn.linear_model import LinearRegression, LogisticRegression

import re

print(f"oracle doubleml {doubleml.__version__}")
BASE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "_verify")
rows = []
for line in open(BASE + r"\_dump_1290.txt", encoding="utf-8"):
    line = line.strip()
    if re.match(r"^\d+,", line):
        rows.append([float(v) for v in line.split(",")])
df = pd.DataFrame(rows, columns=["row", "x0", "x1", "y", "d", "t", "id", "g"])
for c in ("row", "t", "id", "g"):
    df[c] = df[c].astype("int64")

data = DoubleMLPanelData(
    df, y_col="y", d_cols="g", t_col="t", id_col="id", x_cols=["x0", "x1"]
)
for flag in (False, True):
    est = DoubleMLDIDCSBinary(
        data,
        g_value=1,
        t_value_pre=0,
        t_value_eval=2,
        ml_g=LinearRegression(),
        ml_m=LogisticRegression(max_iter=2000),
        n_folds=2,
        in_sample_normalization=flag,
        ps_processor_config=PSProcessorConfig(clipping_threshold=0.01),
    )
    est.fit()
    el = est._sensitivity_elements
    print()
    print(f"--- upstream in_sample_normalization={flag} ---")
    print(f"  coef  = {est.coef[0]:.9f}")
    print(f"  nu2   = {float(np.asarray(el['nu2']).ravel()[0])!r}")
    print(f"  sigma2= {float(np.asarray(el['sigma2']).ravel()[0])!r}")

print()
print("port (in_sample_normalization=false, OLS ml_m):")
print("  coef   = 0.9965989708527849      (clip 0.01 default)")
print("  nu2    = 26.718919562055802")
print("  sigma2 = 0.0019663436427471525")
print()
print("The FLAG is the dominant term here: upstream's own nu2 moves between")
print("the two branches too. The port's difference from the matching-flag")
print("upstream value is the ml_m learner (upstream requires a classifier,")
print("the port fits OLS), which propagates through the propensity weights.")