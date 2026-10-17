#!/usr/bin/env python3
"""RDD against upstream `rdrobust.rdrobust`, on a design that actually has noise.

WHY THIS GATE EXISTS
====================
`examples/main` carried five estimator slots with an ANALYTIC oracle only and
no upstream gate at all: RDD, PQ, QTE, LPQ and PolicyTree. PQ/QTE/LPQ are gated
in `pyexample_pq.py`, PolicyTree in `pyexample_policytree.py`. RDD was the last
one, and it was left ungated because a measurement found it divergent --
`_verify/RDD_PARITY_1680.md`.

That measurement was taken on a design with NO NOISE, and has since been
withdrawn; see the next section. Re-measured on a design that does, the port's
bias-corrected estimator agrees with rdrobust to 6.2e-15 and its robust SE to
1.9e-15. So RDD is gated here -- on the arm that matches -- and the divergent
arm is reported beside it rather than gated.

THE DESIGN THAT LOOKED NOISY AND WAS NOT
========================================
The first version of the `rdd_var` DGP added a "noise" term
`(i*130363 + 777) / 131069.5 - 1`. That is an exact LINEAR function of `i`, and
`u` is also linear in `i`, so the term was collinear with the running variable
and the local-linear fit absorbed it exactly. Measured: `0.5 * noise` ranged
over `[-0.497, 396.85]` (a ramp, not a bounded shock), and regressing it on
`(1, u)` left a residual ss-sum of `6.9e-24`. The resulting fit residuals were
`1.7e-23`, so the variance was `3.15e-15` -- not the `0.003535` that section was
introduced to produce.

Two conclusions were drawn from those numbers and both have been retracted:
that the port's SE was ~0.03x upstream's, and that `sandwich_se_weighted`
returned a defective zero. On a zero-residual design a sandwich returns zero;
that is the formula working, not failing. `sandwich_se_weighted` is not
defective. It is left alone.

The DGP here uses a multiplicative hash modulo a prime, which is not a linear
function of the index, so the noise is real: residuals are ~1.67e+01 per side.

WHAT IS GATED AND WHAT IS ONLY REPORTED
=======================================
GATED -- the bias-corrected arm, at rdrobust's own defaults on both sides
(`DoubleMLRDD::tau_bc` with `b == h, p = 1, q = 2`; `DoubleMLRDD::tau_bc_se_rb`
with `vce = "nn"`, rdrobust's default):

    tau_bc        vs  rdrobust  tau.bc      measured gap 6.2e-15
    tau_bc_se_rb  vs  rdrobust  se.rb       measured gap 1.9e-15

REPORTED, NOT GATED -- the shipped default arm. `DoubleMLRDD::coef()` / `se()`
are homoskedastic and UNBIAS-CORRECTED, so they are a different estimator from
rdrobust's default, not a worse implementation of the same one:

    homo_coef     vs  rdrobust  tau.us      ~5.9e-3 relative
    homo_se       vs  rdrobust  se.us       ~19x

A gate that required those to match would be permanently red, and a permanently
red gate is either a failing CI or a mute. Both are worse than recording the
divergence. Making the defaults match is a re-specification, not a bug fix, and
`_verify/RDD_PARITY_1680.md` records what it would cost.

WHY NO SEED IS PINNED
=====================
Earlier notes claimed rdrobust is non-deterministic here, with a 2.99e-02
spread over four fits in one process, and that `np.random.seed` must be set.
That could not be reproduced. Measured on THIS design:

    four fits at one seed        tau.bc identical to the last bit
    four fits at four seeds      tau.bc identical to the last bit
    one fit with no seed at all  tau.bc identical to the last bit

The obvious explanation -- that the spread came from bandwidth SELECTION, which
resamples -- is also wrong: letting rdrobust choose `h` (`bwselect='mserd'`)
returns 1.9791848657268085 at all four seeds, spread 0.0e+00. So whatever
produced the original number is not reproduced by anything tried here, and the
honest statement is "unreproduced", not "explained".

No seed is pinned because none is needed. Pinning one would document a hazard
that is not present, and a reader who later removed it would have no way to tell
that the gate never depended on it. The upstream determinism check below is the
control that keeps this honest: if rdrobust ever does become seed-sensitive here,
that control turns red rather than the tolerance quietly absorbing it.

ON THE TOLERANCE
================
The two arms differ only in summation order between two IEEE-754
implementations, and the measured gaps are ~6e-15. `RTOL` sits about four
orders of magnitude above that -- loose enough never to trip on rounding,
tight enough that the smallest structural difference in play (the 2.0e-2 gap
between rdrobust's `tau.us` and `tau.bc`) is nine orders outside it.

FAILS CLOSED: if `moon run` cannot be executed, its output cannot be parsed, the
independently rebuilt design disagrees with the emitter's, or `rdrobust` is not
importable, the verdict is FAIL.
"""

