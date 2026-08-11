///|
/// Cinelli & Hazlett (2020) omitted-variable bias analysis for DML
/// estimators. Given the per-dessity influence-function scalars
/// `sigma2`, `nu2`, `psi_sigma2`, `psi_nu2`, this helper computes the
/// maximum bias from an unobserved confounder that shifts the
/// outcome nuisance `sigma2` by `psi_sigma2` and the treatment
/// nuisance `nu2` by `psi_nu2`.
///
/// The two quantities returned are
///   - `max_bias`: the worst-case absolute bias on the estimator,
///     equal to `sqrt(sigma2 * nu2)`.
///   - `psi_max_bias`: the gradient of `max_bias` with respect to the
///     confounding strength vector, equal to
///     `(sigma2 * psi_nu2 + nu2 * psi_sigma2) / (2 * max_bias)`.
///
/// Both quantities are length-`n_obs` arrays (per-observation
/// influence vectors); the caller typically averages over the sample
/// to get the scalar bias. Matches the upstream
/// `doubleml.utils._sensitivity._compute_sensitivity_bias` helper.
pub fn compute_sensitivity_bias(
  sigma2 : Double,
  nu2 : Double,
  psi_sigma2 : Array[Double],
  psi_nu2 : Array[Double],
) -> (Array[Double], Array[Double]) {
  require(psi_sigma2.length() == psi_nu2.length())
  let n = psi_sigma2.length()
  let max_bias_scalar = (sigma2 * nu2).sqrt()
  // Degenerate case: when `sigma2 * nu2 == 0` (e.g. deterministic
  // treatment), the gradient is undefined. We return the 0 vector
  // by convention — the bias itself is 0 in this regime.
  if max_bias_scalar == 0.0 {
    let zeros : Array[Double] = Array::make(n, 0.0)
    return (zeros, zeros)
  }
  let max_bias : Array[Double] = Array::make(n, max_bias_scalar)
  let psi_max_bias : Array[Double] = Array::make(n, 0.0)
  let inv = 1.0 / (2.0 * max_bias_scalar)
  for i = 0; i < n; i = i + 1 {
    psi_max_bias[i] = (sigma2 * psi_nu2[i] + nu2 * psi_sigma2[i]) * inv
  }
  (max_bias, psi_max_bias)
}

///|
/// Aggregate the per-observation sensitivity vectors into a scalar
/// "robustness value" `RV` — the minimum confounding strength that
/// would change the estimator's sign. Returns a large sentinel
/// (`1.0e300`) if the estimator is already zero (degenerate) since
/// MoonBit's `Double` has no `Infinity` constant in this build.
/// Per Cinelli & Hazlett (2020) §3.2: `RV = |theta_hat| / mean(max_bias)`.
pub fn robustness_value(
  theta : Double,
  max_bias : Array[Double],
) -> Double {
  if theta == 0.0 {
    return 1.0e300
  }
  let mean_bias = mean(max_bias)
  if mean_bias == 0.0 {
    return 1.0e300
  }
  theta.abs() / mean_bias
}