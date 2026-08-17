///|
/// Gaussian KDE on a standard-normal sample should give a density
/// estimate close to the true `phi(0) = 1/sqrt(2*pi) �?0.39894` at
/// the origin. We use `n = 1000` samples so the KDE bandwidth is
/// ~0.27 and the bias at 0 is small.
test "gaussian_kde_recovers_normal_density" {
  let n = 1000
  let rng = chacha8_rng(2024)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let theta = 2.0 * 3.141592653589793 * u2
    y[i] = r * @math.cos(theta)
  }
  let h = silverman_bandwidth(y)
  let f0 = gaussian_kde(y, 0.0, h)
  let phi0 = 0.3989422804014327
  // KDE at the origin should be within 15% of phi(0)
  inspect((f0 - phi0).abs() / phi0 < 0.15, content="true")
}

///|
/// `silverman_bandwidth` on a uniform sample `[-1, 1]` should give
/// `h �?0.9 * sd * n^(-1/5)` (the IQR term is smaller). For `n =
/// 200`, `sd �?0.577`, so `h �?0.9 * 0.577 * 200^(-0.2) �?0.9 *
/// 0.577 * 0.347 �?0.180`.
test "silverman_bandwidth_uniform" {
  let n = 200
  let y : Array[Double] = Array::makei(n, fn(i) {
    (i.to_double() - (n.to_double() - 1.0) / 2.0) /
    ((n.to_double() - 1.0) / 2.0)
  })
  let h = silverman_bandwidth(y)
  inspect(h > 0.15, content="true")
  inspect(h < 0.25, content="true")
}

///|
/// KDE integrates to ~1 over a wide range (sanity check that the
/// Gaussian normalisation is correct). We sample at 100 points
/// across `[-3, 3]` and sum `f_hat(x_i) * dx`.
test "gaussian_kde_integrates_to_one" {
  let n = 500
  let rng = chacha8_rng(7)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let theta = 2.0 * 3.141592653589793 * u2
    y[i] = r * @math.cos(theta)
  }
  let h = silverman_bandwidth(y)
  let mut acc = 0.0
  let dx = 6.0 / 100.0
  for i = 0; i < 100; i = i + 1 {
    let x = -3.0 + i.to_double() * dx
    acc = acc + gaussian_kde(y, x, h) * dx
  }
  // Should integrate to ~1 (loose tolerance �?KDE tails are truncated)
  inspect(acc > 0.85, content="true")
  inspect(acc < 1.15, content="true")
}
