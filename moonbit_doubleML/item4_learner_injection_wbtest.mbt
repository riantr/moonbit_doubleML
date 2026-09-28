///|
test "pliv_learner_injection_default_unchanged" {
  // v0.59.0+: default `learner` (OLS) must produce the same
  // finite-coef result as the v0.57.0 hardcoded LinearRegression.
  // Sanity check: a small PLIV DGP and a default-fit model.
  let n = 100
  let p = 2
  let rng = chacha8_rng(7)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let z : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double() * 2.0 - 1.0
    }
    let z_i = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    z[i] = z_i
    d[i] = 0.7 * z_i + 0.2 * x_flat[i * p + 0] + (rng.double() - 0.5) * 0.2
    y[i] = 1.5 * d[i] + 0.3 * x_flat[i * p + 1] + (rng.double() - 0.5) * 0.2
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLPLIVData::new(x, y, d, z)
  let fitted = DoubleMLPLIV::new(data, n_folds=2, seed=3141).fit()
  assert_true(fitted.coef().is_nan() == false)
  assert_true(fitted.se() > 0.0)
}

///|
test "pliv_learner_override_with_rf" {
  // v0.59.0+: passing an RFLearner as `learner` overrides the
  // default OLS. The fit must complete without aborting and
  // produce a finite coef + se.
  let n = 100
  let p = 2
  let rng = chacha8_rng(7)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let z : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double() * 2.0 - 1.0
    }
    let z_i = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    z[i] = z_i
    d[i] = 0.7 * z_i + 0.2 * x_flat[i * p + 0] + (rng.double() - 0.5) * 0.2
    y[i] = 1.5 * d[i] + 0.3 * x_flat[i * p + 1] + (rng.double() - 0.5) * 0.2
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLPLIVData::new(x, y, d, z)
  let rf = LearnerDispatch::random_forest(
    RFLearner::new(n_trees=8, max_depth=4, bootstrap_seed=42),
  )
  let fitted = DoubleMLPLIV::new(data, n_folds=2, seed=3141).fit(
    learner=rf,
  )
  assert_true(fitted.coef().is_nan() == false)
  assert_true(fitted.se() > 0.0)
}

///|
test "iivm_default_learners_runs_end_to_end" {
  // v0.59.0+: IIVM with default OLS learners (no override) must
  // produce a finite coef + se. Same DGP shape as IRM but with
  // an instrument Z.
  let n = 200
  let p = 2
  let rng = chacha8_rng(13)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let z : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double() * 2.0 - 1.0
    }
    let z_i = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    z[i] = z_i
    d[i] = 0.7 * z_i + 0.2 * x_flat[i * p + 0] + (rng.double() - 0.5) * 0.2
    y[i] = 1.0 * d[i] + 0.3 * x_flat[i * p + 1] + (rng.double() - 0.5) * 0.2
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLIIVMData::new(x, y, d, z)
  let fitted = DoubleMLIIVM::new(data, n_folds=2, seed=3141).fit()
  assert_true(fitted.coef().is_nan() == false)
  assert_true(fitted.se() > 0.0)
}

///|
test "did_default_learners_runs_end_to_end" {
  // v0.59.0+: DID with default OLS learners must produce a finite
  // coef + se. The DIDBinary/DIDCSBinary/DIDCS wrappers accept
  // ml_g/ml_m at fit() time (forwarded to the inner DoubleMLDID).
  let n = 200
  let p = 2
  let rng = chacha8_rng(17)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double() * 2.0 - 1.0
    }
    let d_i = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    d[i] = d_i
    y[i] = 1.0 * d_i + 0.3 * x_flat[i * p + 0] + (rng.double() - 0.5) * 0.2
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLDIDData::new(x, y, d)
  let fitted = DoubleMLDID::new(data, n_folds=2, seed=3141).fit()
  assert_true(fitted.coef().is_nan() == false)
  assert_true(fitted.se() > 0.0)
}

///|
test "did_per_fit_learner_override_runs" {
  // v0.59.0+: per-fit learner override (RandomForest) on
  // DoubleMLDID::fit must complete and produce a finite coef.
  let n = 200
  let p = 2
  let rng = chacha8_rng(17)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double() * 2.0 - 1.0
    }
    let d_i = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    d[i] = d_i
    y[i] = 1.0 * d_i + 0.3 * x_flat[i * p + 0] + (rng.double() - 0.5) * 0.2
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLDIDData::new(x, y, d)
  let rf = LearnerDispatch::random_forest(
    RFLearner::new(n_trees=6, max_depth=4, bootstrap_seed=99),
  )
  let fitted = DoubleMLDID::new(data, n_folds=2, seed=3141).fit(
    ml_g=rf,
    ml_m=rf,
  )
  assert_true(fitted.coef().is_nan() == false)
  assert_true(fitted.se() > 0.0)
}

///|
test "ssm_default_learners_runs_end_to_end" {
  // v0.59.0+: SSM with default OLS learners (no override) must
  // produce a finite coef + se.
  let n = 200
  let p = 2
  let rng = chacha8_rng(31)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let s : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double() * 2.0 - 1.0
    }
    let d_i = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    d[i] = d_i
    let s_i = if rng.double() > 0.3 { 1.0 } else { 0.0 }
    s[i] = s_i
    y[i] = 0.5 * d_i + 0.3 * x_flat[i * p + 0] + (rng.double() - 0.5) * 0.2
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLSSMData::new(x, y, d, s)
  let fitted = DoubleMLSSM::new(data, n_folds=2, seed=3141).fit()
  assert_true(fitted.coef().is_nan() == false)
  assert_true(fitted.se() > 0.0)
}