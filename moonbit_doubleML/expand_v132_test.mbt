//| v0.132.0 gates -- `DoubleMLIRM`'s default `ml_m` is a CLASSIFIER.
//
//| Context. Upstream makes `ml_m` a MANDATORY positional argument and
//| validates it `_check_learner(ml_m, "ml_m", regressor=False,
//| classifier=True)` (`irm/irm.py:157`), then reads it back through
//| `predict_proba` (`irm.py:161`). There is no upstream default to be wrong
//| about: the type is enforced structurally, because a regressor has no
//| `predict_proba` at all.
//|
//| The port instead DEFAULTED `ml_m` to `LearnerDispatch::linear_regression()`,
//| inherited from v0.59.0's mechanical `LearnerDispatch` injection (which
//| preserved a hardcoded OLS and carried no design intent -- unlike
//| `in_sample_normalization=false`, which v0.8.0 chose on purpose). Nothing
//| crashed: `propensity_clip` (default `1e-6`) kept `1 / m_hat` finite, so
//| the estimator silently returned nonsense instead of raising.
//|
//| These gates pin the fix from two directions. GATE 1 is structural (the
//| default is a classifier). GATE 2 is BEHAVIOURAL -- it would fail just as
//| loudly if someone re-broke this by routing the default through a
//| regressor without touching the `LearnerDispatch` variant.
//|
//| Every threshold below is MEASURED, not guessed. `_verify/probe_v1320_dgp.mbt`
//| runs both arms across three DGP seeds in one process:
//|
//|     seed 3141: default  1.3017 (|bias|   0.1983)  OLS -153.3121 (|bias| 154.8121)
//|     seed 2718: default  1.5078 (|bias|   0.0078)  OLS  -71.2973 (|bias|  72.7973)
//|     seed 1618: default  1.6167 (|bias|   0.1167)  OLS -229.4006 (|bias| 230.9006)
//|
//| true ATE = 1.5 throughout. Worst default bias 0.1983 vs best OLS bias
//| 72.797: a 367x separation, which is what makes a single threshold safe
//| across all three seeds rather than a threshold fitted to one draw.
//|
//| ROUND 21 RE-MEASURED THIS (2026-10-21). The figures used to be quoted at 3
//| and 2 decimals -- "worst default bias 0.198 vs best OLS bias 72.80: a 366x
//| separation" -- and the 366x was a slip: the measured separation is 367.15x,
//| and "recovers within 0.198" was false, because the worst default bias is
//| 0.19827515142504515. The full-precision measurement is in
//| `_verify/_hazard_margins_1650.json`, the README quotes the corrected
//| figures, and GATE 2 below re-derives them -- so this comment cannot go
//| stale without a test failing.

///|
fn v1320_dgp(n : Int32, p : Int32, seed : Int32) -> DoubleMLData {
  let rng = chacha8_rng(seed)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let xi = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      let v = rng.double() * 2.0 - 1.0
      x_flat[i * p + j] = v
      xi[j] = v
    }
    // Strongly saturated propensity: the true P(d=1|x) is a clamp of a
    // linear index whose range runs well past [0,1]. A LINEAR fit to `d`
    // therefore predicts outside [0,1]; a LOGISTIC fit cannot. This is an
    // ordinary observational design -- nothing here is pathological.
    let raw = 0.5 + 1.4 * xi[0] - 0.6 * xi[1] + 0.3 * xi[2]
    let pi = if raw < 0.03 { 0.03 } else if raw > 0.97 { 0.97 } else { raw }
    let di = if rng.double() < pi { 1.0 } else { 0.0 }
    d[i] = di
    y[i] = 0.5 +
      0.8 * xi[0] -
      0.4 * xi[1] +
      0.2 * xi[2] +
      1.5 * di +
      0.3 * (rng.double() - 0.5)
  }
  DoubleMLData::new(Matrix::from_array(x_flat, n, p), y, d)
}

