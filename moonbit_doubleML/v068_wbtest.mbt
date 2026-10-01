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

// ---------------------------------------------------------------------------
// DIDCS sensitivity smoke test (v0.69.0)
// ---------------------------------------------------------------------------

///|
test "didcs_sensitivity_returns_per_cell_results" {
  // v0.69.0+: DIDCS sensitivity returns one
  // SensitivityResult per (g, t) cell. Cells without a
  // fitted estimate (pre-treatment / no eval period) return
  // a zeroed SensitivityResult.
  //
  // Minimal 2-cohort / 3-period panel: g in {0, 1, 2}, t
  // in {1, 2, 3}. Treatment cohort `g=1` is treated in
  // t=2,3; cohort `g=2` is treated only in t=3. 200 obs
  // split evenly between never_treated (g=0) and the two
  // cohorts. Cells with eval_period <= g_value stay at zero
  // per the standard DIDCS missing-cell semantics:
  //   (g=1, t=1): eval_period (1) <= g_value (1) -> zero
  //   (g=1, t=2): eval_period (2) >  g_value (1) -> fitted
  //   (g=1, t=3): eval_period (3) >  g_value (1) -> fitted
  //   (g=2, t=1): eval_period (1) <= g_value (2) -> zero
  //   (g=2, t=2): eval_period (2) <= g_value (2) -> zero
  //   (g=2, t=3): eval_period (3) >  g_value (2) -> fitted
  let n_units = 200
  let n_periods_p = 3
  let n = n_units * n_periods_p
  let p = 2
  let rng = chacha8_rng(1)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t : Array[Int] = Array::make(n, 0)
  let id : Array[Int] = Array::make(n, 0)
  let g : Array[Int] = Array::make(n, 0)
  // Balanced panel: each unit observed in all 3 periods;
  // unit-level cohort g drawn once and replicated across
  // periods. Time-invariant covariates x_v[0, 1]; time-varying
  // id assignment.
  for u = 0; u < n_units; u = u + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    let x1 = rng.double() * 2.0 - 1.0
    // Assign cohort: 1/3 never-treated (g=0), 1/3 early-treated
    // (g=1, treated in t=2 onward), 1/3 late-treated
    // (g=2, treated in t=3 onward).
    let cu = rng.double()
    let g_u = if cu < 0.34 {
      0
    } else if cu < 0.67 {
      1
    } else {
      2
    }
    for pi = 0; pi < n_periods_p; pi = pi + 1 {
      let idx = u * n_periods_p + pi
      let t_u = pi + 1
      let d_treat = if g_u > 0 && t_u > g_u { 1.0 } else { 0.0 }
      x_flat[idx * p + 0] = x0
      x_flat[idx * p + 1] = x1
      g[idx] = g_u
      t[idx] = t_u
      id[idx] = u
      d[idx] = d_treat
      let eps = (rng.double() - 0.5) * 0.3
      y[idx] = d_treat * 1.5 + 0.4 * x0 + 0.2 * x1 + eps
    }
  }
  let x_mat = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLDIDCSData::new(x_mat, y, d, t, id, g)
  let fitted = DoubleMLDIDCS::new(data, n_folds=4, seed=1).fit()
  let results = fitted.sensitivity_analysis()
  // 2 cohorts (g=1, g=2) x 3 periods = 6 cells
  // (row-major by (gi, pi)). Note g=0 is the control
  // sentinel and is excluded from `groups` so n_groups
  // stays at 2 (the discovery rule strips the
  // never_treated_value).
  assert_eq(results.length(), 6)
  // Fitted cells (eval_period > g_value): (g=1, t=2) ->
  // gi=0 / pi=1 / flat=1; (g=1, t=3) -> gi=0 / pi=2 /
  // flat=2; (g=2, t=3) -> gi=1 / pi=2 / flat=5.
  let fitted_cells : Array[Int] = [1, 2, 5]
  // Zero cells (eval_period <= g_value): (g=1, t=1) ->
  // gi=0 / pi=0 / flat=0; (g=2, t=1) -> gi=1 / pi=0 /
  // flat=3; (g=2, t=2) -> gi=1 / pi=1 / flat=4.
  let zero_cells : Array[Int] = [0, 3, 4]
  for k in fitted_cells {
    assert_true(results[k].rv.is_nan() == false)
    assert_true(results[k].sigma2.is_nan() == false)
    assert_true(results[k].nu2.is_nan() == false)
    assert_true(results[k].max_bias.is_nan() == false)
    assert_true(results[k].sigma2 >= 0.0)
    assert_true(results[k].nu2 >= 0.0)
  }
  for k in zero_cells {
    assert_eq(results[k].rv, 0.0)
    assert_eq(results[k].sigma2, 0.0)
    assert_eq(results[k].nu2, 0.0)
    assert_eq(results[k].max_bias, 0.0)
  }
}
