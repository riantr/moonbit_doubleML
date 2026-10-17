"""Pin the rdrobust target for the sec_rdd_var design, and test bias-correction
candidate formulas against out.Estimate['tau.bc'].

Design is a bit-exact transcription of examples/parity/main.mbt:sec_rdd_var.
"""
import numpy as np
from rdrobust import rdrobust

H = 0.5
C = 0.0
N = 800


def build():
    u = np.empty(N)
    z = np.empty(N)
    y = np.empty(N)
    d = np.empty(N)
    for i in range(N):
        uu = (i + 0.5) / 400.0 - 1.0
        zi = ((i * 6271) % 997) / 498.5 - 1.0
        ei = ((i * 130363) + 777) / 131069.5 - 1.0
        di = 1.0 if uu >= 0.0 else 0.0
        u[i] = uu
        z[i] = zi
        d[i] = di
        y[i] = 2.0 + uu + 0.5 * zi + 2.0 * di + 0.5 * ei
    return u, z, y, d


def tri_w(u, h):
    return 1.0 - np.abs(u) / h


def port_side(u, z, y, side, order=1):
    """Exactly rdd_design + WLS with kernel weights; returns beta, A, ids."""
    uu = u - C
    mask = ((uu < 0.0) if side < 0 else (uu >= 0.0)) & (np.abs(uu) <= H)
    idx = np.nonzero(mask)[0]
    uc = uu[idx]
    cols = [uc ** (d + 1) for d in range(order)]
    cols.append(z[idx])
    X = np.column_stack([np.ones(len(idx))] + cols)
    w = tri_w(uc, H)
    W = np.diag(w)
    A = X.T @ W @ X
    beta = np.linalg.solve(A, X.T @ (w * y[idx]))
    resid = y[idx] - X @ beta
    return beta, A, X, w, uc, idx, resid


u, z, y, d = build()

print("=" * 74)
print("1. rdrobust Estimate on the exact sec_rdd_var design (h=0.5, kernel=tri)")
print("=" * 74)
np.random.seed(12345)
o = rdrobust(y=y, x=u, c=C, h=H, kernel="tri")
est = o.Estimate
print("Estimate columns:", list(est.columns))
for col in est.columns:
    print("  %-8s %r" % (col, float(est[col].iloc[0])))
print("o.se.rb   =", repr(float(est["se.rb"].iloc[0])))
print("o.se.us   =", repr(float(est["se.us"].iloc[0])))
print("public attrs:", [a for a in dir(o) if not a.startswith("_")])

np.random.seed(12345)
o2 = rdrobust(y=y, x=u, fuzzy=d, c=C, h=H, kernel="tri")
e2 = o2.Estimate
print("\nfuzzy (d given) tau.us/tau.bc/se.us/se.rb:")
for col in e2.columns:
    print("  %-8s %r" % (col, float(e2[col].iloc[0])))

print()
print("=" * 74)
print("2. port estimate on the same design, both cov arms")
print("=" * 74)
bl, Al, Xl, wl, ucl, il, rl = port_side(u, z, y, -1.0)
br, Ar, Xr, wr, ucr, ir, rr = port_side(u, z, y, +1.0)
tau_us = br[0] - bl[0]
print("port tau.us          = %r" % tau_us)

nL = len(il)
nR = len(ir)
vL = np.linalg.inv(Al)[0, 0] * float(np.sum(wl * rl ** 2)) / (nL * nL)
vR = np.linalg.inv(Ar)[0, 0] * float(np.sum(wr * rr ** 2)) / (nR * nR)
print("port homo var        = %r  se = %r" % (vL + vR, np.sqrt(vL + vR)))

# HC0 exactly as sandwich_se_weighted does it: UNWEIGHTED X^T X for M,
# w^2 on the score.
def hc0_port(side):
    beta, A, X, w, uc, idx, resid = side
    M = np.linalg.inv(X.T @ X)
    m = M[0, :]                       # row 0 == col 0 (symmetric)
    mjx = X @ m
    acc = float(np.sum(w ** 2 * mjx ** 2 * resid ** 2))
    return acc


hL = hc0_port(port_side(u, z, y, -1.0))
hR = hc0_port(port_side(u, z, y, +1.0))
print("port HC0 var         = %r  se = %r" % (hL + hR, np.sqrt(hL + hR)))
print("  hc0 L raw = %r" % hL)
print("  hc0 R raw = %r" % hR)
print("  resid L sq-sum = %r" % float(np.sum(rl ** 2)))

print()
print("=" * 74)
print("3. implied bias  (tau.us - tau.bc)  vs candidate closed forms")
print("=" * 74)
tau_bc = float(est["tau.bc"].iloc[0])
tau_rb = float(est["tau.us"].iloc[0])
print("upstream tau.us     = %r" % tau_rb)
print("upstream tau.bc     = %r" % tau_bc)
print("port    tau.us      = %r   (rel gap vs upstream %r)"
      % (tau_us, abs(tau_us - tau_rb) / abs(tau_rb)))
implied = tau_rb - tau_bc
print("implied bias (us-bc)= %r" % implied)

# candidates, per side, using order-1 local linear on x = u - c
def bias_cct(Ainv, uc, w, h, p=1):
    # (p+1)! * [A^{-1}]_{p+1,p+1} * sum(w x^{p+1})
    return float((p + 1) * 2 ** 0 * Ainv[1, 1] * np.sum(w * uc ** (p + 1)))


invL = np.linalg.inv(Al)
invR = np.linalg.inv(Ar)
cands = {
    "Ainv11 * sum(w u^2)": bias_cct(invL, ucl, wl, H) + bias_cct(invR, ucr, wr, H),
    "2*Ainv11*sum(w u^2)": 2 * (bias_cct(invL, ucl, wl, H) + bias_cct(invR, ucr, wr, H)),
}
# normalised-by-h variants (bias should vanish as h -> 0)
for name, fn in [
    ("Ainv11*sum(w u^2)/h", (bias_cct(invL, ucl, wl, H) + bias_cct(invR, ucr, wr, H)) / H),
    ("2*Ainv11*sum(w u^2)/h", 2 * (bias_cct(invL, ucl, wl, H) + bias_cct(invR, ucr, wr, H)) / H),
]:
    cands[name] = fn

for k, v in cands.items():
    print("  %-24s %-24r  rel gap vs implied %r"
          % (k, v, abs(v - implied) / max(abs(implied), 1e-300)))
