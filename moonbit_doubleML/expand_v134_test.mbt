//| v0.134.0 gates -- `DoubleMLAPO`'s default `ml_m` is a CLASSIFIER.
//
//| Context. Continues the per-estimator migration started in v0.132.0
//| (`DoubleMLIRM`). APO's `ml_m` fits the PROPENSITY, and upstream treats it
//| as a classifier (`regressor=False, classifier=True`, read via
//| `predict_proba`). The port defaulted it to `LearnerDispatch::linear_regression()`
//| instead, inherited mechanically by v0.59.0's `LearnerDispatch` injection.
//
//| APO has the simpler structural story of the two migrated estimators, for a
//| reason worth recording: its `ml_m` is fitted against `treated` -- the
//| `indicator_level(d, treatment_level)` 0/1 VECTOR (apo.mbt:343, :1087) --
//| NOT raw `d`. The target is therefore binary for ANY treatment level, so a
//| classifier is correct by construction rather than by convention. (Contrast
//| `DoubleMLDID`, whose treatment can be continuous, and where a logistic
//| default would hit the `logistic.mbt:134` binary precondition.)
//
//| MEASURED, both arms in one run, three DGP seeds, saturated propensity,
//| true E[Y | D=1] = 1.2 (`_verify/probe_v1340.mbt`):
//|
//|     seed  default coef  |bias|  default SE |  OLS coef   |bias|    OLS SE
//|     3141     1.697814     0.4978      0.035119   -112.7738    113.97    86.278
//|     2718     1.730684     0.5307      0.087709      6.44642     5.246   320.414
//|     1618     1.459053     0.2591      0.269581   -246.9455    248.15   248.460
//|
//| IMPORTANT -- and the reason the gates below are shaped the way they are:
//| APO's COEFFICIENT separation is much weaker than IRM's was. The SMALLEST
//| OLS |bias| here is 5.246 (seed 2718), against a worst default |bias| of
//| 0.531 -- about 10x, where the v0.132.0 IRM fixture separated by 366x.
//| A gate of the IRM shape ("default bias < X, OLS bias > 100*X") would
//| therefore either fail here or need a threshold so loose it stops
//| discriminating.
//|
//| The STANDARD ERROR is the honest discriminator, and it is the mechanism:
//| an OLS propensity is unbounded, so `1 / m_hat` explodes and the variance
//| goes with it. Measured SE ratio (default/OLS) is at worst
//| 0.2696 / 86.28 = 0.0031 -- a 300x separation, versus 10x on the
//| coefficient. GATE 2 asserts the coefficient as a sanity bound and lets the
//| SE carry the load.

///|
fn v1340_data(n : Int, p : Int, seed : Int) -> DoubleMLData {
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
    // Saturated but legitimate propensity: a clamp of a linear index whose
    // range runs well past [0,1]. An OLS fit to `treated` predicts outside
    // [0,1]; a logistic fit cannot.
    let raw = 0.5 + 1.3 * xi[0] - 0.6 * xi[1]
    let pi = if raw < 0.04 { 0.04 } else if raw > 0.96 { 0.96 } else { raw }
    let di = if rng.double() < pi { 1.0 } else { 0.0 }
    d[i] = di
    y[i] = 0.5 +
      0.8 * xi[0] -
      0.4 * xi[1] +
      1.2 * di +
      0.3 * (rng.double() - 0.5)
  }
  DoubleMLData::new(Matrix::from_array(x_flat, n, p), y, d)
}

///|
/// GATE 1 (structural) -- `ml_m` is a classifier, `ml_g` is not.
///
/// Same two halves as the v0.132.0 IRM gate: asserting only "ml_m is a
/// classifier" would leave open "make everything a classifier", which is
/// equally wrong the other way (`ml_g` models `E[Y | X]`).
///
/// Mutation: reverting the default to `linear_regression()` fails this.
/// Flipping `ml_g` to logistic is caught earlier by the `logistic.mbt:134`
/// binary precondition, since APO's `ml_g` fits `y`, not a 0/1 target.
test "v1340_apo_default_ml_m_is_a_classifier_and_ml_g_is_not" {
  let data = v1340_data(200, 2, 3141)
  let m = DoubleMLAPO::new(data, treatment_level=1.0, n_folds=2, seed=3141)
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
/// GATE 2 (behavioural) -- the default propensity keeps the estimator
/// calibrated and well-scaled; an OLS propensity does not.
///
/// Thresholds from the measurement above, with margin:
///   worst default |bias| 0.531 vs guard 1.0   (1.9x)
///   worst default SE    0.270 vs guard 1.0   (3.7x)
///   smallest OLS SE     86.28  vs guard 20.0 (4.3x)
///   default/OLS SE ratio <= 0.0031 vs guard 0.1 (320x)
///
/// The contrast arm is an EXPLICIT `linear_regression()`, never "the old
/// default": once the default moves, a gate phrased against the default
/// silently changes subject. That exact trap was hit in this release -- the
/// v0.133.0 gate compared against APO's default and began failing the moment
/// that default changed, which is why it now pins OLS explicitly.
///
/// Mutation: reverting the default to OLS fails every assertion here,
/// because the "default" arm becomes the OLS arm.
test "v1340_apo_default_is_calibrated_where_ols_propensity_is_not" {
  let ols = LearnerDispatch::linear_regression()
  for seed in [3141, 2718, 1618] {
    let data = v1340_data(600, 2, seed)
    let dflt = DoubleMLAPO::new(data, treatment_level=1.0, n_folds=2, seed=3141).fit()
    let with_ols = DoubleMLAPO::new(
      data,
      treatment_level=1.0,
      n_folds=2,
      seed=3141,
      ml_m=ols,
    ).fit()
    // calibration under the default
    assert_true((dflt.coef() - 1.2).abs() < 1.0)
    assert_true(dflt.se() < 1.0)
    // the unbounded propensity wrecks the variance
    assert_true(with_ols.se() > 20.0)
    // and the separation itself, which is what makes the pair non-vacuous
    assert_true(dflt.se() * 10.0 < with_ols.se())
  }
}

///|
/// GATE 3 (control) -- the classifier default holds at a NON-OBVIOUS treatment
/// level.
///
/// This is the case that separates APO from IRM: `treated` is
/// `indicator_level(d, level)`, so at level 0.0 the propensity being modelled
/// is `P(D = 0 | X)`, not `P(D = 1 | X)`. If `ml_m` were fitted against raw
/// `d` -- or if the classifier assumption were quietly tied to level 1.0 --
/// this is where it would show. Measured at level 0.0 (true 0.5): default
/// coef 0.5564 (|bias| 0.0564) vs OLS 225.297 (|bias| 224.797).
///
/// Mutation: an `ml_m` fitted on raw `d`, or a hardcoded level-1 indicator,
/// fails here.
test "v1340_apo_classifier_default_holds_at_treatment_level_zero" {
  let ols = LearnerDispatch::linear_regression()
  let data = v1340_data(600, 2, 3141)
  let dflt = DoubleMLAPO::new(data, treatment_level=0.0, n_folds=2, seed=3141).fit()
  let with_ols = DoubleMLAPO::new(
    data,
    treatment_level=0.0,
    n_folds=2,
    seed=3141,
    ml_m=ols,
  ).fit()
  // y = 0.5 + 0.8*x0 - 0.4*x1 + 1.2*d, so E[Y | D=0] = 0.5
  assert_true((dflt.coef() - 0.5).abs() < 0.2)
  assert_true(dflt.se() < 1.0)
  assert_true((with_ols.coef() - 0.5).abs() > 20.0)
}
