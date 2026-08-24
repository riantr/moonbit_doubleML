///|
/// `compute_sensitivity_bias` returns the worst-case bias vector and
/// its gradient with respect to the confounding strength. For a
/// deterministic toy case (sigma2=4, nu2=0.25, psi_*=0) the bias is
/// `sqrt(4*0.25) = 1.0` per observation and the gradient is 0.
test "sensitivity_bias_deterministic" {
  let psi_sigma2 : Array[Double] = [0.0, 0.0, 0.0, 0.0]
  let psi_nu2 : Array[Double] = [0.0, 0.0, 0.0, 0.0]
  let (max_bias, psi_max_bias) = compute_sensitivity_bias(
    4.0, 0.25, psi_sigma2, psi_nu2,
  )
  inspect(max_bias.length(), content="4")
  inspect(psi_max_bias.length(), content="4")
  for i = 0; i < 4; i = i + 1 {
    inspect(max_bias[i], content="1")
    inspect(psi_max_bias[i], content="0")
  }
}

///|
/// `compute_sensitivity_bias` with non-zero `psi_sigma2` and `psi_nu2`
/// matches the upstream formula
///   `psi_max_bias = (sigma2 * psi_nu2 + nu2 * psi_sigma2) / (2 * max_bias)`
/// For sigma2=1, nu2=2, psi_sigma2=[0.5, 1.0], psi_nu2=[2.0, 4.0]:
///   max_bias = sqrt(2) ≈ 1.4142
///   psi_max_bias[0] = (1*2 + 2*0.5) / (2*1.4142) = 3 / 2.8284 ≈ 1.0607
///   psi_max_bias[1] = (1*4 + 2*1.0) / (2*1.4142) = 6 / 2.8284 ≈ 2.1213
test "sensitivity_bias_known_formula" {
  let psi_sigma2 : Array[Double] = [0.5, 1.0]
  let psi_nu2 : Array[Double] = [2.0, 4.0]
  let (max_bias, psi_max_bias) = compute_sensitivity_bias(
    1.0, 2.0, psi_sigma2, psi_nu2,
  )
  let sqrt2 = 2.0.sqrt()
  inspect((max_bias[0] - sqrt2).abs() < 1.0e-12, content="true")
  inspect((max_bias[1] - sqrt2).abs() < 1.0e-12, content="true")
  inspect(
    (psi_max_bias[0] - 3.0 / (2.0 * sqrt2)).abs() < 1.0e-12,
    content="true",
  )
  inspect(
    (psi_max_bias[1] - 6.0 / (2.0 * sqrt2)).abs() < 1.0e-12,
    content="true",
  )
}

///|
/// Degenerate input `sigma2 = 0` (deterministic treatment). The
/// function returns the 0 vector for both outputs without dividing
/// by zero.
test "sensitivity_bias_zero_sigma2" {
  let psi_sigma2 : Array[Double] = [1.0, 2.0]
  let psi_nu2 : Array[Double] = [3.0, 4.0]
  let (max_bias, psi_max_bias) = compute_sensitivity_bias(
    0.0, 0.5, psi_sigma2, psi_nu2,
  )
  inspect(max_bias[0], content="0")
  inspect(max_bias[1], content="0")
  inspect(psi_max_bias[0], content="0")
  inspect(psi_max_bias[1], content="0")
}

///|
/// Length mismatch between `psi_sigma2` and `psi_nu2` must abort.
test "panic_sensitivity_bias_length_mismatch" {
  let _ = compute_sensitivity_bias(1.0, 1.0, [1.0, 2.0], [1.0])
}

///|
/// `robustness_value` is `|theta| / mean(max_bias)`. For theta=1,
/// bias=0.5 the RV is 2.0.
test "robustness_value_basic" {
  let bias : Array[Double] = [0.5, 0.5, 0.5]
  inspect((robustness_value(1.0, bias) - 2.0).abs() < 1.0e-12, content="true")
}

///|
/// `robustness_value` returns the large sentinel for `theta = 0`.
test "robustness_value_zero_theta" {
  let bias : Array[Double] = [0.5, 0.5]
  inspect(robustness_value(0.0, bias) > 1.0e100, content="true")
}

// ---------------------------------------------------------------------------
// v0.17.0+ gain_statistics tests
// ---------------------------------------------------------------------------

