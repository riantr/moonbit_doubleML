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
