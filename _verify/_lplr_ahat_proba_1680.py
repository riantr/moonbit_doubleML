"""CORRECTED a_hat probe: probabilities on BOTH sides.

What went wrong in the first run of this file
=============================================
The port's `a_pred` (`lplr.mbt:836`) is a plain outer cross-fit, and upstream's
`a_hat["preds"]` is a bagged one. To measure that difference I built the "port"
side in Python as

    LogisticRegression(...).fit(x[train], d[train]).predict(x[test])

and sklearn's `.predict` returns HARD 0/1 LABELS. Upstream's `a_hat` comes from
`method=self._predict_method["ml_a"]`, which is `"predict_proba"`
(`plm/lplr.py:166`, `:311`), so it is a vector of PROBABILITIES.

So the first run compared probabilities against labels and reported an 82.9%
divergence, and injecting those labels into upstream moved the coefficient by
-0.050. Both numbers were about `predict` vs `predict_proba`, NOT about bagging.

The port is on the probabilities side: `learner.mbt:159` and the implementation
at `logistic.mbt:217-243` -- `predict` returns `sigmoid(eta[i])` clipped into
`(1e-15, 1-1e-15)`, and the hard-label path is a separate `predict_class`
(`logistic.mbt:250-262`). Verified in the code, not just the comment.

This file redoes the measurement with `predict_proba(x)[:, 1]` on both sides,
so the only remaining difference IS the construction: bagged vs plain OOF.

Run: python _verify/_lplr_ahat_proba_1680.py
"""

import importlib.util
import os
import sys
import warnings

import numpy as np

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)
sys.path.insert(0, os.path.join(REPO, "_verify"))
from _lplr_env_1680 import use_vendored_upstream  # noqa: E402
use_vendored_upstream()
sys.path.insert(0, os.path.join(REPO, "_verify"))

N_SEEDS = 5
BAND_SIGMA = 3.0
BASE_SEED = 7000
N_FOLDS_INNER = 2


def load_pyexample():
    path = os.path.join(REPO, "pyexample_lplr.py")
    spec = importlib.util.spec_from_file_location("pyexample_lplr", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    import doubleml.plm.lplr as lplr_mod
    from sklearn.linear_model import LogisticRegression

    pe = load_pyexample()
    print("emitting the gate's rows ...")
    out = pe.run_emitter()
    vals, by_name = pe.parse_section(out, "lplr_upstream")
    n = int(vals["lplr_n"])
    p = int(vals["lplr_p"])
    x = by_name["lplr_x"].reshape(n, p)
    y = by_name["lplr_y"]
    d = by_name["lplr_d"]
    fold_id = by_name["lplr_fold"].astype(int)
    n_outer = int(fold_id.max()) + 1
    print("fixture: n=%d p=%d outer_folds=%d inner_folds=%d"
          % (n, p, n_outer, N_FOLDS_INNER))

    # the port's construction, on the PROBABILITY scale the port actually uses
    plain_proba = np.full(n, np.nan)
    plain_label = np.full(n, np.nan)
    for f in range(n_outer):
        test = np.where(fold_id == f)[0]
        train = np.where(fold_id != f)[0]
        m = LogisticRegression(C=1e6, max_iter=500, solver="lbfgs").fit(x[train, :], d[train])
        plain_proba[test] = m.predict_proba(x[test, :])[:, 1]
        plain_label[test] = m.predict(x[test, :])
    if np.isnan(plain_proba).any():
        raise SystemExit("partition left NaN rows")
    print("plain PROBA: mean=%.6f  min=%.6f  max=%.6f"
          % (plain_proba.mean(), plain_proba.min(), plain_proba.max()))
    print("plain LABEL: mean=%.6f  min=%.6f  max=%.6f   (the wrong control)"
          % (plain_label.mean(), plain_label.min(), plain_label.max()))

    orig = lplr_mod._double_dml_cv_predict
    cap = {}

    def patched(estimator, estimator_name, *a, **kw):
        res = orig(estimator, estimator_name, *a, **kw)
        if estimator_name == "ml_a":
            cap["bagged"] = np.asarray(res["preds"]).ravel().copy()
            res = dict(res)
            res["preds"] = plain_proba.copy()
        return res

    def run(seed, patch):
        lplr_mod._double_dml_cv_predict = patched if patch else orig
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                return pe.upstream_fit(x, y, d, fold_id, N_FOLDS_INNER, seed,
                                      "nuisance_space")
        finally:
            lplr_mod._double_dml_cv_predict = orig

    print("")
    print("=== part 1: the nuisance vector itself, probabilities on both sides ===")
    run(BASE_SEED, True)  # captures upstream's bagged a_hat
    bagged = cap["bagged"]
    span = float(bagged.max() - bagged.min())
    print("    upstream a_hat (bagged, proba): mean=%.6f min=%.6f max=%.6f span=%.6g"
          % (bagged.mean(), bagged.min(), bagged.max(), span))

    for tag, other in (("plain PROBA (correct)", plain_proba),
                       ("plain LABEL (wrong)", plain_label)):
        diff = bagged - other
        rms = float(np.sqrt(np.mean(diff ** 2)))
        print("    vs %-22s rms=%.6g  rms/span=%.4f  corr=%.6f"
              % (tag, rms, rms / max(span, 1e-300),
                 np.corrcoef(bagged, other)[0, 1]))

    print("")
    print("=== part 2: coefficient shift, correct control only ===")
    print("    seed  bagged      plain_proba  shift")
    bag_c, pln_c = [], []
    for i in range(N_SEEDS):
        s = BASE_SEED + 13 * i
        cb, _ = run(s, False)
        cp, _ = run(s, True)
        bag_c.append(cb)
        pln_c.append(cp)
        print("    %d  %12.6f  %12.6f  %+10.6f" % (s, cb, cp, cp - cb))

    bag = np.array(bag_c)
    pln = np.array(pln_c)
    shift = pln - bag
    sd_bag = bag.std(ddof=1)
    r = abs(pln.mean() - bag.mean())
    floor = BAND_SIGMA * sd_bag

    print("")
    print("    mean bagged=%.6f (sd %.6f)   mean plain=%.6f (sd %.6f)"
          % (bag.mean(), sd_bag, pln.mean(), pln.std(ddof=1)))
    print("    mean shift = %+.6f   max|shift| = %.6f" % (shift.mean(), np.abs(shift).max()))
    print("    sign consistency: %d of %d seeds shifted the same way"
          % (int((np.sign(shift) == np.sign(shift[0])).sum()), N_SEEDS))
    print("    gate band floor (3*sd_up, sd_port=0) = %.6f" % floor)
    print("")
    if r < 0.2 * floor:
        print("VERDICT: %.4f, under 20%% of the band floor." % r)
        print("         The bagging is COSMETICALLY real and numerically")
        print("         low-stakes at n=500. Do NOT ship it as a fix; it")
        print("         cannot move the gated gap.")
    elif r < floor:
        print("VERDICT: %.4f, a real fraction of the band floor %.4f." % (r, floor))
        print("         This is comparable to the gate's own tolerance.")
    else:
        print("VERDICT: %.4f, ABOVE the band floor %.4f." % (r, floor))
        print("         The port should then be failing the gate. It is not.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