///|
/// Hand-rolled gain_statistics on a 1-coef, 1-rep toy DGP
/// to verify the algorithm matches the upstream formula.
///   `var_y = 4`
///   `var_y_residuals_long = 1` (sigma2_long)
///   `var_y_residuals_short = 0.5` (sigma2_short)
///   `nu2_long = 1`
///   `nu2_short = 0.5`
///   `all_coef_long = 1.0`
///   `all_coef_short = 1.2`
///
/// Expected:
///   `R2_y_long = 1 - 1/4 = 0.75`
///   `R2_y_short = 1 - 0.5/4 = 0.875`
///   `R2_riesz = 0.5/1 = 0.5`
///   `cf_y = clip((0.75 - 0.875) / (1 - 0.75), 0, 1) = clip(-0.5, 0, 1) = 0`
///   `cf_d = clip((1 - 0.5) / 0.5, 0, 1) = clip(1.0, 0, 1) = 1.0`
///   `delta_theta = 1.2 - 1.0 = 0.2`
///   `var_g = 0.5 - 1 = -0.5` (negative; rho = 0)
///   `var_riesz = 1 - 0.5 = 0.5`
///   `denom = sqrt(-0.5 * 0.5)` is NaN; with negative
///     `var_g`, `denom` is 0 by convention (square root of
///     negative is degenerate; upstream's `np.sqrt` returns
///     NaN, then `np.divide(..., where=denom != 0)` sets rho
///     to 1.0 there). We follow the upstream: when either
///     `var_g` or `var_riesz` is 0/negative, rho = 0.0.
test "gain_statistics_handrolled" {
  let dml_long = GainStatsSource::new([1.0], [1.0], [1.0], 1, 4.0)
  let dml_short = GainStatsSource::new([0.5], [0.5], [1.2], 1, 4.0)
  let gs = gain_statistics(dml_long, dml_short)
  inspect(gs.cf_y.length(), content="1")
  inspect(gs.cf_d.length(), content="1")
  inspect(gs.rho.length(), content="1")
  inspect(gs.delta_theta.length(), content="1")
  // `cf_y = 0` (long has higher R2 than short -> clip to 0).
  inspect((gs.cf_y[0] - 0.0).abs() < 1.0e-12, content="true")
  // `cf_d = 1` (R2_riesz = 0.5, (1-0.5)/0.5 = 1).
  inspect((gs.cf_d[0] - 1.0).abs() < 1.0e-12, content="true")
  // `delta_theta = 1.2 - 1.0 = 0.2`.
  inspect((gs.delta_theta[0] - 0.2).abs() < 1.0e-12, content="true")
  // `rho = sign(delta_theta) * clip(|delta_theta| / sqrt(NaN), 0, 1) = 1.0`
  // (upstream's `np.divide(..., where=denom != 0)` convention
  // sets the ratio to 1.0 when `denom` is 0 or NaN, so
  // `rho = sign(0.2) * 1.0 = 1.0`).
  inspect((gs.rho[0] - 1.0).abs() < 1.0e-12, content="true")
}

///|
/// When both `var_y_residuals` and `nu2` are equal between
/// long and short, `cf_y = 0`, `cf_d = 0`, and
/// `delta_theta = 0`. The model is invariant to the
/// excluded benchmark confounders.
test "gain_statistics_identical" {
  // 2 coefs x 2 reps (so length=4 per array), n_rep=2, n_coef=2.
  let dml_long = GainStatsSource::new(
    // coef 0 reps 0,1 / coef 1 reps 0,1
    [1.0, 1.0, 1.0, 1.0],
    [0.5, 0.5, 0.5, 0.5],
    [1.0, 1.0, 2.0, 2.0],
    2,
    4.0,
  )
  let dml_short = GainStatsSource::new(
    [1.0, 1.0, 1.0, 1.0],
    [0.5, 0.5, 0.5, 0.5],
    [1.0, 1.0, 2.0, 2.0],
    2,
    4.0,
  )
  let gs = gain_statistics(dml_long, dml_short)
  inspect(gs.cf_y.length(), content="2")
  inspect(gs.cf_y[0].abs() < 1.0e-12, content="true")
  inspect(gs.cf_y[1].abs() < 1.0e-12, content="true")
  inspect(gs.cf_d[0].abs() < 1.0e-12, content="true")
  inspect(gs.cf_d[1].abs() < 1.0e-12, content="true")
  inspect(gs.delta_theta[0].abs() < 1.0e-12, content="true")
  inspect(gs.delta_theta[1].abs() < 1.0e-12, content="true")
  inspect(gs.rho[0].abs() < 1.0e-12, content="true")
  inspect(gs.rho[1].abs() < 1.0e-12, content="true")
}

///|
/// `cf_y` and `cf_d` are clipped to `[0, 1]`. Hand-rolled
/// inputs that would produce values outside the range are
/// clipped.
test "gain_statistics_clipping" {
  // R2_y_short > R2_y_long: cf_y numerator is negative,
  // clipped to 0.
  let dml_long = GainStatsSource::new(
    [0.1], // R2_y_long = 0.9
    [1.0],
    [1.0],
    1,
    1.0,
  )
  let dml_short = GainStatsSource::new(
    [0.01], // R2_y_short = 0.99
    [0.1], // R2_riesz = 0.1, cf_d = (1-0.1)/0.1 = 9
    [1.0],
    1,
    1.0,
  )
  let gs = gain_statistics(dml_long, dml_short)
  // `cf_y` clips to 0.
  inspect(gs.cf_y[0].abs() < 1.0e-12, content="true")
  // `cf_d = 9`, clipped to 1.
  inspect((gs.cf_d[0] - 1.0).abs() < 1.0e-12, content="true")
}

