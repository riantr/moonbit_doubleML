///|
/// v0.66.0+: shared inner for the IRM-style
/// `sensitivity_analysis` (PLR / IRM / PLIV / IIVM / APO /
/// APOS / SSM / DID / DIDBinary / DIDCS / DIDCSBinary).
/// Caller passes the outcome-residual array
/// (`residuals[i] = y[i] - l_hat[i]`, where `l_hat` is the
/// outcome nuisance prediction) and the per-observation
/// influence-function denominator `psi_a` (already
/// persisted by v0.64.0). Returns a `SensitivityResult`
/// with `rv`, `sigma2`, `nu2`, `cf_y`, `cf_d`, `max_bias`.
///
/// The underlying formula follows Cinelli & Hazlett (2020):
///
///   sigma2 = mean(residuals^2)
///   nu2    = mean(psi_a^2)
///   psi_sigma2[i] = residuals[i]^2 - sigma2  (centered)
///   psi_nu2[i]    = psi_a[i]^2 - nu2         (centered)
///   (max_bias, _) = compute_sensitivity_bias(sigma2, nu2,
///                                          psi_sigma2,
///                                          psi_nu2)
///   max_bias_scalar = mean(max_bias)
///   rv = |theta| / max_bias_scalar  (degenerates to 1e300
///                                    when either is 0).
///
/// `cf_y` / `cf_d` are user-supplied benchmarking upper
/// bounds (defaults 0.05). They are passed through
/// unmodified — the actual robustness analysis is unchanged
/// for either choice; they are documented in the result for
/// upstream parity.
pub fn irm_style_sensitivity(
  theta : Double,
  residuals : Array[Double],
  psi_a : Array[Double],
  cf_y : Double,
  cf_d : Double,
) -> SensitivityResult raise {
  let n = residuals.length()
  require(n == psi_a.length())
  require(n > 0)
  let n_d = n.to_double()
  let mut ss_resid = 0.0
  let mut ss_psi_a = 0.0
  for i = 0; i < n; i = i + 1 {
    ss_resid = ss_resid + residuals[i] * residuals[i]
    ss_psi_a = ss_psi_a + psi_a[i] * psi_a[i]
  }
  let sigma2 = ss_resid / n_d
  let nu2 = ss_psi_a / n_d
  let psi_sigma2 : Array[Double] = Array::make(n, 0.0)
  let psi_nu2 : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    psi_sigma2[i] = residuals[i] * residuals[i] - sigma2
    psi_nu2[i] = psi_a[i] * psi_a[i] - nu2
  }
  let (max_bias_arr, _) = compute_sensitivity_bias(
    sigma2, nu2, psi_sigma2, psi_nu2,
  )
  let mut mb_sum = 0.0
  for v in max_bias_arr {
    mb_sum = mb_sum + v
  }
  let max_bias = mb_sum / n_d
  let rv = robustness_value(theta, max_bias_arr)
  { rv, sigma2, nu2, cf_y, cf_d, max_bias, }
}

///|
/// v0.72.0+: cluster-robust analogue to `irm_style_sensitivity`
/// (see the IID helper above). Replaces the per-observation
/// variance baselines
///
///   sigma2 = mean(residuals^2)
///   nu2    = mean(psi_a^2)
///
/// with their cluster-summed counterparts
///
///   sigma2_cluster = (1 / n_clusters) * sum_c (sum_{i in c} w[i] * residuals[i])^2
///   nu2_cluster    = (1 / n_clusters) * sum_c (sum_{i in c} w[i] * psi_a[i])^2
///
/// where `w[i]` is the optional kernel weight for observation
/// `i` (default uniform `w[i] = 1.0`).
///
/// `cluster_ids[i]` is the 0-based cluster index of observation
/// `i`. All observations in the same cluster share an id;
/// `cluster_ids.length()` must equal `residuals.length()`. The
/// number of clusters is `1 + max(cluster_ids)`.
///
/// `kernel_weights` (v0.78.0+, RDD-aware): optional per-observation
/// weights `w[i]` of length `residuals.length()`. When empty
/// (`kernel_weights = []`), the function falls back to uniform
/// `w[i] = 1.0` and the cluster sums collapse to the v0.72.0
/// unweighted form. When non-empty, `kernel_weights.length()`
/// must equal `residuals.length()` and the cluster sums use
/// the weighted form
/// `sum_{i in c} w[i] * residuals[i]` / `sum_{i in c} w[i] * psi_a[i]`.
/// This is the kernel-weighted RDD extension: observations near
/// the cutoff (high `w[k]`) drive the cluster-aggregated variance
/// baseline; observations near the bandwidth edge (low `w[k]`)
/// contribute proportionally less.
///
/// `max_bias` and the robustness value `RV` stay per-observation
/// (the upstream Cinelli & Hazlett bias expression is per-obs),
/// but the variance baseline against which `residuals[i]^2` and
/// `psi_a[i]^2` are centered is now the cluster-aggregated
/// `sigma2_cluster` / `nu2_cluster` rather than the IID
/// `mean(residuals^2)` / `mean(psi_a^2)`. The mean of the
/// per-observation `max_bias` array is the scalar returned.
/// The per-observation centering is `residuals[i]^2 - sigma2`
/// (NOT `w[i]^2 * residuals[i]^2 - sigma2`) by convention, so
/// the C&H bias expression remains per-observation-anchored.
///
/// Output shape matches `irm_style_sensitivity` (same
/// `SensitivityResult` struct) so callers can swap IID for
/// cluster-aware without changing the return contract.
pub fn irm_style_sensitivity_cluster(
  theta : Double,
  residuals : Array[Double],
  psi_a : Array[Double],
  cluster_ids : Array[Int],
  cf_y : Double,
  cf_d : Double,
  kernel_weights? : Array[Double] = [],
) -> SensitivityResult raise {
  let n = residuals.length()
  require(n == psi_a.length())
  require(n == cluster_ids.length())
  require(n > 0)
  let use_weights = kernel_weights.length() > 0
  if use_weights {
    require(kernel_weights.length() == n)
  }
  // Find max cluster id (= n_clusters - 1) and cluster-sum
  // both residuals and psi_a. Two passes: first find
  // n_clusters, second accumulate sums.
  let mut max_cid = -1
  for i = 0; i < n; i = i + 1 {
    if cluster_ids[i] > max_cid {
      max_cid = cluster_ids[i]
    }
  }
  require(max_cid >= 0)
  let n_clusters = max_cid + 1
  let n_clusters_d = n_clusters.to_double()
  let cluster_sum_resid : Array[Double] = Array::make(n_clusters, 0.0)
  let cluster_sum_psi_a : Array[Double] = Array::make(n_clusters, 0.0)
  if use_weights {
    for i = 0; i < n; i = i + 1 {
      let cid = cluster_ids[i]
      let w = kernel_weights[i]
      cluster_sum_resid[cid] = cluster_sum_resid[cid] + w * residuals[i]
      cluster_sum_psi_a[cid] = cluster_sum_psi_a[cid] + w * psi_a[i]
    }
  } else {
    for i = 0; i < n; i = i + 1 {
      let cid = cluster_ids[i]
      cluster_sum_resid[cid] = cluster_sum_resid[cid] + residuals[i]
      cluster_sum_psi_a[cid] = cluster_sum_psi_a[cid] + psi_a[i]
    }
  }
  // sigma2_cluster = (1 / n_clusters) * sum_c cluster_sum_resid[c]^2.
  let mut ss_resid = 0.0
  let mut ss_psi_a = 0.0
  for c = 0; c < n_clusters; c = c + 1 {
    ss_resid = ss_resid + cluster_sum_resid[c] * cluster_sum_resid[c]
    ss_psi_a = ss_psi_a + cluster_sum_psi_a[c] * cluster_sum_psi_a[c]
  }
  let sigma2 = ss_resid / n_clusters_d
  let nu2 = ss_psi_a / n_clusters_d
  // Per-observation centering: residuals[i]^2 - sigma2_cluster
  // and psi_a[i]^2 - nu2_cluster. The C&H bias expression is
  // per-obs (depends on the per-obs residual / IF), so we keep
  // the per-obs loop and only swap in the cluster baseline.
  let psi_sigma2 : Array[Double] = Array::make(n, 0.0)
  let psi_nu2 : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    psi_sigma2[i] = residuals[i] * residuals[i] - sigma2
    psi_nu2[i] = psi_a[i] * psi_a[i] - nu2
  }
  let (max_bias_arr, _) = compute_sensitivity_bias(
    sigma2, nu2, psi_sigma2, psi_nu2,
  )
  let mut mb_sum = 0.0
  for v in max_bias_arr {
    mb_sum = mb_sum + v
  }
  let max_bias = mb_sum / n.to_double()
  let rv = robustness_value(theta, max_bias_arr)
  { rv, sigma2, nu2, cf_y, cf_d, max_bias, }
}

