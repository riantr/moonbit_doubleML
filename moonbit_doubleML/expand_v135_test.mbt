//| v0.135.0 gates -- `DoubleMLAPOS`'s default `ml_m` is a CLASSIFIER.
//
//| Context. Completes the APO family: v0.132.0 migrated `DoubleMLIRM`,
//| v0.134.0 migrated `DoubleMLAPO`, and this migrates `DoubleMLAPOS`. Upstream
//| treats the propensity learner as a classifier and reads it through
//| `predict_proba`; the port defaulted it to `LearnerDispatch::linear_regression()`
//| instead, inherited mechanically by v0.59.0's `LearnerDispatch` injection.
//|
//| APOS holds SEVERAL treatment levels at once, one child `DoubleMLAPO`
//| each, so a classifier default has to hold across a per-LEVEL loop rather
//| than at one level. GATE 3 is the level-specific control and GATE 4 the
//| APOS-only property (the `causal_contrast` difference).
//|
//| MEASURED, both arms in one run, two levels, three seeds, saturated
//| propensity, true `E[Y | D=0] = 0.5` and `E[Y | D=1] = 1.7`
//| (`_verify/probe_v1350.mbt`):
//|
//|   seed   default lvl0   |bias|   SE     default lvl1   |bias|    SE
//|   3141     0.5564       0.0564  0.0568     1.6978       0.0022  0.0351
//|   2718     0.3889       0.1111  0.0521     1.7307       0.0307  0.0877
//|   1618    -0.3244       0.8244  0.6561     1.4591       0.2409  0.2696
//!
//!   seed   OLS lvl0        |bias|   SE      OLS lvl1        |bias|   SE
//!   3141   225.297        224.80   255.64  -112.774        114.47   86.28
//!   2718  -435.612        436.11   263.65     6.446          4.75  320.41
//!   1618  -139.951        140.45   111.10  -246.946        248.65  248.46
//|
//| A consistency check worth recording: the level-1 numbers above are
//| BIT-IDENTICAL to the v0.134.0 APO measurement on the same DGP
//| (1.6978140074095915, SE 0.035118700076864975). They should be -- APOS's
//| level 1.0 child IS a `DoubleMLAPO` on that data, and v0.133.0 proved the
//| forwarding is correct. Identical numbers here are evidence the delegation
//| did not perturb anything; had they drifted, the forwarding would have
//| been suspect again.
//|
//| Like APO (and unlike IRM), the coefficient separation is modest on one
//| seed -- the smallest OLS `|bias|` at level 1 is 4.75 -- so the STANDARD
//| ERROR remains the honest discriminator: worst default SE 0.656 vs
//| smallest OLS SE 86.28, a 131x separation.

