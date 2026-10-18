#!/usr/bin/env python3
"""LPLR against upstream `DoubleMLLPLR` on the EXAMPLE'S OWN rows.

WHAT THIS REPLACES
==================
`validate_lplr_with_python.py` does compare `examples/lplr` to upstream, but
the comparison cannot see the estimator. Measured:

  * it fits upstream on `build_simplified_lzz2020` -- a numpy DGP -- and
    compares against the example's `chacha8_rng` numbers. Different datasets.
  * it then attributes the resulting gap to upstream noise (theta sd 0.198
    over 7 refits) and widens the band to `3 * max(se)` floored at 0.10,
    i.e. ~0.81 here.
  * On FIXED data with the partition re-drawn per seed, the same fold draw
    moves theta by sd 0.308 (min 0.154, max 1.155 around a true alpha 0.5).
    So the width is legitimately demanded by the fold draw -- but it is
    spent on noise that can be REMOVED instead of absorbed.

Upstream accepts an externally supplied partition; writing `_smpls` and
`_smpls_inner` and refitting gives BIT-IDENTICAL output (|dcoef| = 0.000e+00).
That is what makes a tight gate possible here at all.

WHAT IS COMPARED
================
`lplr_match_*` -- the port fitted with `ml_g` = LinearRegression and
`ml_m` = LogisticRegression, which mirrors upstream's own
`LinearRegression` / `LogisticRegression` pairing.

The port's DEFAULTS are `linear_regression()` for BOTH slots, so its `ml_M`
(whose target is a probability) is fitted by OLS. Upstream cannot mirror
that at all: `_check_learner(ml_M, regressor=False, classifier=True)`
rejects a regressor outright. Comparing the default configuration would
therefore measure the LEARNER CHOICE, not the estimator. The default
configuration is still emitted, so that effect stays visible.

The residual the band must absorb is the INNER split: the port's
`set_sample_splitting` replaces the outer partition only (`lplr.mbt:1630`),
so its inner draw still comes from `self.seed + r * 1000 + 7`. Both sides'
inner spreads are MEASURED here and the band is built from them, not from
an assumption about their size.

FAILS CLOSED. If `moon run` cannot be executed or its output cannot be
parsed, the verdict is FAIL.
"""

import argparse
import io
import json
import os
import re
import subprocess
import sys
import warnings

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))

# Band width in units of the combined measured spread. The fold split is the
# only remaining source of run-to-run movement on both sides; 3 is the usual
# "could easily happen by chance" width.
BAND_SIGMA = 3.0

# Number of INNER partitions used to measure each side's spread. The inner
# split only perturbs `prelim_beta_per_fold` (the Newton starting value), so
# this is a small correction, not the dominant term -- the outer draw was.
N_INNER_SEEDS = 5


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
    """Pull one `section <name>` ... `end` block out of the emitter output."""
    lines = out.splitlines()
    try:
        start = next(i for i, l in enumerate(lines) if l.strip() == "section " + name)
    except StopIteration:
        raise RuntimeError("emitter emitted no section %r" % name)
    vals, by_name = {}, {}
    for l in lines[start + 1:]:
        s = l.strip()
        if s == "end":
            break
        if s.startswith("val "):
            parts = s.split()
            vals[parts[1]] = float(parts[2])
        elif s.startswith("data "):
            parts = s.split()
            n = int(parts[2])
            arr = np.array([float(v) for v in parts[3:3 + n]], dtype=float)
            if len(arr) != n:
                raise RuntimeError(
                    "data %s declared %d values, got %d" % (parts[1], n, len(arr))
                )
            by_name[parts[1]] = arr
    if not vals:
        raise RuntimeError("section %r emitted no values" % name)
    return vals, by_name


