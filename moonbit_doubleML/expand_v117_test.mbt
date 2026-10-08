// v0.117.0 -- nonlinear CLASSIFIERS (`RFClassifier`, `GBClassifier`).
//
// # What this closes
//
// Every DML estimator's propensity nuisance `ml_m` is a classifier
// whenever the treatment is binary, and this package had exactly ONE
// classifier: `LogisticRegression`. Both tree learners were
// regression-only, so LPLR / DIDBinary / DIDCSBinary / RDD-fuzzy /
// binary-IV had no nonlinear option for `ml_m` at all.
//
// # The measurement that motivates it
//
// On a XOR fixture -- the textbook nonlinearly-separable problem --
// measured in `_verify/probe_v117.mbt`:
//
//   RFClassifier      accuracy 1.000
//   GBClassifier      accuracy 1.000
//   LogisticRegression accuracy 0.500     <- exactly chance
//
// `v117_both_classifiers_beat_logistic_on_a_nonlinear_boundary` asserts
// that gap. A linear model getting chance on XOR is not a defect, it is
// the definition of linear; the point is that the package had no way to
// reach the other number.
//
// # Every tolerance here was MEASURED
//
// The numbers in the comments are the observed values on these
// fixtures, not targets. Where a bound is loose the reason is named.

// ---------------------------------------------------------------------------
// DGPs (private to this file)
// ---------------------------------------------------------------------------

///|
/// A single threshold: `x <= 0 -> y = 0`, else `y = 1`. Both learners
/// should recover this exactly; a tree learner that cannot get a
/// one-dimensional step right has a broken split search, whatever its
/// accuracy on anything harder.
fn v117_threshold_data(n : Int) -> (Matrix, Array[Double]) {
  let x = Matrix::zeros(n, 1)
  let y = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let v = if i < n / 2 { -1.0 } else { 1.0 }
    x.set(i, 0, v)
    y[i] = if v <= 0.0 { 0.0 } else { 1.0 }
  }
  (x, y)
}

///|
/// XOR on a 2x2 grid: label 1 when the two signs disagree. Linearly
/// inseparable, so any learner that gets it right is doing nonlinear
/// work.
fn v117_xor_data(n : Int) -> (Matrix, Array[Double]) {
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let a = if i % 2 == 0 { -1.0 } else { 1.0 }
    let b = if i / 2 % 2 == 0 { -1.0 } else { 1.0 }
    x.set(i, 0, a)
    x.set(i, 1, b)
    y[i] = if a * b > 0.0 { 0.0 } else { 1.0 }
  }
  (x, y)
}

///|
/// Accuracy under a 0.5 threshold on the predicted PROBABILITY.
fn v117_accuracy(p : Array[Double], y : Array[Double]) -> Double {
  let mut ok = 0
  for i = 0; i < y.length(); i = i + 1 {
    let cls = if p[i] >= 0.5 { 1.0 } else { 0.0 }
    if cls == y[i] {
      ok = ok + 1
    }
  }
  ok.to_double() / y.length().to_double()
}

///|
/// Mean absolute deviation of the predicted probability from the label.
fn v117_prob_dev(p : Array[Double], y : Array[Double]) -> Double {
  let mut s = 0.0
  for i = 0; i < y.length(); i = i + 1 {
    let d = p[i] - y[i]
    s = s + (if d < 0.0 { -d } else { d })
  }
  s / y.length().to_double()
}

// ---------------------------------------------------------------------------
// 1. The headline
// ---------------------------------------------------------------------------

