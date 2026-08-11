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