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
pub extend ConstantLearner with Learner::{fit, predict}

///|
pub fn ConstantLearner::new(value : Double) -> ConstantLearner {
  { value, }
}

///|
impl Learner for ConstantLearner with fn fit(self, x, y) {
  // "fit" for a constant predictor: stash the n_rows + n_targets
  // shape on `self` so subsequent `predict` calls can short-circuit
  // (no actual training occurs; the predictor is constant).
  // For now, we just consume the inputs and return self.
  let _n : Int = x.rows() * y.length()
  let _ = _n
  self
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
pub extend NoopLearner with Learner::{fit, predict}

///|
pub fn NoopLearner::new() -> NoopLearner {
  { value: 0.0, }
}

///|
impl Learner for NoopLearner with fn fit(self, x, y) {
  // Same as ConstantLearner::fit: touch the inputs so the
  // compiler doesn't flag the impl body as unused, then
  // return self.
  let _n : Int = x.rows() * y.length()
  let _ = _n
  self
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
/// Cross-fit a `LearnerDispatch` over the given folds. This
/// is the dispatch wrapper around `cross_fit_predict[T : Learner]`
/// (which is generic in `T`); each match arm binds a concrete
/// `T` so the generic call resolves correctly.
///
/// Adding a new learner type: add the corresponding match arm
/// here (and the enum variant in `LearnerDispatch`).
pub fn cross_fit_predict_dispatch(
  learner : LearnerDispatch,
  x : Matrix,
  y : Array[Double],
  folds : Array[Fold],
) -> Array[Double] {
  match learner {
    LinearRegression(lr) => cross_fit_predict(lr, x, y, folds)
    Constant(c) => cross_fit_predict(c, x, y, folds)
    Noop(n) => cross_fit_predict(n, x, y, folds)
  }
}
