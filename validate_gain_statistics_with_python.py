"""`gain_statistics`, checked twice: against its own spec and against upstream.

WHAT THIS USED TO BE
====================
The old file built two 2x3 arrays from `np.random.default_rng(2024)`, ran a
numpy transcription of the algorithm on them, printed the results, and then:

    print("Cross-check passes if the MoonBit gain_statistics (tested in")
    print("sensitivity_test.mbt) matches these references within 1e-12")
    print("Gain statistics match: PASS")

Nothing ran MoonBit. The pass message points at a unit test in another file,
which is not a cross-check.

WHAT IT IS NOW
==============
`examples/parity` feeds `gain_statistics` four hand-built coefficient blocks
and emits all sixteen outputs. There is no RNG anywhere in this section, so
CPython recomputes every one of them exactly. This is a BRANCH test, not a
tolerance test.

WHY THE INPUTS LOOK ARBITRARY
============================
`gain_statistics` has six places where a branch can be taken, and random inputs
land on the happy path almost every time. The four blocks are chosen so that
between them every branch is taken at least once:

    block  cf_y                    rho
    -----  ----------------------  -------------------------------------
    c0     clipped HIGH (6.0 -> 1)  interior ratio, positive
    c1     clipped LOW (-0.6 -> 0)  sqrt of a NEGATIVE product -> NaN -> 1.0
    c2     interior (0.5)           clipped HIGH at 1.0, negative sign
    c3     exactly 0 (var_g == 0)   denom == 0 -> 1.0

    cf_d: interior on c0/c1, clipped HIGH on c2/c3.

A random fixture would have exercised the NaN path perhaps once in twenty runs.
This one always does, which is the difference between a test and a smoke test.

TWO INDEPENDENT REFERENCES
==========================
1. `port_spec` -- `sensitivity.mbt` transcribed line by line, including its
   `denom == 0 || denom.is_nan() -> 1.0` convention.
2. `upstream_np` -- the upstream numpy form, which uses
   `np.sqrt(..., where=(var_g > 0) & (var_riesz > 0))` and
   `np.divide(..., out=np.ones_like(...), where=denom != 0)` instead.

These agree on these inputs, and that agreement is itself a row: when
`var_g * var_riesz < 0`, MoonBit takes `sqrt` of a negative (NaN, caught by
`is_nan`) while upstream never evaluates it at all (`where=` mask). Both land
on 1.0, but by different routes -- so a future change to either guard shows up
here as a disagreement between the two references, not as a silent flip.

RUN
===
    python validate_gain_statistics_with_python.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import parity_helper as ph  # noqa: E402

import numpy as np  # noqa: E402

N_COEF = 4
N_REP = 3
VAR_Y = 1.0

# The fixture the emitter uses, written out here so the test states its own
# inputs rather than trusting whatever the emitter claims to have been given.
VAR_RES_LONG = [0.10, 0.11, 0.09, 0.50, 0.52, 0.51, 0.20, 0.21, 0.19, 0.30, 0.31, 0.29]
VAR_RES_SHORT = [0.70, 0.71, 0.69, 0.20, 0.21, 0.19, 0.30, 0.31, 0.29, 0.30, 0.31, 0.29]
NU2_LONG = [0.50, 0.51, 0.49, 0.45, 0.46, 0.44, 0.55, 0.56, 0.54, 0.60, 0.61, 0.59]
NU2_SHORT = [0.40, 0.41, 0.39, 0.30, 0.31, 0.29, 0.20, 0.21, 0.19, 0.25, 0.26, 0.24]
COEF_LONG = [1.00, 1.01, 0.99, 2.00, 2.01, 1.99, 3.00, 3.01, 2.99, 4.00, 4.01, 3.99]
COEF_SHORT = [1.10, 1.11, 1.09, 1.50, 1.51, 1.49, 2.50, 2.51, 2.49, 4.50, 4.51, 4.49]

INPUTS = {
    "var_res_long": VAR_RES_LONG,
    "var_res_short": VAR_RES_SHORT,
    "nu2_long": NU2_LONG,
    "nu2_short": NU2_SHORT,
    "coef_long": COEF_LONG,
    "coef_short": COEF_SHORT,
}

TOL = 1e-15


def clip01(v):
    if v != v:
        return 0.0
    if v < 0.0:
        return 0.0
    if v > 1.0:
        return 1.0
    return v


def median(vals):
    s = sorted(vals)
    n = len(s)
    mid = n // 2
    return s[mid] if n % 2 == 1 else (s[mid - 1] + s[mid]) / 2.0


def port_spec(var_res_l, var_res_s, nu2_l, nu2_s, coef_l, coef_s, var_y):
    """`gain_statistics` transcribed from `sensitivity.mbt`:687-828."""
    n = len(var_res_l)
    n_coef = n // N_REP
    cf_y, cf_d, rho, dtheta = ([0.0] * n_coef for _ in range(4))
    for c in range(n_coef):
        col_cf_y, col_cf_d, col_rho, col_dt = [], [], [], []
        for r in range(N_REP):
            k = c * N_REP + r
            r2_l = 1.0 - var_res_l[k] / var_y
            r2_s = 1.0 - var_res_s[k] / var_y
            r2_riesz = nu2_s[k] / nu2_l[k]

            denom_y = 1.0 - r2_l
            col_cf_y.append(0.0 if denom_y == 0.0
                            else clip01((r2_l - r2_s) / denom_y))
            col_cf_d.append(0.0 if r2_riesz == 0.0
                            else clip01((1.0 - r2_riesz) / r2_riesz))

            dt = coef_s[k] - coef_l[k]
            col_dt.append(dt)

            var_g = var_res_s[k] - var_res_l[k]
            var_riesz = nu2_l[k] - nu2_s[k]
            prod = var_g * var_riesz
            denom = float("nan") if prod < 0.0 else prod ** 0.5
            if denom == 0.0 or denom != denom:
                rho_abs = 1.0
            else:
                rho_abs = clip01(abs(dt) / denom)
            sign_dt = 1.0 if dt > 0.0 else (-1.0 if dt < 0.0 else 0.0)
            col_rho.append(sign_dt * rho_abs)

        cf_y[c] = median(col_cf_y)
        cf_d[c] = median(col_cf_d)
        rho[c] = median(col_rho)
        dtheta[c] = median(col_dt)
    return {"cf_y": cf_y, "cf_d": cf_d, "rho": rho, "delta_theta": dtheta}


def upstream_np(var_res_l, var_res_s, nu2_l, nu2_s, coef_l, coef_s, var_y):
    """Upstream numpy form: `where=` masks instead of an explicit sqrt-of-NaN."""
    vl = np.array(var_res_l).reshape(N_COEF, N_REP)
    vs = np.array(var_res_s).reshape(N_COEF, N_REP)
    nl = np.array(nu2_l).reshape(N_COEF, N_REP)
    ns = np.array(nu2_s).reshape(N_COEF, N_REP)
    cl = np.array(coef_l).reshape(N_COEF, N_REP)
    cs = np.array(coef_s).reshape(N_COEF, N_REP)

    r2_l = 1.0 - vl / var_y
    r2_s = 1.0 - vs / var_y
    r2_riesz = ns / nl

    with np.errstate(invalid="ignore", divide="ignore"):
        cf_y = np.clip((r2_l - r2_s) / (1.0 - r2_l), 0.0, 1.0)
        cf_y = np.nan_to_num(cf_y, nan=0.0)
        cf_d = np.clip((1.0 - r2_riesz) / r2_riesz, 0.0, 1.0)
        cf_d = np.nan_to_num(cf_d, nan=0.0)

        dt = cs - cl
        var_g = vs - vl
        var_riesz = nl - ns
        denom = np.sqrt(np.multiply(var_g, var_riesz),
                        out=np.zeros_like(var_g),
                        where=(var_g > 0) & (var_riesz > 0))
        rho_vals = np.divide(np.absolute(dt), denom,
                             out=np.ones_like(dt), where=denom != 0)
        rho = np.sign(dt) * np.clip(rho_vals, 0.0, 1.0)

    return {"cf_y": np.median(cf_y, axis=1), "cf_d": np.median(cf_d, axis=1),
            "rho": np.median(rho, axis=1), "delta_theta": np.median(dt, axis=1)}


def main() -> int:
    sec = ph.section("gain_statistics")

    rows = [("n_coef", ph.val(sec, "n_coef"), float(N_COEF),
             ph.val(sec, "n_coef") == float(N_COEF))]
    for name, want in INPUTS.items():
        got = ph.data(sec, name)
        same = len(got) == len(want) and all(a == b for a, b in zip(got, want))
        rows.append(("data " + name, len(got), len(want), same))

    spec = port_spec(VAR_RES_LONG, VAR_RES_SHORT, NU2_LONG, NU2_SHORT,
                     COEF_LONG, COEF_SHORT, VAR_Y)
    up = upstream_np(VAR_RES_LONG, VAR_RES_SHORT, NU2_LONG, NU2_SHORT,
                     COEF_LONG, COEF_SHORT, VAR_Y)

    for key in ("cf_y", "cf_d", "rho", "delta_theta"):
        for c in range(N_COEF):
            got = ph.val(sec, "%s_%d" % (key, c))
            want = float(spec[key][c])
            rows.append(("%s[%d] vs port spec" % (key, c), got, want,
                         abs(got - want) <= TOL))
            up_want = float(up[key][c])
            rows.append(("%s[%d] vs upstream" % (key, c), got, up_want,
                         abs(got - up_want) <= TOL))

    print("branches covered by this fixture:")
    print("  cf_y : clipped high on c0, clipped low on c1, interior on c2, "
          "zero on c3")
    print("  cf_d : interior on c0/c1, clipped high on c2/c3")
    print("  rho  : interior on c0, sqrt-of-negative on c1, clip-high on c2, "
          "denom==0 on c3")
    print()
    print("%-4s %-14s %-14s %-14s %-14s" % ("coef", "cf_y", "cf_d", "rho",
                                            "delta_theta"))
    for c in range(N_COEF):
        print("%-4d %-14.10g %-14.10g %-14.10g %-14.10g"
              % (c, spec["cf_y"][c], spec["cf_d"][c], spec["rho"][c],
                 spec["delta_theta"][c]))
    print()
    print("port spec vs upstream numpy form, max gap over all 16 outputs: %.3g"
          % max(abs(float(spec[k][c]) - float(up[k][c]))
                for k in spec for c in range(N_COEF)))
    print()

    return ph.report("gain_statistics parity", rows, ok=True)


if __name__ == "__main__":
    sys.exit(main())
