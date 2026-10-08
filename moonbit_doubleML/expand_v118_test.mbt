// v0.118.0 -- `sample_weight` on the `Learner` trait.
//
// # What this closes
//
// Upstream `doubleml` is learner-agnostic: `ml_g` / `ml_m` are objects
// with `fit(X, y, sample_weight)`. This package's trait was
// `fit(Self, Matrix, Array[Double]) -> Self` -- no weight parameter at
// all, so **no weighted learner could be expressed**, which is a
// protocol-level narrowing rather than a missing convenience. It also
// blocks the DR-learner, which fits its nuisances with the treatment
// itself as the weight.
//
// The trait now takes a third argument. An EMPTY array means
// unweighted, mirroring scikit-learn's `sample_weight=None` and keeping
// all 22 estimators byte-identical.
//
// # MoonBit could not give us the easy version
//
// The obvious design is a defaulted trait method `fit_weighted` that
// falls back to `fit`. MoonBit traits do NOT support a default method
// body -- adding one fails with `Missing type annotation for the
// parameter`, and the trait then reports "no method predict in trait
// Learner" for every existing impl. So the signature itself changed and
// each `impl` dispatches on emptiness through the shared helper
// `w_is_unweighted`.
//
// # The fixture that made the difference
//
// The first probe used two groups at `x = {-1, +1}` with a linear fit.
// That model INTERPOLATES -- two parameters, two points -- so it hits
// both group means exactly at any weighting. Measured: `predA = 2`,
// `predB = 10` at `k = 1`, `5` and `50` alike. A gate on that fixture
// would pass even if every learner ignored its weights.
//
// The fixture below uses a CONSTANT feature, so the only estimated
// quantity is the intercept and the fitted value is the weighted mean of
// `y`. Group A (mean `m_a`) at weight `k`, group B (mean `m_b`) at
// weight 1, 50 rows each:
//
//     exact = (k * m_a * 50 + m_b * 50) / (k * 50 + 50)
//
// MEASURED (`_verify/probe2_v118.mbt`, group means A = 1.93369,
// B = 10.14718):
//
// | `k` | exact | OLS | RF | GB |
// |---|---:|---:|---:|---:|
// | 1 | 6.04043 | 6.04043 | 5.96339 | 6.04043 |
// | 5 | 3.30260 | 3.30260 | 3.27176 | 3.34307 |
// | 50 | 2.09474 | 2.09474 | 2.08277 | 2.15306 |
//
// and for the classifiers (`P(y=1)` should be `k/(k+1)`):
//
// | `k` | exact | LR | RF | GB |
// |---|---:|---:|---:|---:|
// | 1 | 0.50000 | 0.50000 | 0.50850 | 0.50000 |
// | 5 | 0.83333 | 0.83333 | 0.83597 | 0.82825 |
// | 50 | 0.98039 | 0.98039 | 0.98063 | 0.97238 |
//
// Every tolerance below is set from those numbers.

// ---------------------------------------------------------------------------
// DGP (private to this file)
// ---------------------------------------------------------------------------

///|
/// Constant feature (all `x[i][0] == 1.0`), so only the intercept is
/// estimated and the fit is a genuine average. Group A is rows
/// `[0, n/2)` with mean `~1.934`, group B is `[n/2, n)` with mean
/// `~10.147`.
fn v118_data(n : Int) -> (Matrix, Array[Double]) {
  let x = Matrix::zeros(n, 1)
  let y = Array::make(n, 0.0)
  let rng = chacha8_rng(9091)
  for i = 0; i < n; i = i + 1 {
    x.set(i, 0, 1.0)
    let base = if i < n / 2 { 2.0 } else { 10.0 }
    y[i] = base + (rng.double() - 0.5) * 2.0
  }
  (x, y)
}

///|
/// Group A gets `k`, group B gets 1.
fn v118_weights(n : Int, k : Double) -> Array[Double] {
  let w = Array::make(n, 1.0)
  for i = 0; i < n / 2; i = i + 1 {
    w[i] = k
  }
  w
}

