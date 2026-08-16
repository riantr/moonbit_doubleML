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
  inspect((psi_max_bias[0] - 3.0 / (2.0 * sqrt2)).abs() < 1.0e-12, content="true")
  inspect((psi_max_bias[1] - 6.0 / (2.0 * sqrt2)).abs() < 1.0e-12, content="true")
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
  inspect((gs.cf_y[0]).abs() < 1.0e-12, content="true")
  inspect((gs.cf_y[1]).abs() < 1.0e-12, content="true")
  inspect((gs.cf_d[0]).abs() < 1.0e-12, content="true")
  inspect((gs.cf_d[1]).abs() < 1.0e-12, content="true")
  inspect((gs.delta_theta[0]).abs() < 1.0e-12, content="true")
  inspect((gs.delta_theta[1]).abs() < 1.0e-12, content="true")
  inspect((gs.rho[0]).abs() < 1.0e-12, content="true")
  inspect((gs.rho[1]).abs() < 1.0e-12, content="true")
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
  inspect((gs.cf_y[0]).abs() < 1.0e-12, content="true")
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
    [0.4, 0.4, 0.4,
     // coef 1: reps 0, 1, 2
     0.4, 0.4, 0.4],
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
  let dml_long = GainStatsSource::new(
    [1.0, 1.0], [1.0, 1.0], [1.0], 1, 1.0,
  )
  let dml_short = GainStatsSource::new(
    [0.5, 0.5], [0.5, 0.5], [1.0, 1.0], 1, 1.0,
  )
  let _ = gain_statistics(dml_long, dml_short)
}

///|
/// `GainStatsSource::from_blp` constructs a source from a
/// fitted `DoubleMLBLP` + manually-supplied per-rep arrays.
/// The accessor validates that all three arrays have the
/// same length and that `length % n_rep == 0`.
test "gain_stats_from_blp_basic" {
  let blp = DoubleMLBLP::new(Matrix::zeros(2, 2), [1.0, 1.0]).fit()
  let src = GainStatsSource::from_blp(
    blp, [1.0], [0.5], [0.0], 1, 4.0,
  )
  inspect(src.var_y_residuals.length(), content="1")
  inspect(src.nu2.length(), content="1")
  inspect(src.all_coef.length(), content="1")
  inspect(src.n_rep, content="1")
  inspect((src.var_y - 4.0).abs() < 1.0e-12, content="true")
}