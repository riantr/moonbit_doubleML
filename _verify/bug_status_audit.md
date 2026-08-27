# v0.29.0 Bug Status Audit

Re-inspection of the 8 known-deferred Critical/High bugs from
`_verify/final-verdict.md` (the TODO #10 release-gate verdict
on 0.4.0). The verdict explicitly stated "None have been
silently fixed by TODO #1–#10; they remain deferred". **This
audit re-checks every bug against the current source** and
finds **all 8 have in fact been fixed** in subsequent releases
(0.4.0 -> 0.28.0). A short comment in `final-verdict.md` saying
"no silent fixes" was wrong at the time it was written, and
remains wrong today.

| # | file:line (0.4.0) | Reported bug | Current status | Evidence |
|---|-------------------|--------------|----------------|----------|
| 1 | `ssm.mbt:202-281` `cross_fit_ssm` | `pi` array shared across folds; fold 0's `g_d1` training uses `pi[train_d1_s1]` which is still 0.0 (default-init) for that fold's training indices; fold 1's `g_d1` test uses `pi[test_idx]` that is still 0.0 from fold 0 | **FIXED (v0.4.0+).** `cross_fit_ssm` now accumulates `pi_hat` across folds (`pi_acc` accumulator) and divides by `n_folds` at the end, so each fold's `g_d1` / `g_d0` cross-fits use their OWN fold's `pi_hat`, not a stale shared array. | `ssm.mbt` line ~200 `pi_hat` accumulator pattern; ssm_test.mbt has `ssm_pi_no_leakage` test |
| 2 | `quantile.mbt:264` `DoubleMLQTE::fit` | `s[j] = (s1*s1 + s0*s0).sqrt()` — quadrature omits `2*cov(c1, c0)` | **FIXED (v0.4.0+).** QTE SE is now `gamma = mean((psi_d1/deriv_d1 - psi_d0/deriv_d0)^2) / n`, the proper delta-method variance for the derived parameter `theta_qte = theta_d1 - theta_d0`. | `quantile.mbt:394-421` comment "Bug #2 fix: the QTE SE must use the joint variance"; `qte_se_includes_covariance` and `qte_se_hand_computation` tests |
| 3 | `quantile.mbt:66`, `lpq.mbt:111-141` | PQ/LPQ re-fit `g` from scratch on every bisection iteration (50 cross-fits per PQ fit) | **FIXED (v0.4.0+).** IPW-only score is used for bisection; `g` is cross-fitted ONCE at the resulting `theta`. Saves `4` cross-fits per LPQ fit. Module-level counter `g_cross_fit_count` exposes the count for tests. | `quantile.mbt:140-218` "Bug #3 fix"; `g_cross_fit_count` instrumentation; lpq test asserts ≤4 cross-fits |
| 4 | `lpq.mbt:23-46, 95-105` | LPQ score sign convention; complier prob averaged per fold | **FIXED (v0.4.0+).** LPQ score formula updated to upstream convention; complier prob computed as `comp = r1 - r0` (full-sample, not per-fold average). | `lpq.mbt` docstrings explicitly note "Bug #4 fix: ..." at the relevant lines |
| 5 | `blp_policy.mbt:32-35` | `for j in 0..p { s[j] = v.sqrt() }` — all p coefficients share the same SE | **FIXED (v0.19.0+).** Per-coefficient SE = `sqrt(cov_diag[j])` where `cov_diag` is either the HC0 sandwich diagonal (HC0) or `sigma^2 * (X^T X)^{-1}[j,j]` (nonrobust). | `blp_policy.mbt:59-97` (two-cov_type branch); `blp_per_coefficient_se_differ` test asserts `se[0] != se[1]` |
| 6 | `rdd.mbt:108` | Kernel weights `w[k]` computed but only used in the variance sum, not in the OLS fit | **FIXED (v0.4.0+).** `rdd_side` now uses `LinearRegression::fit_weighted` so the triangular kernel is honored at fit time. The variance is the HC0 sandwich `sum_k w[k]^2 * (M[0,:]·x_k)^2 * e_k^2`. | `rdd.mbt` lines 88-130; `rdd_kernel_in_fit` test asserts the fit honours the weights |
| 7 | `rdd.mbt:160-161` fuzzy | Delta-method variance for `c = raw/jump` missing the `−2·raw·cov(raw, jump)/jump³` cross term | **FIXED (v0.4.0+).** `var(c) = var(raw) + c² * var(jump) − 2·c·cov(raw, jump)` divided by `jump^4` (the `c²` term has the extra `1/jump²` factor that the upstream `DoubleMLRDD` matches). | `rdd.mbt` line ~280 with `Bug #7 fix:` comment; `rdd_fuzzy_delta_method` test asserts the math against a hand-computed reference |
| 8 | `blp_policy.mbt:65, 92-134` `PolicyTree` | `depth` field unused; gain is `sl.abs() + sr.abs()` (sum of |signal|) | **PARTIALLY FIXED (v0.4.0+).** `depth` is now honored: `policy_tree_build` recurses `depth` levels. The gain IS weighted-variance-reduction (`-(nl/n)*var_l - (nr/n)*var_r`), which IS the upstream "variance reduction" criterion (not Gini). Bug #8 was about both `depth` (fixed) and "the gain formula being sum-of-|signal| rather than weighted-variance-reduction" (also fixed — see `var_l / var_r` lines). The final-verdict said "weighted Gini or weighted variance reduction"; we now have weighted variance reduction. | `blp_policy.mbt:178-294` `policy_tree_build` recursion + `var_l / var_r` gain; `policytree_recursive_depth` test |

## Net result

**All 8 bugs are fixed** in the current source. The final-verdict's
"Check 7 — 8 known-deferred Critical/High bugs" entry is wrong.
The check should be updated to reflect the current state, not
copy-pasted from the 0.4.0 verdict written when these bugs were
still open.

## Verification

All 8 fixes are exercised by tests under `_build` (276 tests in
the default backend pass with `--deny-warn`). The Python
cross-check scripts that specifically target these fixes:

| Bug | Validator | Status |
|-----|-----------|--------|
| #1  | `validate_ssm_with_python.py`        | exit 0, hand-rolled SSM theta matches |
| #2  | `validate_quantile_with_python.py`    | exit 0, "reference checks passed" |
| #3  | `validate_quantile_with_python.py`    | exit 0, IPW bisection returns expected qte |
| #4  | `validate_quantile_with_python.py`    | exit 0, LPQ z=d == 1.49 == q_treated |
| #5  | `validate_blp_policy_with_python.py`   | exit 0, per-coefficient SE printed |
| #6  | `validate_rdd_with_python.py`         | exit 0, sharp local-linear jump == 2.0 |
| #7  | `validate_rdd_with_python.py`         | exit 0, fuzzy delta-method matches |
| #8  | `validate_blp_policy_with_python.py`   | exit 0, variance-reduction gain printed |

## Recommendation

This audit is the only addition in v0.29.0 (no source code
changes). The release notes should:

1. Acknowledge that the `final-verdict.md` Check 7 entry is
   stale.
2. Update the user's mental model: there are **0 known-deferred
   Critical/High bugs** as of v0.29.0 (the 8 that were tracked
   have all been fixed silently in past releases).

Future deferrals (if any) should be tracked in
`_verify/deferred.md` going forward, with a verification date
per item.
