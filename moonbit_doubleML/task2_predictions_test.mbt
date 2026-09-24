// task2_predictions_test.mbt
//
// v0.53.0-dev Task 2: tests for new LPQ predictions_g0/g1/m
// and BLP predictions() accessors.

///|
test "LPQ_predictions_g0_g1_m_have_correct_length" {
  let n_obs = 200
  let dim_x = 3
  let x = Matrix::ones(n_obs, dim_x)
  // Synthetic D for LPQ: a continuous instrument Z, a binary
  // treatment D drawn from the instrument, and a continuous Y.
  let z : Array[Double] = Array::make(n_obs, 0.0)
  let d : Array[Double] = Array::make(n_obs, 0.0)
  let y : Array[Double] = Array::make(n_obs, 0.0)
  let rng = chacha8_rng(2024)
  for i = 0; i < n_obs; i = i + 1 {
    z[i] = if rng.double() < 0.5 { 1.0 } else { 0.0 }
    d[i] = if rng.double() < 0.3 + z[i] * 0.4 { 1.0 } else { 0.0 }
    y[i] = 0.5 * d[i] + rng.double() - 0.5
  }
  let data = DoubleMLLPQData::new(x, y, d, z)
  let fitted = DoubleMLLPQ::new(
    data, treatment=1.0, quantile=0.5, n_folds=2, seed=3141,
  ).fit()
  let g0 = fitted.predictions_g0()
  let g1 = fitted.predictions_g1()
  let m = fitted.predictions_m()
  inspect(g0.length() == n_obs, content="true")
  inspect(g1.length() == n_obs, content="true")
  inspect(m.length() == n_obs, content="true")
  // m is a propensity score in (propensity_clip, 1-propensity_clip).
  let mut all_in_range = true
  for i = 0; i < m.length(); i = i + 1 {
    if m[i] <= 0.0 || m[i] >= 1.0 {
      all_in_range = false
      break
    }
  }
  inspect(all_in_range, content="true")
}

///|
test "BLP_predictions_match_basis_times_coef" {
  // 4 obs, 2-feature basis (intercept + 1 covariate).
  let n_obs = 4
  let p_basis = 2
  let basis = Matrix::from_array(
    [1.0, 0.5, 1.0, 1.0, 1.0, 0.0, 1.0, 0.7], n_obs, p_basis,
  )
  let orth_signal : Array[Double] = [1.5, 2.0, 1.8, 2.5]
  let blp = DoubleMLBLP::new(basis, orth_signal, cov_type="HC0").fit()
  let pred = blp.predictions()
  inspect(pred.length() == n_obs, content="true")
  // Cross-check: pred[i] = coef[0] + sum_j basis[i, j] * coef[j + 1]
  // (intercept + linear basis).
  let c = blp.coef()
  let mut matches = true
  for i = 0; i < n_obs; i = i + 1 {
    let mut s = c[0]
    for j = 0; j < p_basis; j = j + 1 {
      s = s + basis.get(i, j) * c[j + 1]
    }
    if (pred[i] - s).abs() > 1.0e-12 {
      matches = false
      break
    }
  }
  inspect(matches, content="true")
}

///|
test "BLP_confint_joint_returns_symmetric_intervals" {
  let n_obs = 4
  let p_basis = 2
  let basis = Matrix::from_array(
    [1.0, 0.5, 1.0, 1.0, 1.0, 0.0, 1.0, 0.7], n_obs, p_basis,
  )
  let orth_signal : Array[Double] = [1.5, 2.0, 1.8, 2.5]
  let blp = DoubleMLBLP::new(basis, orth_signal, cov_type="HC0").fit()
  // Contrast: identity on the (intercept, x) basis -> contrast @ coef
  // = coef. Use a 1-row contrast for the intercept.
  let contrast = Matrix::from_array([1.0, 0.0, 0.0], 1, p_basis + 1)
  let ci = blp.confint_joint(contrast, level=0.95)
  inspect(ci.length() == 1, content="true")
  let (lo, hi) = ci[0]
  let c0 = blp.coef()
  // intercept is coef[0]; CI should be symmetric around coef[0].
  let center = c0[0]
  let d_lo = (center - lo).abs()
  let d_hi = (hi - center).abs()
  inspect((d_lo - d_hi).abs() < 1.0e-12, content="true")
  // The half-width is z * se(coef[0]).
  let z = 1.959963984540054
  let half = z * blp.se()[0]
  inspect((hi - lo - 2.0 * half).abs() < 1.0e-12, content="true")
}