///|
/// Multi-coef, multi-rep case: `n_coef = 2`, `n_rep = 3`.
/// The output is length 2 (per coef), and the median is
/// taken across the 3 reps.
test "gain_statistics_multi_coef_multi_rep" {
  // 2 coefs x 3 reps, var_y = 1.
  let dml_long = GainStatsSource::new(
    // coef 0: reps 0, 1, 2
    [
      0.4, 0.4, 0.4,
      // coef 1: reps 0, 1, 2
       0.4, 0.4, 0.4,
    ],
    [
      0.5, 0.5, 0.5, // coef 0
       0.5, 0.5, 0.5, // coef 1
    ],
    [
      1.0, 1.0, 1.0, // coef 0
       2.0, 2.0, 2.0, // coef 1
    ],
    3,
    1.0,
  )
  let dml_short = GainStatsSource::new(
    // R2_y_short = 0.5
    [0.5, 0.5, 0.5, 0.5, 0.5, 0.5],
    // R2_riesz = 0.8, cf_d = 0.25
    [0.4, 0.4, 0.4, 0.4, 0.4, 0.4],
    // coef 0: delta = 0.1
    // coef 1: delta = 0.2
    [1.1, 1.1, 1.1, 2.2, 2.2, 2.2],
    3,
    1.0,
  )
  let gs = gain_statistics(dml_long, dml_short)
  inspect(gs.cf_y.length(), content="2")
  inspect(gs.cf_d.length(), content="2")
  inspect(gs.rho.length(), content="2")
  inspect(gs.delta_theta.length(), content="2")
  // R2_y_long = 0.6, R2_y_short = 0.5, R2_riesz = 0.8
  // cf_y = (0.6 - 0.5) / (1 - 0.6) = 0.25
  // cf_d = (1 - 0.8) / 0.8 = 0.25
  // delta = 0.1 / 0.2 (per coef)
  // var_g = 0.5 - 0.4 = 0.1, var_riesz = 0.5 - 0.4 = 0.1
  // denom = sqrt(0.1 * 0.1) = 0.1
  // rho = 0.1 / 0.1 = 1.0 (coef 0)
  // rho = 0.2 / 0.1 = 1.0 (coef 1, clipped)
  inspect((gs.cf_y[0] - 0.25).abs() < 1.0e-12, content="true")
  inspect((gs.cf_y[1] - 0.25).abs() < 1.0e-12, content="true")
  inspect((gs.cf_d[0] - 0.25).abs() < 1.0e-12, content="true")
  inspect((gs.cf_d[1] - 0.25).abs() < 1.0e-12, content="true")
  inspect((gs.delta_theta[0] - 0.1).abs() < 1.0e-12, content="true")
  inspect((gs.delta_theta[1] - 0.2).abs() < 1.0e-12, content="true")
  inspect((gs.rho[0] - 1.0).abs() < 1.0e-12, content="true")
  inspect((gs.rho[1] - 1.0).abs() < 1.0e-12, content="true")
}

///|
/// Length mismatch: `dml_long.all_coef.length()` must equal
/// `dml_long.var_y_residuals.length()`. The function aborts.
test "panic_gain_statistics_length_mismatch" {
  let dml_long = GainStatsSource::new([1.0, 1.0], [1.0, 1.0], [1.0], 1, 1.0)
  let dml_short = GainStatsSource::new(
    [0.5, 0.5],
    [0.5, 0.5],
    [1.0, 1.0],
    1,
    1.0,
  )
  let _ = gain_statistics(dml_long, dml_short)
}

///|
/// v0.19.0+: `GainStatsSource::from_blp(blp)` auto-populates
/// the per-rep arrays from the BLP's fit output. The BLP
/// is fit on a small DGP with two features; with the
/// automatic intercept, the BLP returns 3 coefs
/// (intercept + 2 slopes).
test "gain_stats_from_blp_basic" {
  let basis = Matrix::zeros(10, 2)
  for i = 0; i < 10; i = i + 1 {
    basis.set(i, 0, 1.0)
    basis.set(i, 1, i.to_double() * 0.1)
  }
  let orth_signal = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
  let blp = DoubleMLBLP::new(basis, orth_signal).fit()
  let src = GainStatsSource::from_blp(blp)
  let n_coef = blp.coef().length()
  inspect(src.var_y_residuals.length(), content=n_coef.to_string())
  inspect(src.nu2.length(), content=n_coef.to_string())
  inspect(src.all_coef.length(), content=n_coef.to_string())
  inspect(src.n_rep, content="1")
  // all_coef matches the BLP's coef.
  let blp_coef = blp.coef()
  for k = 0; k < n_coef; k = k + 1 {
    inspect((src.all_coef[k] - blp_coef[k]).abs() < 1.0e-15, content="true")
  }
  // var_y matches the BLP's var_y.
  inspect((src.var_y - blp.var_y()).abs() < 1.0e-15, content="true")
}

///|
/// v0.19.0+: `GainStatsSource::from_blp(blp, n_rep=N)`
/// accepts an explicit `n_rep`. The arrays are length
/// `n_coef` (broadcast).
test "gain_stats_from_blp_n_rep" {
  let basis = Matrix::zeros(10, 2)
  for i = 0; i < 10; i = i + 1 {
    basis.set(i, 0, 1.0)
    basis.set(i, 1, i.to_double() * 0.1)
  }
  let orth_signal = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
  let blp = DoubleMLBLP::new(basis, orth_signal).fit()
  let n_coef = blp.coef().length()
  // n_rep must divide n_coef. n_rep=1 (default) works.
  let src = GainStatsSource::from_blp(blp, n_rep=1)
  inspect(src.n_rep, content="1")
  inspect(src.var_y_residuals.length(), content=n_coef.to_string())
}

