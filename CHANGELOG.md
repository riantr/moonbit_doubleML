# Changelog

All notable changes to `mavis/dml` are documented here. Each TODO entry
lists the bugs / polish items fixed, the test count delta, and the
verification verdict.

Format is loosely based on [Keep a Changelog](https://keepachangelog.com/),
with `Added` / `Changed` / `Fixed` / `Removed` per version. The state
under each TODO is reset on every release — the most recent verified
release is the canonical version.

---

## [0.4.1] — REVIEW H1 fix

### Fixed
- **`solve_pq` upper bracket robustness** (`quantile.mbt:150-188`):
  the IPW bisection bracket `[y_min - margin, y_max + margin]` relied
  on `mean(treated/m) - q > 0` at the upper end, which fails when
  `q ≥ 0.95` and the treatment is sparse. The fix detects the bad
  upper bracket by checking the sign at initialization, then widens
  `hi` exponentially up to 20 times. After 20 widens, or if the
  lower bracket sign is wrong, the function aborts with a clear
  message rather than silently converging to the wrong root.

### Tests
- 114 / 114 across all 4 backends (1 new test:
  `panic_solve_pq_aborts_when_upper_bracket_structurally_invalid`).
- 9 / 9 `validate_*_with_python.py` PASS (no regression; canonical
  DGPs use `q = 0.5` where the bracket is always valid).

### Verification
- See `_verify/H1-verdict.md` (VERDICT: PASS).

---

## [0.4.0] — TODO #11c.4

---

## [0.4.0] — TODO #11c

### Added
- **`LinearRegression::sandwich_se`** (`linear.mbt`): HC0 heteroskedasticity-
  consistent SE diagonal. Used by `DoubleMLBLP` by default.
- **`LinearRegression::xtwx_inv_diag`** (`linear.mbt`): cached diagonal of
  `(X^T W X + ridge I)^{-1}` from the WLS fit. Used by `DoubleMLRDD` for the
  WLS-aware intercept variance.
- **`DoubleMLBLP::cov_type`** field (`blp_policy.mbt`): `"HC0"` (default,
  new) or `"nonrobust"` (legacy homoskedastic).
- **`PolicyTreeNode`** enum (`blp_policy.mbt`): `Leaf(Int)` /
  `Split(Int, Double, PolicyTreeNode, PolicyTreeNode)`. The multi-level
  recursion uses these internally; `DoubleMLPolicyTree` exposes the
  depth-1 surface (`split_feature`, `split_value`, `left_treatment`,
  `right_treatment`) for backward compatibility.

### Changed
- **BLP SE formula**: was `sqrt(RSS / (n - p))` (uniform across
  coefficients, Bug #5 fix in TODO #11a). Now `sqrt(cov_diag[j])` where
  `cov_diag` is the HC0 sandwich diagonal; the constant SE was already
  per-coefficient in TODO #11a, this is the heteroskedasticity-robust
  upgrade to match upstream `statsmodels.OLS(cov_type='HC0')`.
- **RDD SE formula**: now scaled by `(X^T W X)^{-1}[0, 0]`, the
  WLS-OLS analogue of the homoskedastic-OLS scaling. The previous
  `v / n^2` lacked the `(X^T W X)^{-1}` factor.
- **`DoubleMLPolicyTree::fit`**: now recursively builds a tree of
  depth `self.depth` (was a single-level stump regardless of `depth`).
  The `depth` field is now honoured; default stays `1`.

### Fixed
- **`DoubleMLPolicyTree`** previously ignored the `depth` parameter — the
  fit was always a single-level stump. TODO #11c.3 implements an actual
  recursive tree-growth (root split → 2 subtrees → 2 sub-subtrees → …).
  The variance-reduction gain formula (TODO #11a Bug #8) is preserved.

### Tests
- 113 / 113 (1 new test: `policy_tree_depth_two_recurses`).
- 9 / 9 `validate_*_with_python.py` PASS.

### Verification
- See `_verify/TODO-11c-verdict.md` (VERDICT: PASS, A rating).

---

## [0.3.0] — TODO #11b

### Added
- **`pq_score_ipw`** (`quantile.mbt`): IPW-only score for the PQ bisection.
  No `g` cross-fit per iteration.
- **`lpq_score_ipw`** (`lpq.mbt`): IPW-only score for the LPQ bisection.
- **`g_cross_fit_count`** module-level counter (`quantile.mbt`): public
  `reset_g_cross_fit_count()` / `g_cross_fit_calls()` for tests to verify
  the cross-fit count drops from 50+ to 3-5 per fit.

### Changed
- **`solve_pq`** (`quantile.mbt`): now returns `(theta, psi, deriv)`
  instead of `(theta, se)`. The bisection uses `pq_score_ipw` (no `g`
  cross-fit per iteration); `g` cross-fit happens ONCE at the bisected
  theta + 2 more for the numerical derivative (3 total vs 50+).
- **`DoubleMLQTE::fit`**: SE now uses the joint variance of
  `psi_d1 / deriv_d1 - psi_d0 / deriv_0` (the delta-method variance of
  the derived parameter `theta_qte = theta_d1 - theta_d0`). The previous
  `sqrt(s1^2 + s0^2)` quadrature assumed zero covariance between the
  two per-treatment influence functions, which is false because both
  PQs share the same `m` and the same folds.
- **`DoubleMLLPQ::fit`**: bisection uses `lpq_score_ipw` (no `g0`/`g1`
  cross-fit per iteration); `g0`/`g1` cross-fit happens ONCE at the
  bisected theta + 4 more for the numerical derivative (6 total vs 100+).

### Fixed
- **QTE SE** was `sqrt(s1^2 + s0^2)` — quadrature under zero cov.
  Bug #2 fix.
- **PQ / LPQ g cross-fit** was 50-100 per fit. Bug #3 fix; the math is
  the same, the speed is 10-20x.

### Tests
- 112 / 112 (7 new tests on the IPW-bisection / cross-fit-count paths).
- 9 / 9 `validate_*_with_python.py` PASS.

### Verification
- See `_verify/TODO-11b-verdict.md` (VERDICT: PASS, A rating).

---

## [0.2.0] — TODO #11a

### Fixed
- **Bug #1** (`ssm.mbt:243-275`): SSM `pi` data leakage. The `pi` array
  was appended as a feature to `g_d1` / `g_d0` training, leaking the
  test-fold `pi` into the training fold. Removed the `augment_one_col`
  call from the g designs; the upstream MAR fit uses `x` only.
- **Bug #4** (`lpq.mbt:23-46, 95-105`): LPQ missing `sign = 2*treatment - 1`
  in the score, and the complier probability was averaged per fold
  instead of computed on the full sample. Added the sign factor; switched
  to full-sample `E[D | Z=1] - E[D | Z=0]`.
- **Bug #5** (`blp_policy.mbt:32-35`): BLP per-coefficient SE was uniform
  `sqrt(RSS / (n - p))` for all coefficients. Added `covariance_diagonal`
  to `LinearRegression` so the SE is `sqrt(sigma^2 * (X^T X)^{-1}_{jj})`.
- **Bug #6** (`rdd.mbt:108`): RDD kernel weights were computed but only
  used in the variance sum; the OLS fit ignored them. Added
  `fit_weighted(x, y, w)` to `LinearRegression`; `rdd_side` now uses WLS.
- **Bug #7** (`rdd.mbt:160-161`): Fuzzy RDD delta-method variance was
  missing the `−2 * raw * cov(raw, jump) / jump^3` cross term. Added the
  residual return (4-tuple); the cross-cov is computed empirically.
- **Bug #8** (`blp_policy.mbt:65, 92-134`): `DoubleMLPolicyTree` ignored
  `depth` (always depth-1 stump); gain was `|sum_left| + |sum_right|`
  instead of weighted-variance-reduction. Added `require(depth >= 1)`
  precondition; switched to variance-reduction gain.

### Added
- **`LinearRegression::covariance_diagonal(sigma2)`** (`linear.mbt`):
  diagonal of `sigma^2 * (X^T X + ridge I)^{-1}`.
- **`LinearRegression::fit_weighted(x, y, w)`** (`linear.mbt`): WLS via
  Cholesky-solved `X^T W X beta = X^T W y`.
- **`augment_with_intercept`** (`linear.mbt`): made `pub` so `LogisticRegression`
  IRLS can reuse it.

### Tests
- 105 / 105 (9 new tests: 3 linear, 1 ssm, 1 lpq, 2 rdd, 2 blp_policy).
- 9 / 9 `validate_*_with_python.py` PASS.

### Verification
- See `_verify/TODO-11a-verdict.md` (VERDICT: PASS, A- rating).

---

## [0.1.0] — TODO #1–#10

This is the initial port. Each TODO addressed a separate concern:

- **TODO #1**: runtime checks + panic probes (`check.mbt`, 4 `panic_*` probes).
- **TODO #2**: empty IRM/IIVM fold handling (fix `filter_indices` bug).
- **TODO #3**: per-repetition coefficient / SE aggregation (`aggregator.mbt`).
- **TODO #4**: `LogisticRegression` (Newton-Raphson IRLS).
- **TODO #5**: test hardening (removed `ignore(se)`, added `>0` / `<1` checks).
- **TODO #6**: 17 `panic_*` tests covering 17 production `require(...)` sites.
- **TODO #7**: Python `n_rep=5` cross-checks (5 sections in `cmd/main`).
- **TODO #8**: `seed_to_bytes` 32-bit little-endian consolidation.
- **TODO #9**: `kahan_sum` (compensated summation) applied to `matmul`,
  `matvec`, `dot`, `mean`, `cholesky`, `var_est`.
- **TODO #10**: `var_est.mbt` extraction (was 12-line inline block in 6 models).

### Tests
- 96 / 96 at the end of TODO #10 (up from 53 at the start of TODO #1).

### Verification
- One `_verify/TODO-N-verdict.md` per TODO (all PASS).
- Final `_verify/final-verdict.md` (VERDICT: PASS, B+ rating) covering
  build + test on all 4 backends, end-to-end `moon run cmd/main`,
  9 `validate_*_with_python.py`, and the 8 known-deferred Critical/High
  bugs (all expanded into TODO #11a–#11c.4).

---

## Versioning

The project is at **0.4.0** as of the TODO #11c.4 release. The version
number is exposed in `moon.mod`. The next minor (0.5.0) will be the
first release after the policy-tree multi-level recursion, sandwich
SE, and LPQ adaptive step have all been verified.
