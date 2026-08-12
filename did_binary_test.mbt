///|
/// End-to-end preprocessing: with 4 units × 2 periods where 3 are
/// treated (`g = 1`) and 1 is never-treated (`g = 0`), the
/// wide-format subset should contain 4 rows (one per unit) with
/// `d = 1` for the 3 treated units and `d = 0` for the
/// never-treated unit.
test "did_binary_preprocess_keeps_both_periods" {
  let n = 8 // 4 units × 2 periods
  let p = 1
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = [0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0]
  let d : Array[Double] = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0]
  let t : Array[Int] = [0, 1, 0, 1, 0, 1, 0, 1]
  // g[unit]: units 0,1,2 are treated (g=1); unit 3 never-treated (g=0)
  let g : Array[Int] = [1, 1, 1, 1, 1, 1, 0, 0]
  // id: 0,1,2,3 each with both periods
  let id : Array[Int] = [0, 0, 1, 1, 2, 2, 3, 3]
  let data = DoubleMLDIDBinaryData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t,
    g,
    id,
  )
  // Drive preprocessing via the public fit interface, then inspect
  // the resulting wide-format subset through the public accessor
  // `n_obs_subset`.
  let fitted = DoubleMLDIDBinary::new(data, 1, 0, 1).fit()
  inspect(fitted.n_obs_subset(), content="4")
  // d (G_indicator): units 0,1,2 are treated (d=1); unit 3 is control (d=0)
  let d_wide = fitted.inner.data.d
  inspect(d_wide[0], content="1")
  inspect(d_wide[1], content="1")
  inspect(d_wide[2], content="1")
  inspect(d_wide[3], content="0")
  // y = y_post - y_pre = 1 - 0 = 1 for all units
  let y_wide = fitted.inner.data.y
  for i = 0; i < 4; i = i + 1 {
    inspect(y_wide[i], content="1")
  }
}

///|
/// End-to-end: the binary DID estimator should recover a known
/// ATT on a synthetic panel DGP. The pre-period outcome is
/// `y_pre = x @ 1`, the post-period is `y_post = x @ 1 + theta *
/// d_post + noise`, with `theta = 1.0`. After preprocessing
/// (`y_diff = y_post - y_pre`), the wide-format outcome is
/// approximately `theta * d` (the `x @ 1` terms cancel in the
/// difference) plus noise. With enough observations the estimator
/// should recover `theta �?1.0` within a few SE.
test "did_binary_recovers_known_att" {
  let n_units = 400
  let p = 3
  let n = n_units * 2 // 2 periods
  let theta0 = 1.0
  // Build panel: each unit has 2 rows (t=0, t=1).
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t : Array[Int] = Array::make(n, 0)
  let g : Array[Int] = Array::make(n, 0)
  let id : Array[Int] = Array::make(n, 0)
  let rng = chacha8_rng(7)
  for u = 0; u < n_units; u = u + 1 {
    // Each unit's x is drawn once (time-invariant covariates).
    let xu : Array[Double] = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      xu[j] = rng.double() * 2.0 - 1.0
    }
    let pre = 2 * u
    let post = 2 * u + 1
    // Half the units are treated (`g = 1`), the other half are
    // never-treated (`g = 0`). Treatment changes `d` in the post
    // period for treated units.
    let is_treated = if u % 2 == 0 { 1 } else { 0 }
    for k = 0; k < 2; k = k + 1 {
      let row = if k == 0 { pre } else { post }
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = xu[j]
      }
      t[row] = k
      id[row] = u
      g[row] = is_treated
      if is_treated == 1 && k == 1 {
        d[row] = 1.0
      } else {
        d[row] = 0.0
      }
      let mut y_val = 0.0
      for j = 0; j < p; j = j + 1 {
        y_val = y_val + xu[j]
      }
      if k == 1 && is_treated == 1 {
        y_val = y_val + theta0
      }
      // Small noise.
      y_val = y_val + 0.05 * (rng.double() - 0.5)
      y[row] = y_val
    }
  }
  let data = DoubleMLDIDBinaryData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t,
    g,
    id,
  )
  let fitted = DoubleMLDIDBinary::new(
    data,
    1,
    0,
    1,
    control_group="never_treated",
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let coef = fitted.coef()
  let se = fitted.se()
  // The wide-format subset has n_units rows.
  inspect(fitted.n_obs_subset() > 0, content="true")
  // ATT should be within 0.2 of true theta = 1.0
  inspect((coef - theta0).abs() < 0.2, content="true")
  inspect(se > 0.0, content="true")
  // The 95% CI should contain theta0.
  let (lo, hi) = fitted.confint()
  inspect(lo < theta0, content="true")
  inspect(hi > theta0, content="true")
}

