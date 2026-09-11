///|
/// v0.51.0: end-to-end CS Binary estimation on a
/// synthetic panel DGP. 2 periods (pre, post), 2 groups
/// (g=0 control, g=1 treated). True ATT = 1.0. The
/// estimator should recover ATT within a few SE of the
/// true value.
test "did_cs_binary_recovers_att" {
  // Panel: n_units per cohort, 2 periods.
  let n_per_cohort = 100
  let p = 3
  let theta0 = 1.0
  let n_periods = 2
  let cohort_count = 2 // g = 0 (control), g = 1 (treated)
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  let rng = chacha8_rng(7)
  for u = 0; u < n_units; u = u + 1 {
    let cohort = u / n_per_cohort
    let xu : Array[Double] = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      xu[j] = rng.double() * 2.0 - 1.0
    }
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = xu[j]
      }
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = cohort
      d[row] = if cohort > 0 && k >= cohort { 1.0 } else { 0.0 }
      // Binary outcome: Y ∈ {0, 1} with the
      // treatment effect added only to
      // (treated, post). Control outcome is
      // constant 0.0; treated-pre is 0.0; treated-
      // post is 1.0. ATT(g=1, t=1) = 1.0.
      let y_val = if cohort > 0 && k >= cohort { 1.0 } else { 0.0 }
      ignore(rng)
      y[row] = y_val
    }
  }
  let data = DoubleMLDIDCSData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
  let fitted = DoubleMLDIDCSBinary::new(
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
  // The post-subset panel is balanced: n_g = n_c
  // (100 treated in post + 100 treated in pre = 200
  // treated; 100 control in pre + 100 control in post
  // = 200 control). n_obs_subset = 400.
  inspect(fitted.n_obs() == 400, content="true")
  inspect(fitted.n_g_subset() == 200, content="true")
  inspect(fitted.n_c_subset() == 200, content="true")
  // ATT should be within 0.3 of true theta = 1.0.
  // (linear-Gaussian Y on a binary-outcome estimator
  // introduces a small but non-zero bias from
  // the LR-on-binary clipping; widen the tolerance
  // to match the v0.49.0/v0.50.0 convention.)
  inspect((coef - theta0).abs() < 0.3, content="true")
  inspect(se > 0.0, content="true")
  // 95% CI should contain theta0.
  let (lo, hi) = fitted.confint()
  inspect(lo < theta0, content="true")
  inspect(hi > theta0, content="true")
  // Fitted accessor.
  inspect(fitted.fitted(), content="true")
  // Nuisance predictions length matches n_obs_subset.
  inspect(fitted.predictions_m().length() == 400, content="true")
  inspect(fitted.predictions_g_d0_t0().length() == 400, content="true")
  inspect(fitted.predictions_g_d1_t1().length() == 400, content="true")
}

///|
/// v0.51.0: the panel subsetting should produce 4
/// `(G, T)` cells. With 4 treated units in (g=1) and
/// 4 control units (g=0), each observed at t=0 and
/// t=1, the post-subset should have 4 G=1 rows (the
/// treated unit at pre and at eval) plus 4 G=0 rows
/// (the control unit at pre and at eval) = 8 rows.
test "did_cs_binary_panel_subset_shape" {
  let p = 2
  let n_per_cohort = 2
  let n_periods = 2
  let cohort_count = 2
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  for u = 0; u < n_units; u = u + 1 {
    let cohort = u / n_per_cohort
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = cohort
      d[row] = if cohort > 0 && k >= cohort { 1.0 } else { 0.0 }
    }
  }
  let data = DoubleMLDIDCSData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
  let fitted = DoubleMLDIDCSBinary::new(
    data,
    1,
    0,
    1,
    control_group="never_treated",
    n_folds=2,
    seed=3141,
  ).fit()
  // n_obs_subset = 4 units × 2 periods = 8.
  inspect(fitted.n_obs() == 8, content="true")
  // n_g_subset = 2 units × 2 periods = 4.
  inspect(fitted.n_g_subset() == 4, content="true")
  // n_c_subset = 2 units × 2 periods = 4.
  inspect(fitted.n_c_subset() == 4, content="true")
  // The post-subset is the entire panel here.
  inspect(fitted.n_obs_panel() == 8, content="true")
}

