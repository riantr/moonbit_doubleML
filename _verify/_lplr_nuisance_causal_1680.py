"""CAUSAL TEST: is the port's LPLR divergence caused by its NUISANCE VALUES?

Section 25h exonerated the FORMULA: the validated Python Newton, fed upstream's
own nuisances on fuzz trial 2's rows, reproduced upstream's coefficient to
|diff| = 0. That leaves exactly two suspects --

    (A) the nuisance VALUES the port feeds the Newton (t_pred, m_pred, a_pred,
        beta), and
    (B) the way the port ITERATES (start value, clamp, iteration cap).

A row-by-row diff cannot separate them: the two sides draw different partitions,
so upstream's `t_hat[i]` and the port's `t_pred[i]` are predictions from
different models and were never comparable.

This separates them by CAUSALITY instead. The port's own four arrays were dumped
from the shipped build on trial 2's rows (`_port_dump_1680.log`, produced by
`_lplr_pickdump_1680.py`, matched to trial 2 by exact row equality). Feeding
THOSE to upstream's own solver -- the solver section 25h proved reproduces
upstream exactly -- answers (A) directly:

    all-port nuisances diverge   -> (A) confirmed. The values are the cause,
                                    and the four arrays can be bisected.
    all-port nuisances converge  -> (A) exonerated, and (B) is the cause.

Either outcome is decisive, so the probe reports both rather than stopping at
the expected one.

Then the 16-cell swap: for each nuisance, take it from the port or from upstream,
holding the rest fixed. That names WHICH array is responsible instead of only
saying "the nuisances".

Two things this probe deliberately does NOT do:

  * It does not compare coefficients to upstream's. Different partitions mean
    different estimates; the question here is stability, not agreement.
  * It does not use the port's clamp. `newton_trace` is deliberately unclamped,
    so what is being tested is whether the port's values are intrinsically
    solvable, not whether the clamp rescues them.

Run: python _verify/_lplr_nuisance_causal_1680.py
"""

import itertools
import os
import re
import sys
import warnings

import numpy as np
import pandas as pd

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)
sys.path.insert(0, os.path.join(REPO, "_verify"))
from _lplr_env_1680 import use_vendored_upstream  # noqa: E402
use_vendored_upstream()
sys.path.insert(0, os.path.join(REPO, "_verify"))

from _lplr_bag_direction_1680 import (  # noqa: E402
    logit, newton_trace, score_terms, variance,
)

from _lplr_env_1680 import PORT_DUMP  # noqa: E402
KEYS = ("x", "y", "d", "t", "m", "a", "b")
# A coefficient past this magnitude is not a root, it is a runaway: the
# unclamped port was measured at th = -440 and th = 139.8 on these very rows.
DIVERGENT = 50.0


def parse_blocks(path):
    """Every `PORTMETA block=..` plus its seven `data port_lplr_*` lines."""
    lines = open(path, encoding="utf-8").read().splitlines()
    blocks = []
    i = 0
    while i < len(lines):
        m = re.match(r"PORTMETA block=(\d+) n=(\d+) p=(\d+) seed=(\d+)", lines[i].strip())
        if not m:
            i += 1
            continue
        rec = {"block": int(m.group(1)), "n": int(m.group(2)),
               "p": int(m.group(3)), "seed": int(m.group(4))}
        j = i + 1
        # Terminate on the keys actually needed, not on a sentinel count.
        while j < len(lines) and not all(k in rec for k in KEYS):
            parts = lines[j].strip().split()
            if len(parts) >= 3 and parts[0] == "data" and parts[1].startswith("port_lplr_"):
                key = parts[1][len("port_lplr_"):]
                k = int(parts[2])
                arr = [float(v) for v in parts[3:3 + k]]
                if len(arr) != k:
                    break
                rec[key] = np.array(arr, dtype=float)
            j += 1
        if all(k in rec for k in KEYS):
            blocks.append(rec)
        i = j
    return blocks


