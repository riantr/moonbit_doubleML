"""v0.131.8 external oracle: do upstream IRM and APO take the SAME nu2 <= 0
fallback branch the port reports on this fixture?

v0.131.7 shipped the family-2 migration (irm + apo) WITHOUT an oracle, and said
so in the changelog. This closes that gap. The specific question is not "do the
formulas agree" -- the gates already re-derive those from (d, m_hat). It is:

    the port reports 540.55 / 290.29, and those numbers come from upstream's
    FALLBACK branch (double_ml.py:1630-1641), not from the primary
    `mean(2*m_alpha - rr^2)`, which measures NEGATIVE (-488.83) on this
    fixture. Does real upstream 0.11.4 take that same branch on the same data?

If upstream took the PRIMARY branch instead, the port would be reporting a
number upstream never produces -- which would be a far worse finding than
v0.131.6's `mean(psi_a^2)` bug, because it would still be wrong after the fix.

The branch condition upstream is `np.any(nu2 <= 0)` on the FULL element vector
(double_ml.py:1630). So this checks both the sign of the primary AND that
`mean(rr^2)` is what both sides report.

Upstream's IRM needs `ml_m` to be a classifier; `ml_g` is fit on each treatment
arm. APO is instantiated at treatment_level 1.0.

SEEDED (`np.random.seed(3141)`) -- v0.131.0's oracle was not, and its own nu2
drifted 22.71 -> 24.60 over four runs.
"""
import sys

_VEND = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML\_verify\_upstream_ps\doubleml-0.11.4"
sys.path.insert(0, _VEND)

import numpy as np
import pandas as pd

import doubleml
from doubleml import DoubleMLAPO, DoubleMLIRM
from doubleml.data import DoubleMLData
from sklearn.linear_model import LinearRegression, LogisticRegression

BASE = r"D:\src\MiniMax\Projects\DoubleMachineLearning\moonbit_doubleML\_verify"

PORT_NU2 = {"IRM": 540.5547419191752, "APO": 290.2904525219809}
PORT_PRIMARY = {"IRM": -488.8297898618956, "APO": None}


def port_elements(kind, d, m, treatment_level=1.0):
    """Transcription of the port's `sensitivity_nu2_elements` for irm / apo.

    irm.mbt  : m_alpha = 1/m + 1/(1-m),  rr = d/m - (1-d)/(1-m)
    apo.mbt  : m_alpha = 1/m,            rr = treated/m
    Both then apply upstream's fallback rule: nu2 <= 0 -> mean(rr^2).
    """
    d = np.asarray(d, dtype=float)
    m = np.asarray(m, dtype=float)
    if kind == "IRM":
        m_alpha = 1.0 / m + 1.0 / (1.0 - m)
        rr = d / m - (1.0 - d) / (1.0 - m)
    else:
        treated = (d == treatment_level).astype(float)
        m_alpha = 1.0 / m
        rr = treated / m
    primary = float((2.0 * m_alpha - rr * rr).mean())
    fallback = float((rr * rr).mean())
    reported = primary if primary > 0.0 else fallback
    return primary, fallback, reported, rr


# ------------------------------------------------------------- load port data
rows = []
for line in open(BASE + r"\_dump_fam2_1318.txt", encoding="utf-8"):
    line = line.strip()
    if line.startswith("FAM2DUMP,"):
        rows.append([float(v) for v in line[len("FAM2DUMP,"):].split(",")])

X = np.array([[r[4], r[5], r[6]] for r in rows])
p_y = np.array([r[0] for r in rows])
p_d = np.array([r[1] for r in rows])
p_m_irm = np.array([r[2] for r in rows])
p_m_apo = np.array([r[3] for r in rows])
n = X.shape[0]

print(f"oracle doubleml {doubleml.__version__}")
print(f"  port fixture: n={n} p=3  mean(d)={p_d.mean():.9f}")
print(f"  port mean(m_hat): irm={p_m_irm.mean():.9f}  apo={p_m_apo.mean():.9f}")

df = pd.DataFrame({
    "y": p_y, "d": p_d,
    "x0": X[:, 0], "x1": X[:, 1], "x2": X[:, 2],
})


def fit_upstream(cls, **kw):
    np.random.seed(3141)
    dml = DoubleMLData(df, y_col="y", d_cols="d", x_cols=["x0", "x1", "x2"])
    est = cls(
        dml,
        ml_g=LinearRegression(),
        ml_m=LogisticRegression(max_iter=2000),
        n_folds=2,
        **kw,
    )
    est.fit()
    el = est._sensitivity_elements
    up_d = np.asarray(est._dml_data.d, dtype=float)
    return est, el, up_d