def upstream_fit(x, y, d, fold_id, n_folds_inner, inner_seed, score):
    """Upstream `DoubleMLLPLR` on the emitted rows and the emitted partition."""
    from sklearn.linear_model import LinearRegression, LogisticRegression
    from doubleml.plm import DoubleMLLPLR
    from doubleml.data import DoubleMLData

    n, p = x.shape
    cols = ["x%d" % (j + 1) for j in range(p)]
    df = pd.DataFrame(np.column_stack([x, y, d]), columns=cols + ["y", "d"])
    obj = DoubleMLData(df, "y", "d", cols)

    outer = []
    for f in range(int(fold_id.max()) + 1):
        test = np.where(fold_id == f)[0]
        train = np.where(fold_id != f)[0]
        outer.append((train, test))

    # Inner splits are nested per OUTER FOLD and partition that fold's
    # TRAINING rows (measured from upstream's own drawn structure).
    inner_per_outer = []
    for fi, (train, _test) in enumerate(outer):
        rng = np.random.default_rng(inner_seed + 1000 * fi)
        perm = rng.permutation(len(train))
        folds = []
        for k in range(n_folds_inner):
            sel = perm[k::n_folds_inner]
            itr = train[np.sort(sel)]
            ite = train[np.sort(np.setdiff1d(perm, sel))]
            folds.append((itr, ite))
        inner_per_outer.append(folds)

    m = DoubleMLLPLR(
        obj,
        ml_M=LogisticRegression(C=1e6, max_iter=500, solver="lbfgs"),
        ml_t=LinearRegression(),
        ml_m=LogisticRegression(C=1e6, max_iter=500, solver="lbfgs"),
        ml_a=LogisticRegression(C=1e6, max_iter=500, solver="lbfgs"),
        n_folds=len(outer),
        n_folds_inner=n_folds_inner,
        score=score,
        draw_sample_splitting=False,
    )
    m._smpls = [outer]
    m._smpls_inner = [inner_per_outer]
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        m.fit()
    return float(m.coef[0]), float(m.se[0])


