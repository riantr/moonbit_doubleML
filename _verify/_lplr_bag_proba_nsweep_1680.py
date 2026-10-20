"""CORRECTED small-n sweep: BAGGED vs PLAIN, both on the PROBABILITY scale.

Section 19 and its n-sweep are WITHDRAWN, and this is why.

Both were built by reconstructing the port's nuisances in Python as

    LogisticRegression(...).fit(x[tr], d[tr]).predict(x[te])

`sklearn`'s `.predict` returns HARD 0/1 LABELS. But upstream's `a_hat` and
`m_hat` are both PROBABILITIES:

  * `a_hat`  -- `method=self._predict_method["ml_a"]`, which is
    `"predict_proba"` (`plm/lplr.py:166`, consumed at `:311`), so
    `_double_dml_cv_predict` takes the `predict_proba` branch at
    `utils/_estimation.py:225-226`.
  * `m_hat`  -- `method=self._predict_method["ml_m"]`, also `"predict_proba"`
    (`plm/lplr.py:150`, consumed at `:261`).

The port is on the probability side there too: `logistic.mbt:217-243` returns
`sigmoid(eta[i])` clipped into `(1e-15, 1-1e-15)`, with `predict_class` the
separate hard-label path.

So every "PLAIN is worse" number in section 19 -- mean(psi) ~13x larger, first
Newton step ~1400x larger, surviving 15 vs 16 / 19 vs 21 / 19 vs 20 of 25 --
was measuring **hard labels against probabilities**, which is a different and
much blunter thing than bagging against a plain outer cross-fit. The wrong
control is easy to favour: labels discard all the confidence information the
score depends on, so of course they destabilise Newton.

This file redoes the sweep with `predict_proba(x)[:, 1]` for BOTH `a_plain`
and `m_hat`, which is the only remaining difference: the bagged inner-model
average versus a plain outer OOF.

If the two arms now behave alike, the bagging is not the small-n culprit and
the search has to look elsewhere.

Run: python _verify/_lplr_bag_proba_nsweep_1680.py
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
    nuisance = {}
    try:
        for n in NS:
            rng = np.random.default_rng(seed + n)
            tally = {"BAGGED": dict(fin=0, bad=0), "PLAIN": dict(fin=0, bad=0)}
            raised = 0
            rows = []
            span_rel = []
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

                # CORRECTED: m_hat on the probability scale, as upstream's
                # `predict_proba` branch produces it.
                m_hat = np.full(n, np.nan)
                for tr, te in smpls:
                    m_hat[te] = mk().fit(x[tr, :], d[tr]).predict_proba(
                        x[te, :])[:, 1]

                # CORRECTED: a_plain likewise.
                a_plain = np.full(n, np.nan)
                for tr, te in smpls:
                    a_plain[te] = mk().fit(x[tr, :], d[tr]).predict_proba(
                        x[te, :])[:, 1]

                sp = float(a_bag.max() - a_bag.min())
                rms = float(np.sqrt(np.mean((a_bag - a_plain) ** 2)))
                span_rel.append(rms / max(sp, 1e-300))

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
            nuisance[n] = span_rel
    finally:
        lplr_mod._double_dml_cv_predict = orig

    print("draws per n: %d   (n_folds=2, n_folds_inner=2, unclamped Newton,"
          % DRAWS)
    print("m_hat AND a_plain both on predict_proba -- corrected control)")
    print("")
    print("%-6s %-22s %-22s %s" % ("n", "BAGGED finite", "PLAIN finite",
                                   "PLAIN better?"))
    for n in NS:
        tally, raised, rows = summary[n]
        b, pl = tally["BAGGED"], tally["PLAIN"]
        tot = b["fin"] + b["bad"]
        verdict = ("PLAIN better by %d" % (pl["fin"] - b["fin"])
                   if pl["fin"] != b["fin"] else "tie")
        print("%-6d %-22s %-22s %s"
              % (n, "%d/%d" % (b["fin"], tot), "%d/%d" % (pl["fin"], tot),
                 verdict))
        if raised:
            print("       (%d draws raised during fit)" % raised)

    print("")
    print("=== the nuisance difference itself, probabilities on both sides ===")
    for n in NS:
        v = np.array(nuisance[n])
        print("    n=%-4d rms(bagged-plain)/span: mean=%.4f  median=%.4f  max=%.4f"
              % (n, v.mean(), np.median(v), v.max()))

    print("")
    print("=== the mechanism section 19 claimed, recomputed ===")
    for n in NS:
        _, _, rows = summary[n]
        rp, rb = [], []
        for rec in rows:
            a, b = rec["PLAIN"], rec["BAGGED"]
            if np.isfinite(a["mean_psi"]) and np.isfinite(b["mean_psi"]) \
                    and b["mean_psi"] != 0:
                rp.append(abs(a["mean_psi"] / b["mean_psi"]))
            if np.isfinite(a["first_step"]) and np.isfinite(b["first_step"]) \
                    and b["first_step"] != 0:
                rb.append(abs(a["first_step"] / b["first_step"]))
        print("    n=%-4d |mean(psi)| PLAIN/BAGGED median=%.3f   "
              "|first step| PLAIN/BAGGED median=%.3f"
              % (n, np.median(rp) if rp else float("nan"),
                 np.median(rb) if rb else float("nan")))
    print("")
    print("    section 19 reported 13x and 1400x. Those came from the")
    print("    hard-label control and are withdrawn.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
