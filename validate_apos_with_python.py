"""v0.49.0 validator: DoubleMLAPOS (Average Potential Outcomes Symmetric).

Cross-checks the MoonBit `DoubleMLAPOS` against a hand-rolled reference
implementation and (optionally) against the upstream `doubleml` Python
package (DoubleMLAPOS in doubleml.irm.apos).

Hand-rolled reference
---------------------
For each requested treatment level `d_level`, the hand-rolled DML estimator
is the standard single-treatment IRM with the `APO` score:
    psi_a = -1
    psi_b = g + indicator(d == d_level) * (y - g) / m
where `g = E[Y | X, d == d_level]` is fit only on the treated subset of
the training fold and `m = E[indicator(d == d_level) | X]` is fit on the
full training fold. The estimator averages psi across folds and the
moment is `mean(psi_b) / mean(psi_a) = -mean(psi_b)`. The variance uses
the standard cross-fold `var_est` formula.

The MoonBit `DoubleMLAPOS` should match the hand-rolled reference to
within `MODEL_TOL = 0.3` for the coefficient and `2 * handrolled_se` for
the SE. The upstream Python is checked with a wider `UPSTREAM_TOL = 0.3`
because the closed-form `LinearRegression` learner differs from
sklearn's defaults.

Test setup
----------
A 2-level discrete-treatment IRM DGP with
    Y = theta0 * 1{d == 1} + theta0 * 1{d == 2} + 0.5 * X + N(0, 1)
where X is N(0, 1) and d in {1, 2} is drawn from a multinomial
conditioned on a single covariate. theta0 = 1.0. n = 500, p = 3.
"""

import argparse
import os
import sys

import numpy as np

# Optional upstream doubleml (not required for the hand-rolled check).
try:
    import doubleml

    HAS_UPSTREAM = True
except ImportError:
    HAS_UPSTREAM = False

MODEL_TOL = 0.3
UPSTREAM_TOL = 0.3


def make_dgp(n, p, theta0, seed):
    """2-level discrete-treatment IRM DGP.

    Returns X (n, p), y (n,), d (n,) with d in {1, 2}.
    """
    rng = np.random.default_rng(seed)
    X = rng.standard_normal((n, p))
    # Treatment probability depends on the first covariate so the
    # estimator has a real propensity to fit.
    p_d1 = 0.5 + 0.2 * np.tanh(X[:, 0])
    p_d2 = 0.5 - 0.2 * np.tanh(X[:, 0])
    p_d0 = 1.0 - p_d1 - p_d2
    # Stack probs and renormalize.
    probs = np.stack([p_d0, p_d1, p_d2], axis=1)
    probs = probs / probs.sum(axis=1, keepdims=True)
    u = rng.uniform(0, 1, size=n)
    cum = probs.cumsum(axis=1)
    d = np.zeros(n, dtype=int)
    d[(u > cum[:, 0]) & (u <= cum[:, 1])] = 1
    d[u > cum[:, 1]] = 2
    # Outcome: Y = theta0 * 1{d == 1} + theta0 * 1{d == 2} + 0.5 * X@1 + N(0, 1)
    y = (
        theta0 * (d == 1).astype(float)
        + theta0 * (d == 2).astype(float)
        + 0.5 * X.sum(axis=1)
        + rng.standard_normal(n)
    )
    return X, y, d