print()
print("=" * 74)
print("CONTROL: port's transcription fed the PORT's own inputs")
print("=" * 74)
for kind, pm in (("IRM", p_m_irm), ("APO", p_m_apo)):
    prim, fb, rep, rr = port_elements(kind, p_d, pm)
    mb = PORT_NU2[kind]
    print("  %s primary=%r fallback(mean rr^2)=%r" % (kind, prim, fb))
    print("  %s transcription reported=%r  moonbit=%r  rel=%.3e"
          % (kind, rep, mb, (rep - mb) / abs(mb)))
    if kind == "IRM":
        assert abs(prim - PORT_PRIMARY["IRM"]) < 1.0e-9, prim
        print("  %s primary agrees with the MEASURED -488.8297898618956" % kind)

print()
print("=" * 74)
print("DECISIVE: which branch does UPSTREAM take, and is it driven by m_hat?")
print("=" * 74)
print("Upstream's branch test is `np.any(nu2 <= 0)` on the FULL element vector")
print("(double_ml.py:1630). Which branch is taken therefore depends on the")
print("NUISANCE, not just the formula -- so the right question is not 'do the")
print("numbers match' but 'do both sides apply the same rule to their own")
print("inputs'. Capturing each side's OWN m_alpha/rr answers that.")

for kind, cls, kw, pm in (
    ("IRM", DoubleMLIRM, {"score": "ATE"}, p_m_irm),
    ("APO", DoubleMLAPO, {"treatment_level": 1}, p_m_apo),
):
    cap = {}
    orig = cls._sensitivity_element_est

    def spy(self, preds, _k=kind, _c=cap, _o=orig):
        out = _o(self, preds)
        _c["rr"] = np.asarray(out["riesz_rep"], dtype=float).copy()
        _c["nu2_primary"] = float(np.asarray(out["nu2"]).ravel()[0])
        _c["m_hat"] = np.asarray(preds["predictions"]["ml_m"], dtype=float).copy()
        return out

    cls._sensitivity_element_est = spy
    try:
        est, el, up_d = fit_upstream(cls, **kw)
    finally:
        cls._sensitivity_element_est = orig

    up_nu2 = float(np.asarray(el["nu2"]).ravel()[0])
    up_rr = cap["rr"]
    up_primary = cap["nu2_primary"]
    up_fallback = float((up_rr * up_rr).mean())

    # What the port's own transcription says about UPSTREAM's inputs.
    prim_u, fb_u, rep_u, _ = port_elements(kind, up_d, cap["m_hat"])

    print()
    print("  --- upstream %s (upstream's own m_hat) ---" % kind)
    print("    upstream's PRIMARY nu2        = %r" % up_primary)
    print("    upstream's mean(rr^2)         = %r" % up_fallback)
    print("    upstream's REPORTED nu2       = %r" % up_nu2)
    up_branch = "PRIMARY" if abs(up_nu2 - up_primary) < abs(up_nu2 - up_fallback) else "FALLBACK"
    print("    -> upstream took the %s branch" % up_branch)

    # And what the port reports on the port's own inputs.
    prim_p, fb_p, rep_p, _ = port_elements(kind, p_d, pm)
    p_branch = "PRIMARY" if prim_p > 0.0 else "FALLBACK"
    print("    port's PRIMARY (port's m_hat) = %r" % prim_p)
    print("    port's REPORTED nu2           = %r" % PORT_NU2[kind])
    print("    -> port took the %s branch" % p_branch)
    print("    mean(m_hat): upstream %.9f vs port %.9f"
          % (cap["m_hat"].mean(), pm.mean()))

    # THE ACTUAL CLAIM: identical inputs => identical branch and value.
    fed_primary, fed_fallback, fed_reported, _ = port_elements(kind, up_d, cap["m_hat"])
    rel = (fed_reported - up_nu2) / abs(up_nu2)
    print("    transcription on UPSTREAM's own m_hat = %r" % fed_reported)
    print("    relative difference vs upstream       = %.3e" % rel)
    verdict = "MATCH" if abs(rel) < 1.0e-9 else "DIFFER"
    if up_branch == "FALLBACK" and abs(fed_reported - up_fallback) < 1e-9 * abs(up_fallback):
        verdict += " (fallback branch, upstream's own mean(rr^2))"
    elif up_branch == "PRIMARY" and abs(fed_reported - fed_primary) < 1e-9 * abs(fed_primary):
        verdict += " (primary branch)"
    print("    --> %s" % verdict)
