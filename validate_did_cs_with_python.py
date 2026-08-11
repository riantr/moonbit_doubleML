"""
Sanity-check for the MoonBit `DoubleMLDIDCS` (Callaway-Sant'Anna
staggered DID) estimator. We build the same multi-cohort panel
DGP as `did_cs_test.mbt`, run a hand-rolled CS-DID reference
implementation that mirrors the MoonBit `DoubleMLDIDBinary` per-
cell estimator, and verify (a) the per-(g, t) ATT estimates
recover the true treatment effect of 1.0, and (b) the per-cell
SEs are positive.

The hand-rolled reference uses the same Cholesky-based OLS
learner + observational Sant'Anna-Zhao score as the MoonBit
`DoubleMLDIDBinary::fit` path.
"""

import sys
import os
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


PROPENSITY_CLIP = 1.0e-6


def _cholesky_solve(a, b):
    try:
        L = np.linalg.cholesky(a)
        y = np.linalg.solve(L, b)
        return np.linalg.solve(L.T, y)
    except np.linalg.LinAlgError:
        return np.linalg.solve(a, b)


def fit_one_cell(x_train, y_train, d_train, x_test, p1, p_train):
    """Per-cell 2-fold OLS DML with the observational Sant'Anna-
    Zhao (2020) score. `d_train` and `d_test` are 0/1; `p1` is the
    number of pre-treatment features; `p_train` is the propensity
    clip."""
    # Cross-fit by half-split.
    n = len(y_train)
    half = n // 2
    perm = np.random.default_rng(3141).permutation(n)
    g0_pred = np.zeros(n)
    g1_pred = np.zeros(n)
    m_pred = np.zeros(n)
    for f in range(2):
        test_idx = perm[f * half : (f + 1) * half] if f == 0 else perm[half:]
        train_idx = np.setdiff1d(np.arange(n), test_idx)
        # g0 on D == 0
        train_d0 = train_idx[d_train[train_idx] == 0.0]
        if len(train_d0) > 0:
            xt = np.hstack(
                [np.ones((len(train_d0), 1)), x_train[train_d0, :p1]]
            )
            yt = y_train[train_d0]
            beta0 = _cholesky_solve(
                xt.T @ xt + 1e-10 * np.eye(xt.shape[1]),
                xt.T @ yt,
            )
            xs = np.hstack(
                [np.ones((len(test_idx), 1)), x_test[test_idx, :p1]]
            )
            g0_pred[test_idx] = xs @ beta0
        # g1 on D == 1
        train_d1 = train_idx[d_train[train_idx] == 1.0]
        if len(train_d1) > 0:
            xt = np.hstack(
                [np.ones((len(train_d1), 1)), x_train[train_d1, :p1]]
            )
            yt = y_train[train_d1]
            beta1 = _cholesky_solve(
                xt.T @ xt + 1e-10 * np.eye(xt.shape[1]),
                xt.T @ yt,
            )
            xs = np.hstack(
                [np.ones((len(test_idx), 1)), x_test[test_idx, :p1]]
            )
            g1_pred[test_idx] = xs @ beta1
        # m on all train
        xt = np.hstack([np.ones((len(train_idx), 1)), x_train[train_idx, :p1]])
        dt = d_train[train_idx]
        beta_m = _cholesky_solve(
            xt.T @ xt + 1e-10 * np.eye(xt.shape[1]),
            xt.T @ dt,
        )
        xs = np.hstack([np.ones((len(test_idx), 1)), x_test[test_idx, :p1]])
        m_pred[test_idx] = np.clip(
            xs @ beta_m, p_train, 1.0 - p_train,
        )
    return g0_pred, g1_pred, m_pred