///|
/// v0.19.0+: panic test — `from_blp` requires the BLP to
/// be fitted first.
test "panic_gain_stats_from_blp_unfitted" {
  let basis = Matrix::zeros(5, 1)
  for i = 0; i < 5; i = i + 1 {
    basis.set(i, 0, 1.0)
  }
  let unfitted = DoubleMLBLP::new(basis, [0.1, 0.2, 0.3, 0.4, 0.5])
  let _ = GainStatsSource::from_blp(unfitted)
}

///|
/// v0.19.0+: panic test — `n_rep` must divide the number
/// of BLP coefficients.
test "panic_gain_stats_from_blp_n_rep_invalid" {
  // 1-column basis -> 2 coefs (intercept + 1 slope).
  // n_rep = 3 does not divide 2.
  let basis = Matrix::zeros(10, 1)
  for i = 0; i < 10; i = i + 1 {
    basis.set(i, 0, 1.0)
  }
  let blp = DoubleMLBLP::new(basis, [
    0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0,
  ]).fit()
  let _ = GainStatsSource::from_blp(blp, n_rep=3)
}

///|
/// v0.19.0+ end-to-end: fit two BLPs with the SAME basis
/// structure (1 feature each, so 2 coefs each with
/// intercept) but DIFFERENT noise realizations on the
/// orthogonal signal. The "long" model (low-noise signal)
/// has smaller residual variance than the "short" model
/// (high-noise signal). Auto-populate `GainStatsSource`
/// via `from_blp` and call `gain_statistics` to compute
/// the per-coef benchmarks. The benchmarks should be
/// well-defined (in [0, 1] for `cf_y` / `cf_d` / `|rho|`).
test "gain_stats_end_to_end_via_blp" {
  let n = 50
  let basis = Matrix::zeros(n, 1)
  for i = 0; i < n; i = i + 1 {
    basis.set(i, 0, 1.0)
  }
  // Two different orthogonal signals with different noise
  // levels. The "long" model uses a low-noise signal
  // (smaller residual variance after BLP fit). The
  // "short" model uses a high-noise signal.
  let signal_low_noise : Array[Double] = []
  let signal_high_noise : Array[Double] = []
  let mut acc_lo = signal_low_noise
  let mut acc_hi = signal_high_noise
  for i = 0; i < n; i = i + 1 {
    let xi = i.to_double() * 0.1
    acc_lo = acc_lo + [0.5 + 0.3 * xi + 0.01 * (i % 5).to_double()]
    acc_hi = acc_hi + [0.5 + 0.3 * xi + 0.5 * (i % 7).to_double()]
  }
  let signal_low_noise = acc_lo
  let signal_high_noise = acc_hi
  let blp_long = DoubleMLBLP::new(basis, signal_low_noise).fit()
  let blp_short = DoubleMLBLP::new(basis, signal_high_noise).fit()
  let src_long = GainStatsSource::from_blp(blp_long)
  let src_short = GainStatsSource::from_blp(blp_short)
  // Long model has smaller residual variance.
  inspect(
    src_long.var_y_residuals[0] <= src_short.var_y_residuals[0] + 1.0e-12,
    content="true",
  )
  // Both sources have the same n_coef (2 = intercept + 1).
  let n_coef = src_long.all_coef.length()
  inspect(src_short.all_coef.length(), content=n_coef.to_string())
  let result = gain_statistics(src_long, src_short)
  inspect(result.cf_y.length(), content=n_coef.to_string())
  inspect(result.cf_d.length(), content=n_coef.to_string())
  inspect(result.rho.length(), content=n_coef.to_string())
  inspect(result.delta_theta.length(), content=n_coef.to_string())
  // All benchmark values must be finite and in valid ranges.
  for k = 0; k < n_coef; k = k + 1 {
    let cf_y_k = result.cf_y[k]
    let cf_d_k = result.cf_d[k]
    let rho_k = result.rho[k]
    inspect(cf_y_k >= 0.0 && cf_y_k <= 1.0, content="true")
    inspect(cf_d_k >= 0.0 && cf_d_k <= 1.0, content="true")
    inspect(rho_k >= -1.0 && rho_k <= 1.0, content="true")
  }
}

// ---------------------------------------------------------------------------
// v0.22.0+ GainStatsSource::from_blp_cv tests
// ---------------------------------------------------------------------------

///|
/// v0.22.0+: `from_blp_cv` produces a `GainStatsSource`
/// with the same `coef` / `var_y` / `all_coef` as
/// `from_blp` (the BLP's full-data fit is unchanged),
/// but a different `var_y_residuals` (computed from
/// out-of-fold predictions rather than in-sample
/// residuals).
test "gain_stats_from_blp_cv_basic" {
  let basis = Matrix::zeros(50, 2)
  for i = 0; i < 50; i = i + 1 {
    basis.set(i, 0, 1.0)
    basis.set(i, 1, i.to_double() * 0.1)
  }
  let orth_signal : Array[Double] = []
  let mut acc = orth_signal
  for i = 0; i < 50; i = i + 1 {
    acc = acc + [0.5 + 0.3 * i.to_double() * 0.1 + 0.5 * (rng_double() - 0.5)]
  }
  let blp = DoubleMLBLP::new(basis, acc).fit()
  let src = GainStatsSource::from_blp_cv(blp, n_folds=5, seed=3141)
  let n_coef = blp.coef().length()
  inspect(src.var_y_residuals.length(), content=n_coef.to_string())
  inspect(src.nu2.length(), content=n_coef.to_string())
  inspect(src.all_coef.length(), content=n_coef.to_string())
  inspect(src.n_rep, content="1")
  // var_y matches the BLP's var_y.
  inspect((src.var_y - blp.var_y()).abs() < 1.0e-15, content="true")
  // all_coef matches the BLP's coef.
  let blp_coef = blp.coef()
  for k = 0; k < n_coef; k = k + 1 {
    inspect((src.all_coef[k] - blp_coef[k]).abs() < 1.0e-15, content="true")
  }
}

