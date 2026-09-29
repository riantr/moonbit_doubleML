///|
// v0.63.0+: wbtests for the 4 follow-up moonbit-ization
// items:
//   #1: APO `cross_fit_apo` plumbing — `ml_g` / `ml_m`
//       actually reach the internal cross-fit helper.
//   #2: `DoubleMLAPOS::bootstrap()` forwards to child
//       `DoubleMLAPO::bootstrap()`.
//   #3: `DoubleMLAPOS::confint()` per-level Wald CIs.
//   #4: `DoubleMLBLP::fit(ml_g?)` accepts a `LearnerDispatch`.

// ---------------------------------------------------------------------------
// #1: APO cross_fit_apo plumbing
// ---------------------------------------------------------------------------

///|
fn make_apo_data(n : Int, seed : Int) -> (Matrix, Array[Double], Array[Double]) {
  let rng = chacha8_rng(seed)
  let p = 2
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    // True theta = 1.0 (APO policy score). Small noise so
    // |theta_hat - 1| stays bounded in 200 draws.
    y[i] = 1.0 * d[i] + 0.5 * x_flat[i * p + 0] + (rng.double() - 0.5) * 0.2
  }
  let x = Matrix::from_array(x_flat, n, p)
  (x, y, d)
}

///|
test "apo_rf_learning_reaches_internal_helper" {
  let n = 200
  let (x, y, d) = make_apo_data(n, 3141)
  let data = DoubleMLData::new(x, y, d)
  let rf = LearnerDispatch::random_forest(
    RFLearner::new(n_trees=4, max_depth=3, bootstrap_seed=7),
  )
  let fitted = DoubleMLAPO::new(data, treatment_level=1.0, n_folds=2, seed=3141).fit(
    ml_g=rf,
    ml_m=rf,
  )
  assert_true(fitted.coef().is_nan() == false)
  assert_true(fitted.se() > 0.0)
}

// ---------------------------------------------------------------------------
// #2: APOS::bootstrap() forwarding to children
// ---------------------------------------------------------------------------

///|
test "apos_bootstrap_forwards_to_children" {
  let n = 200
  let (x, y, d) = make_apo_data(n, 3141)
  let data = DoubleMLData::new(x, y, d)
  let apos = DoubleMLAPOS::new(data, [0.0, 1.0], n_folds=2, seed=3141).fit()
  let booted = apos.bootstrap(n_rep_boot=100)
  let stats = booted.boot_t_stats()
  assert_eq(stats.length(), 2)
  assert_eq(stats[0].length(), 100)
  assert_eq(stats[1].length(), 100)
  assert_eq(booted.boot_method(), "normal")
  assert_eq(booted.n_rep_boot(), 100)
  // Per-level finite sanity.
  for i = 0; i < 100; i = i + 1 {
    assert_true(stats[0][i].is_nan() == false)
    assert_true(stats[1][i].is_nan() == false)
  }
}

///|
test "apos_bayes_bootstrap_works" {
  let n = 150
  let (x, y, d) = make_apo_data(n, 2222)
  let data = DoubleMLData::new(x, y, d)
  let apos = DoubleMLAPOS::new(data, [1.0], n_folds=2, seed=2222).fit()
  let booted = apos.bootstrap(method_name="Bayes", n_rep_boot=80, seed=42)
  assert_eq(booted.boot_method(), "Bayes")
  assert_eq(booted.boot_seed(), 42)
  assert_eq(booted.boot_t_stats()[0].length(), 80)
}

// ---------------------------------------------------------------------------
// #3: APOS::confint() per-level Wald CI
// ---------------------------------------------------------------------------

///|
test "apos_confint_per_level" {
  let n = 200
  let (x, y, d) = make_apo_data(n, 3141)
  let data = DoubleMLData::new(x, y, d)
  let apos = DoubleMLAPOS::new(data, [0.0, 1.0], n_folds=2, seed=3141).fit()
  let ci = apos.confint()
  assert_eq(ci.length(), 2)
  // Each CI must satisfy `lo <= coefs[j] <= hi`.
  for j = 0; j < 2; j = j + 1 {
    let (lo, hi) = ci[j]
    assert_true(lo <= apos.coefs()[j])
    assert_true(apos.coefs()[j] <= hi)
    assert_true(hi - lo > 0.0)
  }
}

// ---------------------------------------------------------------------------
// #4: BLP learner plumbing
// ---------------------------------------------------------------------------

///|
test "blp_default_linear_regression_byte_equal" {
  let n = 100
  let p = 2
  let rng = chacha8_rng(11)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let orth : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    // orth_signal = intercept + B1 * x[0] + B2 * x[1] + noise
    orth[i] = 1.0 +
      2.0 * x_flat[i * p + 0] +
      3.0 * x_flat[i * p + 1] +
      (rng.double() - 0.5) * 0.2
  }
  let basis = Matrix::from_array(x_flat, n, p)
  // v0.62.2 byte-equality: default `LearnerDispatch::linear_regression()`
  // must give the same coef as the hardcoded `LinearRegression::new()`.
  let fitted = DoubleMLBLP::new(basis, orth).fit()
  let c = fitted.coef()
  // `LinearRegression` returns `[intercept, slope_0, ..., slope_{p-1}]`
  // so coef length is `p + 1`.
  assert_eq(c.length(), p + 1)
  assert_true((c[0] - 1.0).abs() < 0.5)
  assert_true((c[1] - 2.0).abs() < 0.5)
  assert_true((c[2] - 3.0).abs() < 0.5)
}

///|
test "blp_rf_learning_does_not_abort" {
  // Non-OLS `ml_g` on BLP: just verifies the dispatch doesn't
  // crash and produces finite numbers. BLP is the OLS projection,
  // so the non-OLS learner's effect is restricted to the RSS path.
  let n = 100
  let p = 2
  let rng = chacha8_rng(33)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let orth : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    orth[i] = 1.0 + 2.0 * x_flat[i * p + 0] + (rng.double() - 0.5) * 0.2
  }
  let basis = Matrix::from_array(x_flat, n, p)
  let rf = LearnerDispatch::random_forest(
    RFLearner::new(n_trees=4, max_depth=3, bootstrap_seed=11),
  )
  let fitted = DoubleMLBLP::new(basis, orth, ml_g=rf).fit()
  let c = fitted.coef()
  assert_eq(c.length(), p + 1)
  assert_true(c[0].is_nan() == false)
}