def upstream_nuisances(x, y, d, p):
    """Upstream's own t_hat / m_hat / a_hat / beta on these rows, pinned."""
    import doubleml.plm.lplr as lplr_mod
    from sklearn.linear_model import LinearRegression, LogisticRegression
    from doubleml.plm import DoubleMLLPLR
    from doubleml.data import DoubleMLData

    def mk():
        return LogisticRegression(C=1e6, max_iter=500, solver="lbfgs")

    orig_d, orig_c = lplr_mod._double_dml_cv_predict, lplr_mod._dml_cv_predict
    cap = {"cv": []}

    def spy_d(estimator, name, *a, **kw):
        r = orig_d(estimator, name, *a, **kw)
        cap[name] = r
        cap.setdefault("smpls", kw.get("smpls"))
        return r

    def spy_c(estimator, xx, yt, **kw):
        r = orig_c(estimator, xx, yt, **kw)
        cap["cv"].append((type(estimator).__name__, r))
        return r

    lplr_mod._double_dml_cv_predict = spy_d
    lplr_mod._dml_cv_predict = spy_c
    try:
        cols = ["x%d" % (j + 1) for j in range(p)]
        df = pd.DataFrame(np.column_stack([x, y, d]), columns=cols + ["y", "d"])
        obj = DoubleMLData(df, "y", "d", cols)
        np.random.seed(20260824)
        mdl = DoubleMLLPLR(obj, ml_M=mk(), ml_t=LinearRegression(), ml_m=mk(),
                          ml_a=mk(), n_folds=2, n_folds_inner=2,
                          score="nuisance_space", draw_sample_splitting=True)
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            mdl.fit()
        coef, se = float(mdl.coef[0]), float(mdl.se[0])
    finally:
        lplr_mod._double_dml_cv_predict = orig_d
        lplr_mod._dml_cv_predict = orig_c

    smpls = []
    for e in cap["smpls"]:
        if isinstance(e, (tuple, list)) and len(e) == 2 and not isinstance(e[0], (tuple, list)):
            smpls.append(e)
        elif isinstance(e, (tuple, list)):
            smpls.extend(list(e))

    m_hat = t_hat = None
    for ename, res in cap["cv"]:
        if "LogisticRegression" in ename and m_hat is None:
            m_hat = np.asarray(res["preds"]).ravel()
        elif "LinearRegression" in ename and t_hat is None:
            t_hat = np.asarray(res["preds"]).ravel()
    a_hat = np.asarray(cap["ml_a"]["preds"]).ravel()
    M_in = [np.asarray(v).ravel() for v in cap["ml_M"]["preds_inner"]]
    a_in = [np.asarray(v).ravel() for v in cap["ml_a"]["preds_inner"]]

    beta = np.zeros(len(d))
    for i, (tr, te) in enumerate(smpls):
        w = logit(M_in[i][tr])
        dt = (d - a_in[i])[tr]
        beta[te] = np.sum(dt * w) / np.sum(dt ** 2)

    return {"t": t_hat, "m": m_hat, "a": a_hat, "b": beta}, coef, se


def solve(theta0, y, d, t, m, a, b):
    """Run the validated Newton on one nuisance combination."""
    r_hat = t - b * a
    with np.errstate(over="ignore", invalid="ignore"):
        th, trace, why = newton_trace(theta0, y, d, r_hat, m, b, a)
        psi, pdf = score_terms(th, y, d, r_hat, m, b, a)
        v = variance(psi, pdf)
    se = float(np.sqrt(v)) if np.isfinite(v) else float("nan")
    return th, why, se