///|
/// GATE 1 (structural) -- the default `ml_m` is a classifier, and the
/// default `ml_g` is not.
///
/// These are the two halves of the property, and asserting only the first
/// would leave open "make everything a classifier", which would be just as
/// wrong in the other direction (`ml_g` models `E[y|x]`, not `P(y=1|x)`).
///
/// Mutation: reverting the `ml_m` default to `LearnerDispatch::linear_regression()`
/// fails this gate; flipping `ml_g` to logistic also fails it.
test "v1320_irm_default_ml_m_is_a_classifier_and_ml_g_is_not" {
  let data = v1320_dgp(200, 3, 3141)
  let m = DoubleMLIRM::new(data, n_folds=2, seed=3141)
  assert_true(m.learner_m().is_classifier())
  assert_true(!m.learner_g().is_classifier())
  match m.learner_m() {
    LogisticRegression(_) => ()
    _ => abort("expected the ml_m default to be LogisticRegression")
  }
  match m.learner_g() {
    LinearRegression(_) => ()
    _ => abort("expected the ml_g default to be LinearRegression")
  }
}

///|
/// GATE 2 (behavioural) -- with the default learner the estimator recovers
/// the true ATE; with an OLS propensity it does not, and the two are orders
/// of magnitude apart.
///
/// Thresholds from the measurement above, with margin:
///   worst default |bias| 0.198 vs guard 0.5   (2.5x margin)
///   best OLS|bias|     72.80 vs guard 20.0  (3.6x margin)
///   default SE max 0.299 vs guard 1.0; OLS SE min 221.7 vs guard 20.0.
///
/// The pairwise check is the load-bearing one: it compares the SAME data
/// through both learners, so it cannot be satisfied by a change that moves
/// both arms together.
///
/// Mutation: reverting the default to OLS fails every assertion here,
/// because the "default" arm becomes the OLS arm.
test "v1320_irm_default_recovers_true_ate_where_ols_does_not" {
  let ols = LearnerDispatch::linear_regression()
  let mut worst_default = 0.0
  let mut best_ols = 0.0
  for seed in [3141, 2718, 1618] {
    let data = v1320_dgp(800, 3, seed)
    let dflt = DoubleMLIRM::new(data, n_folds=2, seed=3141).fit()
    let with_ols = DoubleMLIRM::new(data, n_folds=2, seed=3141, ml_m=ols).fit()
    let d_bias = (dflt.coef() - 1.5).abs()
    let o_bias = (with_ols.coef() - 1.5).abs()
    if d_bias > worst_default {
      worst_default = d_bias
    }
    if best_ols == 0.0 || o_bias < best_ols {
      best_ols = o_bias
    }
    assert_true(d_bias < 0.5)
    assert_true(o_bias > 20.0)
    // the separation itself, not just the two bounds
    assert_true(d_bias < o_bias / 100.0)
    // and the standard error tells the same story
    assert_true(dflt.se() < 1.0)
    assert_true(with_ols.se() > 20.0)
  }
  // ROUND 21: the margins the README quotes for this measurement, re-derived
  // HERE so the document cannot quote a separation the code no longer
  // produces.  Measured 2026-10-21 against this tree: worst default |bias|
  // 0.19827515142504515, best OLS |bias| 72.7973000454581, separation 367.15x.
  // The README says "the default's worst bias is 0.1983, the OLS arm's
  // smallest bias is 72.797 -- a 367x separation"; these four assertions are
  // what make that sentence true rather than merely plausible.
  //
  // Each band is the ROUNDING band of the quoted figure -- the README quotes a
  // rounded measurement, so the measured value must still round to it.  They
  // are tight on purpose: if the estimator's numerics move, the quoted
  // separation is a different number and the document has to say so.
  assert_true((worst_default - 0.1983).abs() <= 0.00005)
  assert_true((best_ols - 72.797).abs() <= 0.0005)
  assert_true((best_ols / worst_default - 367.0).abs() <= 0.5)
}