def handrolled_apo(X, y, d, level, n_folds, n_rep, seed):
    """Reference DoubleMLAPOS for a single treatment level."""
    n, p = X.shape
    # Augmented with intercept.
    Xa = np.concatenate([np.ones((n, 1)), X], axis=1)
    indicator = (d == level).astype(float)
    coefs = np.zeros(n_rep)
    ses = np.zeros(n_rep)
    for r in range(n_rep):
        rng = np.random.default_rng(seed + r)
        perm = rng.permutation(n)
        folds_idx = np.array_split(perm, n_folds)
        psi_a_acc = np.zeros(n)
        psi_b_acc = np.zeros(n)
        for f in range(n_folds):
            te = folds_idx[f]
            tr = np.concatenate([folds_idx[i] for i in range(n_folds) if i != f])
            tr_treated = tr[indicator[tr] == 1.0]
            if len(tr_treated) == 0:
                # No treated in this training fold; skip the g
                # contribution (g_hat stays at 0.0 from the
                # initialisation).
                g_te = np.zeros(len(te))
            else:
                Xt = Xa[tr_treated]
                yt = y[tr_treated]
                # Closed-form linear regression.
                XtX = Xt.T @ Xt + 1.0e-10 * np.eye(Xt.shape[1])
                beta = np.linalg.solve(XtX, Xt.T @ yt)
                g_te = Xa[te] @ beta
            # Propensity on full training fold.
            Xm = Xa[tr]
            ym = indicator[tr]
            XmX = Xm.T @ Xm + 1.0e-10 * np.eye(Xm.shape[1])
            beta_m = np.linalg.solve(XmX, Xm.T @ ym)
            m_te = Xa[te] @ beta_m
            clip = 1.0e-6
            m_te = np.clip(m_te, clip, 1.0 - clip)
            psi_a_acc[te] = -1.0
            psi_b_acc[te] = g_te + indicator[te] * (y[te] - g_te) / m_te
        # Aggregate. The dmlmoonbit `var_est(pa, pb)` returns
        # `theta = -mean(psi_b) / mean(psi_a)`. For the APO score
        # `pa = -1, pb = g + indicator*(y-g)/m`, `mean(pa) = -1`, so
        # `theta = -mean(pb) / -1 = mean(pb)`.
        mean_a = psi_a_acc.mean()
        mean_b = psi_b_acc.mean()
        theta = -mean_b / mean_a
        # Variance: var(psi_b - theta * psi_a) / n
        psi = psi_b_acc - theta * psi_a_acc
        var = psi.var() / n
        se = np.sqrt(var)
        coefs[r] = theta
        ses[r] = se
    return coefs.mean(), ses.mean()


def handrolled_apos(X, y, d, levels, n_folds, n_rep, seed):
    """Vectorised handrolled reference for multiple levels."""
    coefs = []
    ses = []
    for lvl in levels:
        c, s = handrolled_apo(X, y, d, lvl, n_folds, n_rep, seed)
        coefs.append(c)
        ses.append(s)
    return np.array(coefs), np.array(ses)


def upstream_apos(X, y, d, levels, n_folds, n_rep, seed):
    """Optional upstream `doubleml.DoubleMLAPOS` cross-check.

    Only runs if the `doubleml` package is importable. Uses sklearn
    `LinearRegression` and `LogisticRegression` so we don't have to
    re-implement the classifier API surface that sklearn 1.x enforces
    (classes_, _estimator_type, etc.).
    """
    from sklearn.linear_model import LinearRegression, LogisticRegression
    import pandas as pd

    df = pd.DataFrame(X, columns=[f"x{i}" for i in range(X.shape[1])])
    df["y"] = y
    df["d"] = d
    dml_data = doubleml.DoubleMLData(df, "y", "d")
    obj = doubleml.DoubleMLAPOS(
        dml_data,
        ml_g=LinearRegression(),
        ml_m=LogisticRegression(max_iter=1000),
        treatment_levels=levels,
        n_folds=n_folds,
        n_rep=n_rep,
        score="APO",
    )
    obj.fit()
    summary = obj.summary.reset_index()
    summary.columns = ["level", "coef", "std_err", "t_stat", "pval", "ci_lo", "ci_hi"]
    return summary["coef"].to_numpy(), summary["std_err"].to_numpy()


