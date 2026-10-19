"""v0.130.0 external oracle for the did_cs_binary sensitivity fix.

Three questions, answered in order:

1. TRANSCRIPTION. Recompute upstream's residual formula
   (`did_cs_binary.py:856-867`) on the PORT'S OWN inputs -- its subset y, G, t
   and its four cross-fitted g-functions -- and check it reproduces the
   port's new `sigma2` bit for bit. If it does not, the MoonBit is a bad
   transcription regardless of whether the old code was buggy.

2. THE OLD BUG, REPRODUCED. Independently rebuild the pre-v0.130.0 expression
   `data.y[i] - g00[i] - (g10[i] - g00[i]) * data.d[i]` over the FULL panel at
   subset positions and check it reproduces the old sigma2 (1.14726368007027).
   That confirms the diagnosis of WHAT was wrong, not just that something
   changed.

3. THE REAL PACKAGE. Fit the vendored upstream 0.11.4 on the same fixture and
   read its own `_sensitivity_elements["sigma2"]`, as an independent band.
   Exact equality is not expected -- the fold assignment differs -- but a
   583x gap should not survive it.
"""
import re
import sys

_VEND = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML\_verify\_upstream_ps\doubleml-0.11.4"
sys.path.insert(0, _VEND)

import numpy as np
import pandas as pd

import doubleml
from doubleml.data.panel_data import DoubleMLPanelData
from doubleml.did import DoubleMLDIDCSBinary
from doubleml.utils.propensity_score_processing import PSProcessorConfig
from sklearn.linear_model import LinearRegression, LogisticRegression

print(f"oracle doubleml {doubleml.__version__} from {doubleml.__file__}")

BASE = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML\_verify"

# ---- load the full panel (from the v0.129.0 dump) -----------------------
rows = []
for line in open(BASE + r"\_dump_1290.txt", encoding="utf-8"):
    line = line.strip()
    if re.match(r"^\d+,", line):
        rows.append([float(v) for v in line.split(",")])
df = pd.DataFrame(rows, columns=["row", "x0", "x1", "y", "d", "t", "id", "g"])
for c in ("row", "t", "id", "g"):
    df[c] = df[c].astype("int64")

# ---- load the port's own subset + g-functions + psi_a --------------------
ys, gs, ts, g00, g01, g10, g11, pa = ([] for _ in range(8))
for line in open(BASE + r"\_dump_1300.txt", encoding="utf-8"):
    line = line.strip()
    if line.startswith("D "):
        v = [float(x) for x in line[2:].split()]
        ys.append(v[0]); gs.append(v[1]); ts.append(v[2])
        g00.append(v[3]); g01.append(v[4]); g10.append(v[5]); g11.append(v[6])
        pa.append(v[7])

y = np.array(ys); g = np.array(gs); t = np.array(ts)
a00 = np.array(g00); a01 = np.array(g01); a10 = np.array(g10); a11 = np.array(g11)
psi_a = np.array(pa)
n = len(y)
print(f"port subset n={n}   mean(G)={g.mean():.6f}  mean(T)={t.mean():.6f}")

# ---- 1. transcription of upstream's formula ------------------------------
# did_cs_binary.py:856-867, transcribed literally
d0t0 = (1 - g) * (1 - t)
d0t1 = (1 - g) * t
d1t0 = g * (1 - t)
d1t1 = g * t
g_hat = d0t0 * a00 + d0t1 * a01 + d1t0 * a10 + d1t1 * a11
sigma2_upstream_formula = float(np.mean((y - g_hat) ** 2))
print()
print("--- 1. transcription check ---")
print(f"  python sigma2 (upstream formula, port's own inputs) = {sigma2_upstream_formula!r}")
print(f"  moonbit sigma2                                     = 0.0019663436427471525")
print(f"  bit-identical = {sigma2_upstream_formula == 0.0019663436427471525}")

# ---- 2. reproduce the old bug --------------------------------------------
# old: self.data.y[i] - g00[i] - (g10[i] - g00[i]) * self.data.d[i], for
# i in 0..n-1, where self.data is the FULL 1080-row panel.
full_y = df["y"].to_numpy()
full_d = df["d"].to_numpy()
old_resid = full_y[:n] - a00 - (a10 - a00) * full_d[:n]
sigma2_old = float(np.mean(old_resid ** 2))
print()
print("--- 2. the old bug, independently rebuilt ---")
print(f"  python sigma2 (old expression) = {sigma2_old!r}")
print(f"  moonbit sigma2 before v0.130.0  = 1.14726368007027")
print(f"  bit-identical = {sigma2_old == 1.14726368007027}")
print(f"  ratio old/new = {sigma2_old / sigma2_upstream_formula:.1f}x")
t1 = int((df['t'].to_numpy()[:n] == 1).sum())
print(f"  of the {n} rows the old code read, {t1} have t==1 (not in the subset)")

# ---- 3. the real upstream package ---------------------------------------
print()
print("--- 3. vendored upstream 0.11.4, own fit, own elements ---")
data = DoubleMLPanelData(
    df, y_col="y", d_cols="g", t_col="t", id_col="id", x_cols=["x0", "x1"]
)
est = DoubleMLDIDCSBinary(
    data,
    g_value=1,
    t_value_pre=0,
    t_value_eval=2,
    ml_g=LinearRegression(),
    ml_m=LogisticRegression(max_iter=2000),
    n_folds=2,
    ps_processor_config=PSProcessorConfig(clipping_threshold=0.01),
)
est.fit()
print(f"  upstream coef = {est.coef[0]:.9f}")
el = est._sensitivity_elements
u_sigma2 = float(np.asarray(el["sigma2"]).ravel()[0])
u_nu2 = float(np.asarray(el["nu2"]).ravel()[0])
print(f"  upstream sigma2 = {u_sigma2!r}")
print(f"  upstream nu2    = {u_nu2!r}")
print(f"  port sigma2     = {sigma2_upstream_formula!r}")
print(f"  ratio upstream/port sigma2 = {u_sigma2 / sigma2_upstream_formula:.4f}x")
print(f"  ratio OLD-bug / upstream   = {sigma2_old / u_sigma2:.4f}x")
print()
print("Fold assignment differs between the two (upstream stratifies on d and t"),
print("via StratifiedKFold; the port uses its own kfold_stratified), so exact")
print("equality is not expected. The discriminating fact is the ORDER OF")
print("MAGNITUDE: the old expression was ~2 orders out, the new one is level.")