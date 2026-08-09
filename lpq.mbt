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
  require(x.rows() == y.length())
  require(x.rows() == d.length())
  require(x.rows() == z.length())
  { x, y, d, z }
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
  }
}

///|
pub fn DoubleMLLPQ::fit(self : DoubleMLLPQ) -> DoubleMLLPQ {
  let n = self.data.y.length()
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
  let y_min = array_min(self.data.y)
  let y_max = array_max(self.data.y)
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
  // Numerical derivative via 4 more cross-fits at theta +/- h.
  // TODO #11c.4: adaptive finite-difference step. The previous
  // constant `1% of y_range` is too coarse when y is discrete
  // (the indicator `1{y <= theta}` is a step function with jump
  // at the median, so a 1% step may land on the same y-cell as
  // theta and the derivative collapses to zero). The Silverman-style
  // `1/sqrt(n)` heuristic gives a sample-size-aware step that is
  // robust across both continuous and discrete y. We take the
  // smaller of the two: on continuous y (large range) the 1% step
  // wins; on discrete y (small range) the 1/sqrt(n) step wins.
  // We use `min` here (not `max`) to keep the step small on the
  // canonical continuous DGPs, which is where the previous 1% step
  // already worked well.
  let y_range = y_max - y_min
  let h_continuous = y_range * 1.0e-2 + 1.0e-8
  let h_sample = 1.0 / nf.sqrt()
  let h = if h_continuous < h_sample { h_continuous } else { h_sample }
  let iyp = outcome_indicator(self.data.y, theta + h)
  let iym = outcome_indicator(self.data.y, theta - h)
  let gp0 = cross_fit_conditional(self.data.x, iyp, z0, folds)
  let gp1 = cross_fit_conditional(self.data.x, iyp, z1, folds)
  let gm0 = cross_fit_conditional(self.data.x, iym, z0, folds)
  let gm1 = cross_fit_conditional(self.data.x, iym, z1, folds)
  let mean_p = mean(
    lpq_score(self.data, tr, m, gp0, gp1, comp, theta + h, self.quantile, sign),
  )
  let mean_m = mean(
    lpq_score(self.data, tr, m, gm0, gm1, comp, theta - h, self.quantile, sign),
  )
  let deriv = (mean_p - mean_m) / (2.0 * h)
  let mut v = 0.0
  for u in psi {
    v = v + u * u
  }
  let se = (v / nf / (deriv * deriv * nf)).sqrt()
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
  }
}

///|
pub fn DoubleMLLPQ::coef(self : DoubleMLLPQ) -> Double {
  require(self.fitted)
  self.coef
}

///|
pub fn DoubleMLLPQ::se(self : DoubleMLLPQ) -> Double {
  require(self.fitted)
  self.se
}
