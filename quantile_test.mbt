///|
fn quantile_test_data() -> DoubleMLData {
  let n = 400
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    d[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
    y[i] = d[i] + (i % 100).to_double() / 100.0
  }
  DoubleMLData::new(x, y, d)
}

///|
test "pq_estimates_treated_median" {
  let fitted = DoubleMLPQ::new(
    quantile_test_data(),
    treatment=1.0,
    quantile=0.5,
  ).fit()
  inspect((fitted.coef() - 1.5).abs() < 0.08, content="true")
  inspect(fitted.se() > 0.0, content="true")
}

///|
test "qte_estimates_location_shift" {
  let fitted = DoubleMLQTE::new(quantile_test_data(), quantiles=[
    0.25, 0.5, 0.75,
  ]).fit()
  for c in fitted.coefs() {
    inspect((c - 1.0).abs() < 0.08, content="true")
  }
  inspect(fitted.ses().length(), content="3")
}

///|
test "cvar_estimates_upper_tail_mean" {
  let fitted = DoubleMLCVAR::new(
    quantile_test_data(),
    treatment=1.0,
    quantile=0.5,
  ).fit()
  inspect((fitted.coef() - 1.75).abs() < 0.1, content="true")
  inspect(fitted.se() > 0.0, content="true")
}

///|
/// Bug #3 fix: `solve_pq` should not call `cross_fit_conditional`
/// during the bisection. The pre-fix code did 1 g cross-fit per
/// bisection iteration (50 iterations) + 1 for the final score + 2
/// for the numerical derivative = 53 g cross-fits per PQ fit. The
/// post-fix code does 1 (final) + 2 (derivative) = 3. Asserting
/// `count <= 5` leaves headroom for the CVaR model's extra call.
test "pq_fit_uses_ipw_bisection" {
  reset_g_cross_fit_count()
  let _ = DoubleMLPQ::new(quantile_test_data(), treatment=1.0, quantile=0.5).fit()
  let count = g_cross_fit_calls()
  // The post-fix budget is 3 (one at theta, two for the numerical
  // derivative). Allow up to 5 for safety against minor future
  // refactors that might add a 4th call (e.g. for the IPW sanity
  // check on the bracket).
  inspect(count <= 5, content="true")
  // Sanity-check that the pre-fix budget (>= 50) is no longer
  // being hit. If the IPW bisection is broken and the code
  // re-falls back to per-iteration g cross-fits, this catches it.
  inspect(count < 50, content="true")
}

///|
/// Bug #3 fix: `pq_score_ipw` should not depend on `x` (no g
/// cross-fit) and should return the IPW-only score for a known
/// input. The pre-fix `pq_score` would have called
/// `cross_fit_conditional`, but the IPW score is purely a
/// function of `treated`, `m`, `y`, `theta`, `q`.
test "pq_ipw_score_no_g_needed" {
  let treated = [1.0, 0.0, 1.0, 0.0, 1.0]
  let m = [0.5, 0.5, 0.5, 0.5, 0.5]
  let y = [0.5, 1.5, 0.3, 1.7, 0.8]
  // theta=1.0: only the first 3 observations have y <= 1.0
  // (y[0]=0.5, y[2]=0.3, y[4]=0.8). So the score is
  //   i=0: 1/0.5 * 1 - 0.5 = 1.5
  //   i=1: 0/0.5 * 0 - 0.5 = -0.5
  //   i=2: 1/0.5 * 1 - 0.5 = 1.5
  //   i=3: 0/0.5 * 0 - 0.5 = -0.5
  //   i=4: 1/0.5 * 1 - 0.5 = 1.5
  let _ = @dml.Matrix::zeros(5, 1)
  let s = pq_score_ipw(Matrix::zeros(5, 1), y, treated, m, 1.0, 0.5)
  inspect(s.length(), content="5")
  let expected = [1.5, -0.5, 1.5, -0.5, 1.5]
  for i = 0; i < 5; i = i + 1 {
    inspect((s[i] - expected[i]).abs() < 1.0e-12, content="true")
  }
  // theta=0.4: only i=2 (y=0.3) has y <= 0.4. So the score is
  //   i=0: 1/0.5 * 0 - 0.5 = -0.5
  //   i=1: 0/0.5 * 0 - 0.5 = -0.5
  //   i=2: 1/0.5 * 1 - 0.5 = 1.5
  //   i=3: 0/0.5 * 0 - 0.5 = -0.5
  //   i=4: 1/0.5 * 0 - 0.5 = -0.5
  let s2 = pq_score_ipw(Matrix::zeros(5, 1), y, treated, m, 0.4, 0.5)
  let expected2 = [-0.5, -0.5, 1.5, -0.5, -0.5]
  for i = 0; i < 5; i = i + 1 {
    inspect((s2[i] - expected2[i]).abs() < 1.0e-12, content="true")
  }
  // Also check the cross-fit counter does NOT increase when
  // pq_score_ipw is called directly (it has no g dependency).
  let before = g_cross_fit_calls()
  let _ = pq_score_ipw(Matrix::zeros(5, 1), y, treated, m, 0.5, 0.5)
  let after = g_cross_fit_calls()
  inspect(after - before == 0, content="true")
}

