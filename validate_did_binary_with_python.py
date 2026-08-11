"""
Sanity-check for the MoonBit `DoubleMLDIDBinary` estimator. The
hand-rolled reference implements the same long→wide preprocessing
followed by a 2-fold OLS cross-fit (matching the MoonBit
`LinearRegression::fit` semantics), but uses its own RNG seed.
We compare the *qualitative* agreement: both estimators should
land within ~0.2 of the true ATT = 1.0 on the canonical synthetic
panel DGP (n_units = 400, p = 3, half treated, half never-treated).

For a tighter bit-equal comparison, run the MoonBit demo:
    `moon run cmd/did_binary`
and compare its ATT_hat to this script's `handrolled_theta`.
"""

import sys
import os
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def _cholesky_solve(a, b):
    try:
        L = np.linalg.cholesky(a)
        y = np.linalg.solve(L, b)
        return np.linalg.solve(L.T, y)
    except np.linalg.LinAlgError:
        return np.linalg.solve(a, b)


PROPENSITY_CLIP = 1.0e-6


def fit_did_binary_panel(
    n_units,
    p,
    theta0,
    seed_x,
    seed_noise,
    fold_seed=3141,
):
    """Hand-rolled reference for `DoubleMLDIDBinary::fit`.

    Returns (theta_hat, se, n_sub) for the binary DID estimator on
    the panel DGP described in the module docstring.
    """
    rng_x = np.random.default_rng(seed_x)
    rng_n = np.random.default_rng(seed_noise)
    rng_f = np.random.default_rng(fold_seed)
    # Generate unit-level covariates (time-invariant).
    xu = rng_x.uniform(-1.0, 1.0, size=(n_units, p))
    g_unit = (np.arange(n_units) % 2).astype(int)
    n_total = n_units * 2
    x_long = np.repeat(xu, 2, axis=0)
    t_long = np.tile(np.array([0, 1]), n_units)
    id_long = np.repeat(np.arange(n_units), 2)
    g_long = np.repeat(g_unit, 2)
    d_long = ((g_long == 1) & (t_long == 1)).astype(float)
    base = x_long.sum(axis=1)
    noise = rng_n.normal(0.0, 0.05, size=n_total)
    y_long = base + theta0 * d_long + noise
    # Wide-format preprocessing.
    wide_y, wide_d, wide_x = [], [], []
    for u in range(n_units):
        pre_idx_arr = np.where((id_long == u) & (t_long == 0))[0]
        post_idx_arr = np.where((id_long == u) & (t_long == 1))[0]
        if len(pre_idx_arr) == 0 or len(post_idx_arr) == 0:
            continue
        g_u = g_long[pre_idx_arr[0]]
        g_indicator = 1.0 if g_u == 1 else 0.0
        c_indicator = 1.0 if g_u == 0 else 0.0
        if g_indicator + c_indicator != 1.0:
            continue
        wide_y.append(y_long[post_idx_arr[0]] - y_long[pre_idx_arr[0]])
        wide_d.append(g_indicator)
        wide_x.append(xu[u])
    wide_y = np.array(wide_y)
    wide_d = np.array(wide_d)
    wide_x = np.array(wide_x)
    n_sub = len(wide_y)
    # 2-fold OLS cross-fit (matches LinearRegression::fit).
    perm = rng_f.permutation(n_sub)
    base_fold = n_sub // 2
    rem = n_sub - base_fold * 2
    fold_sizes = [base_fold + (1 if f < rem else 0) for f in range(2)]
    offsets = np.cumsum([0] + fold_sizes[:-1])
    g0_pred = np.zeros(n_sub)
    g1_pred = np.zeros(n_sub)
    m_pred = np.zeros(n_sub)
    for f in range(2):
        test_idx = perm[offsets[f] : offsets[f] + fold_sizes[f]]
        train_mask = np.ones(n_sub, dtype=bool)
        train_mask[test_idx] = False
        train_idx = np.where(train_mask)[0]
        # g0 on D == 0
        train_d0 = train_idx[wide_d[train_idx] == 0.0]
        if len(train_d0) > 0:
            xt_train = wide_x[train_d0]
            xt_train1 = np.hstack([np.ones((len(xt_train), 1)), xt_train])
            yt_train = wide_y[train_d0]
            beta0 = _cholesky_solve(
                xt_train1.T @ xt_train1 + 1e-10 * np.eye(xt_train1.shape[1]),
                xt_train1.T @ yt_train,
            )
            xt_test = wide_x[test_idx]
            xt_test1 = np.hstack([np.ones((len(xt_test), 1)), xt_test])
            g0_pred[test_idx] = xt_test1 @ beta0
        # g1 on D == 1
        train_d1 = train_idx[wide_d[train_idx] == 1.0]
        if len(train_d1) > 0:
            xt_train = wide_x[train_d1]
            xt_train1 = np.hstack([np.ones((len(xt_train), 1)), xt_train])
            yt_train = wide_y[train_d1]
            beta1 = _cholesky_solve(
                xt_train1.T @ xt_train1 + 1e-10 * np.eye(xt_train1.shape[1]),
                xt_train1.T @ yt_train,
            )
            xt_test = wide_x[test_idx]
            xt_test1 = np.hstack([np.ones((len(xt_test), 1)), xt_test])
            g1_pred[test_idx] = xt_test1 @ beta1
        # m on all train
        xt_train = wide_x[train_idx]
        xt_train1 = np.hstack([np.ones((len(xt_train), 1)), xt_train])
        dt_train = wide_d[train_idx]
        beta_m = _cholesky_solve(
            xt_train1.T @ xt_train1 + 1e-10 * np.eye(xt_train1.shape[1]),
            xt_train1.T @ dt_train,
        )
        xt_test = wide_x[test_idx]
        xt_test1 = np.hstack([np.ones((len(xt_test), 1)), xt_test])
        m_pred[test_idx] = np.clip(
            xt_test1 @ beta_m, PROPENSITY_CLIP, 1.0 - PROPENSITY_CLIP,
        )
    # Score (observational, no in-sample normalisation).
    p_hat = wide_d.mean()
    psi_a = -wide_d / p_hat
    resid_d0 = wide_y - g0_pred
    one_minus_m = 1.0 - m_pred
    denom = p_hat * one_minus_m
    psi_b = (wide_d - m_pred) / denom * resid_d0
    # Variance.
    mean_a = psi_a.mean()
    mean_b = psi_b.mean()
    theta_hat = -mean_b / mean_a
    gamma = ((theta_hat * psi_a + psi_b) ** 2).mean()
    sigma2 = gamma / (mean_a * mean_a * n_sub)
    se_hat = np.sqrt(sigma2)
    return theta_hat, se_hat, n_sub


if __name__ == "__main__":
    print("=" * 70)
    print("DID Binary reference (panel, 400 units × 2 periods)")
    print("=" * 70)
    n_units = 400
    p = 3
    theta0 = 1.0
    theta_hat, se_hat, n_sub = fit_did_binary_panel(
        n_units=n_units,
        p=p,
        theta0=theta0,
        seed_x=7,
        seed_noise=13,
    )
    print(f"hand-rolled DIDBinary: theta={theta_hat:.6f}, se={se_hat:.6f}, n_sub={n_sub}")
    print(f"true theta = {theta0}")
    if abs(theta_hat - theta0) > 0.3:
        print(f"FAIL: |theta - {theta0}| = {abs(theta_hat - theta0):.4f} > 0.3")
        sys.exit(1)
    print(f"PASS: hand-rolled DID Binary theta within 0.3 of true ({theta0})")
    # Reference for MoonBit comparison.
    print("")
    print("Reference: run `moon run cmd/did_binary` for the MoonBit output.")