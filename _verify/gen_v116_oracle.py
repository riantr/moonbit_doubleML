"""Oracle probe for moonbit_doubleML v0.116.0 (RDD `vce = "nn"`).

Emits golden values from the upstream Python port of `rdrobust`
(`rdpackages/rdrobust`, `Python/rdrobust/src/rdrobust/`) for:

  1. `nn_residual`      -- cross-checked against `_nn_residuals_jit` directly
  2. `tau_bc_se_nn`     -- cross-checked against `rdrobust(vce="nn")` `.se.bc`
  3. the HC0 sibling    -- cross-checked against `rdrobust(vce="hc0")` `.se.bc`

The DGP is a closed-form function of the observation index so that
MoonBit can regenerate byte-identical inputs without sharing a file.

Run from `_verify/`:
    python gen_v116_oracle.py
"""

import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "_oracle"))

from rdrobust.rdrobust import rdrobust  # noqa: E402
from rdrobust.funs import _nn_residuals_jit  # noqa: E402


# --------------------------------------------------------------------------
# Deterministic DGP, mirrored exactly in expand_v116_test.mbt
# --------------------------------------------------------------------------
N = 240


def _lcg(i: int, salt: int) -> float:
    s = (1103515245 * (i + 1) + salt) % 2147483648
    return s / 2147483648.0


def dgp():
    x = np.empty(N, dtype=np.float64)
    y = np.empty(N, dtype=np.float64)
    for i in range(N):
        jitter = 0.004 * (_lcg(i, 12345) - 0.5)
        xi = -1.0 + 2.0 * i / (N - 1) + jitter
        eps = (_lcg(i, 777) - 0.5) * 1.2
        # Asymmetric curvature: a symmetric c makes the per-side
        # polynomial-order bias cancel in xi_r - xi_l, so the fixture
        # cannot distinguish order 1 from order 2 (v0.115.0 lesson).
        curv = 0.35 if xi < 0.0 else 0.95
        yi = 0.30 + 0.70 * xi + curv * xi * xi + (0.55 if xi >= 0.0 else 0.0) + eps
        x[i] = xi
        y[i] = yi
    return x, y


# --------------------------------------------------------------------------
# 1. The nn-residual kernel, straight from _nn_residuals_jit
# --------------------------------------------------------------------------
def _dups_arrays(xs):
    """The mass-point bookkeeping `rdrobust` builds at rdrobust.py:815-822.

    `dups[i]` is the size of i's equal-x group and `dupsid[i]` its
    1-based offset WITHIN that group. It is NOT `arange(1, n+1)`: for a
    run of distinct x every entry is 1, and getting that wrong silently
    shifts every neighbourhood after the second observation while leaving
    the first two correct -- a fixture bug that looks like an algorithm
    bug.
    """
    import pandas as pd
    aux = pd.DataFrame({"nn": np.ones(len(xs)), "X": xs})
    dups = aux.groupby("X")["nn"].transform("sum").values.astype(np.int64)
    dupsid = aux.groupby("X")["nn"].transform("cumsum").values.astype(np.int64)
    return dups, dupsid


def nn_probe(x, y):
    """Run the upstream jit kernel on small slices of the real DGP."""
    out = {}
    # A left-side window slice, already ascending in x.
    idx = np.where((x < 0.0) & (x >= -0.42))[0]
    xs = np.ascontiguousarray(x[idx], dtype=np.float64)
    ys = np.ascontiguousarray(y[idx], dtype=np.float64)
    dups, dupsid = _dups_arrays(xs)
    for mm in (1, 2, 3, 5):
        res = _nn_residuals_jit(
            xs, ys,
            np.zeros(len(xs)), np.zeros((len(xs), 0)),
            dups, dupsid, mm, 0, 0, len(xs),
        )
        out["left_n%d" % mm] = [float(v) for v in res[:, 0]]
    # A deliberately duplicated-x slice to exercise the mass-point walk.
    xs2 = np.array([0.01, 0.01, 0.02, 0.05, 0.05, 0.05, 0.09, 0.11, 0.20, 0.30],
                   dtype=np.float64)
    ys2 = np.array([1.0, 1.4, 2.0, 3.0, 3.3, 3.9, 4.1, 4.4, 5.0, 6.0],
                   dtype=np.float64)
    d2, di2 = _dups_arrays(xs2)
    res2 = _nn_residuals_jit(
        xs2, ys2, np.zeros(len(xs2)), np.zeros((len(xs2), 0)),
        d2, di2, 3, 0, 0, len(xs2),
    )
    out["masspoint"] = [float(v) for v in res2[:, 0]]
    return out


