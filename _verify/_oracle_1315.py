"""v0.131.5 external oracle: is the 15.3% nu2 gap a PORT DEFECT or a NUISANCE difference?

The open question carried out of v0.131.4. v0.131.0's `_oracle_1310.py` compared:

    upstream  (ml_m = LogisticRegression, in_sample_normalization=False)  nu2 = 23.179137007778895
    port      (ml_m = OLS,               in_sample_normalization=false)  nu2 = 26.718919562055802

a 15.3% gap, and attributed it in a closing comment to the ml_m learner without
proving it. `sigma2` agreeing to 1.1% is consistent with that story -- sigma2
depends on g_hat, nu2 depends on m_hat -- but "consistent with" is not proof.

THE DECISIVE TEST. nu2 is a pure function of (d, t, m_hat) and the flag:

    m_alpha = d/p^2 * (1/lambda + 1/(1-lambda)) * (1 + m/(1-m))
    rr      = ( t/(p*lambda) + (1-t)/(p*(1-lambda)) ) * ( d + (1-d)*m/(1-m) )
    nu2     = mean( 2*m_alpha - rr^2 )

So feed UPSTREAM'S OWN m_hat into the port's transcription and see whether it
reproduces UPSTREAM'S nu2. If it does, the transcription is proven faithful and
the 15.3% can only be the nuisance model. Then run the SAME transcription on the
PORT's m_hat and check it reproduces the port's nu2, closing the loop from the
other side.

Either branch reproducing its own number proves the formula. Both reproducing
proves the gap is entirely the input m_hat, not the port.
"""
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

import re

BASE = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML\_verify"


def port_nu2(d, t, m):
    """Transcription of the port's `cs_bin_sensitivity_nu2_elements`, false
    branch (did_cs_binary.mbt:1277-1299), which mirrors upstream
    did_cs_binary.py:896-902 + :932. Guarded denominators reproduced so the
    transcription matches the PORT rather than upstream's bare np.divide."""
    d = np.asarray(d, dtype=float)
    t = np.asarray(t, dtype=float)
    m = np.asarray(m, dtype=float)
    n = d.shape[0]
    n_d = float(n)
    p_hat = d.mean()
    lam = t.mean()
    pw = np.where((1.0 - m) > 1e-12, m / (1.0 - m), 0.0)
    m_alpha_1 = (1.0 / lam + 1.0 / (1.0 - lam)) if (lam > 1e-12 and lam < 1.0 - 1e-12) else 0.0
    m_alpha = (d / (p_hat * p_hat)) * (m_alpha_1 * (1.0 + pw)) if p_hat > 0.0 else np.zeros(n)
    if p_hat > 1e-12 and lam > 1e-12 and lam < 1.0 - 1e-12:
        rr_1 = t / (p_hat * lam) + (1.0 - t) / (p_hat * (1.0 - lam))
    else:
        rr_1 = np.zeros(n)
    rr = rr_1 * (d + (1.0 - d) * pw)
    elem = 2.0 * m_alpha - rr * rr
    return float(elem.mean()), elem


print(f"oracle doubleml {doubleml.__version__}")

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

print()
print("=" * 74)
print("UPSTREAM, in_sample_normalization=False (the matching branch)")
print("=" * 74)
# upstream's OWN d, t and m_hat -- the exact inputs its nu2 was built from.
# m_hat is not exposed as an attribute, so capture it AT THE CALL SITE by
# wrapping PSProcessor.adjust_ps, whose return value IS m_hat
# (did_cs_binary.py:516). Same technique as _oracle_1290.py: never trust a
# name or a comment for what flows into the formula -- record the value.
from doubleml.utils.propensity_score_processing import PSProcessor

CAPTURED = []
_orig_adjust = PSProcessor.adjust_ps


def _spy_adjust(self, ps_preds, ps_index, **kwargs):
    out = _orig_adjust(self, ps_preds, ps_index, **kwargs)
    CAPTURED.append(np.asarray(out, dtype=float).copy())
    return out


PSProcessor.adjust_ps = _spy_adjust

