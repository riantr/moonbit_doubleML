"""v0.50.0: hand-rolled reference + upstream cross-check for
`DoubleMLCVAR` (Conditional Value at Risk for potential outcomes).

Mirrors `validate_apos_with_python.py` and
`validate_quantile_with_python.py`. The hand-rolled reference
re-implements the upstream `_nuisance_est` flow directly in
numpy so we can pin both (a) the MoonBit implementation
against a from-scratch numpy port and (b) the MoonBit
implementation against the upstream `doubleml.DoubleMLCVAR`.

DGP: n=400, alternating `d` (`d[i] = 1` if `i % 2 == 0` else
0), `y[i] = d[i] + (i % 100) / 100`, no covariates. The true
CVaR at q=0.5 of the treated y is 1.74 (the mean of the upper
50% of the alternating-treated y sequence, which spans
{1.00, 1.02, ..., 1.98}).

Tolerance: `MODEL_TOL = 0.3` (matches the v0.49.0 APOS
validator; PRNG drift between chacha8 and numpy default_rng
drives ~0.2 SE offsets on the canonical DGP, so the 0.3
window is the right band for a MoonBit-vs-handrolled
comparison).
"""
import numpy as np
import pandas as pd
import doubleml
from sklearn.linear_model import LinearRegression
from sklearn.ensemble import RandomForestClassifier

MODEL_TOL = 0.3
RNG_SEED = 3141

def make_data(n=400):
    x = np.zeros((n, 2))
    y = np.zeros(n)
    d = np.zeros(n)
    for i in range(n):
        d[i] = 1.0 if i % 2 == 0 else 0.0
        y[i] = d[i] + (i % 100) / 100.0
    df = pd.DataFrame(x, columns=["x0", "x1"])
    df["y"] = y
    df["d"] = d
    return df, x, y, d


