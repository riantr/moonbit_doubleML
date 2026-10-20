"""Is the port's Newton start value BIASED, or is 6.84 just one draw?

`_lplr_newton_basin_1680.py` found the mechanism: on trial 2's rows upstream's
own `method="newton"` converges only for x0 in [0, 3.5]. Upstream's own start
(np.average(beta) = 1.003) is inside; the port's (6.842) is outside, where the
derivative collapses to -8e-5 and the first step overshoots to about -1380.

One trial establishes the mechanism. It does NOT establish bias -- and bias is
what decides whether there is a bug to fix. With n_folds=2, `np.average(beta)` is
the mean of TWO noisy per-fold scalars, so it has a wide spread by construction.

So this sweeps upstream's own start value across many redrawn partitions on the
SAME rows and asks two things:

  1. how often does upstream's OWN mean(beta) exceed the basin's edge?
  2. how often does upstream's OWN solver actually diverge because of it?

If upstream's mean(beta) routinely exceeds 3.5 on these rows, then the port's
6.84 is unremarkable, there is no port bias in `beta`, and the fragility is
shared. That would mean the clamp is not papering over a port defect -- it is
covering for an upstream fragility that the port happens to hit on this draw.
If instead upstream's mean(beta) is tightly concentrated near 0 while the port
sits at 6.84, that IS a bias and points back into `prelim_beta_per_fold` and the
inner OOF `m_inner` / `a_inner` it consumes.

Upstream's redraws are reproducible: the global NumPy seed is pinned per draw.

Run: python _verify/_lplr_startval_bias_1680.py
"""

import os
import sys
import warnings

import numpy as np
import pandas as pd
from scipy.optimize import root_scalar

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)
sys.path.insert(0, os.path.join(REPO, "_verify"))
from _lplr_env_1680 import use_vendored_upstream  # noqa: E402
use_vendored_upstream()
sys.path.insert(0, os.path.join(REPO, "_verify"))

from _lplr_nuisance_causal_1680 import parse_blocks  # noqa: E402
from _lplr_bag_direction_1680 import logit, score_terms  # noqa: E402

from _lplr_env_1680 import PORT_DUMP  # noqa: E402
DRAWS = 40
BASIN_EDGE = 3.5   # measured in _lplr_newton_basin_1680.py
PORT_START = 6.842375


def one_draw(x, y, d, cols, seed, p):
    """Upstream's own start value and its own convergence, one partition."""
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
        df = pd.DataFrame(np.column_stack([x, y, d]), columns=cols + ["y", "d"])
        obj = DoubleMLData(df, "y", "d", cols)
        np.random.seed(seed)
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

    # Rebuild beta exactly as `plm/lplr.py:320-323` does, then the start value.
    smpls = []
    for e in cap["smpls"]:
        if isinstance(e, (tuple, list)) and len(e) == 2 and not isinstance(e[0], (tuple, list)):
            smpls.append(e)
        elif isinstance(e, (tuple, list)):
            smpls.extend(list(e))
    M_in = [np.asarray(v).ravel() for v in cap["ml_M"]["preds_inner"]]
    a_in = [np.asarray(v).ravel() for v in cap["ml_a"]["preds_inner"]]
    m_hat = t_hat = None
    for ename, res in cap["cv"]:
        if "LogisticRegression" in ename and m_hat is None:
            m_hat = np.asarray(res["preds"]).ravel()
        elif "LinearRegression" in ename and t_hat is None:
            t_hat = np.asarray(res["preds"]).ravel()
    a_hat = np.asarray(cap["ml_a"]["preds"]).ravel()

    beta = np.zeros(len(d))
    for i, (tr, te) in enumerate(smpls):
        w = logit(M_in[i][tr])
        dt = (d - a_in[i])[tr]
        beta[te] = np.sum(dt * w) / np.sum(dt ** 2)
    start = float(np.average(beta))

    # Upstream's own solver from its own start, on its own nuisances.
    r_hat = t_hat - beta * a_hat

    def sc(th):
        with np.errstate(over="ignore", invalid="ignore"):
            return float(np.mean(score_terms(th, y, d, r_hat, m_hat, beta, a_hat)[0]))

    def dv(th):
        with np.errstate(over="ignore", invalid="ignore"):
            return float(np.mean(score_terms(th, y, d, r_hat, m_hat, beta, a_hat)[1]))

    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            r = root_scalar(sc, x0=start, fprime=dv, method="newton")
        conv = bool(r.converged)
    except Exception:
        conv = False
    return start, coef, se, conv


