"""v0.131.6 external oracle: is the port's DID `nu2` upstream's DID `nu2`?

Same discipline as `_oracle_1315.py`, which is the only reason that release was
trustworthy: do not compare two ESTIMATES. Feed each side's OWN inputs into the
port's transcription and require each to reproduce its own number.

`nu2` for the DID ATT score (upstream `did/did.py:332-353`):

    p_hat = mean(d);  pw = m_hat / (1 - m_hat)

    observational + in_sample_normalization:
        w_d0    = (1-d) * pw
        m_alpha = (d/p) * (1/p + pw/mean(w_d0))
        rr      = d/p - w_d0/mean(w_d0)
    observational, not in_sample_normalization:
        m_alpha = (d/p^2) * (1 + pw)
        rr      = d/p - ((1-d)/p) * pw
    experimental:
        m_alpha = 1/p + 1/(1-p)
        rr      = d/p - (1-d)/(1-p)

    nu2 = mean( 2*m_alpha - rr^2 )

SEEDED. v0.131.0's oracle was not, and its own `nu2` moved 22.71 -> 24.60 over
four runs -- an ~8% spread on the very number a "15.3% gap" was measured against.
"""
import sys

_VEND = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML\_verify\_upstream_ps\doubleml-0.11.4"
sys.path.insert(0, _VEND)

import numpy as np
import pandas as pd

import doubleml
from doubleml import DoubleMLDID
from doubleml.data import DoubleMLDIDData
from doubleml.utils.propensity_score_processing import PSProcessorConfig
from sklearn.linear_model import LinearRegression, LogisticRegression

BASE = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML\_verify"


def port_nu2(d, m, in_sample_normalization, score):
    """Transcription of `DoubleMLDID::sensitivity_nu2_elements` (did.mbt)."""
    d = np.asarray(d, dtype=float)
    m = np.asarray(m, dtype=float)
    p_hat = d.mean()
    pw = np.where((1.0 - m) > 1e-12, m / (1.0 - m), 0.0)
    mean_w_d0 = ((1.0 - d) * pw).mean()

    d_over_p = np.where(p_hat > 1e-12, d / p_hat, 0.0)
    inv_p = np.where(p_hat > 1e-12, 1.0 / p_hat, 0.0)

    if score == "observational":
        if in_sample_normalization:
            pw_over_w = np.where(mean_w_d0 > 1e-12, pw / mean_w_d0, 0.0)
            m_alpha = d_over_p * (inv_p + pw_over_w)
            rr = d_over_p - (1.0 - d) * pw_over_w
        else:
            d_over_p2 = np.where(p_hat > 1e-12, d / (p_hat * p_hat), 0.0)
            m_alpha = d_over_p2 * (1.0 + pw)
            rr = d_over_p - (1.0 - d) * inv_p * pw
    else:
        inv_d0 = np.where((p_hat > 1e-12) & (p_hat < 1.0 - 1e-12),
                          1.0 / (1.0 - p_hat), 0.0)
        m_alpha = inv_p + inv_d0
        rr = d_over_p - (1.0 - d) * inv_d0
    return float((2.0 * m_alpha - rr * rr).mean())


# ---------------------------------------------------------------- load the port's own data
rows = []
for line in open(BASE + r"\_dump_did_1316.txt", encoding="utf-8"):
    line = line.strip()
    if line.startswith("DIDDUMP,"):
        rows.append([float(v) for v in line[len("DIDDUMP,"):].split(",")])

X = np.array([[r[3], r[4], r[5]] for r in rows])
p_y = np.array([r[0] for r in rows])
p_d = np.array([r[1] for r in rows])
p_m = np.array([r[2] for r in rows])
n = X.shape[0]
print(f"oracle doubleml {doubleml.__version__}")
print(f"  port fixture: n={n} p=3 mean(d)={p_d.mean():.9f} mean(m_hat)={p_m.mean():.9f}")

# ---------------------------------------------------------------- CONTROL: port's own inputs
PORT_MB = {
    ("observational", False): 47.70752003810404,
    ("observational", True): 54.452951164428164,
    ("experimental", False): 4.1006481302183575,
}
print()
print("=" * 74)
print("CONTROL: port's transcription fed the PORT's own (d, m_hat)")
print("=" * 74)
ctrl_ok = True
for (sc, isn), mb in sorted(PORT_MB.items()):
    got = port_nu2(p_d, p_m, isn, sc)
    rel = (got - mb) / abs(mb)
    print("  %-22s transcription=%r moonbit=%r rel=%.3e" % (sc + " isn=" + str(isn), got, mb, rel))
    ctrl_ok = ctrl_ok and abs(rel) < 1e-12

# ---------------------------------------------------------------- DECISIVE: upstream's own inputs
print()
print("=" * 74)
print("DECISIVE: fit upstream on the PORT's data, feed ITS m_hat back in")
print("=" * 74)

# `DoubleMLDID` does NOT use PSProcessor (did.py:267 clips directly), so wrap
# `_sensitivity_element_est` itself -- the exact call site where m_hat enters
# the formula (did.py:322 reads `preds["predictions"]["ml_m"]`). Same
# "capture at the call site, never infer from a name" discipline as
# _oracle_1290.py and _oracle_1315.py.
CAPTURED = []
_orig_est = DoubleMLDID._sensitivity_element_est


def _spy_element(self, preds):
    CAPTURED.append({
        "m_hat": np.asarray(preds["predictions"]["ml_m"], dtype=float).copy(),
        "d": np.asarray(self._dml_data.d, dtype=float).copy(),
    })
    return _orig_est(self, preds)


DoubleMLDID._sensitivity_element_est = _spy_element

for sc, isn in [("observational", False), ("observational", True), ("experimental", False)]:
    CAPTURED.clear()
    np.random.seed(3141)
    df = pd.DataFrame({"y": p_y, "d": p_d, "x0": X[:, 0], "x1": X[:, 1], "x2": X[:, 2]})
    dml = DoubleMLDIDData(df, y_col="y", d_cols="d", x_cols=["x0", "x1", "x2"])
    est = DoubleMLDID(
        dml,
        ml_g=LinearRegression(),
        ml_m=LogisticRegression(max_iter=2000),
        n_folds=2,
        score=sc,
        in_sample_normalization=isn,
    )
    est.fit()
    el = est._sensitivity_elements
    up_nu2 = float(np.asarray(el["nu2"]).ravel()[0])
    if not CAPTURED:
        print("  !! no capture for score=%s isn=%s" % (sc, isn))
        continue
    cap = CAPTURED[-1]
    up_d = cap["d"]
    up_m = cap["m_hat"]
    if up_m is None:
        print("  !! could not capture upstream m_hat for %s" % sc)
        continue
    fed = port_nu2(up_d, up_m, isn, sc)
    rel = (fed - up_nu2) / abs(up_nu2)
    print()
    print("  --- upstream score=%s in_sample_normalization=%s ---" % (sc, isn))
    print("    upstream's own nu2        = %r" % up_nu2)
    print("    transcription on its input= %r" % fed)
    print("    relative difference       = %.3e" % rel)
    print("    --> %s" % ("MATCH" if abs(rel) < 1e-12 else "DIFFER"))
    print("    mean m_hat: upstream %.9f vs port %.9f" % (up_m.mean(), p_m.mean()))

print()
print("=" * 74)
print("SUMMARY")
print("=" * 74)
print("  control (port inputs) reproduces the MoonBit values : %s" % ctrl_ok)