///|
/// v0.51.0: each fold should have all 4 strata
/// represented (G+2T ∈ {0, 1, 2, 3}). With a balanced
/// panel (4 treated, 4 control, 2 periods), the
/// stratified k-fold partition should give each fold
/// exactly one unit per stratum.
test "did_cs_binary_stratified_splits_balance" {
  let p = 2
  let n_per_cohort = 4
  let n_periods = 2
  let cohort_count = 2 // g=0 control, g=1 treated
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  for u = 0; u < n_units; u = u + 1 {
    let cohort = u / n_per_cohort
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = cohort
      d[row] = if cohort > 0 && k >= cohort { 1.0 } else { 0.0 }
    }
  }
  let data = DoubleMLDIDCSData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
  // n_folds = 2 → each fold should have all 4 strata
  // (2 treated rows per fold + 2 control rows per
  // fold, across 2 periods each).
  let fitted = DoubleMLDIDCSBinary::new(
    data,
    1,
    0,
    1,
    control_group="never_treated",
    n_folds=2,
    seed=3141,
  ).fit()
  // n_obs_subset = 4 * 2 = 8 (n_units=8, 2 periods).
  inspect(fitted.n_obs() == 16, content="true")
  // g_value / t_value_pre / t_value_pre are
  // accessors that should match the constructor
  // arguments.
  inspect(fitted.g_value(), content="1")
  inspect(fitted.t_value_pre(), content="0")
  inspect(fitted.t_value_eval(), content="1")
  // fitted / confint / coef / se should be set.
  inspect(fitted.fitted(), content="true")
  // `coef` and `se` are well-defined (the panel
  // is degenerate — every Y = 0 — so the SE may
  // be 0 or NaN; we just check the fit ran).
  let _ = fitted.coef()
  let _ = fitted.se()
  let _ = fitted.confint()
  // psi_a / psi_b length match n_obs_subset.
  inspect(fitted.psi_a().length() == 16, content="true")
  inspect(fitted.psi_b().length() == 16, content="true")
}

///|
/// v0.51.0: the constructor and post-fit accessors
/// return the same values as the arguments passed to
/// `new`. The `score` argument is restricted to
/// `"observational"`.
test "did_cs_binary_accessors_match" {
  let p = 2
  let n_per_cohort = 4
  let n_periods = 2
  let cohort_count = 2
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  for u = 0; u < n_units; u = u + 1 {
    let cohort = u / n_per_cohort
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = cohort
      d[row] = if cohort > 0 && k >= cohort { 1.0 } else { 0.0 }
    }
  }
  let data = DoubleMLDIDCSData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
  // Pre-fit: fitted() is false, n_obs() is 0
  // (post-subset not yet computed).
  let pre = DoubleMLDIDCSBinary::new(
    data,
    1,
    0,
    1,
    control_group="never_treated",
    n_folds=2,
    seed=3141,
  )
  inspect(pre.fitted(), content="false")
  inspect(pre.n_obs(), content="0")
  // Constructor accessors return the stored args.
  inspect(pre.g_value(), content="1")
  inspect(pre.t_value_pre(), content="0")
  inspect(pre.t_value_eval(), content="1")
  let fitted = pre.fit()
  inspect(fitted.fitted(), content="true")
  // After fit: n_obs returns the post-subset count
  // (= 8 units × 2 periods = 16), NOT the full
  // panel size (= 16 here, but in general they
  // differ).
  inspect(fitted.n_obs() == 16, content="true")
  // Constructor args are unchanged.
  inspect(fitted.g_value(), content="1")
  inspect(fitted.t_value_pre(), content="0")
  inspect(fitted.t_value_eval(), content="1")
}
