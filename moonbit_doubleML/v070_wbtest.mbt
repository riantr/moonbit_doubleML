///|
// v0.70.0+: wbtests for the `sensitivity_analysis`
// additions on the remaining 5 estimators that did not have
// it yet in v0.69.0:
//   - DIDCrossSection (single-theta IRM-style)
//   - DIDMulti (per-cell IRM-style, filtered by
//     gt_combinations)
//   - PLPR (single-theta IRM-style, panel partialling-out)
//   - LPLR (single-theta IRM-style, partially logistic ATE)
//   - QTE (per-quantile, centered-IF single-psi-sensitivity)
//
// All five decompose through the shared
// `irm_style_sensitivity` / `single_psi_sensitivity` helpers
// (see sensitivity.mbt); the wbtests pin the per-estimator
// shape (single-theta vs Array[SensitivityResult]) and
// finite-value contract.

// ---------------------------------------------------------------------------
// DIDCrossSection sensitivity smoke test (v0.70.0)
// ---------------------------------------------------------------------------

///|
test "didcs_cross_section_sensitivity_returns_finite_result" {
  // v0.70.0+: cross-section DID sensitivity analysis
  // (Sant'Anna-Zhao 2020, observational score, ATT form).
  // Single-theta IRM-style decomposition: outcome residual
  // is the ATT form
  // `y - g_d0_t0 - (g_d1_t0 - g_d0_t0) * d`; the per-row
  // Riesz representer is the `psi_a` already persisted by
  // `fit`. We only check finiteness + non-negativity of
  // sigma2 / nu2 (sensitivity is an unbiasedness test, not
  // a point estimate test).
  let n = 300
  let p = 2
  let rng = chacha8_rng(1)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    x_flat[i * p + 0] = rng.double() * 2.0 - 1.0
    x_flat[i * p + 1] = rng.double() * 2.0 - 1.0
    // Treatment `d` and post-period `t` are both binary
    // {0, 1}; we draw them independently so the four
    // (d, t) cells all have non-trivial support.
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    t[i] = if rng.double() > 0.5 { 1 } else { 0 }
    let x_sum = x_flat[i * p + 0] + x_flat[i * p + 1]
    let post = t[i].to_double()
    // ATT-form outcome: 1.5 * d * post + 0.4 * x_sum +
    // iid noise. Heterogeneous-by-design treatment effect
    // (zero in the pre-period).
    let eps = (rng.double() - 0.5) * 0.3
    y[i] = 1.5 * d[i] * post + 0.4 * x_sum + eps
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLDIDCrossSectionData::new(x, y, d, t)
  let fitted = DoubleMLDIDCrossSection::new(data, n_folds=4, seed=1).fit()
  let r = fitted.sensitivity_analysis()
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
  assert_true(r.sigma2 >= 0.0)
  assert_true(r.nu2 >= 0.0)
}

// ---------------------------------------------------------------------------
// DIDMulti sensitivity smoke test (v0.70.0)
// ---------------------------------------------------------------------------

///|
test "didmulti_sensitivity_returns_per_combination_results" {
  // v0.70.0+: DIDMulti sensitivity analysis delegates to
  // `DoubleMLDIDCS::sensitivity_analysis` (per-cell
  // `Array[SensitivityResult]` of length
  // `n_groups * n_periods`) and filters down to the
  // `gt_combinations` selector. The default keyword
  // `"standard"` resolves to every (g, t) pair with
  // `t_eval > g`, so the result length equals the number
  // of `(g, t)` cells with `t_eval > g`.
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
  for u = 0; u < n_units; u = u + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    let x1 = rng.double() * 2.0 - 1.0
    let cu = rng.double()
    let g_u = if cu < 0.34 { 0 } else if cu < 0.67 { 1 } else { 2 }
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
  // `gt_combinations` keyword "standard" -> 3 fitted cells
  // across the (g=1, g=2) cohorts and 3 periods: (1,2),
  // (1,3), (2,3). Length should be 3.
  let fitted = DoubleMLDIDMulti::new(data, n_folds=4, seed=1).fit()
  let results = fitted.sensitivity_analysis()
  assert_eq(results.length(), 3)
  for k = 0; k < results.length(); k = k + 1 {
    assert_true(results[k].rv.is_nan() == false)
    assert_true(results[k].sigma2.is_nan() == false)
    assert_true(results[k].nu2.is_nan() == false)
    assert_true(results[k].max_bias.is_nan() == false)
    assert_true(results[k].sigma2 >= 0.0)
    assert_true(results[k].nu2 >= 0.0)
  }
}