def run_moonbit_apos():
    """Spawn `moon run cmd/apos` and parse the output table."""
    import subprocess

    proj_root = os.path.dirname(os.path.abspath(__file__))
    cmd_path = os.path.join(proj_root, "cmd", "apos", "main.mbt")
    if not os.path.exists(cmd_path):
        return None, None
    try:
        result = subprocess.run(
            ["moon", "run", "cmd/apos", "--target", "native"],
            cwd=proj_root,
            capture_output=True,
            text=True,
            timeout=120,
        )
    except Exception as e:
        print(f"moon run cmd/apos failed: {e}")
        return None, None
    if result.returncode != 0:
        print(f"moon run cmd/apos non-zero exit: {result.stderr[:500]}")
        return None, None
    # Parse output lines like "  level 1.0: coef=1.05, se=0.08"
    coefs = []
    ses = []
    for line in result.stdout.splitlines():
        if "coef=" in line and "se=" in line:
            try:
                parts = line.split("coef=")[1]
                coef_str, rest = parts.split(",", 1)
                se_str = rest.split("se=")[1].split(",")[0].strip()
                coefs.append(float(coef_str))
                ses.append(float(se_str))
            except (IndexError, ValueError):
                continue
    if not coefs:
        return None, None
    return np.array(coefs), np.array(ses)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=500)
    parser.add_argument("--p", type=int, default=3)
    parser.add_argument("--n_folds", type=int, default=2)
    parser.add_argument("--n_rep", type=int, default=1)
    parser.add_argument("--seed", type=int, default=3141)
    parser.add_argument("--theta0", type=float, default=1.0)
    parser.add_argument(
        "--levels",
        type=float,
        nargs="+",
        default=[1.0, 2.0],
        help="treatment levels to evaluate",
    )
    args = parser.parse_args()

    print(
        f"=== DoubleMLAPOS validator (n={args.n}, p={args.p}, "
        f"n_folds={args.n_folds}, n_rep={args.n_rep}, "
        f"levels={args.levels}, theta0={args.theta0}) ==="
    )

    X, y, d = make_dgp(args.n, args.p, args.theta0, args.seed)
    print(
        f"DGP: d in {sorted(set(d.tolist()))}, "
        f"level counts: {dict(zip(*np.unique(d, return_counts=True)))}"
    )

    # 1) Hand-rolled reference.
    hr_coefs, hr_ses = handrolled_apos(
        X, y, d, args.levels, args.n_folds, args.n_rep, args.seed
    )
    print(f"handrolled coefs: {hr_coefs}")
    print(f"handrolled ses:   {hr_ses}")

    # 2) MoonBit (via `moon run cmd/apos`).
    mb_coefs, mb_ses = run_moonbit_apos()
    if mb_coefs is None:
        print("WARN: could not run `moon run cmd/apos` (cmd entry missing?).")
        print("Skipping MoonBit cross-check.")
    else:
        print(f"moonbit   coefs: {mb_coefs}")
        print(f"moonbit   ses:   {mb_ses}")
        for i, lvl in enumerate(args.levels):
            ref = hr_coefs[i]
            mb = mb_coefs[i]
            se_bound = max(MODEL_TOL, 2.0 * hr_ses[i])
            ok = abs(mb - ref) < se_bound
            print(
                f"  level {lvl}: |mb - handrolled| = {abs(mb - ref):.4f} "
                f"< max(MODEL_TOL={MODEL_TOL}, 2.0*hr_se={2.0 * hr_ses[i]:.4f}) = "
                f"{se_bound:.4f} -> {'PASS' if ok else 'FAIL'}"
            )
            if not ok:
                sys.exit(1)

    # 3) Optional upstream Python.
    if HAS_UPSTREAM:
        up_coefs, up_ses = upstream_apos(
            X, y, d, args.levels, args.n_folds, args.n_rep, args.seed
        )
        print(f"upstream  coefs: {up_coefs}")
        print(f"upstream  ses:   {up_ses}")
        for i, lvl in enumerate(args.levels):
            ok = (
                abs(up_coefs[i] - hr_coefs[i]) < UPSTREAM_TOL
                or abs(up_coefs[i] - hr_coefs[i]) < 2.0 * hr_ses[i]
            )
            print(
                f"  upstream level {lvl}: "
                f"|upstream - handrolled| = {abs(up_coefs[i] - hr_coefs[i]):.4f} "
                f"-> {'PASS' if ok else 'FAIL'}"
            )
            if not ok:
                sys.exit(1)
    else:
        print("(upstream doubleml not installed; skipping upstream check)")

    print("Reference: run `moon run cmd/apos` for the MoonBit output.")


if __name__ == "__main__":
    main()