def main():
    blocks = parse_blocks(PORT_DUMP)
    b0 = blocks[0]
    n, p = b0["n"], b0["p"]
    x = b0["x"].reshape(n, p)
    y, d = b0["y"], b0["d"]
    cols = ["x%d" % (j + 1) for j in range(p)]
    print("trial 2 rows: n=%d p=%d   %d upstream redraws, each pinned"
          % (n, p, DRAWS))
    print("")
    starts, convs, coefs = [], [], []
    for k in range(DRAWS):
        s, c, se, conv = one_draw(x, y, d, cols, 20260824 + k, p)
        starts.append(s)
        convs.append(conv)
        coefs.append(c)
        print("  draw %2d  mean(beta)=%9.4f  coef=%12.5f  converged=%s%s"
              % (k, s, c, conv, "" if s <= BASIN_EDGE else "   <- beyond the measured edge"))
    starts = np.array(starts)

    print("")
    print("=== distribution of upstream's OWN start value on these rows ===")
    print("    n=%d draws   mean=%.4f  sd=%.4f  min=%.4f  max=%.4f"
          % (len(starts), starts.mean(), starts.std(), starts.min(), starts.max()))
    print("    quantiles: 25%%=%.4f  50%%=%.4f  75%%=%.4f  90%%=%.4f"
          % (np.percentile(starts, 25), np.percentile(starts, 50),
             np.percentile(starts, 75), np.percentile(starts, 90)))
    beyond = int((starts > BASIN_EDGE).sum())
    print("    draws with start > basin edge (%.1f) : %d/%d  (%.0f%%)"
          % (BASIN_EDGE, beyond, len(starts), 100.0 * beyond / len(starts)))
    print("    upstream fits that did NOT converge : %d/%d  (%.0f%%)"
          % (len(convs) - sum(convs), len(convs),
             100.0 * (len(convs) - sum(convs)) / len(convs)))
    print("")
    print("    the port's start on trial 2 : %.4f" % PORT_START)
    pct = 100.0 * float((starts < PORT_START).mean())
    print("    its percentile within upstream's own draws : %.0f%%" % pct)
    print("")

    print("=== reading ===")
    if beyond == 0:
        print("Upstream's OWN start value never exceeded the basin edge on these")
        print("rows, so the port's 6.84 would be a BIAS, not a draw -- and the")
        print("defect would live in the port's `beta`, i.e. in the inner OOF")
        print("m_inner / a_inner feeding `prelim_beta_per_fold`.")
    else:
        print("Upstream's own start value exceeded the basin edge on %d/%d draws"
              % (beyond, len(starts)))
        print("(%d actually failed to converge). The fragility is SHARED: upstream"
              % (len(convs) - sum(convs)))
        print("runs the same unbracketed Newton from the same rule, and on these")
        print("rows it is exposed too.")
        print("")
        print("The port's %.4f sits at the %.0fth percentile of upstream's own"
              % (PORT_START, pct))
        print("draws, so it is an unremarkable draw rather than an outlier.")
        print("")
        print("This does NOT show the port is unbiased -- one draw cannot -- but")
        print("it removes 'the port's start value is systematically too large'")
        print("as a conclusion. A bias claim needs the port's start measured over")
        print("the same sweep, which needs the partition injected into the port.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
