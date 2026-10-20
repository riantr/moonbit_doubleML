"""Sweep n: does BAGGED survive where PLAIN dies?

Section 19 measured the mechanism (PLAIN leaves mean(psi) ~13x larger at
theta0, so the first Newton step is ~1400x larger) but did so at n=500,
where -- as 19c states plainly -- NEITHER arm reproduced the divergence:
BAGGED 7/8 finite, PLAIN 8/8.

n=500 is the wrong place to test it. Section 11 already records that the
LPLR parity gate AGREES at n=500 and the estimator is WRONG at n=60. The
failure lives at small n, so that is where this has to be asked.

Same construction as `_lplr_bag_direction_1680.py`, unchanged except that n
is swept: upstream's own t_hat / beta / m_hat / W_inner / a_inner / theta0
are held fixed and only `a_hat` varies between the bagged inner-model
average and the port's plain outer OOF. Newton runs UNCLAMPED with scipy
1.18's stopping rule, because the clamp is precisely what is under
suspicion.

    n=60    the port's own parity gap (section 11)
    n=100   second small-n gap
    n=160   third
    n=500   control -- both arms expected to pass

Run: python _verify/_lplr_bag_nsweep_1680.py
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
sys.path.insert(0, os.path.join(REPO, "_verify"))

from _lplr_bag_direction_1680 import (  # noqa: E402
    expit, logit, make_dgp, newton_trace, score_terms, variance,
)

NS = [60, 100, 160, 500]
DRAWS = 25


def main(seed=20260824, p=6):
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

    summary = {}
    try:
        for n in NS:
            rng = np.random.default_rng(seed + n)
            tally = {"BAGGED": dict(fin=0, bad=0), "PLAIN": dict(fin=0, bad=0)}
            raised = 0
            rows = []
            for k in range(DRAWS):
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
                            n_folds=2, n_folds_inner=2,
                            score="nuisance_space", draw_sample_splitting=True)
                        mdl.fit()
                except Exception:
                    raised += 1
                    continue

                smpls = []
                for e in cap["smpls"]:
                    if isinstance(e, (tuple, list)) and len(e) == 2 \
                            and not isinstance(e[0], (tuple, list)):
                        smpls.append(e)
                    elif isinstance(e, (tuple, list)):
                        smpls.extend(list(e))

                a_bag = np.asarray(cap["ml_a"]["preds"]).ravel()
                M_in = [np.asarray(v).ravel() for v in cap["ml_M"]["preds_inner"]]
                a_in = [np.asarray(v).ravel() for v in cap["ml_a"]["preds_inner"]]

                W_inner, beta = [], np.zeros(n)
                for i, (tr, te) in enumerate(smpls):
                    w = logit(M_in[i][tr])
                    W_inner.append(w)
                    dt = (d - a_in[i])[tr]
                    beta[te] = np.sum(dt * w) / np.sum(dt ** 2)

                t_hat = np.full(n, np.nan)
                for i, (tr, te) in enumerate(smpls):
                    t_hat[te] = LinearRegression().fit(
                        x[tr, :], W_inner[i]).predict(x[te, :])

                m_hat = np.full(n, np.nan)
                for tr, te in smpls:
                    m_hat[te] = mk().fit(x[tr, :], d[tr]).predict(x[te, :])

                a_plain = np.full(n, np.nan)
                for tr, te in smpls:
                    a_plain[te] = mk().fit(x[tr, :], d[tr]).predict(x[te, :])

                theta0 = float(beta.mean())
                rec = {"k": k, "theta0": theta0}
                for name, av in (("BAGGED", a_bag), ("PLAIN", a_plain)):
                    r_hat = t_hat - beta * av
                    psi0, pder0 = score_terms(theta0, y, d, r_hat, m_hat,
                                             beta, av)
                    th, trace, why = newton_trace(theta0, y, d, r_hat, m_hat,
                                                  beta, av)
                    psif, pdf = score_terms(th, y, d, r_hat, m_hat, beta, av)
                    with np.errstate(over="ignore", invalid="ignore"):
                        v = variance(psif, pdf)
                    ok = bool(np.isfinite(v) and np.isfinite(th))
                    tally[name]["fin" if ok else "bad"] += 1
                    rec[name] = dict(ok=ok, theta=float(th), stop=why,
                                     mean_psi=float(psi0.mean()),
                                     first_step=(
                                         float(trace[0][4])
                                         if trace and np.isfinite(trace[0][4])
                                         else np.nan))
                rows.append(rec)
            summary[n] = (tally, raised, rows)
    finally:
        lplr_mod._double_dml_cv_predict = orig

    print("draws per n: %d   (n_folds=2, n_folds_inner=2, unclamped Newton)"
          % DRAWS)
    print()
    print("%-6s %-22s %-22s %s" % ("n", "BAGGED finite", "PLAIN finite",
                                  "verdict"))
    print("-" * 78)
    for n in NS:
        tally, raised, _ = summary[n]
        b, q = tally["BAGGED"], tally["PLAIN"]
        tot_b, tot_q = b["fin"] + b["bad"], q["fin"] + q["bad"]
        if raised:
            verdict = "upstream raised %d" % raised
        elif q["bad"] == 0:
            verdict = "PLAIN never fails here -- no headroom to improve"
        elif b["bad"] < q["bad"]:
            verdict = "BAGGED survives more often (direction CONFIRMED)"
        elif b["bad"] == q["bad"]:
            verdict = "same failure rate -- bagging is NOT the cause"
        else:
            verdict = "BAGGED worse -- refutes the direction"
        print("%-6d %-22s %-22s %s"
              % (n, "%d/%d" % (b["fin"], tot_b),
                 "%d/%d" % (q["fin"], tot_q), verdict))

    print()
    print("=== median first Newton step, by arm (n-dependent) ===")
    print("%-6s %-14s %-14s %-10s" % ("n", "BAGGED", "PLAIN", "ratio"))
    for n in NS:
        _, _, rows = summary[n]
        if not rows:
            continue
        mb = float(np.median([abs(r["BAGGED"]["first_step"]) for r in rows
                              if np.isfinite(r["BAGGED"]["first_step"])] or
                             [np.nan]))
        mq = float(np.median([abs(r["PLAIN"]["first_step"]) for r in rows
                              if np.isfinite(r["PLAIN"]["first_step"])] or
                             [np.nan]))
        print("%-6d %-14.5g %-14.5g %.3f" % (n, mb, mq,
                                             mb / mq if mq else np.nan))

    print()
    print("=== failing draws, PLAIN arm, by n ===")
    for n in NS:
        _, _, rows = summary[n]
        bad = [(r["k"], r["theta0"], r["PLAIN"]["theta"], r["PLAIN"]["stop"])
               for r in rows if not r["PLAIN"]["ok"]]
        print("n=%-5d %d failing draw(s)" % (n, len(bad)))
        for b in bad[:6]:
            print("    k=%-3d theta0=%-9.4g theta_end=%-12.4g stop=%s"
                  % (b[0], b[1], b[2], b[3]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