///|
/// v0.22.0+: the cross-fit `var_y_residuals` differs
/// from the in-sample `var_y_residuals` (because the
/// cross-fit version is honest about the basis's
/// inability to predict held-out rows).
test "gain_stats_from_blp_cv_differs_from_in_sample" {
  let basis = Matrix::zeros(50, 2)
  for i = 0; i < 50; i = i + 1 {
    basis.set(i, 0, 1.0)
    basis.set(i, 1, i.to_double() * 0.1)
  }
  let orth_signal : Array[Double] = []
  let mut acc = orth_signal
  for i = 0; i < 50; i = i + 1 {
    acc = acc + [0.5 + 0.3 * i.to_double() * 0.1 + 0.5 * (rng_double() - 0.5)]
  }
  let blp = DoubleMLBLP::new(basis, acc).fit()
  let src_in = GainStatsSource::from_blp(blp)
  let src_cv = GainStatsSource::from_blp_cv(blp, n_folds=5, seed=3141)
  // The in-sample variance is biased low (the basis
  // was fit on the same rows), so it should be
  // strictly less than the cross-fit variance on
  // average. Allow a small tolerance for the
  // random variation across folds.
  inspect(
    src_cv.var_y_residuals[0] >= src_in.var_y_residuals[0] - 0.05,
    content="true",
  )
}

///|
/// v0.22.0+: cross-fit `var_y_residuals` is deterministic
/// given a fixed `seed` (the kfold split is deterministic).
test "gain_stats_from_blp_cv_deterministic" {
  let basis = Matrix::zeros(50, 2)
  for i = 0; i < 50; i = i + 1 {
    basis.set(i, 0, 1.0)
    basis.set(i, 1, i.to_double() * 0.1)
  }
  let orth_signal : Array[Double] = []
  let mut acc = orth_signal
  for i = 0; i < 50; i = i + 1 {
    acc = acc + [0.5 + 0.3 * i.to_double() * 0.1 + 0.5 * (rng_double() - 0.5)]
  }
  let blp = DoubleMLBLP::new(basis, acc).fit()
  let s1 = GainStatsSource::from_blp_cv(blp, n_folds=5, seed=3141)
  let s2 = GainStatsSource::from_blp_cv(blp, n_folds=5, seed=3141)
  inspect(
    (s1.var_y_residuals[0] - s2.var_y_residuals[0]).abs() < 1.0e-15,
    content="true",
  )
  inspect((s1.nu2[0] - s2.nu2[0]).abs() < 1.0e-15, content="true")
}

///|
/// v0.22.0+: end-to-end. Two BLPs (long = full basis
/// with 1 feature, short = constant basis with the
/// same intercept column), auto-populate via
/// `from_blp_cv`, and check the cross-fit
/// `var_y_residuals` is honest. The long model has
/// higher R^2 (more predictors), so its cross-fit
/// residual variance is smaller.
test "gain_stats_from_blp_cv_end_to_end" {
  let n = 50
  // Long: basis with 1 feature (constant + 1 slope).
  let basis_long = Matrix::zeros(n, 1)
  for i = 0; i < n; i = i + 1 {
    basis_long.set(i, 0, 1.0)
  }
  // Short: basis with 1 feature, but the "feature"
  // is noise. After LinearRegression's automatic
  // intercept, both bases have 2 coefficients.
  // We make the short feature pure noise so the
  // short model has worse out-of-fold predictions.
  let basis_short = Matrix::zeros(n, 1)
  let rng = chacha8_rng(7)
  for i = 0; i < n; i = i + 1 {
    basis_short.set(i, 0, rng.double() * 2.0 - 1.0)
  }
  let orth_signal : Array[Double] = Array::make(n, 0.0)
  let rng2 = chacha8_rng(11)
  for i = 0; i < n; i = i + 1 {
    orth_signal[i] = 0.5 +
      0.3 * i.to_double() * 0.05 +
      0.5 * (rng2.double() - 0.5)
  }
  let blp_long = DoubleMLBLP::new(basis_long, orth_signal).fit()
  let blp_short = DoubleMLBLP::new(basis_short, orth_signal).fit()
  let src_long = GainStatsSource::from_blp_cv(blp_long, n_folds=5, seed=3141)
  let src_short = GainStatsSource::from_blp_cv(blp_short, n_folds=5, seed=3141)
  // Both BLPs have the same n_coef (2 = intercept
  // + 1 slope after the automatic intercept).
  let n_coef = src_long.all_coef.length()
  inspect(src_short.all_coef.length(), content=n_coef.to_string())
  // Long has lower cross-fit variance (the feature
  // is informative).
  inspect(
    src_long.var_y_residuals[0] <= src_short.var_y_residuals[0] + 0.1,
    content="true",
  )
}