///|
/// Bug #2 fix: the QTE SE must include the cross-covariance
/// between `psi_d1` and `psi_d0`. For the canonical DGP
/// (`d ~ Bernoulli(0.5)`, `y = d + (i%100)/100` alternating),
/// the covariance is small but positive, so the new SE is
/// typically slightly smaller than the (incorrect) quadrature
/// `sqrt(SE_d1^2 + SE_d0^2)`. The test asserts:
///   1. SE is positive and finite (sanity).
///   2. SE <= buggy quadrature SE (i.e. the covariance
///      correction is applied in the right direction).
test "qte_se_includes_covariance" {
  let fitted = DoubleMLQTE::new(quantile_test_data(), quantiles=[0.5]).fit()
  let se_new = fitted.ses()[0]
  // SE must be positive and finite. `is_nan` is the only
  // finiteness check we have without `@math`; the only
  // way to get a NaN SE is if deriv == 0, which is
  // exceedingly unlikely with a sensible DGP.
  inspect(se_new > 0.0, content="true")
  inspect(!se_new.is_nan(), content="true")
  // Compute the old (buggy) quadrature SE by hand from the
  // per-treatment PQ fits. We do this by re-fitting the two
  // PQs with their SE values, not by recreating the buggy
  // code path.
  let pq1 = DoubleMLPQ::new(quantile_test_data(), treatment=1.0, quantile=0.5).fit()
  let pq0 = DoubleMLPQ::new(quantile_test_data(), treatment=0.0, quantile=0.5).fit()
  let se_buggy = (pq1.se() * pq1.se() + pq0.se() * pq0.se()).sqrt()
  // The new SE can be <= or > the buggy SE depending on the
  // sign of the cross-covariance. For this DGP the cross-
  // covariance is small but positive, so the new SE should
  // be <= the buggy SE. We assert this with a small slack
  // to allow for finite-sample noise.
  inspect(se_new <= se_buggy + 1.0e-6, content="true")
}

///|
/// Bug #2 fix: the QTE SE should be hand-computable from the
/// per-treatment `solve_pq` outputs. The test re-derives the
/// new (covariance-adjusted) SE by hand and asserts it matches
/// the framework output to within 1e-9.
test "qte_se_hand_computation" {
  let data = quantile_test_data()
  // Re-derive the QTE for q=0.5 by hand.
  let (theta1, psi1, deriv1) = solve_pq(data, 1.0, 0.5, 2, 3141, 1.0e-6)
  let (theta0, psi0, deriv0) = solve_pq(data, 0.0, 0.5, 2, 3141, 1.0e-6)
  let n = data.n_obs().to_double()
  // Coef = theta1 - theta0
  let coef = theta1 - theta0
  // New SE = sqrt(mean((psi1/deriv1 - psi0/deriv0)^2) / n)
  let mut gamma = 0.0
  for i = 0; i < psi1.length(); i = i + 1 {
    let u = psi1[i] / deriv1 - psi0[i] / deriv0
    gamma = gamma + u * u
  }
  gamma = gamma / n
  let se_hand = (gamma / n).sqrt()
  // Compare to framework output
  let fitted = DoubleMLQTE::new(data, quantiles=[0.5]).fit()
  let se_framework = fitted.ses()[0]
  let coef_framework = fitted.coefs()[0]
  inspect((coef - coef_framework).abs() < 1.0e-12, content="true")
  inspect((se_hand - se_framework).abs() < 1.0e-9, content="true")
}
