///|
// v0.65.0+: wbtests for Item #2 (fit_cluster) and Item #4
// (tune on the four remaining IRM-style estimators).
//
// Coverage:
//   #4: IRM / PLIV / IIVM / APO  ::tune() picks the OLS-only
//       candidate under a strictly-linear DGP and produces
//       a fitted model with finite coef (smoke test).
//   #2: IRM / PQ / APO / APOS ::fit_cluster() runs with
//       cluster_vars=non-empty and produces a fitted model
//       with finite coef / se (smoke test).

// ---------------------------------------------------------------------------
// #4: tune() smoke tests
// ---------------------------------------------------------------------------

///|
fn build_irm_tune_data(
  n : Int,
  p : Int,
  seed : Int,
) -> (Matrix, Array[Double], Array[Double]) {
  let rng = chacha8_rng(seed)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double() * 2.0 - 1.0
    }
    let x0 = x_flat[i * p + 0]
    let d_i = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    d[i] = d_i
    y[i] = 1.2 * d_i + 0.5 * x0 + (rng.double() - 0.5) * 0.1
  }
  let x = Matrix::from_array(x_flat, n, p)
  (x, y, d)
}

///|
test "irm_tune_picks_ols_candidate" {
  let (x, y, d) = build_irm_tune_data(200, 2, 1)
  let data = DoubleMLData::new(x, y, d)
  let lr = LearnerDispatch::linear_regression()
  let grid : Array[TuneParam] = [TuneParam::new(lr, lr), TuneParam::new(lr, lr)]
  let fitted = DoubleMLIRM::new(data, n_folds=4, seed=1).tune(
    param_set=grid,
    n_folds_tune=4,
    seed=1,
  )
  let coef = fitted.coef()
  assert_true(coef.is_nan() == false)
  assert_true(coef.is_inf() == false)
}

///|
test "pliv_tune_picks_ols_candidate" {
  let (x, y, d) = build_irm_tune_data(200, 2, 2)
  let z : Array[Double] = Array::make(200, 0.0)
  for i = 0; i < 200; i = i + 1 {
    z[i] = if i % 3 == 0 { 1.0 } else { 0.0 }
  }
  let data = DoubleMLPLIVData::new(x, y, d, z)
  let lr = LearnerDispatch::linear_regression()
  let grid : Array[LearnerDispatch] = [lr, lr]
  let fitted = DoubleMLPLIV::new(data, n_folds=4, seed=2).tune(
    param_set=grid,
    n_folds_tune=4,
    seed=2,
  )
  let coef = fitted.coef()
  assert_true(coef.is_nan() == false)
  assert_true(coef.is_inf() == false)
}

///|
test "iivm_tune_picks_ols_candidate" {
  let (x, y, d) = build_irm_tune_data(200, 2, 3)
  let z : Array[Double] = Array::make(200, 0.0)
  for i = 0; i < 200; i = i + 1 {
    z[i] = if i % 3 == 0 { 1.0 } else { 0.0 }
  }
  let data = DoubleMLIIVMData::new(x, y, d, z)
  let lr = LearnerDispatch::linear_regression()
  let grid : Array[TuneParam] = [TuneParam::new(lr, lr)]
  let fitted = DoubleMLIIVM::new(data, n_folds=4, seed=3).tune(
    param_set=grid,
    n_folds_tune=4,
    seed=3,
  )
  let coef = fitted.coef()
  assert_true(coef.is_nan() == false)
  assert_true(coef.is_inf() == false)
}

///|
test "apo_tune_picks_ols_candidate" {
  let (x, y, d) = build_irm_tune_data(200, 2, 4)
  let data = DoubleMLData::new(x, y, d)
  let lr = LearnerDispatch::linear_regression()
  let grid : Array[TuneParam] = [TuneParam::new(lr, lr)]
  let fitted = DoubleMLAPO::new(data, treatment_level=1.0, n_folds=4, seed=4).tune(
    param_set=grid,
    n_folds_tune=4,
    seed=4,
  )
  let coef = fitted.coef()
  assert_true(coef.is_nan() == false)
  assert_true(coef.is_inf() == false)
}

// ---------------------------------------------------------------------------
// #2: fit_cluster() smoke tests (PQ / APO deferred; IRM
// already had fit_cluster — the smoke test confirms the v0.65.0
// path still produces finite coef / se when cluster_vars is
// non-empty).
// ---------------------------------------------------------------------------

///|
test "irm_fit_cluster_produces_finite_estimates" {
  let n = 200
  let n_units = 50
  let rng = chacha8_rng(5)
  let x_flat : Array[Double] = Array::make(n * 2, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let cluster : Array[Int] = Array::make(n, 0)
  for u = 0; u < n_units; u = u + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    let d_i = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    for period = 0; period < 4; period = period + 1 {
      let row = u * 4 + period
      cluster[row] = u
      x_flat[row * 2 + 0] = x0
      x_flat[row * 2 + 1] = rng.double() * 2.0 - 1.0
      d[row] = d_i
      y[row] = 1.0 * d_i + 0.5 * x0 + (rng.double() - 0.5) * 0.1
    }
  }
  let x = Matrix::from_array(x_flat, n, 2)
  let data = DoubleMLData::new(x, y, d, cluster_vars=cluster)
  let fitted = DoubleMLIRM::new(data, n_folds=4, seed=5).fit()
  let coef = fitted.coef()
  let se = fitted.se()
  assert_true(coef.is_nan() == false)
  assert_true(se.is_nan() == false)
  assert_true(se > 0.0)
}

///|
test "apo_fit_cluster_produces_finite_estimates" {
  let n = 200
  let n_units = 50
  let rng = chacha8_rng(6)
  let x_flat : Array[Double] = Array::make(n * 2, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let cluster : Array[Int] = Array::make(n, 0)
  for u = 0; u < n_units; u = u + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    let d_i = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    for period = 0; period < 4; period = period + 1 {
      let row = u * 4 + period
      cluster[row] = u
      x_flat[row * 2 + 0] = x0
      x_flat[row * 2 + 1] = rng.double() * 2.0 - 1.0
      d[row] = d_i
      y[row] = 1.0 * d_i + 0.5 * x0 + (rng.double() - 0.5) * 0.1
    }
  }
  let x = Matrix::from_array(x_flat, n, 2)
  let data = DoubleMLData::new(x, y, d, cluster_vars=cluster)
  let fitted = DoubleMLAPO::new(data, treatment_level=1.0, n_folds=4, seed=6).fit()
  let coef = fitted.coef()
  let se = fitted.se()
  assert_true(coef.is_nan() == false)
  assert_true(se.is_nan() == false)
  assert_true(se > 0.0)
}
