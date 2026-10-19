"""Locate the 5.1% gap in nu2 by capturing the object upstream ACTUALLY passes.

Established: `_sensitivity_element_est` reads `preds["predictions"]["ml_m"]` --
a NESTED dict -- while `est.predictions` is a FLAT dict. They are different
objects, so the flat one may not be the cross-fitted set that feeds `nu2`.

Rather than keep guessing at the difference, monkeypatch the method to record
its `preds` argument verbatim, then recompute `nu2` three ways:

  1. the captured `preds["predictions"]["ml_m"]`   (what upstream actually used)
  2. `est.predictions["ml_m"]`                      (what the public flat API shows)
  3. the clipped variant of (1)

Whichever reproduces the reported `nu2` names the input, and the gap is closed
by measurement instead of attribution.
"""
import warnings

import numpy as np
import pandas as pd

warnings.filterwarnings("ignore")

from doubleml.did.did import DoubleMLDIDData
from doubleml.did.did_cs import DoubleMLDIDCS
from doubleml.did.datasets import make_did_cs_CS2021
from sklearn.ensemble import RandomForestRegressor
from sklearn.linear_model import LogisticRegression

np.random.seed(3141)

df = make_did_cs_CS2021(n_obs=400, dgp_type=1, include_never_treated=True,
                        lambda_t=0.5)
tvals = df["t"].to_numpy()
tdates = df["d"].to_numpy()
period_list = sorted(pd.unique(tvals))
df["t"] = pd.factorize(df["t"], sort=True)[0]
df["d"] = (tvals >= tdates).astype(float)
lo = period_list.index(min(p for p in period_list if (tdates == p).any()))
df = df[np.isin(pd.factorize(tvals, sort=True)[0], [lo, lo + 1])].reset_index(drop=True)
df["t"] = (df["t"] - lo).astype(int)

dml = DoubleMLDIDData(df, y_col="y", d_cols=["d"], t_col="t",
                      x_cols=["Z1", "Z2", "Z3", "Z4"])

captured = {}
_orig = DoubleMLDIDCS._sensitivity_element_est


def spy(self, preds):
    captured["preds"] = preds
    return _orig(self, preds)


DoubleMLDIDCS._sensitivity_element_est = spy

est = DoubleMLDIDCS(
    dml,
    ml_g=RandomForestRegressor(n_estimators=50, random_state=3141, min_samples_leaf=10),
    ml_m=LogisticRegression(max_iter=1000),
    n_folds=2, n_rep=1, score="observational", in_sample_normalization=True,
)
est.fit()

el = est._sensitivity_elements
nu2 = float(np.asarray(el["nu2"]).ravel()[0])
sigma2 = float(np.asarray(el["sigma2"]).ravel()[0])

d = np.asarray(est._dml_data.d, dtype=float)
t = np.asarray(est._dml_data.t, dtype=float)
d0t0, d0t1 = (1.0 - d) * (1.0 - t), (1.0 - d) * t
d1t0, d1t1 = d * (1.0 - t), d * t
p_hat, lam = d.mean(), t.mean()


def nu2_of(pw):
    w01, w00 = d0t1 * pw, d0t0 * pw
    mw01, mw00 = w01.mean(), w00.mean()
    ma = (d / p_hat) * (1.0 / d1t1.mean() + 1.0 / d1t0.mean()
                        + pw / mw01 + pw / mw00)
    rr = d1t1 / d1t1.mean() - d1t0 / d1t0.mean() - w01 / mw01 + w00 / mw00
    return float(np.mean(2.0 * ma - np.square(rr)))


def sigma2_of(gh):
    g = d0t0 * gh["d0t0"] + d0t1 * gh["d0t1"] + d1t0 * gh["d1t0"] + d1t1 * gh["d1t1"]
    return float(np.mean(np.square(np.asarray(est._dml_data.y, dtype=float) - g)))


print("=" * 74)
print("REPORTED  nu2 = %r   sigma2 = %r" % (nu2, sigma2))
print("=" * 74)

preds = captured["preds"]
print("captured preds type:", type(preds), "keys:", list(preds.keys())[:6])
inner = preds["predictions"] if "predictions" in preds else preds
print("inner keys:", list(inner.keys()))

m_inner = np.asarray(inner["ml_m"], dtype=float).ravel()
m_flat = np.asarray(est.predictions["ml_m"], dtype=float).ravel()
print()
print("ml_m inner shape %s  flat shape %s" % (m_inner.shape, m_flat.shape))
print("max |inner - flat| = %.6g   identical: %s"
      % (np.max(np.abs(m_inner - m_flat)), bool(np.allclose(m_inner, m_flat))))

gh_inner = {
    "d0t0": np.asarray(inner["ml_g_d0_t0"], dtype=float).ravel(),
    "d0t1": np.asarray(inner["ml_g_d0t1"] if "ml_g_d0t1" in inner
                       else inner["ml_g_d0_t1"], dtype=float).ravel(),
    "d1t0": np.asarray(inner["ml_g_d1_t0"], dtype=float).ravel(),
    "d1t1": np.asarray(inner["ml_g_d1_t1"], dtype=float).ravel(),
}

print()
for label, m in (("captured inner ml_m", m_inner), ("public flat ml_m", m_flat)):
    print("  nu2 from %-20s = %r   match: %s"
          % (label, nu2_of(m / (1.0 - m)), bool(np.isclose(nu2_of(m / (1 - m)), nu2, rtol=1e-9))))
mc = np.clip(m_inner, 1e-2, 1 - 1e-2)
print("  nu2 from %-20s = %r   match: %s"
      % ("clipped inner ml_m", nu2_of(mc / (1 - mc)),
         bool(np.isclose(nu2_of(mc / (1 - mc)), nu2, rtol=1e-9))))
print()
print("  sigma2 from captured inner g's = %r   match: %s"
      % (sigma2_of(gh_inner), bool(np.isclose(sigma2_of(gh_inner), sigma2, rtol=1e-9))))
print("  cell occupancy d0t0=%.4f d0t1=%.4f d1t0=%.4f d1t1=%.4f"
      % (d0t0.mean(), d0t1.mean(), d1t0.mean(), d1t1.mean()))
print("  p_hat=%.6f lambda_hat=%.6f  n=%d" % (p_hat, lam, len(d)))