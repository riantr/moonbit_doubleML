"""Does upstream's BAGGED a_hat["preds"] differ from a plain outer OOF?

Section 18 established a structural difference by reading source:
`_double_dml_cv_predict` (`utils/_estimation.py:207-229`) sums every inner
model's prediction on the outer test rows and divides by `len(smpls)`, so
`a_hat["preds"]` is an average over inner models. The port's `a_pred`
(`lplr.mbt:836`) is a single outer-OOF prediction. That value feeds
`r_hat = t_hat - beta * a_hat["preds"]` (`lplr.py:345`), then
`psi_hat = expit(-r_hat)`, the factor that collapses (`mean(psi_deriv)`).

Before building a cross-language comparison, settle the CHEAPER question
first, and it is answerable in Python alone: are the two numbers actually
different by a meaningful amount?

This is deliberately not "run upstream and look at the SE". It reads the
intermediate both ways on the SAME rows and the SAME partition, which is
what 14, 15 and 17 all failed to do.

Direction matters and is NOT predictable: averaging generally SHRINKS a
fitted value toward the mean, which would make upstream's a_hat SMALLER,
which makes upstream's r_hat LARGER (since r_hat = t - beta*a). If
psi_hat = expit(-r_hat) is what collapses, upstream having the LARGER r_hat
is the WRONG direction for this to be the explanation. So a large difference
still does not make it a cause -- it only stops it being a non-issue.

Run: python _verify/_lplr_ahat_bag_1680.py
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


def make_dgp(rng, n=500, p=6):
    x = rng.normal(size=(n, p))
    a = 0.5 * np.sin(x[:, 0]) + 0.5 * np.cos(x[:, 1]) + 0.5 * rng.normal(size=n)
    d = (rng.random(n) < expit(a)).astype(float)
    r = (0.25 * x[:, 0] * x[:, 1] + 0.25 * x[:, 2] * x[:, 2]
         + 0.25 * np.cos(x[:, 3]) - 0.5 * np.sin(x[:, 4])
         + (x[:, 5] > 0.0).astype(float) - 0.5)
    prob = expit(0.5 * d + r)
    y = (rng.random(n) < prob).astype(float)
    return x, y, d


def main(n_draws=12, n=500, p=6, seed=20260824):
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

    # Capture upstream's OWN a_hat. `preds` is built inside _nuisance_est and
    # is not exposed as a model attribute, so spying on the function that
    # produces it is the reliable way -- and it guarantees the value compared
    # is upstream's, not a re-derivation of it.
    orig = lplr_mod._double_dml_cv_predict
    captured = {}

    def spy(estimator, estimator_name, *a, **kw):
        res = orig(estimator, estimator_name, *a, **kw)
        captured[estimator_name] = res
        # Take the partition from the CALL, not from `model.smpls`. The
        # accessor nests differently before and after fit (`_i_rep` unset ->
        # all repetitions; set -> the last one), and unpacking the wrong one
        # yields tuples that index numpy as multiple axes instead of rows.
        captured["smpls"] = kw.get("smpls")
        return res

    lplr_mod._double_dml_cv_predict = spy

    rng = np.random.default_rng(seed)
    rows = []
    try:
        for k in range(n_draws):
            captured.clear()
            x, y, d = make_dgp(rng, n, p)
            cols = ["x%d" % (j + 1) for j in range(p)]
            df = pd.DataFrame(np.column_stack([x, y, d]),
                              columns=cols + ["y", "d"])
            try:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore")
                    obj = DoubleMLData(df, "y", "d", cols)
                    model = DoubleMLLPLR(
                        obj,
                        ml_M=mk(), ml_t=LinearRegression(), ml_m=mk(), ml_a=mk(),
                        n_folds=2, n_folds_inner=2, score="nuisance_space",
                        draw_sample_splitting=True,
                    )
                    model.fit()
                    # The partition comes from the spy (above), captured from
                    # the very call that produced `a_hat`.
                    smpls = captured["smpls"]
                    bag = np.asarray(captured["ml_a"]["preds"]).ravel()
                    r_up = np.asarray(captured.get("r", bag)).ravel()
                    flat = []
                    for entry in smpls:
                        if isinstance(entry, (tuple, list)) and len(entry) == 2 \
                                and not isinstance(entry[0], (tuple, list)):
                            flat.append(entry)
                        elif isinstance(entry, (tuple, list)):
                            flat.extend([e for e in entry])
                    smpls = flat
            except Exception as e:
                print("draw %d: upstream raised %s: %s"
                      % (k, type(e).__name__, e))
                continue

            # the port's a_pred: ONE model per outer test row, same partition
            plain = np.full(n, np.nan)
            for train_idx, test_idx in smpls:
                m = mk().fit(x[train_idx, :], d[train_idx])
                plain[test_idx] = m.predict(x[test_idx, :])

            diff = bag - plain
            rows.append(dict(
                k=k,
                absmax=float(np.abs(diff).max()),
                rms=float(np.sqrt(np.mean(diff ** 2))),
                span=float(np.max(bag) - np.min(bag)),
                rms_over_span=float(np.sqrt(np.mean(diff ** 2))
                                   / max(np.max(bag) - np.min(bag), 1e-300)),
                bag_mean=float(bag.mean()),
                plain_mean=float(plain.mean()),
                psi_hat_bag=float(np.mean(expit(-r_up))),
            ))
    finally:
        lplr_mod._double_dml_cv_predict = orig

    if not rows:
        print("no draws completed -- nothing measured")
        return 3

    print("draws measured: %d  (n=%d, n_folds=2, n_folds_inner=2)"
          % (len(rows), n))
    print()
    print("%-5s %-11s %-11s %-11s %-9s %-9s %-9s"
          % ("draw", "max|diff|", "rms(diff)", "span(a_hat)", "rms/span",
             "mean(bag)", "mean(plain)"))
    for r in rows:
        print("%-5d %-11.4g %-11.4g %-11.4g %-9.3f %-9.4f %-9.4f"
              % (r["k"], r["absmax"], r["rms"], r["span"], r["rms_over_span"],
                 r["bag_mean"], r["plain_mean"]))
    print()
    med_span = float(np.median([r["span"] for r in rows]))
    med_rms = float(np.median([r["rms"] for r in rows]))
    med_ratio = float(np.median([r["rms_over_span"] for r in rows]))
    print("median span of a_hat across rows : %.5f" % med_span)
    print("median rms(bag - plain)          : %.5f" % med_rms)
    print("median rms/span                  : %.4f" % med_ratio)
    print()
    if med_ratio < 0.02:
        print("VERDICT: the two agree to under 2%% of a_hat's own span.")
        print("=> the bagging is NOT a material difference; section 18's lead")
        print("   dies on MAGNITUDE, like 14, 15 and 17 died on occupancy.")
    elif med_ratio < 0.25:
        print("VERDICT: the two differ by %.1f%% of a_hat's span -- real but"
              % (100 * med_ratio))
        print("small. Magnitude alone cannot settle whether it explains the")
        print("collapse; it must be carried into the full r_hat comparison.")
    else:
        print("VERDICT: the two differ by %.1f%% of a_hat's span -- LARGE."
              % (100 * med_ratio))
        print("The structural difference is material and the lead survives.")
    print()
    print("direction check (see module docstring): does averaging SHRINK it?")
    diffs_mean = [r["bag_mean"] - r["plain_mean"] for r in rows]
    print("mean(bag) - mean(plain): %s"
          % np.array2string(np.array(diffs_mean), precision=5))
    print("sign is what decides the direction of the resulting r_hat:")
    print("   bag < plain  =>  upstream r_hat LARGER  (wrong way to explain)")
    print("   bag > plain  =>  upstream r_hat smaller  (right way)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
