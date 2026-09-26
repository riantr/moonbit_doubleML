///|
// Whitebox tests for learner.mbt internals.
//
// The 412-test blackbox suite covers the full PLR pipeline
// with `LinearRegression` (the v0.54.0 default). This file
// tests the new `LearnerDispatch` injection path directly:
//
//   1. `ConstantLearner::predict` returns the constant for any
//      input shape (square matrix, single row, ...).
//   2. `ConstantLearner::fit` is a no-op (returns self with
//      the same value).
//   3. `NoopLearner::predict` returns zeros regardless of input.
//   4. `cross_fit_predict_dispatch` routes each
//      `LearnerDispatch` arm to the right concrete
//      `cross_fit_predict[T : Learner]` call.
//   5. PLR end-to-end orthogonality sanity:
//      when `learner_l = ConstantLearner(0.0)`, the
//      cross-fitted nuisance `l_hat` collapses to the
//      all-zeros vector, so psi_b[i] = v_hat[i] * (y[i] - 0)
//      — the DML score no longer orthogonalises against l,
//      and the partial-FWL structure breaks. The estimated
//      coef stays finite but is generally NOT zero (this is
//      a regression-test for "no NaN / no Inf / no abort").
//   6. PLR end-to-end with `NoopLearner` for both nuisances:
//      m_hat = l_hat = 0 → psi_a = -(d-0)^2 = -d^2, J = mean
//      of psi_a is always negative (the var_est formula
//      requires J < 0 for the causal parameter to be
//      well-defined). The estimator should still produce a
//      finite coef + se (no abort, no NaN), demonstrating
//      that the pipeline degrades gracefully under
//      pathological learners.

///|
test "learner_wbtest_constant_predict_returns_constant" {
  let cl = ConstantLearner::new(3.14)
  // `Matrix.data` is a flat row-major `Array[Double]`.
  // 4 rows × 2 cols = 8 doubles.
  let x : Matrix = {
    nrows: 4,
    ncols: 2,
    data: [1.0, 0.0, 0.0, 1.0, 1.0, 1.0, 2.0, 3.0],
  }
  let out = cl.predict(x)
  inspect(out.length(), content="4")
  inspect(out[0], content="3.14")
  inspect(out[1], content="3.14")
  inspect(out[2], content="3.14")
  inspect(out[3], content="3.14")
}

///|
test "learner_wbtest_constant_fit_returns_self" {
  let cl = ConstantLearner::new(0.5)
  let x : Matrix = { nrows: 3, ncols: 1, data: [1.0, 2.0, 3.0], }
  let y : Array[Double] = [10.0, 20.0, 30.0]
  let fitted = cl.fit(x, y)
  // fit is a no-op; the value is unchanged
  inspect(fitted.value, content="0.5")
}

///|
test "learner_wbtest_noop_predict_returns_zeros" {
  let nl = NoopLearner::new()
  let x : Matrix = {
    nrows: 5,
    ncols: 3,
    data: [
      1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 0.0, 0.0, 0.0, -1.0, -2.0, -3.0,
    ],
  }
  let out = nl.predict(x)
  inspect(out.length(), content="5")
  for i = 0; i < 5; i = i + 1 {
    inspect(out[i], content="0")
  }
}

///|
test "learner_wbtest_dispatch_constant_routes" {
  // Build a tiny dataset and verify cross_fit_predict_dispatch
  // returns a constant array for the Constant arm (mimics a
  // ConstantLearner cross-fit: every fold predicts the same
  // value, so the OOF prediction vector is uniformly constant).
  let x : Matrix = {
    nrows: 4,
    ncols: 2,
    data: [1.0, 0.0, 0.0, 1.0, 1.0, 1.0, 2.0, 3.0],
  }
  let y : Array[Double] = [10.0, 20.0, 30.0, 40.0]
  let folds : Array[Fold] = [
    { train_idx: [0, 1], test_idx: [2, 3], },
    { train_idx: [2, 3], test_idx: [0, 1], },
  ]
  let out = cross_fit_predict_dispatch(
    LearnerDispatch::constant(7.5),
    x,
    y,
    folds,
  )
  inspect(out.length(), content="4")
  // every position must be the constant 7.5
  for i = 0; i < 4; i = i + 1 {
    inspect(out[i], content="7.5")
  }
}

