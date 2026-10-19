"""v0.129.0 external oracle: WHAT IS UPSTREAM'S LOCAL `d` IN did_cs_binary?

v0.128.0 recorded a "nuisance divergence": it claimed upstream regresses `ml_m`
on `d` and this port on `g_indicator`. That claim is WRONG. It was inferred
from the LOCAL VARIABLE NAME `d`, not from the data.

The decisive source line is `did_cs_binary.py:472`:

    _, d = check_X_y(x, self._g_data_subset, ensure_all_finite=False)
    #                                                                   ^^^^^
    #                                  (line 472's own inline comment reads
    #                                   "(d is the G_indicator)")

and `did_cs_binary.py:179`:
    self._g_data_subset = self.data_subset.loc[:, "G_indicator"].values

So upstream regresses `ml_m` on G and calibrates `adjust_ps` against G --
exactly what this port already did.

This script confirms that at RUNTIME against the vendored upstream 0.11.4
package, on the MoonBit port's own fixture. Decisive evidence: upstream's
`external_predictions['ml_m']['targets']`, which `did_cs_binary.py:552`
serialises, must equal G_indicator and must NOT equal the per-period `d`.
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

DUMP = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML\_verify\_dump_1290.txt"

rows, m01, m03 = [], [], []
with open(DUMP, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if line.startswith("HDR"):
            continue
        if line.startswith("M01 ") or line.startswith("M03 "):
            tag, val = line.split(" ", 1)
            try:
                f = float(val)
            except ValueError:
                continue
            (m01 if tag == "M01" else m03).append(f)
        elif re.match(r"^\d+,", line):
            rows.append([float(v) for v in line.split(",")])
assert m01 and m03 and int(m01[0]) == 720 and int(m03[0]) == 720, (m01[:2], m03[:2])
m01, m03 = m01[1:], m03[1:]

df = pd.DataFrame(rows, columns=["row", "x0", "x1", "y", "d", "t", "id", "g"])
# g/t/id MUST be integer dtype: `_get_never_treated_value` returns `inf` for a
# FLOATING g column, and `_is_never_treated` then does `np.isinf(g)` -> all
# False -> "No observations in the control group". Our dump wrote them via
# `to_string()` on ints, so restore the dtype rather than the value.
for c in ("row", "t", "id", "g"):
    df[c] = df[c].astype("int64")
print(f"fixture rows {len(df)}   port predictions_m n {len(m01)}")

tv = df["t"].to_numpy()
sub = df[(tv == 0) | (tv == 2)]
differ = int((sub["d"].to_numpy() != sub["g"].to_numpy()).sum())
print(f"panel subset {len(sub)}   rows with d != g: {differ}  <- the v0.128.0 premise, and it holds")
print(f"  mean(d) over subset = {sub['d'].mean():.6f}   mean(g) over subset = {sub['g'].mean():.6f}")
print("  so the two candidate nuisances are genuinely different functions;")
print("  the question is ONLY which one upstream actually fits.\n")

# ---------------------------------------------------------------- upstream
# `DoubleMLPanelData` takes the GROUP variable as d_cols[0]; `g_col` IS
# `d_cols[0]` (panel_data.py:249-253).
data = DoubleMLPanelData(
    df, y_col="y", d_cols="g", t_col="t", id_col="id", x_cols=["x0", "x1"]
)

# ------------------------------------------------- instrument the two sites
# There is no public `external_predictions` accessor in 0.11.4, and reading the
# variable name is exactly the mistake that produced v0.128.0. So instead we
# CAPTURE THE ARGUMENTS AT THE TWO CALL SITES the port is being compared to:
#   * `_dml_cv_predict(learner, x, d, ...)`   -- the ml_m REGRESSION TARGET
#   * `PSProcessor.adjust_ps(preds, d, cv=)`  -- the CALIBRATION TARGET
# Whatever upstream actually passes at those two points is, by definition, the
# nuisance definition -- no naming convention involved.
import doubleml.did.did_cs_binary as csb
import doubleml.utils.propensity_score_processing as psp

captured = {"cv_targets": [], "adjust_targets": []}

_orig_cv = csb._dml_cv_predict


def spy_cv(est, x, y, *a, **kw):
    captured["cv_targets"].append(np.asarray(y, dtype=float).copy())
    return _orig_cv(est, x, y, *a, **kw)


csb._dml_cv_predict = spy_cv

_orig_adjust = psp.PSProcessor.adjust_ps


def spy_adjust(self, preds, treatment, *a, **kw):
    captured["adjust_targets"].append(np.asarray(treatment, dtype=float).copy())
    return _orig_adjust(self, preds, treatment, *a, **kw)


psp.PSProcessor.adjust_ps = spy_adjust

res = {}
sub_g = sub["g"].to_numpy()
sub_d = sub["d"].to_numpy()
for tag, cfg in (
    ("0.01", PSProcessorConfig(clipping_threshold=0.01)),
    ("0.30", PSProcessorConfig(clipping_threshold=0.3)),
):
    captured["cv_targets"].clear()
    captured["adjust_targets"].clear()
    est = DoubleMLDIDCSBinary(
        data,
        g_value=1,
        t_value_pre=0,
        t_value_eval=2,
        ml_g=LinearRegression(),
        ml_m=LogisticRegression(max_iter=2000),
        n_folds=2,
        ps_processor_config=cfg,
    )
    est.fit()
    print(f"--- upstream clip {tag} ---")
    print(f"  upstream coef = {est.coef[0]:.12f}")
    for label, calls in (
        ("ml_m REGRESSION TARGET  (_dml_cv_predict 3rd arg)", captured["cv_targets"]),
        ("CALIBRATION TARGET     (adjust_ps 2nd arg)", captured["adjust_targets"]),
    ):
        # the LAST captured call is ml_m's (ml_g d0t0/d0t1/d1t0/d1t1 come first)
        tgt = calls[-1]
        print(f"  {label}")
        print(f"    n calls={len(calls)}  n={tgt.size}  sum={tgt.sum():.1f}")
        print(f"    == subset G_indicator : {np.array_equal(tgt, sub_g)}")
        print(f"    == subset d          : {np.array_equal(tgt, sub_d)}")
    lo, hi = (0.01, 0.99) if tag == "0.01" else (0.3, 0.7)
    final = captured["adjust_targets"][-1]
    res[tag] = final
    print()

print("VERDICT PREMISE: subset has", differ, "rows with d != g, and",
      f"mean(d)={sub_d.mean():.4f} vs mean(g)={sub_g.mean():.4f},")
print("so the two candidate targets are numerically distinguishable.\n")
print("port      clip 0.30 exact-bound 0.30/0.70 = 373 / 20  (v0.128.0, G-based)")
print("port      clip 0.30 preds mean =", round(float(np.mean(m03)), 9))
print("port      clip 0.01 preds mean =", round(float(np.mean(m01)), 9))