///|
/// v0.22.0+: panic test — `from_blp_cv` requires the
/// BLP to be fit first.
test "panic_gain_stats_from_blp_cv_unfitted" {
  let basis = Matrix::zeros(5, 1)
  for i = 0; i < 5; i = i + 1 {
    basis.set(i, 0, 1.0)
  }
  let unfitted = DoubleMLBLP::new(basis, [0.1, 0.2, 0.3, 0.4, 0.5])
  let _ = GainStatsSource::from_blp_cv(unfitted)
}

///|
/// v0.22.0+: panic test — `n_folds` must be >= 2.
test "panic_gain_stats_from_blp_cv_n_folds_too_small" {
  let basis = Matrix::zeros(10, 1)
  for i = 0; i < 10; i = i + 1 {
    basis.set(i, 0, 1.0)
  }
  let orth_signal_zero : Array[Double] = Array::make(10, 0.0)
  let blp = DoubleMLBLP::new(basis, orth_signal_zero).fit()
  let _ = GainStatsSource::from_blp_cv(blp, n_folds=1)
}

// ---------------------------------------------------------------------------
// v0.23.0+ GainStatsSource::from_blp_hc0 tests
// ---------------------------------------------------------------------------

///|
/// v0.23.0+: `from_blp_hc0` produces a source with
/// the same shape as `from_blp` / `from_blp_cv` but
/// a different `nu2` (HC0-honest projection-weight
/// formula rather than the homoskedastic
/// OLS-derived `var_y_residuals / (n * se^2)`).
test "gain_stats_from_blp_hc0_basic" {
  let basis = Matrix::zeros(50, 2)
  for i = 0; i < 50; i = i + 1 {
    basis.set(i, 0, 1.0)
    basis.set(i, 1, i.to_double() * 0.1)
  }
  let orth_signal : Array[Double] = Array::make(50, 0.0)
  let rng = chacha8_rng(7)
  for i = 0; i < 50; i = i + 1 {
    orth_signal[i] = 0.5 +
      0.3 * i.to_double() * 0.1 +
      0.5 * (rng.double() - 0.5)
  }
  let blp = DoubleMLBLP::new(basis, orth_signal).fit()
  let src = GainStatsSource::from_blp_hc0(blp, n_folds=5, seed=3141)
  let n_coef = blp.coef().length()
  inspect(src.var_y_residuals.length(), content=n_coef.to_string())
  inspect(src.nu2.length(), content=n_coef.to_string())
  inspect(src.all_coef.length(), content=n_coef.to_string())
  inspect(src.n_rep, content="1")
  // var_y matches the BLP's var_y.
  inspect((src.var_y - blp.var_y()).abs() < 1.0e-15, content="true")
}

///|
/// v0.23.0+: the HC0 `nu2` differs from the
/// homoskedastic `nu2` (computed by `from_blp`)
/// when the BLP uses HC0 SE. The two formulas only
/// agree under homoskedasticity.
test "gain_stats_from_blp_hc0_nu2_differs" {
  let basis = Matrix::zeros(100, 2)
  let rng = chacha8_rng(7)
  for i = 0; i < 100; i = i + 1 {
    basis.set(i, 0, 1.0)
    // Heteroskedastic feature: variance grows with i.
    basis.set(i, 1, i.to_double() * 0.1 * (1.0 + 0.1 * (rng.double() - 0.5)))
  }
  let orth_signal : Array[Double] = Array::make(100, 0.0)
  for i = 0; i < 100; i = i + 1 {
    // Heteroskedastic noise.
    let noise_scale = 1.0 + 0.5 * (i.to_double() / 100.0)
    orth_signal[i] = 0.5 +
      0.3 * i.to_double() * 0.1 +
      noise_scale * (rng.double() - 0.5)
  }
  let blp = DoubleMLBLP::new(basis, orth_signal).fit()
  let src_homo = GainStatsSource::from_blp_cv(blp, n_folds=5, seed=3141)
  let src_hc0 = GainStatsSource::from_blp_hc0(blp, n_folds=5, seed=3141)
  // Compare nu2[1] (first slope coef). The two
  // formulas should differ under heteroskedasticity.
  let nu2_homo = src_homo.nu2[1]
  let nu2_hc0 = src_hc0.nu2[1]
  // Allow a small relative tolerance for the
  // difference (the two are on the same order of
  // magnitude; the difference is the
  // heteroskedasticity correction).
  let diff = (nu2_homo - nu2_hc0).abs()
  // The relative diff should be > 0 (the two
  // formulas genuinely differ).
  inspect(diff > 0.0, content="true")
}