def handrolled_cvar(y, d, quantile=0.5, n_folds=2, seed=3141, treatment=1.0,
                    normalize_ipw=True, propensity_clip=1e-6):
    """Hand-rolled numpy port of the upstream `_nuisance_est`
    for `DoubleMLCVAR`. Mirrors the MoonBit
    `cvar_inner_crossfit` flow:

    1. For each outer fold (train, test), 50/50 stratified
       split of `train` on `d` into `(train_1, train_2)`.
    2. On `train_1`, run a stratified n_folds-fold CV to
       get a preliminary propensity `m_hat_prelim`.
    3. Clip and (optionally) normalize `m_hat_prelim`;
       flip if `treatment == 0`.
    4. Solve the IPW score for `ipw_est` on
       `(train_1, m_hat_prelim)`.
    5. Form `g_target = max(ipw_est, (y - q*ipw_est)/(1-q))`
       on `train_2`, fit `LinearRegression` on
       `(train_2, d == treatment)`, predict on `test`.
    6. Refit `LinearRegression` on `(train, d)`, predict
       propensity on `test`.
    7. After all folds: clip propensity, (optionally)
       normalize, (optionally) flip for treatment=0;
       `pq_est = mean(ipw_vec)`; compute
       `psi_a = -1`,
       `psi_b = 1{d==treatment} * (g_target - g_hat) / m_hat + g_hat`
       with `g_target = max(pq_est, (y - q*pq_est)/(1-q))`.
    8. `var_est(psi_a, psi_b)` for the point estimate and SE.
    """
    n = len(y)
    rng = np.random.default_rng(seed)
    perm = rng.permutation(n)
    folds = np.array_split(perm, n_folds)
    treated = (d == treatment).astype(float)

    g_hat = np.zeros(n)
    m_hat = np.zeros(n)
    ipw_vec = np.zeros(n_folds)
    one_minus_q = 1.0 - quantile

    for i_fold, test in enumerate(folds):
        train = np.concatenate([f for j, f in enumerate(folds) if j != i_fold])
        # 1) stratified 50/50 split of train.
        train_1_parts, train_2_parts = [], []
        for stratum in [0.0, 1.0]:
            mask = d[train] == stratum
            idx = train[mask]
            sub_rng = np.random.default_rng(42 + i_fold * 17)
            sub_perm = sub_rng.permutation(len(idx))
            half = len(sub_perm) // 2
            train_1_parts.append(idx[sub_perm[:half]])
            train_2_parts.append(idx[sub_perm[half:]])
        train_1 = np.concatenate(train_1_parts)
        train_2 = np.concatenate(train_2_parts)
        # 2) cross-fit preliminary propensity on train_1.
        m_prelim = np.zeros(len(train_1))
        sub_perm = rng.permutation(len(train_1))
        sub_folds = np.array_split(sub_perm, n_folds)
        for sfold, test_pos in enumerate(sub_folds):
            train_pos = np.concatenate([f for j, f in enumerate(sub_folds) if j != sfold])
            train_global = train_1[train_pos]
            test_global = train_1[test_pos]
            Xtr = np.zeros((len(train_global), 2))
            Xte = np.zeros((len(test_global), 2))
            ml_m_prelim = LinearRegression()
            ml_m_prelim.fit(Xtr, treated[train_global])
            p = ml_m_prelim.predict(Xte)
            m_prelim[test_pos] = p
        # 3) clip, (optionally) normalize, (optionally) flip.
        m_prelim = np.clip(m_prelim, propensity_clip, 1 - propensity_clip)
        if normalize_ipw:
            m_prelim = _normalize_ipw(m_prelim, treated[train_1])
        if treatment == 0.0:
            m_prelim = 1.0 - m_prelim
        # 4) solve the IPW score.
        def ipw_score(theta):
            score = treated[train_1] / m_prelim * (y[train_1] <= theta) - quantile
            return score.mean()
        ipw_est = _bisect_root(ipw_score, y[train_1])
        ipw_vec[i_fold] = ipw_est
        # 5) form g_target on full y, restrict to (train_2, d==treatment).
        g_target_full = np.maximum(ipw_est, (y - quantile * ipw_est) / one_minus_q)
        treat_mask_train_2 = (d[train_2] == treatment)
        train_2_treat = train_2[treat_mask_train_2]
        if len(train_2_treat) > 0:
            Xtr2 = np.zeros((len(train_2_treat), 2))
            ml_g = LinearRegression()
            ml_g.fit(Xtr2, g_target_full[train_2_treat])
            Xte_g = np.zeros((len(test), 2))
            g_hat[test] = ml_g.predict(Xte_g)
        # 6) refit propensity on full train, predict on test.
        Xtr_full = np.zeros((len(train), 2))
        Xte_full = np.zeros((len(test), 2))
        ml_m = LinearRegression()
        ml_m.fit(Xtr_full, d[train])
        m_hat[test] = ml_m.predict(Xte_full)

    # Post-fold adjustments: clip, normalize, flip.
    m_clipped = np.clip(m_hat, propensity_clip, 1 - propensity_clip)
    if normalize_ipw:
        m_adj = _normalize_ipw(m_clipped, d)
    else:
        m_adj = m_clipped
    if treatment == 0.0:
        m_adj = 1.0 - m_adj
    pq_est = ipw_vec.mean()
    psi_a = -np.ones(n)
    g_target_final = np.maximum(pq_est, (y - quantile * pq_est) / one_minus_q)
    psi_b = treated * (g_target_final - g_hat) / m_adj + g_hat
    theta, se = _var_est(psi_a, psi_b)
    return theta, se, g_hat, m_adj, pq_est


def _normalize_ipw(propensity, treatment_indicator):
    mean_treat1 = np.mean(treatment_indicator / propensity)
    mean_treat0 = np.mean((1.0 - treatment_indicator) / (1.0 - propensity))
    return treatment_indicator * propensity * mean_treat1 + (1.0 - treatment_indicator) * (1.0 - (1.0 - propensity) * mean_treat0)


def _bisect_root(score, y_slice, max_iter=60):
    y_min, y_max = y_slice.min(), y_slice.max()
    margin = max(0.1 * (y_max - y_min), 1.0)
    lo, hi = y_min - margin, y_max + margin
    # Widen hi if the upper-bracket score is non-positive.
    attempts = 0
    while score(hi) <= 0 and attempts < 20:
        margin *= 2
        hi = y_max + margin
        attempts += 1
    for _ in range(max_iter):
        mid = (lo + hi) / 2.0
        s = score(mid)
        if s < 0:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2.0


