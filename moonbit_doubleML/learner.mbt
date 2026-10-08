///|
// Learner injection for v0.54.0+.
//
// Upstream `doubleml-for-py` accepts any sklearn-compatible
// estimator as `learner_l` / `learner_m`. The MoonBit port
// already declares the `Learner` trait in `linear.mbt` with
// two methods (`fit` + `predict`) and provides a generic
// `cross_fit_predict[T : Learner]` cross-fit helper. This
// module adds two learner variants on top of the existing
// `LinearRegression` (which is the v0.54.0 default):
//
//   - `ConstantLearner(value)`: predicts `value` for every
//     row. Useful for unit tests that want a known-null
//     nuisance estimator (the DML score should collapse to
//     θ ≈ 0 when `l_hat == 0`).
//
//   - `NoopLearner`: a trivial learner that always returns
//     zero for every row. Useful for sanity tests that the
//     DML pipeline doesn't divide by zero when the nuisance
//     is trivial.
//
// Adding more learner types (logistic regression, gradient
// boosting, random forest) is a one-line `impl Learner for X`
// away — no other code changes required, because
// `cross_fit_predict[T : Learner]` is generic.
//
// `LearnerDispatch` is the enum wrapper that lets a non-generic
// struct field hold one of the concrete learner types. The
// dispatcher `cross_fit_predict_dispatch` pattern-matches the
// enum and routes each arm to the generic
// `cross_fit_predict[T : Learner]` with the right concrete
// `T`. Adding a new learner type means:
//   1. declare `impl Learner for NewType`
//   2. add a `NewType(NewType)` arm to `LearnerDispatch`
//   3. add the corresponding match arm in
//      `cross_fit_predict_dispatch` and
//      `learner_dispatch_default`.

///|
/// Constant-predictor learner. `fit` is a no-op (returns
/// `self`); `predict` returns a length-`x.rows()` array of
/// the constant `value` for every row, ignoring `x`.
pub struct ConstantLearner {
  value : Double
} derive(Debug)

///|
pub extend ConstantLearner with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ConstantLearner with Learner::{predict}

///|
pub fn ConstantLearner::new(value : Double) -> ConstantLearner {
  { value, }
}

///|
/// v0.118.0: the body became this inherent method so that
/// `ConstantLearner::new(..).fit(x, y)` still resolves; the trait
/// method (three-argument) delegates here.
pub fn ConstantLearner::fit(
  self : ConstantLearner,
  x : Matrix,
  y : Array[Double],
) -> ConstantLearner {
  // "fit" for a constant predictor: stash the n_rows + n_targets
  // shape on `self` so subsequent `predict` calls can short-circuit
  // (no actual training occurs; the predictor is constant).
  // For now, we just consume the inputs and return self.
  let _n : Int = x.rows() * y.length()
  let _ = _n
  self
}

///|
impl Learner for ConstantLearner with fn fit(self, x, y, _w) {
  self.fit(x, y)
}

///|
impl Learner for ConstantLearner with fn predict(self, x) {
  Array::make(x.rows(), self.value)
}

///|
/// Trivial learner: predicts zero for every row. `fit` is a
/// no-op; `predict` returns all zeros. Useful for sanity
/// tests that the DML pipeline doesn't divide by zero when
/// the nuisance is trivial.
pub struct NoopLearner {
  // `value : Double = 0.0` placeholder; preserved as a struct
  // (not a unit type) so adding fields later is non-breaking.
  value : Double
} derive(Debug)

///|
pub extend NoopLearner with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend NoopLearner with Learner::{predict}

///|
pub fn NoopLearner::new() -> NoopLearner {
  { value: 0.0, }
}

///|
/// v0.118.0: same treatment as `ConstantLearner::fit` -- the body is
/// an inherent method, the three-argument trait method delegates.
pub fn NoopLearner::fit(
  self : NoopLearner,
  x : Matrix,
  y : Array[Double],
) -> NoopLearner {
  // Same as ConstantLearner::fit: touch the inputs so the
  // compiler doesn't flag the impl body as unused, then
  // return self.
  let _n : Int = x.rows() * y.length()
  let _ = _n
  self
}

