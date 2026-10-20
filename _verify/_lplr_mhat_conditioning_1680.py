"""Does upstream's m_hat CONDITIONING explain the port's Newton divergence?

The candidate
=============
`plm/lplr.py:247-252`, for `score == "nuisance_space"`:

    elif self.score == "nuisance_space":
        filtered_smpls = []
        for train, test in smpls:
            train_filtered = train[y[train] == 0]
            filtered_smpls.append((train_filtered, test))
        weights = None
    m_hat = _dml_cv_predict(self._learner["ml_m"], x, d, smpls=filtered_smpls, ...)

So upstream fits the propensity `ml_m` on the **controls only** and predicts
on the full test fold. The port uses `m_pred = a_pred`, an UNCONDITIONED outer
cross-fit (`lplr.mbt:836`, alias at `:928`).

Section 14a checked the outer-cross-fit SHAPE and found the alias faithful --
`_dml_cv_predict(self._learner["ml_m"], x, d, ...)` really is a plain outer
cross-fit. It did not check what is inside the fit. That is this probe.

Why it matters
==============
Unclamped, the port's Newton runs away (`se = NaN, th = -440.16`, fuzz trial
2) while upstream, running the SAME bare Newton, converges. If the two score
functions were identical that could not happen. The conditioning is the one
input difference still standing, because it changes `d_tilde = d - m_hat` --
the only term in the score that section 16a verified by FORM but not by VALUE.

The measurement
===============
Both arms run the same Newton's path with everything else held at upstream's
real values, and differ ONLY in `m_pred`:

  UNCONDITIONED  the port's construction: outer OOF, fitted on all train rows
  CONDITIONED    upstream's real `m_hat`, captured from the fit itself

Both on the PROBABILITY scale. This is the correction from section 21: the
earlier probes used sklearn `.predict`, which returns hard labels, and that
turned out to be the whole of an apparent 69% divergence. `.predict_proba`
here, and the reconstruction is validated against upstream's own ml_a output
before it is used for anything.

If CONDITIONED converges where UNCONDITIONED runs away, then implementing the
conditioning is what makes the clamp unnecessary -- and the clamp is the one
remaining reason the port disagrees with upstream at n=100.

Run: python _verify/_lplr_mhat_conditioning_1680.py
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

NS = [100, 160, 500]
DRAWS = 12


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
    orig_cv = lplr_mod._dml_cv_predict
    cap = {}

    def spy(estimator, estimator_name, *a, **kw):
        res = orig(estimator, estimator_name, *a, **kw)
        cap[estimator_name] = res
        cap.setdefault("smpls", kw.get("smpls"))
        return res

    def spy_cv(estimator, x, ytarget, **kw):
        res = orig_cv(estimator, x, ytarget, **kw)
        # `_dml_cv_predict` carries no estimator name, so each call is recorded
        # with its target and its output; the propensity call is identified
        # after the fit by matching the target against `d`.
        # `_double_dml_cv_predict` calls the ORIGINAL `_dml_cv_predict` from its
        # own module, so patching the lplr namespace cannot double-count.
        cap.setdefault("_cv_calls", []).append(
            (np.asarray(ytarget).ravel().copy(), res))
        return res

    lplr_mod._double_dml_cv_predict = spy
    lplr_mod._dml_cv_predict = spy_cv

    rows = []
    recon_err = []
    try:
        for n in NS:
            rng = np.random.default_rng(seed + n)
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
                    continue

                # Upstream's real m_hat: the `_dml_cv_predict` call whose
                # target is the treatment vector `d`.
                m_cond = None
                for tgt, res in cap.get("_cv_calls", []):
                    if tgt.shape == d.shape and np.allclose(tgt, d):
                        m_cond = np.asarray(res["preds"]).ravel()
                        break
                if m_cond is None:
                    continue
                a_bag = np.asarray(cap["ml_a"]["preds"]).ravel()

                smpls = []
                for e in cap["smpls"]:
                    if isinstance(e, (tuple, list)) and len(e) == 2 \
                            and not isinstance(e[0], (tuple, list)):
                        smpls.append(e)
                    elif isinstance(e, (tuple, list)):
                        smpls.extend(list(e))

                # The port's `a_pred`: plain outer OOF, UNCONDITIONED, on the
                # probability scale (section 21's correction).
                a_plain = np.full(n, np.nan)
                for tr, te in smpls:
                    a_plain[te] = mk().fit(x[tr, :], d[tr]).predict_proba(
                        x[te, :])[:, 1]

                # Validate the reconstruction against upstream's own ml_a,
                # which is the same target, same learner, same outer folds.
                recon_err.append(float(np.sqrt(np.mean((a_plain - a_bag) ** 2))))

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

                theta0 = float(beta.mean())
                rec = {"n": n, "k": k,
                       "d_mhat": float(np.sqrt(np.mean(
                           (m_cond - a_plain) ** 2)))}
                for name, m_use in (("UNCOND", a_plain), ("COND", m_cond)):
                    r_hat = t_hat - beta * a_plain
                    th, trace, why = newton_trace(theta0, y, d, r_hat, m_use,
                                                  beta, a_plain)
                    psif, pdf = score_terms(th, y, d, r_hat, m_use, beta, a_plain)
                    with np.errstate(over="ignore", invalid="ignore"):
                        v = variance(psif, pdf)
                    rec[name] = dict(theta=float(th),
                                     ok=bool(np.isfinite(v) and np.isfinite(th)),
                                     stop=why)
                rows.append(rec)
    finally:
        lplr_mod._double_dml_cv_predict = orig
        lplr_mod._dml_cv_predict = orig_cv

    if not rows:
        print("no comparable draws -- the propensity call was never seen")
        return 3

    print("draws per n: %d" % DRAWS)
    print("reconstruction check: rms(port a_plain - upstream ml_a bagged)")
    print("    mean=%.5f  max=%.5f   (small => the reconstruction is sound)"
          % (np.mean(recon_err), np.max(recon_err)))
    print("")
    print("%-6s %-28s %-28s %s" % ("n", "UNCONDITIONED (the port)", "CONDITIONED (upstream)", "rms diff in m_hat"))
    for n in NS:
        sub = [r for r in rows if r["n"] == n]
        if not sub:
            continue
        u = sum(1 for r in sub if r["UNCOND"]["ok"])
        c = sum(1 for r in sub if r["COND"]["ok"])
        dm = np.mean([r["d_mhat"] for r in sub])
        print("%-6d %-28s %-28s %.4f"
              % (n, "%d/%d finite" % (u, len(sub)),
                 "%d/%d finite" % (c, len(sub)), dm))

    print("")
    wins = loses = ties = 0
    for r in rows:
        a, b = r["UNCOND"]["ok"], r["COND"]["ok"]
        if a == b:
            ties += 1
        elif b:
            wins += 1
        else:
            loses += 1
    print("conditioning strictly helps on %d draws, strictly hurts on %d, ties on %d"
          % (wins, loses, ties))
    print("")
    if wins and not loses:
        print("VERDICT: CONDITIONED is strictly better -- the conditioning is a")
        print("         real port deviation and is worth implementing.")
        print("         It is the remaining candidate for why the unclamped")
        print("         Newton runs away where upstream's converges.")
    elif wins > loses:
        print("VERDICT: CONDITIONED wins %d vs %d but loses on %d. Not clean." % (wins, loses, ties))
    elif wins:
        print("VERDICT: mixed -- wins %d, loses %d. Not a clean cause." % (wins, loses))
    else:
        print("VERDICT: no strict wins (%d vs %d, %d ties). The conditioning is"
              % (wins, loses, ties))
        print("         NOT the cause of the Newton runaway, even though it is")
        print("         a genuine deviation from upstream.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