import argparse
import io
import json
import os
import subprocess
import sys
import traceback
import warnings

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))

N = 800
BANDWIDTH = 0.5
CUTOFF = 0.0
KERNEL = "tri"

# ~4 orders of magnitude above the measured 6.2e-15 / 1.9e-15 gaps.
RTOL = 1e-11

# Fingerprint bound. `sum_u` is the sum of a SYMMETRIC grid, so its true value
# is 0 and both sides produce only cancellation noise -- MoonBit gives
# -7.105e-15 where CPython gives exactly 0.0. Comparing that relatively is
# meaningless: `abs(a-b) / max(|a|,|b|)` is 1.0 by construction whenever the
# larger of the two is 0, so the row can never pass. It is therefore bounded
# ABSOLUTELY. 1e-9 is six orders above the noise and still six orders below the
# 400-scale magnitudes the other fingerprint rows carry.
FP_ATOL = 1e-9


def build():
    """`examples/parity`'s `rdd_var` design, rebuilt independently. Integer
    arithmetic only, so CPython and MoonBit construct the same numbers."""
    u = np.empty(N)
    z = np.empty(N)
    y = np.empty(N)
    d = np.empty(N)
    for i in range(N):
        uu = (i + 0.5) / 400.0 - 1.0
        zi = ((i * 6271) % 997) / 498.5 - 1.0
        # Multiplicative hash mod a prime: NOT a linear function of `i`.
        ei = ((i * 2654435761) % 1000003) / 500001.5 - 1.0
        di = 1.0 if uu >= 0.0 else 0.0
        u[i] = uu
        z[i] = zi
        d[i] = di
        y[i] = 2.0 + uu + 0.5 * zi + 2.0 * di + 0.5 * ei
    return u, z, y, d


def run_emitter():
    r = subprocess.run(
        ["moon", "run", "examples/parity", "--target", "native"],
        cwd=HERE, capture_output=True, text=True, timeout=1800,
    )
    if r.returncode != 0:
        raise RuntimeError(
            "moon run examples/parity exited %d: %s"
            % (r.returncode, (r.stderr or r.stdout)[:600])
        )
    return r.stdout


def parse_section(out, name):
    lines = out.splitlines()
    try:
        start = next(i for i, l in enumerate(lines)
                     if l.strip() == "section " + name)
    except StopIteration:
        raise RuntimeError("emitter emitted no section %r" % name)
    vals, data = {}, {}
    for l in lines[start + 1:]:
        s = l.strip()
        if s == "end":
            break
        if s.startswith("val "):
            p = s.split()
            vals[p[1]] = float(p[2])
        elif s.startswith("data "):
            p = s.split()
            data[p[1]] = [float(v) for v in p[3:]]
    return vals, data


def upstream_estimate(y, u):
    from rdrobust import rdrobust
    o = rdrobust(y=y, x=u, c=CUTOFF, h=BANDWIDTH, kernel=KERNEL)
    e = o.Estimate
    return {k: float(e[k].iloc[0]) for k in ("tau.us", "tau.bc", "se.us", "se.rb")}


def close(a, b, rtol, atol=0.0):
    return abs(a - b) <= rtol * max(abs(a), abs(b)) + atol


