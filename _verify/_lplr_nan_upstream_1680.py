"""Is the NaN SE a port defect, or upstream's behaviour too?

Arm (b) (unclamped Newton, upstream-faithful) failed fuzz trial 2 with
`se=NaN, th=-440.16`. Before concluding "the clamp must stay", that claim has
to be tested against UPSTREAM, not against the port's own fuzz invariant --
the port's `se` ceiling is not a property upstream must satisfy.

Two parts:

1. Mechanism, arithmetically. The fuzz DGP makes `d` binary, so
   `exp(-theta*d)` is `exp(440)` at that iterate, not an overflow by itself.
   It is the SQUARING in the variance that overflows:
       gamma = mean(psi^2),  psi ~ 1e191  ->  psi^2 ~ 1e382 = Inf
       J^2                   ~ 1e382      = Inf
       sigma2 = gamma / (J^2 * n)        = Inf / Inf = NaN

2. Upstream on the same DGP. `d` and `y` binary, so run doubleml's LPLR on
   random draws and count how often upstream's own SE is non-finite.

Usage: python _verify/_lplr_nan_upstream_1680.py
"""

import io
import os
import sys
import warnings

import numpy as np
import pandas as pd

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "_verify", "_upstream_ps", "doubleml-0.11.4"))


def part1():
    print("=== 1. mechanism ===")
    th = -440.0
    e = np.exp(-th * 1.0)
    print("exp(-theta*d) with d=1      = %.4e" % e)
    print("is that finite?             =", np.isfinite(e))
    psi = e
    J = e
    with np.errstate(over="ignore", invalid="ignore"):
        gamma = np.mean(np.square(np.array([psi])))
        Jm = J
        sigma2 = gamma / (Jm * Jm * 1.0)
    print("mean(psi^2)                = %.4e  finite=%s"
          % (gamma, np.isfinite(gamma)))
    print("sigma2 = gamma/(J^2*n)     = %s  finite=%s" % (sigma2, np.isfinite(sigma2)))
    print("=> the overflow is in the SQUARING, not in exp itself")


def part2(n_draws=300, n=500, p=6, seed=20260824):
    print()
    print("=== 2. upstream on the same binary DGP ===")
    try:
        import doubleml
        from doubleml.plm import DoubleMLLPLR
        from doubleml.data import DoubleMLData
        from sklearn.linear_model import LinearRegression, LogisticRegression
    except Exception as e:  # pragma: no cover
        print("SKIP: cannot import doubleml: %s" % e)
        return 3
    print("doubleml %s" % getattr(doubleml, "__version__", "?"))

    rng = np.random.default_rng(seed)
    nonfinite_se = 0
    nonfinite_coef = 0
    raised = 0
    ran = 0
    worst = []
    for k in range(n_draws):
        x = rng.normal(size=(n, p))
        a = 0.5 * np.sin(x[:, 0]) + 0.5 * np.cos(x[:, 1]) + 0.5 * rng.normal(size=n)
        d = (rng.random(n) < _expit(a)).astype(float)
        r = (0.25 * x[:, 0] * x[:, 1] + 0.25 * x[:, 2] * x[:, 2]
             + 0.25 * np.cos(x[:, 3]) - 0.5 * np.sin(x[:, 4])
             + (x[:, 5] > 0.0).astype(float) - 0.5)
        prob = _expit(0.5 * d + r)
        y = (rng.random(n) < prob).astype(float)
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                cols = ["x%d" % (j + 1) for j in range(p)]
                df = pd.DataFrame(np.column_stack([x, y, d]),
                                  columns=cols + ["y", "d"])
                obj = DoubleMLData(df, "y", "d", cols)
                model = DoubleMLLPLR(
                    obj,
                    ml_M=LogisticRegression(C=1e6, max_iter=500, solver="lbfgs"),
                    ml_t=LinearRegression(),
                    ml_m=LogisticRegression(C=1e6, max_iter=500, solver="lbfgs"),
                    ml_a=LogisticRegression(C=1e6, max_iter=500, solver="lbfgs"),
                    n_folds=2,
                    n_folds_inner=2,
                    score="nuisance_space",
                    draw_sample_splitting=True,
                ).fit()
        except Exception as e:
            if k < 3:
                import traceback
                print("draw %d: upstream raised %s" % (k, type(e).__name__))
                traceback.print_exc()
            else:
                raised += 1
            continue
        ran += 1
        coef = float(np.asarray(model.coef).ravel()[0])
        se = float(np.asarray(model.se).ravel()[0])
        if not np.isfinite(se):
            nonfinite_se += 1
            worst.append((k, coef, se))
        if not np.isfinite(coef):
            nonfinite_coef += 1
    print("draws run                  = %d / %d" % (ran, n_draws))
    print("draws raised               = %d" % raised)
    print("upstream NON-FINITE se     = %d" % nonfinite_se)
    print("upstream NON-FINITE coef   = %d" % nonfinite_coef)
    if worst:
        print("first few (draw, coef, se):")
        for w in worst[:5]:
            print("   %s" % (w,))
    print()
    # "0 non-finite se" from a run where nothing completed is NOT evidence.
    if ran < n_draws // 2:
        print("INCONCLUSIVE: only %d/%d draws completed." % (ran, n_draws))
        print("A zero count over a run that mostly raised is not upstream")
        print("staying finite; it is the probe measuring nothing.")
        return 3
    if nonfinite_se > 0:
        print("VERDICT: upstream ALSO emits a non-finite SE on this DGP.")
        print("=> 'se must be finite' is NOT an upstream property; it is a")
        print("   port-only invariant that the clamp was silently satisfying.")
    else:
        print("VERDICT: upstream stayed finite on every draw.")
        print("=> the port's NaN is a real port-side defect.")
    return 0


def _expit(z):
    return 1.0 / (1.0 + np.exp(-z))


if __name__ == "__main__":
    part1()
    sys.exit(part2())