///|
/// The gap this round exists for, as three numbers on one fixture.
///
/// MEASURED: RF 1.000, GB 1.000, LogisticRegression 0.500. The
/// logistic bound is 0.60 -- loose on purpose, because on a symmetric
/// XOR grid a linear model lands on exactly chance and the assertion is
/// about it being UNABLE, not about it being unlucky.
///
/// This single gate fails if either tree learner silently degenerates
/// to a linear rule, and it fails if a future change makes `ml_m`'s
/// only classifier able to fit a nonlinear boundary.
test "v117_both_classifiers_beat_logistic_on_a_nonlinear_boundary" {
  let (x, y) = v117_xor_data(200)
  let rf = RFClassifier::new(n_trees=100).fit(x, y)
  let gb = GBClassifier::new(n_trees=100).fit(x, y)
  let lr = LogisticRegression::new().fit(x, y)
  let acc_rf = v117_accuracy(rf.predict(x), y)
  let acc_gb = v117_accuracy(gb.predict(x), y)
  let acc_lr = v117_accuracy(lr.predict(x), y)
  // MEASURED 1.000 and 1.000; the 0.95 band is well outside the MC
  // spread of a 200-row balanced fixture.
  assert_true(acc_rf >= 0.95)
  assert_true(acc_gb >= 0.95)
  // MEASURED 0.500 -- exactly chance, as it must be.
  assert_true(acc_lr <= 0.60)
}

// ---------------------------------------------------------------------------
// 2. Gini really is being used
// ---------------------------------------------------------------------------

///|
/// On a one-dimensional step the Gini criterion reaches exact
/// separation, so every leaf is pure and the forest's average leaf
/// proportion is exactly 0 or 1. MEASURED: accuracy 1.0, mean absolute
/// probability deviation EXACTLY 0.0.
///
/// # This gate CANNOT tell Gini from MSE, and an earlier draft of its
/// docs claimed it could
///
/// The previous version of this comment asserted that exactness would
/// catch an MSE-split mutant. Mutation M1 in `mut_v117_learner.ps1` was
/// written to do exactly that, survived, and the claim turned out to be
/// FALSE. For a node of binary labels with proportion `p`,
///
///     sum (y_i - p)^2  =  n * p * (1 - p)  =  (n / 2) * [2p(1-p)]
///                                     MSE              Gini
///
/// so on binary labels the weighted MSE score is EXACTLY HALF the
/// weighted Gini score at every candidate split. Minimising one
/// minimises the other, ties break identically under the strict `<`
/// comparison, and the leaf value is `mean(y)` either way. Checked
/// numerically in `_verify/_m1_gini_vs_mse.py`: `2*MSE` matches Gini to
/// 3.9e-16 relative over 3000 random binary nodes, the argmin agrees in
/// 2999 of 3000 (the one disagreement is a floating-point tie), and on
/// MULTI-CLASS labels -- where the identity does not hold -- they differ
/// in 32 of 3000. Applying M1 leaves the whole suite at **878/878**, so
/// no gate here moves.
///
/// M1 is therefore declared expected-equivalent rather than papered over.
/// What this gate actually pins is that the split search finds the
/// separating threshold and that leaves hold class PROPORTIONS -- the
/// latter being the part that would break if someone changed the leaf
/// rule, which is what mutation M2 covers.
test "v117_rf_classifier_separates_a_single_threshold_exactly" {
  let (x, y) = v117_threshold_data(200)
  let rf = RFClassifier::new(n_trees=50).fit(x, y)
  let p = rf.predict(x)
  assert_true(v117_accuracy(p, y) == 1.0)
  assert_true(v117_prob_dev(p, y) == 0.0)
}

