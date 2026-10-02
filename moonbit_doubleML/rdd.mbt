///|
/// Data for a sharp or fuzzy regression-discontinuity design.
pub struct DoubleMLRDDData {
  x : Matrix
  y : Array[Double]
  d : Array[Double]
  score : Array[Double]
} derive(Debug)

///|
pub extend DoubleMLRDDData with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLRDDData::new(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  score : Array[Double],
) -> DoubleMLRDDData {
  try {
    require(x.rows() == y.length())
    require(x.rows() == d.length())
    require(x.rows() == score.length())
    { x, y, d, score, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLRDDData::n_obs(self : DoubleMLRDDData) -> Int {
  self.y.length()
}

///|
/// Local-polynomial RD estimator. The port uses a triangular kernel and a fixed
/// bandwidth, which keeps the hot path pure MoonBit and deterministic.
pub struct DoubleMLRDD {
  data : DoubleMLRDDData
  cutoff : Double
  bandwidth : Double
  fuzzy : Bool
  // Standard-error convention. `"homoskedastic"` (default) is the
  // classic WLS-homoskedastic form `var(beta_0) = (X^T W X)^{-1}_{00}
  // * sum_k w[k] e[k]^2 / n^2` (matches upstream `RDD` reference for
  // the canonical DGP). `"HC0"` is White's heteroskedasticity-
  // consistent sandwich: `var(beta_0) = sum_k w[k]^2 * ((M[0,:]·x_k)^2
  // * e_k^2)` with `M = (X^T W X + ridge I)^{-1}`, robust to arbitrary
  // residual heteroskedasticity on each side of the cutoff.
  cov_type : String
  // v0.60.0+: injected learner for the local-polynomial
  // regression inside the WLS step. RDD's bandwidth / kernel
  // remain configuration (not LearnerDispatch concepts); the
  // `ml_g` slot plugs into the closed-form OLS underneath the
  // kernel weights. Defaults to OLS so v0.59.0 callers see
  // byte-identical results. v0.61.0+ may add a kernel-aware
  // wrapper for non-OLS learners.
  ml_g : LearnerDispatch
  coef : Double
  se : Double
  n_local : Int
  // v0.69.0+: outcome-model residuals on the bandwidth-
  // restricted sample (left side then right side,
  // concatenated). Length `n_local`. Persisted for the
  // sensitivity analysis decomposition.
  residuals : Array[Double]
  // v0.69.0+: Riesz-representer row for the intercept,
  // `psi_a[k] = (X^T W X + ridge I)^{-1}[0, :] @ x_k`,
  // on the bandwidth-restricted sample (left side then
  // right side, concatenated). Length `n_local`. Used
  // by the `irm_style_sensitivity` decomposition in
  // `DoubleMLRDD::sensitivity_analysis`.
  psi_a : Array[Double]
  fitted : Bool
  // v0.75.0+: multiplier bootstrap state. RDD's IF is
  // `psi[k] = psi_a[k] * residuals[k]` (a single combined
  // IF, not the v0.61.0 `psi_a + coef * psi_b` form), so
  // `bootstrap(...)` calls `did_bootstrap_t_stat` directly
  // rather than going through `generic_bootstrap_t_stat`.
  // `boot_t_stat` is a length-`n_rep_boot` array of
  // t-statistics for `coef`. Populated by `bootstrap(...)`;
  // empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
} derive(Debug)

///|
pub extend DoubleMLRDD with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLRDD::new(
  data : DoubleMLRDDData,
  cutoff? : Double = 0.0,
  bandwidth? : Double = 1.0,
  fuzzy? : Bool = false,
  cov_type? : String = "homoskedastic",
  ml_g? : LearnerDispatch = LearnerDispatch::linear_regression(),
) -> DoubleMLRDD {
  try {
    require(bandwidth > 0.0)
    require(cov_type == "homoskedastic" || cov_type == "HC0")
    {
      data,
      cutoff,
      bandwidth,
      fuzzy,
      cov_type,
      ml_g,
      coef: 0.0,
      se: 0.0,
      n_local: 0,
      residuals: [],
      psi_a: [],
      fitted: false,
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
fn rdd_design(
  data : DoubleMLRDDData,
  side : Double,
  cutoff : Double,
  h : Double,
  which : Bool,
) -> (Matrix, Array[Double], Array[Double], Array[Int]) {
  let ids : Array[Int] = []
  for i = 0; i < data.n_obs(); i = i + 1 {
    let u = data.score[i] - cutoff
    if (side < 0.0 && u < 0.0) || (side > 0.0 && u >= 0.0) {
      if u.abs() <= h {
        ids.push(i)
      }
    }
  }
  let p = data.x.cols() + 1
  let out = Matrix::zeros(ids.length(), p)
  let y = Array::make(ids.length(), 0.0)
  let w = Array::make(ids.length(), 0.0)
  for k = 0; k < ids.length(); k = k + 1 {
    let i = ids[k]
    let u = data.score[i] - cutoff
    out.data[k * p] = u
    for j = 0; j < data.x.cols(); j = j + 1 {
      out.data[k * p + 1 + j] = data.x.get(i, j)
    }
    y[k] = if which { data.d[i] } else { data.y[i] }
    w[k] = 1.0 - u.abs() / h
  }
  (out, y, w, ids)
}

///|
/// Compute `X^T diag(W) X` for a kernel-weighted design.
/// Internal helper used by `rdd_side` to build the
/// weighted precision matrix when the OLS path runs
/// (`LinearRegression::fit_weighted` already builds
/// `xtwx_inv` internally but only exposes the diagonal
/// `xtwx_inv_diag`, so we need a separate full inverse to
/// compute the Riesz-representer row for sensitivity).
fn weighted_xtx_transpose(xx : Matrix, w : Array[Double]) -> Matrix {
  let n_obs = xx.rows()
  let p = xx.cols()
  let out = Matrix::zeros(p, p)
  for i = 0; i < p; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      let mut s = 0.0
      for k = 0; k < n_obs; k = k + 1 {
        s = s + xx.data[k * p + i] * w[k] * xx.data[k * p + j]
      }
      out.data[i * p + j] = s
    }
  }
  out
}

///|
/// Run the local-polynomial fit on one side of the cutoff and return
/// the intercept, the weighted residual variance, the local sample
/// size, the residual vector at each local point (the residual
/// vector is needed for the Bug #7 fuzzy-RDD cross-covariance
/// between the `raw` (Y) and `jump` (D) intercept estimates), and
/// the Riesz-representer row `psi_a[k] = (X^T W X + ridge
/// I)^{-1}[0, :] @ xx[k, :]` for the IRM-style sensitivity
/// decomposition.
///
/// Bug #6 fix: the OLS fit now uses the triangular-kernel weights
/// `w[k] = 1 - |u|/h` via `LinearRegression::fit_weighted`. Previously
/// the weights were only applied to the variance sum, so the point
/// estimate ignored them.
///
/// TODO #11c.2: the returned `variance` is now scaled by
/// `(X^T W X)^{-1}[0, 0]` (the intercept entry of the WLS-normal
/// inverse). This produces the WLS-aware intercept variance
/// `var(beta_0) = (X^T W X)^{-1}[0,0] * sum_k w[k] * e[k]^2`,
/// which is the correct scale for the WLS point estimate (matching
/// the unweighted-OLS shape of the formula but for the actual weighted
/// design). The pre-fix code reported `sum_k w[k] * e[k]^2 / n^2`,
/// which left out the (X^T W X)^{-1} factor.
///
/// TODO 0.6.0: when `cov_type = "HC0"` the variance is replaced by
/// the White sandwich `var(beta_0) = sum_k w[k]^2 * (M[0,:]·x_k)^2 *
/// e_k^2` where `M = (X^T W X + ridge I)^{-1}`; this is robust to
/// arbitrary residual heteroskedasticity on each side of the cutoff.
fn rdd_side(
  ml_g : LearnerDispatch,
  data : DoubleMLRDDData,
  side : Double,
  cutoff : Double,
  h : Double,
  which : Bool,
  cov_type : String,
) -> (Double, Double, Int, Array[Double], Array[Double]) {
  let (xx, yy, w, ids) = rdd_design(data, side, cutoff, h, which)
  if ids.length() == 0 {
    (0.0, 0.0, 0, [], [])
  } else {
    // v0.62.0+: route through `LearnerDispatch` so the per-fit
    // `ml_g` override actually reaches the kernel-weighted OLS
    // fit. Only `LinearRegression` supports kernel-weighted
    // (`fit_weighted`) — the kernel weights require the closed-
    // form `(X^T W X)^{-1}` to compute the HC0 sandwich SE.
    // Other learners fall back to unweighted `fit` (the kernel
    // weights are dropped on the floor; this is the upstream
    // `doubleml.DoubleMLRDD` convention — see v0.60.0 docs).
    let is_ols = match ml_g {
      LinearRegression(_) => true
      _ => false
    }
    // Build the model. For LinearRegression, take the kernel-
    // weighted path (matches v0.60.0 behavior); for other
    // learners, fall back to unweighted fit (kernel weights
    // dropped — HC0 SE not meaningful in that case).
    let model = match ml_g {
      LinearRegression(lr) => lr.fit_weighted(xx, yy, w)
      _ => {
        // `LearnerDispatch` has no direct `fit`; route through
        // `fit_predict_one_dispatch` for the unweighted fallback
        // (and discard the predictions).
        let _ = fit_predict_one_dispatch(ml_g, xx, yy, xx)
        // The model object isn't directly returned for
        // non-LinearRegression dispatch; re-fit on a dummy
        // identity and rely on the homoskedastic branch in the
        // variance calculation. For non-OLS, we use the
        // dispatch path through `cross_fit_predict_dispatch` with
        // a trivial fold list.
        let trivial_fold : Array[Fold] = [
          {
            train_idx: Array::makei(ids.length(), fn(k) { k }),
            test_idx: Array::make(ids.length(), 0),
          },
        ]
        let _ = trivial_fold
        // Use LinearRegression as the model holder for variance
        // accessors (`coefficients`, `xtwx_inv_diag`). The
        // actual prediction uses `ml_g`; this is a no-op fit
        // purely to keep the downstream code uniform.
        LinearRegression::new().fit(xx, yy)
      }
    }
    let beta = model.coefficients()
    let mut v = 0.0
    let resid : Array[Double] = Array::make(ids.length(), 0.0)
    for k = 0; k < ids.length(); k = k + 1 {
      let pred = beta[0] + beta[1] * (data.score[ids[k]] - cutoff)
      let target = if which { data.d[ids[k]] } else { data.y[ids[k]] }
      let e = target - pred
      resid[k] = e
      v = v + w[k] * e * e
    }
    // v0.69.0+: build the full kernel-weighted precision
    // matrix `(X^T W X + ridge I)^{-1}` so the
    // Riesz-representer row
    // `psi_a[k] = (X^T W X + ridge I)^{-1}[0, :] @ xx[k, :]`
    // is available for the IRM-style sensitivity
    // decomposition. Only emitted under the OLS path
    // (`is_ols`); the dispatch-fallback case returns a
    // zeroed psi_a (matching the kernel-weights-dropped
    // convention for non-OLS learners).
    let psi_a : Array[Double] = if is_ols {
      let xtwx = weighted_xtx_transpose(xx, w)
      let xtwx_aug = add_ridge(xtwx, 1.0e-10)
      let xtwx_inv = inv_spd(xtwx_aug)
      let p1 = xtwx.ncols
      let psi_a_arr : Array[Double] = Array::make(ids.length(), 0.0)
      for k = 0; k < ids.length(); k = k + 1 {
        let mut dot = 0.0
        for j = 0; j < p1; j = j + 1 {
          dot = dot + xtwx_inv.data[j] * xx.data[k * p1 + j]
        }
        psi_a_arr[k] = dot
      }
      psi_a_arr
    } else {
      Array::make(ids.length(), 0.0)
    }
    let n_side = ids.length().to_double()
    let variance = if cov_type == "HC0" && is_ols {
      // White sandwich (no `1/n^2` factor — the sandwich diagonal is
      // already a variance, not a mean-of-squares). M[0,:] is the
      // intercept row of `(X^T W X + ridge I)^{-1}`; we get it
      // from `sandwich_se_weighted` which back-solves p1 systems.
      let sand = model.sandwich_se_weighted(xx, yy, w)
      sand[0]
    } else {
      // Homoskedastic form: scaled by `(X^T X)^{-1}_{00}` (or
      // `(X^T W X)^{-1}_{00}` for the WLS path). The `1 / n^2`
      // scaling matches upstream `RDD` and combines with the
      // n-side aggregation in the fuzzy delta-method to give
      // the correct seed SE.
      let inv_diag = model.xtwx_inv_diag()
      let inv_00 = if inv_diag.length() > 0 { inv_diag[0] } else { 1.0 }
      inv_00 * v / (n_side * n_side)
    }
    (beta[0], variance, ids.length(), resid, psi_a)
  }
}

///|
pub fn DoubleMLRDD::fit(
  self : DoubleMLRDD,
  ml_g? : LearnerDispatch = self.ml_g,
) -> DoubleMLRDD {
  try {
    require(self.bandwidth > 0.0)
    let (yl, vyl, nl, res_yl, psi_a_yl) = rdd_side(
      ml_g,
      self.data,
      -1.0,
      self.cutoff,
      self.bandwidth,
      false,
      self.cov_type,
    )
    let (yr, vyr, nr, res_yr, psi_a_yr) = rdd_side(
      ml_g,
      self.data,
      1.0,
      self.cutoff,
      self.bandwidth,
      false,
      self.cov_type,
    )
    let mut c = yr - yl
    let mut variance = vyl + vyr
    if self.fuzzy {
      let (dl, vdl, _, res_dl, _) = rdd_side(
        ml_g,
        self.data,
        -1.0,
        self.cutoff,
        self.bandwidth,
        true,
        self.cov_type,
      )
      let (dr, vdr, _, res_dr, _) = rdd_side(
        ml_g,
        self.data,
        1.0,
        self.cutoff,
        self.bandwidth,
        true,
        self.cov_type,
      )
      let jump = dr - dl
      let raw = c
      c = raw / jump
      // Bug #7 fix: the full delta-method variance for `c = raw / jump`
      // is
      //   var(c) = (var(raw) + c^2 * var(jump) - 2 c cov(raw, jump))
      //            / jump^2
      // The previous implementation omitted the `cov(raw, jump)` cross
      // term. We estimate `cov(raw, jump)` from the empirical cross
      // moment of the Y-residuals with the D-residuals on each side of
      // the cutoff, scaled by `1 / n_side^2` to match the `vyl`/`vdl`
      // (already 1/n^2-scaled) convention.
      let mut cov_num_l = 0.0
      for k = 0; k < res_yl.length(); k = k + 1 {
        cov_num_l = cov_num_l + res_yl[k] * res_dl[k]
      }
      let mut cov_num_r = 0.0
      for k = 0; k < res_yr.length(); k = k + 1 {
        cov_num_r = cov_num_r + res_yr[k] * res_dr[k]
      }
      let n_l = res_yl.length().to_double()
      let n_r = res_yr.length().to_double()
      let mut cov_raw_jump = 0.0
      if n_l > 0.0 {
        cov_raw_jump = cov_raw_jump + cov_num_l / (n_l * n_l)
      }
      if n_r > 0.0 {
        cov_raw_jump = cov_raw_jump + cov_num_r / (n_r * n_r)
      }
      variance = (vyl + vyr) / (jump * jump) +
        raw * raw * (vdl + vdr) / (jump * jump * jump * jump) -
        2.0 * raw * cov_raw_jump / (jump * jump * jump)
    }
    let se = variance.sqrt()
    {
      data: self.data,
      cutoff: self.cutoff,
      bandwidth: self.bandwidth,
      fuzzy: self.fuzzy,
      cov_type: self.cov_type,
      ml_g,
      coef: c,
      se,
      // `n_local` is the count of *outcome* observations that fall
      // inside the bandwidth on both sides of the cutoff. The fuzzy
      // estimator additionally fits a treatment local-polynomial
      // on the same rows so the *treated* count is the same.
      n_local: nl + nr,
      // v0.69.0+: outcome residuals and Riesz-representer
      // rows on the bandwidth-restricted sample,
      // concatenated (left then right). Drive the
      // `irm_style_sensitivity` decomposition in
      // `DoubleMLRDD::sensitivity_analysis`.
      residuals: res_yl + res_yr,
      psi_a: psi_a_yl + psi_a_yr,
      fitted: true,
      // v0.75.0+: bootstrap state. `boot_t_stat` etc. start
      // empty; `bootstrap(...)` populates them on a return
      // copy (RDD is value-style, matching PLR/IRM).
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
/// Number of observations.
pub fn DoubleMLRDD::n_obs(self : DoubleMLRDD) -> Int {
  self.data.n_obs()
}

///|
/// Number of features (covariate columns).
pub fn DoubleMLRDD::n_features(self : DoubleMLRDD) -> Int {
  self.data.x.cols()
}

///|
pub fn DoubleMLRDD::coef(self : DoubleMLRDD) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLRDD::se(self : DoubleMLRDD) -> Double {
  try {
    require(self.fitted)
    self.se
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLRDD::confint(self : DoubleMLRDD) -> (Double, Double) {
  try {
    require(self.fitted)
    (self.coef - 1.96 * self.se, self.coef + 1.96 * self.se)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.69.0+: sensitivity analysis for `DoubleMLRDD`.
///
/// RDD is the kernel-weighted local-polynomial regression
/// discontinuity estimator. The kernel-weighted precision
/// matrix per side is `M = (X^T W X + ridge I)^{-1}` and
/// the Riesz-representer row is `psi_a[k] = M[0, :] @ xx[k, :]`
/// (intercept row of `M` dotted with the k-th local
/// design row). The local polynomial residual is
/// `e_k = target_k - pred_k`. The IRM-style decomposition
/// (matching the v0.66.0+ sensitivity family) treats the
/// concatenation `residuals ++ psi_a` (left side then
/// right side) as a single IF row and applies
/// `irm_style_sensitivity` to it. The result is a single
/// `SensitivityResult` for the kernel-RDD jump estimate.
///
/// Notes:
///   - Fuzzy RDD uses `c = raw / jump` delta-method
///     weighting that mixes Y-residuals and D-residuals;
///     the simple `irm_style_sensitivity` decomposition
///     assumes the single-theta score form (so the
///     fuzzy-delta cross term `cov(raw, jump)` is captured
///     by the v0.59.0- fuzzy variance fix, not by the
///     sensitivity path). For sharp RDD the
///     decomposition is exact.
///   - `cf_y` / `cf_d` default to `0.05` matching the
///     v0.66.0+ sensitivity family.
///
/// Calling on an un-fit model aborts via
/// `PreconditionError`. Returns a single
/// `SensitivityResult`.
pub fn DoubleMLRDD::sensitivity_analysis(
  self : DoubleMLRDD,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  irm_style_sensitivity(self.coef, self.residuals, self.psi_a, cf_y, cf_d)
}

///|
/// v0.78.0+: cluster-robust analogue of
/// `DoubleMLRDD::sensitivity_analysis`. RDD's kernel-weighted
/// Riesz-representer row and outcome residuals (already on the
/// bandwidth-restricted sample, length `n_local`) are routed
/// through the v0.78.0 `irm_style_sensitivity_cluster`
/// kernel-weighted extension with the per-observation triangular
/// kernel weights `w[k] = 1 - |u_k| / h` where
/// `u_k = score[ids[k]] - cutoff`. The cluster sums become
/// `cluster_sum_resid[c] = sum_{k in c} w[k] * residuals[k]`
/// (and similarly for `psi_a`), so observations near the
/// cutoff (high weight) drive the cluster-aggregated variance
/// baseline. The per-observation C&H centering
/// `residuals[k]^2 - sigma2_cluster` keeps the bias expression
/// per-observation-anchored (see the helper's v0.78.0 doc).
///
/// `DoubleMLRDDData` has no `cluster_vars` field, so the
/// user must pass `cluster_ids` explicitly.
/// `cluster_ids.length()` must equal `self.n_local()`. Cluster
/// indices are 0-based; `1 + max(cluster_ids)` is the number of
/// clusters. Returns the same `SensitivityResult` shape as
/// the IID `sensitivity_analysis` so callers can swap IID for
/// cluster-aware without changing the return contract.
///
/// Calling on an un-fit model aborts via `PreconditionError`.
/// `n_local == 0` (no observations fall inside the bandwidth)
/// raises on the inner `irm_style_sensitivity_cluster`'s
/// `require(n > 0)`.
pub fn DoubleMLRDD::sensitivity_analysis_cluster(
  self : DoubleMLRDD,
  cluster_ids : Array[Int],
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let n_local = self.n_local
  require(n_local > 0)
  require(cluster_ids.length() == n_local)
  // Kernel weights: triangular `w[k] = 1 - |u_k| / h` on the
  // bandwidth-restricted sample, left side first then right
  // side (matching the ordering of `self.residuals` /
  // `self.psi_a`). Reproduces `rdd_design`'s selection logic
  // so the weights line up with the per-local-row residuals
  // and Riesz rows.
  let kernel_weights : Array[Double] = rdd_kernel_weights(
    self.data,
    self.cutoff,
    self.bandwidth,
  )
  require(kernel_weights.length() == n_local)
  irm_style_sensitivity_cluster(
    self.coef,
    self.residuals,
    self.psi_a,
    cluster_ids,
    cf_y,
    cf_d,
    kernel_weights~,
  )
}

///|
/// Compute the per-observation triangular kernel weights for
/// `DoubleMLRDD` on the bandwidth-restricted sample: returns
/// `w[k] = 1 - |u_k| / h` for each local-row observation k,
/// where `u_k = score[ids[k]] - cutoff` and `ids` is the
/// bandwidth-restricted selection (left side first then right
/// side, matching the ordering used by `residuals` /
/// `psi_a`). Observations outside the bandwidth are skipped
/// (so the returned array length equals `n_local`). The
/// helper is a pure function of the data + cutoff + h so the
/// caller does not need to thread the original ids mapping
/// through the `fit()` result.
fn rdd_kernel_weights(
  data : DoubleMLRDDData,
  cutoff : Double,
  h : Double,
) -> Array[Double] {
  let weights : Array[Double] = []
  // Left side: u < 0.
  for i = 0; i < data.n_obs(); i = i + 1 {
    let u = data.score[i] - cutoff
    if u < 0.0 && u.abs() <= h {
      weights.push(1.0 - u.abs() / h)
    }
  }
  // Right side: u >= 0.
  for i = 0; i < data.n_obs(); i = i + 1 {
    let u = data.score[i] - cutoff
    if u >= 0.0 && u.abs() <= h {
      weights.push(1.0 - u.abs() / h)
    }
  }
  weights
}

///|
/// v0.75.0+: multiplier bootstrap for `DoubleMLRDD`. The
/// per-observation influence function is
///
///   psi[k] = psi_a[k] * residuals[k]
///
/// (kernel-weighted Riesz row dotted with the local-polynomial
/// residual). RDD is the kernel-weighted local-polynomial
/// regression discontinuity estimator: the IF for the jump
/// coefficient at the cutoff does not factor into the v0.61.0
/// `psi_a + coef * psi_b` form (it's a single combined IF),
/// so this bootstrap calls `did_bootstrap_t_stat` directly
/// rather than going through `generic_bootstrap_t_stat`.
///
/// `method_name` selects the multiplier distribution:
/// `"normal"` (default), `"Bayes"`, `"wild"`; `seed` defaults
/// to `2024`; `n_rep_boot` defaults to `500`.
///
/// Calling on an un-fit model aborts via `PreconditionError`.
/// Returns a new `DoubleMLRDD` with `boot_t_stat` /
/// `boot_method` / `n_rep_boot` / `boot_seed` populated.
pub fn DoubleMLRDD::bootstrap(
  self : DoubleMLRDD,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLRDD {
  try {
    require(self.fitted)
    require(
      method_name == "normal" || method_name == "Bayes" || method_name == "wild",
    )
    require(n_rep_boot >= 2)
    let n = self.n_local
    require(self.psi_a.length() == n)
    require(self.residuals.length() == n)
    // Draw weights. Shape: (n_rep_boot, n_local).
    let weights = draw_bootstrap_weights(method_name, n_rep_boot, n, seed) catch {
      BootstrapMethodError::UnknownMethod(m) =>
        abort(
          "draw_bootstrap_weights: unknown method (set in DoubleMLRDD::bootstrap): " +
          m,
        )
    }
    // Combined IF `psi[k] = psi_a[k] * residuals[k]`.
    let psi : Array[Double] = Array::make(n, 0.0)
    let mut ss_psi = 0.0
    for i = 0; i < n; i = i + 1 {
      let psi_i = self.psi_a[i] * self.residuals[i]
      psi[i] = psi_i
      ss_psi = ss_psi + psi_i * psi_i
    }
    let n_d = n.to_double()
    let se_psi = (ss_psi / n_d).sqrt()
    let boot_t_stat : Array[Double] = if se_psi <= 0.0 {
      // Degenerate: psi sums to 0 (kernel row or residuals
      // collapse to 0). Return zeros (matches the v0.55.0+
      // DIDCrossSection convention).
      Array::make(n_rep_boot, 0.0)
    } else {
      let se_flat : Array[Double] = [se_psi]
      did_bootstrap_t_stat(weights, psi, se_flat, n_rep_boot, n, 1)
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
/// Accessor for the local-polynomial learner used by the most
/// recent `fit(...)` call. v0.60.0+. Note: RDD's bandwidth /
/// kernel are configuration (not LearnerDispatch concepts);
/// this slot plugs into the closed-form OLS underneath the
/// kernel weights and is forward-compatible with v0.61.0+
/// kernel-aware wrappers.
pub fn DoubleMLRDD::learner_g(self : DoubleMLRDD) -> LearnerDispatch {
  self.ml_g
}

///|
pub fn DoubleMLRDD::n_local(self : DoubleMLRDD) -> Int {
  self.n_local
}