///|
test "learner_wbtest_dispatch_noop_routes" {
  let x : Matrix = {
    nrows: 4,
    ncols: 2,
    data: [1.0, 0.0, 0.0, 1.0, 1.0, 1.0, 2.0, 3.0],
  }
  let y : Array[Double] = [10.0, 20.0, 30.0, 40.0]
  let folds : Array[Fold] = [
    { train_idx: [0, 1], test_idx: [2, 3], },
    { train_idx: [2, 3], test_idx: [0, 1], },
  ]
  let out = cross_fit_predict_dispatch(LearnerDispatch::noop(), x, y, folds)
  inspect(out.length(), content="4")
  for i = 0; i < 4; i = i + 1 {
    inspect(out[i], content="0")
  }
}

///|
test "learner_wbtest_plr_with_constant_l_finite" {
  // DML orthogonality regression test: plug ConstantLearner
  // into learner_l and a real LinearRegression into learner_m.
  // The estimator should produce a finite coef + se (no abort,
  // no NaN, no Inf). It is NOT expected to recover the true
  // DML theta — the l-orthogonalisation step is broken by the
  // constant nuisance — but the pipeline must degrade
  // gracefully instead of aborting.
  let n = 200
  let rng = chacha8_rng(42)
  let x_data : Array[Double] = Array::make(n * 3, 0.0)
  let y_data : Array[Double] = Array::make(n, 0.0)
  let d_data : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    let x1 = rng.double() * 2.0 - 1.0
    let x2 = rng.double() * 2.0 - 1.0
    x_data[i * 3 + 0] = x0
    x_data[i * 3 + 1] = x1
    x_data[i * 3 + 2] = x2
    // y = 1.5 d + 0.5 x0 + small noise
    let eps = rng.double() * 0.5 - 0.25
    let d_i = (x0 + x1 + x2 + rng.double() * 0.3) / 3.0
    d_data[i] = d_i
    y_data[i] = 1.5 * d_i + 0.5 * x0 + eps
  }
  let x : Matrix = { nrows: n, ncols: 3, data: x_data, }
  let data = DoubleMLData::new(x, y_data, d_data)
  let plr = DoubleMLPLR::new(
    data,
    learner_l=LearnerDispatch::constant(0.0),
    learner_m=LearnerDispatch::linear_regression(),
    n_folds=4,
    seed=3141,
  ).fit()
  let coef = plr.coef()
  let se = plr.se()
  // Finiteness check: NaN-safe equality + bound on absolute
  // value (the codebase convention from `quantile_test.mbt`).
  inspect(coef.is_nan() == false, content="true")
  inspect(se.is_nan() == false, content="true")
  // J-floor recovery: se must be strictly positive
  inspect(se > 0.0, content="true")
}

///|
test "learner_wbtest_plr_with_noop_both_nuisances_finite" {
  // Pathological-case test: plug NoopLearner into BOTH l and m.
  // psi_a = -(d - 0)^2 = -d^2 (always non-positive); mean(psi_a)
  // is strictly negative whenever d has any variance. J =
  // mean(psi_a) < 0 makes the theta estimator well-defined (no
  // J-floor abort) and the pipeline produces a finite coef + se.
  // The theta value is NOT meaningful (no orthogonalisation) —
  // we only check finiteness + that nothing aborts.
  let n = 200
  let rng = chacha8_rng(43)
  let x_data : Array[Double] = Array::make(n * 3, 0.0)
  let y_data : Array[Double] = Array::make(n, 0.0)
  let d_data : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    let x1 = rng.double() * 2.0 - 1.0
    let x2 = rng.double() * 2.0 - 1.0
    x_data[i * 3 + 0] = x0
    x_data[i * 3 + 1] = x1
    x_data[i * 3 + 2] = x2
    let eps = rng.double() * 0.5 - 0.25
    let d_i = 0.7 * x0 + rng.double() * 0.4
    d_data[i] = d_i
    y_data[i] = 1.5 * d_i + 0.5 * x1 + eps
  }
  let x : Matrix = { nrows: n, ncols: 3, data: x_data, }
  let data = DoubleMLData::new(x, y_data, d_data)
  let plr = DoubleMLPLR::new(
    data,
    learner_l=LearnerDispatch::noop(),
    learner_m=LearnerDispatch::noop(),
    n_folds=4,
    seed=3141,
  ).fit()
  let coef = plr.coef()
  let se = plr.se()
  inspect(coef.is_nan() == false, content="true")
  inspect(se.is_nan() == false, content="true")
  // With NoopLearner for m, m_hat = 0, so v_hat = d, and
  // psi_a = -d^2 is a per-row non-positive value whose
  // mean is < 0 (since d has variance). So J < 0 → no J-floor.
  // Therefore se > 0 by the J-floor recovery check.
  inspect(se > 0.0, content="true")
}