///|
/// `max_depth` is load-bearing and is honoured: a stump cannot reach
/// the accuracy a depth-2 forest gets on the same fixture.
///
/// # The stump's accuracy is NOT a stable number, and this gate used to
/// assert a false one
///
/// An earlier draft of this gate asserted the stump scored at most
/// 0.30, from a probe that had recorded 0.25. It failed, and the
/// investigation is worth keeping because the number is a trap.
///
/// MEASURED at three sample sizes on the same XOR generator
/// (`_verify/probe4_v117.mbt`):
///
/// | `n`  | fraction of predictions below 0.5 | predicted range | accuracy |
/// |------|-----------------------------------|-----------------|----------|
/// | 200  | 200 / 200 (all below)             | [0.4935, 0.4981] | 0.50 |
/// | 400  | 100 / 400 (straddling)            | [0.4971, 0.5065] | 0.25 |
/// | 800  | 0 / 800 (all above)               | [0.5003, 0.5021] | 0.50 |
///
/// The reason: with `mtry = 1` on two features, a stump draws ONE
/// random feature per node, so every leaf's value is a bootstrap mean
/// of a 50/50 mixture -- i.e. 0.5 plus sampling noise of about
/// `+-0.005`. Whether a given quadrant's average lands above or below
/// the 0.5 threshold is arbitrary, and the whole prediction vector
/// therefore sits in a razor-thin band straddling 0.5. At `n = 200`
/// every quadrant fell below, at `n = 400` half fell above, and the
/// accuracy swung between chance and ANTI-chance as a result.
///
/// The lesson generalises past this test: **a gate on an
/// `accuracy` of a model that sits on a decision boundary is a gate on
/// floating-point noise.** The bound below is `0.75` -- the most a
/// degenerate rule can score on a balanced binary fixture -- so it
/// holds at every measured size, and the claim it makes is the one that
/// is actually stable: depth 1 cannot separate XOR, depth 2 can.
test "v117_rf_max_depth_is_load_bearing_on_a_nonlinear_boundary" {
  let (x, y) = v117_xor_data(200)
  let stump = RFClassifier::new(n_trees=100, max_depth=1).fit(x, y)
  let deep = RFClassifier::new(n_trees=100, max_depth=2).fit(x, y)
  // MEASURED 0.5 here; see the header for why this is 0.75 and not a
  // tighter bound.
  assert_true(v117_accuracy(stump.predict(x), y) <= 0.75)
  // MEASURED 1.0 -- and unlike the stump this one is stable, because
  // the leaf values are near 0 and 1 rather than near 0.5.
  assert_true(v117_accuracy(deep.predict(x), y) >= 0.95)
}

// ---------------------------------------------------------------------------
// 3. Log-loss specifics, not regression specifics
// ---------------------------------------------------------------------------

///|
/// `GBClassifier::initial` is the log-ODDS of the base rate, NOT the
/// base rate. On a balanced fixture `pbar = 0.5` and
/// `log(0.5 / 0.5) = 0` EXACTLY, whereas the regression learner's
/// `mean(y)` would also be 0.5.
///
/// The exact-zero assertion is what makes it a real gate: a learner
/// that carried over `GBLearner`'s `initial = mean(y)` returns 0.5 and
/// fails, and one that carried over the wrong sign returns 0.0 and
/// passes only by luck -- so `base_rate()` is checked separately to
/// pin both halves.
test "v117_gb_initial_is_the_log_odds_not_the_base_rate" {
  let (x, y) = v117_threshold_data(200)
  let gb = GBClassifier::new(n_trees=50).fit(x, y)
  assert_true(gb.base_rate() == 0.5)
  // log(1) == 0.0 exactly in IEEE754.
  assert_true(gb.initial() == 0.0)
  assert_true(gb.initial() != gb.base_rate())
}

///|
/// The Newton leaf is `SUM(g) / SUM(h)`, not `mean(g)`. The two agree
/// only when `h` is constant across the leaf, which is never true here
/// because `h = p (1 - p)` depends on the current margin. Asserting
/// this directly needs the alternative implementation to compare
/// against, so it is enforced by the mutation harness instead
/// (`mut_v117_rdd.ps1` M2, "Newton leaf replaced by the node mean"),
/// which is the tool that can actually distinguish the two. What this
/// gate pins is the OBSERVABLE consequence: GB's probabilities are
/// smooth, not the hard 0/1 a mean-leaf would drive them toward.
///
/// MEASURED: mean absolute deviation 0.0033 on the threshold fixture
/// and 0.0035 on XOR -- three orders below RF's 0.2375 on XOR, which is
/// what saturating pure leaves look like.
test "v117_gb_probabilities_are_smooth_not_saturated" {
  let (x, y) = v117_threshold_data(200)
  let gb = GBClassifier::new(n_trees=50).fit(x, y)
  let p = gb.predict(x)
  // Smooth: every prediction strictly inside (0, 1).
  let mut strict = 0
  for i = 0; i < p.length(); i = i + 1 {
    if p[i] > 0.0 && p[i] < 1.0 {
      strict = strict + 1
    }
  }
  assert_true(strict == p.length())
  // MEASURED 0.0033; 0.02 is a wide band that still excludes both a
  // hard 0/1 predictor (dev 0.5) and an un-sigmoided margin.
  assert_true(v117_prob_dev(p, y) < 0.02)
}

