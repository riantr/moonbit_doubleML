"""Scoping check: how wrong is the shared `nu2 = mean(psi_a^2)` convention?

v0.130.0's oracle already reported, on the same fixture:
    upstream 0.11.4 nu2 = 25.83093370768923
    port          nu2 =   3.30275229357797
an 7.8x gap -- but upstream used LogisticRegression for ml_m (it requires a
classifier) while the port uses OLS, so part of that is a nuisance difference.

This isolates the CONVENTION itself, using the port's OWN quantities:

1. Is the port's `psi_a` really upstream's Riesz representer `rr`?
   Recompute upstream's `rr` (did_cs_binary.py:890-895) from the dumped d, t
   and m_hat and compare against the dumped psi_a.

2. If it is, recompute upstream's `nu2 = mean(2*m_alpha - rr^2)`
   (did_cs_binary.py:882-933) on the port's own inputs and compare against
   `mean(psi_a^2)` = 3.30275229357797.

Only needs the v0.130.0 dump plus m_hat, which is dumped here.
"""
import re
import os

BASE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "_verify")

ys, gs, ts, g00, g01, g10, g11, pa = ([] for _ in range(8))
for line in open(BASE + r"\_dump_1300.txt", encoding="utf-8"):
    line = line.strip()
    if line.startswith("D "):
        v = [float(x) for x in line[2:].split()]
        ys.append(v[0]); gs.append(v[1]); ts.append(v[2])
        g00.append(v[3]); g01.append(v[4]); g10.append(v[5]); g11.append(v[6])
        pa.append(v[7])

mhat = []
for line in open(BASE + r"\_dump_1310.txt", encoding="utf-8"):
    line = line.strip()
    if line.startswith("M "):
        mhat.append(float(line[2:]))

import numpy as np

y = np.array(ys); g = np.array(gs); t = np.array(ts)
rr_port = np.array(pa)
n = len(y)
print(f"subset n={n}   m_hat dumped = {len(mhat)}")
assert len(mhat) == n, "m_hat dump missing or wrong length"

d0t0 = (1 - g) * (1 - t); d0t1 = (1 - g) * t
d1t0 = g * (1 - t);       d1t1 = g * t

m = np.array(mhat)
pw = np.divide(m, np.where(1 - m > 1e-12, 1 - m, 1.0))   # upstream: m/(1-m)
w_d0t1 = d0t1 * pw
w_d0t0 = d0t0 * pw
mw_d0t1 = np.mean(w_d0t1)
mw_d0t0 = np.mean(w_d0t0)

# upstream did_cs_binary.py:890-895 (observational, in_sample_normalization)
rr_up = (
    np.divide(d1t1, np.mean(d1t1))
    - np.divide(d1t0, np.mean(d1t0))
    - np.divide(w_d0t1, mw_d0t1)
    + np.divide(w_d0t0, mw_d0t0)
)
print()
print("--- 1. is the port's psi_a upstream's rr? ---")
print(f"  max |port psi_a - upstream rr| = {np.max(np.abs(rr_port - rr_up)):.3e}")
print(f"  bit-identical = {np.array_equal(rr_port, rr_up)}")

# upstream did_cs_binary.py:882-888
p_hat = np.mean(g)
m_alpha = np.multiply(
    np.divide(g, p_hat),
    np.divide(1.0, np.mean(d1t1))
    + np.divide(1.0, np.mean(d1t0))
    + np.divide(pw, mw_d0t1)
    + np.divide(pw, mw_d0t0),
)
nu2_upstream = float(np.mean(2.0 * m_alpha - np.square(rr_up)))
nu2_port = float(np.mean(np.square(rr_port)))
print()
print("--- 2. nu2: upstream convention vs the port's shared convention ---")
print(f"  upstream  mean(2*m_alpha - rr^2) = {nu2_upstream!r}")
print(f"  port      mean(psi_a^2)          = {nu2_port!r}")
print(f"  ratio port/upstream              = {nu2_port / nu2_upstream:.4f}x")
print(f"  mean(2*m_alpha)                  = {float(np.mean(2.0*m_alpha)):.6f}")
print(f"  mean(rr^2)                       = {nu2_port:.6f}")
print()
print("  reference: real upstream 0.11.4 on this fixture reported nu2 =")
print("  25.83093370768923, port reported 3.30275229357797")