///|
/// v0.10.0: the `predictions_m()` accessor should return the
/// propensity vector clipped to `[ps_processor.clipping_threshold,
/// 1 - ps_processor.clipping_threshold]`. Set the processor to a
/// loose 0.25 clip and verify the resulting predictions are
/// bounded in `[0.25, 0.75]`.
test "did_binary_uses_ps_processor_clipping" {
  let n_units = 100
  let p = 2
  let n = n_units * 2
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t : Array[Int] = Array::make(n, 0)
  let g : Array[Int] = Array::make(n, 0)
  let id : Array[Int] = Array::make(n, 0)
  let rng = chacha8_rng(7)
  for u = 0; u < n_units; u = u + 1 {
    let is_treated = if u % 2 == 0 { 1 } else { 0 }
    for k = 0; k < 2; k = k + 1 {
      let row = 2 * u + k
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = rng.double() * 2.0 - 1.0
      }
      t[row] = k
      id[row] = u
      g[row] = is_treated
      d[row] = if is_treated == 1 && k == 1 { 1.0 } else { 0.0 }
      y[row] = (k + is_treated).to_double() + 0.05 *
        (rng.double() - 0.5)
    }
  }
  let data = DoubleMLDIDBinaryData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t,
    g,
    id,
  )
  let psp = PSProcessor::new(
    config=PSProcessorConfig::new(clipping_threshold=0.25),
  )
  let fitted = DoubleMLDIDBinary::new(
    data,
    1,
    0,
    1,
    ps_processor=psp,
    n_folds=2,
    seed=3141,
  ).fit()
  let m_hat = fitted.predictions_m()
  // Every entry should be in [0.25, 0.75].
  let mut all_in_range = true
  for i = 0; i < m_hat.length(); i = i + 1 {
    if m_hat[i] < 0.25 - 1.0e-12 || m_hat[i] > 0.75 + 1.0e-12 {
      all_in_range = false
    }
  }
  inspect(all_in_range, content="true")
}

///|
/// v0.10.0: with a balanced panel, the G+2T strata are
/// non-degenerate and `stratified_kfold` is used (vs. falling back
/// to plain `kfold`). Sanity check: changing the `ps_processor`
/// should change the cross-fitted propensity but the ATT estimate
/// should stay close to the true theta.
test "did_binary_att_invariant_under_ps_processor" {
  let n_units = 200
  let p = 2
  let n = n_units * 2
  let theta0 = 1.0
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t : Array[Int] = Array::make(n, 0)
  let g : Array[Int] = Array::make(n, 0)
  let id : Array[Int] = Array::make(n, 0)
  let rng = chacha8_rng(7)
  for u = 0; u < n_units; u = u + 1 {
    let is_treated = if u % 2 == 0 { 1 } else { 0 }
    for k = 0; k < 2; k = k + 1 {
      let row = 2 * u + k
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = rng.double() * 2.0 - 1.0
      }
      t[row] = k
      id[row] = u
      g[row] = is_treated
      d[row] = if is_treated == 1 && k == 1 { 1.0 } else { 0.0 }
      let mut y_val = 0.0
      for j = 0; j < p; j = j + 1 {
        y_val = y_val + x_flat[row * p + j]
      }
      if k == 1 && is_treated == 1 {
        y_val = y_val + theta0
      }
      y_val = y_val + 0.05 * (rng.double() - 0.5)
      y[row] = y_val
    }
  }
  let data = DoubleMLDIDBinaryData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t,
    g,
    id,
  )
  let psp_loose = PSProcessor::new(
    config=PSProcessorConfig::new(clipping_threshold=0.05),
  )
  let psp_tight = PSProcessor::new(
    config=PSProcessorConfig::new(clipping_threshold=0.01),
  )
  let fitted_loose = DoubleMLDIDBinary::new(
    data,
    1,
    0,
    1,
    ps_processor=psp_loose,
    n_folds=2,
    seed=3141,
  ).fit()
  let fitted_tight = DoubleMLDIDBinary::new(
    data,
    1,
    0,
    1,
    ps_processor=psp_tight,
    n_folds=2,
    seed=3141,
  ).fit()
  let coef_loose = fitted_loose.coef()
  let coef_tight = fitted_tight.coef()
  // Both ATTs within 0.3 of true theta = 1.0.
  inspect((coef_loose - theta0).abs() < 0.3, content="true")
  inspect((coef_tight - theta0).abs() < 0.3, content="true")
  // Tighter clip slightly shifts the estimate but they should be
  // within 0.15 of each other (the score is bounded and
  // continuous in the clip threshold).
  inspect((coef_loose - coef_tight).abs() < 0.15, content="true")
}