///|
impl Learner for NoopLearner with fn fit(self, x, y, _w) {
  self.fit(x, y)
}

///|
impl Learner for NoopLearner with fn predict(self, x) {
  Array::make(x.rows(), self.value)
}

///|
/// Dispatch enum for the `Learner` trait. Stores one of the
/// concrete learner types and lets `cross_fit_predict_dispatch`
/// route to the right `cross_fit_predict[T : Learner]` arm.
///
/// The enum keeps `DoubleMLPLR` non-generic in its struct
/// definition (callers don't have to write
/// `DoubleMLPLR[LinearRegression, LinearRegression]`), at the
/// cost of an extra match arm per learner type. Adding a new
/// learner is 3 small edits (see the file header).
pub enum LearnerDispatch {
  /// OLS via `LinearRegression` (the v0.54.0 default)
  LinearRegression(LinearRegression)
  /// Constant-predictor learner (see `ConstantLearner`)
  Constant(ConstantLearner)
  /// Zero-predictor learner (see `NoopLearner`)
  Noop(NoopLearner)
  /// Pure-MoonBit random forest (Breiman 2001 regression).
  /// v0.56.0+: Path A — first non-OLS learner.
  RandomForest(RFLearner)
  /// Pure-MoonBit gradient boosting (Friedman 2001 regression).
  /// v0.57.0+: Path A — second non-OLS learner.
  GradientBoosting(GBLearner)
  /// Pure-MoonBit logistic regression (binary classification,
  /// IRLS Newton-Raphson). v0.62.0+: added for LPLR plumbing.
  /// `predict` returns P(y = 1 | x) for every row.
  LogisticRegression(LogisticRegression)
  /// Pure-MoonBit random-forest CLASSIFICATION (Breiman 2001,
  /// Gini splits). v0.117.0+: the first nonlinear classifier, added so
  /// the binary-outcome estimators have a bagged option for `ml_m`
  /// that is not logistic. `predict` returns P(y = 1 | x).
  RandomForestClassifier(RFClassifier)
  /// Pure-MoonBit gradient-boosting CLASSIFICATION (Friedman 2001,
  /// binary log loss, Newton leaf values). v0.117.0+: the boosted
  /// counterpart. `predict` returns P(y = 1 | x).
  GradientBoostingClassifier(GBClassifier)
} derive(Debug)

///|
pub extend LearnerDispatch with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Default `LearnerDispatch` (a fresh `LinearRegression`).
/// Used as the default value for the `learner_l` /
/// `learner_m` labeled params on `DoubleMLPLR::new`.
pub fn LearnerDispatch::linear_regression() -> LearnerDispatch {
  LinearRegression(LinearRegression::new())
}

///|
/// Wrap a `ConstantLearner` in a `LearnerDispatch`.
pub fn LearnerDispatch::constant(value : Double) -> LearnerDispatch {
  Constant(ConstantLearner::new(value))
}

///|
/// Wrap a `NoopLearner` in a `LearnerDispatch`.
pub fn LearnerDispatch::noop() -> LearnerDispatch {
  Noop(NoopLearner::new())
}

///|
/// Wrap an `RFLearner` in a `LearnerDispatch`. v0.56.0+.
/// Factory for the Path A random-forest learner; callers can
/// override n_trees / max_depth / min_samples_leaf / mtry via
/// `RFLearner::new(...)` before wrapping.
pub fn LearnerDispatch::random_forest(rf : RFLearner) -> LearnerDispatch {
  RandomForest(rf)
}

///|
/// Wrap a `GBLearner` in a `LearnerDispatch`. v0.57.0+.
/// Factory for the Path A gradient-boosting learner; callers
/// can override n_trees / learning_rate / max_depth / subsample
/// via `GBLearner::new(...)` before wrapping.
pub fn LearnerDispatch::gradient_boosting(gb : GBLearner) -> LearnerDispatch {
  GradientBoosting(gb)
}

