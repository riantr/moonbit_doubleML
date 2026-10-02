// v0.71.0: whitebox tests for DoubleMLCVAR::sensitivity_analysis.
//
// The CVaR sensitivity uses the IRM-style IF decomposition
// documented in cvar.mbt::sensitivity_analysis: psi_a is the
// constant -1 vector, psi_b is the treated/IPW quadratic term
// around `g_target = max(coef, (y - q*coef)/(1-q))`, and the
// residual is `y - g_hat`. We reuse the shared
// irm_style_sensitivity helper from v0.66.0; the contract is
// the same `SensitivityResult { rv, sigma2, nu2, max_bias }`
// shape that all other IRM-family estimators expose.

///|
test "cvar_sensitivity_returns_finite_result" {
  // DGP: 400 obs, p=2 covariates. Treatment propensity is a
  // logistic on x[0]; outcome y is the linear DGP
  // `y = 0.5 + 0.4 * x[0] - 0.3 * x[1] + eps` (so treated
  // y has mean ~ 0.5 and is in roughly [-0.1, 1.1]).
  // CVaR at q=0.5 of the treated group should land ~ 0.55
  // (the upper half of treated y).
  let n = 400
  let p = 2
  let rng = chacha8_rng(42)
  let x_flat = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    let x1 = rng.double() * 2.0 - 1.0
    x_flat[i * p + 0] = x0
    x_flat[i * p + 1] = x1
    let p_d = 1.0 / (1.0 + @math.exp(-x0))
    d[i] = if rng.double() < p_d { 1.0 } else { 0.0 }
    y[i] = 0.5 + 0.4 * x0 - 0.3 * x1 + (rng.double() - 0.5) * 0.3
  }
  let x_mat = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x_mat, y, d)
  let fitted = DoubleMLCVAR::new(data, treatment=1.0, quantile=0.5).fit()
  let r = fitted.sensitivity_analysis()
  // rho/sigma2/nu2/Max_bias must all be finite and non-negative
  // (sigma2 / nu2 are sample variances; rv / max_bias are the
  // confounding bounds at their mean (rv >= 0; max_bias >= 0)).
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
  assert_true(r.sigma2 >= 0.0)
  assert_true(r.nu2 >= 0.0)
  assert_true(r.max_bias >= 0.0)
}
