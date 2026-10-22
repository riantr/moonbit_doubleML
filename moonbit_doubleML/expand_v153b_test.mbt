// expand_v153b_test.mbt
//
// v0.153.0 -- learner accessors for the four estimators that STORED but never
// EXPOSED their learners.
//
// The v0.153.0 audit split the 14 learner-taking estimators three ways: ten
// stored and exposed, three did neither (fixed in expand_v153_test.mbt), and
// these four did the middle thing -- `DoubleMLBLP`, `DoubleMLDID`,
// `DoubleMLIIVM`, `DoubleMLSSM` each kept the pair on the struct since v0.60.0
// but published no accessor. The information was there; nothing could read it.
//
// Method note. The first version of this file fitted each estimator twice and
// compared coefficients. That was abandoned on measurement: fitting
// `DoubleMLSSM` at n=400, p=5 aborts with a precondition failure at
// `require(yi == 0.0 || yi == 1.0)` (`logistic.mbt:134`), so the gate was
// measuring the learner optimiser rather
// than the accessor. These gates therefore pattern-match the `LearnerDispatch`
// enum directly -- `learner_m()` returns the variant the constructor was given.
// No fit, no optimiser, no fragile fixture, and the assertion is exactly the
// one that matters: does the accessor report the learner it was recorded with?
//
// Every contrast names BOTH arms explicitly (logistic AND OLS). An accessor
// returning a hardcoded OLS fails the logistic arm; one returning a hardcoded
// logistic fails the OLS arm.

///|
fn v153b_ols() -> LearnerDispatch {
  LearnerDispatch::linear_regression()
}

///|
fn v153b_logistic() -> LearnerDispatch {
  LearnerDispatch::logistic_regression(LogisticRegression::new())
}

///|
fn v153b_is_logistic(l : LearnerDispatch) -> Bool {
  match l {
    LogisticRegression(_) => true
    _ => false
  }
}

///|
fn v153b_is_ols(l : LearnerDispatch) -> Bool {
  match l {
    LinearRegression(_) => true
    _ => false
  }
}

///|
/// `DoubleMLDID`. The inner estimator every DID variant delegates to, so it is
/// the most-used learner pair in the package and previously the least
/// inspectable. Data is a stochastic-treatment panel; `::new` only validates it
/// here, nothing is fitted.
test "v153b_did_reports_the_recorded_learners" {
  let n = 200
  let p = 3
  let x = Array::make(n * p, 0.0)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let rng = chacha8_rng(3141)
  for i = 0; i < n; i = i + 1 {
    let xi0 = rng.double()
    let xi1 = rng.double()
    let xi2 = rng.double()
    x[i * p + 0] = xi0
    x[i * p + 1] = xi1
    x[i * p + 2] = xi2
    let mut prob = 0.3 + 0.2 * (0.8 * xi0 - 0.5 * xi1 + 0.3 * xi2)
    if prob < 0.05 {
      prob = 0.05
    }
    if prob > 0.95 {
      prob = 0.95
    }
    d[i] = if rng.double() < prob { 1.0 } else { 0.0 }
    y[i] = d[i] + 0.5 * xi0 + 0.2 * xi1 + 0.1 * rng.double()
  }
  let data = DoubleMLDIDData::new(Matrix::from_array(x, n, p), y, d)
  let mk = fn(ml_g : LearnerDispatch, ml_m : LearnerDispatch) {
    DoubleMLDID::new(data, n_folds=2, n_rep=1, seed=3141, ml_g~, ml_m~)
  }
  // OLS arm
  let a = mk(v153b_ols(), v153b_ols())
  assert_true(v153b_is_ols(a.learner_g()))
  assert_true(v153b_is_ols(a.learner_m()))
  // logistic arm -- this is what kills a hardcoded-OLS accessor
  let b = mk(v153b_logistic(), v153b_logistic())
  assert_true(v153b_is_logistic(b.learner_g()))
  assert_true(v153b_is_logistic(b.learner_m()))
}

