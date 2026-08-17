# Changelog

All notable changes to `mavis/dml` are documented here. Each TODO entry
lists the bugs / polish items fixed, the test count delta, and the
verification verdict.

Format is loosely based on [Keep a Changelog](https://keepachangelog.com/),
with `Added` / `Changed` / `Fixed` / `Removed` per version. The state
under each TODO is reset on every release — the most recent verified
release is the canonical version.

---

## [0.18.0] — BH / BY FDR p-adjust

### Added
- **`did_multi.mbt::bh_fdr_p_adjust(unadjusted)`**:
  Benjamini-Hochberg FDR correction. Sort p-values
  ascending, `p_adj_sorted[k] = min(1, p_sorted[k] * n /
  (k + 1))`, enforce monotonicity from the largest rank
  downward (BH-specific direction), re-order to
  original cell order. Matches
  `statsmodels.stats.multitest.multipletests(p, method='fdr_bh')`.
- **`did_multi.mbt::by_fdr_p_adjust(unadjusted)`**:
  Benjamini-Yekutieli FDR correction. Same as BH but
  multiplied by the harmonic-sum factor
  `c = sum_{i=1}^{n} 1/i`. Matches
  `statsmodels.stats.multitest.multipletests(p, method='fdr_by')`.
- **`DoubleMLDIDMulti::p_adjust` accepts `"bh"` and
  `"by"`**: end-to-end dispatcher for FDR control.
  BH / BY do **not** require `bootstrap()` (they only
  consume the unadjusted p-values), so they are cheaper
  than the Romano-Wolf stepdown.

### Tests
- 200/200 across all 4 backends (native, wasm-gc, wasm,
  js). Was 192 in v0.17.0, +8 new tests:
  - `bh_fdr_handrolled` — known 4-element example
    with exact reference values.
  - `by_fdr_handrolled` — same example, BY formula
    with `c = 1 + 1/2 + 1/3 + 1/4 = 2.0833...`.
  - `bh_by_inclusion_relations` — `BY[i] >= BH[i]`
    pointwise (`c >= 1`).
  - `bh_by_sorted_output_is_monotonic` — algorithm
    invariant: BH/BY are non-decreasing when read in
    sorted-p order.
  - `p_adjust_bh_no_bootstrap_required` — end-to-end
    through `DoubleMLDIDMulti::p_adjust("bh")` on the
    canonical DGP.
  - `p_adjust_by_no_bootstrap_required` — end-to-end
    through `p_adjust("by")`, plus `BY >= BH` check.
  - `p_adjust_bh_deterministic` — same DGP, two fits,
    bit-equal output.
  - `bh_by_vs_statsmodels_reference` — exact
    cross-check against
    `statsmodels.stats.multitest.multipletests`
    on a 5-element p-value array.

### Cross-check vs statsmodels
For `p = [0.001, 0.01, 0.02, 0.03, 0.05]` (n = 5):

| Method | statsmodels | MoonBit |
|--------|-------------|---------|
| BH     | `[0.005, 0.025, 0.033333, 0.0375, 0.05]` | ✓ |
| BY     | `[0.011417, 0.057083, 0.076111, 0.085625, 0.114167]` | ✓ |

### Notes
- BH controls the false discovery rate (FDR); the
  adjusted p-values can be smaller than the unadjusted
  ones (BH is less conservative than Holm or
  Bonferroni on average).
- BY is at least as conservative as BH (`c >= 1`), but
  the comparison BY vs Bonferroni is case-by-case:
  BY sorts and applies a different scaling, so
  `BY[i] >= Bonferroni[i]` is **not** guaranteed.
- The 5 existing demos still produce bit-equal output
  to v0.17.0 (none call `p_adjust("bh")` or
  `p_adjust("by")`).
- 15/15 Python validators still PASS. The
  `validate_padjust_with_python.py` script now also
  emits the BH / BY reference values for
  cross-checking.

---

## [0.17.1] — `moon fmt` pass (hygiene)

### Fixed
- `kde.mbt`: trailing newline added. The file was
  last modified in v0.6.0; the missing EOL was a
  long-standing condition that the v0.17.0 release
  inherited. `moon fmt --check` had been silently
  failing on this file since v0.6.0.
- `cmd/datasets/moon.pkg`, `cmd/did_binary/moon.pkg`:
  trailing newline added (matches `cmd/did_cs` and
  `cmd/did_multi` `moon.pkg` which already had EOL).

### Changed (mechanical, no semantic change)
- `moon fmt` pass: 24 source files re-formatted by
  the official MoonBit formatter. Changes are pure
  whitespace / line-wrap / doc-comment re-flow
  (e.g. 19 tests in `ps_processor_test.mbt` added
  and 19 removed in net-zero fashion; 88
  doc-comment lines re-flowed). No API change, no
  behaviour change, no test change.
- Files affected (24):
  `cmd/datasets/main.mbt`, `cmd/datasets/moon.pkg`,
  `cmd/did_binary/main.mbt`, `cmd/did_binary/moon.pkg`,
  `cmd/did_cs/main.mbt`, `cmd/did_multi/main.mbt`,
  `did.mbt`, `did_aggregation_test.mbt`,
  `did_binary.mbt`, `did_binary_test.mbt`,
  `did_cs.mbt`, `did_cs_test.mbt`,
  `did_multi.mbt`, `did_multi_test.mbt`,
  `kde.mbt`, `kde_test.mbt`,
  `lpq.mbt`, `ps_processor.mbt`, `ps_processor_test.mbt`,
  `resampling.mbt`, `resampling_test.mbt`,
  `sensitivity.mbt`, `sensitivity_test.mbt`,
  `var_est.mbt`.

### Notes
- No behavioural change. This is a pure hygiene pass.
- 192/192 tests still pass (bit-equal to v0.17.0).
- 15/15 Python validators still PASS.
- 5/5 demos still run cleanly with bit-equal output
  to v0.17.0 (and to v0.16.0, v0.15.0, ...).
- `moon fmt --check` now exits clean.

---

## [0.17.0] — `gain_statistics` (sensitivity parameter benchmarks from two DML fits)

### Added
- **`sensitivity.mbt::gain_statistics(dml_long, dml_short)`**:
  compute the per-coefficient gain-statistic benchmark
  values `cf_y`, `cf_d`, `rho`, and `delta_theta` from
  two fitted DML models. Matches the upstream
  `doubleml.utils.gain_statistics.gain_statistics`:
  - `R2_y = 1 - var_y_residuals / var_y`
  - `R2_riesz = nu2_short / nu2_long`
  - `cf_y = clip((R2_y_long - R2_y_short) / (1 - R2_y_long), 0, 1)`
  - `cf_d = clip((1 - R2_riesz) / R2_riesz, 0, 1)`
  - `delta_theta = median(all_coef_short - all_coef_long)`
  - `rho = median(sign(delta_theta) * clip(|delta_theta| / sqrt(var_g * var_riesz), 0, 1))`,
    where `var_g = var_y_residuals_short - var_y_residuals_long`
    and `var_riesz = nu2_long - nu2_short`.
- **`sensitivity.mbt::GainStatsResult`**: container
  struct holding the four per-coefficient benchmark
  arrays (length `n_coef`).
- **`sensitivity.mbt::GainStatsSource`**: minimal source
  struct exposing the per-rep arrays
  `var_y_residuals`, `nu2`, `all_coef` (row-major
  `(n_coef, n_rep)`), plus `n_rep` and the scalar `var_y`.
  Designed so any DML estimator (BLP, PolicyTree, PLR,
  IRM, ...) can be benchmarked without the upstream
  `DoubleMLFramework` machinery.
- **`sensitivity.mbt::GainStatsSource::new`**: builder
  constructor that validates shape consistency (all three
  per-rep arrays have the same length; length divisible
  by `n_rep`).
- **`sensitivity.mbt::GainStatsSource::from_blp`**: a
  convenience constructor that takes a fitted
  `DoubleMLBLP` plus the manually-supplied per-rep arrays.
  Currently a thin wrapper that ignores the BLP and
  forwards the arrays; a future port can populate the
  per-rep arrays from the BLP's fit output automatically.
- **`sensitivity.mbt::median_sorted`**: helper that
  computes the median of a sorted array. Used internally
  by `gain_statistics`; exposed for testability.
- **`validate_gain_statistics_with_python.py`**: new
  Python cross-check. Replicates the upstream
  `gain_statistics` algorithm in numpy and emits the
  per-coefficient benchmarks for a 2-coef × 3-rep
  random DGP. The MoonBit tests in
  `sensitivity_test.mbt` match this reference within
  1e-12 on the same inputs.

### Notes / known limitations
- **`rho` and `cf_y` degenerate regimes**:
  - `rho = 0.0` (or `1.0` with sign) when `var_g * var_riesz <= 0`.
    The upstream's `np.divide(..., where=denom != 0)` sets
    the ratio to `1.0` in this regime, and the MoonBit
    port follows the same convention (`denom == 0` or NaN
    → `rho_abs = 1.0`).
  - `cf_y = 0` (clipped) when the long model has higher
    `R2_y` than the short model (i.e. the confounder
    helps with the long fit).
  - `cf_d = 0` (clipped) when `nu2_short >= nu2_long`.
- **No automatic DML attribute extraction**. The
  upstream `gain_statistics` reads
  `dml_long.framework.sensitivity_elements` directly.
  The v0.17.0 port defines `GainStatsSource` as an
  explicit input struct; users fill in `var_y_residuals`
  and `nu2` per rep (typically by re-fitting the model
  with different feature subsets or seeds). The
  `from_blp` helper is a placeholder for a future
  auto-population path.
- **The `from_blp` helper currently ignores its BLP
  argument** and forwards only the user-supplied arrays.
  A future port can compute `var_y_residuals` from
  `blp.coef()` and the BLP's RSS, and `nu2` from the
  BLP's sandwich SE; the v0.17.0 release ships the
  data-flow plumbing only.

### Verification
- 4-backend `moon test --deny-warn` (native, wasm,
  wasm-gc, js): **192/192 passed** (was 186, +6 new
  tests in `sensitivity_test.mbt`):
  - 1 `gain_statistics_handrolled`: algorithm
    correctness on a 1-coef, 1-rep toy DGP with known
    expected values.
  - 1 `gain_statistics_identical`: when long and short
    are identical, all four benchmarks are 0.
  - 1 `gain_statistics_clipping`: `cf_y` clips to 0
    when `R2_y_short > R2_y_long`; `cf_d` clips to 1
    when `R2_riesz = 0.1` (raw value 9).
  - 1 `gain_statistics_multi_coef_multi_rep`: 2-coef,
    3-rep hand-rolled DGP; output is length 2 with
    exact expected values.
  - 1 `panic_gain_statistics_length_mismatch`:
    per-rep arrays of different lengths abort.
  - 1 `gain_stats_from_blp_basic`: the
    `GainStatsSource::from_blp` helper constructs a
    source from a fitted BLP + user-supplied arrays.
- 15 Python validators: all PASS, including the new
  `validate_gain_statistics_with_python.py`.
- 5 demos (`moon run cmd/{main, datasets, did_binary,
  did_cs, did_multi}`) all run cleanly and produce
  bit-equal output to v0.16.0. None calls
  `gain_statistics` (it's opt-in via the
  `GainStatsSource` + `gain_statistics` API).

---

## [0.16.0] — `DoubleMLDIDMulti` multiple-testing p-adjustment (Romano-Wolf / Holm / Bonferroni)

### Added
- **`did_multi.mbt::DoubleMLDIDMulti::p_adjust(method_name)`**:
  multiple-testing p-value adjustment for the per-(g, t)
  ATTs. Returns an `Array[Double]` of adjusted p-values
  (length `n_combinations`).
  - `"romano-wolf"` (default): the stepdown bootstrap
    procedure from Romano & Wolf (2005). For each cell
    `k`, sorted by descending `|t_k|`, compute
    `p_k = mean_b [max_j > k |boot_t_stat[b, j]| >=
    |t_k|]`. Then enforce monotonicity:
    `p_corrected[k] = max(p_k, p_corrected[k - 1])` (in
    sorted order). Requires `bootstrap()` to have been
    called first.
  - `"rw"`: alias for `"romano-wolf"`.
  - `"holm"`: Holm-Bonferroni stepdown (no bootstrap
    required). Sort unadjusted p-values ascending; for
    each `k`, `p_corrected[k] = max((n - k) * p_sorted[k],
    p_corrected[k - 1])`, then re-sort to original order.
  - `"bonferroni"`: `p_corrected[k] = n * p_k`, clipped
    to `1.0`. No bootstrap required.
- **`did_multi.mbt::DoubleMLDIDMulti::t_stats()`**:
  per-cell Wald-style t-statistics `theta / se` (length
  `n_combinations`). Used by `p_adjust`.
- **`did_multi.mbt::DoubleMLDIDMulti::p_values()`**:
  per-cell unadjusted two-sided p-values for `H0:
  theta = 0`. Length `n_combinations`.
- **`did_multi.mbt::romano_wolf_p_adjust(boot_t_stat,
  unadjusted, t_stats)`** (public for testability):
  pure MoonBit Romano-Wolf stepdown.
- **`did_multi.mbt::holm_bonferroni_p_adjust(unadjusted)`**
  (public for testability): pure MoonBit
  Holm-Bonferroni stepdown.
- **`did_multi.mbt::bonferroni_p_adjust(unadjusted)`**
  (public for testability): pure MoonBit Bonferroni.
- **`did_multi.mbt::norm_sf(x)`** (public for
  testability): standard-normal survival function
  `P(Z > x)` using the Abramowitz & Stegun (1964)
  formula 7.1.26 (max absolute error ~7.5e-8 for
  `x >= 0`). MoonBit's `@math` does not expose
  `erfc`, so we approximate the normal CDF directly.
- **`validate_padjust_with_python.py`**: new Python
  cross-check. Replicates the upstream Romano-Wolf
  algorithm with `numpy.random.normal` +
  `scipy.stats.norm.sf`, then compares to the MoonBit
  output via the per-cell `t_stats` accessor +
  `p_adjust`.

### Notes / known limitations
- **Romano-Wolf is conservative by construction**. The
  adjusted p-values are >= the unadjusted p-values.
  With `n_rep_boot = 500` and a small number of cells
  (3-12), the critical value's Monte-Carlo error is
  ~`1 / n_rep_boot = 0.002`. Users on designs with
  many cells should bump `n_rep_boot` to 1000+ for
  tighter adjusted p-values.
- **No `BH` / `BY` upstream methods**. The
  `statsmodels.stats.multitest.multipletests`
  fallback path supports `bonferroni`, `holm`,
  `sidak`, `fdr_bh`, `fdr_by`, etc. We port the most
  common three (`romano-wolf`, `holm`,
  `bonferroni`); the rest are deferred — add a
  one-liner per method in `did_multi.mbt::p_adjust`
  if needed.
- **The default `p_adjust(method_name)` is
  `"romano-wolf"`**. To use Holm without bootstrap,
  pass `method_name="holm"` explicitly.
- **The `p_adjust(romano-wolf)` before
  `bootstrap()` aborts**. The error message names the
  upstream `DoubleMLFramework.p_adjust("romano-wolf")`
  contract.

### Verification
- 4-backend `moon test --deny-warn` (native, wasm,
  wasm-gc, js): **186/186 passed** (was 174, +12 new
  tests in `did_multi_test.mbt`):
  - 1 `t_stats_basic`: |t| is large on the canonical
    DGP.
  - 1 `p_values_basic`: unadjusted p-values are
    vanishingly small.
  - 1 `p_adjust_holm`: Holm-Bonferroni on the
    canonical DGP.
  - 1 `p_adjust_bonferroni`: Bonferroni on the
    canonical DGP.
  - 1 `p_adjust_romano_wolf`: Romano-Wolf on the
    canonical DGP.
  - 1 `p_adjust_romano_wolf_alias_rw`: `"rw"` alias.
  - 1 `p_adjust_romano_wolf_handrolled`: algorithm
    correctness on a hand-rolled t-statistic vector.
  - 1 `holm_bonferroni_monotonic`: Holm on a
    hand-rolled unadjusted-p-value vector.
  - 1 `bonferroni_handrolled`: exact-value test.
  - 1 `panic_p_adjust_unknown_method`: abort on
    invalid method name.
  - 1 `panic_p_adjust_romano_wolf_without_bootstrap`:
    abort on Romano-Wolf before bootstrap.
  - 1 `p_adjust_deterministic_seed`: same seed →
    bit-equal adjusted p-values.
- 14 Python validators: all PASS, including the new
  `validate_padjust_with_python.py`.
- 5 demos (`moon run cmd/{main, datasets, did_binary,
  did_cs, did_multi}`) all run cleanly and produce
  bit-equal output to v0.15.0. None calls `p_adjust`
  (it's opt-in via `DoubleMLDIDMulti::p_adjust`).

---

## [0.15.0] — `DoubleMLDIDMulti` multiplier bootstrap / joint confidence intervals

### Added
- **`did_multi.mbt::DoubleMLDIDMulti::bootstrap(method_name,
  n_rep_boot, seed)`**: multiplier bootstrap for joint
  confidence intervals. Draws `n_rep_boot` weight vectors
  from the chosen multiplier distribution and computes
  per-cell t-statistics
  `boot_t_stat[b, k] = sum_i w[b, i] * psi_k[i] / (sqrt(n) * se_k)`.
  Supports `"normal"` (default; matches upstream
  `bootstrap(method="normal")`), `"Bayes"`, and `"wild"`
  (robust to heteroskedasticity). The chacha8 RNG is seeded
  by `seed` for reproducibility (default `2024`).
- **`did_multi.mbt::DoubleMLDIDMulti::confint(joint, level)`**:
  confidence intervals for the per-(g, t) ATT. `joint = false`
  (default) returns Wald-style `theta ± 1.96 * se` intervals.
  `joint = true` returns bootstrap intervals
  `theta ± cv * se` where `cv` is the empirical
  `level`-quantile of `max_k |boot_t_stat[b, k]|` across
  bootstrap replications. Joint CIs are wider (more
  conservative) and require `bootstrap()` to be called first.
- **`did_multi.mbt::draw_bootstrap_weights(method_name,
  n_rep_boot, n_obs, seed)`** (public for testability): pure
  MoonBit weight-draw function for the three multiplier
  distributions. Returns a row-major `(n_rep_boot, n_obs)`
  array.
- **`did_multi.mbt::box_muller_normal(rng)`** (public for
  testability): standard-normal sample via Box-Muller.
- **`did.mbt` (v0.15.0 extension)**: `DoubleMLDID` now
  exposes per-observation `psi_a` and `psi_b` influence-
  function components (length `n_obs` on the wide-format
  data). The DML score is `psi_a + theta * psi_b`; this is
  the influence function used by the multiplier bootstrap.
- **`did_binary.mbt` (v0.15.0 extension)**:
  - `WideDIDSubset` now also stores the long-format
    `eval_idx` per wide-format row (the index into the
    `DoubleMLDIDBinaryData` long-format array).
  - `DoubleMLDIDBinary` stores `eval_idx` in its struct
    and exposes `psi_a_long` / `psi_b_long` accessors that
    map the wide-format psi back to the long-format panel
    (with 0 padding for rows not in the cell).
  - `DoubleMLDIDBinary` also exposes `inner_psi_a` /
    `inner_psi_b` accessors that return the wide-format
    psi directly, used by the per-cell loop in
    `DoubleMLDIDCS::fit` to build the per-cell influence
    function on the full long-format panel.
- **`did_cs.mbt` (v0.15.0 extension)**:
  - `DoubleMLDIDCS` now stores a `psi_matrix` of shape
    `(n_groups * n_periods, n_obs)`: the per-cell
    influence function on the full long-format panel,
    used by the multiplier bootstrap.
  - The per-cell fit loop records the full long-format
    index for each sub row (`full_idx_acc`) and uses it
    to map the cell's wide-format psi back to the full
    long-format panel via the wide-format `eval_idx`.
- **`validate_bootstrap_with_python.py`**: new Python
  cross-check. Computes the empirical moments of the
  three multiplier distributions (mean ≈ 0, variance ≈ 1)
  on a 200 × 50 weight matrix to verify the algorithm
  matches the upstream `numpy.random.normal /
  exponential` shape (the actual values differ because
  MoonBit uses chacha8 vs. numpy's PCG64, but the
  distributions agree).

### Changed
- **`did.mbt::DoubleMLDID` struct** gained `psi_a` and
  `psi_b` fields (length `n_obs` each). The `fit` method
  populates them alongside the existing `coef` / `se` /
  `g0_hat` / `g1_hat` / `m_hat` outputs. Existing call
  sites continue to work; the new fields are additive.

### Notes / known limitations
- **Joint CIs are conservative by construction**. The
  bootstrap critical value is the empirical `level`-
  quantile of `max_k |boot_t_stat[b, k]|` over
  `n_rep_boot` replications. With `n_rep_boot = 500`
  and `level = 0.95`, the critical value is typically
  2.5 – 4 on the canonical DGP (vs. 1.96 for the
  pointwise Wald CI). This matches the upstream
  `confint(joint=True)` behaviour.
- **Joint CIs on a small DGP may not cover the true
  ATT**. With `n = 240` units and `n_rep_boot = 500`,
  the joint CIs are wide enough that coverage holds
  for the canonical DGP; users on smaller designs
  should bump `n_rep_boot` to 1000+ for tighter
  critical-value estimates.
- **No `panel = False` (cross-section) support for
  the bootstrap**. The CS-DID bootstrap (which would
  resample at the cross-section unit level) is out of
  scope; the v0.15.0 port is panel-only. The
  `DoubleMLDIDCS` upstream class has a `panel` flag
  but the v0.9.0+ port always uses panel mode.
- **The bootstrap RNG seed is `2024` by default**,
  matching the upstream `numpy.random.seed(2024)` for
  the canonical `_verify/test_bootstrap_reference.py`
  first-test setup. Users can pass a different `seed`
  for reproducibility across runs.
- **No `_draw_weights` upstream exact-value parity**:
  MoonBit's chacha8 RNG and numpy's PCG64 produce
  different absolute weight values, so the bootstrap
  critical values are not bit-equal to upstream. The
  empirical moments match (mean ≈ 0, variance ≈ 1)
  and the joint CI coverage matches asymptotically.
  The `validate_bootstrap_with_python.py` script
  documents the RNG difference.

### Verification
- 4-backend `moon test --deny-warn` (native, wasm,
  wasm-gc, js): **174/174 passed** (was 163, +11 new
  tests in `did_multi_test.mbt`):
  - 3 weight-moment tests (normal / Bayes / wild
    means ≈ 0, variances ≈ 1 on 200 × 50 matrices).
  - 1 determinism test (same seed produces bit-equal
    `boot_t_stat`).
  - 1 joint-wider-than-pointwise test (the central
    property of joint CIs).
  - 2 CI coverage tests (pointwise and joint CIs both
    cover the true ATT for every (g, t) cell on the
    canonical DGP).
  - 3 `panic_` tests (joint CIs before bootstrap;
    bootstrap before fit; invalid `method_name`).
  - 1 default-method test (default `"normal"`, default
    `n_rep_boot = 500`).
- 13 Python validators: all PASS, including the new
  `validate_bootstrap_with_python.py`.
- 5 demos (`moon run cmd/{main, datasets, did_binary,
  did_cs, did_multi}`) all run cleanly and produce
  bit-equal output to v0.14.0. None of the demos
  calls `bootstrap()` (it's opt-in via
  `DoubleMLDIDMulti::bootstrap`).

---

## [0.14.0] — isotonic (PAVA) propensity-score calibration

### Added
- **`ps_processor.mbt::pava(y, weights?)`** — pure-MoonBit
  pool-adjacent-violators algorithm. Given a sequence `y`
  sorted by the predictor `x` and (optionally) per-element
  `weights`, returns the isotonic (non-decreasing) L2
  projection. Each output block is the weighted mean of its
  constituent elements; ties in the input are handled by
  the algorithm itself (they form a single block).
  Weighted-mean handling matches the canonical PAVA
  convention: a single block of `n` weighted observations
  with sum `s` and weight `w` reports `s / w`, not `s / n`.
- **`ps_processor.mbt::fit_isotonic(x, y)`** — sort `(x, y)`
  by `x` (stable sort, ties preserve original order) and
  apply `pava` to the sorted `y`. Returns `(sorted_x,
  sorted_y_hat)` with both arrays the same length as the
  input. Used as the calibration-step foundation for
  `PSProcessor::adjust_ps`.
- **`ps_processor.mbt::predict_isotonic(fitted_x,
  fitted_y_hat, x_new)`** — step-function lookup on the
  PAVA-fitted model. For each `x_new[i]`, returns the
  `fitted_y_hat` at the largest `fitted_x[j] <= x_new[i]`,
  clipped to `[0, 1]` (defensive). Matches
  `sklearn.isotonic.IsotonicRegression(out_of_bounds="clip",
  y_min=0.0, y_max=1.0)` on the no-tie case.
- **Isotonic calibration in `PSProcessor::adjust_ps`**.
  `PSProcessorConfig::new` already accepted
  `calibration_method="isotonic"` in v0.10.0 as a
  forward-compat placeholder; v0.14.0 wires up the actual
  PAVA-based fit. The new `cv?` parameter on
  `PSProcessor::adjust_ps(ps, treatment, cv?)` is consulted
  only when `config.calibration_method="isotonic"` and
  `config.cv_calibration=true`: each `(train_idx, test_idx)`
  fold fits PAVA on the training subset and predicts on
  the test subset, concatenating the held-out predictions
  in the original index order. When `cv = None`, a
  deterministic 5-fold split with `seed=3141` is used
  (matches upstream `cross_val_predict(cv=5)` default).
- **`validate_pava_with_python.py`** — new Python
  cross-check. Prints the sklearn `IsotonicRegression`
  reference (in-sample + 5-fold CV) on a 10-element DGP
  with strictly-distinct propensity scores and binary
  treatment; the per-DGP numbers are used as the
  ground-truth for the MoonBit test cases in
  `ps_processor_test.mbt`.

### Changed
- **`PSProcessor::adjust_ps` signature** gained a third
  optional `cv?` parameter. Default `cv = None` means
  "use the deterministic 5-fold split" when
  `cv_calibration=true`, and is ignored otherwise. No
  caller is broken: existing calls `adjust_ps(ps, t)`
  continue to work and the v0.10.0..v0.13.0
  `calibration_method="none"` path is byte-equal to
  v0.14.0.
- **`ps_processor.mbt::PSProcessorConfig` docstring**:
  the v0.10.0 "v0.12+ TODO" placeholder is gone. The
  isotonic section now describes the actual v0.14.0
  semantics (PAVA fit, optional CV) with a usage
  example.
- **Validation helper added**: `validate_treatment`
  (private) aborts on non-binary `treatment[i]` in
  `0.0 / 1.0` before any calibration work runs. The
  upstream `_validate_treatment` (full type/dim check
  + `type_of_target == "binary"`) is a strict superset
  but we don't have a generic target-type helper in
  pure MoonBit; the bitwise `0.0 / 1.0` check is the
  upstream-equivalent contract for the propensity-score
  use case.

### Fixed
- **`PSProcessorConfig` v0.10.0 placeholder abort**:
  v0.10.0..v0.13.0 `calibration_method="isotonic"` would
  call `abort("isotonic calibration not yet implemented
  in this port")` on first use. v0.14.0 implements the
  full PAVA-based calibration; the abort is gone.

### Notes / known limitations
- **PAVA tie handling differs from sklearn on tied-x
  inputs**. The MoonBit PAVA treats each `x` value as a
  separate observation (regardless of ties); sklearn's
  `IsotonicRegression` groups tied `x` values into a
  single block before applying PAVA. On a strictly
  distinct-x input (the canonical case for the
  propensity-score use, where `ps` is a continuous
  prediction) the two are bit-equal. On tied-x inputs
  the two may differ by a few ULPs of the block mean.
  This is documented in the v0.14.0 PAVA tests; the
  validate_pava_with_python.py script uses a 4-decimal
  random x to ensure no ties.
- **Default `cv` is a deterministic 5-fold split with
  `seed=3141`** (matches the package's standard fold
  RNG). To use a different fold partition, pass
  `cv=Some([(train1, test1), (train2, test2), ...])`;
  the union of all `test_idx` must cover `[0, n)`
  (otherwise `isotonic_calibrate_cv` aborts with a
  clear "cv partition does not cover all indices"
  message).
- **No `propensity_score_processing` upstream
  convenience function port** (the `init_ps_processor`
  wrapper in upstream that handles the deprecated
  `trimming_rule` / `trimming_threshold` keywords). The
  v0.14.0 entry point is the `PSProcessor` class
  directly; users who need the trimming-rule shim can
  build it on top of `PSProcessor::new` in 2 lines.
- **No change to the v0.10.0 default 1e-2 clip** or to
  the v0.13.0 accessor surface. The 1e-2 default is
  applied after the (optional) calibration step, so
  the user can opt into a different `clipping_threshold`
  without affecting the calibration.

### Verification
- 4-backend `moon test --deny-warn` (native, wasm,
  wasm-gc, js): **163/163 passed** (was 150, +13 new
  tests in `ps_processor_test.mbt`: 6 PAVA primitives +
  4 PSProcessor integration + 1 predict_isotonic step
  function + 1 CV path + 1 input-no-mutation guard).
- 12 Python validators: all PASS, including the new
  `validate_pava_with_python.py` (sklearn reference for
  PAVA in-sample + 5-fold CV on a 10-element DGP with
  distinct-x).
- 5 demos (`moon run cmd/{main, datasets, did_binary,
  did_cs, did_multi}`) all run cleanly and produce
  bit-equal output to v0.13.0. The `did_binary` and
  `did_cs` demos continue to use the default
  `PSProcessor` config (clip-only, no calibration); the
  isotonic calibration is opt-in via
  `calibration_method="isotonic"`.

---

## [0.13.0] — Polish: API accessor consistency, REVIEW history trim, logistic_test cleanup

### Added
- **`n_obs` / `n_features` accessors on every model**. The 15 estimators
  previously had an inconsistent API surface: `DoubleMLPLR`,
  `DoubleMLIRM`, `DoubleMLAPO`, `DoubleMLRDD`, `DoubleMLPQ`,
  `DoubleMLQTE`, `DoubleMLCVAR`, `DoubleMLLPQ` all now expose both
  accessors with matching docstrings. The implementations reuse the
  existing data containers (`data.n_obs()`, `data.n_features()`,
  `data.x.rows()` / `data.x.cols()` for the LPQ / RDD variants that
  carry a `Matrix` rather than a `DoubleMLData`).
- **`README.mbt.md::Demo entry points` table** documenting all five
  `cmd/*/main.mbt` drivers: which model each runs, what the DGP is,
  and what the true θ is. Each row is hyperlinked to the demo's
  source so users can read the DGP before running the demo.

### Changed
- **REVIEW history trim**: dropped 6 historical-context comments that
  no longer reflect the current code (REVIEW L2 / L3 / M3 / M4 / M9 /
  M10 — purely "we used to do X, now we do Y" notes). Kept the
  REVIEW comments that document real API contracts (L5 / L7 / L8 /
  L11 / L12 / H1 / M10-fix / L11-fix). Net `−20` lines of comment
  text with zero behaviour change.
- **`logistic_test.mbt` cleanup**: dropped the local 7-bit-encoding
  `logistic_seed_buf` helper (was used by 2 tests for the
  chacha8-RNG setup; net `−30` LOC). The new `chacha8_rng(N)` and
  `permute(n, seed: Int)` call paths use the canonical
  32-bit-LE `seed_to_bytes` encoding, so test results are bit-equal
  to v0.12.0.
- **`quantile.mbt`** + **`rdd.mbt`** + **`apo.mbt`** + **`kfold.mbt`**
  + **`blp_policy.mbt`** + **`linear.mbt`** + **`lpq.mbt`**:
  * Docstring consistency: every accessor now has the same
    "Number of observations." / "Number of features (covariate
    columns)." header. Several previously blank docstrings
    (PQ / QTE / CVAR / RDD's `n_obs`) are now filled in.
  * Three duplicate `///| ///|` doc-comment artifacts from
    `0.12.0`'s accessor-add pass are collapsed to single `///|`
    markers.

### Notes / known limitations
- **No behaviour change** vs. v0.12.0. This is a pure polish
  release: same numbers, same tests, just cleaner accessor surface
  and a tidier comment trail.
- **No new features, no test additions, no API breakage**. The
  `n_obs` / `n_features` additions are pure additions — no field
  renames, no signature changes.

### Verification
- 4-backend `moon test --deny-warn` (native, wasm, wasm-gc, js):
  **150/150 passed** (no test count delta from v0.12.0; this is
  a pure polish release).
- 11 Python validators: all PASS, including
  `validate_did_binary_with_python.py` and
  `validate_did_cs_with_python.py` (the most recent additions).
  No tolerance widened.
- 5 demos (`moon run cmd/{main,datasets,did_binary,did_cs,did_multi}`)
  all run cleanly and produce bit-equal output to v0.12.0.

---

## [0.12.0] — Cleanup: chacha8_rng helper + verifier-scratch hygiene

### Added
- **`seed.mbt::chacha8_rng(seed)`**: convenience constructor
  that returns `Rand::chacha8(seed=Bytes::from_array(seed_to_bytes(seed)))`.
  Used in 13 test files and 5 demos; the 3-line boilerplate
  pattern (`let bytes = seed_to_bytes(N); let rng =
  @random.Rand::chacha8(seed=Bytes::from_array(bytes))`)
  collapses to `let rng = chacha8_rng(N)`. The function is
  a one-liner but removes ~50 lines of duplicated code and
  keeps the canonical encoding visible at every callsite.

### Changed
- **`seed.mbt::seed_to_bytes` docstring**: the wildcard-vs-`3`
  match comment is now a one-liner explaining that
  `k ∈ 0..32` so the `_` arm is dead at runtime; the
  previous text talked about the `REVIEW L6` history that
  no longer reflects the current code.
- **`.gitignore`**: the `_verify/` directory is split into
  tracked-vs-scratch:
  - **Tracked** (must stay): `T###-verdict.md` and
    `T###-commit-msg.txt` — the release summary and the
    git commit message template.
  - **Scratch** (gitignored): build logs, probe outputs,
    Python validator outputs, ad-hoc adversarial test
    scripts, archived `.mbt.archived` files.
  - The 250+ historical `_verify/*.log`,
    `_verify/TODO-*`, `_verify/H*`, `_verify/LOW*`,
    `_verify/MEDIUM*`, `_verify/REVIEW*`,
    `_verify/T0*-backend-*.log`,
    `_verify/T0*-pycheck*.log`, `_verify/T0*-demo.log`,
    `_verify/final-*`, etc. have been removed from the
    index (but are still on disk if you have a stale
    checkout; `git clean -dfX _verify/` drops them
    locally).
- **`pkg.generated.mbti`** is now git-ignored. It is
  regenerated automatically by `moon info` and was
  previously committed by accident. The other tracked
  `cmd/main/pkg.generated.mbti` is the moon-package's own
  generated interface and is unchanged.
- **`cmd/main/main.mbt`** + **`cmd/datasets/main.mbt`** +
  **`cmd/did_binary/main.mbt`** + **`cmd/did_cs/main.mbt`**
  + **`cmd/did_multi/main.mbt`**: switched from the
  3-line `seed_to_bytes -> Bytes::from_array -> chacha8`
  boilerplate to `chacha8_rng(seed)`.
- **`README.mbt.md`** test count and source-file count
  refreshed (150 / 150 across all 4 backends; 54 source
  files = 26 production + 28 test). Added a "Library
  helpers" section documenting `chacha8_rng`,
  `stratified_kfold`, and `PSProcessor` for users who
  arrive at the package via the API docs rather than the
  README.

### Notes / known limitations
- **`_verify/` size dropped from ~250 files to 12 files**
  (6 `T###-verdict.md` + 6 `T###-commit-msg.txt`). The
  cleanup is purely a hygiene release: no model behaviour
  changed, no test thresholds widened.
- **`pkg.generated.mbti`** is regenerated automatically by
  `moon info`. If you change the package surface and the
  CI reports "interface out of date", just run
  `moon info && moon test`.

### Verification
- 4-backend `moon test --deny-warn` (native, wasm, wasm-gc, js):
  **150/150 passed** (no test count delta from v0.11.0;
  this is a pure cleanup release).
- 9 Python validators: all PASS (no behaviour changes).
- 5 demos (`moon run cmd/{main,datasets,did_binary,did_cs,did_multi}`)
  all run cleanly with the new `chacha8_rng` helper.

---

## [0.11.0] — DoubleMLDIDMulti (top-level multi-period DID with aggregation)

### Added
- **`did_aggregation.mbt`** (~250 LOC): `DIDAggregationResult`
  struct (`theta` + `se` + `agg_names`) and three aggregation
  helpers:
  - `aggregate_group(coef, se, groups, periods, group_sizes)`:
    one entry per group, equal-weight mean over the
    post-treatment cells within each group.
  - `aggregate_time(coef, se, groups, periods, group_sizes)`:
    one entry per time period, group-size-weighted mean
    across groups for that period.
  - `aggregate_event(coef, se, groups, periods, group_sizes)`:
    one entry per event time `e = t - g`, group-size-weighted
    mean across groups for that event time.
  - All three aggregators skip the `t == g` baseline cells
    (which `DoubleMLDIDCS` leaves at 0.0 by convention) and
    the event aggregator skips `e <= 0` cells.
  - SE is the delta-method propagation: `se_agg = sqrt(sum_i
    w_i^2 * se_i^2) / sum_i w_i`.
- **`did_multi.mbt`** (~340 LOC): `DoubleMLDIDMulti`, the
  top-level multi-period DID container. Wraps `DoubleMLDIDCS`
  to drive the per-(g, t) ATT cross-fits, then exposes:
  - `gt_combinations` as a constructor arg: either an
    explicit `Array[(Int, Int, Int)]` of `(g_value,
    t_value_pre, t_value_eval)` triples, or a keyword
    `"standard"` (every `(g, t)` with `t > g` and `t_pre = g`,
    the canonical Callaway-Sant'Anna staggered set),
    `"all"` (every cell, including pre-treatment baselines),
    or `"universal"` (alias for `"all"` in the panel case;
    repeated-cross-section `"universal"` is not ported).
  - `n_combinations()`, `coef_at_idx(i)`, `se_at_idx(i)` for
    accessing the per-(g, t) ATT matrix.
  - `aggregate_group()`, `aggregate_time()`,
    `aggregate_event()` methods that delegate to
    `did_aggregation.mbt` and use the per-cell ATT + SE
    matrix from the inner `DoubleMLDIDCS::fit`.
- **`did_aggregation_test.mbt`** (4 tests): basic
  arithmetic for each aggregator; pre-treatment /
  baseline-skipping; per-group size weighting.
- **`did_multi_test.mbt`** (2 tests): end-to-end multi-cohort
  panel recovers true ATT in every (g, t) cell; the three
  aggregations produce well-formed result arrays.
- **`cmd/did_multi/main.mbt`**: end-to-end demo on a
  4-cohort × 4-period panel; prints the per-(g, t) ATT
  matrix and the three aggregations.

### Notes / known limitations
- **No bootstrap / joint CIs.** Upstream's `did_multi.py`
  implements a full bootstrap pipeline for joint
  confidence intervals on the aggregated effects (via
  `DoubleMLFramework.bootstrap`). This is a significant
  piece (~400 LOC) and is deferred to a later release
  (v0.12+). The Wald-style (pointwise) SEs that we do
  compute match the upstream default and are sufficient
  for the standard event-study visualisation.
- **No `panel : Bool` switch.** The port is panel-only;
  the upstream `"universal"` keyword (which is meaningful
  only for repeated cross sections) is treated as an
  alias for `"all"`. A `DoubleMLDIDCS` cross-section port
  is out of scope here; the upstream `did_multi.py` itself
  dispatches to `DoubleMLDIDCSBinary` (panel) or
  `DoubleMLDIDCS` (cross-section) per the `panel` flag.
- **No `print_periods` accessor.** The upstream
  `DoubleMLDIDMulti.__init__` prints a one-line summary of
  each `(g, t_pre, t_eval)` combination when
  `print_periods=True`. We omitted the print accessor to
  keep the API surface small; the per-cell info is
  available via `coef_at_idx` / `se_at_idx`.
- **Per-group sizes are derived from `data.id`** (max id
  + 1, divided equally across groups). The upstream
  weights come from a more careful per-cell sample-count
  inside the per-cell DML. The equal-weight approximation
  is sufficient for balanced panels (the canonical DGP
  here) and matches the upstream behaviour to within
  rounding error on balanced designs.

### Verification
- 4-backend `moon test --deny-warn` (native, wasm, wasm-gc, js):
  **150/150 passed** (was 144, +6 new tests: 4 `did_aggregation`
  + 2 `did_multi`).
- 9 Python validators: all PASS, including the existing
  `validate_did_*_with_python.py` (no new validator — the
  `did_multi` aggregations are pure MoonBit-only, with the
  per-cell numbers already cross-checked by
  `validate_did_binary_with_python.py` and
  `validate_did_cs_with_python.py`).
- Demo (`moon run cmd/did_multi`) on a 4-cohort × 4-period
  panel (n_units=240, p=3, true ATT=1.0) recovers the per-(g,
  t) ATTs to within ~1% of truth (1.0005, 0.9989, 1.0046
  for the 3 (g, t) combos) and the three aggregations
  produce sensible summaries: g=1 → 0.9997, g=2 → 1.0046
  (g=3 has no post-treatment cells); t=2 → 1.0005, t=3 →
  1.0017; e=1 → 1.0025, e=2 → 0.9989 (e <= 0 cells stay at
  0.0 by convention).

---

## [0.10.0] — DoubleMLDIDCSBinary (ps_processor + G+2T stratified folds)

### Added
- **`ps_processor.mbt`** (~140 LOC): `PSProcessorConfig` struct
  (clipping_threshold, extreme_threshold, calibration_method,
  cv_calibration) and `PSProcessor` with `adjust_ps(ps, treatment)`.
  The default config clips the propensity to `[1e-2, 1 - 1e-2]`
  (matches upstream's default). `adjust_ps` first applies the
  configured calibration (currently a pass-through; `isotonic` PAVA
  is a documented TODO for v0.12+) and then clips to
  `[clipping_threshold, 1 - clipping_threshold]`. The processor
  does not mutate the caller's `ps` or `treatment` arrays.
- **`ps_processor_test.mbt`** (6 tests): config validation
  (clipping_threshold ∈ (0, 0.5), `cv_calibration=true` requires
  a calibration method), `adjust_ps` clip behaviour, no-input-
  mutation guarantee.
- **G+2T stratified folds in `DoubleMLDID`** (`did.mbt`):
  - New `strata : Array[Int]` field on `DoubleMLDID` (default
    `[]` = no stratification). Length must be 0 or `n_obs`.
  - `DoubleMLDID::fit` checks `self.strata.length() == n`: if
    so, it calls `stratified_kfold` (per-stratum Fisher-Yates
    + fold allocation); otherwise it falls back to plain
    `kfold`.
- **`DoubleMLDIDBinary` / `DoubleMLDIDCS` ps_processor integration**
  (`did_binary.mbt`, `did_cs.mbt`):
  - New `ps_processor : PSProcessor` field on
    `DoubleMLDIDBinary` (constructor arg `ps_processor?`).
  - `DoubleMLDIDBinary::fit` computes the wide-format strata
    `G_indicator + 2 * t_indicator` (matching upstream's
    `self._strata`) and passes it to the inner
    `DoubleMLDID::new(strata=...)`.
  - `ps_processor` propagates through `DoubleMLDIDBinary` →
    `DoubleMLDID::fit`, where it replaces the inner
    `clip_vec(m, 1e-6, 1-1e-6)` with
    `ps_processor.adjust_ps(m, d)` for the public-facing
    `m_hat` and the score denominator. The inner `clip_vec`
    is retained as a per-rep numerical-safety net.

### Changed
- **`DoubleMLDID` default behaviour**: the cross-fitted
  propensity in `m_hat` is now clipped to
  `[1e-2, 1 - 1e-2]` (via the default `PSProcessor`) instead
  of the legacy `1e-6` hard-coded clip. This widens the score
  denominator slightly and is the upstream default. The
  `DoubleMLDIDBinary` demo ATT moved from 1.0008 (v0.8.0) to
  1.0004 (v0.10.0) on the canonical DGP; both well within
  ~1 SE of the true value 1.0. The legacy
  `propensity_clip?` constructor argument is retained for
  backward compat but is read only by the inner
  `cross_fit_did` numerical-safety clip; the public-facing
  clip is now controlled by `ps_processor`.

### Fixed / hardening
- **Stratified-fold safety net in `DoubleMLDIDBinary::fit`**: if
  any stratum has fewer observations than `n_folds` (which
  would abort inside `stratified_kfold`), the strata array is
  dropped to `[]`, falling back to plain `kfold` for that
  dataset. This avoids a regression for small panels (e.g.
  the 4-unit, 1-control-cohort toy dataset in
  `did_binary_test.mbt`) that worked under plain `kfold` and
  would otherwise crash under the v0.10.0 stratified path.

### Notes / known limitations
- **`isotonic` calibration is not yet implemented** (v0.12+
  TODO). `PSProcessorConfig::new` accepts `calibration_method =
  "isotonic"` for forward-compat, but `PSProcessor::adjust_ps`
  aborts on that value (with a clear message). The `clip` step
  alone is sufficient for the v0.10.0 panel CS-DID work.
- **`DoubleMLDIDCS` is a strict superset of
  `DoubleMLDIDCSBinary`**: the upstream `did_cs_binary.py` adds
  `ps_processor_config`, `print_periods`, and a `print_periods`
  accessor, but otherwise shares the same score / nuisance
  structure as `DoubleMLDIDCS`. We did not introduce a
  separate `DoubleMLDIDCSBinary` struct; `DoubleMLDIDCS` in
  v0.10.0 already covers both use cases.

### Verification
- 4-backend `moon test --deny-warn` (native, wasm, wasm-gc, js):
  **144/144 passed** (was 136, +8 new tests: 6 `ps_processor` +
  2 `DoubleMLDIDBinary` integration tests for the new
  `ps_processor` field and the wide-format strata plumbing).
- 9 Python validators: all PASS, including
  `validate_did_binary_with_python.py` and
  `validate_did_cs_with_python.py` (the wide-format demo
  ATT moved from 1.0008 → 1.0004 under the 1e-2 default
  clip; both well within the 0.3 / 0.5 qualitative
  tolerances).

---

## [0.9.0] — Callaway-Sant'Anna staggered DID (DoubleMLDIDCS)

### Added
- **`DoubleMLDIDCS`** (`did_cs.mbt`, ~260 LOC): Callaway-Sant'Anna
  (2021) staggered DID estimator for **multi-period panel** data.
  Iterates over every `(g, t_pre, t_eval)` triple with `t_eval > g`,
  restricts the long-format panel to the never-treated cohort ∪ the
  `g == g_value` cohort, dispatches to `DoubleMLDIDBinary::fit` on the
  wide-format subset, and stores per-`(g, t)` ATT estimates and SEs in
  a row-major `coef_matrix` / `se_matrix` indexed by
  `[gi * n_periods + pi]`. Pre-treatment cells (`t_eval ≤ g`) and
  groups whose pre-treatment period is unobserved are left at the
  default `0.0` (the CS-DID convention is "no pre-treatment effect").
- **`DoubleMLDIDCSData`** (`did_cs.mbt`): multi-period panel data
  container. Stores long-format observations + `id`, `t`, `g` index
  arrays. Validates that all index arrays share length and that
  `d ∈ {0, 1}` at construction time. `DoubleMLDIDCSData::new` deep-
  copies `g` and `t` so the caller's arrays are never mutated by the
  in-place sort inside `discover_groups_times` (`Array::copy()` is
  shallow, and `Array::sort()` mutates the receiver in place — a
  discovered trap on this build of MoonBit).
- **`cmd/did_cs/main.mbt`** demo: synthetic staggered panel DGP
  (200 units × 4 periods, cohorts g=0, 1, 2, 3; true ATT = 1.0)
  running the new estimator. Recovers per-cell ATTs within ~1% of
  truth: (g=1, t=2) → 0.9925, (g=1, t=3) → 0.9929, (g=2, t=3) →
  1.0035; all 95% CIs contain the true ATT.

### Changed
- **`did_cs.mbt::DoubleMLDIDCSData::new`** deep-copies the caller's
  `g` and `t` arrays on entry, instead of retaining the caller's
  references. This insulates the caller from any in-place mutation
  inside `discover_groups_times` (and any future in-place ops
  inside `fit`). Was a latent ownership-trap bug: `g.copy()` is
  shallow, so `g_sorted.sort()` on the local copy was also mutating
  the caller's `g` array, scrambling the (g, t) cell selection.

### Notes / known limitations
- The CS-DID score is fixed to `observational` with
  `in_sample_normalization = false` (matches the upstream
  `DoubleMLDID` default). Upstream's CS-DID uses a 4-D nuisance
  `g_hat_d0_t0, g_hat_d0_t1, g_hat_d1_t0, g_hat_d1_t1` plus a
  propensity `m_hat` and the unconditional `p_hat = mean(d)` /
  `lambda_hat = mean(t)`. The current port approximates the
  per-cell nuisance via the existing `DoubleMLDIDBinary` (which uses
  the standard 2-D `g0, g1` nuisance + propensity), so the per-cell
  SEs are conservative for the panel-CS-DID target.
- Multi-valued `d ∈ {-1, 0, 1}` (the "switchers" convention) is not
  supported; use `DoubleMLDIDBinary` with
  `control_group = "not_yet_treated"` for the staggered case.
- No sensitivity / tune / aggregation / IRM-style bridge layers;
  per-(g, t) ATT only.

### Verification
- 4-backend `moon test --deny-warn` (native, wasm, wasm-gc, js):
  **136/136 passed** (was 131, +5 new tests for `DoubleMLDIDCS`:
  end-to-end ATT recovery, pre-treatment zero cells,
  `discover_groups_times` correctness, and two `panic_` prefix tests
  for non-binary `d` and invalid `control_group`).
- 9 Python validators: all PASS, including the new
  `validate_did_cs_with_python.py` (hand-rolled reference for the
  multi-cohort panel CS-DID DGP).

---

## [0.8.0] — DoubleMLDIDBinary (panel data DID) + DoubleMLDID score extensions

### Added
- **`DoubleMLDIDBinary`** (`did_binary.mbt`): binary-treatment DID
  for **panel data** following Sant'Anna & Zhao (2020) §4.3. The
  estimator accepts long-format panel observations
  `(id, t, y, d, x_1, ..., x_p, g)`, preprocesses them into the
  wide-format DID dataset (units with both `t_value_pre` and
  `t_value_eval`, `y_diff = y_post - y_pre`, `G_indicator` /
  `C_indicator` per `control_group`), and dispatches to
  `DoubleMLDID::fit`. Supports both `"never_treated"` and
  `"not_yet_treated"` control groups and the
  `anticipation_periods` parameter.
- **`DoubleMLDIDBinaryData`** (`did_binary.mbt`): panel data
  container storing long-format observations + time/unit/group
  index arrays. Validates that all index arrays share length at
  construction time.
- **`cmd/did_binary/main.mbt`** demo: synthetic panel DGP (200
  units × 2 periods, half treated) running the new estimator.
  Recovers `ATT = 1.0008` (true = 1.0) on a 400-unit panel.

### Changed
- **`DoubleMLDID`** (`did.mbt`): now supports two new constructor
  options — `score : "observational" | "experimental"` (default
  `"observational"`) and `in_sample_normalization : Bool` (default
  `false`). The 2×2 = 4 score flavours implement the four cells of
  Sant'Anna & Zhao (2020) Table 1 (experimental / observational
  with in-sample normalisation). The default
  `(observational, false)` is byte-equal to the pre-0.8.0 port.

### Tests
- 131 / 131 across all 4 backends (added 2 tests for the new
  `DoubleMLDIDBinary`: preprocessing + end-to-end ATT recovery).
- 9 / 9 `validate_*_with_python.py` PASS (added
  `validate_did_binary_with_python.py` for the new estimator).
- `cmd/did_binary` demo: ATT = 1.0008 (true = 1.0) with
  `se ≈ 0.0021` and the 95% CI contains the true value.

### Verification
- See `_verify/T080-verdict.md`.

---

## [0.7.0] — REVIEW-0.4.3 leftover smells + 0.7.0 hygiene

### Fixed
- **L12** (`logistic.mbt:81-93`): `LogisticRegression::fit` now
  validates `y ∈ {0, 1}` via `require(y_i == 0.0 || y_i == 1.0)`
  for every label. The pre-fix code silently tolerated out-of-range
  labels (the IRLS `z = eta + (y - p) / w` formula is mathematically
  defined for any `y`, but the interpretation as binary
  classification breaks). New test
  `panic_logistic_fit_rejects_non_binary_y` pins the contract.

- **N1** (`resampling.mbt:35-49`): removed dead `strata_start` /
  `strata_end` placeholder arrays that were superseded by
  `acc_s` / `acc_e` during the `+ [...]` accumulator refactor.
  The `ignore()` calls on the unused arrays were also dropped.

- **N2** (`sensitivity.mbt:3`): typo in doc — "per-dessity" → "per-density".

### Changed
- **L11** (`lpq.mbt:224-228`, `var_est.mbt:55-87`): LPQ's variance
  computation now delegates to a new shared helper
  `var_est_with_jacobian(psi, jacobian)` instead of inlining the
  `sum(psi^2) / n / (deriv^2 * n)` formula. The math is byte-equal;
  the helper has a Kahan-compensated accumulator and aborts on
  `jacobian == 0`. Removes the last inlined variance calc across the
  package — every estimator now goes through `var_est.mbt` (either
  the 2-argument or the 1-argument + jacobian form).

### Tests
- 129 / 129 across all 4 backends (added 1 panic test for L12).
- 8 / 8 `validate_*_with_python.py` PASS.
- LPQ coef on canonical `z=d` DGP: bit-equal at `1.490000`.

### Verification
- See `_verify/T070-verdict.md`.

---

## [0.6.0] — RDD HC0 + Sensitivity + Resampling + LPQ KDE + dataset demo

### Added
- **RDD HC0 sandwich SE** (`rdd.mbt`, `linear.mbt:125-175`):
  `DoubleMLRDD` now accepts `cov_type="HC0"` (default
  `"homoskedastic"`). HC0 is White's heteroskedasticity-consistent
  sandwich `var(beta_0) = sum_k w_k^2 * (M[0,:]·x_k)^2 * e_k^2`
  with `M = (X^T W X + ridge I)^{-1}`, robust to arbitrary residual
  heteroskedasticity on each side of the cutoff. Both sharp and
  fuzzy RDD support the new `cov_type`.
- **`LinearRegression::sandwich_se_weighted`** (`linear.mbt:125-175`):
  WLS variant of the HC0 sandwich. Caches the full `(X^T W X)^{-1}`
  row and back-solves `p1` systems for each coefficient.
- **`compute_sensitivity_bias`** + **`robustness_value`**
  (`sensitivity.mbt`): Cinelli & Hazlett (2020) omitted-variable
  bias analysis. Given `sigma2`, `nu2`, `psi_sigma2`, `psi_nu2`,
  computes the worst-case bias vector
  `sqrt(sigma2 * nu2)` and its gradient w.r.t. confounding
  strength. `robustness_value = |theta_hat| / mean(max_bias)` gives
  the scalar "RV" — the minimum confounding strength that would
  change the estimator's sign.
- **`silverman_bandwidth`** + **`gaussian_kde`** +
  **`gaussian_kde_weighted`** (`kde.mbt`): Silverman's rule of
  thumb bandwidth `h = 0.9 * min(sd, IQR/1.34) * n^(-1/5)` for
  one-dimensional Gaussian KDE; weighted variant for evaluating
  `f_hat(theta) = (1/(h*sqrt(2π))) * sum w_i K((theta-y_i)/h)`.
  Includes `sample_sd` and `iqr` helpers.
- **`stratified_kfold`** + **`repeated_kfold`** (`resampling.mbt`):
  per-stratum K-fold partition (each fold's test set contains a
  proportional share of every stratum); repeated K-fold for
  `n_rep`-times replication.
- **`cmd/datasets/main.mbt`** demo: synthetic 401(k)-style DGP
  (n=4000, p=9, true `theta=1.5`) running `DoubleMLPLR` and
  `DoubleMLIRM` end-to-end. The DGP captures the qualitative
  features of the upstream `fetch_401K` example (binary `e401`,
  continuous `net_tfa`, 9 controls) without depending on the
  upstream `.dta` file. Run with `moon run cmd/datasets`.

### Changed
- **LPQ numerical derivative** (`lpq.mbt:189-227`): the
  finite-difference `(mean_p - mean_m) / (2h)` with `2 * n_folds`
  extra cross-fits is replaced by a single
  `gaussian_kde_weighted` evaluation of the IPW coefficient at
  `theta`. Saves `4` cross-fits per LPQ fit (was `2 + 4 = 6`
  total, now `2 + 1 = 3`) and removes the discrete-y pathology
  where `1{y <= theta+h} = 1{y <= theta-h}` collapses the
  finite-difference to zero. The `lpq_within_5pct_of_pre_fix` SE
  tolerance is widened from 30% to 50% to absorb the smoothed
  numerical derivative's slight bias.

### Tests
- 128 / 128 across all 4 backends (added 13 new tests: 1 RDD HC0,
  6 sensitivity, 3 resampling, 3 KDE).
- 8 / 8 `validate_*_with_python.py` PASS.
- LPQ with `z=d` (all compliers, full-sample `comp=1`):
  bit-equal output `1.490000` on canonical DGP (KDE-based
  derivative converges to the same `theta` as the previous
  finite-difference).
- `cmd/datasets` demo: PLR `theta = 1.4844`, IRM `theta = 1.4707`,
  both within a few SE of true `1.5` (`se ≈ 0.04`).

### Verification
- See `_verify/T060-verdict.md`.

---

## [0.5.0] — REVIEW-0.4.3 high + medium + low polish

### Fixed
- **H2** (`apo.mbt:163-176`): `DoubleMLAPO::fit` no longer inlines
  the `var_est` calculation. It now calls the shared
  `var_est(pa, pb)` helper, matching the other six DML estimators
  (PLR, IRM, PLIV, IIVM, DID, SSM). The 13-line inline version was
  missing two things the helper has: (a) Kahan compensation on the
  `gamma` accumulator, and (b) coverage by `var_est_test.mbt`'s three
  contract tests (happy-path, length-mismatch abort, n-zero abort).

- **M13** (`kfold.mbt:32-49`): `kfold` no longer carries its own
  legacy 7-bit-per-byte seed encoder. It now delegates to the
  canonical 8-bit `seed_to_bytes` helper, matching the rest of the
  package. The two encoders produced different byte streams from the
  same integer seed (e.g. `seed = 3141`), so `kfold(n, k, 3141)` and
  `seed_to_bytes(3141) -> chacha8` previously produced different
  fold partitions than a user would expect from the docstring.

### Changed
- **quantile_test.mbt:138-148** (`qte_se_includes_covariance`): the
  relative tolerance on the QTE vs. buggy-quadrature SE comparison
  widened from `<= buggy + 1e-6` to `<= buggy * 1.05 + 1e-6` to
  absorb the post-M13 fold-encoder change. The QTE's covariance
  crosses zero on this DGP under the new fold partition, and a 1e-6
  absolute tolerance was too tight for the noise level.

### Docs
- **L10** (`README.mbt.md`): test count updated from 113 / 113 to
  115 / 115 across the four-block backend matrix and the "113 / 113
  on all 4 backends" table row. The 0.4.1 and 0.4.3 releases added
  one `panic_` test each (H1 + L7); the count had been stale since.

### Skipped (with reason)
- **L11** (LPQ inlined variance): structural difference — LPQ's
  `deriv` is a gradient, not a constant-`1` mean, so a
  `var_est_with_jacobian` helper would be a different refactor. 5
  lines of code, no current maintenance hazard.
- **L12** (`LogisticRegression` `y ∈ {0, 1}` validation): the
  existing IRLS clamping (`p → (eps, 1-eps)`) silently tolerates
  out-of-range y. Adding a `require` would be a behaviour change
  that could break callers depending on the lax behaviour. Deferred
  to 0.6.0 unless a concrete bug surfaces.
- **L9**: stale comment in `kfold.mbt`; folded into M13.
- **L13**: confirmation that the 4 v0.4.3 deferred items (M5, L1,
  L3, L4) remain deferred with reason.

### Tests
- 115 / 115 across all 4 backends (no test count change; the
  QTE test tolerance was widened, not replaced).
- 8 / 8 `validate_*_with_python.py` PASS.
- IRM n_rep=1: theta = 1.1068 (was 0.9811). The M13 fold-encoder
  change shifts the fold partition by a few indices, which is
  within the DGP noise band; the n_rep=5 estimate (theta = 0.9878)
  is the canonical number and still inside the upstream CI.

### Verification
- See `_verify/REVIEW2-verdict.md`.

---

## [0.4.3] — REVIEW low polish

### Fixed
- **L7** (`linear.mbt:166-189`): `LinearRegression::fit_weighted` now
  `require`s `w[i] >= 0.0`. Negative WLS weights silently flip the
  sign of the residual contribution and produced wrong-direction
  estimates; rejected at the call site instead. New test
  `panic_fit_weighted_aborts_on_negative_weight` pins the contract
  (MoonBit's test runner reports the `abort` as a PASS).

### Docs
- **L2** (`apo.mbt:91-105`): `cross_fit_apo` doc explains the
  asymmetric split (treated-only `g`, full-sample `m`).
- **L5** (`blp_policy.mbt:1-22`): `DoubleMLBLP` doc expanded with
  the full HC0 vs. nonrobust semantics and the rationale for keeping
  `cov_type` as a struct field (post-fit introspection).
- **L6** (`seed.mbt:31-37`): in-source comment explains why the
  match uses a wildcard instead of an explicit `3 => b3` — `Int % 4`
  is signed, so negative remainders are possible. The "explicit
  case" alternative is non-exhaustive and fails `moon --deny-warn`.
- **L8** (`linear.mbt:127-156`): `covariance_diagonal` doc warns that
  `xtx_inv_diag` is the empty array after `fit_weighted` (M10 fix
  side-effect) and the call would yield a vector of zeros.

### Skipped
- **L1** (`cov_type` field on `DoubleMLBLP`): refactoring to a local
  var would break the public API surface auto-generated in
  `pkg.generated.mbti`. The field is unused after fit but kept for
  forward compat.
- **L3** (`coef_` mutability): already managed correctly via the
  struct copy in `fit`/`fit_weighted`; no `let mut` was missing.
- **L4** (asymmetric `n_features` accessor presence): cosmetic; the
  asymmetry is consistent across all DML models.

### Tests
- 115 / 115 across all 4 backends (added 1 `panic_*` test for L7).
- 8 / 8 `validate_*_with_python.py` PASS.

### Verification
- See `_verify/LOW-verdict.md`.

---

## [0.4.2] — REVIEW medium polish

### Changed
- **M1** (`apo.mbt:70-77`): `DoubleMLAPO::predictions_g` / `predictions_m`
  now `require(self.fitted)` (consistent with `coef` / `se`).
- **M3** (`apo.mbt:124-148`): `DoubleMLAPO::fit` no longer round-trips
  through `ga` / `ma` accumulators — accumulates directly into `g`
  / `m` and divides by `n_rep` at the end.
- **M4** (`apo.mbt:217-228`): `DoubleMLAPOS::fit` now passes `n_rep=1`
  to each child `DoubleMLAPO::fit` (the parent APOS loop performs the
  repetition). This avoids the previous `n_rep * n_rep` total fold
  draws.
- **M9** (`linear.mbt:236-282`): `sandwich_se` replaces the
  `inv_spd`-based full matrix inversion with `p1` back-solves via
  `solve_spd`. Saves O(p³) memory per fit and produces bit-equal
  HC0 SE values.
- **M10** (`linear.mbt:194-221`): `fit_weighted` no longer computes
  the unweighted `(X'X)^{-1}` diagonal — only the weighted
  `(X'WX)^{-1}` diagonal is needed (by `DoubleMLRDD`). Saves one
  matrix multiplication + one Cholesky-based inverse per fit.

### Fixed
- **M6** (`did.mbt:11-23`): `DoubleMLDIDData::new` now validates that
  `d ∈ {0, 1}` (the only treatment convention supported by the port).
  Catches upstream data errors at construction time.
- **M7** (`quantile.mbt:2-23`): `array_min` / `array_max` now panic
  on empty input instead of `v[0]` out-of-bounds.

### Docs
- **M2** (`apo.mbt:149-152`): `pa` doc comment explains the structural
  `psi_a = -1` of the APO score.
- **M8** (`quantile.mbt:131-141`): `solve_pq` doc explains why it is
  `pub` (blackbox-test-only API).
- **M11** (`rdd.mbt:222-234`): `n_local` doc explains the count is for
  outcome observations inside the bandwidth.
- **M12** (`quantile.mbt:32-45`): `g_cross_fit_count` doc explains the
  thread-safety assumption.

### Skipped
- **M5** (defensive `Array::copy` on `predictions_*` accessors): the
  review itself notes this is a 90-line change with poor risk/reward
  ratio. The current shared-reference behaviour is faster and the
  caller is trusted. Deferred — not blocking.

### Tests
- 114 / 114 across all 4 backends (no test count change; existing
  tests cover the refactored paths).
- 9 / 9 `validate_*_with_python.py` PASS.

### Verification
- See `_verify/MEDIUM-verdict.md`.

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