def main():
    blocks = parse_blocks(PORT_DUMP)
    if not blocks:
        raise SystemExit("no blocks in %s" % PORT_DUMP)
    print("port fit(s) on trial 2's rows : %s" % [b["block"] for b in blocks])

    blk0 = blocks[0]
    n, p = blk0["n"], blk0["p"]
    x = blk0["x"].reshape(n, p)
    y, d = blk0["y"], blk0["d"]
    for b in blocks[1:]:
        assert np.array_equal(b["x"], blk0["x"]) and np.array_equal(b["y"], y) \
            and np.array_equal(b["d"], d), "blocks disagree on rows"

    up, up_coef, up_se = upstream_nuisances(x, y, d, p)
    print("rows: n=%d p=%d seed=%d" % (n, p, blk0["seed"]))
    print("")
    print("=== upstream, pinned partition ===")
    print("    coef=%.6f  se=%.6f   (finite: %s)"
          % (up_coef, up_se, np.isfinite(up_coef) and np.isfinite(up_se)))
    th_u, why_u, se_u = solve(up["b"].mean(), y, d, up["t"], up["m"], up["a"], up["b"])
    print("    harness on upstream's OWN nuisances -> theta=%.6f  stop=%s  se=%.6f"
          % (th_u, why_u, se_u))
    print("    (section 25h validated |theta - coef_upstream| = 0 on this cell)")
    print("")

    print("=== the port's own nuisance VALUES, seen up close ===")
    for b in blocks:
        print("    block %d: t range [%9.4g, %9.4g]   m range [%.4f, %.4f]   "
              "beta distinct=%d"
              % (b["block"], b["t"].min(), b["t"].max(),
                 b["m"].min(), b["m"].max(), len(np.unique(b["b"]))))
    print("    upstream   : t range [%9.4g, %9.4g]   m range [%.4f, %.4f]   "
          "beta distinct=%d"
          % (up["t"].min(), up["t"].max(), up["m"].min(), up["m"].max(),
             len(np.unique(up["b"]))))
    print("    |t| is the tell: upstream's t_hat is a fitted E[W|X] and stays")
    print("    small; the port's reaches +/-20 on 66 rows.")
    print("")

    print("=== A) CAUSAL TEST: upstream's solver on the port's own nuisances ===")
    verdicts = []
    for b in blocks:
        th_p, why_p, se_p = solve(b["b"].mean(), y, d, b["t"], b["m"], b["a"], b["b"])
        bad = (not np.isfinite(th_p)) or abs(th_p) > DIVERGENT or not np.isfinite(se_p)
        verdicts.append(bad)
        print("    block %d: theta0=%9.4f -> theta=%14.6f  stop=%-18s se=%12.6g  %s"
              % (b["block"], b["b"].mean(), th_p, why_p, se_p,
                 "DIVERGES" if bad else "converges"))
        if bad:
            print("             => the port's VALUES alone make upstream's own")
            print("                solver diverge on rows upstream handles fine.")
    print("")

    print("=== B) BISECT: which array is responsible (block %d) ===" % blocks[0]["block"])
    b = blocks[0]
    names = ("t", "m", "a", "b")
    print("    cells are labelled U=upstream's array, P=port's array")
    print("")
    print("    %-12s %14s %-20s %12s  %s" % ("t/m/a/b", "theta", "stop", "se", "verdict"))
    for combo in itertools.product("UP", repeat=4):
        pick = {k: (b[k] if s == "P" else up[k]) for k, s in zip(names, combo)}
        th, why, se = solve(pick["b"].mean(), y, d,
                            pick["t"], pick["m"], pick["a"], pick["b"])
        bad = (not np.isfinite(th)) or abs(th) > DIVERGENT or not np.isfinite(se)
        label = "/".join(combo)
        print("    %-12s %14.6f %-20s %12.6g  %s"
              % (label, th, why, se, "DIVERGES" if bad else "ok"))
    print("")

    print("=== reading ===")
    if not any(verdicts):
        print("The port's nuisance VALUES do NOT make upstream's solver")
        print("diverge. Combined with 25h (formula exonerated), that leaves the")
        print("ITERATION as the sole remaining suspect -- the start value, the")
        print("clamp, or the convergence rule in lplr.mbt's Newton loop.")
    else:
        print("The port's nuisance VALUES are sufficient on their own to make")
        print("upstream's solver diverge on rows upstream handles fine.")
        print("The formula is exonerated (25h) and the values are now implicated.")
        print("The bisect above names which array carries the effect: a cell")
        print("flips to DIVERGES when exactly one array is taken from the port.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