///|
/// `predict` is a probability, not a margin and not a hard label. On
/// the threshold fixture the fitted model is confident but finite:
/// MEASURED p[0] = 0.00325 and p[199] = 0.99675.
///
/// The two bounds are deliberately asymmetric about 0 and 1 -- a
/// predictor that returned the raw margin F would give values far
/// outside [0, 1] and fail on the range check; one that thresholded at
/// 0.5 would give exactly 0.0 and 1.0 and fail on the strict check.
test "v117_gb_predict_returns_a_probability_not_a_margin" {
  let (x, y) = v117_threshold_data(200)
  let gb = GBClassifier::new(n_trees=50).fit(x, y)
  let p = gb.predict(x)
  // MEASURED 0.0032510 and 0.9967490.
  assert_true(p[0] < 0.01 && p[0] > 0.0)
  assert_true(p[199] > 0.99 && p[199] < 1.0)
}

///|
/// A perfectly separated training fold has `pbar` at an open endpoint,
/// where `log(pbar / (1 - pbar))` is infinite. The clamp is what stops
/// that.
///
/// MEASURED on an all-ones fold: `base_rate = 0.999999999` (i.e.
/// `1 - 1e-9`, so the clamp fired) and `initial = 20.723`, which is
/// `log(1e-9)` to three decimals. Both finite. Without the clamp this
/// fit would produce `inf` / `NaN` and every downstream AIPW division
/// would poison.
test "v117_gb_survives_a_single_class_training_fold" {
  let (x, _y0) = v117_xor_data(200)
  let all_ones = Array::make(200, 1.0)
  let gb = GBClassifier::new(n_trees=5).fit(x, all_ones)
  // MEASURED 0.999999999 -- the clamp at 1 - 1e-9, not exactly 1.
  assert_true(gb.base_rate() > 0.99 && gb.base_rate() < 1.0)
  // MEASURED 20.723265864228342.
  assert_true(gb.initial() > 20.0 && gb.initial() < 21.0)
  // and the prediction is still a usable probability, not NaN
  let p = gb.predict(x)
  assert_true(p[0] > 0.99 && p[0] <= 1.0)
}

// ---------------------------------------------------------------------------
// 4. Integration: dispatch, cache identity, estimator use
// ---------------------------------------------------------------------------

///|
/// The new variants are reachable through every dispatch path, not just
/// by naming the learner directly. Three separate paths are exercised
/// because they are three separate `match` statements and a new enum
/// variant that is wired into one but not the others compiles fine and
/// aborts at run time.
///
/// A `fit` / `predict` round-trip also pins that each learner actually
/// stores fitted state rather than silently returning the unfitted
/// fallback.
test "v117_classifiers_dispatch_through_every_learner_path" {
  // XOR, not the threshold fixture. The threshold fixture puts ALL
  // class-0 rows in 0..99, so a fold training on exactly that half
  // sees a single class and predicts 0 for everything -- which is
  // correct behaviour for a classifier and useless as a test. XOR
  // interleaves the labels, so every half has both classes. That was
  // the first version of this gate's bug, caught by MEASUREMENT: it
  // reported 0/100 test hits, which is a fixture defect, not a
  // learner defect.
  let (x, y) = v117_xor_data(200)
  let folds : Array[Fold] = [
    Fold::new(
      Array::makei(100, fn(i) { i }),
      Array::makei(100, fn(i) { i + 100 }),
    ),
  ]
  let rf_dispatch = LearnerDispatch::random_forest_classifier(
    RFClassifier::new(n_trees=20),
  )
  let gb_dispatch = LearnerDispatch::gradient_boosting_classifier(
    GBClassifier::new(n_trees=20),
  )
  let rf_cross = cross_fit_predict_dispatch(rf_dispatch, x, y, folds)
  let gb_cross = cross_fit_predict_dispatch(gb_dispatch, x, y, folds)
  assert_true(rf_cross.length() == 200)
  assert_true(gb_cross.length() == 200)
  // The test half must be classified well enough to be usable as a
  // propensity; MEASURED both well above chance on a separable fold.
  let mut rf_hits = 0
  let mut gb_hits = 0
  for i = 0; i < 100; i = i + 1 {
    if (if rf_cross[100 + i] >= 0.5 { 1.0 } else { 0.0 }) == y[100 + i] {
      rf_hits = rf_hits + 1
    }
    if (if gb_cross[100 + i] >= 0.5 { 1.0 } else { 0.0 }) == y[100 + i] {
      gb_hits = gb_hits + 1
    }
  }
  assert_true(rf_hits.to_double() / 100.0 > 0.9)
  assert_true(gb_hits.to_double() / 100.0 > 0.9)
  // fit_predict_one_dispatch is a separate match; exercise it too.
  let one = fit_predict_one_dispatch(rf_dispatch, x, y, x)
  assert_true(one.length() == 200)
}

