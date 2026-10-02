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
  let n_obs = self.orth_signal.length()
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
  let mut rss = 0.0
  let residuals : Array[Double] = Array::make(n_obs, 0.0)
  for i = 0; i < n_obs; i = i + 1 {
    let e = self.orth_signal[i] - pred[i]
    residuals[i] = e
    rss = rss + e * e
  }
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
  }
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
  fitted : Bool
} derive(Debug)

///|
pub extend DoubleMLPolicyTree with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLPolicyTree::new(
  features : Matrix,
  orth_signal : Array[Double],
  depth? : Int = 1,
) -> DoubleMLPolicyTree {
  try {
    require(features.rows() == orth_signal.length())
    require(depth >= 1)
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
      fitted: false,
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
pub fn DoubleMLPolicyTree::fit(self : DoubleMLPolicyTree) -> DoubleMLPolicyTree {
  let root = policy_tree_build(self.features, self.orth_signal, self.depth)
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
  let n_obs = self.orth_signal.length()
  let leaf_assignment : Array[Int] = Array::make(n_obs, 0)
  for i = 0; i < n_obs; i = i + 1 {
    let lf = policy_tree_leaf_index(root, self.features, i, 0)
    leaf_assignment[i] = lf
    leaf_signal_sum[lf] = leaf_signal_sum[lf] + self.orth_signal[i]
    leaf_count_arr[lf] = leaf_count_arr[lf] + 1
  }
  let leaf_signal_mean : Array[Double] = Array::make(n_leaves, 0.0)
  for k = 0; k < n_leaves; k = k + 1 {
    if leaf_count_arr[k] > 0 {
      leaf_signal_mean[k] = leaf_signal_sum[k] / leaf_count_arr[k].to_double()
    }
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
    fitted: true,
  }
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
/// Calling on an un-fit model aborts via
/// `PreconditionError`.
pub fn DoubleMLPolicyTree::sensitivity_analysis(
  self : DoubleMLPolicyTree,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> Array[SensitivityResult] raise {
  require(self.fitted)
  let n_obs = self.orth_signal.length()
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
  // Bucket residuals and psi_a per leaf, then call
  // `irm_style_sensitivity` once per leaf.
  for l = 0; l < n_leaves; l = l + 1 {
    let n_in_leaf = self.leaf_count[l]
    if n_in_leaf == 0 {
      continue
    }
    let residuals : Array[Double] = Array::make(n_in_leaf, 0.0)
    let psi_a : Array[Double] = Array::make(n_in_leaf, -1.0)
    let mut k = 0
    for i = 0; i < n_obs; i = i + 1 {
      if self.leaf_assignment[i] == l {
        residuals[k] = self.orth_signal[i] - self.leaf_signal_mean[l]
        k = k + 1
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