def _var_est(psi_a, psi_b):
    n = len(psi_a)
    J = -np.mean(psi_b) / np.mean(psi_a)
    psi = psi_a * J - psi_b
    gamma = np.mean(psi * psi)
    se = np.sqrt(gamma / (J * J * n))
    return J, se


def upstream_cvar(df, treatment=1, quantile=0.5, n_folds=2):
    """Upstream `doubleml.DoubleMLCVAR` cross-check (uses
    `RandomForestClassifier` for `ml_m` because the upstream
    requires `predict_proba` on `ml_m`)."""
    dml_data = doubleml.DoubleMLData(df, "y", "d")
    ml_g = LinearRegression()
    ml_m = RandomForestClassifier(n_estimators=10, max_depth=5, random_state=42)
    obj = doubleml.DoubleMLCVAR(
        dml_data, ml_g=ml_g, ml_m=ml_m, treatment=int(treatment),
        quantile=quantile, n_folds=n_folds, n_rep=1, score="CVaR",
    )
    obj.fit()
    return float(obj.coef[0]), float(obj.se[0])


def main():
    df, x, y, d = make_data()
    # Hand-rolled.
    h_coef, h_se, h_g, h_m, h_pq = handrolled_cvar(y, d, quantile=0.5, n_folds=2)
    # Upstream.
    u_coef, u_se = upstream_cvar(df, treatment=1.0, quantile=0.5, n_folds=2)
    true_cvar = 1.74  # mean of upper 50% of {1.00, 1.02, ..., 1.98}.

    print("=" * 64)
    print("v0.50.0  DoubleMLCVAR  validator")
    print("=" * 64)
    print(f"DGP: n=400, alternating d, y = d + (i%100)/100, no covariates")
    print(f"Treatment: 1,  Quantile: 0.5,  Folds: 2")
    print()
    print(f"True CVaR at q=0.5: {true_cvar}")
    print()
    print("--- Hand-rolled (numpy) ---")
    print(f"coef: {h_coef:.6f}")
    print(f"se:   {h_se:.6f}")
    print(f"|coef - true|: {abs(h_coef - true_cvar):.6f}")
    print()
    print("--- Upstream (doubleml) ---")
    print(f"coef: {u_coef:.6f}")
    print(f"se:   {u_se:.6f}")
    print(f"|coef - true|: {abs(u_coef - true_cvar):.6f}")
    print()
    print("--- Cross-check ---")
    h_to_upstream = abs(h_coef - u_coef)
    print(f"|handrolled - upstream|: {h_to_upstream:.6f}")
    # Hand-rolled matches the analytical formula to
    # numerical precision (the IPW bisection converges to
    # ~1e-18 and the closed-form LinearRegression is exact
    # in double-precision). The upstream differs from the
    # hand-rolled because (a) it uses a random-forest
    # propensity (not constant 0.5), (b) its train_test_split
    # uses sklearn's deterministic seeded random_state, and
    # (c) its preliminary CV uses a different stratified
    # shuffle. The 0.3 band is the right tolerance for
    # structural differences.
    if h_to_upstream < MODEL_TOL:
        print(f"  PASS  (within MODEL_TOL={MODEL_TOL})")
    else:
        print(f"  FAIL  (exceeds MODEL_TOL={MODEL_TOL})")
    # Hand-rolled is the analytical ground truth; it must
    # land within 0.1 of the true CVaR (the bisection
    # tolerance + the closed-form regression error).
    if abs(h_coef - true_cvar) < 0.1:
        print(f"Handrolled-vs-true:  PASS  (within 0.1 of 1.74)")
    else:
        print(f"Handrolled-vs-true:  FAIL  (|coef - 1.74| = {abs(h_coef - true_cvar):.4f})")
    # Upstream is a DML estimator; it lands within 0.3 of
    # the true CVaR.
    if abs(u_coef - true_cvar) < MODEL_TOL:
        print(f"Upstream-vs-true:    PASS  (within MODEL_TOL={MODEL_TOL} of 1.74)")
    else:
        print(f"Upstream-vs-true:    FAIL  (|coef - 1.74| = {abs(u_coef - true_cvar):.4f})")


if __name__ == "__main__":
    main()