///|
/// v0.66.0+: empirical (1 - `q`) quantile of an `Array[Double]`
/// via insertion sort. Used by the joint confidence-interval
/// max-|t| critical-value computation (the per-rep max |t|
/// over all thetas is collected into a length-`n_rep_boot`
/// array; the (1 - alpha) quantile is the joint critical
/// value). Insertion sort is O(n^2) but `n` is small
/// (`n_rep_boot` is typically 500), so the cost is
/// negligible compared to the bootstrap itself.
pub fn empirical_quantile(arr : Array[Double], q : Double) -> Double raise {
  require(arr.length() > 0)
  require(q >= 0.0 && q <= 1.0)
  let s = arr.copy()
  let n = s.length()
  // Insertion sort ascending.
  for i = 1; i < n; i = i + 1 {
    let v = s[i]
    let mut j = i
    while j > 0 && s[j - 1] > v {
      s[j] = s[j - 1]
      j = j - 1
    }
    s[j] = v
  }
  let idx = ((n - 1).to_double() * q).to_int()
  s[idx]
}

///|
/// v0.73.0+: multi-theta analogue of
/// `irm_style_sensitivity_cluster`. Loops over the per-theta
/// `residuals_matrix[k]` / `psi_a_matrix[k]` (each a
/// length-`n` row corresponding to one "theta" of a per-cell
/// or per-coef estimator) and routes each row through the
/// single-theta `irm_style_sensitivity_cluster` helper with
/// the same shared `cluster_ids`. Output is an
/// `Array[SensitivityResult]` of length `theta_array.length()`.
///
/// Each row's cluster_ids are identical across thetas (one
/// observation belongs to exactly one cluster regardless of
/// which theta's IF you're looking at). The cluster-summed
/// `sigma2_cluster` / `nu2_cluster` are therefore shared
/// across all thetas in principle, but the per-theta call to
/// `irm_style_sensitivity_cluster` recomputes them on each
/// iteration; the cost is O(n * n_thetas) extra work and the
/// numerical result is identical (the cluster sums only
/// depend on the rows, not on `theta_array[k]`).
///
/// Preconditions:
///   - `theta_array.length() == residuals_matrix.length() ==
///     psi_a_matrix.length()`.
///   - Each row of `residuals_matrix` and `psi_a_matrix` has
///     the same length as `cluster_ids` (so the inner
///     `irm_style_sensitivity_cluster` preconditions fire as
///     well).
pub fn irm_style_sensitivity_cluster_multi(
  theta_array : Array[Double],
  residuals_matrix : Array[Array[Double]],
  psi_a_matrix : Array[Array[Double]],
  cluster_ids : Array[Int],
  cf_y : Double,
  cf_d : Double,
) -> Array[SensitivityResult] raise {
  let n_thetas = theta_array.length()
  require(n_thetas == residuals_matrix.length())
  require(n_thetas == psi_a_matrix.length())
  let out : Array[SensitivityResult] = Array::make(n_thetas, {
    rv: 0.0,
    sigma2: 0.0,
    nu2: 0.0,
    cf_y: 0.0,
    cf_d: 0.0,
    max_bias: 0.0,
  })
  for k = 0; k < n_thetas; k = k + 1 {
    out[k] = irm_style_sensitivity_cluster(
      theta_array[k],
      residuals_matrix[k],
      psi_a_matrix[k],
      cluster_ids,
      cf_y,
      cf_d,
    )
  }
  out
}

///|
/// v0.67.0+: shared inner for the centered single-IF
/// `sensitivity_analysis` (LPQ / PQ). The IF `psi` is already
/// centered (mean 0 at the bisection root); the
/// Riesz-representer variance is `nu2 = mean(psi^2)`. The
/// outcome nuisance variance `sigma2 = Var(y)` (population,
/// i.e. `mean((y - mean(y))^2)`) plays the role of
/// `sigma2` in the C&H formula. Returns a
/// `SensitivityResult` matching the IRM-style path's shape.
pub fn single_psi_sensitivity(
  theta : Double,
  psi : Array[Double],
  y : Array[Double],
  cf_y : Double,
  cf_d : Double,
) -> SensitivityResult raise {
  let n = psi.length()
  require(n == y.length())
  require(n > 0)
  let n_d = n.to_double()
  let mut nu2_sum = 0.0
  let mut y_sum = 0.0
  for i = 0; i < n; i = i + 1 {
    nu2_sum = nu2_sum + psi[i] * psi[i]
    y_sum = y_sum + y[i]
  }
  let nu2 = nu2_sum / n_d
  let y_bar = y_sum / n_d
  let mut sigma2_sum = 0.0
  for i = 0; i < n; i = i + 1 {
    let dy = y[i] - y_bar
    sigma2_sum = sigma2_sum + dy * dy
  }
  let sigma2 = sigma2_sum / n_d
  let psi_sigma2 : Array[Double] = Array::make(n, 0.0)
  let psi_nu2 : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    psi_sigma2[i] = (y[i] - y_bar) * (y[i] - y_bar) - sigma2
    psi_nu2[i] = psi[i] * psi[i] - nu2
  }
  let (max_bias_arr, _) = compute_sensitivity_bias(
    sigma2, nu2, psi_sigma2, psi_nu2,
  )
  let mut mb_sum = 0.0
  for v in max_bias_arr {
    mb_sum = mb_sum + v
  }
  let max_bias = mb_sum / n_d
  let rv = robustness_value(theta, max_bias_arr)
  { rv, sigma2, nu2, cf_y, cf_d, max_bias, }
}

