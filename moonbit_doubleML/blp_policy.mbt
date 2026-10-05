///|
/// Best linear predictor of an orthogonal signal on a supplied basis.
///
/// `cov_type` selects the standard-error convention. Valid values:
///   - `"HC0"` (default): White's heteroskedasticity-consistent
///     sandwich SE — robust to arbitrary residual heteroskedasticity.
///     Matches the upstream `doubleml.utils.blp` call to
///     `statsmodels.OLS(cov_type='HC0')`.
///   - `"nonrobust"`: classic homoskedastic OLS SE
///     (`sigma^2 * (X^T X)^{-1}` with `sigma^2 = RSS / (n - p)`),
///     which is only valid under the homogeneous-error assumption.
///
/// REVIEW L5: the field is currently stored on the struct for forward
/// compatibility (post-fit introspection), but is not used outside
/// `fit`. Construct via `DoubleMLBLP::new` to validate the value.
///
/// v0.63.0+: `ml_g?` field accepts a `LearnerDispatch`. The
/// `coef` / `(X^T X)^{-1}` machinery is always the closed-form OLS
/// path (BLP is by definition the OLS projection); the dispatch
/// learner only affects the residual / RSS computation. Defaults
/// to `LearnerDispatch::linear_regression()` which preserves the
/// v0.62.2 byte-equality behaviour for the standard fit.
pub struct DoubleMLBLP {
  basis : Matrix
  orth_signal : Array[Double]
  cov_type : String
  ml_g : LearnerDispatch
  coef : Array[Double]
  se : Array[Double]
  fitted : Bool
  // v0.19.0+: post-fit summary statistics used by
  // `GainStatsSource::from_blp` to auto-populate the
  // sensitivity parameter benchmarks. Initialised to
  // zero in `new`; filled in by `fit`.
  n_obs : Int
  rss : Double
  var_y : Double
  // v0.64.0+: per-observation residual vector at the fitted
  // OLS projection. Length `n_obs`. Persisted for the
  // multiplier bootstrap.
  residuals : Array[Double]
  // v0.64.0+: multiplier bootstrap state. `boot_t_stat` is
  // a flat `[n_rep_boot * (p + 1)]` array of t-statistics
  // (row-major by rep, then by coef — same layout as the
  // rest of the package). Populated by `bootstrap(...)`;
  // empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
  // v0.83.0+: memoization state. `memoize_enabled` is the
  // user-facing switch (false by default to preserve v0.82.0
  // behavior bit-for-bit). When true, `fit()` caches the
  // single-pass `(coef, se, n_obs, rss, var_y, residuals)`
  // plus a placeholder fold_ids vector in `fit_cache` and
  // reuses them on the next call when the basis, orthogonal
  // signal, learner fingerprint, and covariance type are
  // unchanged. Mirrors the IRM / PLR / CVAR / SSM plumbing.
  memoize_enabled : Bool
  fit_cache : FitCache
} derive(Debug)

