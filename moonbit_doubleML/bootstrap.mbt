///|
// Multiplier bootstrap core for DML score-based confidence
// intervals. v0.55.0+ extraction from `did_multi.mbt` and
// `did_cross_section.mbt`.
//
// Two estimator families use this primitive:
//   1. `DoubleMLDIDMulti` (panel DID) — computes
//      `boot_t_stat[b, k] = sum_i w[b, i] * psi_k[i] /
//      (sqrt(n) * se_k)` for each `(b, k)` where `b`
//      indexes bootstrap reps and `k` indexes group-time
//      combinations. `se_k` comes from the per-cell
//      `se_matrix`. `psi_k` is sliced from the per-cell
//      `psi_matrix` flat array (length
//      `n_groups * n_periods * n_obs`).
//   2. `DoubleMLDIDCrossSection` (cross-section DID) —
//      `n_thetas = 1` case; `psi_1 = psi_a + coef * psi_b`
//      is a length-`n_obs` array; `se_1 = sqrt(mean(psi^2))`.
//
// The common core reduces to a flat-row-major matrix
// product `boot_t_stat[b, k] = sum_i w[b, i] * psi_k[i] /
// (sqrt(n) * se_k)`, which the `did_bootstrap_t_stat`
// function below computes in one pass.

///|
/// Per-cell multiplier bootstrap t-statistics.
///
/// Parameters:
///   - `weights : Array[Double]` — flat row-major, shape
///     `[n_rep_boot, n_obs]`. Drawn by
///     `draw_bootstrap_weights(method_name, n_rep_boot,
///     n_obs, seed)` in the calling estimator.
///   - `psi : Array[Double]` — flat row-major, shape
///     `[n_thetas, n_obs]`. Each row is the per-observation
///     influence function `psi_k[i]` for theta `k`.
///     For `DoubleMLDIDMulti`, this is a slice of
///     `psi_matrix[flat * n_obs : (flat+1) * n_obs]` for
///     each group-time `(gi, pi)`.
///     For `DoubleMLDIDCrossSection`, this is a single
///     row `[n_obs]` of `psi_a[i] + coef * psi_b[i]`.
///   - `se : Array[Double]` — length `n_thetas`. The
///     standard error of the per-cell estimate. For DIDMulti,
///     `se[k] = se_matrix[gi * n_periods + pi]`. For
///     DIDCrossSection, `se[0] = sqrt(mean(psi^2))`.
///   - `n_rep_boot : Int` — number of bootstrap reps.
///   - `n_obs : Int` — sample size.
///   - `n_thetas : Int` — number of theta values
///     (= `gt_combinations.length()` for DIDMulti;
///     = 1 for DIDCrossSection).
///
/// Returns:
///   - `boot_t_stat : Array[Double]` — flat row-major,
///     shape `[n_rep_boot, n_thetas]`. Indexed as
///     `boot_t_stat[b * n_thetas + k]` for rep `b`, theta `k`.
///
/// Algorithm:
///   for b in 0..n_rep_boot:
///     for k in 0..n_thetas:
///       if se[k] == 0: skip (pre-treatment / empty cell)
///       s = 0
///       for i in 0..n_obs:
///         s += weights[b * n_obs + i] * psi[k * n_obs + i]
///       boot_t_stat[b * n_thetas + k] = s / (sqrt(n) * se[k])
///
/// Rows where `se[k] == 0` are set to 0 (matches the upstream
/// convention: empty cells produce no bootstrap variation).
pub fn did_bootstrap_t_stat(
  weights : Array[Double],
  psi : Array[Double],
  se : Array[Double],
  n_rep_boot : Int,
  n_obs : Int,
  n_thetas : Int,
) -> Array[Double] {
  let boot_t_stat : Array[Double] = Array::make(n_rep_boot * n_thetas, 0.0)
  let n_d = n_obs.to_double()
  let sqrt_n = n_d.sqrt()
  for b = 0; b < n_rep_boot; b = b + 1 {
    for k = 0; k < n_thetas; k = k + 1 {
      let se_k = se[k]
      // Skip empty / pre-treatment cells (se = 0). Matches the
      // v0.16.0+ DIDMulti convention; for DIDCrossSection the
      // caller pre-computes se[0] and only invokes the helper
      // when se[0] > 0 (degenerate se is handled before this
      // call to preserve the v0.42.0 "return zeros" path).
      if se_k == 0.0 {
        continue
      }
      let mut s = 0.0
      for i_long = 0; i_long < n_obs; i_long = i_long + 1 {
        let psi_k_i = psi[k * n_obs + i_long]
        s = s + weights[b * n_obs + i_long] * psi_k_i
      }
      boot_t_stat[b * n_thetas + k] = s / (sqrt_n * se_k)
    }
  }
  boot_t_stat
}