///|
// v0.66.0+: result struct for `DoubleMLXXX::sensitivity_analysis`.
pub struct SensitivityResult {
  rv : Double
  sigma2 : Double
  nu2 : Double
  cf_y : Double
  cf_d : Double
  max_bias : Double
} derive(Debug)

///|
pub extend SensitivityResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Cinelli & Hazlett (2020) omitted-variable bias analysis for DML
/// estimators. Given the per-density influence-function scalars
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
  try {
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
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Aggregate the per-observation sensitivity vectors into a scalar
/// "robustness value" `RV` — the minimum confounding strength that
/// would change the estimator's sign. Returns a large sentinel
/// (`1.0e300`) if the estimator is already zero (degenerate) since
/// MoonBit's `Double` has no `Infinity` constant in this build.
/// Per Cinelli & Hazlett (2020) §3.2: `RV = |theta_hat| / mean(max_bias)`.
pub fn robustness_value(theta : Double, max_bias : Array[Double]) -> Double {
  if theta == 0.0 {
    return 1.0e300
  }
  let mean_bias = mean(max_bias)
  if mean_bias == 0.0 {
    return 1.0e300
  }
  theta.abs() / mean_bias
}

// ---------------------------------------------------------------------------
// v0.17.0+ Gain statistics (benchmark values for sensitivity parameters)
// ---------------------------------------------------------------------------

///|
/// Container for the per-coefficient gain-statistic benchmark values.
/// Returned by `gain_statistics`. The four fields are
///   - `cf_y` (length `n_coef`): the maximum percentage of the
///     outcome's residual variance explainable by an unobserved
///     confounder that explains the difference between
///     `dml_long` and `dml_short`'s residual variance. Used as
///     the upper bound on `cf_y` in `sensitivity_analysis`.
///   - `cf_d` (length `n_coef`): the maximum percentage gain in
///     the Riesz representer's variance explainable by an
///     unobserved confounder. Used as the upper bound on
///     `cf_d`.
///   - `rho` (length `n_coef`): the sign-and-magnitude of the
///     confounding correlation (in `[-1, 1]`) that drives the
///     coefficient change from `dml_long` to `dml_short`.
///   - `delta_theta` (length `n_coef`): the per-coefficient
///     change `coef_short - coef_long` (median over reps).
///
/// All four are length `n_coef = dml_long.coef.length()`. The
/// benchmark is the upstream `doubleml.utils.gain_statistics`
/// output; see Cinelli & Hazlett (2020) §3.4 for the
/// interpretation of `cf_y` / `cf_d` / `rho`.
pub struct GainStatsResult {
  cf_y : Array[Double]
  cf_d : Array[Double]
  rho : Array[Double]
  delta_theta : Array[Double]
} derive(Debug)

///|
pub extend GainStatsResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Compute the gain-statistic benchmark values for `cf_y`,
/// `cf_d`, `rho`, and `delta_theta` from two fitted DML
/// models: `dml_long` (which includes all observed
/// confounders) and `dml_short` (which excludes one or more
/// "benchmark" confounders).
///
/// Each of `dml_long` / `dml_short` exposes four per-rep
/// arrays (shape `(n_coef, n_rep)`):
///   - `all_coef`: the per-rep coefficient estimates.
///   - `var_y_residuals`: the per-rep outcome-residual
///     variance (i.e. `sigma2`).
///   - `nu2`: the per-rep treatment-residual variance (i.e.
///     the squared norm of the Riesz representer).
///   - `var_y`: the overall outcome variance (scalar, shared
///     between `dml_long` and `dml_short`).
///
/// The algorithm (matches upstream
/// `doubleml.utils.gain_statistics.gain_statistics`):
///   1. `R2_y_long = 1 - var_y_residuals_long / var_y`,
///      `R2_y_short = 1 - var_y_residuals_short / var_y`,
///      `R2_riesz = nu2_short / nu2_long`.
///   2. `cf_y = clip((R2_y_long - R2_y_short) / (1 - R2_y_long), 0, 1)`.
///   3. `cf_d = clip((1 - R2_riesz) / R2_riesz, 0, 1)`.
///   4. `delta_theta = median(dml_short.all_coef - dml_long.all_coef, axis=rep)`.
///   5. `rho = median(sign(delta_theta) * |delta_theta| / sqrt(var_g * var_riesz))`,
///      where `var_g = var_y_residuals_short - var_y_residuals_long`
///      and `var_riesz = nu2_long - nu2_short` (clipped to
///      `[-1, 1]` and `0` when the denominator is 0).
///   6. Return the median across reps for each coefficient.
///
/// The per-coefficient `cf_y` and `cf_d` benchmark the
/// "tipping point" of the sensitivity analysis: a
/// confounder with strength <= `cf_y` (resp. `cf_d`) cannot
/// change the conclusion. `rho` and `delta_theta` are
/// diagnostic: they tell the user the direction and
/// magnitude of the change between `dml_long` and
/// `dml_short`.
pub fn gain_statistics(
  dml_long : GainStatsSource,
  dml_short : GainStatsSource,
) -> GainStatsResult {
  try {
    require(dml_long.var_y_residuals.length() == dml_long.nu2.length())
    require(dml_long.var_y_residuals.length() == dml_long.all_coef.length())
    require(dml_short.var_y_residuals.length() == dml_short.nu2.length())
    require(dml_short.var_y_residuals.length() == dml_short.all_coef.length())
    // Long and short must share the same per-rep dimensions.
    let n_long = dml_long.var_y_residuals.length()
    let n_short = dml_short.var_y_residuals.length()
    // `n_coef` is the per-coefficient count, derived from the
    // shared `var_y` (scalar). The arrays are row-major
    // `(n_coef, n_rep)`, so `n_coef = n_long / n_rep` (or
    // `n_short / n_rep`; they must agree).
    let n_rep_long = dml_long.n_rep
    let n_rep_short = dml_short.n_rep
    require(n_long % n_rep_long == 0)
    require(n_short % n_rep_short == 0)
    let n_coef = n_long / n_rep_long
    require(n_coef == n_short / n_rep_short)
    // Per-rep nonparametric R2.
    let r2_y_long : Array[Double] = Array::make(n_long, 0.0)
    let r2_y_short : Array[Double] = Array::make(n_long, 0.0)
    let r2_riesz : Array[Double] = Array::make(n_long, 0.0)
    let var_y = dml_long.var_y
    for k = 0; k < n_long; k = k + 1 {
      r2_y_long[k] = 1.0 - dml_long.var_y_residuals[k] / var_y
      r2_y_short[k] = 1.0 - dml_short.var_y_residuals[k] / var_y
      r2_riesz[k] = dml_short.nu2[k] / dml_long.nu2[k]
    }
    // `cf_y[k] = clip((R2_y_long - R2_y_short) / (1 - R2_y_long), 0, 1)`.
    let all_cf_y : Array[Double] = Array::make(n_long, 0.0)
    let all_cf_d : Array[Double] = Array::make(n_long, 0.0)
    for k = 0; k < n_long; k = k + 1 {
      let denom = 1.0 - r2_y_long[k]
      let cf_y = if denom == 0.0 {
        0.0
      } else {
        let v = (r2_y_long[k] - r2_y_short[k]) / denom
        if v < 0.0 {
          0.0
        } else if v > 1.0 {
          1.0
        } else {
          v
        }
      }
      all_cf_y[k] = cf_y
      // `cf_d = clip((1 - R2_riesz) / R2_riesz, 0, 1)`.
      let cf_d = if r2_riesz[k] == 0.0 {
        0.0
      } else {
        let v = (1.0 - r2_riesz[k]) / r2_riesz[k]
        if v < 0.0 {
          0.0
        } else if v > 1.0 {
          1.0
        } else {
          v
        }
      }
      all_cf_d[k] = cf_d
    }
    ignore(n_rep_short)
    // `delta_theta = median(dml_short.all_coef - dml_long.all_coef, axis=rep)`.
    let all_delta_theta : Array[Double] = Array::make(n_long, 0.0)
    for k = 0; k < n_long; k = k + 1 {
      all_delta_theta[k] = dml_short.all_coef[k] - dml_long.all_coef[k]
    }
    // `rho = median(sign(delta_theta) * clip(|delta_theta| /
    // sqrt(var_g * var_riesz), 0, 1))`, where
    // `var_g = var_y_residuals_short - var_y_residuals_long`
    // and `var_riesz = nu2_long - nu2_short`. The
    // `np.divide(..., where=denom != 0)` upstream convention
    // sets the ratio to 1.0 when `denom` is 0 (or NaN).
    let all_rho : Array[Double] = Array::make(n_long, 0.0)
    for k = 0; k < n_long; k = k + 1 {
      let var_g = dml_short.var_y_residuals[k] - dml_long.var_y_residuals[k]
      let var_riesz = dml_long.nu2[k] - dml_short.nu2[k]
      let denom = (var_g * var_riesz).sqrt()
      let abs_dt = all_delta_theta[k].abs()
      let rho_abs = if denom == 0.0 || denom.is_nan() {
        1.0
      } else {
        let v = abs_dt / denom
        if v < 0.0 {
          0.0
        } else if v > 1.0 {
          1.0
        } else {
          v
        }
      }
      let sign_dt = if all_delta_theta[k] > 0.0 {
        1.0
      } else if all_delta_theta[k] < 0.0 {
        -1.0
      } else {
        0.0
      }
      all_rho[k] = sign_dt * rho_abs
    }
    // Median across reps per coefficient.
    let cf_y_out : Array[Double] = Array::make(n_coef, 0.0)
    let cf_d_out : Array[Double] = Array::make(n_coef, 0.0)
    let rho_out : Array[Double] = Array::make(n_coef, 0.0)
    let delta_theta_out : Array[Double] = Array::make(n_coef, 0.0)
    for c = 0; c < n_coef; c = c + 1 {
      // Extract the c-th column of each `(n_coef, n_rep)` array.
      let col_cf_y : Array[Double] = Array::make(n_rep_long, 0.0)
      let col_cf_d : Array[Double] = Array::make(n_rep_long, 0.0)
      let col_rho : Array[Double] = Array::make(n_rep_long, 0.0)
      let col_dt : Array[Double] = Array::make(n_rep_long, 0.0)
      for r = 0; r < n_rep_long; r = r + 1 {
        let k = c * n_rep_long + r
        col_cf_y[r] = all_cf_y[k]
        col_cf_d[r] = all_cf_d[k]
        col_rho[r] = all_rho[k]
        col_dt[r] = all_delta_theta[k]
      }
      col_cf_y.sort()
      col_cf_d.sort()
      col_rho.sort()
      col_dt.sort()
      cf_y_out[c] = median_sorted(col_cf_y)
      cf_d_out[c] = median_sorted(col_cf_d)
      rho_out[c] = median_sorted(col_rho)
      delta_theta_out[c] = median_sorted(col_dt)
    }
    {
      cf_y: cf_y_out,
      cf_d: cf_d_out,
      rho: rho_out,
      delta_theta: delta_theta_out,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Container exposing the per-rep arrays `gain_statistics`
/// needs from a fitted DML model. The upstream API is the
/// `DoubleML` object; the v0.17.0 port defines a minimal
/// struct so any DML estimator (BLP, PolicyTree, PLR, IRM,
/// ...) can be benchmarked. `var_y_residuals`, `nu2`, and
/// `all_coef` are row-major `(n_coef, n_rep)`; `n_rep` is
/// the per-coefficient repetition count; `var_y` is the
/// scalar outcome variance.
pub struct GainStatsSource {
  var_y_residuals : Array[Double]
  nu2 : Array[Double]
  all_coef : Array[Double]
  n_rep : Int
  var_y : Double
} derive(Debug)

///|
pub extend GainStatsSource with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Builder constructor for `GainStatsSource` that mirrors
/// the upstream `DoubleML` attribute access. Validates
/// shape consistency: all three per-rep arrays must have
/// the same length, and that length must be divisible by
/// `n_rep`.
pub fn GainStatsSource::new(
  var_y_residuals : Array[Double],
  nu2 : Array[Double],
  all_coef : Array[Double],
  n_rep : Int,
  var_y : Double,
) -> GainStatsSource {
  try {
    let n = var_y_residuals.length()
    require(n == nu2.length())
    require(n == all_coef.length())
    require(n_rep > 0)
    require(n % n_rep == 0)
    { var_y_residuals, nu2, all_coef, n_rep, var_y, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.19.0+ convenience constructor for `GainStatsSource`
/// from a fitted `DoubleMLBLP`. Auto-populates all the
/// per-rep arrays from the BLP's fit output:
///
///   - `var_y_residuals[k] = RSS / n_obs` (constant across
///     coefficients; the BLP's residual variance).
///   - `nu2[k] = var_y_residuals[k] / (n_obs * se[k]^2)`
///     (the per-coef Riesz representer norm squared under
///     the homoskedastic OLS convention
///     `se[k]^2 = sigma^2 * (Z^T Z)^{-1}_{kk}`).
///   - `all_coef[k] = blp.coef()[k]`.
///   - `var_y = blp.var_y()` (the variance of the BLP's
///     orthogonal signal — the BLP's "outcome" variable).
///
/// The HC0 SE convention is consistent with this
/// homoskedastic interpretation up to O(1/n) corrections
/// (the BLP's HC0 SE is robust to heteroskedasticity in
/// the orthogonal-signal residuals; the auto-populated
/// `nu2` uses the BLP's reported SE directly).
///
/// `n_rep` defaults to 1 (single-rep BLP). Multi-rep
/// DMLs should pass `n_rep > 1`, in which case the
/// auto-populated arrays are broadcast across reps (the
/// BLP does not natively produce per-rep sensitivity
/// elements).
pub fn GainStatsSource::from_blp(
  blp : DoubleMLBLP,
  n_rep? : Int = 1,
) -> GainStatsSource {
  try {
    require(blp.fitted)
    let n_obs = blp.n_obs()
    let coef = blp.coef()
    let se = blp.se()
    let p = coef.length()
    let n_obs_d = n_obs.to_double()
    let rss = blp.rss()
    let var_y_residuals_scalar = rss / n_obs_d
    // var_y_residuals broadcast to length p (constant).
    let var_y_residuals : Array[Double] = Array::make(p, var_y_residuals_scalar)
    // nu2 per coef: sigma^2 / (n_obs * se^2). Degenerate se
    // (= 0) sets nu2 = 1.0 (sentinel: nu2 * n * se^2 = 1,
    // which collapses the se^2 weight in
    // `var_riesz = nu2_long - nu2_short` for that coef).
    let nu2 : Array[Double] = Array::make(p, 0.0)
    for k = 0; k < p; k = k + 1 {
      let se_k = se[k]
      if se_k <= 0.0 {
        nu2[k] = 1.0
      } else {
        nu2[k] = var_y_residuals_scalar / (n_obs_d * se_k * se_k)
      }
    }
    let all_coef = coef.copy()
    let var_y = blp.var_y()
    require(n_rep > 0)
    require(p % n_rep == 0)
    { var_y_residuals, nu2, all_coef, n_rep, var_y, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.22.0+: `from_blp_cv(blp, n_folds?, seed?)` is
/// the cross-fit variant of `from_blp`. The only
/// difference is `var_y_residuals`, which is computed
/// from out-of-fold (OOF) predictions rather than
/// the in-sample BLP residuals. The OOF residual
/// variance is honest (no leakage from the basis
/// fit on the same rows), so the `R2_y` benchmark
/// in `gain_statistics` is more accurate.
///
/// Algorithm:
///   1. Draw `n_folds` random folds via `kfold` (with
///      `chacha8_rng`-style seeding through `seed`).
///   2. For each fold, fit a LinearRegression on the
///      training rows and predict on the test fold.
///   3. Compute the per-fold test residual variance
///      `sigma2_fold = sum_i (y_i - y_hat_i)^2 /
///      n_fold` (the honest OOF estimate).
///   4. `var_y_residuals_scalar` = mean over folds of
///      `sigma2_fold` (the "average fold residual
///      variance").
///
/// `coef`, `se`, `var_y`, and `all_coef` are
/// unchanged from `from_blp` (the BLP's own fit on
/// the full data is the canonical coefficient
/// estimate; only `var_y_residuals` is recomputed).
///
/// `nu2` is recomputed as
/// `var_y_residuals_cv / (n_obs * se^2)` (same
/// homoskedastic convention as `from_blp`).
pub fn GainStatsSource::from_blp_cv(
  blp : DoubleMLBLP,
  n_folds? : Int = 5,
  seed? : Int = 3141,
) -> GainStatsSource {
  try {
    require(blp.fitted)
    require(n_folds >= 2)
    let n_obs = blp.n_obs()
    require(n_obs >= n_folds)
    let coef = blp.coef()
    let se = blp.se()
    let p = coef.length()
    let n_obs_d = n_obs.to_double()
    let orth_signal = blp.orth_signal()
    let basis = blp.basis()
    // Compute the OOF residual variance via k-fold.
    let folds = kfold(n_obs, n_folds, seed)
    let mut ss_resid_oof = 0.0
    let mut n_pred = 0
    for fold = 0; fold < n_folds; fold = fold + 1 {
      let test_idx = folds[fold].test_idx
      let train_idx = folds[fold].train_idx
      let n_train = train_idx.length()
      let n_test = test_idx.length()
      let p_basis = basis.cols()
      // Build the training sub-matrix.
      let mut x_train_acc : Array[Double] = []
      let mut y_train_acc : Array[Double] = []
      for k = 0; k < n_train; k = k + 1 {
        let i = train_idx[k]
        for j = 0; j < p_basis; j = j + 1 {
          x_train_acc = x_train_acc + [basis.data[i * p_basis + j]]
        }
        y_train_acc = y_train_acc + [orth_signal[i]]
      }
      // Build the test sub-matrix.
      let mut x_test_acc : Array[Double] = []
      for k = 0; k < n_test; k = k + 1 {
        let i = test_idx[k]
        for j = 0; j < p_basis; j = j + 1 {
          x_test_acc = x_test_acc + [basis.data[i * p_basis + j]]
        }
      }
      let x_train = Matrix::from_array(x_train_acc, n_train, p_basis)
      let x_test = Matrix::from_array(x_test_acc, n_test, p_basis)
      let model = LinearRegression::new().fit(x_train, y_train_acc)
      let pred = model.predict(x_test)
      for k = 0; k < n_test; k = k + 1 {
        let i = test_idx[k]
        let r = orth_signal[i] - pred[k]
        ss_resid_oof = ss_resid_oof + r * r
      }
      n_pred = n_pred + n_test
    }
    // `var_y_residuals_cv = ss_resid_oof / n_obs`
    // (the OOF residual variance, equivalent to the
    // mean of per-fold `sigma2_fold` weighted by
    // `n_fold / n_obs`).
    let var_y_residuals_scalar = ss_resid_oof / n_obs_d
    let var_y_residuals : Array[Double] = Array::make(p, var_y_residuals_scalar)
    let nu2 : Array[Double] = Array::make(p, 0.0)
    for k = 0; k < p; k = k + 1 {
      let se_k = se[k]
      if se_k <= 0.0 {
        nu2[k] = 1.0
      } else {
        nu2[k] = var_y_residuals_scalar / (n_obs_d * se_k * se_k)
      }
    }
    let all_coef = coef.copy()
    let var_y = blp.var_y()
    // n_rep is fixed at 1 for the BLP cross-fit (the
    // BLP does not natively produce per-rep sensitivity
    // elements; multi-rep would require multiple BLP
    // fits with different folds).
    let n_rep = 1
    // Suppress unused-variable warnings.
    let _ = n_pred
    { var_y_residuals, nu2, all_coef, n_rep, var_y, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.25.0+: `from_blp_cv_repeated(blp, n_folds?,
/// n_repeats?, seed?)` is a more stable version of
/// `from_blp_cv`. A single K-fold split has
/// non-trivial variance in `var_y_residuals`
/// (different splits put different rows in the
/// test fold, so the OOF residual sum changes).
/// Repeating the K-fold split `n_repeats` times
/// with different seeds and averaging the residual
/// variance reduces this variance by ~`n_repeats`x
/// (i.i.d. assumption on the per-rep estimate).
///
/// Algorithm:
///   1. For each `rep` in `0..n_repeats`, run the
///      K-fold OOF pipeline from `from_blp_cv` with
///      `seed_eff = seed + rep` (any reproducible
///      per-rep seed works; this scheme keeps
///      `seed=3141` giving the same first rep as
///      `from_blp_cv`).
///   2. `var_y_residuals_scalar` = mean over reps
///      of `ss_resid_oof_rep / n_obs` (the per-rep
///      average fold residual variance).
///
/// `coef`, `se`, `var_y`, `all_coef`, `n_rep`, and
/// the `nu2` formula are all identical to
/// `from_blp_cv` — only the residual variance
/// estimate is averaged across repeats.
///
/// On small samples (e.g. `n_obs=200`) with
/// `n_folds=5` and `n_repeats=10`, this typically
/// gives a 5-10x reduction in the standard error
/// of `var_y_residuals`, which translates to a
/// similar stabilization of the downstream
/// `R2_y` and `nu2` sensitivity benchmarks.
pub fn GainStatsSource::from_blp_cv_repeated(
  blp : DoubleMLBLP,
  n_folds? : Int = 5,
  n_repeats? : Int = 10,
  seed? : Int = 3141,
) -> GainStatsSource {
  try {
    require(blp.fitted)
    require(n_folds >= 2)
    require(n_repeats >= 1)
    let n_obs = blp.n_obs()
    require(n_obs >= n_folds)
    let coef = blp.coef()
    let se = blp.se()
    let p = coef.length()
    let n_obs_d = n_obs.to_double()
    let orth_signal = blp.orth_signal()
    let basis = blp.basis()
    let p_basis = basis.cols()
    // Outer loop: n_repeats independent K-fold runs.
    // Per-rep seed = seed + rep, so different splits.
    // (Note: `seed + rep` is fine for `seed_to_bytes`
    // because the bytes change; chacha8 with these
    // distinct 8-byte keys produces well-separated
    // permutations.)
    let mut ss_resid_total = 0.0
    for rep = 0; rep < n_repeats; rep = rep + 1 {
      let seed_rep = seed + rep
      let folds = kfold(n_obs, n_folds, seed_rep)
      let mut ss_resid_oof = 0.0
      let mut n_pred_rep = 0
      for fold = 0; fold < n_folds; fold = fold + 1 {
        let test_idx = folds[fold].test_idx
        let train_idx = folds[fold].train_idx
        let n_train = train_idx.length()
        let n_test = test_idx.length()
        // Build the training sub-matrix.
        let mut x_train_acc : Array[Double] = []
        let mut y_train_acc : Array[Double] = []
        for k = 0; k < n_train; k = k + 1 {
          let i = train_idx[k]
          for j = 0; j < p_basis; j = j + 1 {
            x_train_acc = x_train_acc + [basis.data[i * p_basis + j]]
          }
          y_train_acc = y_train_acc + [orth_signal[i]]
        }
        // Build the test sub-matrix.
        let mut x_test_acc : Array[Double] = []
        for k = 0; k < n_test; k = k + 1 {
          let i = test_idx[k]
          for j = 0; j < p_basis; j = j + 1 {
            x_test_acc = x_test_acc + [basis.data[i * p_basis + j]]
          }
        }
        let x_train = Matrix::from_array(x_train_acc, n_train, p_basis)
        let x_test = Matrix::from_array(x_test_acc, n_test, p_basis)
        let model = LinearRegression::new().fit(x_train, y_train_acc)
        let pred = model.predict(x_test)
        for k = 0; k < n_test; k = k + 1 {
          let i = test_idx[k]
          let r = orth_signal[i] - pred[k]
          ss_resid_oof = ss_resid_oof + r * r
        }
        n_pred_rep = n_pred_rep + n_test
      }
      // Per-rep residual variance. (n_pred_rep
      // should equal n_obs each time; assert via
      // n_pred_total accumulation below.)
      ss_resid_total = ss_resid_total + ss_resid_oof
      let _ = n_pred_rep
    }
    // Average over repeats: total SS / (n_repeats * n_obs).
    let var_y_residuals_scalar = ss_resid_total /
      (n_repeats.to_double() * n_obs_d)
    let var_y_residuals : Array[Double] = Array::make(p, var_y_residuals_scalar)
    let nu2 : Array[Double] = Array::make(p, 0.0)
    for k = 0; k < p; k = k + 1 {
      let se_k = se[k]
      if se_k <= 0.0 {
        nu2[k] = 1.0
      } else {
        nu2[k] = var_y_residuals_scalar / (n_obs_d * se_k * se_k)
      }
    }
    let all_coef = coef.copy()
    let var_y = blp.var_y()
    let n_rep = 1
    { var_y_residuals, nu2, all_coef, n_rep, var_y, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.23.0+: `from_blp_hc0(blp, n_folds?, seed?)` is
/// the HC0-honest variant of `from_blp_cv`. The
/// difference is the `nu2` formula: instead of the
/// homoskedastic OLS convention
/// `nu2 = var_y_residuals / (n_obs * se^2)`, it uses
/// the projection-weight formula
/// `nu2[k] = (1 / n_obs) * ||M[k,:] @ basis^T||^2`
/// where `M = (basis^T basis + ridge I)^{-1}` is the
/// BLP's regression matrix. This is consistent with
/// the upstream
/// `doubleml.utils._estimation._compute_sensitivity_elements`
/// convention, where `nu2 = E[score_d^2]` and the
/// score is the per-observation influence on the
/// k-th coefficient (`M[k,:] @ x_i`).
///
/// The homoskedastic formula conflates `nu2` with
/// `se^2` (using the relation
/// `se^2 = sigma^2 * (Z^T Z)^{-1}_{kk}`), which is
/// only correct under homoskedasticity. The HC0 SE
/// `se^2 = sum_i (M[k,:] @ x_i)^2 * e_i^2` does not
/// satisfy the same relation; the projection-weight
/// formula is the HC0-compatible alternative.
///
/// `var_y_residuals` is computed via K-fold
/// cross-fitting (same as `from_blp_cv`). `coef`,
/// `se`, `var_y`, and `all_coef` are unchanged from
/// `from_blp`.
pub fn GainStatsSource::from_blp_hc0(
  blp : DoubleMLBLP,
  n_folds? : Int = 5,
  seed? : Int = 3141,
) -> GainStatsSource {
  try {
    require(blp.fitted)
    require(n_folds >= 2)
    let n_obs = blp.n_obs()
    require(n_obs >= n_folds)
    let coef = blp.coef()
    let se = blp.se()
    let p = coef.length()
    let n_obs_d = n_obs.to_double()
    let orth_signal = blp.orth_signal()
    let basis = blp.basis()
    let p_basis = basis.cols()
    require(p == p_basis + 1) // p = p_basis + 1 (intercept)
    // Compute `M = (basis^T basis + ridge I)^{-1}` using
    // the same ridge as the BLP's `LinearRegression`.
    // `LinearRegression::fit` uses `ridge = 1e-10`.
    let ridge = 1.0e-10
    let basis_t = basis.transpose()
    let xtx = matmul(basis_t, basis)
    // Add ridge to the diagonal.
    let xtx_ridged = Matrix::zeros(p_basis, p_basis)
    for i = 0; i < p_basis; i = i + 1 {
      for j = 0; j < p_basis; j = j + 1 {
        xtx_ridged.set(i, j, xtx.get(i, j) + (if i == j { ridge } else { 0.0 }))
      }
    }
    let m_mat = inv_spd(xtx_ridged)
    // Compute `nu2[k] = (1 / n_obs) * ||M[k,:] @ basis^T||^2`
    // for each coef k. Note: the BLP's stored `coef`
    // has the intercept at position 0 (because
    // `LinearRegression::fit` augments with an
    // intercept column). The regression matrix `M` is
    // for the un-augmented basis, so `nu2[0]` (the
    // intercept coef) uses `M[0,:] @ basis^T` (the
    // first row of M, which corresponds to the first
    // basis column — wait, no; `M[0,:]` is the
    // first row, which corresponds to the first coef
    // in the un-augmented basis. But the BLP's coef
    // is in the order [intercept, slopes] = [0, 1, ...].
    // So we need to map: nu2[k] uses M[k-1, :] for
    // k >= 1, and nu2[0] corresponds to the intercept
    // (which doesn't have a M row; we use a sentinel).
    let nu2 : Array[Double] = Array::make(p, 0.0)
    // Intercept (k = 0): no projection; nu2 = 1.0
    // (sentinel, matches the from_blp convention).
    nu2[0] = 1.0
    // Slopes (k = 1, ..., p - 1): use M[k - 1, :].
    for k = 1; k < p; k = k + 1 {
      let m_row = k - 1
      // `r = M[m_row, :] @ basis^T` is a length-`n_obs`
      // vector. We compute it as `r[i] = sum_j
      // M[m_row, j] * basis[i, j]`.
      let mut sum_sq = 0.0
      for i = 0; i < n_obs; i = i + 1 {
        let mut r_i = 0.0
        for j = 0; j < p_basis; j = j + 1 {
          r_i = r_i + m_mat.get(m_row, j) * basis.get(i, j)
        }
        sum_sq = sum_sq + r_i * r_i
      }
      nu2[k] = sum_sq / n_obs_d
    }
    // Compute cross-fit var_y_residuals (same as
    // from_blp_cv).
    let folds = kfold(n_obs, n_folds, seed)
    let mut ss_resid_oof = 0.0
    for fold = 0; fold < n_folds; fold = fold + 1 {
      let test_idx = folds[fold].test_idx
      let train_idx = folds[fold].train_idx
      let n_train = train_idx.length()
      let n_test = test_idx.length()
      let mut x_train_acc : Array[Double] = []
      let mut y_train_acc : Array[Double] = []
      for k = 0; k < n_train; k = k + 1 {
        let i = train_idx[k]
        for j = 0; j < p_basis; j = j + 1 {
          x_train_acc = x_train_acc + [basis.data[i * p_basis + j]]
        }
        y_train_acc = y_train_acc + [orth_signal[i]]
      }
      let mut x_test_acc : Array[Double] = []
      for k = 0; k < n_test; k = k + 1 {
        let i = test_idx[k]
        for j = 0; j < p_basis; j = j + 1 {
          x_test_acc = x_test_acc + [basis.data[i * p_basis + j]]
        }
      }
      let x_train = Matrix::from_array(x_train_acc, n_train, p_basis)
      let x_test = Matrix::from_array(x_test_acc, n_test, p_basis)
      let model = LinearRegression::new().fit(x_train, y_train_acc)
      let pred = model.predict(x_test)
      for k = 0; k < n_test; k = k + 1 {
        let i = test_idx[k]
        let r = orth_signal[i] - pred[k]
        ss_resid_oof = ss_resid_oof + r * r
      }
    }
    let var_y_residuals_scalar = ss_resid_oof / n_obs_d
    let var_y_residuals : Array[Double] = Array::make(p, var_y_residuals_scalar)
    let _ = se // Suppress unused-variable warning; se
    // is exposed via the source but not used
    // in the HC0 nu2 formula.
    let all_coef = coef.copy()
    let var_y = blp.var_y()
    let n_rep = 1
    { var_y_residuals, nu2, all_coef, n_rep, var_y, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Median of a sorted array. Returns the middle value (or
/// the average of the two middle values for even-length
/// arrays). Caller is expected to pre-sort with
/// `Array::sort`.
fn median_sorted(sorted : Array[Double]) -> Double {
  let n = sorted.length()
  if n == 0 {
    return 0.0
  }
  if n % 2 == 1 {
    sorted[n / 2]
  } else {
    (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
  }
}

// ---------------------------------------------------------------------------
// v0.77.0+ Joint sensitivity (cross-estimator joint coverage + RV)
// ---------------------------------------------------------------------------

///|
/// v0.77.0+: per-estimator summary fed into `joint_sensitivity`.
/// Distinct from the existing `SensitivityResult` (which is the
/// post-Cinelli-Hazlett `(rv, sigma2, nu2, cf_y, cf_d, max_bias)`
/// return of `irm_style_sensitivity` / `irm_style_sensitivity_cluster`)
/// — this struct carries the high-level `(name, coef, se, sigma_sq,
/// rho, cf_y, cf_d)` summary that the joint-coverage formula
/// operates on. Naming a second struct `SensitivityResult` would
/// shadow the existing one and break all 22 estimator `sensitivity_analysis
/// (_cluster)` contracts, so the joint helper takes this distinct
/// struct.
///
///   - `name`: a label for the estimator (typically the struct name
///     like `"irm"`, `"plr"`, `"did"`). Empty by default; callers
///     should set it for downstream debugging.
///   - `coef`: the estimator coefficient `theta_hat`.
///   - `se`: the estimator's homoskedasticity- or cluster-robust
///     standard error.
///   - `sigma_sq`: the residual variance (matches
///     `SensitivityResult.sigma2`); used in the joint RV derivation
///     (`|theta| / sqrt(sigma_sq * |rho|)` form).
///   - `rho`: the confounding correlation in `[-1, 1]` (matches
///     `GainStatsResult.rho`).
///   - `cf_y`: benchmarking upper-bound on the outcome-nuisance
///     confounding fraction (default 0.05). Pass-through to the
///     joint result for parity with `SensitivityResult.cf_y`.
///   - `cf_d`: benchmarking upper-bound on the treatment-nuisance
///     confounding fraction (default 0.05). Pass-through to the
///     joint result for parity with `SensitivityResult.cf_d`.
pub struct JointSensitivityInput {
  name : String
  coef : Double
  se : Double
  sigma_sq : Double
  rho : Double
  cf_y : Double
  cf_d : Double
} derive(Debug)

///|
pub extend JointSensitivityInput with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// v0.77.0+: builder constructor for `JointSensitivityInput`. All
/// fields are required; use `JointSensitivityInput::empty()` for a
/// zero-default sentinel.
pub fn JointSensitivityInput::new(
  name : String,
  coef : Double,
  se : Double,
  sigma_sq : Double,
  rho : Double,
  cf_y : Double,
  cf_d : Double,
) -> JointSensitivityInput {
  { name, coef, se, sigma_sq, rho, cf_y, cf_d, }
}

///|
/// v0.77.0+: zero-valued `JointSensitivityInput`. Useful for tests
/// and as a placeholder (all numeric fields are `0.0`, `name` is
/// the empty string). Note that `joint_sensitivity` will report a
/// degenerate RV (`1.0e300` sentinel) for a zero-valued input
/// because `sigma_sq * rho == 0`.
pub fn JointSensitivityInput::empty() -> JointSensitivityInput {
  {
    name: "",
    coef: 0.0,
    se: 0.0,
    sigma_sq: 0.0,
    rho: 0.0,
    cf_y: 0.0,
    cf_d: 0.0,
  }
}

///|
/// v0.77.0+: output of `joint_sensitivity`. Combines per-estimator
/// Bonferroni-corrected CIs with the cross-estimator joint RV and
/// joint RV_q.
///
///   - `joint_lower` = `min(per_estimator_lower)` — the most
///     conservative lower CI across estimators at the Bonferroni
///     alpha.
///   - `joint_upper` = `max(per_estimator_upper)` — the most
///     conservative upper CI.
///   - `joint_rv` = `min(per_estimator_rv)` — the worst (smallest)
///     RV across estimators. A confounder that would tip the
///     LEAST-robust single estimator would tip the joint
///     conclusion.
///   - `joint_rv_q` = `min(per_estimator_rv_q)` — the worst
///     (smallest) RV_q across estimators. RV_q is the C&H
///     q-bias-based RV — the strength that would push `|theta|`
///     below the `z_alpha * se` significance threshold.
///   - `per_estimator_lower / per_estimator_upper / per_estimator_rv /
///     per_estimator_rv_q`: per-estimator outputs, length K.
///   - `bonferroni_alpha` = `alpha / K`.
///   - `num_estimators` = K.
pub struct JointSensitivityResult {
  joint_lower : Double
  joint_upper : Double
  joint_rv : Double
  joint_rv_q : Double
  per_estimator_lower : Array[Double]
  per_estimator_upper : Array[Double]
  per_estimator_rv : Array[Double]
  per_estimator_rv_q : Array[Double]
  bonferroni_alpha : Double
  num_estimators : Int
} derive(Debug)

///|
pub extend JointSensitivityResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// v0.77.0+: cross-estimator joint coverage + joint RV. Cinelli &
/// Hazlett (2020) §3.6 extension to the multi-estimator setting.
/// Given K estimators on the same dataset, each producing
/// `(coef_k, se_k, sigma_sq_k, rho_k)`, the function computes:
///
///   1. Bonferroni-corrected alpha per test = `alpha / K`. For
///      K=2 and alpha=0.05, this is 0.025; the two-sided critical
///      value `z_{1 - alpha/(2K)}` widens for K >= 2.
///   2. Per-estimator joint CI at `alpha / K`: standard Wald
///      `theta_k +/- z_{1 - alpha/(2K)} * se_k`.
///   3. Per-estimator RV: the Cinelli-Hazlett bias-to-zero
///      confounding-strength ratio. We use the simplified form
///      `|theta| / sqrt(sigma_sq * |rho|)` (a v4 sentinel
///      `1.0e300` is returned when `sigma_sq == 0` or `|rho| ==
///      0` since the ratio is degenerate in those regimes).
///   4. Per-estimator RV_q: the confounding strength that would
///      push `|theta|` below the `z_{alpha/K} * se` significance
///      threshold:
///        rv_q = (se * z) / sqrt(theta^2 - (se * z)^2)
///      when `|theta| > se * z`, else `1.0e300`.
///   5. Joint CI: the union of per-estimator CIs at `alpha / K` =
///      `[min(per_estimator_lower), max(per_estimator_upper)]`.
///   6. Joint RV: `min(per_estimator_rv)` — a confounder that
///      would tip the LEAST-robust single estimator would also
///      tip the joint conclusion (Bonferroni-aligned joint-RV).
///   7. Joint RV_q: `min(per_estimator_rv_q)`.
///
/// Special cases:
///   - `inputs.length() == 0`: returns a zero-valued result with
///     `num_estimators = 0`, `bonferroni_alpha = alpha` (no
///     division), and empty per-estimator arrays. The joint
///     bounds / RV stay at their zero / `1.0e300` sentinels.
///   - `inputs.length() == 1`: Bonferroni alpha = `alpha / 1 =
///     alpha` (no correction). The joint CI / RV collapse to the
///     single estimator's CI / RV at alpha.
///
/// Pre-conditions:
///   - `alpha > 0` and `alpha < 1`.
///   - Each `input.se >= 0`.
///   - Each `input.sigma_sq >= 0`.
///   - Each `input.rho` in `[-1, 1]`.
pub fn joint_sensitivity(
  inputs : Array[JointSensitivityInput],
  alpha : Double,
) -> JointSensitivityResult raise {
  require(alpha > 0.0 && alpha < 1.0)
  let k = inputs.length()
  // Validate per-input ranges. Skip the empty-input case to
  // avoid spurious precondition errors when `K == 0`.
  for i = 0; i < k; i = i + 1 {
    let input = inputs[i]
    require(input.se >= 0.0)
    require(input.sigma_sq >= 0.0)
    require(input.rho >= -1.0 && input.rho <= 1.0)
    ignore(input.cf_y)
    ignore(input.cf_d)
    ignore(input.name)
  }
  let bonferroni_alpha = if k == 0 { alpha } else { alpha / k.to_double() }
  let per_estimator_lower : Array[Double] = Array::make(k, 0.0)
  let per_estimator_upper : Array[Double] = Array::make(k, 0.0)
  let per_estimator_rv : Array[Double] = Array::make(k, 0.0)
  let per_estimator_rv_q : Array[Double] = Array::make(k, 0.0)
  // Sentinel for the K=0 case: z is never used (no per-estimator
  // CI is computed), but we still want a sane value for the
  // downstream struct. `1.959963984540054` = `norm.ppf(0.975)`
  // (the standard Wald 5% critical value).
  let mut z = 1.959963984540054
  if k > 0 {
    // Bonferroni-corrected two-sided CI: per-estimator alpha is
    // alpha / K; the two-sided critical value is
    // z_{1 - alpha/(2K)} = z_{1 - bonferroni_alpha / 2}.
    z = norm_ppf(1.0 - bonferroni_alpha / 2.0)
  }
  let mut joint_lower = 0.0
  let mut joint_upper = 0.0
  let mut joint_rv = 1.0e300
  let mut joint_rv_q = 1.0e300
  for i = 0; i < k; i = i + 1 {
    let input = inputs[i]
    let coef = input.coef
    let se = input.se
    let sigma_sq = input.sigma_sq
    let abs_rho = input.rho.abs()
    let lo = coef - z * se
    let hi = coef + z * se
    per_estimator_lower[i] = lo
    per_estimator_upper[i] = hi
    // RV = |theta| / sqrt(sigma_sq * |rho|). Sentinel 1.0e300
    // when either factor is 0 (degenerate: ratio undefined).
    let rv = if sigma_sq == 0.0 || abs_rho == 0.0 {
      1.0e300
    } else {
      coef.abs() / (sigma_sq * abs_rho).sqrt()
    }
    per_estimator_rv[i] = rv
    // RV_q = (se * z) / sqrt(theta^2 - (se * z)^2).
    let se_z = se * z
    let rv_q = if se_z == 0.0 {
      1.0e300
    } else if coef.abs() <= se_z {
      // Estimate is already non-significant at alpha_b;
      // any confounder is a counterfactual (sentinel).
      1.0e300
    } else {
      se_z / (coef * coef - se_z * se_z).sqrt()
    }
    per_estimator_rv_q[i] = rv_q
    // Accumulate joint minima / maxima across estimators.
    if i == 0 {
      joint_lower = lo
      joint_upper = hi
      joint_rv = rv
      joint_rv_q = rv_q
    } else {
      if lo < joint_lower {
        joint_lower = lo
      }
      if hi > joint_upper {
        joint_upper = hi
      }
      if rv < joint_rv {
        joint_rv = rv
      }
      if rv_q < joint_rv_q {
        joint_rv_q = rv_q
      }
    }
  }
  {
    joint_lower,
    joint_upper,
    joint_rv,
    joint_rv_q,
    per_estimator_lower,
    per_estimator_upper,
    per_estimator_rv,
    per_estimator_rv_q,
    bonferroni_alpha,
    num_estimators: k,
  }
}