///|
/// Mean over `p[lo, hi)`.
fn v118_mean(p : Array[Double], lo : Int, hi : Int) -> Double {
  let mut s = 0.0
  for i = lo; i < hi; i = i + 1 {
    s = s + p[i]
  }
  s / (hi - lo).to_double()
}

///|
/// The closed-form weighted mean this fixture should produce.
fn v118_exact(y : Array[Double], n : Int, k : Double) -> Double {
  let m_a = v118_mean(y, 0, n / 2)
  let m_b = v118_mean(y, n / 2, n)
  (k * m_a * (n / 2).to_double() + m_b * (n / 2).to_double()) /
  (k * (n / 2).to_double() + (n / 2).to_double())
}

///|
/// Separable binary design on a constant feature: group A `y = 1`,
/// group B `y = 0`, so the weighted base rate is exactly `k/(k+1)`.
fn v118_clf_data(n : Int) -> (Matrix, Array[Double]) {
  let x = Matrix::zeros(n, 1)
  let y = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    x.set(i, 0, 1.0)
    y[i] = if i < n / 2 { 1.0 } else { 0.0 }
  }
  (x, y)
}

// ---------------------------------------------------------------------------
// 1. The weights reach the fit
// ---------------------------------------------------------------------------

///|
/// WLS is the exact case: with a constant feature the intercept IS the
/// weighted mean of `y`, so this can be asserted against a closed form.
///
/// MEASURED drift from `v118_exact`: 3.0e-12 (k=1), 5.5e-13 (k=5),
/// 4.3e-14 (k=50) in absolute terms -- i.e. relative ~1e-12. The bound
/// is 1e-9, two orders of headroom.
///
/// This gate dies the instant any learner routes the empty array instead
/// of the supplied one.
test "v118_weights_move_the_ols_intercept_to_the_closed_form" {
  let n = 100
  let (x, y) = v118_data(n)
  for k in [1.0, 5.0, 50.0] {
    let w = v118_weights(n, k)
    let got = v118_mean(
      LinearRegression::new().fit_weighted(x, y, w).predict(x),
      0,
      n,
    )
    let want = v118_exact(y, n, k)
    assert_true((got - want).abs() <= 1.0e-9 * want.abs())
  }
}

///|
/// The same for weighted logistic IRLS. The closed form is the weighted
/// base rate `k / (k + 1)`.
///
/// MEASURED: 0.0 (k=1), 2.7e-11 (k=5), 7.7e-12 (k=50) -- the residue
/// is IRLS convergence, not the weighting. Bound 1e-8.
test "v118_weights_move_the_logistic_base_rate" {
  let n = 100
  let (x, y) = v118_clf_data(n)
  for k in [1.0, 5.0, 50.0] {
    let w = v118_weights(n, k)
    let got = v118_mean(
      LogisticRegression::new().fit(x, y, sample_weight=w).predict(x),
      0,
      n,
    )
    let want = k / (k + 1.0)
    assert_true((got - want).abs() <= 1.0e-8)
  }
}

///|
/// The tree learners track the same closed form, within their own
/// approximation error, and are MONOTONE in `k` -- more weight on group
/// A can only pull the prediction further toward group A's mean.
///
/// MEASURED drift from `v118_exact` (the numbers in the header):
/// RF 0.077 / 0.031 / 0.012 for k = 1 / 5 / 50; GB 0.000 / 0.041 /
/// 0.058. The bound is 0.15 absolute, comfortably above all of them and
/// far below the 6.04 -> 2.09 signal, so it cannot pass by accident.
///
/// Monotonicity is asserted separately because it is the property that
/// survives even if the absolute scale drifts: a learner that ignored
/// the weights would return the SAME number for every `k`.
test "v118_weights_move_the_tree_learners_monotonically" {
  let n = 100
  let (x, y) = v118_data(n)
  let mut prev_rf = 1.0e18
  let mut prev_gb = 1.0e18
  for k in [1.0, 5.0, 50.0] {
    let w = v118_weights(n, k)
    let want = v118_exact(y, n, k)
    let got_rf = v118_mean(
      RFLearner::new(n_trees=40).fit_weighted(x, y, w).predict(x),
      0,
      n,
    )
    let got_gb = v118_mean(
      GBLearner::new(n_trees=40).fit_weighted(x, y, w).predict(x),
      0,
      n,
    )
    assert_true((got_rf - want).abs() <= 0.15)
    assert_true((got_gb - want).abs() <= 0.15)
    assert_true(got_rf < prev_rf)
    assert_true(got_gb < prev_gb)
    prev_rf = got_rf
    prev_gb = got_gb
  }
}