# ---- 3. reproduce the MOONBIT's expression exactly, with its guards --------
# The v0.131.0 MoonBit reports nu2 = 26.718919562055802. If Python cannot
# reproduce that bit-for-bit, the transcription differs and must be found
# BEFORE shipping -- a 0.5% gap is not rounding.
EPS = 1e-12
pw = np.array([m[i] / (1 - m[i]) if (1 - m[i]) > EPS else 0.0 for i in range(n)])
w_d0t1 = d0t1 * pw
w_d0t0 = d0t0 * pw


def acc(a):          # plain left-to-right sum, like the MoonBit loop
    s = 0.0
    for v in a:
        s += v
    return s / len(a)


mw_d0t1 = acc(w_d0t1)
mw_d0t0 = acc(w_d0t0)
p_hat = acc(g)
lambda_hat = acc(t)
mean_d1t1 = acc(d1t1)
mean_d1t0 = acc(d1t0)

ma = np.zeros(n)
rr2 = np.zeros(n)
for i in range(n):
    di = g[i]; ti = t[i]; pwi = pw[i]
    d_over_p = di / p_hat if p_hat > 0.0 else 0.0
    inv1 = 1.0 / mean_d1t1 if mean_d1t1 > 0.0 else 0.0
    inv2 = 1.0 / mean_d1t0 if mean_d1t0 > 0.0 else 0.0
    inv3 = pwi / mw_d0t1 if mw_d0t1 > 0.0 else 0.0
    inv4 = pwi / mw_d0t0 if mw_d0t0 > 0.0 else 0.0
    ma[i] = d_over_p * (inv1 + inv2 + inv3 + inv4)
    a = di * ti / mean_d1t1 if mean_d1t1 > 0.0 else 0.0
    b = di * (1 - ti) / mean_d1t0 if mean_d1t0 > 0.0 else 0.0
    c = (1 - di) * ti * pwi / mw_d0t1 if mw_d0t1 > 0.0 else 0.0
    e = (1 - di) * (1 - ti) * pwi / mw_d0t0 if mw_d0t0 > 0.0 else 0.0
    rr2[i] = a - b - c + e

nu2_moon = float(acc(2.0 * ma - np.square(rr2)))
print()
print("--- 3a. the in_sample_normalization = TRUE branch ---")
print(f"  python nu2 = {nu2_moon!r}   (probe's inline copy agrees)")
print(f"  this is NOT what the estimator uses -- see 3b")

# ---- 3b. the branch the estimator ACTUALLY takes -------------------------
# `DoubleMLDIDCSBinary::new(..., in_sample_normalization : Bool = false)`
# (did_cs_binary.mbt:712), so `cs_bin_sensitivity_nu2_elements` runs
# upstream's `else` branch (did_cs_binary.py:896-902).
#
# NOTE: upstream's own default for in_sample_normalization is TRUE
# (did_cs_binary.py:118). The port defaults it to false. That is a separate,
# pre-existing divergence in the SCORE path (it moves coef and se too) and is
# deliberately NOT touched here -- it needs its own measurement pass.
ma_f = np.zeros(n)
rr_f = np.zeros(n)
for i in range(n):
    di = g[i]; ti = t[i]; pwi = pw[i]
    m_alpha_1 = 1.0 / lambda_hat + 1.0 / (1.0 - lambda_hat)
    d_over_p2 = di / (p_hat * p_hat)
    ma_f[i] = d_over_p2 * (m_alpha_1 * (1.0 + pwi))
    rr_1 = ti / (p_hat * lambda_hat) + (1 - ti) / (p_hat * (1 - lambda_hat))
    rr_2 = di + (1 - di) * pwi
    rr_f[i] = rr_1 * rr_2
nu2_false = float(acc(2.0 * ma_f - np.square(rr_f)))
print()
print("--- 3b. the in_sample_normalization = FALSE branch (the one in use) ---")
print(f"  python nu2 = {nu2_false!r}")
print(f"  moonbit nu2 = 26.718919562055802")
print(f"  bit-identical = {nu2_false == 26.718919562055802}")
print()
print("  expected resulting max_bias = sqrt(sigma2*nu2) =")
print(f"    {(0.0019663436427471525 * nu2_false) ** 0.5!r}")