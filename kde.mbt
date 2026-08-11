///|
/// Silverman's rule of for-band for a Gaussian KDE: given samples
/// `y[0..n)`,`h = 0.9 * min(sd(y), IQR/1.34) * n^(-1/5)`. The
/// `min(sd, IQR/1.34)` factor is robust to outliers (a sample of
/// `N(0, 1)` typically has `IQR/1.34 ≈ sd`; heavy-tailed samples get
/// the smaller IQR, which prevents oversmoothing).
///
/// For samples drawn from a single-mode distribution the bandwidth
/// is asymptotically optimal; for multimodal or heavy-tailed data the
/// user should switch to a plug-in estimator (cross-validated or
/// Sheather-Jones) — but the simpler Silverman rule is fine for the
/// LPQ numerical-derivative use case where `y` is typically uniform-
/// shaped or mildly bimodal.
pub fn silverman_bandwidth(y : Array[Double]) -> Double {
  let n = y.length()
  require(n >= 2)
  let sd = sample_sd(y)
  let iqr_over_134 = iqr(y) / 1.34
  let spread = if sd < iqr_over_134 { sd } else { iqr_over_134 }
  let n_d = n.to_double()
  0.9 * spread * @math.pow(n_d, -0.2)
}

///|
/// Standard sample standard deviation `sqrt(sum((y - mean)^2) / (n - 1))`.
/// Empty or single-element input returns 0.0.
fn sample_sd(y : Array[Double]) -> Double {
  let n = y.length()
  if n < 2 {
    return 0.0
  }
  let m = mean(y)
  let mut acc = 0.0
  for i = 0; i < n; i = i + 1 {
    let d = y[i] - m
    acc = acc + d * d
  }
  (acc / (n.to_double() - 1.0)).sqrt()
}

///|
/// Interquartile range `Q3 - Q1`. Uses linear interpolation on the
/// sorted sample (matching `numpy.percentile(..., interpolation='linear')`).
/// Empty input returns 0.0.
fn iqr(y : Array[Double]) -> Double {
  let n = y.length()
  if n == 0 {
    return 0.0
  }
  let sorted : Array[Double] = y.copy()
  sorted.sort()
  let q1 = percentile_sorted(sorted, 25.0)
  let q3 = percentile_sorted(sorted, 75.0)
  q3 - q1
}

///|
/// Linear-interpolation percentile on a pre-sorted array. `p` is in
/// `[0, 100]`. `n == 0` returns 0.0.
fn percentile_sorted(sorted : Array[Double], p : Double) -> Double {
  let n = sorted.length()
  if n == 0 {
    return 0.0
  }
  if n == 1 {
    return sorted[0]
  }
  let rank = p / 100.0 * (n.to_double() - 1.0)
  let lo = rank.floor().to_int()
  let hi = if lo + 1 < n { lo + 1 } else { lo }
  let frac = rank - lo.to_double()
  sorted[lo] * (1.0 - frac) + sorted[hi] * frac
}

///|
/// Gaussian KDE density estimate at `x`, evaluated using samples
/// `y[0..n)` and bandwidth `h`:
///
///     f_hat(x) = (1 / (n * h * sqrt(2*pi))) * sum_i exp(-(x - y_i)^2 / (2 * h^2))
///
/// Returns a non-negative density. The constant `sqrt(2 * pi) =
/// 1.7724538509055159` is the standard Gaussian normalisation factor.
pub fn gaussian_kde(y : Array[Double], x : Double, h : Double) -> Double {
  let n = y.length()
  require(n >= 1)
  require(h > 0.0)
  let inv_h = 1.0 / h
  let inv_norm = inv_h / 2.5066282746310002 // 1 / (h * sqrt(2*pi))
  let mut acc = 0.0
  for i = 0; i < n; i = i + 1 {
    let z = (x - y[i]) * inv_h
    acc = acc + @math.exp(-0.5 * z * z)
  }
  acc * inv_norm / n.to_double()
}

///|
/// Weighted Gaussian KDE density estimate at `x`, evaluated using
/// samples `y[0..n)` with per-sample weights `w[0..n)` and bandwidth
/// `h`:
///
///     f_hat(x) = (1 / (h * sqrt(2*pi))) * sum_i w[i] * exp(-(x - y[i])^2 / (2*h^2))
///
/// Note: the weights enter *without* a `/ sum(w)` normalisation, so
/// this is a weighted KDE estimate (not a probability density unless
/// `sum(w) == 1`). Used by `DoubleMLLPQ::fit` to compute the
/// numerical derivative of `mean(psi(theta))` w.r.t. `theta`:
///
///     d/dtheta mean(psi_ipw) = (1/n) * sum_i w_i * delta(y_i - theta)
///                            ≈ (1/n) * f_hat_weighted(theta)
///
/// where `w_i = sign * (z_i/m_i - (1-z_i)/(1-m_i)) * treated_i / comp`
/// is the IPW coefficient. The derivative feeds directly into the
/// delta-method variance `se = sqrt(gamma / (deriv^2 * n))`.
pub fn gaussian_kde_weighted(
  y : Array[Double],
  w : Array[Double],
  x : Double,
  h : Double,
) -> Double {
  let n = y.length()
  require(n >= 1)
  require(y.length() == w.length())
  require(h > 0.0)
  let inv_h = 1.0 / h
  let inv_norm = inv_h / 2.5066282746310002 // 1 / (h * sqrt(2*pi))
  let mut acc = 0.0
  for i = 0; i < n; i = i + 1 {
    let z = (x - y[i]) * inv_h
    acc = acc + w[i] * @math.exp(-0.5 * z * z)
  }
  acc * inv_norm
}