# v0.131.0's oracle fitted WITHOUT a seed, so upstream's cross-fitting folds were
# redrawn every run and its nu2 came out at 22.71 / 23.10 / 24.11 / 24.60 on four
# consecutive runs -- a ~8% spread. Any "the port is N% away from upstream" claim
# built on that number was measured against a moving baseline. Pin the RNG so
# every number below is reproducible.
np.random.seed(3141)

est = DoubleMLDIDCSBinary(
    data,
    g_value=1,
    t_value_pre=0,
    t_value_eval=2,
    ml_g=LinearRegression(),
    ml_m=LogisticRegression(max_iter=2000),
    n_folds=2,
    in_sample_normalization=False,
    ps_processor_config=PSProcessorConfig(clipping_threshold=0.01),
)
est.fit()
el = est._sensitivity_elements
up_nu2 = float(np.asarray(el["nu2"]).ravel()[0])
up_sig2 = float(np.asarray(el["sigma2"]).ravel()[0])

# upstream's OWN d, t and m_hat -- the exact inputs its nu2 was built from.
up_d = np.asarray(est._g_data_subset, dtype=float)
up_t = np.asarray(est._t_data_subset, dtype=float)
up_m = None
for cand in CAPTURED:
    if cand.ndim == 1 and cand.shape[0] == up_d.shape[0]:
        up_m = cand
        break

print(f"  upstream nu2      = {up_nu2!r}")
print(f"  upstream sigma2   = {up_sig2!r}")
print(f"  upstream n        = {up_d.shape[0]}")
if up_m is None:
    print("  !! could not locate upstream m_hat; cannot run the decisive test")
    sys.exit(2)

print(f"  upstream mean(m_hat) = {up_m.mean():.9f}")
print(f"  upstream p_hat       = {up_d.mean():.9f}")
print(f"  upstream lambda_hat  = {up_t.mean():.9f}")

print()
print("=" * 74)
print("DECISIVE: port's transcription fed UPSTREAM's own (d, t, m_hat)")
print("=" * 74)
fed_nu2, _ = port_nu2(up_d, up_t, up_m)
rel = (fed_nu2 - up_nu2) / abs(up_nu2)
print(f"  transcription on upstream inputs = {fed_nu2!r}")
print(f"  upstream's own nu2               = {up_nu2!r}")
print(f"  relative difference              = {rel:.3e}")
print(f"  --> {'MATCH: the port formula is upstream\'s formula' if abs(rel) < 1e-12 else 'DIFFER'}")

print()
print("=" * 74)
print("CONTROL: the SAME transcription fed the PORT's own m_hat")
print("=" * 74)
PORT_NU2 = 26.718919562055802
try:
    rows2 = []
    for line in open(BASE + r"\_dump_nu2_1315.txt", encoding="utf-8"):
        line = line.strip()
        if line.startswith("DUMP1315,"):
            rows2.append([float(v) for v in line[len("DUMP1315,"):].split(",")])
    if rows2:
        p_m = np.array([r[0] for r in rows2])
        p_d = np.array([r[1] for r in rows2])
        p_t = np.array([r[2] for r in rows2])
        print(f"  port dump n       = {p_m.shape[0]}")
        print(f"  port mean(m_hat)  = {p_m.mean():.9f}")
        ctrl_nu2, _ = port_nu2(p_d, p_t, p_m)
        print(f"  transcription on port inputs  = {ctrl_nu2!r}")
        print(f"  the port's own reported nu2   = {PORT_NU2!r}")
        ctl_rel = (ctrl_nu2 - PORT_NU2) / abs(PORT_NU2)
        print(f"  relative difference           = {ctl_rel:.3e}")
        print()
        print("  --> %s" % (
            "BOTH SIDES MATCH: same formula, so the 15.3% is entirely m_hat"
            if abs(ctl_rel) < 1e-12 and abs(rel) < 1e-12
            else "one side did not match -- investigate before concluding"))
        print()
        print(f"  m_hat mean: upstream {up_m.mean():.9f} vs port {p_m.mean():.9f}")
        print(f"  m_hat L2 distance between the two: "
              f"{np.sqrt(((up_m - p_m) ** 2).sum()):.9f}")
    else:
        print("  (no _dump_nu2_1315.txt yet -- run the MoonBit probe first)")
except FileNotFoundError:
    print("  (no _dump_nu2_1315.txt yet -- run the MoonBit probe first)")