def rel(a, b):
    d = max(abs(a), abs(b))
    return abs(a - b) / d if d > 0 else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="accepted for symmetry with the other pyexample_* gates")
    ap.add_argument("--json", help="write the measurement record here")
    args = ap.parse_args()

    print("=" * 76)
    print("RDD port vs upstream rdrobust (bias-corrected arm)")
    print("=" * 76)

    try:
        import importlib.metadata as _md
        try:
            _ver = _md.version("rdrobust")
        except Exception:  # noqa: BLE001
            _ver = "(version unknown)"
        print("rdrobust %s" % _ver)
        from rdrobust import rdrobust  # noqa: F401
    except Exception as exc:  # noqa: BLE001
        print("rdrobust is not importable: %r" % (exc,))
        print("\nRESULT: RDD upstream parity: FAIL")
        return 1

    u, z, y, d = build()

    print("\n--- 1. the two constructions of the design ---")
    # A fingerprint, not a class count: `sum_d` alone survives any relabelling.
    fp = {
        "n": float(N),
        "sum_y": float(np.sum(y)),
        "sum_d": float(np.sum(d)),
        "sum_u": float(np.sum(u)),
    }

    out = run_emitter()
    vals, _data = parse_section(out, "rdd_var")

    ok = True
    for k, want in fp.items():
        if k not in vals:
            print("    %-12s MISSING from emitter" % k)
            ok = False
            continue
        got = vals[k]
        same = close(got, want, 1e-12, FP_ATOL)
        print("    %-12s port=%.12f  rebuilt=%.12f  %s"
              % (k, got, want, "ok" if same else "DISAGREE"))
        ok = ok and same

    if not ok:
        print("\nREFUSING to compare: the two constructions of the design "
              "disagree.")
        print("RESULT: RDD upstream parity: FAIL")
        return 1

    # A control on the UPSTREAM side: two fits must agree before any comparison
    # made with this reference is worth reading.
    print("\n--- 2. upstream determinism ---")
    up_a = upstream_estimate(y, u)
    up_b = upstream_estimate(y, u)
    for k in ("tau.bc", "se.rb"):
        same = up_a[k] == up_b[k]
        print("    %-8s two fits identical: %-5s  %.17g" % (k, same, up_a[k]))
        ok = ok and same
    if not ok:
        print("\nREFUSING to compare: upstream is not deterministic on this "
              "design.")
        print("RESULT: RDD upstream parity: FAIL")
        return 1

    print("\n--- 3. GATED: the bias-corrected arm at matched defaults ---")
    gated = [
        ("tau_bc", "tau.bc", "bias-corrected point estimate"),
        ("tau_bc_se_rb", "se.rb", "procedure-(iii) robust SE"),
    ]
    rows = []
    for port_key, up_key, what in gated:
        if port_key not in vals:
            print("    %-14s MISSING from emitter" % port_key)
            ok = False
            continue
        got = vals[port_key]
        want = up_a[up_key]
        r = rel(got, want)
        good = r <= RTOL
        print("    %-14s port %.17g" % (port_key, got))
        print("    %-14s up  %.17g   (%s)" % ("", want, what))
        print("    %-14s rel gap %.3e (bound %.0e)  %s"
              % ("", r, RTOL, "ok" if good else "DISAGREE"))
        ok = ok and good
        rows.append(dict(quantity=port_key, port=got, upstream=want,
                         rel_gap=r, bound=RTOL, agree=bool(good)))

    print("\n--- 4. REPORTED, NOT GATED: the shipped default arm ---")
    print("    `coef()` / `se()` are homoskedastic and uncorrected. That is a")
    print("    different estimator from rdrobust's default, not a worse one.")
    reported = [
        ("homo_coef", "tau.us", "unbiased point estimate"),
        ("homo_se", "se.us", "conventional SE"),
    ]
    for port_key, up_key, what in reported:
        if port_key not in vals:
            print("    %-14s MISSING from emitter" % port_key)
            ok = False
            continue
        got = vals[port_key]
        want = up_a[up_key]
        r = rel(got, want)
        print("    %-14s port %.17g" % (port_key, got))
        print("    %-14s up  %.17g   (%s)" % ("", want, what))
        print("    %-14s rel gap %.3e" % ("", r))
        rows.append(dict(quantity=port_key, port=got, upstream=want,
                         rel_gap=r, bound=None, agree=None))

    if "tau_bc_collapsed" in vals and "tau_bc" in vals:
        print("\n    tau_bc_collapsed %.17g -- NOT the same quantity as"
              % vals["tau_bc_collapsed"])
        print("    tau.bc; the v0.116.0 docstring claims they agree when b == h.")
        print("    Measured here they differ by %.3e, so that sentence is wrong"
              % abs(vals["tau_bc_collapsed"] - vals["tau_bc"]))
        print("    and the test that 'pins' it cannot see the difference.")
        rows.append(dict(quantity="tau_bc_collapsed",
                         port=vals["tau_bc_collapsed"], upstream=None,
                         rel_gap=None, bound=None, agree=None))

    print("\n" + "=" * 76)
    if ok:
        print("RESULT: RDD upstream parity: PASS")
    else:
        print("RESULT: RDD upstream parity: FAIL")
    print("=" * 76)

    if args.json:
        with io.open(args.json, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(dict(agree=bool(ok), n=N, bandwidth=BANDWIDTH,
                           rtol=RTOL, rows=rows), fh, indent=2)
    return 0 if ok else 1


if __name__ == "__main__":
    warnings.filterwarnings("ignore")
    # Every exit path must print a verdict. An unhandled exception used to exit
    # 1 with no `RESULT:` line at all, which a battery reading only the exit
    # code scores as a pass -- so a crash looked identical to a red gate. The
    # traceback still goes to stderr; this only guarantees the verdict exists.
    try:
        _rc = main()
    except Exception:  # noqa: BLE001
        traceback.print_exc()
        print("\nRESULT: RDD upstream parity: FAIL")
        _rc = 1
    sys.exit(_rc)
