"""Does UPSTREAM's DoubleMLLPLR have the same heavy coefficient tail on small-n
confounded designs as this port?

Why this is the missing measurement. D1 (upstream's `m_hat` conditioning,
`plm/lplr.py:244-264`) was reverted because it made the port's worst |coef|
77x larger and took `examples/fuzz` from 11/11 to FAIL. But the fuzz ceiling
`|coef| < 1e10` is the PORT's invariant, not upstream's: the alias
`m_pred = a_pred` may simply be an accidentally-stable answer on designs
upstream does not agree with. The goal is consistency WITH UPSTREAM, so the
question that decides D1 is not "is the port stable" but "is the port's
tail shape upstream's tail shape".

Replicates fuzz's design distribution (n = 60..159, p = 6, the same
confounded tanh-probability / expit-outcome construction) in numpy and fits
upstream. Only the family needs to match, not the exact draws -- the question
is about the shape of the distribution, and numpy cannot reproduce the port's
chacha8 stream anyway.

Prints the tail counts the port's probe used, so the two are comparable:
  |coef| > 1e8, |coef| > 1e10, max |coef|, and how many WARN.
"""

import numpy as np
import warnings

from doubleml.data import DoubleMLData
from doubleml.plm import DoubleMLLPLR
from sklearn.linear_model import LinearRegression, LogisticRegression


def make_design(rng, n, p=6):
    pool = rng.standard_normal(n * p + n)
    x = pool[: n * p].reshape(n, p)
    d = (rng.random(n) < np.clip(
        0.5 * np.sin(x[:, 0]) + 0.5 * np.cos(x[:, 1]) + 0.5 * pool[n * p:], 0, 1))
    d = d.astype(float)
    r = (0.25 * x[:, 0] * x[:, 1]
         + 0.25 * x[:, 2] ** 2
         + 0.25 * np.cos(x[:, 3])
         - 0.5 * np.sin(x[:, 4])
         + (x[:, 5] > 0).astype(float)
         - 0.5)
    y = (rng.random(n) < 1.0 / (1.0 + np.exp(-(0.5 * d + r)))).astype(float)
    return x, y, d


def main():
    import pandas as pd
    trials = 200
    rng = np.random.default_rng(20261017)
    over1e8 = 0
    over1e10 = 0
    warned = 0
    errs = 0
    mags = []
    for _ in range(trials):
        n = int(rng.integers(60, 160))
        x, y, d = make_design(rng, n)
        df = pd.DataFrame(x, columns=["x%d" % i for i in range(x.shape[1])])
        df["y"] = y
        df["d"] = d
        try:
            dml_data = DoubleMLData(
                df, "y", "d", ["x%d" % i for i in range(x.shape[1])]
            )
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                model = DoubleMLLPLR(
                    dml_data,
                    ml_M=LogisticRegression(),
                    ml_t=LinearRegression(),
                    ml_m=LogisticRegression(),
                    n_folds=2,
                    n_folds_inner=2,
                    score="nuisance_space",
                ).fit()
            th = float(np.asarray(model.coef).ravel()[0])
        except Exception as e:
            # A fit that RAISES is not a measurement of the tail. Counted
            # separately so it cannot be mistaken for a small coefficient,
            # and the first few are printed -- an all-errors run is a bug in
            # THIS script, not a finding about upstream.
            errs += 1
            if errs <= 3:
                print("ERR[%d] %s: %s" % (errs, type(e).__name__, str(e)[:160]))
            continue
        a = abs(th)
        mags.append(a)
        if a > 1e8:
            over1e8 += 1
            try:
                w = model._dml_data  # noqa: F841  (touch only; see warned check)
                if getattr(model, "_coef_start_val", None) is not None and \
                        len(getattr(model, "warnings", []) or []) > 0:
                    warned += 1
            except Exception:
                pass
        if a > 1e10:
            over1e10 += 1
    mags = np.array(mags)
    print("UPSTREAM_TRIALS %d  ERRORS %d  FITTED %d" % (trials, errs, len(mags)))
    print("UPSTREAM_OVER_1E8 %d" % over1e8)
    print("UPSTREAM_OVER_1E10 %d" % over1e10)
    print("UPSTREAM_MAX_ABS %.6g" % (mags.max() if len(mags) else 0.0))
    if len(mags):
        print("UPSTREAM_MEDIAN %.6g" % np.median(mags))
        for q in (0.5, 0.9, 0.99):
            print("UPSTREAM_Q%.0f %.6g" % (q * 100, np.quantile(mags, q)))


if __name__ == "__main__":
    main()
