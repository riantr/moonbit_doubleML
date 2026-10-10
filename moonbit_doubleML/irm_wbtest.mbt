///|
test "irm_learner_g_accessor_returns_default" {
  // v0.59.0+: a default IRM (no learner override) must report
  // its constructor-time `ml_g` / `ml_m` via the accessors.
  //
  // v0.132.0: the DEFAULTS DIVERGE, deliberately. `ml_g` is the OUTCOME
  // nuisance, so it stays OLS. `ml_m` is the PROPENSITY, and upstream
  // requires a classifier there: `DoubleMLIRM`'s `ml_m` is a mandatory
  // positional arg validated `_check_learner(ml_m, "ml_m", regressor=False,
  // classifier=True)` (irm.py:157) and read back with `predict_proba`
  // (irm.py:161). A regressor has no `predict_proba` at all.
  //
  // This is not cosmetic. A propensity enters the score as `1 / m_hat`;
  // with the old OLS default, `propensity_clip = 1e-6` kept that finite
  // but the estimator returned `coef = -225.86` where the true ATE was
  // `1.5`, silently. Clipping converted a crash into wrong numbers.
  let n = 60
  let p = 2
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x.set(i, j, 0.1 * (i + 1).to_double() * (j + 1).to_double())
      y[i] = y[i] + x.get(i, j)
    }
    if i % 2 == 0 {
      d[i] = 1.0
      y[i] = y[i] + 1.0
    }
  }
  let data = DoubleMLData::new(x, y, d)
  let m = DoubleMLIRM::new(data, n_folds=2, seed=3141)
  // Accessors must be callable pre-fit: they return the
  // constructor-set defaults.
  match m.learner_g() {
    LinearRegression(_) => ()
    _ => abort("expected ml_g default LearnerDispatch::LinearRegression")
  }
  match m.learner_m() {
    LogisticRegression(_) => ()
    _ => abort("expected ml_m default LearnerDispatch::LogisticRegression")
  }
  // The default `ml_m` must be a CLASSIFIER -- the property upstream
  // enforces structurally via `predict_proba`.
  assert_true(m.learner_m().is_classifier())
  assert_true(!m.learner_g().is_classifier())
  let _ = p
}

///|
test "irm_per_fit_override_persists_learner" {
  // v0.59.0+: per-fit override of `ml_g` / `ml_m` must be
  // reflected on the returned `DoubleMLIRM` via the accessors.
  // Use a small RFLearner so the change is observable (RF is a
  // non-OLS LearnerDispatch variant; the default is OLS).
  let n = 100
  let p = 2
  let rng = chacha8_rng(7)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double() * 2.0 - 1.0
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    y[i] = 1.0 * d[i] + 0.5 * x_flat[i * p + 0] + (rng.double() - 0.5) * 0.2
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d)
  let rf_g = LearnerDispatch::random_forest(
    RFLearner::new(n_trees=10, max_depth=4, bootstrap_seed=11),
  )
  let rf_m = LearnerDispatch::random_forest(
    RFLearner::new(n_trees=10, max_depth=4, bootstrap_seed=22),
  )
  let fitted = DoubleMLIRM::new(data, n_folds=2, seed=3141).fit(
    ml_g=rf_g,
    ml_m=rf_m,
  )
  // accessor returns the persisted per-fit override
  match fitted.learner_g() {
    RandomForest(_) => ()
    _ => abort("expected per-fit RandomForest override on learner_g")
  }
  match fitted.learner_m() {
    RandomForest(_) => ()
    _ => abort("expected per-fit RandomForest override on learner_m")
  }
  // the fit itself should produce a finite coef (no abort)
  assert_true(fitted.coef().is_nan() == false)
  assert_true(fitted.se() > 0.0)
}

///|
test "irm_constructor_learner_param_persists_pre_fit" {
  // v0.59.0+: the `ml_g?` / `ml_m?` labeled optionals on
  // `DoubleMLIRM::new` must be reflected on the returned struct
  // BEFORE any `fit(...)` call (so callers can inspect the
  // learner they configured without running the DML loop).
  let n = 60
  let p = 2
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x.set(i, j, 0.1 * (i + 1).to_double() * (j + 1).to_double())
    }
    if i % 2 == 0 {
      d[i] = 1.0
      y[i] = y[i] + 0.3
    }
  }
  let data = DoubleMLData::new(x, y, d)
  let gb = LearnerDispatch::gradient_boosting(
    GBLearner::new(n_trees=8, learning_rate=0.1, max_depth=3, bootstrap_seed=1),
  )
  let m = DoubleMLIRM::new(data, n_folds=2, seed=3141, ml_g=gb)
  match m.learner_g() {
    GradientBoosting(_) => ()
    _ => abort("expected constructor-set GradientBoosting learner_g")
  }
  // v0.132.0: `ml_m` was NOT set by the constructor here, so it is the
  // DEFAULT -- and the default is a classifier (LogisticRegression), not
  // OLS. See `irm_learner_g_accessor_returns_default` for why.
  match m.learner_m() {
    LogisticRegression(_) => ()
    _ => abort("expected default LogisticRegression learner_m")
  }
  assert_true(m.learner_m().is_classifier())
}