///|
/// Wrap a `LogisticRegression` in a `LearnerDispatch`.
/// v0.62.0+: LPLR plumbing — binary classification for the
/// double cross-fit path (`ml_M`, `ml_a`, `ml_m`).
pub fn LearnerDispatch::logistic_regression(
  lr : LogisticRegression,
) -> LearnerDispatch {
  LogisticRegression(lr)
}

///|
/// Wrap an `RFClassifier` in a `LearnerDispatch`. v0.117.0+.
///
/// `predict` returns `P(y = 1 | x)`, so this is drop-in for the
/// binary-classification nuisance slots (`ml_m`, `ml_M`, `ml_a`)
/// alongside `logistic_regression`.
pub fn LearnerDispatch::random_forest_classifier(
  rf : RFClassifier,
) -> LearnerDispatch {
  RandomForestClassifier(rf)
}

///|
/// Wrap a `GBClassifier` in a `LearnerDispatch`. v0.117.0+.
///
/// `predict` returns `P(y = 1 | x)` -- see
/// `LearnerDispatch::random_forest_classifier`.
pub fn LearnerDispatch::gradient_boosting_classifier(
  gb : GBClassifier,
) -> LearnerDispatch {
  GradientBoostingClassifier(gb)
}

///|
/// Cross-fit a `LearnerDispatch` over the given folds. This
/// is the dispatch wrapper around `cross_fit_predict[T : Learner]`
/// (which is generic in `T`); each match arm binds a concrete
/// `T` so the generic call resolves correctly.
///
/// Adding a new learner type: add the corresponding match arm
/// here (and the enum variant in `LearnerDispatch`).
///
/// v0.118.0: `sample_weight?` is forwarded through every arm; empty
/// means unweighted, which is the byte-identical pre-v0.118.0 path.
pub fn cross_fit_predict_dispatch(
  learner : LearnerDispatch,
  x : Matrix,
  y : Array[Double],
  folds : Array[Fold],
  sample_weight? : Array[Double] = [],
) -> Array[Double] {
  match learner {
    LinearRegression(lr) => cross_fit_predict(lr, x, y, folds, sample_weight~)
    Constant(c) => cross_fit_predict(c, x, y, folds, sample_weight~)
    Noop(n) => cross_fit_predict(n, x, y, folds, sample_weight~)
    RandomForest(rf) => cross_fit_predict(rf, x, y, folds, sample_weight~)
    GradientBoosting(gb) => cross_fit_predict(gb, x, y, folds, sample_weight~)
    LogisticRegression(lr) => cross_fit_predict(lr, x, y, folds, sample_weight~)
    RandomForestClassifier(rf) =>
      cross_fit_predict(rf, x, y, folds, sample_weight~)
    GradientBoostingClassifier(gb) =>
      cross_fit_predict(gb, x, y, folds, sample_weight~)
  }
}

///|
/// Single-fit + single-predict helper for a `LearnerDispatch`.
/// Used by estimators (e.g. `DoubleMLSSM` for the augmented
/// `(X, D) -> S` pi fit, `DoubleMLIIVM` for conditional subsets
/// where the augmenting column changes the feature matrix shape)
/// that need a one-off `fit` on a subset followed by a `predict`
/// on a different-shape test set — i.e. cases where
/// `cross_fit_predict_dispatch` (which slices a single matrix
/// by train/test indices) doesn't apply.
///
/// v0.59.0+.
pub fn fit_predict_one_dispatch(
  learner : LearnerDispatch,
  x_train : Matrix,
  y_train : Array[Double],
  x_test : Matrix,
) -> Array[Double] {
  match learner {
    LinearRegression(lr) => lr.fit(x_train, y_train).predict(x_test)
    Constant(c) => c.fit(x_train, y_train).predict(x_test)
    Noop(n) => n.fit(x_train, y_train).predict(x_test)
    RandomForest(rf) => rf.fit(x_train, y_train).predict(x_test)
    GradientBoosting(gb) => gb.fit(x_train, y_train).predict(x_test)
    LogisticRegression(lr) => lr.fit(x_train, y_train).predict(x_test)
    RandomForestClassifier(rf) => rf.fit(x_train, y_train).predict(x_test)
    GradientBoostingClassifier(gb) => gb.fit(x_train, y_train).predict(x_test)
  }
}