# --------------------------------------------------------------------------
# 2/3. Full rdrobust with pinned bandwidths
# --------------------------------------------------------------------------
def full_probe(x, y, h, b):
    """Golden values for the three `rdrobust` procedures.

    Field layout, read off rdrobust.py:1129-1170 rather than guessed:
        coef = [conventional, bias-corrected, robust]  with rows 2 and 3
               sharing the SAME point estimate
        se   = [se_conventional, se_conventional, se_robust]
        tau_cl / tau_bc / bias are the PER-SIDE [left, right] vectors
               (rdrobust.py:1205-1206), not scalars
    """
    res = {}
    for vce in ("nn", "hc0", "hc1", "hc2"):
        est = rdrobust(
            y=y, x=x, c=0.0, p=1, q=2, h=h, b=b,
            kernel="tri", bwselect="", vce=vce, nnmatch=3, all=True,
        )
        est = np.asarray(est).ravel()[0]
        coef = [float(v) for v in np.asarray(est.coef).ravel()]
        se = [float(v) for v in np.asarray(est.se).ravel()]
        vl = np.asarray(est.V_rb_l, dtype=np.float64).reshape(2, 2)
        vr = np.asarray(est.V_rb_r, dtype=np.float64).reshape(2, 2)
        res[vce] = {
            # procedures (i), (ii), (iii)
            "tau_conv": coef[0],
            "tau_bc": coef[1],
            "tau_rob": coef[2],
            "se_conv": se[0],
            "se_bc": se[1],
            "se_rb": se[2],
            # per-side limits
            "xi_cl_l": float(np.asarray(est.tau_cl).ravel()[0]),
            "xi_cl_r": float(np.asarray(est.tau_cl).ravel()[1]),
            "xi_bc_l": float(np.asarray(est.tau_bc).ravel()[0]),
            "xi_bc_r": float(np.asarray(est.tau_bc).ravel()[1]),
            "bias_l": float(np.asarray(est.bias).ravel()[0]),
            "bias_r": float(np.asarray(est.bias).ravel()[1]),
            # the procedure (iii) sandwich, per side
            "V_rb_l": [[float(v) for v in row] for row in vl],
            "V_rb_r": [[float(v) for v in row] for row in vr],
            "N_h": [int(v) for v in np.asarray(est.N_h).ravel()],
            "N_b": [int(v) for v in np.asarray(est.N_b).ravel()],
        }
        # Self-consistency of the oracle itself: the reported robust SE must
        # be the root-sum of the two per-side sandwich diagonals.
        chk = math.sqrt(res[vce]["V_rb_l"][0][0] + res[vce]["V_rb_r"][0][0])
        res[vce]["se_rb_from_V"] = chk
    return res


def main():
    x, y = dgp()
    out = {
        "n": N,
        "nn": nn_probe(x, y),
        "h_eq_b": full_probe(x, y, 0.30, 0.30),
        "h_ne_b": full_probe(x, y, 0.30, 0.42),
    }
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "_v116_golden.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=1)

    # Console summary -- the full nn arrays are long, so only show heads.
    print("wrote", path)
    for k, v in out["nn"].items():
        head = ", ".join("%.12g" % t for t in v[:5])
        print("  nn.%-9s n=%-3d first5=[%s]" % (k, len(v), head))
    for band in ("h_eq_b", "h_ne_b"):
        print(" ", band)
        for vce, r in out[band].items():
            print("    %-4s tau_conv=%+.10f tau_bc=%+.10f | se_conv=%.10f "
                  "se_rb=%.10f (sqrt(V)=%.10f)"
                  % (vce, r["tau_conv"], r["tau_bc"], r["se_conv"],
                     r["se_rb"], r["se_rb_from_V"]))


if __name__ == "__main__":
    main()