def print_report_smalln(out):
    """Re-measure the SMALL-N divergence on every run. Reported, not gated.

    Sections 1-4 are all at the example's n = 500, where the port and upstream
    agree to ~0.007. That is one design point, and the small-n ones are not all
    the same kind of problem.

    MEASURED at `8da9915`, on identical rows and the identical outer partition:

        n=60   port -0.0491291  se 0.762404   | upstream  3.53962   se 20.1991
        n=100  port 14.431      se 751657     | upstream -0.558127  se 0.832026
        n=160  port  0.580578   se 0.777112   | upstream  0.749398  se 0.587901

    Note the direction REVERSES. At n=60 the port is the well-behaved one
    (se 0.76) and upstream is the pathological one (se 20.2, coefficient 3.54
    against a true effect near 0.5). At n=100 it is the reverse: the port is
    the broken one (se 7.5e5, one warning) and upstream is sane. At n=160 both
    are finite and well-conditioned but 29% apart. So there is no single
    "the port diverges at small n" story to match -- the two implementations
    fail in OPPOSITE directions at different n, which is why reconciling them
    is not one fix.

    CORRECTION. This docstring previously read "the port returns -3.3e6 and
    -1.1e6 where upstream returns 3.54 and -0.558". The upstream half was
    right; the port half described a build from BEFORE D4. Section 12 showed a
    reported -3.3e6 is arithmetically unreachable by `theta` (Newton clamps
    each step to 0.25 over 50 iterations, and the start `sum(d*t_pred)/sum(d^2)`
    is bounded by `|t_pred| <= 37`), which is only consistent with the number
    never having been `theta`: the pre-D4 re-derivation, not the root, was
    producing the 1e6. D4 made the point estimate `theta` itself (v0.163.0).
    The section 11/12 records of -3.3e6 are history and stay as history; this
    live comment described current behaviour and did not.

    A control arm against `bb38642~1` and `c744fc4` shows the small-n
    divergence is PRE-EXISTING, and upstream's own `m_hat` conditioning (D1)
    makes it worse rather than better -- so neither is the cause.

    Why report instead of gate: the number is a real divergence and gating it
    would be a permanently-red gate, which this repo treats as worse than no
    gate. What is gated is that the port still agrees with upstream where it is
    expected to; this line makes sure nobody has to REMEMBER that there is a
    regime where it does not.

    An upstream fit that raises is printed as ERROR and never counted as
    agreement -- a crash is not a measurement.
    """
    sections = []
    cur = None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("section lplr_smalln_"):
            cur = {"name": s.split(None, 1)[1], "val": {}, "data": {}}
            sections.append(cur)
            continue
        if cur is None:
            continue
        if s == "end":
            cur = None
            continue
        if s.startswith("val "):
            p = s.split()
            cur["val"][p[1]] = float(p[2])
        elif s.startswith("data "):
            p = s.split()
            k = int(p[2])
            arr = np.array([float(v) for v in p[3:3 + k]], dtype=float)
            if len(arr) == k:
                cur["data"][p[1]] = arr
    if not sections:
        print("    NO smalln sections in the emitter output -- skip")
        return
    print("    On identical rows and the identical outer partition:")
    for sec in sections:
        n = int(sec["val"]["n"])
        pcols = int(sec["val"]["p"])
        x = sec["data"]["x"].reshape(n, pcols)
        y = sec["data"]["y"]
        d = sec["data"]["d"]
        fold = sec["data"]["fold"]
        pc = sec["val"]["port_coef"]
        pw = int(sec["val"]["port_n_warn"])
        print("      n=%-4d port coef=%-16.6g se=%-14.6g warn=%d"
              % (n, pc, sec["val"]["port_se"], pw))
        try:
            uc, us = upstream_fit(x, y, d, fold, 2, 7000, "nuisance_space")
            ratio = abs(pc) / max(abs(uc), 1e-12)
            print("              upstream coef=%-12.6g se=%-14.6g  ratio=%.4g %s"
                  % (uc, us, ratio,
                     "<-- DIVERGES" if ratio > 100.0 else ""))
        except Exception as e:
            print("              upstream ERROR %s: %s" % (type(e).__name__, str(e)[:90]))
    print("    Recorded, not gated: _verify/LPLR_GATE_BLINDNESS_1680.md section 11.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="accepted for symmetry with the other pyexample_* gates")
    ap.add_argument("--json", help="write the measurement record here")
    args = ap.parse_args()

    print("=" * 76)
    print("LPLR vs upstream DoubleMLLPLR -- same rows, same outer partition")
    print("=" * 76)

    out = run_emitter()
    vals, by_name = parse_section(out, "lplr_upstream")

    n = int(vals["lplr_n"])
    p = int(vals["lplr_p"])
    x = by_name["lplr_x"].reshape(n, p)
    y = by_name["lplr_y"]
    d = by_name["lplr_d"]
    fold_id = by_name["lplr_fold"].astype(int)

    # Self-check: the emitter must have reproduced the example's own fit.
    # Its printed `theta_hat` is 0.46033435469463013; if the replication in
    # `sec_lplr_upstream` ever drifts this stops matching and the whole
    # comparison is measuring something else.
    #
    # MOVED TWICE, both deliberately, and both verified against TWO independent
    # sources -- the `examples/lplr` printout and the `sec_lplr_upstream`
    # emission -- before each re-pin. That is the point of this check: it is a
    # replication check, so a pin may move only when the thing it replicates
    # has itself moved on purpose.
    #
    #   0.46411015764901836  OLS default `ml_m`, `m_pred = a_pred`
    #   0.3874127183029159  logistic default + the upstream `Y == 0`
    #                        conditioning -- HELD OFF, see the `m_pred` block
    #                        in `lplr.mbt`
    #   0.46403803469979032  logistic default, conditioning held off
    #   0.46033435469463013  logistic default + D2/D3 (v0.163.0)  <-- here
    #
    # The v0.163.0 move is not a re-pin in the usual sense: the value moved
    # because the PORT changed, not because the example's DGP drifted. D2
    # gives `W_inner` the inner cross-fit of ml_M (upstream
    # `plm/lplr.py:318`) and D3 keeps `beta` per-observation (`:315-323`,
    # `:345`) instead of averaging it to a scalar (`:326`). The example's
    # rows are untouched. v0.163.4: this used to read "which is what this
    # check exists to confirm". It does not -- the check compares
    # `lplr_ns_theta` and says nothing about x/y/d. What it pins is the
    # port's ANSWER, which is exactly what a port-side behaviour change moves.
    expected = 0.46033435469463013
    got = vals["lplr_ns_theta"]
    selfcheck = abs(got - expected) <= 1e-15
    print("")
    print("--- 0. the emitter reproduces the example's FIT ---")
    print("    lplr_ns_theta = %.17g" % got)
    print("    example prints %.17g" % expected)
    print("    identical: %s" % selfcheck)
    if not selfcheck:
        # v0.163.4: this used to read "REFUSING to compare: the fixture is not
        # the example's data". Measured 2026-10-18, that pointed at the wrong
        # half: switching on upstream's `Y == 0` `ml_m` conditioning left the
        # rows BIT-IDENTICAL and moved `lplr_ns_theta` by -0.0467. The check is
        # on the port's OUTPUT, so it cannot tell the two causes apart -- name
        # both rather than assert the wrong one.
        print("    REFUSING to compare. `identical:` is false, which has TWO"
              " causes needing")
        print("    different responses, and this check cannot tell them apart:")
        print("      * the ROWS moved   -> a DGP / seed / fixture change")
        print("      * the ANSWER moved -> a behaviour change to the port")
        print("    Decide by asking whether the change was to the port or to"
              " the example,")
        print("    not by this message. All four re-pins above were the second.")
        print("LPLR upstream parity: FAIL")
        return 1

    n_folds_inner = 2
    port = {
        "nuisance_space": [vals["lplr_match_seed%d" % (3141 + i)] for i in range(N_INNER_SEEDS)],
        "instrument": [vals["lplr_match_in_seed%d" % (3141 + i)] for i in range(N_INNER_SEEDS)],
    }

    print("")
    print("--- 1. port inner-split spread (outer partition held fixed) ---")
    for sc in ("nuisance_space", "instrument"):
        v = np.array(port[sc], dtype=float)
        print("    %-14s n=%d mean=%.6f sd=%.6f" % (sc, len(v), v.mean(), v.std(ddof=1)))

    print("")
    print("--- 2. upstream on the SAME rows and the SAME outer partition ---")
    up = {}
    for sc in ("nuisance_space", "instrument"):
        seeds = [7000 + 13 * i for i in range(N_INNER_SEEDS)]
        coefs, ses = [], []
        for s in seeds:
            c, e = upstream_fit(x, y, d, fold_id, n_folds_inner, s, sc)
            coefs.append(c)
            ses.append(e)
        up[sc] = dict(coef=np.array(coefs), se=np.array(ses))
        print("    %-14s coef mean=%.6f sd=%.6f  se mean=%.6f"
              % (sc, np.mean(coefs), np.std(coefs, ddof=1), np.mean(ses)))

    print("")
    print("--- 3. comparison ---")
    ok = True
    rows = []
    for sc in ("nuisance_space", "instrument"):
        port_v = np.array(port[sc], dtype=float)
        up_v = up[sc]["coef"]
        sd_port = port_v.std(ddof=1)
        sd_up = up_v.std(ddof=1)
        band = BAND_SIGMA * float(np.hypot(sd_port, sd_up))
        gap = abs(port_v.mean() - up_v.mean())
        within = gap < band
        print("    %-14s port=%.6f upstream=%.6f  gap=%.6f  band=%.6f -> %s"
              % (sc, port_v.mean(), up_v.mean(), gap, band, "OK" if within else "OUT"))
        print("        (band = %.1f * sqrt(sd_port^2 + sd_up^2) = %.1f*sqrt(%.6f^2+%.6f^2))"
              % (BAND_SIGMA, BAND_SIGMA, sd_port, sd_up))
        rows.append(dict(score=sc, port=float(port_v.mean()), upstream=float(up_v.mean()),
                         gap=gap, band=band, sd_port=float(sd_port), sd_up=float(sd_up),
                         within=bool(within)))
        if not within:
            ok = False

    print("")
    print("--- 4. standard error, reported not asserted ---")
    print("    The SE comparison is reported, not gated: the two sides use")
    print("    different variance implementations (the port's linear-score")
    print("    path vs upstream's `_var_est`), and n=5 draws cannot resolve a")
    print("    small systematic difference from the inner-split spread.")
    for sc in ("nuisance_space", "instrument"):
        port_se = vals["lplr_match_ns_se"] if sc == "nuisance_space" else vals["lplr_match_in_se"]
        print("    %-14s port se=%.6f  upstream se mean=%.6f  ratio=%.4f"
              % (sc, port_se, up[sc]["se"].mean(),
                 port_se / up[sc]["se"].mean()))

    print("")
    print("--- 5. small-n regime: a KNOWN divergence, reported not asserted ---")
    print_report_smalln(out)

    print("")
    print("LPLR upstream parity: %s" % ("PASS" if ok else "FAIL"))
    if args.json:
        with io.open(args.json, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(dict(selfcheck=bool(selfcheck), rows=rows,
                           port_default=dict(ns_theta=vals["lplr_ns_theta"],
                                             ns_se=vals["lplr_ns_se"],
                                             in_theta=vals["lplr_in_theta"],
                                             in_se=vals["lplr_in_se"])),
                      fh, indent=2)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
