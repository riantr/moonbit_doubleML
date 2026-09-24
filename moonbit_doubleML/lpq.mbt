///|
pub struct DoubleMLLPQData {
  x : Matrix
  y : Array[Double]
  d : Array[Double]
  z : Array[Double]
} derive(Debug)

///|
pub fn DoubleMLLPQData::new(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  z : Array[Double],
) -> DoubleMLLPQData {
  try {
    require(x.rows() == y.length())
    require(x.rows() == d.length())
    require(x.rows() == z.length())
    { x, y, d, z, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Compute the LPQ score. Bug #4 fix: the upstream `doubleml.irm.lpq`
/// reference uses `sign = 2 * treatment - 1` to flip the score sign
/// depending on which treatment level is the "treated" level (so that
/// the bisection can find a `theta` that brackets the complier
/// quantile regardless of which level is being scored).
fn lpq_score(
  data : DoubleMLLPQData,
  treated : Array[Double],
  m : Array[Double],
  g0 : Array[Double],
  g1 : Array[Double],
  comp : Double,
  theta : Double,
  q : Double,
  sign : Double,
) -> Array[Double] {
  let out = Array::make(data.y.length(), 0.0)
  for i = 0; i < out.length(); i = i + 1 {
    let iy = if data.y[i] <= theta { 1.0 } else { 0.0 }
    let a = g1[i] -
      g0[i] +
      data.z[i] / m[i] * (treated[i] * iy - g1[i]) -
      (1.0 - data.z[i]) / (1.0 - m[i]) * (treated[i] * iy - g0[i])
    out[i] = sign * a / comp - q
  }
  out
}

///|
/// IPW-only LPQ score (no g0/g1 cross-fit). Used as the bisection
/// objective in `DoubleMLLPQ::fit` (Bug #3 fix). Matches the
/// upstream `doubleml.irm.lpq.DoubleMLLPQ._compute_ipw_score`:
///   `score[i] = sign * (z[i] / m[i] - (1 - z[i]) / (1 - m[i]))
///               * treated[i] * (y[i] <= theta ? 1 : 0) / comp - q`
/// The bisection does not need g0/g1, so this avoids the
/// `2 * 50 = 100` g cross-fits that the pre-fix code did.
pub fn lpq_score_ipw(
  data : DoubleMLLPQData,
  treated : Array[Double],
  m : Array[Double],
  comp : Double,
  theta : Double,
  q : Double,
  sign : Double,
) -> Array[Double] {
  let out = Array::make(data.y.length(), 0.0)
  for i = 0; i < out.length(); i = i + 1 {
    let iy = if data.y[i] <= theta { 1.0 } else { 0.0 }
    let w = sign *
      (data.z[i] / m[i] - (1.0 - data.z[i]) / (1.0 - m[i])) *
      treated[i] *
      iy /
      comp -
      q
    out[i] = w
  }
  out
}

///|
pub struct DoubleMLLPQ {
  data : DoubleMLLPQData
  treatment : Double
  quantile : Double
  n_folds : Int
  seed : Int
  propensity_clip : Double
  coef : Double
  se : Double
  fitted : Bool
  // Cross-fitted nuisance predictions stored post-fit. Length
  // `n_obs`. v0.53.0-dev Task 2: predictions() accessors mirror
  // the upstream DoubleMLLPQ `predictions["g0"/"g1"/"m"]` API.
  predictions_g0 : Array[Double]
  predictions_g1 : Array[Double]
  predictions_m : Array[Double]
} derive(Debug)

///|
pub fn DoubleMLLPQ::new(
  data : DoubleMLLPQData,
  treatment? : Double = 1.0,
  quantile? : Double = 0.5,
  n_folds? : Int = 2,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
) -> DoubleMLLPQ {
  try {
    require(n_folds >= 2)
    require(seed >= 0)
    require(quantile > 0.0 && quantile < 1.0)
    require(propensity_clip > 0.0)
    {
      data,
      treatment,
      quantile,
      n_folds,
      seed,
      propensity_clip,
      coef: 0.0,
      se: 0.0,
      fitted: false,
      predictions_g0: Array::make(data.y.length(), 0.0),
      predictions_g1: Array::make(data.y.length(), 0.0),
      predictions_m: Array::make(data.y.length(), 0.0),
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLLPQ::fit(self : DoubleMLLPQ) -> DoubleMLLPQ {
  try {
    let n = self.data.y.length()
    require(n >= self.n_folds) // kfold precondition: `n_folds <= n_obs`
    let nf = n.to_double()
    let tr = indicator_level(self.data.d, self.treatment)
    let folds = kfold(n, self.n_folds, self.seed)
    let m = fit_propensity(self.data.x, self.data.z, folds, self.propensity_clip)
    let z0 = Array::make(n, 0.0)
    let z1 = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      z0[i] = if self.data.z[i] == 0.0 { 1.0 } else { 0.0 }
      z1[i] = self.data.z[i]
    }
    // Bug #4 fix: complier prob is the full-sample
    // `E[D | Z=1] - E[D | Z=0]`, NOT the per-fold mean difference
    // averaged over folds (which dilutes the estimate). The upstream
    // `doubleml.irm.lpq.LPQScore` uses the full-sample
    // `comp_prob = E[D | Z=1] - E[D | Z=0]` once, irrespective of the
    // cross-fit partition.
    let idz1 = filter_indices(range_indices(n), z1)
    let idz0 = filter_indices(range_indices(n), z0)
    let mut comp = 0.0
    if idz1.length() > 0 && idz0.length() > 0 {
      let r1 = mean(slice_vector(self.data.d, idz1))
      let r0 = mean(slice_vector(self.data.d, idz0))
      comp = r1 - r0
    }
    if comp.abs() < self.propensity_clip {
      comp = self.propensity_clip
    }
    // `sign = 2 * treatment - 1` flips the score sign so that the
    // bisection brackets the complier quantile regardless of which
    // treatment level is being scored. Bug #4 fix: previously missing.
    let sign = 2.0 * self.treatment - 1.0
    // Bug #3 fix: use the IPW score for the bisection, then
    // cross-fit g0, g1 ONCE at the preliminary theta (plus
    // 4 more cross-fits for the numerical derivative). This
    // drops the total g cross-fit count from `2 * 50 = 100`
    // (bisection) + 4 (derivative) = 104 to 2 + 4 = 6.
    let y_min = array_min(self.data.y) catch {
      EmptyArrayError => abort("array_min: empty y array (data.y.length() == 0)")
    }
    let y_max = array_max(self.data.y) catch {
      EmptyArrayError => abort("array_max: empty y array (data.y.length() == 0)")
    }
    let y_range = y_max - y_min
    let margin = if y_range > 0.0 { y_range * 0.1 } else { 1.0 }
    let mut lo = y_min - margin
    let mut hi = y_max + margin
    for _iter = 0; _iter < 60; _iter = _iter + 1 {
      let mid = (lo + hi) / 2.0
      let s = mean(
        lpq_score_ipw(self.data, tr, m, comp, mid, self.quantile, sign),
      )
      if s < 0.0 {
        lo = mid
      } else {
        hi = mid
      }
    }
    let theta = (lo + hi) / 2.0
    // Cross-fit g0, g1 ONCE at theta (replaces the per-iteration
    // g cross-fit from the pre-fix code).
    let iy = outcome_indicator(self.data.y, theta)
    let g0 = cross_fit_conditional(self.data.x, iy, z0, folds)
    let g1 = cross_fit_conditional(self.data.x, iy, z1, folds)
    let psi = lpq_score(
      self.data,
      tr,
      m,
      g0,
      g1,
      comp,
      theta,
      self.quantile,
      sign,
    )
    // Numerical derivative via KDE-weighted evaluation at `theta`.
    // TODO 0.6.0: replace the finite-difference `2 * n_folds = 4` extra
    // cross-fits with a single weighted-KDE evaluation of the IPW
    // coefficient at `theta`. The IPW score's `theta`-derivative is
    //   `d/dtheta mean(psi_ipw) = (1/n) * sum_i w_i * delta(y_i - theta)`
    // which we smooth by replacing the Dirac with a Gaussian KDE
    // `K_h((theta - y_i) / h) / h`. The Silverman bandwidth is
    // sample-size-aware so the KDE is consistent at the canonical DGP
    // scale (continuous `y`) and does not collapse to zero at discrete
    // `y` like the previous finite-difference did.
    //
    // Bandwidth selection: Silverman's rule on `y` directly (rather than
    // the previous `min(1% y_range, 1/sqrt(n))` heuristic). For the
    // canonical DGPs the new bandwidth is comparable to the old heuristic
    // (typically a few percent of `y_range`); for discrete `y` it
    // adapts to the local cell width automatically.
    let w_kde : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      let z_i = self.data.z[i]
      let m_i = m[i]
      let comp_safe = if comp.abs() < 1.0e-12 { 1.0e-12 } else { comp }
      w_kde[i] = sign *
        (z_i / m_i - (1.0 - z_i) / (1.0 - m_i)) *
        tr[i] /
        comp_safe
    }
    let h_kde = silverman_bandwidth(self.data.y)
    let f_theta = gaussian_kde_weighted(self.data.y, w_kde, theta, h_kde)
    // `deriv = d/dtheta mean(psi_ipw) ≈ f_theta / n` (because the
    // IPW score's `psi_a` is the constant `-1`, so the derivative
    // contribution from `psi_a` is zero and only the `psi_b` part
    // contributes; the `(1/n)` factor above accounts for the mean
    // rather than the sum).
    let deriv = f_theta / nf
    // REVIEW L11 fix (0.7.0): use the shared `var_est_with_jacobian`
    // helper instead of inlining `sum(psi^2) / n / (deriv^2 * n)`.
    // The math is byte-equal; the helper gives a Kahan-compensated
    // accumulator and the test contract is the same.
    let se = var_est_with_jacobian(psi, deriv)
    {
      data: self.data,
      treatment: self.treatment,
      quantile: self.quantile,
      n_folds: self.n_folds,
      seed: self.seed,
      propensity_clip: self.propensity_clip,
      coef: theta,
      se,
      fitted: true,
      predictions_g0: g0,
      predictions_g1: g1,
      predictions_m: m,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Number of observations.
pub fn DoubleMLLPQ::n_obs(self : DoubleMLLPQ) -> Int {
  self.data.x.rows()
}

///|
/// Number of features (covariate columns).
pub fn DoubleMLLPQ::n_features(self : DoubleMLLPQ) -> Int {
  self.data.x.cols()
}

///|
/// 95% Wald confidence interval (z = 1.959963984540054). Matches the
/// `DoubleMLLPLR::confint` idiom byte-for-byte.
pub fn DoubleMLLPQ::confint(self : DoubleMLLPQ) -> (Double, Double) {
  try {
    require(self.fitted)
    let z = 1.959963984540054
    (self.coef - z * self.se, self.coef + z * self.se)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLLPQ::coef(self : DoubleMLLPQ) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLLPQ::se(self : DoubleMLLPQ) -> Double {
  try {
    require(self.fitted)
    self.se
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Cross-fitted outcome nuisance for Z=0 (length `n_obs`).
/// v0.53.0-dev: matches upstream `DoubleMLLPQ.predictions["g0"]`.
pub fn DoubleMLLPQ::predictions_g0(
  self : DoubleMLLPQ,
) -> Array[Double] {
  try {
    require(self.fitted)
    self.predictions_g0
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Cross-fitted outcome nuisance for Z=1 (length `n_obs`).
/// v0.53.0-dev: matches upstream `DoubleMLLPQ.predictions["g1"]`.
pub fn DoubleMLLPQ::predictions_g1(
  self : DoubleMLLPQ,
) -> Array[Double] {
  try {
    require(self.fitted)
    self.predictions_g1
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Cross-fitted treatment nuisance (propensity score, length `n_obs`).
/// v0.53.0-dev: matches upstream `DoubleMLLPQ.predictions["m"]`.
pub fn DoubleMLLPQ::predictions_m(self : DoubleMLLPQ) -> Array[Double] {
  try {
    require(self.fitted)
    self.predictions_m
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