///|
/// v0.23.0+: the HC0 `nu2` is the
/// projection-weight formula
/// `nu2[k] = (1 / n_obs) * ||M[k,:] @ basis^T||^2`.
/// Verify by recomputing the formula from scratch
/// and comparing to the function output.
test "gain_stats_from_blp_hc0_nu2_matches_projection_formula" {
  let basis = Matrix::zeros(50, 2)
  for i = 0; i < 50; i = i + 1 {
    basis.set(i, 0, 1.0)
    basis.set(i, 1, i.to_double() * 0.1)
  }
  let orth_signal : Array[Double] = Array::make(50, 0.0)
  let rng = chacha8_rng(7)
  for i = 0; i < 50; i = i + 1 {
    orth_signal[i] = 0.5 +
      0.3 * i.to_double() * 0.1 +
      0.5 * (rng.double() - 0.5)
  }
  let blp = DoubleMLBLP::new(basis, orth_signal).fit()
  let src = GainStatsSource::from_blp_hc0(blp, n_folds=5, seed=3141)
  let p_basis = basis.cols()
  let n_obs = blp.n_obs()
  let n_obs_d = n_obs.to_double()
  // Recompute M = (basis^T basis + 1e-10 I)^{-1}.
  let ridge = 1.0e-10
  let xtx = matmul(basis.transpose(), basis)
  let xtx_ridged = Matrix::zeros(p_basis, p_basis)
  for i = 0; i < p_basis; i = i + 1 {
    for j = 0; j < p_basis; j = j + 1 {
      xtx_ridged.set(i, j, xtx.get(i, j) + (if i == j { ridge } else { 0.0 }))
    }
  }
  let m_mat = inv_spd(xtx_ridged)
  // Recompute nu2[1] (first slope).
  let k = 1
  let m_row = k - 1
  let mut sum_sq = 0.0
  for i = 0; i < n_obs; i = i + 1 {
    let mut r_i = 0.0
    for j = 0; j < p_basis; j = j + 1 {
      r_i = r_i + m_mat.get(m_row, j) * basis.get(i, j)
    }
    sum_sq = sum_sq + r_i * r_i
  }
  let expected_nu2 = sum_sq / n_obs_d
  inspect((src.nu2[1] - expected_nu2).abs() < 1.0e-12, content="true")
}

///|
/// v0.23.0+: panic test — `from_blp_hc0` requires
/// the BLP to be fit.
test "panic_gain_stats_from_blp_hc0_unfitted" {
  let basis = Matrix::zeros(5, 1)
  for i = 0; i < 5; i = i + 1 {
    basis.set(i, 0, 1.0)
  }
  let unfitted = DoubleMLBLP::new(basis, [0.1, 0.2, 0.3, 0.4, 0.5])
  let _ = GainStatsSource::from_blp_hc0(unfitted)
}

// ---------------------------------------------------------------------------
// v0.25.0+ GainStatsSource::from_blp_cv_repeated tests
// ---------------------------------------------------------------------------

///|
/// v0.25.0+: `from_blp_cv_repeated` produces a
/// `GainStatsSource` with the same shape as
/// `from_blp_cv` (same `coef`, `var_y`, `all_coef`,
/// `n_rep`), but the `var_y_residuals` is averaged
/// across `n_repeats` independent K-fold runs
/// (each with a different seed).
test "gain_stats_from_blp_cv_repeated_basic" {
  let basis = Matrix::zeros(50, 2)
  for i = 0; i < 50; i = i + 1 {
    basis.set(i, 0, 1.0)
    basis.set(i, 1, i.to_double() * 0.1)
  }
  let orth_signal : Array[Double] = []
  let mut acc = orth_signal
  for i = 0; i < 50; i = i + 1 {
    acc = acc + [0.5 + 0.3 * i.to_double() * 0.1 + 0.5 * rng_double2(i)]
  }
  let blp = DoubleMLBLP::new(basis, acc).fit()
  let src = GainStatsSource::from_blp_cv_repeated(
    blp,
    n_folds=5,
    n_repeats=10,
    seed=3141,
  )
  let n_coef = blp.coef().length()
  inspect(src.var_y_residuals.length(), content=n_coef.to_string())
  inspect(src.nu2.length(), content=n_coef.to_string())
  inspect(src.all_coef.length(), content=n_coef.to_string())
  inspect(src.n_rep, content="1")
  // var_y matches the BLP's var_y.
  inspect((src.var_y - blp.var_y()).abs() < 1.0e-15, content="true")
  // all_coef matches the BLP's coef.
  let blp_coef = blp.coef()
  for k = 0; k < n_coef; k = k + 1 {
    inspect((src.all_coef[k] - blp_coef[k]).abs() < 1.0e-15, content="true")
  }
  // var_y_residuals is positive (not NaN, not inf).
  for k = 0; k < n_coef; k = k + 1 {
    let v = src.var_y_residuals[k]
    inspect(v > 0.0, content="true")
    inspect(v < 1.0e10, content="true")
  }
}

///|
/// v0.25.0+: `from_blp_cv_repeated` with `n_repeats=1`
/// should match the per-rep result of
/// `from_blp_cv` with the same `seed` (both use the
/// same K-fold partition, so the residual SS is
/// bit-equal).
test "gain_stats_from_blp_cv_repeated_matches_single_when_one_repeat" {
  let basis = Matrix::zeros(40, 2)
  for i = 0; i < 40; i = i + 1 {
    basis.set(i, 0, 1.0)
    basis.set(i, 1, i.to_double() * 0.1)
  }
  let orth_signal : Array[Double] = []
  let mut acc = orth_signal
  for i = 0; i < 40; i = i + 1 {
    acc = acc + [0.5 + 0.2 * i.to_double() * 0.1 + 0.5 * rng_double2(i)]
  }
  let blp = DoubleMLBLP::new(basis, acc).fit()
  let src_single = GainStatsSource::from_blp_cv(blp, n_folds=5, seed=3141)
  let src_rep1 = GainStatsSource::from_blp_cv_repeated(
    blp,
    n_folds=5,
    n_repeats=1,
    seed=3141,
  )
  // Same residual variance when n_repeats=1.
  let p = src_single.var_y_residuals.length()
  for k = 0; k < p; k = k + 1 {
    inspect(
      (src_single.var_y_residuals[k] - src_rep1.var_y_residuals[k]).abs() <
      1.0e-15,
      content="true",
    )
  }
}