///|
pub extend DoubleMLBLP with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLBLP::new(
  basis : Matrix,
  orth_signal : Array[Double],
  cov_type? : String = "HC0",
  ml_g? : LearnerDispatch = LearnerDispatch::linear_regression(),
) -> DoubleMLBLP {
  try {
    require(basis.rows() == orth_signal.length())
    require(cov_type == "HC0" || cov_type == "nonrobust")
    {
      basis,
      orth_signal,
      cov_type,
      ml_g,
      coef: [],
      se: [],
      fitted: false,
      n_obs: 0,
      rss: 0.0,
      var_y: 0.0,
      residuals: Array::make(basis.rows(), 0.0),
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      // v0.83.0+: default memoize off so v0.82.0 callers see
      // byte-identical fit() output. Enable explicitly via
      // `.enable_memoize()` for caching.
      memoize_enabled: false,
      fit_cache: FitCache::empty(),
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLBLP::fit(
  self : DoubleMLBLP,
  ml_g? : LearnerDispatch = self.ml_g,
) -> DoubleMLBLP {
  // v0.83.0+: memoize check. BLP is a single-pass OLS
  // projection (no `n_folds` / `n_rep`), so the cache stores
  // the post-fit `(coef, se, residuals, n_obs, rss, var_y)`
  // plus a length-`n_obs` placeholder `fold_ids` (BLP does
  // not partition rows into folds; the cache layout still
  // expects a `Array[Int]` of length `n_obs` so the
  // `FitCache::is_valid` check has a consistent shape).
  let n_obs = self.orth_signal.length()
  let memoize = self.memoize_enabled
  let data_hash : UInt64 = if memoize {
    // BLP has no `d` / `z` / `cluster_vars`; pass empty
    // arrays so the hash reflects only the basis +
    // orth_signal content.
    hash_data(self.basis, self.orth_signal, [])
  } else {
    0UL
  }
  let hparams_hash : UInt64 = if memoize {
    // BLP's only nuisance learner is `ml_g`. We pass `ml_g`
    // twice (once for the `ml_g` slot, once as a placeholder
    // for the `ml_m` slot BLP doesn't carry) and use a
    // `propensity_clip` proxy derived from `cov_type` --
    // 0.0 for "HC0", 1.0 for "nonrobust" -- so the
    // hyperparams hash also invalidates on a covariance-type
    // switch.
    let cov_clip = if self.cov_type == "HC0" { 0.0 } else { 1.0 }
    hash_hyperparams("blp", ml_g, ml_g, cov_clip)
  } else {
    0UL
  }
  let cluster_hash : UInt64 = if memoize {
    // BLP data has no `cluster_vars`; pass an empty vector
    // so the hash stays 0 across calls (matches the IID
    // sentinel).
    hash_cluster_ids([])
  } else {
    0UL
  }
  let cache_hit = memoize &&
    self.fit_cache.is_valid(
      self.cov_type.length(),
      // BLP has no `seed` / `n_folds`; use `cov_type.length()`
      // (3 for "HC0", 9 for "nonrobust") as a fingerprint so a
      // covariance-type change invalidates the cache. The
      // `n_folds` slot is fed the basis row count as a
      // placeholder so the cache key is still dimensional.
      self.basis.rows(),
      1,
      n_obs,
      data_hash,
      hparams_hash,
      cluster_hash,
      "blp",
    )
  if cache_hit {
    // Reuse the cached OLS projection. The returned struct
    // mirrors the constructor's "fitted" state but with
    // `fitted = true` and the cached arrays.
    let preds = self.fit_cache.predictions
    let c : Array[Double] = preds[0]
    let s_arr : Array[Double] = preds[1]
    let cached_rss : Double = preds[2][0]
    let cached_var_y : Double = preds[3][0]
    let cached_residuals : Array[Double] = preds[4]
    return {
      basis: self.basis,
      orth_signal: self.orth_signal,
      cov_type: self.cov_type,
      ml_g,
      coef: c,
      se: s_arr,
      fitted: true,
      n_obs,
      rss: cached_rss,
      var_y: cached_var_y,
      residuals: cached_residuals,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      memoize_enabled: self.memoize_enabled,
      fit_cache: self.fit_cache,
    }
  }
  // v0.63.0+: route through `LearnerDispatch` so the per-fit
  // `ml_g` override reaches the BLP fit. Defaults preserve
  // v0.62.2 byte-equality (default `LearnerDispatch::linear_regression()`
  // matches the hardcoded `LinearRegression::new()` path).
  // The closed-form `(X^T X)^{-1}` machinery stays on the
  // OLS path (BLP is by construction the OLS projection);
  // the dispatch learner only affects the residual / RSS
  // computation.
  let ols_model = LinearRegression::new().fit(self.basis, self.orth_signal)
  let c = ols_model.coefficients()
  let p = c.length()
  let s = Array::make(p, 0.0)
  // Per-coefficient SE. Two flavours:
  //   - HC0 (sandwich, default): `cov_jj = sum_i ((M[j,:] x_i)^2 * e_i^2)`
  //     matches upstream `statsmodels.OLS(cov_type='HC0')`. Robust
  //     to arbitrary heteroskedasticity.
  //   - nonrobust: `cov_jj = sigma^2 * (X^T X)^{-1}_{jj}` with
  //     `sigma^2 = RSS / (n - p)` (homogeneous-error assumption).
  // Per-coefficient SE (Bug #5 fix); HC0 default matches
  // upstream `statsmodels.OLS(cov_type='HC0')`.
  // v0.63.0+: route through `fit_predict_one_dispatch` so the
  // per-fit `ml_g` override drives the residual computation.
  // For the default `LearnerDispatch::linear_regression()` this
  // matches the v0.62.2 `model.predict(self.basis)` path
  // byte-for-byte (the dispatch wrapper calls `lr.fit(basis,
  // orth_signal).predict(basis)` internally).
  let pred = fit_predict_one_dispatch(
    ml_g,
    self.basis,
    self.orth_signal,
    self.basis,
  )
  // v0.83.0+: vectorise the residual / RSS computation. Use
  // `vector_subtract` for the per-observation residual and
  // `vector_multiply` for the squared-residual, then
  // `mean * n` for the sum (no public `sum` helper; this
  // matches the upstream convention of a two-pass mean).
  let residuals : Array[Double] = vector_subtract(self.orth_signal, pred)
  let sq_resid : Array[Double] = vector_multiply(residuals, residuals)
  let rss = mean(sq_resid) * n_obs.to_double()
  // `var_y` = variance of the orthogonal signal (the BLP's
  // "outcome" variable). Computed as a one-pass Welford
  // would be slightly more accurate, but a two-pass mean
  // is fine for our purposes.
  let mut mean_y = 0.0
  for i = 0; i < n_obs; i = i + 1 {
    mean_y = mean_y + self.orth_signal[i]
  }
  mean_y = mean_y / n_obs.to_double()
  let mut ss_y = 0.0
  for i = 0; i < n_obs; i = i + 1 {
    let d = self.orth_signal[i] - mean_y
    ss_y = ss_y + d * d
  }
  let var_y = ss_y / n_obs.to_double()
  let cov_diag = if self.cov_type == "HC0" {
    ols_model.sandwich_se(self.basis, self.orth_signal)
  } else {
    let sigma2 = rss / (n_obs.to_double() - p.to_double())
    ols_model.covariance_diagonal(sigma2)
  }
  for j = 0; j < p; j = j + 1 {
    s[j] = cov_diag[j].sqrt()
  }
  // v0.83.0+: when memoize is on and the cache missed, write
  // the freshly-computed OLS projection to the cache. The
  // cache layout stores `coef` and `se` as length-`p`
  // arrays, `rss` and `var_y` as length-1 arrays (so they
  // fit the `Array[Array[Double]]` shape of `FitCache`),
  // `residuals` as a length-`n_obs` array, and a length-
  // `n_obs` placeholder `fold_ids` (BLP does not partition
  // rows into folds).
  let next_cache = if memoize {
    FitCache::from_fit(
      Array::make(n_obs, 0),
      [c, s, Array::make(1, rss), Array::make(1, var_y), residuals],
      self.cov_type.length(),
      self.basis.rows(),
      1,
      n_obs,
      data_hash,
      hparams_hash,
      cluster_hash,
      "blp",
    )
  } else {
    FitCache::empty()
  }
  {
    basis: self.basis,
    orth_signal: self.orth_signal,
    cov_type: self.cov_type,
    ml_g,
    coef: c,
    se: s,
    fitted: true,
    n_obs,
    rss,
    var_y,
    residuals,
    boot_t_stat: [],
    boot_method: "",
    n_rep_boot: 0,
    boot_seed: 0,
    memoize_enabled: self.memoize_enabled,
    fit_cache: next_cache,
  }
}

///|
/// v0.83.0+: turn on memoization for subsequent `fit()` calls.
/// When enabled, `fit()` will cache the OLS projection
/// `(coef, se, residuals, n_obs, rss, var_y)` and skip the
/// `LinearRegression::fit` + `sandwich_se` path on a repeat
/// call whose basis + orthogonal signal + learner + covariance
/// type are all unchanged. Mirrors the IRM / PLR / CVAR / SSM
/// plumbing.
///
/// Default is OFF. When OFF, every `fit()` call runs the full
/// OLS projection and the cache is neither read nor written,
/// so v0.82.0 callers see byte-identical output.
pub fn DoubleMLBLP::enable_memoize(self : DoubleMLBLP) -> DoubleMLBLP {
  { ..self, memoize_enabled: true, }
}

///|
/// v0.83.0+: turn off memoization. Same immutability contract
/// as `enable_memoize()`. After this, `fit()` will not read or
/// write the cache; the existing `fit_cache` is preserved on
/// the returned struct (call `clear_cache()` to drop it).
pub fn DoubleMLBLP::disable_memoize(self : DoubleMLBLP) -> DoubleMLBLP {
  { ..self, memoize_enabled: false, }
}

///|
/// v0.83.0+: drop any cached OLS projection. Forces the next
/// `fit()` to recompute from scratch.
pub fn DoubleMLBLP::clear_cache(self : DoubleMLBLP) -> DoubleMLBLP {
  { ..self, fit_cache: FitCache::empty(), }
}

///|
/// v0.83.0+: `true` iff `fit_cache` holds at least one cached
/// observation (i.e. at least one prior `fit()` call with
/// `memoize_enabled = true` has populated the cache). Note
/// that the cache may still be stale relative to the current
/// basis / learner configuration -- check `memoize_enabled`
/// before assuming a cache hit.
pub fn DoubleMLBLP::has_cache(self : DoubleMLBLP) -> Bool {
  !self.fit_cache.is_empty()
}

///|
pub fn DoubleMLBLP::coef(self : DoubleMLBLP) -> Array[Double] {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLBLP::se(self : DoubleMLBLP) -> Array[Double] {
  try {
    require(self.fitted)
    self.se
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.19.0+: sample size used by the BLP fit.
pub fn DoubleMLBLP::n_obs(self : DoubleMLBLP) -> Int {
  try {
    require(self.fitted)
    self.n_obs
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.64.0+: multiplier bootstrap for `DoubleMLBLP`. BLP is
/// the OLS projection of `orth_signal` onto the augmented
/// design `[1, basis]`; per-observation IF is
/// `psi[i, j] = M[j, :] @ xa_i * e_i` where
/// `M = (Xa^T Xa + ridge I)^{-1}` and `xa_i = [1, basis[i, :]]`.
/// `se_flat` is the per-coefficient SE (HC0 sandwich diagonal
/// under `cov_type = "HC0"`, `sqrt(sigma^2 * (X^T X)^{-1}_{jj})`
/// under `cov_type = "nonrobust"`); the helper skips a
/// coefficient when `se[j] = 0`. Routes through the shared
/// `generic_bootstrap_ols_per_coef` helper (see
/// `bootstrap_helper.mbt`).
///
/// `method_name` selects the multiplier distribution:
/// `"normal"` (default), `"Bayes"`, `"wild"`. `seed` defaults
/// to `2024`; `n_rep_boot` defaults to `500`.
///
/// `boot_t_stat` is a flat `[n_rep_boot * (p + 1)]` array of
/// t-statistics (row-major by rep, then by coef). Calling on
/// an un-fit model aborts via `PreconditionError`.
pub fn DoubleMLBLP::bootstrap(
  self : DoubleMLBLP,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLBLP {
  try {
    require(self.fitted)
    require(
      method_name == "normal" || method_name == "Bayes" || method_name == "wild",
    )
    require(n_rep_boot >= 2)
    // Recompute (Xa^T Xa + ridge I)^{-1} from the augmented
    // design so the IF rows `psi[i, j] = M[j, :] @ xa_i * e_i`
    // are consistent with `LinearRegression::fit` (which
    // augments with an intercept internally and applies the
    // same ridge regularisation to the normal equations).
    let xa = augment_with_intercept(self.basis)
    let xa_t = xa.transpose()
    let xtx = matmul(xa_t, xa)
    let xtx_aug = add_ridge(xtx, 1.0e-10)
    let xtx_inv = inv_spd(xtx_aug)
    let boot_t_stat = generic_bootstrap_ols_per_coef(
      xa,
      self.residuals,
      xtx_inv,
      self.se,
      method_name,
      n_rep_boot,
      seed,
    ) catch {
      BootstrapMethodError::UnknownMethod(m) =>
        abort(
          "draw_bootstrap_weights: unknown method (set in DoubleMLBLP::bootstrap): " +
          m,
        )
    }
    {
      ..self,
      boot_t_stat,
      boot_method: method_name,
      n_rep_boot,
      boot_seed: seed,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.19.0+: residual sum of squares from the BLP fit.
/// Equals `sum_i (orth_signal[i] - basis[i] @ coef)^2`.
pub fn DoubleMLBLP::rss(self : DoubleMLBLP) -> Double {
  try {
    require(self.fitted)
    self.rss
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.69.0+: per-coefficient sensitivity analysis for `DoubleMLBLP`.
///
/// BLP is the closed-form OLS projection of `orth_signal` onto the
/// augmented design `Xa = [1, basis]` (intercept + basis columns).
/// Per-observation influence-function rows for coefficient `j` are
///
///   psi_a[j][i] = M[j, :] @ xa_i
///
/// where `M = (Xa^T Xa + ridge I)^{-1}` is the OLS precision matrix
/// and `xa_i` is the augmented row `i`. The full IF for coef `j`
/// decomposes as `psi[i, j] = psi_a[j][i] * residuals[i]` (matches
/// the v0.64.0 `bootstrap` IF rows used by
/// `generic_bootstrap_ols_per_coef`).
///
/// Sensitivity for each coef follows the shared
/// `irm_style_sensitivity` decomposition with:
///   - `theta = coef[j]`
///   - `residuals = self.residuals` (the OLS residuals from `fit`)
///   - `psi_a = psi_a[j]`
///   - `cf_y / cf_d` default to `0.05` (matching the rest of the
///     v0.66.0-onward sensitivity family).
///
/// Returns an `Array[SensitivityResult]` of length `coef.length()`
/// (= `n_features + 1`, including the intercept at index 0).
/// Calling on an un-fit model aborts via `PreconditionError`.
pub fn DoubleMLBLP::sensitivity_analysis(
  self : DoubleMLBLP,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> Array[SensitivityResult] raise {
  require(self.fitted)
  let n_obs = self.orth_signal.length()
  let n_coef = self.coef.length()
  // Reconstruct the augmented design + precision matrix (matches
  // the v0.64.0 `bootstrap` IF-row computation so the IRM-style
  // decomposition here stays consistent with the bootstrap path).
  let xa = augment_with_intercept(self.basis)
  let p_aug = xa.ncols
  let xa_t = xa.transpose()
  let xtx = matmul(xa_t, xa)
  let xtx_aug = add_ridge(xtx, 1.0e-10)
  let xtx_inv = inv_spd(xtx_aug)
  let results : Array[SensitivityResult] = Array::make(n_coef, {
    rv: 0.0,
    sigma2: 0.0,
    nu2: 0.0,
    cf_y: 0.0,
    cf_d: 0.0,
    max_bias: 0.0,
  })
  for j = 0; j < n_coef; j = j + 1 {
    let psi_a_j : Array[Double] = Array::make(n_obs, 0.0)
    for i = 0; i < n_obs; i = i + 1 {
      // psi_a[j][i] = M[j, :] @ xa_i = sum_k xtx_inv[j, k] * xa[i, k]
      let mut dot = 0.0
      for k = 0; k < p_aug; k = k + 1 {
        dot = dot + xtx_inv.data[j * p_aug + k] * xa.data[i * p_aug + k]
      }
      psi_a_j[i] = dot
    }
    results[j] = irm_style_sensitivity(
      self.coef[j],
      self.residuals,
      psi_a_j,
      cf_y,
      cf_d,
    )
  }
  results
}

///|
/// v0.74.0+: cluster-robust analogue of
/// `DoubleMLBLP::sensitivity_analysis`. Same residual
/// (`self.residuals`) and same per-coef `psi_a_j` (the
/// `M[j, :] @ xa_i` Riesz-representer rows from the OLS
/// precision matrix) as the IID path; only the variance /
/// bias computation is cluster-aware. The augmented
/// design `xa` and the precision `xtx_inv` are recomputed
/// identically so the per-coef `psi_a_j` rows match the
/// bootstrap IF rows exactly.
///
/// `DoubleMLBLP` has no `data` field (just `basis` +
/// `orth_signal`); the user must pass `cluster_ids`
/// explicitly. `cluster_ids.length()` must equal
/// `self.basis.rows()` (= `self.orth_signal.length()`).
///
/// Returns an `Array[SensitivityResult]` of length
/// `self.coef.length()` (= `n_features + 1`, including the
/// intercept at index 0). Calling on an un-fit model aborts
/// via `PreconditionError`.
pub fn DoubleMLBLP::sensitivity_analysis_cluster(
  self : DoubleMLBLP,
  cluster_ids : Array[Int],
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> Array[SensitivityResult] raise {
  require(self.fitted)
  let n_obs = self.orth_signal.length()
  let n_coef = self.coef.length()
  require(cluster_ids.length() == n_obs)
  // Reconstruct the augmented design + precision matrix
  // (matches the v0.64.0 `bootstrap` IF-row computation so
  // the IRM-style decomposition here stays consistent with
  // the bootstrap path).
  let xa = augment_with_intercept(self.basis)
  let p_aug = xa.ncols
  let xa_t = xa.transpose()
  let xtx = matmul(xa_t, xa)
  let xtx_aug = add_ridge(xtx, 1.0e-10)
  let xtx_inv = inv_spd(xtx_aug)
  // Build per-coef `psi_a` rows once, then loop the cluster
  // helper per coef.
  let psi_a_all : Array[Array[Double]] = Array::make(n_coef, [])
  for j = 0; j < n_coef; j = j + 1 {
    let psi_a_j : Array[Double] = Array::make(n_obs, 0.0)
    for i = 0; i < n_obs; i = i + 1 {
      // psi_a[j][i] = M[j, :] @ xa_i = sum_k xtx_inv[j, k] * xa[i, k]
      let mut dot = 0.0
      for k = 0; k < p_aug; k = k + 1 {
        dot = dot + xtx_inv.data[j * p_aug + k] * xa.data[i * p_aug + k]
      }
      psi_a_j[i] = dot
    }
    psi_a_all[j] = psi_a_j
  }
  // For BLP the residuals are shared across coefs (they are
  // the OLS projection residuals of `orth_signal` on
  // `xa`). Replicate into n_coef rows for the multi helper.
  let residuals_arr : Array[Array[Double]] = Array::make(n_coef, [])
  for j = 0; j < n_coef; j = j + 1 {
    residuals_arr[j] = self.residuals.copy()
  }
  irm_style_sensitivity_cluster_multi(
    self.coef,
    residuals_arr,
    psi_a_all,
    cluster_ids,
    cf_y,
    cf_d,
  )
}

///|
/// v0.19.0+: variance of the orthogonal signal (the BLP's
/// "outcome" variable). Computed as a population variance
/// (divisor `n`, not `n - 1`).
pub fn DoubleMLBLP::var_y(self : DoubleMLBLP) -> Double {
  try {
    require(self.fitted)
    self.var_y
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.22.0+: the orthogonal signal array (the BLP's
/// "outcome" variable). Length `n_obs`. Used by
/// `GainStatsSource::from_blp_cv` to compute the
/// cross-fit residual variance.
pub fn DoubleMLBLP::orth_signal(self : DoubleMLBLP) -> Array[Double] {
  try {
    require(self.fitted)
    self.orth_signal
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.22.0+: the basis matrix (the BLP's "design
/// matrix"). Shape `n_obs x p_features`. Used by
/// `GainStatsSource::from_blp_cv` to refit the
/// BLP on each fold's training subset.
pub fn DoubleMLBLP::basis(self : DoubleMLBLP) -> Matrix {
  try {
    require(self.fitted)
    self.basis
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Fitted values `basis_aug @ coef` for each observation, length
/// `n_obs`. Matches the upstream `DoubleMLBLP.predictions` /
/// `predict` semantic — the orthogonal-signal prediction under
/// the BLP coefficient vector.
///
/// Note: `coef` has length `p_basis + 1` because
/// `LinearRegression::fit` adds an intercept column to `basis`.
/// We reconstruct that column (all-1.0) on the fly to keep the
/// stored `self.basis` unchanged.
pub fn DoubleMLBLP::predictions(self : DoubleMLBLP) -> Array[Double] {
  try {
    require(self.fitted)
    let n = self.orth_signal.length()
    let p = self.basis.cols()
    let pred : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      // Intercept term.
      let mut s = self.coef[0]
      for j = 0; j < p; j = j + 1 {
        s = s + self.basis.get(i, j) * self.coef[j + 1]
      }
      pred[i] = s
    }
    pred
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Joint confidence interval for the linear contrast
/// `contrast @ coef` (length `n_contrast`), via chi-squared
/// critical value on the Mahalanobis distance.
///
///   `(contrast @ (coef - theta))^T @ inv(Omega_contrast) @ (contrast @ (coef - theta)) ~ chi2(n_contrast)`
///
/// where `Omega_contrast = contrast @ Omega @ contrast^T` is the
/// induced covariance. Equivalent to a Bonferroni-style worst-case
/// bound but tighter for low correlation.
///
/// Parameters:
/// - `contrast`: row-major matrix `(n_contrast, p + 1)` whose rows
///   define the linear functions of `coef` to interval-estimate.
/// - `level`: confidence level in (0, 1). Default 0.95.
///
/// Returns: array of `(low, high)` tuples (each row a symmetric
/// interval around `contrast @ coef`). For a single contrast
/// row, returns a 1-element array. v0.53.0-dev Task 3 / v0.11.4
/// upstream parity.
///
/// Notes: the upstream joint-CI uses bootstrap to draw the
/// critical value from `np.quantile(np.max(np.abs(bootstrap)))`,
/// which requires the full `omega` matrix. In our port we
/// approximate the critical value with the chi-squared quantile
/// (1 df per row), and use the diagonal sandwich form of
/// `Omega_contrast` (`contrast[r]^2 @ diag(se^2)`) for the
/// variance. This is the standard closed-form chi-squared joint
/// CI when the joint-CI variance is dominated by the diagonal
/// (a conservative approximation for the upstream bootstrap).
pub fn DoubleMLBLP::confint_joint(
  self : DoubleMLBLP,
  contrast : Matrix,
  level? : Double = 0.95,
) -> Array[(Double, Double)] {
  try {
    require(self.fitted)
    require(level > 0.0 && level < 1.0)
    let n_contrast = contrast.rows()
    let p = self.coef.length()
    require(contrast.cols() == p)
    let mut out : Array[(Double, Double)] = []
    for r = 0; r < n_contrast; r = r + 1 {
      let mut theta = 0.0
      let mut variance = 0.0
      for j = 0; j < p; j = j + 1 {
        theta = theta + contrast.get(r, j) * self.coef[j]
        let cv = contrast.get(r, j)
        let sv = self.se[j]
        variance = variance + cv * cv * sv * sv
      }
      let se = variance.sqrt()
      // chi2(1, level) = (z_{1 - level/2})^2 ; for level=0.95 this
      // is z^2 = 1.959963984540054^2 ≈ 3.841458820694125
      // (the same value as `statsmodels.OLS.conf_int(joint=True)`
      // critical-value adjustment before v0.11.4).
      let z = 1.959963984540054
      let half = se * z
      out = out + [(theta - half, theta + half)]
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

// ---------------------------------------------------------------------------
// v0.97.0: `hac_se` / `cluster_hac_se` -- the projection HAC sandwich
// ---------------------------------------------------------------------------
//
// WHY BLP DOES NOT REUSE `sandwich_se` / `sandwich_variance`
// ==========================================================
//
// Same reason RDD does not, and the same trap wearing the same
// "Huber-White" name. `sandwich_variance_hc0` (the shared DML helper
// in `sandwich.mbt`) and BLP's own HC0 branch (`fit`, `cov_type ==
// "HC0"`, which delegates to `LinearRegression::sandwich_se`) are not
// the same algebra, and routing BLP through the shared helper
// produces a number that is plausible, finite, and NOT BLP's HC0.
//
// The two meats, side by side. BLP's (`linear.mbt`,
// `LinearRegression::sandwich_se`, sqrt'd at `fit`):
//
//     var_j = sum_i ( (M[j, :] . xa_i)^2 * e_i^2 ),
//     M = (X'X + ridge I)^-1,  X = [1, basis],  e = y - X . beta
//
// -- a full `p1 x p1` inverse, a ROW of it per coefficient, and NO
// `1 / n^2`. The shared helper (`sandwich_variance_hc0`, since
// v0.91.0):
//
//     M_inv[0,0]^2 * sum_i psi[i]^2 / n / n
//
// Three independent mismatches, any one of which is fatal:
//
//   1. THE SCALAR JACOBIAN. `sandwich_variance_hc0` takes a 1x1
//      `M_inv` and squares it (`M_inv[0,0]^2`). BLP has no DML
//      moment, so it has no scalar Jacobian: it estimates `p1`
//      coefficients off the whole `(X'X)^-1`, and coefficient `j`
//      picks out its `[j, :]` ROW. Forcing a 1x1 in means either
//      passing `[[1.0]]` (dropping the entire `(X'X)^-1`
//      conditioning, so every coefficient would get the same
//      variance) or inventing a `1 / mean(...)` that is not a
//      derivative of anything. BLP's answer is a VECTOR, so even a
//      correct shared helper would need a different signature.
//
//   2. THE PER-ROW TERM. The DML influence function is a SUM of two
//      score terms, `psi[i] = psi_a[i] * theta + psi_b[i]`, and the
//      meat squares the WHOLE thing. BLP has no `psi_a` and no
//      `psi_b`: its per-row sandwich term is a PRODUCT
//      `m_j(xa_i) * e_i` of a projection (the `j`-th row of the
//      normal inverse dotted with the augmented row) and a residual.
//      Squaring the product is a second power of each factor;
//      routing the DML form in instead replaces the data-dependent
//      `m_j(xa_i)^2` with a factor the DML package has no way to
//      produce.
//
//   3. THE `1 / n^2`. The shared helper is a MEAN moment, so it
//      divides the meat by `n` twice. BLP's variance is a sum of
//      squared row scores over `n_obs` rows -- the same kind of
//      quantity as `LinearRegression::sandwich_se`, whose per-
//      coefficient output `fit` sqrt's. Dividing by `n_obs^2 =
//      400^2` would shrink every SE by 400x and the HC0 anchor
//      `hac_se(HC0) == se` would fail by exactly that factor --
//      loudly, which is the only reason to prefer the mistake that
//      is quiet.
//
// The HC2 / HC3 leverage splits the same way. The shared helper
// uses the CONSTANT mean-regression leverage `h_ii = 1 / n_obs`,
// which is what makes `sandwich_variance_hc2 ==
// sandwich_variance_hc1` hold in the DML family (see the
// `SandwichKind` doc). BLP's is a genuine OLS hat diagonal
// `h_i = xa_i' (X'X + ridge I)^-1 xa_i` that VARIES per row, so
// BLP's HC2 / HC3 are NOT HC1 and that identity does not carry
// over.
//
// CONSEQUENCE: `DoubleMLBLP` exposes `hac_se`, NOT `sandwich_se`.
// BLP is a projection estimator, not a DML-score estimator -- it
// has no `psi_a`, no `psi_b`, no `E[theta psi_a + psi_b]` moment, no
// scalar `M_inv` -- so a method literally named `sandwich_se` would
// promise a DML sandwich contract it cannot honour, and would have
// the wrong SIGNATURE (scalar `M_inv` vs a `p1`-vector result). The
// name says what the number is: the HAC sandwich of an OLS
// projection of an orthogonal signal onto a basis.
//
// SCOPE OF THE ANCHOR
// -------------------
// `hac_se(HC0) == se` BIT-IDENTICALLY, ELEMENTWISE, holds exactly
// when the fit took the HC0 branch, i.e. `cov_type = "HC0"`:
//
//   - `cov_type = "nonrobust"` fit: `se` is
//     `sqrt(sigma^2 * (X'X)^-1_jj)` with `sigma^2 = RSS / (n - p)`,
//     a homoskedastic variance, so `hac_se(HC0) != se` there.
//     Pinned by `blp_hac_se_hc0_differs_from_se_on_nonrobust_path`.
//   - not fitted: ABORTS via `PreconditionError`.
//
// Unlike RDD, there is no learner refusal. BLP's HC0 branch calls
// `LinearRegression::sandwich_se(basis, orth_signal)` on a FRESH
// `LinearRegression::new()`, independent of the `ml_g` dispatch, so
// `hac_se` is a function of `(basis, orth_signal)` alone for every
// learner and the anchor holds whatever `ml_g` is. (`ml_g` moves
// `residuals` / `rss`, which the HC0 meat does not read -- it reads
// `e = y - X . beta` from the OLS model.)
//
// The four HC variants, with `n = n_obs` and `p1 = n_params()`:
//
//     HC0:  sum_i ( (M[j,:] . xa_i)^2 * e_i^2 )
//     HC1:  the same, with the sum scaled by n / (n - p1)
//     HC2:  each term divided by (1 - h_i)
//     HC3:  each term divided by (1 - h_i)^2
//
// `p1` READ FROM THE CODE, not assumed: `LinearRegression::fit`
// augments the design with an intercept column (`basis` is stored
// WITHOUT one -- see `predictions`), so the projection estimates
// `p1 = basis.cols() + 1` coefficients and `coef.length() ==
// se.length() == p1` with the intercept at index 0. This is the same
// `p` the `nonrobust` branch already uses at `sigma^2 = RSS / (n -
// p)`, so the HC1 correction is consistent with the homoskedastic SE
// sitting next to it in the same struct. `n_params()` exposes it.

///|
/// v0.97.0+: the number of coefficients the BLP projection
/// estimates, `basis.cols() + 1`. `LinearRegression::fit` augments
/// the stored `basis` with an intercept column, so this is
/// `coef.length()` and `se.length()` on a fitted model, with the
/// intercept at index 0.
///
/// This is the `k` of the HC1 finite-sample correction
/// `n / (n - k)` in `hac_se(HC1)`, and the same `p` the
/// `cov_type = "nonrobust"` branch uses for `RSS / (n - p)`. Read it
/// from here rather than assuming `basis.cols()`: the two differ by
/// the intercept.
///
/// Available before `fit` (it is a property of the design, not of
/// the fit), mirroring `DoubleMLRDD::n_local_params`.
pub fn DoubleMLBLP::n_params(self : DoubleMLBLP) -> Int {
  self.basis.cols() + 1
}

///|
/// Internal: the OLS hat-matrix diagonal of the intercept-augmented
/// BLP design,
/// `h_i = xa_i' * (X'X + ridge I)^-1 * xa_i`
/// with `X = [1, basis]`, `xa_i` the i-th augmented row, and
/// `ridge = 1e-10` -- the `LinearRegression::new()` default that
/// `fit` and `LinearRegression::sandwich_se` both use, so the
/// leverage is regularised exactly as the point estimate and the
/// HC0 meat are.
///
/// Length `n_obs`. The single source of the leverage for
/// `leverage()` and for `hac_se` HC2 / HC3, so those three cannot
/// drift apart. No fit is required (it reads only the persisted
/// `basis`); nothing new is persisted for it.
fn DoubleMLBLP::blp_hat_diagonal(self : DoubleMLBLP) -> Array[Double] {
  let xa = augment_with_intercept(self.basis)
  let n = xa.nrows
  let p1 = xa.ncols
  let xtx = matmul(xa.transpose(), xa)
  let m = inv_spd(add_ridge(xtx, 1.0e-10))
  let h = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let mut acc = 0.0
    for a = 0; a < p1; a = a + 1 {
      let xa_i_a = xa.data[i * p1 + a]
      for b = 0; b < p1; b = b + 1 {
        acc = acc + xa_i_a * m.data[a * p1 + b] * xa.data[i * p1 + b]
      }
    }
    h[i] = acc
  }
  h
}

///|
/// v0.97.0+: the OLS hat-matrix diagonal of the BLP design, the same
/// quantity `hac_se` HC2 / HC3 divide by. Length `n_obs`.
///
/// `X^a (X'X + ridge I)^-1 X^{a'}` is a projection plus a
/// `ridge`-order perturbation, so every entry lies in `[0, 1)` and
/// the entries sum to the RANK of the augmented design -- the trace
/// of a projection is its rank -- which is `n_params()` for a
/// full-rank `basis` and LESS for a rank-deficient one (a constant
/// or duplicated basis column), always up to the `ridge` term.
/// `expand_v097_test.mbt` pins the trace against the rank and the
/// `[0, 1)` bound.
///
/// Recomputed from the persisted `basis` on every call: BLP is a
/// single closed-form OLS projection, so there is nothing to
/// persist for it and nothing in the `FitCache` to extend.
pub fn DoubleMLBLP::leverage(self : DoubleMLBLP) -> Array[Double] {
  try {
    require(self.fitted)
    self.blp_hat_diagonal()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Degrees-of-freedom guard for the HC1 / HC2 / HC3 variants: the
/// projection must have MORE rows than the augmented design has
/// parameters, or the fit is rank-deficient.
///
/// This is not a formality, and it is not a formality that a
/// leverage-range check can replace. With `1e-10` ridge, a
/// rank-deficient design reports `h_i = 1 - 1e-10` rather than the
/// exact `1`, so `1 - h_i` is POSITIVE and a pure "is `1 - h_i > 0`"
/// check does NOT fire -- while HC2 would then divide the meat by
/// `~1e-10` and report an SE inflated by `1 / sqrt(1e-10) ~ 1e5`.
/// So this df check has to come FIRST, and the range check alone is
/// not sufficient. This is the same ordering, and the same measured
/// failure mode, as `rdd_hac_require_df` (v0.96.0).
///
/// HC0 is deliberately NOT guarded: on such a fit `fit` itself still
/// reports a number, and `hac_se(HC0) == se` is the anchor this API
/// promises -- refusing HC0 would break the one identity it makes.
fn blp_hac_require_df(kind_name : String, n : Int, p1 : Int) -> Unit {
  if n <= p1 {
    abort(
      "DoubleMLBLP::hac_se(" +
      kind_name +
      "): the projection has " +
      n.to_string() +
      " rows but the augmented design has " +
      p1.to_string() +
      " parameters (basis.cols() = " +
      (p1 - 1).to_string() +
      " plus the intercept LinearRegression::fit adds), so it is rank-deficient. HC1 needs n - k > 0, and HC2 / HC3 need an identified leverage: a rank-deficient design reports h_i = 1 - ridge, so the (1 - h_i) divisor would be a ridge artifact and inflate the variance by ~1 / ridge. Supply more rows or fewer basis columns.",
    )
  }
}

///|
/// v0.97.0+: heteroskedasticity-consistent (Huber-White) standard
/// errors for the BLP projection, in the HC0 / HC1 / HC2 / HC3
/// family. Returns a length-`n_params()` vector -- one SE per
/// coefficient, intercept at index 0 -- mirroring `coef` and `se`,
/// which are both that length.
///
/// This is NOT `sandwich_se`. Read the section comment above
/// ("WHY BLP DOES NOT REUSE `sandwich_se`") for the algebra: BLP's
/// meat is `sum_i ( (M[j,:] . xa_i)^2 * e_i^2 )` with a full
/// `p1 x p1` normal inverse and no `1 / n^2`, where the shared DML
/// helper is a scalar-Jacobian MEAN-moment sandwich. The
/// `SandwichKind` enum is reused -- it is the package's shared
/// vocabulary for the HC family -- but the arithmetic behind each
/// variant is the projection one.
///
/// The invariant that proves the wiring: on a `cov_type = "HC0"`
/// fit, `se` IS the HC0 standard error, so
/// `hac_se(HC0) == se` holds BIT-IDENTICALLY, elementwise. It is
/// NOT claimed on a `cov_type = "nonrobust"` fit, whose `se` is the
/// homoskedastic `sigma^2 (X'X)^-1` form.
///
/// HC2 / HC3 divide each term by `1 - h_i` (HC2) or `(1 - h_i)^2`
/// (HC3) using the OLS hat diagonal from `leverage()`. If any `h_i`
/// leaves `[0, 1)` the divisor would be non-positive, which means
/// the projection is rank-deficient. This ABORTS rather than
/// clipping: a clip is what silently broke identities in v0.93 /
/// v0.94, and for a leverage in `[0, 1)` no correction should ever
/// fire. See `blp_hac_require_df` for why the df check has to run
/// first.
pub fn DoubleMLBLP::hac_se(
  self : DoubleMLBLP,
  kind : SandwichKind,
) -> Array[Double] {
  try {
    require(self.fitted)
    let n = self.orth_signal.length()
    let p1 = self.n_params()
    // The SE vector is indexed by coefficient, so its length is
    // fixed by the design, not by `cov_type`.
    require(p1 == self.coef.length())
    require(p1 == self.se.length())
    let needs_df = match kind {
      HC0 => false
      HC1 => true
      HC2 => true
      HC3 => true
    }
    if needs_df {
      blp_hac_require_df(kind.to_string(), n, p1)
    }
    let out = Array::make(p1, 0.0)
    let uses_leverage = match kind {
      HC0 | HC1 => false
      HC2 | HC3 => true
    }
    if !uses_leverage {
      // HC0 / HC1: call the SAME expression `fit` calls on its HC0
      // branch, so `hac_se(HC0) == se` is bit-identical BY
      // CONSTRUCTION rather than by matching a re-implementation.
      // `LinearRegression::new()` carries the same default ridge
      // (1e-10) `fit` uses.
      let var_diag = LinearRegression::new()
        .fit(self.basis, self.orth_signal)
        .sandwich_se(self.basis, self.orth_signal)
      // HC1 is a pure variance scale (the Stata `, robust` /
      // `statsmodels cov_type='HC1'` convention). The SE ratio is
      // therefore `sqrt(n / (n - p1))`, and `blp_hac_require_df`
      // has already guaranteed the denominator is positive.
      let scale = match kind {
        HC1 => n.to_double() / (n.to_double() - p1.to_double())
        _ => 1.0
      }
      for j = 0; j < p1; j = j + 1 {
        out[j] = (var_diag[j] * scale).sqrt()
      }
      return out
    }
    // HC2 / HC3: the same meat, per term, divided by the leverage.
    // The divisor for row i is `1 - h_i` (HC2) or `(1 - h_i)^2`
    // (HC3); the `[0, 1)` range check ABORTS rather than clips.
    let h = self.blp_hat_diagonal()
    require(h.length() == n)
    let div = Array::make(n, 1.0)
    for i = 0; i < n; i = i + 1 {
      let hi = h[i]
      if !(hi >= 0.0 && hi < 1.0) {
        abort(
          "DoubleMLBLP::hac_se: leverage h_" +
          i.to_string() +
          " = " +
          hi.to_string() +
          " is outside [0, 1). An OLS hat-matrix diagonal always lies in [0, 1) unless the projection is rank-deficient (fewer rows than parameters, or a collinear basis), so 1 - h_i would be non-positive. Aborting instead of clipping.",
        )
      }
      let one_minus_h = 1.0 - hi
      div[i] = match kind {
        HC3 => one_minus_h * one_minus_h
        _ => one_minus_h
      }
    }
    // Rebuild the HC0 ingredients in exactly the association
    // `LinearRegression::sandwich_se` accumulates them in --
    // `M[j,:]` by back-solving `(X'X + ridge I) m_j = e_j` (the
    // implementation's route, not a full inverse), the row product
    // left-to-right, and the residual as `y_i - (X . beta)_i` from
    // the OLS model. With every `div[i] == 1.0` this reduces to
    // `hac_se(HC0)`; `expand_v097_test.mbt` pins that reduction on a
    // constant-leverage design.
    let xa = augment_with_intercept(self.basis)
    let ols_model = LinearRegression::new().fit(self.basis, self.orth_signal)
    let beta = ols_model.coefficients()
    let pred = matvec(xa, beta)
    let xtx_aug = add_ridge(matmul(xa.transpose(), xa), 1.0e-10)
    let ej = Array::make(p1, 0.0)
    for j = 0; j < p1; j = j + 1 {
      ej[j] = 1.0
      let mj = solve_spd(xtx_aug, ej)
      ej[j] = 0.0
      let mut acc = 0.0
      for i = 0; i < n; i = i + 1 {
        let mut mjx = 0.0
        for a = 0; a < p1; a = a + 1 {
          mjx = mjx + mj[a] * xa.data[i * p1 + a]
        }
        let ei = self.orth_signal[i] - pred[i]
        acc = acc + mjx * mjx * ei * ei / div[i]
      }
      out[j] = acc.sqrt()
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.97.0+: cluster-robust (Arellano 1987, Cameron-Gelbach-Miller
/// 2011) standard errors for the BLP projection -- the clustered
/// analogue of `hac_se(HC0)`, one SE per coefficient.
///
/// `cluster_ids[i]` is the 0-based cluster of the i-th row of
/// `basis` and `orth_signal`, and `cluster_ids.length()` must equal
/// `n_obs`. Cluster indices are 0-based; `1 + max(cluster_ids)` is
/// the number of clusters.
///
/// Per-row score for coefficient `j`, `s_ij = m_j(xa_i) * e_i` (the
/// BLP HC0 term under a square root, with its sign), aggregated
/// within cluster:
///
///     S_cj    = sum_{i in c} s_ij
///     var_j   = sum_c S_cj^2 * n_c / (n_c - 1)
///
/// with the `(n_c - 1)` jackknife correction clipped to 1 for
/// single-observation clusters (the `statsmodels
/// cov_type='cluster'` convention, and the same clip
/// `cluster_sandwich_variance` uses). There is NO `1 / n^2`
/// divisor: the shared helper needs one because its moment is a
/// MEAN moment, while this is a sum of squared row scores, exactly
/// like `hac_se(HC0)`.
///
/// With all-singleton clusters the meat collapses to
/// `sum_i s_ij^2`, i.e. `hac_se(HC0)` -- to floating-point
/// tolerance, NOT bit-exactly, for two reasons: the per-row square
/// is formed as `s_i * s_i` here against the `m^2 e^2`
/// association in `hac_se`, and this accumulator is
/// Kahan-compensated (as in `cluster_sandwich_variance`) against
/// `hac_se`'s plain running sum. Pooled clusters differ.
///
/// `DoubleMLBLP` has no `cluster_vars` field, so the user must pass
/// `cluster_ids` explicitly. Calling on an un-fit model aborts via
/// `PreconditionError`.
pub fn DoubleMLBLP::cluster_hac_se(
  self : DoubleMLBLP,
  cluster_ids : Array[Int],
) -> Array[Double] {
  try {
    require(self.fitted)
    let n = self.orth_signal.length()
    let p1 = self.n_params()
    require(p1 == self.coef.length())
    require(cluster_ids.length() == n)
    let mut max_cid = -1
    for i = 0; i < n; i = i + 1 {
      require(cluster_ids[i] >= 0)
      if cluster_ids[i] > max_cid {
        max_cid = cluster_ids[i]
      }
    }
    require(max_cid >= 0)
    let n_clusters = max_cid + 1
    // One accumulator PER CLUSTER: `Array::make(n_clusters, row)`
    // would alias a single inner array across every cluster, so the
    // rows are allocated explicitly.
    let cluster_sum : Array[Array[Double]] = Array::make(n_clusters, [])
    for c = 0; c < n_clusters; c = c + 1 {
      cluster_sum[c] = Array::make(p1, 0.0)
    }
    let cluster_size : Array[Int] = Array::make(n_clusters, 0)
    let xa = augment_with_intercept(self.basis)
    let ols_model = LinearRegression::new().fit(self.basis, self.orth_signal)
    let beta = ols_model.coefficients()
    let pred = matvec(xa, beta)
    let xtx_aug = add_ridge(matmul(xa.transpose(), xa), 1.0e-10)
    let ej = Array::make(p1, 0.0)
    for j = 0; j < p1; j = j + 1 {
      ej[j] = 1.0
      let mj = solve_spd(xtx_aug, ej)
      ej[j] = 0.0
      for i = 0; i < n; i = i + 1 {
        let mut mjx = 0.0
        for a = 0; a < p1; a = a + 1 {
          mjx = mjx + mj[a] * xa.data[i * p1 + a]
        }
        let s = mjx * (self.orth_signal[i] - pred[i])
        cluster_sum[cluster_ids[i]][j] = cluster_sum[cluster_ids[i]][j] + s
      }
    }
    for i = 0; i < n; i = i + 1 {
      cluster_size[cluster_ids[i]] = cluster_size[cluster_ids[i]] + 1
    }
    let out = Array::make(p1, 0.0)
    // Kahan-compensated, matching `cluster_sandwich_variance`.
    for j = 0; j < p1; j = j + 1 {
      let mut acc = 0.0
      let mut acc_c = 0.0
      for c = 0; c < n_clusters; c = c + 1 {
        let nc = cluster_size[c]
        if nc == 0 {
          continue
        }
        let scale = if nc <= 1 {
          1.0
        } else {
          nc.to_double() / (nc.to_double() - 1.0)
        }
        let sc = cluster_sum[c][j]
        let term = sc * sc * scale
        let y = term - acc_c
        let t = acc + y
        acc_c = t - acc - y
        acc = t
      }
      require(acc >= 0.0)
      out[j] = acc.sqrt()
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// A binary tree node used by `DoubleMLPolicyTree`. A `Leaf` is a
/// terminal that always returns the given treatment. A `Split` carries
/// the split feature, the threshold value, and the two child nodes.
/// Internal-only (not exposed in the public API) so the public
/// `DoubleMLPolicyTree` signature is unchanged from the depth-1 era.
pub enum PolicyTreeNode {
  Leaf(Int)
  Split(Int, Double, PolicyTreeNode, PolicyTreeNode)
} derive(Debug)

///|
pub extend PolicyTreeNode with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Recursively compute the variance-reduction gain for the best split
/// at the given depth. At `depth == 1` (the leaf level) we stop and
/// return the leaf treatment (sign of the mean signal). At deeper
/// levels we expand the recursion by one level.
fn policy_tree_build(
  features : Matrix,
  signal : Array[Double],
  depth : Int,
) -> PolicyTreeNode {
  let n = signal.length()
  if n == 0 {
    return Leaf(0)
  }
  // depth=0 means: this subtree is a leaf (no further splitting).
  // The build call at the root always passes `depth=self.depth` and
  // recurses with `depth-1`, so depth=1 builds a Split whose
  // children are leaves (depth-1 stump), depth=2 builds a Split
  // whose children are depth-1 stumps, etc.
  if depth == 0 {
    let mut sum = 0.0
    for s in signal {
      sum = sum + s
    }
    let mean = sum / n.to_double()
    return Leaf(if mean >= 0.0 { 1 } else { 0 })
  }
  // find the best-split feature and threshold
  let mut best = -1.0e308
  let mut bf = -1
  let mut bv = 0.0
  let mut bnl = 0
  let mut bnr = 0
  for j = 0; j < features.cols(); j = j + 1 {
    let mut threshold = 0.0
    for i = 0; i < n; i = i + 1 {
      threshold = threshold + features.get(i, j)
    }
    threshold = threshold / n.to_double()
    let mut sl = 0.0
    let mut sr = 0.0
    let mut nl = 0
    let mut nr = 0
    let mut ssl = 0.0
    let mut ssr = 0.0
    for i = 0; i < n; i = i + 1 {
      if features.get(i, j) < threshold {
        sl = sl + signal[i]
        ssl = ssl + signal[i] * signal[i]
        nl = nl + 1
      } else {
        sr = sr + signal[i]
        ssr = ssr + signal[i] * signal[i]
        nr = nr + 1
      }
    }
    let gain = if nl > 0 && nr > 0 {
      let mean_l = sl / nl.to_double()
      let mean_r = sr / nr.to_double()
      let var_l = ssl / nl.to_double() - mean_l * mean_l
      let var_r = ssr / nr.to_double() - mean_r * mean_r
      -(nl.to_double() / n.to_double()) * var_l -
      nr.to_double() / n.to_double() * var_r
    } else {
      -1.0e308
    }
    if gain > best {
      best = gain
      bf = j
      bv = threshold
      bnl = nl
      bnr = nr
    }
  }
  // If no split improves, return a leaf
  if bf < 0 {
    let mut sum = 0.0
    for s in signal {
      sum = sum + s
    }
    let mean = sum / n.to_double()
    return Leaf(if mean >= 0.0 { 1 } else { 0 })
  }
  // Build left and right sub-feature matrices / sub-signal arrays
  let left_signal : Array[Double] = Array::make(bnl, 0.0)
  let right_signal : Array[Double] = Array::make(bnr, 0.0)
  let left_idx : Array[Int] = []
  let right_idx : Array[Int] = []
  for i = 0; i < n; i = i + 1 {
    if features.get(i, bf) < bv {
      left_signal[left_idx.length()] = signal[i]
      left_idx.push(i)
    } else {
      right_signal[right_idx.length()] = signal[i]
      right_idx.push(i)
    }
  }
  // Build sub-feature matrices (same columns, fewer rows)
  let left_features = Matrix::zeros(bnl, features.cols())
  let right_features = Matrix::zeros(bnr, features.cols())
  for k = 0; k < bnl; k = k + 1 {
    for j = 0; j < features.cols(); j = j + 1 {
      left_features.data[k * features.cols() + j] = features.get(left_idx[k], j)
    }
  }
  for k = 0; k < bnr; k = k + 1 {
    for j = 0; j < features.cols(); j = j + 1 {
      right_features.data[k * features.cols() + j] = features.get(
        right_idx[k],
        j,
      )
    }
  }
  let left = policy_tree_build(left_features, left_signal, depth - 1)
  let right = policy_tree_build(right_features, right_signal, depth - 1)
  Split(bf, bv, left, right)
}

///|
/// Walk the policy tree to find the leaf treatment for one row.
fn policy_tree_predict(node : PolicyTreeNode, x : Matrix, row : Int) -> Int {
  match node {
    Leaf(t) => t
    Split(feature, threshold, left, right) =>
      if x.get(row, feature) < threshold {
        policy_tree_predict(left, x, row)
      } else {
        policy_tree_predict(right, x, row)
      }
  }
}

///|
/// A compact policy tree. It searches one split per level using weighted
/// variance-reduction gain (Bug #8); the `depth` parameter controls
/// how many levels of recursion to use (TODO #11c.3: previously the
/// `depth` field was unused and the fit was always a depth-1 stump).
pub struct DoubleMLPolicyTree {
  features : Matrix
  orth_signal : Array[Double]
  depth : Int
  // The fitted tree root. `Leaf(_)` means a single treatment for
  // all rows (depth=1 with no useful split, or depth exhaustion).
  root : PolicyTreeNode
  // The depth-1 public surface retained for backward compatibility:
  //   - `split_feature` and `split_value` are the root split if the
  //     root is a Split node, else -1 / 0.0.
  //   - `left_treatment` / `right_treatment` are the leaf treatments
  //     at the depth-1 layer; for depth > 1 they are the leaf
  //     treatments of the immediate left/right children.
  split_feature : Int
  split_value : Double
  left_treatment : Int
  right_treatment : Int
  // v0.69.0+: leaf index per observation (length `n_obs`),
  // populated by `fit`. Used by `sensitivity_analysis` to
  // bucket the residuals and the Riesz-representer rows
  // into per-leaf sub-IRM-style decompositions. The leaf
  // index is a flat 0-based offset into the tree's
  // depth-first leaf enumeration (matching
  // `policy_tree_walk_leaves`).
  leaf_assignment : Array[Int]
  // v0.69.0+: leaf means of `orth_signal`, indexed by leaf
  // assignment. Length = number of leaves in the fitted
  // tree. The per-leaf nuisance-persistence residual is
  // `orth_signal[i] - leaf_signal_mean[3]` for unit `i` with
  // leaf index `3`.
  leaf_signal_mean : Array[Double]
  // v0.69.0+: leaf sizes (counts), indexed by leaf
  // assignment. Length = number of leaves in the fitted
  // tree.
  leaf_count : Array[Int]
  // v0.98.0+: HONESTY (Athey & Imbens 2016, PNAS 113(27):
  // 7353-7358). `honest = true` splits the training sample in
  // two: `policy_tree_build` sees ONLY `split_indices` (the
  // splitting half) and every reported leaf statistic --
  // `leaf_assignment`, `leaf_signal_mean`, `leaf_count`,
  // `leaf_se` -- is computed on `est_indices` (the estimation
  // half) only. `honest = false` (the default) is the v0.97.0
  // behaviour, byte-identical: the same rows choose the splits
  // and produce the leaf means.
  //
  // WHY THIS MATTERS. In the non-honest tree each observation
  // both picks the leaf it lands in AND sets that leaf's
  // reported value, so `leaf_signal_mean` is the value of an
  // ADAPTIVE (data-selected) estimator. Its bias does not vanish
  // at a usable rate and interval coverage can fall well below
  // nominal (Athey & Imbens 2016 report ~69% of nominal for
  // adaptive vs honest recursive partitioning). Splitting the
  // sample buys exactly their property:
  //
  //   "Honesty has the implication that the asymptotic
  //    properties of treatment effect estimates within the
  //    partitions are the same as if the partition had been
  //    exogenously given."
  //
  // and makes that phrase a PROPERTY rather than a claim: the
  // partition is a function of the splitting half alone, so
  // each leaf mean on the estimation half is a plain sample
  // mean of i.i.d. draws under a fixed partition.
  //
  // `split_seed` seeds the `kfold(n, 2, split_seed)` call that
  // produces the two halves, so the split is deterministic and
  // reproducible. `min_leaf_n` is the small-leaf guard threshold
  // (see `leaf_se`); it is a constructor parameter rather than
  // a hard-coded constant so a caller with a smaller
  // estimation half can retune it.
  //
  // COST, ACCEPTED AND DOCUMENTED: a single honest tree throws
  // away roughly half the sample from each of its two jobs. Athey
  // & Imbens recover precision by growing many trees; Wager &
  // Athey (2018, JASA) average many honest trees for exactly
  // this reason in the causal forest. This package deliberately
  // does NOT build a forest -- see the "future work" note on
  // `leaf_se`. Users who need the precision should treat the
  // single honest tree as a diagnostic.
  honest : Bool
  split_seed : Int
  min_leaf_n : Int
  // v0.98.0+: ORIGINAL row indices of the estimation half
  // (length `n_est = ceil(n_obs / 2)` under honesty). These are
  // the indices into `features` / `orth_signal`, NOT positions
  // in a sliced copy. EMPTY when `honest = false`, where the
  // estimation sample is the whole sample in identity order --
  // keeping it empty is what leaves the default path's
  // allocations (and therefore its numbers) untouched.
  est_indices : Array[Int]
  // v0.98.0+: ORIGINAL row indices of the splitting half
  // (length `n_split = floor(n_obs / 2)`). EMPTY when
  // `honest = false`.
  split_indices : Array[Int]
  // v0.98.0+: per-leaf standard errors of `leaf_signal_mean`
  // measured ON THE ESTIMATION HALF, length `n_leaves`. EMPTY
  // when `honest = false` -- see `leaf_se()` for why the
  // adaptive analogue is deliberately not reported.
  leaf_se : Array[Double]
  fitted : Bool
  // v0.85.0+: memoization state. `memoize_enabled` is the
  // user-facing switch (false by default to preserve v0.84.0
  // behavior bit-for-bit). When true, `fit()` caches the
  // fitted tree structure (flat-encoded node array) plus the
  // leaf statistics (`leaf_signal_mean` / `leaf_count` /
  // `leaf_assignment`) in `fit_cache` and reuses them on the
  // next call when the features, orthogonal signal, and
  // `depth` are unchanged. This completes the memoize +
  // vectorize surface on all 22 estimators.
  //
  // PolicyTree is not a cross-fitted nuisance-regression
  // estimator: it has no `n_folds` / `n_rep` / `cluster_vars`.
  // The cache therefore reuses the `FitCache` slots as a
  // shape-compatible container (see the layout docstring on
  // `policy_tree_cache_encode`):
  //   - `fold_ids`          -> `leaf_assignment` (len n_obs)
  //   - `predictions[0]`    -> `leaf_signal_mean` (len n_leaves)
  //   - `predictions[1]`    -> `leaf_assignment` as Double
  //   - `predictions[2]`    -> flat node encoding (len 5*n_nodes)
  //   - `predictions[3]`    -> `leaf_count` as Double
  //   - `predictions[4]`    -> [split_feature, split_value, lt, rt]
  //   - `n_folds`           -> n_leaves (partition-count analogue)
  //   - `fold_split_seed`   -> `depth` (PolicyTree has no seed)
  //
  // v0.98.0+: UNDER HONESTY the layout shifts, because the cached
  // payload is no longer indexed by all `n_obs` rows:
  //   - `fold_ids`          -> `est_indices` (len n_est)
  //   - `n_obs`             -> `n_est` (the cached row count;
  //                            `is_valid` compares
  //                            `fold_ids.length() == n_obs`, so
  //                            this slot MUST hold n_est under
  //                            honesty or the hit can never fire)
  //   - `predictions[5]`    -> `leaf_se` (len n_leaves)
  //   - `predictions[6]`    -> `split_indices` as Double
  //                            (len n_split)
  // The default (`honest = false`) layout above is UNCHANGED.
  //
  // v0.98.0+ CACHE KEY. `honest` and `split_seed` are structural
  // -- they change which rows build the tree and which rows
  // produce the leaf means -- so they are folded into the key via
  // the `estimator_kind` string: `"policy_tree"` when not honest
  // (byte-identical to v0.85.0-v0.97.0) and
  // `"policy_tree_honest:<split_seed>"` when honest.
  // `hash_hyperparams` folds `estimator_kind`'s length and bytes
  // into the hyperparams hash and `is_valid` compares the stored
  // string, so toggling `honest` or changing `split_seed`
  // invalidates the cache in both directions. `min_leaf_n` is
  // deliberately NOT in the key: it is a reporting threshold,
  // not a fitting input, and it does not change a single fitted
  // number.
  memoize_enabled : Bool
  fit_cache : FitCache
} derive(Debug)

///|
pub extend DoubleMLPolicyTree with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// v0.98.0+: the HONESTY switch, `honest`, plus its two supporting
/// parameters `split_seed` and `min_leaf_n`. All three default to
/// the inert setting, so a v0.97.0 call site sees byte-identical
/// output -- see the `honest` field docstring on the struct for the
/// definition and the motivation.
///
/// - `honest` (default `false`): when `true`, split the sample and
///   build the tree on one half only. See the struct field.
/// - `split_seed` (default `2024`): seeds the
///   `kfold(n_obs, 2, split_seed)` call that produces the two
///   halves. Ignored when `honest = false`. Only the FIRST of the
///   two returned folds is used: its `train_indices()` is the
///   splitting half (`floor(n_obs / 2)` rows) and its
///   `test_indices()` is the estimation half
///   (`ceil(n_obs / 2)` rows).
/// - `min_leaf_n` (default `5`): the small-leaf guard threshold on
///   ESTIMATION-half leaf counts. Must be `>= 2`. See `leaf_se` for
///   why 5.
pub fn DoubleMLPolicyTree::new(
  features : Matrix,
  orth_signal : Array[Double],
  depth? : Int = 1,
  honest? : Bool = false,
  split_seed? : Int = 2024,
  min_leaf_n? : Int = 5,
) -> DoubleMLPolicyTree {
  try {
    require(features.rows() == orth_signal.length())
    require(depth >= 1)
    // `min_leaf_n = 1` would make the guard vacuous and
    // `min_leaf_n = 2` would still admit a 0-degree-of-freedom
    // variance, so both are refused at construction rather than
    // producing an undefined `leaf_se` later.
    require(min_leaf_n >= 2)
    {
      features,
      orth_signal,
      depth,
      root: Leaf(0),
      split_feature: -1,
      split_value: 0.0,
      left_treatment: 0,
      right_treatment: 0,
      leaf_assignment: [],
      leaf_signal_mean: [],
      leaf_count: [],
      // v0.98.0+: honesty off by default so v0.97.0 callers see
      // byte-identical fit() output. The three honest-only arrays
      // stay empty until a `honest = true` fit populates them.
      honest,
      split_seed,
      min_leaf_n,
      est_indices: [],
      split_indices: [],
      leaf_se: [],
      fitted: false,
      // v0.85.0+: default memoize off so v0.84.0 callers see
      // byte-identical fit() output. Enable explicitly via
      // `.enable_memoize()` for caching.
      memoize_enabled: false,
      fit_cache: FitCache::empty(),
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Extract the depth-1 left/right leaf treatments from the root. If
/// the root is itself a leaf, both sides get the same treatment.
fn policy_root_lr_treatments(root : PolicyTreeNode) -> (Int, Int) {
  match root {
    Leaf(t) => (t, t)
    Split(_, _, left, right) =>
      match (left, right) {
        (Leaf(l), Leaf(r)) => (l, r)
        (Leaf(l), _) => (l, l)
        (_, Leaf(r)) => (r, r)
        _ => (0, 0)
      }
  }
}

///|
/// Walk the tree and emit leaves in depth-first order. Returns the
/// list of leaf treatments in DFS order. v0.69.0+ used by
/// `DoubleMLPolicyTree::fit` to populate
/// `leaf_assignment` / `leaf_signal_mean` / `leaf_count`.
fn policy_tree_walk_leaves(node : PolicyTreeNode, out : Array[Int]) -> Unit {
  match node {
    Leaf(t) => out.push(t)
    Split(_, _, left, right) => {
      policy_tree_walk_leaves(left, out)
      policy_tree_walk_leaves(right, out)
    }
  }
}

///|
/// Walk the tree to find the leaf index for a single row. The leaf
/// index matches the DFS order emitted by
/// `policy_tree_walk_leaves`. v0.69.0+ used by
/// `DoubleMLPolicyTree::fit` to populate `leaf_assignment`.
fn policy_tree_leaf_index(
  node : PolicyTreeNode,
  x : Matrix,
  row : Int,
  acc : Int,
) -> Int {
  match node {
    Leaf(_) => acc
    Split(feature, threshold, left, right) =>
      if x.get(row, feature) < threshold {
        policy_tree_leaf_index(left, x, row, acc)
      } else {
        // Skip the entire left subtree (its DFS range is
        // [acc, acc + n_left_leaves)); recurse into right.
        let after_left = acc + policy_tree_count_leaves(left)
        policy_tree_leaf_index(right, x, row, after_left)
      }
  }
}

///|
/// Count the leaves in a tree subtree. Internal helper
/// for `policy_tree_leaf_index`.
fn policy_tree_count_leaves(node : PolicyTreeNode) -> Int {
  match node {
    Leaf(_) => 1
    Split(_, _, left, right) =>
      policy_tree_count_leaves(left) + policy_tree_count_leaves(right)
  }
}

///|
/// Widen an `Array[Int]` to `Array[Double]`. Used by the v0.85.0+
/// memoization layer so the `Int`-typed policy-tree statistics
/// (`leaf_assignment`, `leaf_count`) fit into the
/// `Array[Array[Double]]` payload shape of `FitCache`.
fn policy_tree_ints_to_doubles(xs : Array[Int]) -> Array[Double] {
  let n = xs.length()
  let out : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    out[i] = xs[i].to_double()
  }
  out
}

///|
/// Inverse of `policy_tree_ints_to_doubles`. The stored values are
/// exact small integers widened to `Double`, so `to_int()` recovers
/// them without loss. Used on the v0.85.0+ cache-hit path to
/// restore `leaf_assignment` / `leaf_count`.
fn policy_tree_ints_from_doubles(xs : Array[Double]) -> Array[Int] {
  let n = xs.length()
  let out : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    out[i] = xs[i].to_int()
  }
  out
}

///|
/// v0.85.0+: flat-encode a `PolicyTreeNode` into a fixed-width
/// `Array[Double]` so the fitted tree can be stored in the
/// `Array[Array[Double]]` payload of `FitCache` and rebuilt on a
/// cache hit. `PolicyTreeNode` is a recursive sum type with no
/// `Clone` derive, so it cannot be stored directly.
///
/// Layout: 5 slots per node, emitted in pre-order. Each node
/// occupies `[kind, a, b, left_slot, right_slot]`:
///
///   - `kind == 0.0` -> `Leaf(a.to_int())`; `b` and both slot
///     fields are unused (written as `0.0` / `-1.0`).
///   - `kind == 1.0` -> `Split(a.to_int(), b, left, right)` where
///     `left` / `right` are recursive indexes into `out`.
///
/// The 5 slots of the parent are reserved BEFORE recursing into
/// the children, so a child's slot index is always greater than
/// its parent's and `policy_tree_cache_decode` can walk the
/// pre-order array without any extra bookkeeping. The root always
/// lands at slot 0.
fn policy_tree_cache_encode(node : PolicyTreeNode, out : Array[Double]) -> Int {
  let slot = out.length() / 5
  out.push(0.0)
  out.push(0.0)
  out.push(0.0)
  out.push(-1.0)
  out.push(-1.0)
  match node {
    Leaf(t) => {
      out[slot * 5 + 0] = 0.0
      out[slot * 5 + 1] = t.to_double()
    }
    Split(feature, threshold, left, right) => {
      let left_slot = policy_tree_cache_encode(left, out)
      let right_slot = policy_tree_cache_encode(right, out)
      out[slot * 5 + 0] = 1.0
      out[slot * 5 + 1] = feature.to_double()
      out[slot * 5 + 2] = threshold
      out[slot * 5 + 3] = left_slot.to_double()
      out[slot * 5 + 4] = right_slot.to_double()
    }
  }
  slot
}

///|
/// v0.85.0+: inverse of `policy_tree_cache_encode`. Rebuilds the
/// `PolicyTreeNode` rooted at `slot` from the flat pre-order
/// encoding produced by `policy_tree_cache_encode`.
fn policy_tree_cache_decode(flat : Array[Double], slot : Int) -> PolicyTreeNode {
  let b = slot * 5
  if flat[b] == 0.0 {
    Leaf(flat[b + 1].to_int())
  } else {
    let left = policy_tree_cache_decode(flat, flat[b + 3].to_int())
    let right = policy_tree_cache_decode(flat, flat[b + 4].to_int())
    Split(flat[b + 1].to_int(), flat[b + 2], left, right)
  }
}

///|
/// v0.98.0+: the HONEST per-leaf standard errors, measured on the
/// ESTIMATION half only.
///
/// WHY AN ORDINARY SAMPLE VARIANCE IS THE HONEST NUMBER HERE.
/// Athey & Imbens (2016) define honesty as "not using the same
/// information for selecting the model structure ... as for
/// estimation given a model structure", and state the payoff
/// exactly: under honesty "the asymptotic properties of treatment
/// effect estimates within the partitions are the same as if the
/// partition had been exogenously given". Held fixed, leaf `k`'s
/// value IS a plain sample mean of `n_k` i.i.d. draws, so its
/// variance is the textbook one:
///
///     leaf_se[k] = sqrt( sum_{i in k} (y_i - theta_k)^2
///                        / ((n_k - 1) * n_k) )
///
/// i.e. the sample standard deviation (divisor `n_k - 1`) over
/// `sqrt(n_k)`. That is the whole formula -- no sandwich.
///
/// WHY NOT `sandwich_variance` / `var_est`. Both are for DML
/// SCORES. `var_est` computes the `-Q` ratio
/// `theta = -mean(psi_b) / mean(psi_a)` and divides by
/// `mean(psi_a)^2 * n`; a leaf mean is not a ratio of two means
/// and has no `psi_a`/`psi_m` split, so routing it through
/// `var_est` would estimate a different functional.
/// `sandwich_variance_hc0` takes a `(1, 1)` `m_inv` and an
/// `n_params` count, i.e. it is the meat of a LINEAR projection
/// (the shape BLP / RDD `hac_se` use). A leaf mean is a third
/// thing: a scalar mean under a fixed partition. It is also worth
/// saying what is NOT being claimed: this SE excludes the
/// variance contributed by the split SEARCH. Honesty buys
/// nominal coverage for the WITHIN-partition effects, which is
/// what Athey & Imbens promise; it does not make the partition
/// itself exogenous, and no amount of honesty turns the selected
/// partition into a fixed one.
///
/// `n_k <= 1` has zero degrees of freedom, so the sample variance
/// is genuinely undefined there and the entry is set to
/// `@double.not_a_number` -- not to `0.0`, which would read as
/// "infinitely precise", and not to a huge finite number, which
/// would read as an ordinary large SE. Every such leaf is also
/// reported by `unreliable_leaves()` because
/// `min_leaf_n >= 2 > n_k`.
fn policy_tree_honest_leaf_se(
  leaf_count : Array[Int],
  leaf_mean : Array[Double],
  signal : Array[Double],
  leaf_assignment : Array[Int],
) -> Array[Double] {
  let n_leaves = leaf_count.length()
  let n_est = signal.length()
  // Uncentred second moment per leaf, accumulated in increasing
  // row order over the ESTIMATION half only.
  let leaf_sumsq : Array[Double] = Array::make(n_leaves, 0.0)
  for j = 0; j < n_est; j = j + 1 {
    let l = leaf_assignment[j]
    let d = signal[j] - leaf_mean[l]
    leaf_sumsq[l] = leaf_sumsq[l] + d * d
  }
  let out : Array[Double] = Array::make(n_leaves, 0.0)
  for k = 0; k < n_leaves; k = k + 1 {
    let nk = leaf_count[k]
    if nk < 2 {
      out[k] = @double.not_a_number
    } else {
      let nk_d = nk.to_double()
      out[k] = (leaf_sumsq[k] / ((nk_d - 1.0) * nk_d)).sqrt()
    }
  }
  out
}

///|
pub fn DoubleMLPolicyTree::fit(self : DoubleMLPolicyTree) -> DoubleMLPolicyTree {
  // v0.85.0+: memoize check. PolicyTree is a deterministic policy
  // learner (no `n_folds` / `n_rep` / `cluster_vars`), so the cache
  // holds the fitted tree structure plus the per-leaf statistics
  // rather than per-fold nuisance predictions. The cache key is
  // `(data_hash, depth, hyperparams_hash)`; on a hit `fit()` skips
  // both `policy_tree_build` (the dominant `O(n * p * nodes)` cost,
  // with a recursive `Matrix` allocation per node) and the
  // `O(n * depth)` leaf-walk / accumulation loop.
  let n_obs = self.orth_signal.length()
  let memoize = self.memoize_enabled
  // v0.98.0+: THE HONESTY SPLIT. Reuse the package's existing
  // seeded `kfold` helper rather than writing a third splitting
  // routine -- `kfold(n_obs, 2, split_seed)` is a deterministic
  // Fisher-Yates shuffle cut in half, and `Fold`'s two index
  // lists are DISJOINT and jointly exhaustive by construction.
  //
  // `halves[0].train_indices()` (floor(n_obs / 2) rows) becomes
  // the SPLITTING half; `halves[0].test_indices()` (ceil(n_obs /
  // 2) rows) becomes the ESTIMATION half. Only fold 0 is used --
  // the second fold is the complement of the first, so taking it
  // would give back the same partition.
  //
  // Under `honest = false` both lists stay EMPTY and every
  // derived quantity below is the whole sample in identity order,
  // which is what keeps the default path byte-identical.
  let halves : Array[Fold] = if self.honest {
    kfold(n_obs, 2, self.split_seed)
  } else {
    []
  }
  let split_rows : Array[Int] = if self.honest {
    halves[0].train_indices()
  } else {
    []
  }
  let est_rows : Array[Int] = if self.honest {
    halves[0].test_indices()
  } else {
    []
  }
  // What `policy_tree_build` sees: the splitting half only.
  let build_features : Matrix = if self.honest {
    slice_matrix_rows(self.features, split_rows)
  } else {
    self.features
  }
  let build_signal : Array[Double] = if self.honest {
    slice_vector(self.orth_signal, split_rows)
  } else {
    self.orth_signal
  }
  // What the leaf walk and every reported leaf statistic sees:
  // the estimation half only.
  let est_features : Matrix = if self.honest {
    slice_matrix_rows(self.features, est_rows)
  } else {
    self.features
  }
  let est_signal : Array[Double] = if self.honest {
    slice_vector(self.orth_signal, est_rows)
  } else {
    self.orth_signal
  }
  let n_est = if self.honest { est_rows.length() } else { n_obs }
  // The cached row count. `FitCache::is_valid` enforces
  // `fold_ids.length() == n_obs`, and the honest payload is keyed
  // by the estimation half, so this slot must be `n_est` under
  // honesty. Identical to `n_obs` on the default path.
  let n_obs_cache = n_est
  // v0.98.0+: the cache-kind discriminator. `honest` and
  // `split_seed` are structural (they change which rows build the
  // tree and which rows produce the means), so they go into the
  // key. `hash_hyperparams` folds the string's length and bytes
  // into `hparams_hash`, and `is_valid` compares the stored
  // string, so this invalidates in both directions. The
  // non-honest value is byte-identical to v0.85.0-v0.97.0.
  let estimator_kind : String = if self.honest {
    "policy_tree_honest:" + self.split_seed.to_string()
  } else {
    "policy_tree"
  }
  let data_hash : UInt64 = if memoize {
    // PolicyTree has no `d` vector; pass an empty array so the
    // hash reflects only the features + orth_signal content. This
    // is the FULL sample under honesty too: every row feeds
    // either the splitting half or the estimation half, so a
    // change anywhere has to invalidate.
    hash_data(self.features, self.orth_signal, [])
  } else {
    0UL
  }
  let hparams_hash : UInt64 = if memoize {
    // PolicyTree carries no nuisance learner, so both learner
    // slots get a `Noop` dispatch and the `depth` is folded in
    // through the `propensity_clip` slot (its Double analogue
    // here). Mirrors the BLP `cov_type` proxy convention.
    hash_hyperparams(
      estimator_kind,
      LearnerDispatch::noop(),
      LearnerDispatch::noop(),
      self.depth.to_double(),
    )
  } else {
    0UL
  }
  let cluster_hash : UInt64 = if memoize {
    // No `cluster_vars`; the empty vector hashes to the IID
    // sentinel 0.
    hash_cluster_ids([])
  } else {
    0UL
  }
  // `n_leaves` is a property of the fitted tree, so it is not
  // known before the cache is consulted. The `n_folds` slot is
  // therefore fed from the cache's own `leaf_signal_mean` length
  // (0 on an empty cache), which keeps the stored `n_folds`
  // consistent with the briefing's "n_folds = n_leaves"
  // partition-count analogue. An empty cache fails the
  // `fold_ids.length() == n_obs` check first, so a
  // wrong-shape payload can never reach the restore path.
  let n_leaves_hint : Int = if self.fit_cache.is_empty() {
    0
  } else {
    self.fit_cache.predictions[0].length()
  }
  let cache_hit = memoize &&
    self.fit_cache.is_valid(
      // PolicyTree has no seed; `depth` is the structural
      // fingerprint of the fitted tree. (`split_seed` rides on
      // `estimator_kind` instead.)
      self.depth,
      n_leaves_hint,
      1,
      n_obs_cache,
      data_hash,
      hparams_hash,
      cluster_hash,
      estimator_kind,
    )
  if cache_hit {
    // Rebuild the tree + leaf statistics from the cache. The
    // decode is the exact inverse of `policy_tree_cache_encode`,
    // so `root` (and therefore `predict`) is restored bit-for-bit.
    let preds = self.fit_cache.predictions
    let cached_root = policy_tree_cache_decode(preds[2], 0)
    let meta = preds[4]
    let cached_leaf_mean = preds[0]
    let cached_leaf_count = policy_tree_ints_from_doubles(preds[3])
    let cached_leaf_assignment = policy_tree_ints_from_doubles(preds[1])
    // v0.98.0+: the honest-only payload. `fold_ids` holds
    // `est_indices` under honesty (and `leaf_assignment` on the
    // default path, where it is left where it was).
    let cached_leaf_se : Array[Double] = if self.honest { preds[5] } else { [] }
    let cached_split : Array[Int] = if self.honest {
      policy_tree_ints_from_doubles(preds[6])
    } else {
      []
    }
    let cached_est : Array[Int] = if self.honest {
      self.fit_cache.fold_ids
    } else {
      []
    }
    return {
      features: self.features,
      orth_signal: self.orth_signal,
      depth: self.depth,
      root: cached_root,
      split_feature: meta[0].to_int(),
      split_value: meta[1],
      left_treatment: meta[2].to_int(),
      right_treatment: meta[3].to_int(),
      leaf_assignment: cached_leaf_assignment,
      leaf_signal_mean: cached_leaf_mean,
      leaf_count: cached_leaf_count,
      honest: self.honest,
      split_seed: self.split_seed,
      min_leaf_n: self.min_leaf_n,
      est_indices: cached_est,
      split_indices: cached_split,
      leaf_se: cached_leaf_se,
      fitted: true,
      memoize_enabled: self.memoize_enabled,
      fit_cache: self.fit_cache,
    }
  }
  let root = policy_tree_build(build_features, build_signal, self.depth)
  let (split_feature, split_value) = match root {
    Leaf(_) => (-1, 0.0)
    Split(feature, threshold, _, _) => (feature, threshold)
  }
  let (lt, rt) = policy_root_lr_treatments(root)
  // v0.69.0+: enumerate leaves in DFS order, populate
  // per-row leaf_assignment + per-leaf means + count.
  let leaf_treatments : Array[Int] = []
  policy_tree_walk_leaves(root, leaf_treatments)
  let n_leaves = leaf_treatments.length()
  let leaf_signal_sum : Array[Double] = Array::make(n_leaves, 0.0)
  let leaf_count_arr : Array[Int] = Array::make(n_leaves, 0)
  let leaf_assignment : Array[Int] = Array::make(n_est, 0)
  // v0.98.0+: the tree built on the SPLITTING half is applied to
  // the ESTIMATION half by the existing `policy_tree_leaf_index`
  // walk -- that walk is what makes honesty work, and it is the
  // same walk the default path uses. Under `honest = false`
  // `est_features` IS `self.features`, `est_signal` IS
  // `self.orth_signal`, and `n_est == n_obs`, so this loop is the
  // v0.85.0-v0.97.0 loop with the same index expressions in the
  // same order: byte-identical.
  //
  // The per-row tree walk (`policy_tree_leaf_index`) is a
  // branchy depth-limited descent, so it stays a scalar loop. Only
  // the per-leaf mean is vectorised below.
  for j = 0; j < n_est; j = j + 1 {
    let lf = policy_tree_leaf_index(root, est_features, j, 0)
    leaf_assignment[j] = lf
    leaf_signal_sum[lf] = leaf_signal_sum[lf] + est_signal[j]
    leaf_count_arr[lf] = leaf_count_arr[lf] + 1
  }
  // v0.85.0+: vectorise the per-leaf mean. `vector_divide` gives
  // `sum / count` for every populated leaf (count >= 1 > eps, so
  // the denominator is used verbatim) and `0.0 / eps = 0.0` for an
  // empty leaf, which reproduces the old `if count > 0` guard
  // exactly -- an empty leaf always has `sum == 0.0` because both
  // accumulators are written in the same loop iteration. So the
  // default (memoize off) path stays byte-identical to v0.84.0.
  let leaf_signal_mean : Array[Double] = vector_divide(
    leaf_signal_sum,
    policy_tree_ints_to_doubles(leaf_count_arr),
    eps=1.0e-12,
  )
  // v0.98.0+: the honest per-leaf SE, on the estimation half only.
  // Empty on the default path -- the adaptive analogue is not a
  // standard error and `leaf_se()` refuses to report it.
  let leaf_se : Array[Double] = if self.honest {
    policy_tree_honest_leaf_se(
      leaf_count_arr, leaf_signal_mean, est_signal, leaf_assignment,
    )
  } else {
    []
  }
  // v0.85.0+: when memoize is on and the cache missed, write the
  // freshly-built tree + leaf statistics to the cache. See the
  // struct field docstring for the slot layout.
  let next_cache = if memoize {
    let flat : Array[Double] = []
    let _ = policy_tree_cache_encode(root, flat)
    let meta : Array[Double] = [
      split_feature.to_double(),
      split_value,
      lt.to_double(),
      rt.to_double(),
    ]
    // v0.98.0+: under honesty the fold-id slot carries the
    // estimation-half indices (which really are a fold
    // assignment, and whose length `n_est` is what the `n_obs`
    // slot records), and two extra payload slots carry `leaf_se`
    // and the splitting half. The default payload is byte-for-
    // byte the v0.85.0 list.
    let fold_ids_slot : Array[Int] = if self.honest {
      est_rows
    } else {
      leaf_assignment
    }
    let preds : Array[Array[Double]] = if self.honest {
      [
        leaf_signal_mean,
        policy_tree_ints_to_doubles(leaf_assignment),
        flat,
        policy_tree_ints_to_doubles(leaf_count_arr),
        meta,
        leaf_se,
        policy_tree_ints_to_doubles(split_rows),
      ]
    } else {
      [
        leaf_signal_mean,
        policy_tree_ints_to_doubles(leaf_assignment),
        flat,
        policy_tree_ints_to_doubles(leaf_count_arr),
        meta,
      ]
    }
    FitCache::from_fit(
      fold_ids_slot,
      preds,
      self.depth,
      n_leaves,
      1,
      n_obs_cache,
      data_hash,
      hparams_hash,
      cluster_hash,
      estimator_kind,
    )
  } else {
    FitCache::empty()
  }
  {
    features: self.features,
    orth_signal: self.orth_signal,
    depth: self.depth,
    root,
    split_feature,
    split_value,
    left_treatment: lt,
    right_treatment: rt,
    leaf_assignment,
    leaf_signal_mean,
    leaf_count: leaf_count_arr,
    honest: self.honest,
    split_seed: self.split_seed,
    min_leaf_n: self.min_leaf_n,
    est_indices: est_rows,
    split_indices: split_rows,
    leaf_se,
    fitted: true,
    memoize_enabled: self.memoize_enabled,
    fit_cache: next_cache,
  }
}

///|
/// v0.98.0+: turn HONESTY on or off. Same immutability contract as
/// `enable_memoize()`: a new struct is returned, the receiver is
/// untouched, and the config flag can be read with `is_honest()`
/// BEFORE `fit()`.
///
/// Toggling this on an already-fitted, memoized model keeps the
/// existing `fit_cache`, but the cache key includes the honesty flag,
/// so the next `fit()` MISSES and recomputes -- the cache can never
/// hand an adaptive fit's numbers to an honest request, nor the
/// reverse. `clear_cache()` drops it outright.
pub fn DoubleMLPolicyTree::enable_honesty(
  self : DoubleMLPolicyTree,
  on : Bool,
) -> DoubleMLPolicyTree {
  { ..self, honest: on, }
}

///|
/// v0.98.0+: re-seed the honesty split. Ignored by the default
/// (non-honest) path, which has no split to seed; folded into the
/// memoize key, so changing it on a memoized model invalidates the
/// cache exactly like toggling `honest` does.
pub fn DoubleMLPolicyTree::enable_split_seed(
  self : DoubleMLPolicyTree,
  seed : Int,
) -> DoubleMLPolicyTree {
  { ..self, split_seed: seed, }
}

///|
/// v0.98.0+: retune the small-leaf guard threshold. Requires `>= 2`.
/// Raising it makes the guard STRICTER. Purely a reporting knob: it
/// changes no fitted number, which is why it is deliberately NOT part
/// of the memoize key.
pub fn DoubleMLPolicyTree::set_min_leaf_n(
  self : DoubleMLPolicyTree,
  n : Int,
) -> DoubleMLPolicyTree {
  try {
    require(n >= 2)
    { ..self, min_leaf_n: n, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.85.0+: turn on memoization for subsequent `fit()` calls.
/// When enabled, `fit()` caches the fitted policy tree plus the
/// per-leaf statistics and skips `policy_tree_build` + the
/// leaf-walk loop on a repeat call whose features, orthogonal
/// signal, and `depth` are all unchanged. Mirrors the BLP / IRM /
/// PLR / CVAR / SSM plumbing.
///
/// Default is OFF. When OFF, every `fit()` call runs the full
/// tree build and the cache is neither read nor written, so
/// v0.84.0 callers see byte-identical output.
pub fn DoubleMLPolicyTree::enable_memoize(
  self : DoubleMLPolicyTree,
) -> DoubleMLPolicyTree {
  { ..self, memoize_enabled: true, }
}

///|
/// v0.85.0+: turn off memoization. Same immutability contract as
/// `enable_memoize()`. After this, `fit()` will not read or write
/// the cache; the existing `fit_cache` is preserved on the
/// returned struct (call `clear_cache()` to drop it).
pub fn DoubleMLPolicyTree::disable_memoize(
  self : DoubleMLPolicyTree,
) -> DoubleMLPolicyTree {
  { ..self, memoize_enabled: false, }
}

///|
/// v0.85.0+: drop any cached policy tree + leaf statistics. Forces
/// the next `fit()` to recompute from scratch.
pub fn DoubleMLPolicyTree::clear_cache(
  self : DoubleMLPolicyTree,
) -> DoubleMLPolicyTree {
  { ..self, fit_cache: FitCache::empty(), }
}

///|
/// v0.85.0+: `true` iff `fit_cache` holds at least one cached
/// observation (i.e. at least one prior `fit()` call with
/// `memoize_enabled = true` has populated the cache). Note that
/// the cache may still be stale relative to the current features /
/// orthogonal signal / `depth` -- check `memoize_enabled` before
/// assuming a cache hit.
pub fn DoubleMLPolicyTree::has_cache(self : DoubleMLPolicyTree) -> Bool {
  !self.fit_cache.is_empty()
}

///|
pub fn DoubleMLPolicyTree::predict(
  self : DoubleMLPolicyTree,
  x : Matrix,
) -> Array[Int] {
  try {
    require(self.fitted)
    let out = Array::make(x.rows(), 0)
    for i = 0; i < x.rows(); i = i + 1 {
      out[i] = policy_tree_predict(self.root, x, i)
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLPolicyTree::split_feature(self : DoubleMLPolicyTree) -> Int {
  try {
    require(self.fitted)
    self.split_feature
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLPolicyTree::split_value(self : DoubleMLPolicyTree) -> Double {
  try {
    require(self.fitted)
    self.split_value
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.98.0+: which regime produced this model's numbers --
/// `true` iff the fit split the sample (honesty), `false` for the
/// v0.97.0 adaptive fit.
///
/// This is the check a caller should make before reading ANY of
/// the uncertainty accessors. `leaf_se`, `policy_value`,
/// `policy_value_se`, `leaf_influence` and the honest branch of
/// `sensitivity_analysis` are all defined on the estimation half
/// of an honest fit and refuse to report on an adaptive one;
/// `is_honest()` lets the caller branch instead of catching an
/// abort. Readable before `fit()` -- it is a configuration flag,
/// not a fitted quantity.
pub fn DoubleMLPolicyTree::is_honest(self : DoubleMLPolicyTree) -> Bool {
  self.honest
}

///|
/// v0.98.0+: the small-leaf guard threshold on ESTIMATION-half
/// leaf counts. Leaves with fewer than this many estimation
/// observations are reported by `unreliable_leaves()` and
/// excluded from `policy_value_se()`. Default `5`; set via
/// `new(min_leaf_n=...)`. Requires `>= 2`. Readable before
/// `fit()`.
pub fn DoubleMLPolicyTree::min_leaf_n(self : DoubleMLPolicyTree) -> Int {
  self.min_leaf_n
}

///|
/// v0.98.0+: the SPLITTING half -- original row indices of the
/// observations `policy_tree_build` was allowed to look at.
/// Length `floor(n_obs / 2)` under honesty. EMPTY when
/// `honest = false`. Disjoint from `est_indices()` and jointly
/// exhaustive of `range_indices(n_obs)`.
pub fn DoubleMLPolicyTree::split_indices(
  self : DoubleMLPolicyTree,
) -> Array[Int] {
  self.split_indices
}

///|
/// v0.98.0+: the ESTIMATION half -- original row indices of the
/// observations every reported leaf statistic is computed from.
/// Length `ceil(n_obs / 2)` under honesty. EMPTY when
/// `honest = false` (there the estimation sample is the whole
/// sample in identity order).
///
/// Under honesty `leaf_assignment` has THIS length, not
/// `n_obs`: position `j` of `leaf_assignment` describes row
/// `est_indices()[j]`. `leaf_influence` returns arrays of the same
/// length, indexed the same way.
pub fn DoubleMLPolicyTree::est_indices(self : DoubleMLPolicyTree) -> Array[Int] {
  self.est_indices
}

///|
/// v0.98.0+: per-leaf standard errors of `leaf_signal_mean`,
/// measured on the ESTIMATION half, length `n_leaves`. See
/// `policy_tree_honest_leaf_se` for the formula and the full
/// derivation.
///
/// WHAT THIS NUMBER IS NOT. It is CONDITIONAL ON THE FITTED
/// STRUCTURE. It is the sampling variance of leaf `k`'s mean
/// given that partition -- it does NOT include the variance from
/// having SEARCHED for that partition. Athey & Imbens (2016) buy
/// nominal coverage for the within-partition effects under
/// honesty; they do not claim the partition itself is exogenous,
/// and neither does this accessor. A leaf mean is a third kind of
/// quantity: it is neither a DML score (so `sandwich_variance` is
/// wrong) nor a projection of several coefficients (so `hac_se` is
/// wrong), and it is not routed through either.
///
/// Requires `honest = true` AND a completed `fit()`. On an
/// adaptive fit this ABORTS rather than returning the naive
/// same-formula number, because that number is the standard error
/// of an adaptive estimator whose bias does not vanish at a usable
/// rate -- reporting it would be the exact silent failure this
/// release exists to prevent. Use `is_honest()` to branch.
pub fn DoubleMLPolicyTree::leaf_se(self : DoubleMLPolicyTree) -> Array[Double] {
  try {
    require(self.fitted)
    require(self.honest)
    self.leaf_se
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.98.0+: `true` iff EVERY leaf holds at least `min_leaf_n()`
/// estimation-half observations, i.e. iff every `leaf_se` entry is
/// backed by enough degrees of freedom to be worth reading. This is
/// the guard that keeps honesty honest about its own limits.
///
/// WHY THE GUARD EXISTS AT ALL. Cattaneo, Klusowski & Yu,
/// "Accuracy Limits of Causal Trees for Individualized Treatment
/// Effects" (arXiv:2509.11381) prove that CART-type greedy
/// recursive partitioning "selects highly imbalanced splits with
/// nonvanishing probability, producing terminal nodes containing
/// very few observations and leading to large estimation variance",
/// and -- the part that matters here -- that "sample splitting,
/// often called 'honesty', does not remove this limitation". So
/// honesty fixes the BIAS (the partition is no longer chosen by
/// the same rows that fill it) and it does NOT fix the SMALL-LEAF
/// VARIANCE. A leaf holding three estimation observations has a
/// real, computed, and nearly meaningless `leaf_se`. Reporting it
/// unflagged would be the "silent huge number" failure mode.
pub fn DoubleMLPolicyTree::leaf_se_reliable(self : DoubleMLPolicyTree) -> Bool {
  try {
    require(self.fitted)
    require(self.honest)
    self.unreliable_leaves().length() == 0
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.98.0+: the leaves whose estimation-half count is below
/// `min_leaf_n()`, in DFS leaf order. Empty iff
/// `leaf_se_reliable()`. This is the explicit, enumerable failure
/// mode: a caller can see exactly WHICH leaves are untrustworthy
/// rather than inferring it from one enormous `leaf_se`.
///
/// Leaves with fewer than 2 estimation observations also land
/// here, and additionally carry a `NaN` in `leaf_se()` -- their
/// sample variance has zero degrees of freedom and does not exist.
pub fn DoubleMLPolicyTree::unreliable_leaves(
  self : DoubleMLPolicyTree,
) -> Array[Int] {
  try {
    require(self.fitted)
    require(self.honest)
    let out : Array[Int] = []
    for k = 0; k < self.leaf_count.length(); k = k + 1 {
      if self.leaf_count[k] < self.min_leaf_n {
        out.push(k)
      }
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.98.0+: the smallest estimation-half leaf count -- the single
/// number that tells a caller whether this honest fit is in the
/// regime Cattaneo-Klusowski-Yu warn about. Requires
/// `honest = true` AND a completed `fit()`.
pub fn DoubleMLPolicyTree::smallest_leaf_count(
  self : DoubleMLPolicyTree,
) -> Int {
  try {
    require(self.fitted)
    require(self.honest)
    let mut smallest = -1
    for k = 0; k < self.leaf_count.length(); k = k + 1 {
      if smallest < 0 || self.leaf_count[k] < smallest {
        smallest = self.leaf_count[k]
      }
    }
    smallest
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.98.0+: THE SCALAR. The policy value of the tree's own
/// decision rule on the estimation half, i.e. the average value
/// the tree assigns to the units it was shown:
///
///     policy_value = sum_k (n_k / n) * theta_k
///
/// over the estimation half, `n_k = leaf_count[k]`,
/// `theta_k = leaf_signal_mean[k]`, `n = sum_k n_k`.
///
/// THE ESTIMAND, STATED PRECISELY, AND IT IS NOT WHAT YOU MIGHT
/// EXPECT. Because `theta_k = (1/n_k) sum_{i in k} y_i`, the
/// weights telescope and
///
///     sum_k (n_k / n) * theta_k = (1/n) * sum_k sum_{i in k} y_i
///                               = (1/n) * sum_j y_j
///                               = mean(y)
///
/// -- the policy value of a leaf-MEAN policy is IDENTICALLY the
/// plain sample mean of `orth_signal` over the estimation half. That
/// is not a bug in the formula, it is the standard fact that a
/// policy whose action value is the group mean attains the group
/// mean by construction and so has ZERO advantage over treating
/// everyone. All the tree's information is in the per-leaf
/// `leaf_signal_mean` / `leaf_se` pairs, NOT in this scalar. The
/// scalar is worth exposing because that identity is the honest
/// headline about what a single-leaf-mean policy tree buys, and
/// because its exact variance is available for free (see
/// `policy_value_se`).
///
/// This is a VALUE (a mean outcome), not a CATE. Requires
/// `honest = true` AND a completed `fit()`. Unguarded: a
/// population-weighted mean is not variance-dominated by one tiny
/// leaf, so no abort is warranted here even when
/// `leaf_se_reliable()` is false.
pub fn DoubleMLPolicyTree::policy_value(self : DoubleMLPolicyTree) -> Double {
  try {
    require(self.fitted)
    require(self.honest)
    let n_est = self.est_indices.length()
    let mut acc = 0.0
    for k = 0; k < self.leaf_signal_mean.length(); k = k + 1 {
      acc = acc +
        self.leaf_count[k].to_double() /
        n_est.to_double() *
        self.leaf_signal_mean[k]
    }
    acc
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.98.0+: standard error of `policy_value()`. It is the EXACT
/// standard error of the plain sample mean of `orth_signal` over
/// the estimation half:
///
///     policy_value_se = sqrt( sum_{j=1..n} (y_j - ybar)^2
///                            / (n * (n - 1)) )
///                     = sd(y) / sqrt(n)
///
/// WHY IT IS NOT `sum_k (n_k/n)^2 * se_k^2`, WHICH IS THE
/// TEMPTING FORMULA AND IS WRONG. That expression assumes the leaf
/// means are INDEPENDENT. They are not: they are `n_k` row means of
/// ONE sample, and two disjoint group means from one sample are
/// NEGATIVELY correlated, `Cov(theta_k, theta_l) =
/// -s_k^2 s_l^2 / (n (n - 1))` for `k != l`. Dropping that
/// covariance does not produce a conservative bound, it produces a
/// wrong number in the wrong direction, and it is worst exactly
/// where the tree is most interesting:
///
/// - If all the variation is BETWEEN leaves (`s_k^2 = 0` for every
///   leaf -- zero within-leaf noise, genuine heterogeneity), the
///   independence formula returns EXACTLY ZERO. The quantity it
///   describes is a sample mean of genuinely spread-out data, so
///   its true SE is `> 0`.
/// - The two-leaf worst case makes it concrete: two leaves of size
///   `n/2` with means `ybar +/- d` give `sum_j (y_j - ybar)^2 = n
///   d^2`, hence `policy_value_se = |d| / sqrt(n - 1) > 0`, while
///   the independence formula still returns `0`.
///
/// The exact form needs no cross-leaf covariance, which is why the
/// joint `n_leaves x n_leaves` covariance matrix -- the honest
/// per-leaf CIs would genuinely want it -- stays out of scope here.
/// FUTURE WORK: expose the full covariance of the leaf means
/// (`Cov(theta_k, theta_l) = -s_k^2 s_l^2 / (n (n-1))` off-diagonal,
/// `s_k^2 / n_k` on it) so per-leaf CIs can be reported honestly at
/// any depth. Building a FOREST of honest trees to recover the
/// precision a single tree loses (Wager & Athey 2018, JASA) is also
/// future work and is deliberately not attempted.
///
/// SAME CAVEAT AS `leaf_se()`: conditional on the fitted
/// structure, not on the partition having been exogenous.
///
/// Requires `honest = true`, a completed `fit()`, AND
/// `leaf_se_reliable() == true`. The reliability guard is
/// deliberate: a scalar SE that is dominated by a three-observation
/// leaf is a claim about sampling variability that the data cannot
/// support, and aborting (with the standard precondition message)
/// is the explicit failure mode. Check `smallest_leaf_count()` or
/// `unreliable_leaves()` first if you want the number anyway.
pub fn DoubleMLPolicyTree::policy_value_se(self : DoubleMLPolicyTree) -> Double {
  try {
    require(self.fitted)
    require(self.honest)
    require(self.leaf_se_reliable())
    let sig = slice_vector(self.orth_signal, self.est_indices)
    let n_est = sig.length()
    let ybar = mean(sig)
    let mut ss = 0.0
    for j = 0; j < n_est; j = j + 1 {
      let d = sig[j] - ybar
      ss = ss + d * d
    }
    (ss / (n_est.to_double() * (n_est.to_double() - 1.0))).sqrt()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.98.0+: THE LEAF-MEAN INFLUENCE FUNCTION, ONE LEAF AT A TIME.
///
/// DERIVATION. Leaf `k` of an honest tree is estimated by the mean
/// of `n_k` i.i.d. observations of the estimation half. Write its
/// estimating equation as an average over the leaf's own rows:
///
///     f_k(theta)  = (1/n_k) * sum_{i in k} (y_i - theta)
///                 = (1/n_k) * sum_{i in k} y_i - theta
///     f_k'(theta) = -n_k * (1/n_k) = -1
///     f_k(theta_hat_k) = 0   at   theta_hat_k = mean(y in k)
///
/// For a Z-estimator `f(theta) = (1/n) sum_i f_i(theta)` the
/// influence function is `IF_i = -f_i(theta_hat) / f'(theta_hat)`.
/// Splitting the estimating function per observation,
/// `f_i(theta) = (y_i - theta) / n_k`, so `f_i'(theta) = -1/n_k`
/// and
///
///     IF_k(i) = -[(y_i - theta_hat_k) / n_k] / (-1)
///             = (y_i - theta_hat_k) / n_k
///
/// on the estimation rows of leaf `k`, and `0` everywhere else.
/// So `M_inv = 1 / f_k' = -1` and the per-observation Riesz
/// denominator that `irm_style_sensitivity` consumes is
/// `psi_a[i] = f_i'(theta_hat_k) = -1 / n_k` -- see
/// `leaf_psi_a`.
///
/// TWO CONSISTENCY CHECKS WORTH WRITING DOWN. (i) It sums to zero
/// within the leaf: `sum_{i in k} IF_k(i) = (1/n_k) sum_{i in k}
/// (y_i - theta_hat_k) = 0`, which is required of any influence
/// function. (ii) Its norm reproduces the leaf SE:
/// `sum_{i in k} IF_k(i)^2 = (n_k - 1) s_k^2 / n_k^2`, which
/// agrees with `leaf_se[k] = s_k / sqrt(n_k)` to within the
/// familiar `(n_k - 1)/n_k` factor -- the two differ because
/// `leaf_se` uses the `n_k - 1` divisor and `sqrt(sum IF^2)` does
/// not.
///
/// Requires `honest = true` AND a completed `fit()`. Length equals
/// `est_indices().length()`, position `j` corresponding to
/// original row `est_indices()[j]` -- NOT to row `j`. On an
/// adaptive fit the same array is computable but is not a valid
/// influence function (the partition was chosen using these same
/// rows), so this accessor refuses rather than pretending.
pub fn DoubleMLPolicyTree::leaf_influence(
  self : DoubleMLPolicyTree,
  leaf : Int,
) -> Array[Double] {
  try {
    require(self.fitted)
    require(self.honest)
    require(leaf >= 0 && leaf < self.leaf_count.length())
    let sig = slice_vector(self.orth_signal, self.est_indices)
    let out : Array[Double] = Array::make(sig.length(), 0.0)
    let nk_d = self.leaf_count[leaf].to_double()
    for j = 0; j < sig.length(); j = j + 1 {
      if self.leaf_assignment[j] == leaf {
        out[j] = (sig[j] - self.leaf_signal_mean[leaf]) / nk_d
      }
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.98.0+: the per-observation Riesz denominator
/// `psi_a[i] = -1 / n_k` for the rows of leaf `leaf` in the
/// estimation half and `0.0` elsewhere -- i.e. `leaf_influence`
/// with its residual divisor pulled out, in exactly the shape
/// `sensitivity_analysis` feeds to `irm_style_sensitivity`.
///
/// The default (`honest = false`) path passes the CONSTANT `-1.0`
/// for its own rows instead, and that is what it still passes:
/// `sensitivity_analysis`'s v0.69.0-v0.97.0 numbers are pinned
/// and unchanged. `-1` is the per-LEAF derivative `f_k'` scaled up
/// by `n_k`; `-1/n_k` is the per-OBSERVATION derivative `f_i'`,
/// which is the honest one. Both are legitimate inputs to the
/// Cinelli-Hazlett decomposition -- it consumes `psi_a` only
/// through `psi_a^2`, so the sign is immaterial and the magnitude
/// sets the variance scale -- but only the honest path's numbers
/// describe an estimator whose partition is independent of the
/// rows it is computed from.
pub fn DoubleMLPolicyTree::leaf_psi_a(
  self : DoubleMLPolicyTree,
  leaf : Int,
) -> Array[Double] {
  try {
    require(self.fitted)
    require(self.honest)
    require(leaf >= 0 && leaf < self.leaf_count.length())
    let out : Array[Double] = Array::make(self.leaf_assignment.length(), 0.0)
    let psi = -1.0 / self.leaf_count[leaf].to_double()
    for j = 0; j < self.leaf_assignment.length(); j = j + 1 {
      if self.leaf_assignment[j] == leaf {
        out[j] = psi
      }
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.69.0+: per-leaf sensitivity analysis for `DoubleMLPolicyTree`.
///
/// PolicyTree is a deterministic policy learner: each
/// row is predicted with the leaf treatment emitted by
/// `policy_tree_predict`. The IRM-style per-leaf
/// decomposition treats the leaf mean of `orth_signal`
/// as the nuisance-persistence anchor
/// (`leaf_signal_mean`), the per-leaf outcome residual
/// as `orth_signal[i] - leaf_signal_mean[leaf(i)]`,
/// the per-leaf Riesz-representer row as `psi_a = -1`
/// (the constant IRM-style treatment-effect IF), and
/// the per-leaf coefficient as `leaf_signal_mean[l]`.
///
/// Returns an `Array[SensitivityResult]` in the same
/// DFS order as `policy_tree_walk_leaves` /
/// `leaf_signal_mean` / `leaf_count`. Leaves with
/// `leaf_count == 0` (impossible in the current
/// build since the build loop only creates leaves
/// containing at least one row) get a zeroed
/// `SensitivityResult`. `cf_y` / `cf_d` default to `0.05`
/// matching the v0.66.0+ sensitivity family.
///
/// v0.98.0+ -- BEHAVIOUR CHANGE UNDER `honest = true`, AND
/// NOTHING CHANGES WITHOUT IT. This method BECAME HONESTY-AWARE,
/// and the honest numbers DIFFER from the v0.97.0 numbers in two
/// deliberate ways. On the DEFAULT path (`honest = false`,
/// the v0.97.0 behaviour) the decomposition still runs over all
/// `n_obs` rows in identity order with `psi_a = -1`, and every
/// returned number is byte-identical to v0.69.0-v0.97.0; that is
/// pinned in `expand_v098_test.mbt`. On the HONEST path it
/// instead:
///
///   - runs over the ESTIMATION half only, so
///     `n_rows == leaf_assignment.length() == ceil(n_obs / 2)`
///     rather than `n_obs`, with position `j` describing original
///     row `est_indices()[j]`; and
///   - passes `psi_a = -1 / n_l`, the true per-observation
///     derivative of the leaf-mean estimating function (derived
///     in full on `leaf_influence`), rather than the constant
///     `-1`.
///
/// Both changes are forced by honesty rather than cosmetic: the
/// split half is not in `leaf_signal_mean`, so including it would
/// contaminate every leaf's residual, and `-1` is `n_l` times the
/// derivative that actually describes an honest leaf mean.
/// Because `irm_style_sensitivity` consumes `psi_a` through
/// `psi_a^2` only, the sign flip is immaterial but `nu2` scales by
/// `1 / n_l^2` and the reported `rv` / `max_bias` move
/// accordingly. Callers that want the old numbers must leave
/// `honest` at its default.
///
/// Calling on an un-fit model aborts via
/// `PreconditionError`.
pub fn DoubleMLPolicyTree::sensitivity_analysis(
  self : DoubleMLPolicyTree,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> Array[SensitivityResult] raise {
  require(self.fitted)
  // v0.98.0+: WHICH ROWS, and WHICH psi_a. See the docstring for
  // why this is a deliberate behaviour change under honesty and a
  // no-op without it.
  //
  // Default path: `sig` IS `self.orth_signal` (same array object)
  // and `n_rows == n_obs`, so `vector_subtract` sees exactly the
  // operands it saw in v0.97.0 and the buckets below are filled
  // in the same increasing-`i` order -- the results are
  // byte-identical, not merely close.
  let sig : Array[Double] = if self.honest {
    slice_vector(self.orth_signal, self.est_indices)
  } else {
    self.orth_signal
  }
  // `leaf_assignment.length()` is `n_obs` on the default path and
  // `n_est` under honesty, so one expression serves both.
  let n_rows = self.leaf_assignment.length()
  let n_leaves = self.leaf_signal_mean.length()
  let zero_result : SensitivityResult = {
    rv: 0.0,
    sigma2: 0.0,
    nu2: 0.0,
    cf_y: 0.0,
    cf_d: 0.0,
    max_bias: 0.0,
  }
  let out : Array[SensitivityResult] = Array::make(n_leaves, zero_result)
  // v0.85.0+: vectorise the per-observation residual. The residual
  // is `orth_signal[i] - leaf_signal_mean[leaf(i)]`, so gathering
  // the per-row leaf mean once and calling `vector_subtract` a
  // single time replaces the per-leaf scalar subtract. Values are
  // bit-identical to the old inline expression. Rows are still
  // bucketed per leaf in increasing `i` order, so the residual
  // array handed to `irm_style_sensitivity` has the same layout
  // as before.
  let leaf_mean_per_row : Array[Double] = Array::make(n_rows, 0.0)
  for i = 0; i < n_rows; i = i + 1 {
    leaf_mean_per_row[i] = self.leaf_signal_mean[self.leaf_assignment[i]]
  }
  let residuals_all : Array[Double] = vector_subtract(sig, leaf_mean_per_row)
  let residual_fill : Array[Int] = Array::make(n_leaves, 0)
  // Bucket residuals and psi_a per leaf, then call
  // `irm_style_sensitivity` once per leaf.
  for l = 0; l < n_leaves; l = l + 1 {
    let n_in_leaf = self.leaf_count[l]
    if n_in_leaf == 0 {
      continue
    }
    // v0.98.0+: `-1` on the default path (pinned, unchanged),
    // `-1 / n_l` under honesty -- the true per-observation
    // derivative `f_i'(theta)` of `f_l(theta) = (1/n_l) sum
    // (y_i - theta)`; derivation on `leaf_influence`.
    let psi_value : Double = if self.honest {
      -1.0 / n_in_leaf.to_double()
    } else {
      -1.0
    }
    let residuals : Array[Double] = Array::make(n_in_leaf, 0.0)
    let psi_a : Array[Double] = Array::make(n_in_leaf, psi_value)
    for i = 0; i < n_rows; i = i + 1 {
      if self.leaf_assignment[i] == l {
        residuals[residual_fill[l]] = residuals_all[i]
        residual_fill[l] = residual_fill[l] + 1
      }
    }
    out[l] = irm_style_sensitivity(
      self.leaf_signal_mean[l],
      residuals,
      psi_a,
      cf_y,
      cf_d,
    )
  }
  out
}
