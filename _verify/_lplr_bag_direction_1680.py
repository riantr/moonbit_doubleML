"""Does using upstream's BAGGED a_hat avoid the divergence the port hits?

This settles the direction question section 18d left open -- and may
overturn what 18d asserts.

18d measured that `a_hat` (bagged) < `a_pred` (plain) on 12/12 draws, and
reasoned that since `r_hat = t_hat - beta*a_hat` with beta > 0, upstream's
r_hat is LARGER, hence psi_hat SMALLER, hence mean(psi_deriv) smaller --
"the wrong direction". That reasoning used ONE failure channel. There are
two, and they point opposite ways:

  (1) the RUNAWAY STEP. Newton takes `theta - s/sd`. If mean(psi_deriv)
      collapses, the step explodes and theta lands far from the root. Smaller
      psi_hat makes mean(psi_deriv) smaller, i.e. WORSE. This is the
      channel 18d reasoned about.

  (2) the VARIANCE OVERFLOW. Once theta is large, `A = y*exp(-theta*d)*d_tilde`
      reaches ~1e191 (theta = -440). Then `psi = psi_hat*A`, and the variance
      does `mean(psi^2) / (J^2 * n)`, so `psi^2 ~ psi_hat^2 * 1e382`.
      A SMALLER psi_hat is PROTECTIVE here: it is psi_hat squared, so
      shrinking psi_hat by k shrinks the square by k^2.

So smaller psi_hat is worse for (1) and better for (2). 18d asserted (1)
decides it, without measuring either. This measures both, on upstream's own
captured quantities, holding EVERYTHING else fixed:

    t_hat, beta, m_hat, W_inner, a_inner, theta0   identical in both arms
    a_hat                                         bagged  vs  plain

and reports, per arm: mean(psi), mean(psi_deriv), the first Newton step,
the theta trajectory, and the resulting variance.

Run: python _verify/_lplr_bag_direction_1680.py
"""

import os
import sys
import warnings

import numpy as np
import pandas as pd

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "_verify"))
from _lplr_env_1680 import use_vendored_upstream  # noqa: E402
use_vendored_upstream()


def expit(z):
    return 1.0 / (1.0 + np.exp(-z))


def logit(p):
    p = np.clip(p, 1e-8, 1 - 1e-8)
    return np.log(p / (1 - p))


def make_dgp(rng, n=500, p=6):
    x = rng.normal(size=(n, p))
    a = 0.5 * np.sin(x[:, 0]) + 0.5 * np.cos(x[:, 1]) + 0.5 * rng.normal(size=n)
    d = (rng.random(n) < expit(a)).astype(float)
    r = (0.25 * x[:, 0] * x[:, 1] + 0.25 * x[:, 2] * x[:, 2]
         + 0.25 * np.cos(x[:, 3]) - 0.5 * np.sin(x[:, 4])
         + (x[:, 5] > 0.0).astype(float) - 0.5)
    y = (rng.random(n) < expit(0.5 * d + r)).astype(float)
    return x, y, d


def score_terms(theta, y, d, r_hat, m_hat, beta, a_hat):
    """Upstream nuisance_space score/derivative, on one theta."""
    d_tilde = d - m_hat
    psi_hat = expit(-r_hat)
    score_const = d_tilde * (1.0 - y) * np.exp(r_hat)
    score_1 = y * np.exp(-theta * d) * d_tilde
    psi = psi_hat * (score_1 - score_const)
    psi_deriv = psi_hat * y * (-d) * np.exp(-theta * d) * d_tilde
    return psi, psi_deriv


def newton_trace(theta0, y, d, r_hat, m_hat, beta, a_hat,
                 tol=1.48e-8, maxiter=50):
    """scipy 1.18 newton's stopping rule, UNCLAMPED, recording the path."""
    th = float(theta0)
    trace = []
    for itr in range(maxiter):
        psi, pd = score_terms(th, y, d, r_hat, m_hat, beta, a_hat)
        s, sd = psi.mean(), pd.mean()
        if s == 0.0:
            trace.append((itr, th, s, sd, np.nan))
            return th, trace, "fval==0"
        if sd == 0.0:
            trace.append((itr, th, s, sd, np.nan))
            return th, trace, "fder==0"
        step = s / sd
        p = th - step
        trace.append((itr, th, s, sd, step))
        if abs(p - th) <= tol + 0.0 * abs(th):
            return p, trace, "converged"
        th = p
        if not np.isfinite(th):
            return th, trace, "nonfinite"
    return th, trace, "maxiter"