///|
/// `DoubleMLSSM`. Note this estimator's `ml_m` DEFAULT is logistic since
/// v0.138.0 -- the single measured hazard in the package -- so the default arm
/// here is deliberately the logistic one, which is also what makes the OLS arm
/// a real contrast rather than a restatement of the default.
test "v153b_ssm_reports_the_recorded_learners" {
  let mk = fn(ml_g : LearnerDispatch, ml_m : LearnerDispatch) {
    DoubleMLSSM::new(
      v107_ssm_dgp(chacha8_rng(3141), 400, 5, 1.0),
      n_folds=2,
      n_rep=1,
      seed=3141,
      ml_g~,
      ml_m~,
    )
  }
  let a = mk(v153b_ols(), v153b_ols())
  assert_true(v153b_is_ols(a.learner_g()))
  assert_true(v153b_is_ols(a.learner_m()))
  let b = mk(v153b_logistic(), v153b_logistic())
  assert_true(v153b_is_logistic(b.learner_g()))
  assert_true(v153b_is_logistic(b.learner_m()))
}

///|
/// `DoubleMLIIVM` -- the only estimator in the package with a third learner
/// slot, `ml_r` (the selection propensity). All three accessors are checked;
/// an `ml_r` accessor that returned the wrong slot would still pass a
/// two-slot gate, so the third is asserted separately.
test "v153b_iivm_reports_the_recorded_learners" {
  let n = 200
  let x_flat = Array::make(n, 0.0)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let z = Array::make(n, 0.0)
  let rng = chacha8_rng(3141)
  for i = 0; i < n; i = i + 1 {
    let xi = rng.double()
    x_flat[i] = xi
    z[i] = 0.7 * xi + 0.3 * rng.double()
    let mut prob = 0.3 + 0.2 * xi
    if prob < 0.05 {
      prob = 0.05
    }
    if prob > 0.95 {
      prob = 0.95
    }
    d[i] = if rng.double() < prob { 1.0 } else { 0.0 }
    y[i] = 1.0 * d[i] + 0.4 * xi + 0.1 * rng.double()
  }
  // `DoubleMLIIVMData::new` takes `x` as a Matrix, unlike `DoubleMLDIDData`.
  let data = DoubleMLIIVMData::new(Matrix::from_array(x_flat, n, 1), y, d, z)
  let mk = fn(
    ml_g : LearnerDispatch,
    ml_m : LearnerDispatch,
    ml_r : LearnerDispatch,
  ) {
    DoubleMLIIVM::new(data, n_folds=2, seed=3141, ml_g~, ml_m~, ml_r~)
  }
  let a = mk(v153b_ols(), v153b_ols(), v153b_ols())
  assert_true(v153b_is_ols(a.learner_g()))
  assert_true(v153b_is_ols(a.learner_m()))
  assert_true(v153b_is_ols(a.learner_r()))
  let b = mk(v153b_logistic(), v153b_logistic(), v153b_logistic())
  assert_true(v153b_is_logistic(b.learner_g()))
  assert_true(v153b_is_logistic(b.learner_m()))
  assert_true(v153b_is_logistic(b.learner_r()))
}

///|
/// `DoubleMLBLP` -- single learner slot (`ml_g`). The BLP policy score has no
/// propensity term, so there is no `ml_m` to expose, and there is deliberately
/// no `learner_m` accessor to assert absent.
test "v153b_blp_reports_the_recorded_learner" {
  let basis = Matrix::zeros(3, 2)
  let signal = [1.0, 2.0, 3.0]
  let a = DoubleMLBLP::new(basis, signal, ml_g=v153b_ols())
  assert_true(v153b_is_ols(a.learner_g()))
  let b = DoubleMLBLP::new(basis, signal, ml_g=v153b_logistic())
  assert_true(v153b_is_logistic(b.learner_g()))
}