// ---------------------------------------------------------------------------
// PLPR sensitivity smoke test (v0.70.0)
// ---------------------------------------------------------------------------

///|
test "plpr_sensitivity_returns_finite_result" {
  // v0.70.0+: panel partialling-out / IV-type
  // sensitivity analysis. Single-theta IRM-style
  // decomposition: outcome residual `y - l_hat`; psi_a
  // recomputed on-the-fly from `(d, l_hat, m_hat)` per the
  // score branch.
  //
  // DGP: balanced panel with 100 units x 3 periods = 300
  // obs. Cross-sectional covariates x_v[0, 1]; unit-level
  // treatment D generated from a logistic propensity on
  // x_v[0]; outcome y is the canonical 2-period ATT DGP.
  // Approach: `fd_exact` (first-differences) with default
  // `"partialling out"` score.
  let n_units = 100
  let n_periods_p = 3
  let n = n_units * n_periods_p
  let p = 2
  let rng = chacha8_rng(1)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t : Array[Int] = Array::make(n, 0)
  let id : Array[Int] = Array::make(n, 0)
  for u = 0; u < n_units; u = u + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    let x1 = rng.double() * 2.0 - 1.0
    // Unit fixed effect so the static-panel approach has
    // signal beyond OLS. Time-varying D (re-sampled per
    // period) keeps the cluster weighted sum non-zero
    // (constant D within a unit makes the within-unit
    // first-difference collapse to zero, hitting the
    // est_coef_cluster precondition).
    let alpha = (rng.double() - 0.5) * 2.0
    for pi = 0; pi < n_periods_p; pi = pi + 1 {
      let idx = u * n_periods_p + pi
      let t_u = pi + 1
      // Time-varying covariates (unit-trait + period noise)
      let x1_t = x1 + (rng.double() - 0.5) * 0.5
      // Treatment: propensity P(D=1) = expit(x0 + alpha/2).
      let p_d = 1.0 / (1.0 + @math.exp(-(x0 + alpha / 2.0)))
      let d_it = if rng.double() < p_d { 1.0 } else { 0.0 }
      let eps = (rng.double() - 0.5) * 0.3
      x_flat[idx * p + 0] = x0
      x_flat[idx * p + 1] = x1_t
      d[idx] = d_it
      t[idx] = t_u
      id[idx] = u
      // Y_it = 1.0 * D_it + 0.4 * x0 + 0.2 * x1_t + alpha + eps.
      y[idx] = 1.0 * d_it + 0.4 * x0 + 0.2 * x1_t + alpha + eps
    }
  }
  let x_mat = Matrix::from_array(x_flat, n, p)
  let panel = DoubleMLPanelData::new(x_mat, y, d, t, id)
  let fitted = DoubleMLPLPR::new(
    panel,
    approach="fd_exact",
    score="partialling out",
    n_folds=2,
    seed=1,
  ).fit()
  let r = fitted.sensitivity_analysis()
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
  assert_true(r.sigma2 >= 0.0)
  assert_true(r.nu2 >= 0.0)
}

// ---------------------------------------------------------------------------
// LPLR sensitivity smoke test (v0.70.0)
// ---------------------------------------------------------------------------

