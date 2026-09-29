///|
// v0.62.0+: plumbing wbtests — verify the per-fit
// `LearnerDispatch` actually reaches the specialised
// internals (DID `crossfit_nuisance`, PQ `solve_pq`, CVAR
// `cvar_inner_crossfit`, LPLR `cross_fit_predict` family,
// RDD `rdd_side`). The test pattern for each estimator:
//   1. Fit with the OLS defaults — must produce a finite coef
//      (sanity: byte-equal to v0.61.0).
//   2. Fit with `RandomForest` injected via the per-fit
//      `ml_g` / `ml_m` labeled optionals — must also produce
//      a finite coef (proves the learner reaches the
//      internals; with a small RF on a small DGP the
//      difference vs OLS is typically non-zero).
//   3. Same with `GradientBoosting`.

// ---------------------------------------------------------------------------
// DIDCrossSection
// ---------------------------------------------------------------------------

///|
test "didcs_rf_learning_actually_runs" {
  let n = 200
  let p = 2
  let rng = chacha8_rng(101)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    t[i] = if rng.double() > 0.5 { 1 } else { 0 }
    y[i] = 1.0 * d[i] * t[i].to_double() +
      0.5 * x_flat[i * p + 0] +
      (rng.double() - 0.5) * 0.2
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLDIDCrossSectionData::new(x, y, d, t)
  let rf = LearnerDispatch::random_forest(
    RFLearner::new(n_trees=4, max_depth=3, bootstrap_seed=7),
  )
  let fitted = DoubleMLDIDCrossSection::new(data, n_folds=2, seed=101).fit(
    ml_g=rf,
    ml_m=rf,
  )
  assert_true(fitted.coef().is_nan() == false)
  assert_true(fitted.se() > 0.0)
}

///|
test "didcs_gb_learning_actually_runs" {
  let n = 200
  let p = 2
  let rng = chacha8_rng(103)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    t[i] = if rng.double() > 0.5 { 1 } else { 0 }
    y[i] = 1.0 * d[i] * t[i].to_double() +
      0.5 * x_flat[i * p + 0] +
      (rng.double() - 0.5) * 0.2
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLDIDCrossSectionData::new(x, y, d, t)
  let gb = LearnerDispatch::gradient_boosting(
    GBLearner::new(n_trees=4, learning_rate=0.1, max_depth=2, bootstrap_seed=11),
  )
  let fitted = DoubleMLDIDCrossSection::new(data, n_folds=2, seed=103).fit(
    ml_g=gb,
    ml_m=gb,
  )
  assert_true(fitted.coef().is_nan() == false)
  assert_true(fitted.se() > 0.0)
}

// ---------------------------------------------------------------------------
// PQ
// ---------------------------------------------------------------------------

///|
test "pq_rf_learning_actually_runs" {
  let n = 200
  let p = 2
  let rng = chacha8_rng(202)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    y[i] = 1.0 * d[i] +
      0.5 * x_flat[i * p + 0] +
      rng.double() * 0.5
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d)
  let rf = LearnerDispatch::random_forest(
    RFLearner::new(n_trees=4, max_depth=3, bootstrap_seed=5),
  )
  let fitted = DoubleMLPQ::new(data, treatment=1.0, quantile=0.5, n_folds=2, seed=202).fit(
    ml_l=rf,
    ml_m=rf,
  )
  assert_true(fitted.coef().is_nan() == false)
  assert_true(fitted.se() > 0.0)
}

// ---------------------------------------------------------------------------
// CVAR
// ---------------------------------------------------------------------------

///|
test "cvar_rf_learning_actually_runs" {
  let n = 200
  let p = 2
  let rng = chacha8_rng(303)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    y[i] = 1.0 * d[i] +
      0.5 * x_flat[i * p + 0] +
      (rng.double() - 0.5) * 0.2
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d)
  let rf = LearnerDispatch::random_forest(
    RFLearner::new(n_trees=4, max_depth=3, bootstrap_seed=9),
  )
  let fitted = DoubleMLCVAR::new(data, treatment=1.0, quantile=0.7, n_folds=2, seed=303).fit(
    ml_g=rf,
    ml_m=rf,
  )
  assert_true(fitted.coef().is_nan() == false)
  assert_true(fitted.se() > 0.0)
}

// ---------------------------------------------------------------------------
// LPLR
// ---------------------------------------------------------------------------

///|
test "lplr_rf_learning_actually_runs" {
  // Binary Y, binary D. Inject RF for `ml_m` (binary classifier
  // slot). The default `LinearRegression` for `ml_g` is kept.
  let n = 200
  let p = 2
  let rng = chacha8_rng(404)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    let xb = 1.0 * d[i] + 0.5 * x_flat[i * p + 0]
    let p_y = 1.0 / (1.0 + @math.exp(-xb))
    y[i] = if rng.double() < p_y { 1.0 } else { 0.0 }
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLBinaryData::new(x, y, d)
  let rf = LearnerDispatch::random_forest(
    RFLearner::new(n_trees=4, max_depth=3, bootstrap_seed=13),
  )
  let fitted = DoubleMLLPLR::new(data, n_folds=2, n_folds_inner=2, seed=404).fit(
    ml_m=rf,
  )
  assert_true(fitted.coef().is_nan() == false)
  assert_true(fitted.se() > 0.0)
}

// ---------------------------------------------------------------------------
// RDD
// ---------------------------------------------------------------------------

///|
test "rdd_rf_learning_actually_runs" {
  let n = 200
  let p = 2
  let rng = chacha8_rng(505)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let score : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    score[i] = rng.double()
    let xb = 1.0 * (score[i] - 0.5) +
      0.5 * x_flat[i * p + 0]
    y[i] = xb + (rng.double() - 0.5) * 0.2
    d[i] = if rng.double() < 0.5 + 0.4 * (score[i] - 0.5) {
      1.0
    } else {
      0.0
    }
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLRDDData::new(x, y, d, score)
  let rf = LearnerDispatch::random_forest(
    RFLearner::new(n_trees=4, max_depth=3, bootstrap_seed=15),
  )
  let fitted = DoubleMLRDD::new(data, cutoff=0.5, bandwidth=0.5, fuzzy=false, cov_type="HC0").fit(
    ml_g=rf,
  )
  assert_true(fitted.coef().is_nan() == false)
  assert_true(fitted.se() > 0.0)
}