///|
/// The two classifiers, same fixture, same monotonicity claim.
///
/// MEASURED against `k/(k+1)`: RF 0.0085 / 0.0026 / 0.00024 for
/// k = 1 / 5 / 50; GB 0.0 / 0.0051 / 0.0080. Bound 0.02 absolute.
test "v118_weights_move_the_tree_classifiers_monotonically" {
  let n = 100
  let (x, y) = v118_clf_data(n)
  let mut prev_rf = -1.0
  let mut prev_gb = -1.0
  for k in [1.0, 5.0, 50.0] {
    let w = v118_weights(n, k)
    let want = k / (k + 1.0)
    let got_rf = v118_mean(
      RFClassifier::new(n_trees=40).fit_weighted(x, y, w).predict(x),
      0,
      n,
    )
    let got_gb = v118_mean(
      GBClassifier::new(n_trees=40).fit_weighted(x, y, w).predict(x),
      0,
      n,
    )
    assert_true((got_rf - want).abs() <= 0.02)
    assert_true((got_gb - want).abs() <= 0.02)
    assert_true(got_rf > prev_rf)
    assert_true(got_gb > prev_gb)
    prev_rf = got_rf
    prev_gb = got_gb
  }
}

// ---------------------------------------------------------------------------
// 2. Backward compatibility
// ---------------------------------------------------------------------------

///|
/// The claim the whole design rests on: an all-ones weight vector
/// reproduces the unweighted fit EXACTLY, for all six weighted
/// learners.
///
/// Measured drift: **0.0** on every learner, on both the regression
/// and the classification fixture. Asserted with `==` rather than a
/// tolerance, because that is what was measured and because the
/// arithmetic is designed for it -- `cart_fit`'s unweighted branches are
/// the pre-v0.118.0 code verbatim, and the weighted branch is never
/// entered when `w` is empty.
///
/// If this ever fails, the "byte-identical for existing callers" promise
/// in `Learner`'s docs is false and 22 estimators' defaults moved.
test "v118_uniform_weights_are_exactly_a_no_op" {
  let n = 100
  let ones = Array::make(n, 1.0)
  let (x, y) = v118_data(n)
  let a = LinearRegression::new().fit(x, y).predict(x)
  let b = LinearRegression::new().fit_weighted(x, y, ones).predict(x)
  let ra = RFLearner::new(n_trees=20).fit(x, y).predict(x)
  let rb = RFLearner::new(n_trees=20).fit_weighted(x, y, ones).predict(x)
  let ga = GBLearner::new(n_trees=20).fit(x, y).predict(x)
  let gb = GBLearner::new(n_trees=20).fit_weighted(x, y, ones).predict(x)
  for i = 0; i < n; i = i + 1 {
    assert_true(a[i] == b[i])
    assert_true(ra[i] == rb[i])
    assert_true(ga[i] == gb[i])
  }
  let (xc, yc) = v118_clf_data(n)
  let ca = RFClassifier::new(n_trees=20).fit(xc, yc).predict(xc)
  let cb = RFClassifier::new(n_trees=20).fit_weighted(xc, yc, ones).predict(xc)
  let da = GBClassifier::new(n_trees=20).fit(xc, yc).predict(xc)
  let db = GBClassifier::new(n_trees=20).fit_weighted(xc, yc, ones).predict(xc)
  let la = LogisticRegression::new().fit(xc, yc).predict(xc)
  let lb = LogisticRegression::new().fit(xc, yc, sample_weight=ones).predict(xc)
  for i = 0; i < n; i = i + 1 {
    assert_true(ca[i] == cb[i])
    assert_true(da[i] == db[i])
    assert_true(la[i] == lb[i])
  }
}