def variance(psi, psi_deriv):
    """doubleml's sigma2 = mean(psi^2) / (n * J^2) -- no overflow guard."""
    with np.errstate(over="ignore", invalid="ignore"):
        gamma = np.mean(np.square(psi))
        J = psi_deriv.mean()
        return gamma / (J * J * len(psi))


def main(n_draws=8, n=500, p=6, seed=20260824):
    try:
        from doubleml.plm import DoubleMLLPLR
        from doubleml.data import DoubleMLData
        from sklearn.linear_model import LogisticRegression, LinearRegression
        import doubleml.plm.lplr as lplr_mod
    except Exception as e:  # pragma: no cover
        print("SKIP: cannot import doubleml: %s" % e)
        return 3

    def mk():
        return LogisticRegression(C=1e6, max_iter=500, solver="lbfgs")

    orig = lplr_mod._double_dml_cv_predict
    cap = {}

    def spy(estimator, estimator_name, *a, **kw):
        res = orig(estimator, estimator_name, *a, **kw)
        cap[estimator_name] = res
        cap["smpls"] = kw.get("smpls")
        return res

    lplr_mod._double_dml_cv_predict = spy

    rng = np.random.default_rng(seed)
    table = []
    try:
        for k in range(n_draws):
            cap.clear()
            x, y, d = make_dgp(rng, n, p)
            cols = ["x%d" % (j + 1) for j in range(p)]
            df = pd.DataFrame(np.column_stack([x, y, d]),
                              columns=cols + ["y", "d"])
            try:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore")
                    obj = DoubleMLData(df, "y", "d", cols)
                    mdl = DoubleMLLPLR(
                        obj, ml_M=mk(), ml_t=LinearRegression(),
                        ml_m=mk(), ml_a=mk(),
                        n_folds=2, n_folds_inner=2, score="nuisance_space",
                        draw_sample_splitting=True)
                    mdl.fit()
            except Exception as e:
                print("draw %d: upstream raised %s: %s"
                      % (k, type(e).__name__, e))
                continue

            smpls = cap["smpls"]
            flat = []
            for e in smpls:
                if isinstance(e, (tuple, list)) and len(e) == 2 \
                        and not isinstance(e[0], (tuple, list)):
                    flat.append(e)
                elif isinstance(e, (tuple, list)):
                    flat.extend(list(e))
            smpls = flat

            a_bag = np.asarray(cap["ml_a"]["preds"]).ravel()
            M_inner = [np.asarray(v).ravel() for v in cap["ml_M"]["preds_inner"]]
            a_inner = [np.asarray(v).ravel() for v in cap["ml_a"]["preds_inner"]]

            # upstream's W_inner and beta, lplr.py:314-326
            W_inner, beta = [], np.zeros(n)
            for i, (tr, te) in enumerate(smpls):
                w = logit(M_inner[i][tr])
                W_inner.append(w)
                dt = (d - a_inner[i])[tr]
                beta[te] = np.sum(dt * w) / np.sum(dt ** 2)

            # upstream's t_hat, lplr.py:332-345
            t_hat = np.full(n, np.nan)
            for i, (tr, te) in enumerate(smpls):
                lr = LinearRegression().fit(x[tr, :], W_inner[i])
                t_hat[te] = lr.predict(x[te, :])

            # m_hat: ml_m plain outer CV (upstream lplr.py:244-266)
            m_hat = np.full(n, np.nan)
            for tr, te in smpls:
                m_hat[te] = mk().fit(x[tr, :], d[tr]).predict(x[te, :])

            # the port's a_pred: plain outer OOF of the SAME learner
            a_plain = np.full(n, np.nan)
            for tr, te in smpls:
                a_plain[te] = mk().fit(x[tr, :], d[tr]).predict(x[te, :])

            theta0 = float(beta.mean())
            row = {"k": k, "theta0": theta0}
            for name, av in (("BAGGED", a_bag), ("PLAIN", a_plain)):
                r_hat = t_hat - beta * av
                psi0, pder0 = score_terms(theta0, y, d, r_hat, m_hat,
                                          beta, av)
                th, trace, why = newton_trace(theta0, y, d, r_hat, m_hat,
                                              beta, av)
                psi_f, pdf_f = score_terms(th, y, d, r_hat, m_hat, beta, av)
                with np.errstate(over="ignore", invalid="ignore"):
                    v = variance(psi_f, pdf_f)
                row[name] = dict(
                    r_max=float(np.abs(r_hat).max()),
                    psi_hat_mean=float(expit(-r_hat).mean()),
                    psi_hat_spread=float(np.std(np.log10(
                        np.maximum(expit(-r_hat), 1e-300)))),
                    mean_psi=float(psi0.mean()),
                    mean_deriv=float(pder0.mean()),
                    first_step=float(trace[0][4]) if trace else np.nan,
                    min_step=float(min(abs(t[4]) for t in trace
                                       if np.isfinite(t[4]))) if trace else np.nan,
                    iters=len(trace), theta=float(th), stop=why,
                    se=bool(np.isfinite(v)),
                    psi_absmax=float(np.abs(psi_f).max()),
                )
            table.append(row)
    finally:
        lplr_mod._double_dml_cv_predict = orig

    if not table:
        print("no draws completed -- nothing measured")
        return 3

    print("draws: %d   (n=%d, n_folds=2, n_folds_inner=2)" % (len(table), n))
    print()
    for name in ("BAGGED", "PLAIN"):
        print("--- %s  (upstream's a_hat vs the port's a_pred) ---" % name)
        print("%-4s %-10s %-10s %-11s %-12s %-10s %-8s %-7s %-5s"
              % ("draw", "theta0", "mean_psi", "mean_deriv", "first_step",
                 "theta_end", "iters", "stop", "se?"))
        for r in table:
            a = r[name]
            print("%-4d %-10.4g %-10.4g %-11.4g %-12.4g %-10.4g %-8s %-7s %-5s"
                  % (r["k"], r["theta0"], a["mean_psi"], a["mean_deriv"],
                     a["first_step"], a["theta"], a["iters"], a["stop"],
                     "fin" if a["se"] else "NONFIN"))
        print()

    print("=== the two failure channels, side by side (medians) ===")
    med = lambda k, f: float(np.median([r[k][f] for r in table]))
    print("%-34s %-14s %-14s %s" % ("quantity", "BAGGED", "PLAIN", "ratio"))
    for label, f in (("|r_hat| max", "r_max"),
                     ("mean psi_hat", "psi_hat_mean"),
                     ("log10 spread of psi_hat", "psi_hat_spread"),
                     ("mean(psi)", "mean_psi"),
                     ("mean(psi_deriv)", "mean_deriv"),
                     ("FIRST Newton step", "first_step"),
                     ("theta after Newton", "theta"),
                     ("|psi| max at solution", "psi_absmax")):
        b, q = med("BAGGED", f), med("PLAIN", f)
        ratio = (b / q) if q not in (0.0,) else float("nan")
        print("%-34s %-14.5g %-14.5g %.3f" % (label, b, q, ratio))
    print()
    nb = sum(1 for r in table if r["BAGGED"]["se"])
    np_ = sum(1 for r in table if r["PLAIN"]["se"])
    print("finite SE  BAGGED %d/%d    PLAIN %d/%d" % (nb, len(table),
                                                     np_, len(table)))
    print()
    fs_b = med("BAGGED", "first_step")
    fs_p = med("PLAIN", "first_step")
    print("CHANNEL (1) runaway step: first_step is smaller under BAGGED"
          " -> %s" % (fs_b < fs_p))
    print("CHANNEL (2) psi^2 overflow: |psi| max smaller under BAGGED -> %s"
          % (med("BAGGED", "psi_absmax") < med("PLAIN", "psi_absmax")))
    print("=> 18d's 'wrong direction' claim is %s"
          % ("REFUTED" if (fs_b < fs_p and
                          med("BAGGED", "psi_absmax") < med("PLAIN", "psi_absmax"))
             else "not fully refuted"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