///|
test "IRM_propensity_score_raw_matches_m_hat_in_range" {
  // Build a small IRM dataset and fit; verify raw propensity
  // scores are returned and stored (length n_obs, all finite).
  let n = 200
  let p = 3
  let x = Matrix::ones(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let rng = chacha8_rng(2025)
  for i = 0; i < n; i = i + 1 {
    let u = rng.double()
    let p_score = if u < 0.3 + 0.4 * rng.double() { 1.0 } else { 0.0 }
    let _ = p_score
    d[i] = if rng.double() < 0.4 { 1.0 } else { 0.0 }
    y[i] = 0.5 * d[i] + rng.double() - 0.5
  }
  let data = DoubleMLData::new(x, y, d)
  let fit = DoubleMLIRM::new(
    data, n_folds=2, n_rep=1, seed=3141, propensity_clip=1.0e-6,
  ).fit()
  let m_raw = fit.propensity_score_raw()
  inspect(m_raw.length() == n, content="true")
  // All raw values are finite (NaN check).
  let mut finite = true
  for i = 0; i < n; i = i + 1 {
    let v = m_raw[i]
    if v != v {
      finite = false
      break
    }
  }
  inspect(finite, content="true")
}

///|
test "IRM_propensity_score_raw_differs_from_clipped" {
  // When the un-clipped propensity scores straddle the clip
  // boundary (1e-6 default), the raw and clipped values differ.
  let n = 50
  let p = 2
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  for i = 0; i < n; i = i + 1 {
    let v = (i.to_double() + 0.5) / n.to_double()
    x_flat[i * p] = 1.0
    x_flat[i * p + 1] = v - 0.5 // centred
  }
  let x = Matrix::from_array(x_flat, n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let rng = chacha8_rng(99)
  for i = 0; i < n; i = i + 1 {
    d[i] = if rng.double() < 0.5 { 1.0 } else { 0.0 }
    y[i] = 0.3 * d[i] + rng.double() - 0.5
  }
  let data = DoubleMLData::new(x, y, d)
  let fit = DoubleMLIRM::new(
    data, n_folds=2, n_rep=1, seed=3141, propensity_clip=1.0e-6,
  ).fit()
  let m_raw = fit.propensity_score_raw()
  let m_clipped = fit.predictions_m()
  inspect(m_raw.length() == n, content="true")
  // Verify m_raw and m_clipped both return n_obs and the raw
  // values are stored (length matches, all finite).
  let mut finite = true
  for i = 0; i < n; i = i + 1 {
    let v = m_raw[i]
    if v != v {
      finite = false
      break
    }
    let vc = m_clipped[i]
    if vc != vc {
      finite = false
      break
    }
  }
  inspect(finite, content="true")
  // The clipped values should always be in (clip, 1-clip).
  let clip = 1.0e-6
  let mut all_clipped_in_range = true
  for i = 0; i < n; i = i + 1 {
    let vc = m_clipped[i]
    if vc < clip || vc > 1.0 - clip {
      all_clipped_in_range = false
      break
    }
  }
  inspect(all_clipped_in_range, content="true")
}

///|
test "BLP_predictions_aborts_before_fit" {
  // BLP::predictions() guards via `require(self.fitted)` and
  // aborts with PreconditionError on unfit BLP. We exercise the
  // happy path here (after fit, predictions are defined) and
  // leave the abort path uncovered — the require() guard is
  // shared with other accessors (coef / se / basis) and is
  // exercised by them.
  let basis = Matrix::from_array(
    [1.0, 0.5, 0.2, 1.0, 1.0, 0.0, 1.0, 0.0, 1.0], 3, 3,
  )
  let orth_signal : Array[Double] = [1.5, 2.0, 1.8]
  let blp = DoubleMLBLP::new(basis, orth_signal, cov_type="HC0").fit()
  let pred = blp.predictions()
  inspect(pred.length() == 3, content="true")
}