///|
/// The memoize key must distinguish each classifier from its
/// REGRESSION sibling.
///
/// This is not hygiene. `learner_dispatch_tag` is folded into
/// `hash_hyperparams`, which is half the fit cache key. If
/// `RandomForestClassifier` shared the `"random_forest"` tag, a model
/// fitted with `ml_m = RFLearner` and then re-fit with
/// `ml_m = RFClassifier` would take a CACHE HIT and hand back
/// regression predictions where propensity probabilities were asked
/// for -- silently, with no error, because the numbers are all finite.
///
/// The test asserts on `hash_hyperparams` rather than the private tag
/// because that is the observable contract; the private function's
/// visibility is not a promise.
test "v117_classifier_cache_keys_differ_from_regression_siblings" {
  let reg_rf = LearnerDispatch::random_forest(RFLearner::new(n_trees=10))
  let clf_rf = LearnerDispatch::random_forest_classifier(
    RFClassifier::new(n_trees=10),
  )
  let reg_gb = LearnerDispatch::gradient_boosting(GBLearner::new(n_trees=10))
  let clf_gb = LearnerDispatch::gradient_boosting_classifier(
    GBClassifier::new(n_trees=10),
  )
  let h_reg_rf = hash_hyperparams("k", reg_rf, reg_rf, 1.0e-6)
  let h_clf_rf = hash_hyperparams("k", clf_rf, clf_rf, 1.0e-6)
  let h_reg_gb = hash_hyperparams("k", reg_gb, reg_gb, 1.0e-6)
  let h_clf_gb = hash_hyperparams("k", clf_gb, clf_gb, 1.0e-6)
  assert_true(h_reg_rf != h_clf_rf)
  assert_true(h_reg_gb != h_clf_gb)
  // ...and the two classifiers do not collide with each other either.
  assert_true(h_clf_rf != h_clf_gb)
}

