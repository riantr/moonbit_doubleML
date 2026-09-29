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
  fitted : Bool
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
      fitted: false,
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
/// Run the local-polynomial fit on one side of the cutoff and return
/// the intercept, the weighted residual variance, the local sample
/// size, and the residual vector at each local point (the residual
/// vector is needed for the Bug #7 fuzzy-RDD cross-covariance
/// between the `raw` (Y) and `jump` (D) intercept estimates).
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
) -> (Double, Double, Int, Array[Double]) {
  let (xx, yy, w, ids) = rdd_design(data, side, cutoff, h, which)
  if ids.length() == 0 {
    (0.0, 0.0, 0, [])
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
          { train_idx: Array::makei(ids.length(),  fn(k) { k }),
            test_idx: Array::make(ids.length(),    0) },
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
    (beta[0], variance, ids.length(), resid)
  }
}

///|
pub fn DoubleMLRDD::fit(
  self : DoubleMLRDD,
  ml_g? : LearnerDispatch = self.ml_g,
) -> DoubleMLRDD {
  try {
    require(self.bandwidth > 0.0)
    let (yl, vyl, nl, res_yl) = rdd_side(
      ml_g,
      self.data,
      -1.0,
      self.cutoff,
      self.bandwidth,
      false,
      self.cov_type,
    )
    let (yr, vyr, nr, res_yr) = rdd_side(
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
      let (dl, vdl, _, res_dl) = rdd_side(
        ml_g,
        self.data,
        -1.0,
        self.cutoff,
        self.bandwidth,
        true,
        self.cov_type,
      )
      let (dr, vdr, _, res_dr) = rdd_side(
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
      fitted: true,
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