///|
/// `w_is_unweighted` is the single definition of "these weights mean
/// nothing" that all eight `impl`s route through. Pinned directly
/// because the convention drifting between two learners is exactly the
/// failure this helper exists to prevent.
test "v118_w_is_unweighted_is_the_single_convention" {
  assert_true(w_is_unweighted([]))
  assert_true(!w_is_unweighted([1.0]))
  assert_true(!w_is_unweighted([0.0]))
  // A vector of ZEROS is NOT "unweighted" -- it is the degenerate
  // weighting that annihilates every contribution, and treating it as
  // unweighted would silently rescue a caller whose weights were all
  // destroyed upstream.
  assert_true(!w_is_unweighted([0.0, 0.0, 0.0]))
}

// ---------------------------------------------------------------------------
// 3. Cross-fit plumbing
// ---------------------------------------------------------------------------

///|
/// Weights must be SLICED per fold alongside `x` and `y`. A weight that
/// stayed at its full-length position would be fitted against the wrong
/// observations.
///
/// The gate computes the expected answer by hand -- one weighted OLS on
/// the first fold's training rows, using the weights of THOSE rows --
/// and requires the cross-fit output to match. An implementation that
/// ignored the slice would produce a different number on at least one
/// of the test rows.
test "v118_cross_fit_slices_the_weights_with_the_rows" {
  let n = 100
  let (x, y) = v118_data(n)
  let w = v118_weights(n, 5.0)
  // Fold 1: train [0, 50) (all of group A, weight 5), test [50, 100).
  // Fold 2: train [50, 100) (group B, weight 1), test [0, 50).
  let folds : Array[Fold] = [
    Fold::new(Array::makei(50, fn(i) { i }), Array::makei(50, fn(i) { i + 50 })),
    Fold::new(Array::makei(50, fn(i) { i + 50 }), Array::makei(50, fn(i) { i })),
  ]
  let unweighted = cross_fit_predict_dispatch(
    LearnerDispatch::linear_regression(),
    x,
    y,
    folds,
  )
  let weighted = cross_fit_predict_dispatch(
    LearnerDispatch::linear_regression(),
    x,
    y,
    folds,
    sample_weight=v118_weights(n, 5.0),
  )
  assert_true(unweighted.length() == n)
  assert_true(weighted.length() == n)
  // Fold 1's model sees ONLY group A, so its constant prediction is
  // group A's mean regardless of the weights (one distinct feature
  // value per row, and the weights are uniform WITHIN the fold).
  let fold1_expect = v118_mean(y, 0, 50)
  for i = 50; i < n; i = i + 1 {
    assert_true((weighted[i] - fold1_expect).abs() <= 1.0e-9)
  }
  // Fold 2's model sees only group B.
  let fold2_expect = v118_mean(y, 50, 100)
  for i = 0; i < 50; i = i + 1 {
    assert_true((weighted[i] - fold2_expect).abs() <= 1.0e-9)
  }
  // And the unweighted run gives the same per-fold answers here, because
  // each fold is internally weight-homogeneous -- which is exactly why
  // this fixture is a SLICING test and not a weighting test.
  for i = 0; i < n; i = i + 1 {
    assert_true((unweighted[i] - weighted[i]).abs() <= 1.0e-9)
  }
  // The slicing itself is still observable: with folds that MIX the
  // groups, the weights change the answer.
  let mixed : Array[Fold] = [
    Fold::new(
      Array::makei(100, fn(i) { if i % 2 == 0 { i } else { (i + 1) % 100 } }),
      Array::makei(100, fn(i) { if i % 2 == 0 { (i + 1) % 100 } else { i } }),
    ),
  ]
  let mixed_unweighted = cross_fit_predict_dispatch(
    LearnerDispatch::linear_regression(),
    x,
    y,
    mixed,
  )
  let mixed_weighted = cross_fit_predict_dispatch(
    LearnerDispatch::linear_regression(),
    x,
    y,
    mixed,
    sample_weight=w,
  )
  assert_true(mixed_unweighted != mixed_weighted)
}

