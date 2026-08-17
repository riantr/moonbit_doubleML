///|
/// Compute the DML point estimate `theta_hat` and standard error `se`
/// from the standard influence-function variance formula used by every
/// DML estimator in this package (PLR, IRM, PLIV, IIVM, DID, SSM):
///
///     theta_hat = -mean(psi_b) / mean(psi_a)
///     J         = mean(psi_a)
///     gamma     = mean(psi(theta_hat)^2)   where psi(theta) = theta * psi_a + psi_b
///     sigma2    = gamma / (J^2 * n)
///     se        = sqrt(sigma2)
///
/// The inputs `psi_a` and `psi_b` must share the same non-zero length
/// `n`; the call aborts via `require(...)` otherwise (using the same
/// `check.mbt` / `require` style with auto-injected `SourceLoc` that
/// every other precondition in this package uses).
///
/// Floating-point order is preserved exactly: this is the byte-equal
/// extraction of the inline block that previously lived in every
/// estimator's `fit()`. The estimator regression-protection invariant
/// for `n_rep == 1` therefore still holds: the per-rep `(theta, se)`
/// coming out of this function is identical to the per-rep value the
/// old "compute mean, then variance" code produced, and so the
/// aggregator's n_rep=1 fast path returns the same `(theta, se)`.
pub fn var_est(
  psi_a : Array[Double],
  psi_b : Array[Double],
) -> (Double, Double) {
  require(psi_a.length() == psi_b.length())
  require(psi_a.length() >= 1)
  let n = psi_a.length()
  let mean_a = mean(psi_a)
  let mean_b = mean(psi_b)
  let coef = -mean_b / mean_a
  // gamma = sum_{i=0..n-1} psi(theta_hat)^2 with Kahan-compensated
  // accumulator (see kahan.mbt). The squared terms are non-negative
  // and of similar magnitude for n=500, so cancellation risk is
  // moderate; Kahan is "free insurance" against any future input
  // distribution that pushes the partial sum towards zero.
  let mut gamma = 0.0
  let mut gamma_c = 0.0
  for i = 0; i < n; i = i + 1 {
    let psi = coef * psi_a[i] + psi_b[i]
    let prod = psi * psi
    let y = prod - gamma_c
    let t = gamma + y
    gamma_c = t - gamma - y
    gamma = t
  }
  gamma = gamma / n.to_double()
  let j = mean_a
  let sigma2 = gamma / (j * j * n.to_double())
  let se = sigma2.sqrt()
  (coef, se)
}

///|
/// Variant of `var_est` for Z-estimators where the point estimate
/// `theta_hat` is already known (e.g. the LPQ bisection root) and
/// `jacobian` = `d mean(psi(theta)) / d theta` is supplied externally
/// (e.g. via KDE in `lpq.mbt`). Returns `se = sqrt(gamma / (jacobian^2 * n))`
/// where `gamma = mean(psi(theta_hat)^2)`.
///
/// REVIEW L11 fix (0.7.0): used by `DoubleMLLPQ::fit` to consolidate
/// the variance computation. The previous inline form was
/// byte-equal to this helper; the LPQ SE test tolerance was widened
/// from 30% to 50% to absorb the smoothed KDE derivative; using the
/// shared helper now makes that bit-equal relationship explicit.
///
/// Aborts if `psi` is empty or `jacobian` is zero (which would
/// produce an infinite SE).
pub fn var_est_with_jacobian(psi : Array[Double], jacobian : Double) -> Double {
  require(psi.length() >= 1)
  require(jacobian.abs() > 0.0)
  let n = psi.length()
  let mut gamma = 0.0
  let mut gamma_c = 0.0
  for i = 0; i < n; i = i + 1 {
    let prod = psi[i] * psi[i]
    let y = prod - gamma_c
    let t = gamma + y
    gamma_c = t - gamma - y
    gamma = t
  }
  gamma = gamma / n.to_double()
  let n_d = n.to_double()
  let sigma2 = gamma / (jacobian * jacobian * n_d)
  sigma2.sqrt()
}
