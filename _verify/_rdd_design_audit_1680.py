"""Diagnose sec_rdd_var's design, then size a NON-collinear replacement.

Finding under test: the 'noise' term added in the sec_rdd_var increment is an
exact linear function of the index, hence exactly collinear with u, so the
local-linear WLS fits it perfectly and every residual is ~1e-23.
"""
import numpy as np
from rdrobust import rdrobust

N = 800
H = 0.5
C = 0.0


def design_current():
    u = np.empty(N); z = np.empty(N); y = np.empty(N); d = np.empty(N)
    ei_all = np.empty(N)
    for i in range(N):
        uu = (i + 0.5) / 400.0 - 1.0
        zi = ((i * 6271) % 997) / 498.5 - 1.0
        ei = ((i * 130363) + 777) / 131069.5 - 1.0
        di = 1.0 if uu >= 0.0 else 0.0
        u[i] = uu; z[i] = zi; d[i] = di; ei_all[i] = ei
        y[i] = 2.0 + uu + 0.5 * zi + 2.0 * di + 0.5 * ei
    return u, z, y, d, ei_all


def design_fixed():
    """Same skeleton, but the noise uses a multiplicative hash mod a prime,
    so it is NOT a linear function of i."""
    u = np.empty(N); z = np.empty(N); y = np.empty(N); d = np.empty(N)
    for i in range(N):
        uu = (i + 0.5) / 400.0 - 1.0
        zi = ((i * 6271) % 997) / 498.5 - 1.0
        ei = ((i * 2654435761) % 1000003) / 500001.5 - 1.0
        di = 1.0 if uu >= 0.0 else 0.0
        u[i] = uu; z[i] = zi; d[i] = di
        y[i] = 2.0 + uu + 0.5 * zi + 2.0 * di + 0.5 * ei
    return u, z, y, d


def tri_w(u, h):
    return 1.0 - np.abs(u) / h


def port_fit(u, z, y, side, order=1):
    uu = u - C
    mask = ((uu < 0.0) if side < 0 else (uu >= 0.0)) & (np.abs(uu) <= H)
    idx = np.nonzero(mask)[0]
    uc = uu[idx]
    cols = [uc ** (dd + 1) for dd in range(order)] + [z[idx]]
    X = np.column_stack([np.ones(len(idx))] + cols)
    w = tri_w(uc, H)
    A = X.T @ (X * w[:, None])
    beta = np.linalg.solve(A, X.T @ (w * y[idx]))
    resid = y[idx] - X @ beta
    return beta, A, X, w, idx, resid


def report(name, u, z, y, d):
    print("=" * 74)
    print(name)
    print("=" * 74)
    bl, Al, Xl, wl, il, rl = port_fit(u, z, y, -1.0)
    br, Ar, Xr, wr, ir, rr = port_fit(u, z, y, +1.0)
    ssL = float(np.sum(rl ** 2)); ssR = float(np.sum(rr ** 2))
    print("residual sq-sum  L=%.6e  R=%.6e   (n=%d/%d)"
          % (ssL, ssR, len(il), len(ir)))
    print("port tau.us      = %r" % (br[0] - bl[0]))
    nL = float(len(il)); nR = float(len(ir))
    vL = np.linalg.inv(Al)[0, 0] * (wl * rl ** 2).sum() / (nL * nL)
    vR = np.linalg.inv(Ar)[0, 0] * (wr * rr ** 2).sum() / (nR * nR)
    print("port homo se     = %r" % np.sqrt(vL + vR))

    np.random.seed(12345)
    o = rdrobust(y=y, x=u, c=C, h=H, kernel="tri")
    e = o.Estimate
    tau_us = float(e["tau.us"].iloc[0]); tau_bc = float(e["tau.bc"].iloc[0])
    se_us = float(e["se.us"].iloc[0]); se_rb = float(e["se.rb"].iloc[0])
    print("upstream tau.us  = %r" % tau_us)
    print("upstream tau.bc  = %r" % tau_bc)
    print("upstream se.us   = %r" % se_us)
    print("upstream se.rb   = %r" % se_rb)
    print("tau.us gap port/upstream = %.3e"
          % (abs((br[0] - bl[0]) - tau_us) / abs(tau_us)))
    print("bias (us - bc)   = %r" % (tau_us - tau_bc))
    print("se ratio homo/se.us = %.4f   se.rb/se_us = %.4f"
          % (np.sqrt(vL + vR) / se_us, se_rb / se_us))
    print()
    return dict(ssL=ssL, ssR=ssR, tau_us=tau_us, tau_bc=tau_bc,
                se_us=se_us, se_rb=se_rb)


u0, z0, y0, d0, ei0 = design_current()

print("### Is the sec_rdd_var 'noise' collinear with u? ###")
uu = u0
A_lin = np.column_stack([np.ones(N), uu])
coef, *_ = np.linalg.lstsq(A_lin, 0.5 * ei0, rcond=None)
fit_resid = 0.5 * ei0 - A_lin @ coef
print("ei range          = [%.4f, %.4f]" % (ei0.min(), ei0.max()))
print("0.5*ei regressed on (1, u): resid ss-sum = %.6e" % float(np.sum(fit_resid ** 2)))
print("  -> 0.5*ei IS an exact linear function of u; it is signal, not noise")
print("0.5*ei vs u sample: i=0 %.6f  i=400 %.6f  i=799 %.6f"
      % (0.5 * ei0[0], 0.5 * ei0[400], 0.5 * ei0[799]))
print()

r_cur = report("A. CURRENT sec_rdd_var design (claimed 'noisy')", u0, z0, y0, d0)
u1, z1, y1, d1 = design_fixed()
r_new = report("B. FIXED design (multiplicative-hash noise)", u1, z1, y1, d1)
