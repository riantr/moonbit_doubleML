///|
// v0.68.0+: wbtests for the SSM / APOS sensitivity
// additions. SSM uses the shared `irm_style_sensitivity`
// helper (psi_a = -1 constant, residuals = y - g_d1_hat);
// APOS returns an Array[SensitivityResult] of length
// n_levels via per-level re-fit (mirrors the bootstrap
// pattern).
//
// Coverage:
//   SSM::sensitivity_analysis returns a finite
//   SensitivityResult.
//   APOS::sensitivity_analysis returns one
//   SensitivityResult per treatment level.

// ---------------------------------------------------------------------------
// SSM sensitivity smoke test
// ---------------------------------------------------------------------------

///|
test "ssm_sensitivity_returns_finite_result" {
  let n = 200
  let p = 1
  let rng = chacha8_rng(1)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let s : Array[Double] = Array::make(n, 1.0)
  for i = 0; i < n; i = i + 1 {
    x_flat[i * p + 0] = rng.double() * 2.0 - 1.0
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    y[i] = 1.0 * d[i] + 0.5 * x_flat[i * p + 0] + (rng.double() - 0.5) * 0.2
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLSSMData::new(x, y, d, s)
  let fitted = DoubleMLSSM::new(data, n_folds=4, seed=1).fit()
  let r = fitted.sensitivity_analysis()
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
}

// ---------------------------------------------------------------------------
// APOS sensitivity smoke test
// ---------------------------------------------------------------------------

///|
test "apos_sensitivity_returns_per_level_results" {
  // v0.69.0+: real APOS sensitivity wbtest. Binary (discrete)
  // treatment DGP avoids the v0.63.0 bootstrap-baseline
  // per-observation NaN guard that fires under continuous
  // treatment (the IRM-style helper itself is verified by
  // the SSM::sensitivity_analysis test above; per-level
  // aggregation is the re-fit plumbing). 2-level policy
  // (treatment in {0, 1}, ~50/50 split); the per-level
  // re-fit returns one SensitivityResult per level.
  let n = 200
  let rng = chacha8_rng(1)
  let x_flat : Array[Double] = Array::make(n * 2, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    x_flat[i * 2 + 0] = rng.double() * 2.0 - 1.0
    x_flat[i * 2 + 1] = rng.double() * 2.0 - 1.0
    let u = rng.double()
    d[i] = if u > 0.5 { 1.0 } else { 0.0 }
    let x_sum = x_flat[i * 2 + 0] + x_flat[i * 2 + 1]
    y[i] = 1.5 * d[i] + 0.3 * x_sum + (rng.double() - 0.5) * 0.2
  }
  let x = Matrix::from_array(x_flat, n, 2)
  let data = DoubleMLData::new(x, y, d)
  let levels : Array[Double] = [0.0, 1.0]
  let fitted = DoubleMLAPOS::new(data, levels, n_folds=4, seed=1).fit()
  let results = fitted.sensitivity_analysis()
  assert_eq(results.length(), 2)
  for j = 0; j < 2; j = j + 1 {
    assert_true(results[j].rv.is_nan() == false)
    assert_true(results[j].sigma2.is_nan() == false)
    assert_true(results[j].nu2.is_nan() == false)
    assert_true(results[j].max_bias.is_nan() == false)
    assert_true(results[j].sigma2 > 0.0)
    assert_true(results[j].nu2 > 0.0)
  }
}

// ---------------------------------------------------------------------------
// BLP sensitivity smoke test (v0.69.0)
// ---------------------------------------------------------------------------

///|
test "blp_sensitivity_returns_per_coef_results" {
  // v0.69.0+: BLP sensitivity analysis returns one
  // SensitivityResult per coefficient (including the
  // intercept). The IRM-style decomposition is identical to
  // the SSM/APO/SensitivityResult tests above; this test
  // pins the per-coef shape and finite-value contract on
  // BLP's OLS projection path.
  //
  // DGP: `y = 1.0 + 0.8 * x1 + 0.4 * x2 + eps`, eps ~ N(0, 0.4^2).
  // `basis` is a 2-column design (intercept handled inside the
  // augmented design reconstruction); `orth_signal` is `y`.
  let n = 200
  let p_basis = 2
  let rng = chacha8_rng(1)
  let basis_flat : Array[Double] = Array::make(n * p_basis, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    basis_flat[i * p_basis + 0] = rng.double() * 2.0 - 1.0
    basis_flat[i * p_basis + 1] = rng.double() * 2.0 - 1.0
    let eps = (rng.double() - 0.5) * 0.4
    y[i] = 1.0 + 0.8 * basis_flat[i * p_basis + 0] + 0.4 *
      basis_flat[i * p_basis + 1] +
      eps
  }
  let basis = Matrix::from_array(basis_flat, n, p_basis)
  let fitted = DoubleMLBLP::new(basis, y).fit()
  let results = fitted.sensitivity_analysis()
  // 3 coefficients: intercept + 2 basis columns.
  assert_eq(results.length(), 3)
  for j = 0; j < 3; j = j + 1 {
    assert_true(results[j].rv.is_nan() == false)
    assert_true(results[j].sigma2.is_nan() == false)
    assert_true(results[j].nu2.is_nan() == false)
    assert_true(results[j].max_bias.is_nan() == false)
    assert_true(results[j].sigma2 > 0.0)
    assert_true(results[j].nu2 > 0.0)
  }
}