///|
test "lplr_sensitivity_returns_finite_result" {
  // v0.70.0+: partially logistic regression sensitivity
  // analysis (Liu-Zhang-Zhou 2021). Single-theta IRM-style
  // decomposition with the simplified psi_a
  // `psi_a[i] = -d[i] * (d[i] - a_hat[i])` (binary ATE
  // analogue); outcome residual `y - t_pred`. The LPLR
  // score is nonlinear in theta and the exact
  // `psi_deriv(theta)` depends on the preliminary linear
  // coefficient `beta_start` which the struct does not
  // persist; the simplified IRM-style form is the
  // conservative convention the C&H formula expects.
  let n = 300
  let p = 2
  let rng = chacha8_rng(1)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    x_flat[i * p + 0] = rng.double() * 2.0 - 1.0
    x_flat[i * p + 1] = rng.double() * 2.0 - 1.0
    // Binary treatment and binary outcome; both DGPs are
    // independent of each other (no confounding) so the
    // sensitivity test pins the unbiasedness-shape
    // contract only.
    let p_d = 1.0 / (1.0 + @math.exp(-x_flat[i * p + 0]))
    d[i] = if rng.double() < p_d { 1.0 } else { 0.0 }
    let p_y = 1.0 /
      (
        1.0 +
        @math.exp(
          -(0.8 * d[i] + 0.4 * x_flat[i * p + 0] + 0.2 * x_flat[i * p + 1]),
        )
      )
    y[i] = if rng.double() < p_y { 1.0 } else { 0.0 }
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLBinaryData::new(x, y, d)
  let fitted = DoubleMLLPLR::new(data, n_folds=4, n_folds_inner=4, seed=1).fit()
  let r = fitted.sensitivity_analysis()
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
  assert_true(r.sigma2 >= 0.0)
  assert_true(r.nu2 >= 0.0)
}

// ---------------------------------------------------------------------------
// QTE sensitivity smoke test (v0.70.0)
// ---------------------------------------------------------------------------

///|
test "qte_sensitivity_returns_per_quantile_results" {
  // v0.70.0+: per-quantile QTE sensitivity analysis.
  // Single-quantile setup (length=1 array) pins the
  // contract on the canonical `[0.5]` QTE; multi-quantile
  // setup pins the length-of-result contract.
  let n = 300
  let p = 2
  let rng = chacha8_rng(1)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    x_flat[i * p + 0] = rng.double() * 2.0 - 1.0
    x_flat[i * p + 1] = rng.double() * 2.0 - 1.0
    let p_d = 1.0 / (1.0 + @math.exp(-x_flat[i * p + 0]))
    d[i] = if rng.double() < p_d { 1.0 } else { 0.0 }
    let eps = (rng.double() - 0.5) * 0.3
    y[i] = 1.0 * d[i] + 0.5 * x_flat[i * p + 0] + eps
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d)
  // Single-quantile: should return exactly 1
  // SensitivityResult.
  let fitted_single = DoubleMLQTE::new(data, quantiles=[0.5], n_folds=4, seed=1).fit()
  let single_results = fitted_single.sensitivity_analysis()
  assert_eq(single_results.length(), 1)
  assert_true(single_results[0].rv.is_nan() == false)
  assert_true(single_results[0].sigma2.is_nan() == false)
  assert_true(single_results[0].nu2.is_nan() == false)
  assert_true(single_results[0].max_bias.is_nan() == false)
  assert_true(single_results[0].sigma2 >= 0.0)
  assert_true(single_results[0].nu2 >= 0.0)
  // Multi-quantile: should return exactly 3
  // SensitivityResults.
  let fitted_multi = DoubleMLQTE::new(
    data,
    quantiles=[0.25, 0.5, 0.75],
    n_folds=4,
    seed=1,
  ).fit()
  let multi_results = fitted_multi.sensitivity_analysis()
  assert_eq(multi_results.length(), 3)
  for k = 0; k < 3; k = k + 1 {
    assert_true(multi_results[k].rv.is_nan() == false)
    assert_true(multi_results[k].sigma2.is_nan() == false)
    assert_true(multi_results[k].nu2.is_nan() == false)
    assert_true(multi_results[k].max_bias.is_nan() == false)
    assert_true(multi_results[k].sigma2 >= 0.0)
    assert_true(multi_results[k].nu2 >= 0.0)
  }
}