///|
/// The actual deliverable: a nonlinear `ml_m` reaches a real estimator
/// and changes its answer. `DoubleMLIRM` with a binary treatment fits
/// its propensity with `ml_m`, so swapping the classifier has to move
/// the estimate -- if it does not, the variant is not reaching the
/// nuisance slot and every gate above is testing the learner in
/// isolation rather than in the position it exists for.
///
/// The assertions are deliberately weak on magnitude (finite, positive
/// SE, and the two learners disagreeing) because this is a wiring
/// proof, not a performance claim. Exact recovery of `theta` is
/// `irm_test.mbt`'s job and it does not belong here.
test "v117_a_nonlinear_classifier_reaches_an_estimator_s_ml_m" {
  let n = 600
  let x = Matrix::zeros(n, 3)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let rng = chacha8_rng(8642)
  for i = 0; i < n; i = i + 1 {
    let a = rng.double() * 2.0 - 1.0
    let b = rng.double() * 2.0 - 1.0
    let c = rng.double() * 2.0 - 1.0
    x.set(i, 0, a)
    x.set(i, 1, b)
    x.set(i, 2, c)
    // Nonlinear propensity: logistic in a linear index cannot express
    // this, so a linear `ml_m` is mis-specified by construction.
    let idx = a * b + 0.3 * c
    d[i] = if rng.double() < expit(idx) { 1.0 } else { 0.0 }
    y[i] = 0.5 * d[i] + 0.4 * a + 0.3 * b + 0.2 * c + (rng.double() - 0.5) * 0.5
  }
  let data = DoubleMLData::new(x, y, d)
  let with_logit = DoubleMLIRM::new(
    data,
    n_folds=2,
    n_rep=1,
    seed=555,
    ml_g=LearnerDispatch::linear_regression(),
    ml_m=LearnerDispatch::logistic_regression(LogisticRegression::new()),
  ).fit()
  let with_rf = DoubleMLIRM::new(
    data,
    n_folds=2,
    n_rep=1,
    seed=555,
    ml_g=LearnerDispatch::linear_regression(),
    ml_m=LearnerDispatch::random_forest_classifier(
      RFClassifier::new(n_trees=30),
    ),
  ).fit()
  let with_gb = DoubleMLIRM::new(
    data,
    n_folds=2,
    n_rep=1,
    seed=555,
    ml_g=LearnerDispatch::linear_regression(),
    ml_m=LearnerDispatch::gradient_boosting_classifier(
      GBClassifier::new(n_trees=30),
    ),
  ).fit()
  // Finite, positive SE on all three -- a NaN propensity or a 0/0
  // denominator shows up here first.
  assert_true(with_logit.se() > 0.0)
  assert_true(with_rf.se() > 0.0)
  assert_true(with_gb.se() > 0.0)
  // The nonlinear nuisance moved the answer.
  assert_true(with_logit.coef() != with_rf.coef())
  assert_true(with_logit.coef() != with_gb.coef())
}

///|
/// Unfitted learners keep the package's documented lenient fallback:
/// zeros. Recorded rather than left implicit, because `GBClassifier`
/// returns `sigmoid(F_0)` instead of zeros -- MEASURED 0.5 on a
/// balanced fixture -- and a reader who assumes symmetry with
/// `RFLearner` would be wrong.
///
/// The fallback exists so a caller who constructs a learner and
/// predicts before fitting gets a harmless array rather than an abort;
/// it is NOT a "works without training" guarantee, and neither value is
/// a usable propensity.
test "v117_unfitted_classifier_fallbacks_are_documented_values" {
  let (x, _y) = v117_threshold_data(40)
  let rf = RFClassifier::new()
  let gb = GBClassifier::new()
  // MEASURED: RFLearner-compatible zeros.
  let pr = rf.predict(x)
  for i = 0; i < pr.length(); i = i + 1 {
    assert_true(pr[i] == 0.0)
  }
  // MEASURED: 0.5, i.e. sigmoid(0) -- the base-rate fallback.
  let pg = gb.predict(x)
  for i = 0; i < pg.length(); i = i + 1 {
    assert_true(pg[i] == 0.5)
  }
  // Accessors agree with "not yet fit".
  assert_true(rf.n_trees() == 0)
  assert_true(rf.n_features() == -1)
  assert_true(gb.n_trees() == 0)
}

///|
/// Both learners REFUSE a non-binary `y` instead of returning a
/// plausible-looking number. Gini impurity and the leaf-proportion
/// reading of the node mean are defined for binary labels; a
/// multiclass or regression `y` would flow through and produce numbers
/// that look like probabilities without being any.
///
/// The `panic_` prefix is what tells `moon test` the abort is expected.
test "panic_v117_rf_classifier_rejects_a_non_binary_outcome" {
  let x = Matrix::zeros(20, 1)
  let bad = Array::make(20, 0.0)
  for i = 0; i < 20; i = i + 1 {
    x.set(i, 0, i.to_double() / 10.0)
    bad[i] = i.to_double() // 0..19, not in {0, 1}
  }
  let rf = RFClassifier::new(n_trees=3)
  let _ = rf.fit(x, bad)
  inspect(false, content="unreachable: a non-binary y must abort")
}

///|
/// Same contract for `GBClassifier`.
test "panic_v117_gb_classifier_rejects_a_non_binary_outcome" {
  let x = Matrix::zeros(20, 1)
  let bad = Array::make(20, 0.5)
  let gb = GBClassifier::new(n_trees=3)
  let _ = gb.fit(x, bad)
  inspect(false, content="unreachable: a non-binary y must abort")
}
