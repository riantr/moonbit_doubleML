///|
// v0.64.0+: shared multiplier-bootstrap helpers used by every
// estimator's `bootstrap()` method. The existing per-estimator
// bootstrap() implementations (PLR / IRM / PLIV / IIVM / APO /
// APOS / DIDCrossSection / DIDMulti, added in v0.55.0 / v0.61.0
// / v0.63.0) duplicate the same 50-line dance:
//
//   1. require(fitted)
//   2. require(method_name in {"normal","Bayes","wild"})
//   3. require(n_rep_boot >= 2)
//   4. weights = draw_bootstrap_weights(method_name, n_rep_boot,
//      n_obs, seed) catch ... abort(...)
//   5. psi[i] = psi_at(coef, psi_a, psi_b)[i]  (= coef*psi_a + psi_b)
//   6. se_psi = sqrt(mean(psi^2))
//   7. if se_psi <= 0: return zeros
//   8. boot = did_bootstrap_t_stat(weights, psi, [se_psi],
//      n_rep_boot, n_obs, 1)
//   9. { ..self, boot_t_stat: boot, ... }
//
// This file factors out the shared 8-line inner (steps 4-8) so
// each new estimator's `bootstrap()` is ~15 lines instead of ~50.
//
// Three inner variants cover the existing estimator shapes:
//   - generic_bootstrap_t_stat: single-theta, psi =
//     psi_at(coef, psi_a, psi_b) (CVAR/IRM/IIVM/PLIV/APO/APOS/PLPR/
//     SSM/DID/DIDCSBinary, plus LPLR with its (offset, slope)
//     fields passed the other way round). v0.90.0: the
//     signature is unchanged; only the score order moved from
//     `psi_a + coef * psi_b` to `coef * psi_a + psi_b`.
//   - generic_bootstrap_single_psi: single-theta with a centered
//     IF (LPQ/PQ; QTE reuses this with a flat
//     [n_quantiles * n_obs] psi matrix and se_flat of length
//     n_quantiles).
//   - generic_bootstrap_ols_per_coef: per-coefficient OLS IF
//     (BLP). psi[i, j] = M[j, :] @ x_i * e_i where
//     M = (X^T X)^{-1}.

///|
/// v0.64.0+ shared inner for the single-theta multiplier
/// bootstrap. Caller has already validated `psi_a`, `psi_b`,
/// `coef`, `method_name`, and `n_rep_boot`. Returns a
/// length-`n_rep_boot` array of `boot_t_stat` values; raises
/// `BootstrapMethodError` on an unknown multiplier distribution
/// (the caller is expected to `catch` and abort with the
/// pre-v0.64.0 message); returns a zero array if `se_psi <= 0`
/// (degenerate IF, no variance to divide by).
fn generic_bootstrap_t_stat(
  psi_a : Array[Double],
  psi_b : Array[Double],
  coef : Double,
  method_name : String,
  n_rep_boot : Int,
  seed : Int,
) -> Array[Double] raise BootstrapMethodError {
  let n_obs = psi_a.length()
  if n_obs != psi_b.length() {
    abort(
      "generic_bootstrap_t_stat: psi_a.length() != psi_b.length() (" +
      n_obs.to_string() +
      " vs " +
      psi_b.length().to_string() +
      ")",
    )
  }
  // Evaluate the score at `coef` and track ss_psi for se_psi.
  // v0.90.0: the score is `psi_at(coef, psi_a, psi_b)` --
  // `coef * psi_a + psi_b` -- the same function of `coef` that
  // `var_est` integrates for `se()`. v0.64.0 - v0.89.0 used
  // `psi_a + coef * psi_b`, which evaluates a different function
  // whose root is not `coef`.
  let psi = psi_at(coef, psi_a, psi_b)
  let mut ss_psi = 0.0
  for i = 0; i < n_obs; i = i + 1 {
    let psi_i = psi[i]
    ss_psi = ss_psi + psi_i * psi_i
  }
  let n_d = n_obs.to_double()
  let se_psi = (ss_psi / n_d).sqrt()
  if se_psi <= 0.0 {
    return Array::make(n_rep_boot, 0.0)
  }
  // Draw multipliers. v0.37.0+: draw_bootstrap_weights raises
  // BootstrapMethodError on an unknown method; we let it
  // propagate so the caller can wrap it in a `try { ... } catch
  // { abort(...) }` block.
  let weights = draw_bootstrap_weights(method_name, n_rep_boot, n_obs, seed)
  let se_flat : Array[Double] = [se_psi]
  did_bootstrap_t_stat(weights, psi, se_flat, n_rep_boot, n_obs, 1)
}