def fit_did_cs_panel(
    n_per_cohort,
    p,
    theta0,
    n_periods,
    seed_x,
    seed_noise,
):
    """Hand-rolled CS-DID: for each (g, t_eval) cell with t_eval >
    g, restrict the long-format panel to (g == g_value) ∪
    (g == never_treated), then call the per-cell DML binary DID
    estimator. Returns a dict {(g, t_eval): (theta_hat, se, n_sub)}.
    """
    rng_x = np.random.default_rng(seed_x)
    rng_n = np.random.default_rng(seed_noise)
    cohort_count = n_periods  # g = 0, 1, ..., n_periods - 1
    n_units = n_per_cohort * cohort_count
    n_total = n_units * n_periods
    # Generate unit-level covariates (time-invariant).
    xu = rng_x.uniform(-1.0, 1.0, size=(n_units, p))
    # Long-format panel.
    x_long = np.repeat(xu, n_periods, axis=0)
    t_long = np.tile(np.arange(n_periods), n_units)
    id_long = np.repeat(np.arange(n_units), n_periods)
    g_unit = (np.arange(n_units) // n_per_cohort).astype(int)
    g_long = np.repeat(g_unit, n_periods)
    d_long = ((g_long > 0) & (t_long >= g_long)).astype(float)
    base = x_long.sum(axis=1)
    noise = rng_n.normal(0.0, 0.05, size=n_total)
    y_long = base + theta0 * ((g_long > 0) & (t_long > g_long)).astype(float) + noise
    results = {}
    for g_value in range(1, n_periods):
        for t_eval in range(g_value + 1, n_periods):
            t_pre = g_value
            # Restrict to (g == g_value) ∪ (g == 0) and t ∈ {t_pre, t_eval}.
            keep = ((g_long == g_value) | (g_long == 0)) & (
                (t_long == t_pre) | (t_long == t_eval)
            )
            sub_y = y_long[keep]
            sub_d = d_long[keep]
            sub_t = t_long[keep]
            sub_x = x_long[keep]
            # Wide-format: y_diff = y_post - y_pre, G_indicator
            # = (g == g_value), x = pre-period covariates.
            y_post = sub_y[sub_t == t_eval]
            y_pre = sub_y[sub_t == t_pre]
            x_post = sub_x[sub_t == t_eval]
            x_pre = sub_x[sub_t == t_pre]
            g_post = g_long[keep][sub_t == t_eval]
            y_diff = y_post - y_pre
            G_indicator = (g_post == g_value).astype(float)
            # Drop rows with no G or C indicator.
            valid = (G_indicator + (1.0 - G_indicator)) > 0
            y_diff = y_diff[valid]
            G_indicator = G_indicator[valid]
            x_pre = x_pre[valid]
            n_sub = len(y_diff)
            if n_sub < 8:
                continue
            # Per-cell DML.
            g0_pred, g1_pred, m_pred = fit_one_cell(
                x_pre, y_diff, G_indicator, x_pre,
                p1=p, p_train=PROPENSITY_CLIP,
            )
            # Score (observational, no in-sample norm).
            p_hat = G_indicator.mean()
            psi_a = -G_indicator / p_hat
            resid_d0 = y_diff - g0_pred
            one_minus_m = 1.0 - m_pred
            denom = p_hat * one_minus_m
            psi_b = (G_indicator - m_pred) / denom * resid_d0
            mean_a = psi_a.mean()
            mean_b = psi_b.mean()
            theta_hat = -mean_b / mean_a
            gamma = ((theta_hat * psi_a + psi_b) ** 2).mean()
            sigma2 = gamma / (mean_a * mean_a * n_sub)
            se_hat = np.sqrt(sigma2)
            results[(g_value, t_eval)] = (theta_hat, se_hat, n_sub)
    return results


if __name__ == "__main__":
    print("=" * 70)
    print("DID CS (Callaway-Sant'Anna) reference, multi-cohort panel")
    print("=" * 70)
    n_per_cohort = 50
    p = 3
    theta0 = 1.0
    n_periods = 4
    results = fit_did_cs_panel(
        n_per_cohort=n_per_cohort,
        p=p,
        theta0=theta0,
        n_periods=n_periods,
        seed_x=11,
        seed_noise=13,
    )
    print(f"true theta = {theta0}")
    print("")
    fail = 0
    for (g_value, t_eval), (att, se, n_sub) in sorted(results.items()):
        marker = "PASS" if abs(att - theta0) < 0.5 and se > 0.0 else "FAIL"
        if marker == "FAIL":
            fail += 1
        print(
            f"  (g={g_value}, t={t_eval}): theta={att:.4f}, "
            f"se={se:.4f}, n_sub={n_sub}  [{marker}]"
        )
    if fail > 0:
        print(f"FAIL: {fail} cells out of range")
        sys.exit(1)
    print("")
    print(f"PASS: all {len(results)} (g, t) cells within 0.5 of true ({theta0})")
    print("")
    print("Reference: run `moon run cmd/did_cs` for the MoonBit output.")
