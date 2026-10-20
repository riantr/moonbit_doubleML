"""Does REAL upstream also fail at small n? If so, this is not a port defect.

Section 19's sweep found BAGGED surviving strictly more often than PLAIN at
n=60/100/160 -- direction confirmed -- but BAGGED still failed 9/25 at n=60.
That arm is upstream's own captured `a_hat` plus upstream's own `t_hat`,
`beta`, `m_hat`, `W_inner` and `theta0`. So it is, to the extent this probe
reconstructs it, upstream's configuration.

That makes the decisive question obvious and cheap: run REAL upstream
(`DoubleMLLPLR(...).fit()`, not a reconstruction) on this same DGP at the
same small n and count non-finite SE. The existing
`_lplr_nan_upstream_1680.py` only swept n=500, where it found 0/300 -- which
is exactly the regime where nothing fails.

Two outcomes, and they mean very different things:

  * upstream ALSO non-finite at n=60  -> the port's disclosed small-n
    "divergence" is not a port defect. The estimator is ill-posed at small n
    for BOTH, the clamp merely converts upstream's non-finite into a finite
    wrong number, and the honest framing changes from "known deviation, we
    could not find the cause" to "upstream does not define an answer here".

  * upstream finite at n=60          -> the reconstruction in 19's sweep is
    not faithful, and the bagged difference is still only a partial
    explanation of the port's failures.

Either way this is measurable now, and it was not measurable before.

Run: python _verify/_lplr_upstream_smalln_1680.py
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

NS = [60, 100, 160, 500]
DRAWS = 25


def expit(z):
    return 1.0 / (1.0 + np.exp(-z))


def make_dgp(rng, n=500, p=6):
    x = rng.normal(size=(n, p))
    a = 0.5 * np.sin(x[:, 0]) + 0.5 * np.cos(x[:, 1]) + 0.5 * rng.normal(size=n)
    d = (rng.random(n) < expit(a)).astype(float)
    r = (0.25 * x[:, 0] * x[:, 1] + 0.25 * x[:, 2] * x[:, 2]
         + 0.25 * np.cos(x[:, 3]) - 0.5 * np.sin(x[:, 4])
         + (x[:, 5] > 0.0).astype(float) - 0.5)
    y = (rng.random(n) < expit(0.5 * d + r)).astype(float)
    return x, y, d


def main(seed=20260824, p=6):
    try:
        from doubleml.plm import DoubleMLLPLR
        from doubleml.data import DoubleMLData
        from sklearn.linear_model import LogisticRegression, LinearRegression
    except Exception as e:  # pragma: no cover
        print("SKIP: cannot import doubleml: %s" % e)
        return 3

    def mk():
        return LogisticRegression(C=1e6, max_iter=500, solver="lbfgs")

    print("draws per n: %d   n_folds=2, n_folds_inner=2, score=nuisance_space"
          % DRAWS)
    print()
    print("%-6s %-10s %-14s %-14s %s"
          % ("n", "completed", "non-finite se", "non-finite coef",
             "root-warnings"))
    print("-" * 72)

    verdict_rows = []
    for n in NS:
        rng = np.random.default_rng(seed + n)
        ran = nonfinite_se = nonfinite_coef = 0
        root_warn = 0
        big = []
        for k in range(DRAWS):
            x, y, d = make_dgp(rng, n, p)
            cols = ["x%d" % (j + 1) for j in range(p)]
            df = pd.DataFrame(np.column_stack([x, y, d]),
                              columns=cols + ["y", "d"])
            try:
                with warnings.catch_warnings(record=True) as caught:
                    warnings.simplefilter("always")
                    obj = DoubleMLData(df, "y", "d", cols)
                    mdl = DoubleMLLPLR(
                        obj, ml_M=mk(), ml_t=LinearRegression(),
                        ml_m=mk(), ml_a=mk(),
                        n_folds=2, n_folds_inner=2,
                        score="nuisance_space", draw_sample_splitting=True)
                    mdl.fit()
                    msgs = [str(w.message) for w in caught]
            except Exception:
                continue
            ran += 1
            coef = float(np.asarray(mdl.coef).ravel()[0])
            se = float(np.asarray(mdl.se).ravel()[0])
            if not np.isfinite(se):
                nonfinite_se += 1
                big.append((k, coef, se))
            if not np.isfinite(coef):
                nonfinite_coef += 1
            if any("Could not find a root" in m for m in msgs):
                root_warn += 1

        verdict_rows.append((n, ran, nonfinite_se, nonfinite_coef, root_warn))
        print("%-6d %-10s %-14s %-14s %s"
              % (n, "%d/%d" % (ran, DRAWS),
                 "%d" % nonfinite_se, "%d" % nonfinite_coef, root_warn))
        for b in big[:4]:
            print("       non-finite se: draw=%d coef=%.6g se=%.6g"
                  % (b[0], b[1], b[2]))

    print()
    print("=== comparison against section 19's sweep (same DGP, same seeds) ===")
    print("%-6s %-18s %-18s %s" % ("n", "19-sweep BAGGED", "19-sweep PLAIN",
                                  "REAL upstream"))
    for n, ran, nf_se, nf_coef, rw in verdict_rows:
        if n == 60:
            b, q = "16/25", "15/25"
        elif n == 100:
            b, q = "21/25", "19/25"
        elif n == 160:
            b, q = "20/25", "19/25"
        else:
            b, q = "25/25", "25/25"
        print("%-6d %-18s %-18s %s" % (n, b, q, "%d/%d finite se"
                                       % (ran - nf_se, ran)))
    print()
    small = [r for r in verdict_rows if r[0] < 500]
    any_nf = any(r[2] > 0 for r in small)
    any_warn = any(r[4] > 0 for r in small)
    if any_nf or any_warn:
        print("VERDICT: UPSTREAM ALSO BREAKS AT SMALL n.")
        print("  non-finite se : %s"
              % {r[0]: r[2] for r in verdict_rows})
        print("  root warnings : %s"
              % {r[0]: r[4] for r in verdict_rows})
        print("=> the port's disclosed small-n divergence is NOT a port-only")
        print("   defect. The estimator is ill-posed at small n for upstream")
        print("   too; the clamp converts upstream's non-finite into a finite")
        print("   wrong number rather than causing one.")
    else:
        print("VERDICT: upstream is finite and warns-free at every n tried.")
        print("=> section 19's BAGGED arm is NOT a faithful reconstruction of")
        print("   upstream, and the bagged difference remains only a partial")
        print("   explanation.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