///|
/// v0.64.0+ shared inner for the centered single-IF multiplier
/// bootstrap (LPQ, PQ). The IF `psi` is already the
/// per-observation influence function evaluated at `coef` (mean
/// zero, `se_psi = sqrt(mean(psi^2))` is the bootstrap
/// denominator). For QTE, callers can pass a flat
/// `[n_quantiles * n_obs]` psi matrix and a `se_flat` of length
/// `n_quantiles` to recover the multi-theta case (each quantile
/// has its own se).
///
/// Raises `BootstrapMethodError` on an unknown multiplier
/// distribution (caller `catch`-es and aborts); returns a zero
/// array if `se_psi <= 0` (degenerate IF).
fn generic_bootstrap_single_psi(
  psi : Array[Double],
  method_name : String,
  n_rep_boot : Int,
  seed : Int,
) -> Array[Double] raise BootstrapMethodError {
  let n_obs = psi.length()
  let mut ss_psi = 0.0
  for i = 0; i < n_obs; i = i + 1 {
    let v = psi[i]
    ss_psi = ss_psi + v * v
  }
  let n_d = n_obs.to_double()
  let se_psi = (ss_psi / n_d).sqrt()
  if se_psi <= 0.0 {
    return Array::make(n_rep_boot, 0.0)
  }
  let weights = draw_bootstrap_weights(method_name, n_rep_boot, n_obs, seed)
  let se_flat : Array[Double] = [se_psi]
  did_bootstrap_t_stat(weights, psi, se_flat, n_rep_boot, n_obs, 1)
}

///|
/// v0.64.0+ shared inner for the *multi-psi* single-IF
/// multiplier bootstrap (QTE). Each entry in `psi_flat` is a
/// flat `[n_thetas * n_obs]` matrix laid out row-major
/// (`psi_flat[k * n_obs + i]` = IF for theta `k` at observation
/// `i`). `se_flat` has length `n_thetas`; the helper skips a
/// theta when its `se_flat[k] <= 0` (degenerate IF — writes
/// zeros into `boot_t_stat`). Returns a flat `[n_rep_boot *
/// n_thetas]` array of t-statistics in row-major order.
///
/// Raises `BootstrapMethodError` on an unknown multiplier
/// distribution (caller `catch`-es and aborts).
fn generic_bootstrap_psi_matrix(
  psi_flat : Array[Double],
  se_flat : Array[Double],
  method_name : String,
  n_rep_boot : Int,
  n_obs : Int,
  n_thetas : Int,
  seed : Int,
) -> Array[Double] raise BootstrapMethodError {
  let weights = draw_bootstrap_weights(method_name, n_rep_boot, n_obs, seed)
  did_bootstrap_t_stat(weights, psi_flat, se_flat, n_rep_boot, n_obs, n_thetas)
}

///|
/// v0.64.0+ shared inner for the per-coefficient OLS multiplier
/// bootstrap (BLP). For OLS projection `beta_hat = M X^T y` with
/// `M = (X^T X)^{-1}`, the per-observation influence function is
/// `psi[i, j] = M[j, :] @ x_i * e_i` (so `E[psi] = 0` and
/// `sqrt(sum(psi^2) / n)` is the bootstrap denominator for
/// `coef[j]`).
///
/// Caller has already validated `method_name` and `n_rep_boot`.
/// `se_flat` must be a length-`p` array of the per-coefficient
/// SEs (BLP populates this from its HC0/nonrobust covariance
/// diagonal). Returns a flat `[n_rep_boot * p]` array of t-stats
/// in row-major order; raises `BootstrapMethodError` on an
/// unknown multiplier distribution.
fn generic_bootstrap_ols_per_coef(
  basis : Matrix,
  residuals : Array[Double],
  xtx_inv : Matrix,
  se_flat : Array[Double],
  method_name : String,
  n_rep_boot : Int,
  seed : Int,
) -> Array[Double] raise BootstrapMethodError {
  let n_obs = basis.rows()
  let p = xtx_inv.rows()
  if se_flat.length() != p {
    abort(
      "generic_bootstrap_ols_per_coef: se_flat.length() != p (" +
      se_flat.length().to_string() +
      " vs " +
      p.to_string() +
      ")",
    )
  }
  // Materialize the per-observation IF as a flat
  // [n_thetas, n_obs] matrix where `n_thetas = p`.
  let psi_flat : Array[Double] = Array::make(p * n_obs, 0.0)
  for j = 0; j < p; j = j + 1 {
    if se_flat[j] <= 0.0 {
      continue
    }
    for i = 0; i < n_obs; i = i + 1 {
      // M[j, :] @ x_i = sum_k xtx_inv[j, k] * basis[i, k]
      let mut m_xi = 0.0
      for k = 0; k < basis.cols(); k = k + 1 {
        m_xi = m_xi + xtx_inv.data[j * p + k] * basis.data[i * basis.cols() + k]
      }
      psi_flat[j * n_obs + i] = m_xi * residuals[i]
    }
  }
  let weights = draw_bootstrap_weights(method_name, n_rep_boot, n_obs, seed)
  did_bootstrap_t_stat(weights, psi_flat, se_flat, n_rep_boot, n_obs, p)
}