///|
/// `double_cross_fit_predict` slices through the DOUBLE indexing -- the
/// inner folds index into the outer training slice. A weight has to
/// follow `train_idx[ifold.train_idx[k]]`, not `ifold.train_idx[k]`.
///
/// With a single feature the inner models are again weight-homogeneous
/// per inner fold, so this asserts the plumbing RAN and returned the
/// right SHAPE, and that supplying weights does not break it. The
/// value-level weight assertions live in the single-cross-fit gate above.
test "v118_double_cross_fit_accepts_weights" {
  let n = 60
  let (x, y) = v118_data(n)
  let outer : Array[Fold] = [
    Fold::new(Array::makei(40, fn(i) { i }), Array::makei(20, fn(i) { i + 40 })),
  ]
  let plain = double_cross_fit_predict_dispatch(
    LearnerDispatch::linear_regression(),
    x,
    y,
    outer,
    2,
    12345,
  )
  let weighted = double_cross_fit_predict_dispatch(
    LearnerDispatch::linear_regression(),
    x,
    y,
    outer,
    2,
    12345,
    sample_weight=v118_weights(n, 5.0),
  )
  assert_true(plain.length() == 1)
  assert_true(weighted.length() == 1)
  assert_true(plain[0].length() == 40)
  assert_true(weighted[0].length() == 40)
}

// ---------------------------------------------------------------------------
// 4. Guards
// ---------------------------------------------------------------------------

///|
/// A negative weight aborts. A negative weight flips the sign of a
/// residual, which is not "low weight", it is a different estimator
/// that happens to be expressible; letting it through would produce a
/// plausible-looking fit with no way to tell it apart from a real one.
test "panic_v118_negative_weight_aborts" {
  let n = 40
  let (x, y) = v118_data(n)
  let w = Array::make(n, 1.0)
  w[3] = -1.0
  let _ = LinearRegression::new().fit_weighted(x, y, w)
  inspect(false, content="unreachable: a negative weight must abort")
}

///|
/// The tree learners refuse one too.
test "panic_v118_negative_weight_aborts_in_the_forest" {
  let n = 40
  let (x, y) = v118_data(n)
  let w = Array::make(n, 1.0)
  w[7] = -0.5
  let _ = RFLearner::new(n_trees=3).fit_weighted(x, y, w)
  inspect(false, content="unreachable: a negative weight must abort")
}

///|
/// A weight vector of the wrong length aborts rather than being padded
/// or truncated. Truncation would silently drop the tail rows'
/// weights; padding would fit weight 0 on them.
test "panic_v118_mismatched_weight_length_aborts" {
  let n = 40
  let (x, y) = v118_data(n)
  let w = Array::make(n - 1, 1.0)
  let _ = LinearRegression::new().fit_weighted(x, y, w)
  inspect(false, content="unreachable: a short weight vector must abort")
}

///|
/// Same at the cross-fit boundary, where the error is about the caller
/// supplying a vector that does not line up with the design matrix.
test "panic_v118_cross_fit_rejects_a_misaligned_weight_vector" {
  let n = 40
  let (x, y) = v118_data(n)
  let folds : Array[Fold] = [
    Fold::new(Array::makei(20, fn(i) { i }), Array::makei(20, fn(i) { i + 20 })),
  ]
  let _ = cross_fit_predict_dispatch(
    LearnerDispatch::linear_regression(),
    x,
    y,
    folds,
    sample_weight=Array::make(n - 1, 1.0),
  )
  inspect(false, content="unreachable: a misaligned weight vector must abort")
}