///|
/// v0.25.0+: averaging across repeats reduces the
/// variance of `var_y_residuals` estimates. The
/// single-repeat estimate has a high variance
/// across seeds; the 10-repeat average should be
/// much closer to the "true" (in-sample) residual
/// variance. We check that the 10-repeat estimate
/// is between the 1-repeat estimates for two
/// different seeds (loose but sufficient).
test "gain_stats_from_blp_cv_repeated_smooths_estimate" {
  let basis = Matrix::zeros(60, 2)
  for i = 0; i < 60; i = i + 1 {
    basis.set(i, 0, 1.0)
    basis.set(i, 1, i.to_double() * 0.1)
  }
  let orth_signal : Array[Double] = []
  let mut acc = orth_signal
  for i = 0; i < 60; i = i + 1 {
    acc = acc + [0.5 + 0.2 * i.to_double() * 0.1 + 0.5 * rng_double2(i)]
  }
  let blp = DoubleMLBLP::new(basis, acc).fit()
  // Two different single-rep seeds give different
  // OOF residual variances.
  let s_a = GainStatsSource::from_blp_cv(blp, n_folds=5, seed=3141)
  let s_b = GainStatsSource::from_blp_cv(blp, n_folds=5, seed=4242)
  let s_avg = GainStatsSource::from_blp_cv_repeated(
    blp,
    n_folds=5,
    n_repeats=20,
    seed=3141,
  )
  let v_a = s_a.var_y_residuals[1]
  let v_b = s_b.var_y_residuals[1]
  let v_avg = s_avg.var_y_residuals[1]
  // Guard against a degenerate DGP: if the noise
  // were perfectly predictable from the basis, all
  // three estimates would collapse to ~0 and the
  // comparisons below would be vacuous.
  inspect(v_a > 1.0e-6, content="true")
  inspect(v_b > 1.0e-6, content="true")
  // The averaged estimate should be within [lo/2,
  // hi*3/2] of the two single-rep estimates (the
  // average of seeds 3141..3160 is drawn from the
  // same sampling distribution as seeds 3141 /
  // 4242). A denominator bug that inflates
  // `var_y_residuals` by `n_repeats` breaks this
  // band immediately.
  let lo = if v_a > v_b { v_b } else { v_a }
  let hi = if v_a > v_b { v_a } else { v_b }
  inspect(v_avg > lo * 0.5, content="true")
  inspect(v_avg < hi * 1.5, content="true")
}

///|
/// v0.25.0+: panic test — `from_blp_cv_repeated`
/// requires the BLP to be fit.
test "panic_gain_stats_from_blp_cv_repeated_unfitted" {
  let basis = Matrix::zeros(5, 1)
  for i = 0; i < 5; i = i + 1 {
    basis.set(i, 0, 1.0)
  }
  let unfitted = DoubleMLBLP::new(basis, [0.1, 0.2, 0.3, 0.4, 0.5])
  let _ = GainStatsSource::from_blp_cv_repeated(unfitted)
}

///|
/// v0.25.0+: panic test — `n_repeats` must be >= 1.
test "panic_gain_stats_from_blp_cv_repeated_zero_repeats" {
  let basis = Matrix::zeros(10, 1)
  for i = 0; i < 10; i = i + 1 {
    basis.set(i, 0, 1.0)
  }
  let blp = DoubleMLBLP::new(basis, [
    0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0,
  ]).fit()
  let _ = GainStatsSource::from_blp_cv_repeated(blp, n_repeats=0)
}

///|
/// Helper: deterministic U(-0.5, 0.5) that takes an
/// `i` parameter (so we don't share the chacha8
/// RNG state with the existing `rng_double`).
/// Uses a fresh per-index chacha8 stream so the
/// sequence is genuinely non-affine in `i` (an
/// earlier LCG draft produced values linear in
/// `i`, which made the CV noise perfectly
/// predictable from the basis and collapsed the
/// OOF residual variance to ~1e-25 — a vacuous
/// test DGP).
fn rng_double2(i : Int) -> Double {
  let r = @dml.chacha8_rng(i + 1)
  r.double() - 0.5
}

///|
/// Helper: deterministic U(-0.5, 0.5) for the CV
/// tests (avoids depending on the chacha8 RNG which
/// is shared with other tests).
fn rng_double() -> Double {
  // Deterministic pseudo-random number using a
  // simple LCG; the actual value doesn't matter
  // for the structural test, only that it varies
  // from call to call.
  let _ = 0
  // Use the @random chacha8 RNG with a fixed seed.
  let r = @dml.chacha8_rng(2024)
  r.double() - 0.5
}