///|
fn v1350_data(n : Int32, p : Int32, seed : Int32) -> DoubleMLData {
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
    let raw = 0.5 + 1.3 * xi[0] - 0.6 * xi[1]
    let pi = if raw < 0.04 { 0.04 } else if raw > 0.96 { 0.96 } else { raw }
    let di = if rng.double() < pi { 1.0 } else { 0.0 }
    d[i] = di
    // => E[Y | D=1] = 1.7, E[Y | D=0] = 0.5
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
/// Same two halves as v0.132.0 / v0.134.0: asserting only "ml_m is a
/// classifier" would leave open "make everything a classifier", equally wrong
/// the other way (`ml_g` models `E[Y | X]`).
///
/// Mutation: reverting the default to `linear_regression()` fails this.
test "v1350_apos_default_ml_m_is_a_classifier_and_ml_g_is_not" {
  let data = v1350_data(200, 2, 3141)
  let m = DoubleMLAPOS::new(data, [0.0, 1.0], n_folds=2, seed=3141)
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
/// GATE 2 (behavioural) -- calibrated and well-scaled at EVERY level, across
/// seeds; an OLS propensity is neither.
///
/// Thresholds from the measurement, with margin:
///   worst default |bias| 0.8244 vs guard 1.5   (1.8x)
///   worst default SE    0.6561 vs guard 1.5   (2.3x)
///   smallest OLS SE     86.28  vs guard 20.0 (4.3x)
///   smallest OLS |bias| at either level 4.75 vs guard 2.0 (2.4x)
///
/// The contrast arm is an EXPLICIT `linear_regression()`, never "the old
/// default": a gate phrased against the default silently changes subject the
/// moment the default moves. That trap was hit twice in this migration --
/// v0.134.0 at `ml_m=logit` (`expand_v133_test.mbt:92`), v0.135.0 at
/// `ml_m=logit` (`expand_v133_test.mbt:134`) -- and is why
/// every gate here names the learner.
///
/// Mutation: reverting the default fails every assertion, because the
/// "default" arm becomes the OLS arm.
test "v1350_apos_default_is_calibrated_at_every_level_across_seeds" {
  let ols = LearnerDispatch::linear_regression()
  for seed in [3141, 2718, 1618] {
    let data = v1350_data(600, 2, seed)
    let dflt = DoubleMLAPOS::new(data, [0.0, 1.0], n_folds=2, seed=3141).fit()
    let with_ols = DoubleMLAPOS::new(
      data,
      [0.0, 1.0],
      n_folds=2,
      seed=3141,
      ml_m=ols,
    ).fit()
    let c = dflt.coefs()
    let cs = dflt.ses()
    let o = with_ols.coefs()
    let os = with_ols.ses()
    // level 0.0 -> true 0.5 ; level 1.0 -> true 1.7
    assert_true((c[0] - 0.5).abs() < 1.5)
    assert_true((c[1] - 1.7).abs() < 1.5)
    assert_true(cs[0] < 1.5)
    assert_true(cs[1] < 1.5)
    // the OLS propensity misses badly at BOTH levels...
    assert_true((o[0] - 0.5).abs() > 2.0)
    assert_true((o[1] - 1.7).abs() > 2.0)
    // ...and inflates the variance at both
    assert_true(os[0] > 20.0)
    assert_true(os[1] > 20.0)
  }
}

///|
/// GATE 3 (control) -- the classifier default holds at level 0.0, where the
/// modelled propensity is `P(D = 0 | X)` rather than `P(D = 1 | X)`.
///
/// Inherited in substance from the v0.134.0 APO control, but pinned here too:
/// APOS is the estimator users actually reach for multi-level work, and a
/// level-0 assumption would otherwise only be covered in the single-level
/// estimator's gates. Measured (true 0.5): default 0.5564 / 0.3889 / -0.3244
/// across the three seeds vs OLS 225.30 / -435.61 / -139.95.
///
/// Mutation: an `ml_m` fitted on raw `d`, or a hardcoded level-1 indicator,
/// fails here.
test "v1350_apos_classifier_default_holds_at_treatment_level_zero" {
  let ols = LearnerDispatch::linear_regression()
  let data = v1350_data(600, 2, 3141)
  let dflt = DoubleMLAPOS::new(data, [0.0], n_folds=2, seed=3141).fit()
  let with_ols = DoubleMLAPOS::new(data, [0.0], n_folds=2, seed=3141, ml_m=ols).fit()
  assert_true((dflt.coefs()[0] - 0.5).abs() < 0.3)
  assert_true(dflt.ses()[0] < 1.0)
  assert_true((with_ols.coefs()[0] - 0.5).abs() > 20.0)
}

///|
/// GATE 4 (APOS-only) -- the `causal_contrast` recovers the true difference
/// under the default, and does not under an OLS propensity.
///
/// This is the property that exists ONLY at the multi-level layer: with
/// `E[Y | D=1] - E[Y | D=0] = 1.2` exactly, a propensity that biases BOTH
/// levels in the same direction would still yield the right contrast -- so a
/// contrast-only test can pass while both levels are individually broken.
/// That is why GATE 2 asserts each level separately and GATE 4 asserts the
/// difference, rather than either replacing the other.
///
/// Measured contrast bias: default 0.0586 / 0.1418 / 0.5834 vs OLS 339.27 /
/// 440.86 / 108.19.
///
/// Mutation: reverting the default to OLS fails this at the first seed.
test "v1350_apos_causal_contrast_recovers_the_true_difference" {
  let ols = LearnerDispatch::linear_regression()
  for seed in [3141, 2718, 1618] {
    let data = v1350_data(600, 2, seed)
    let dflt = DoubleMLAPOS::new(data, [0.0, 1.0], n_folds=2, seed=3141).fit()
    let with_ols = DoubleMLAPOS::new(
      data,
      [0.0, 1.0],
      n_folds=2,
      seed=3141,
      ml_m=ols,
    ).fit()
    let d_def = dflt.coefs()[1] - dflt.coefs()[0]
    let d_ols = with_ols.coefs()[1] - with_ols.coefs()[0]
    assert_true((d_def - 1.2).abs() < 1.0)
    assert_true((d_ols - 1.2).abs() > 20.0)
  }
}
