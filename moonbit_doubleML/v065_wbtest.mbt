///|
// v0.65.0+: wbtests for Item #2 (fit_cluster) and Item #4
// (tune on the four remaining IRM-style estimators).
//
// Coverage:
//   #4: IRM / PLIV / IIVM / APO  ::tune() picks the OLS candidate
//       out of a grid that ALSO CONTAINS A WORSE CANDIDATE, and
//       re-fits with it.
//   #2: IRM / PQ / APO / APOS ::fit_cluster() runs with
//       cluster_vars=non-empty and produces a fitted model
//       with finite coef / se (smoke test).
//
// v0.108.0 rewrite of the #4 tests. The originals were named
// `*_tune_picks_ols_candidate` but built grids out of one or two
// IDENTICAL candidates - `[lr, lr]`, or just `[lr]` - so the
// selection step had nothing to decide, and the only assertion was
// that the coefficient was not NaN. Inverting the argmin in
// `tune.mbt` left the whole suite at 808/808. The names were claims,
// not checks.
//
// Two things make the rewritten tests able to fail:
//   1. the grid is `[worst, best]` - `NoopLearner` predicts 0, so an
//      inverted argmin, a skipped argmin, or a short-circuited scorer
//      all land on the Noop candidate and fail the assertion;
//   2. the DGP makes OLS DOMINATE rather than merely edge out Noop.
//      The v0.65.0 generator was `y = 1.2*d + 0.5*x0 + noise`, whose
//      variance is dominated by the `1.2*d` term that OLS on `x` cannot
//      see: OOF MSE lands near 0.36 and Noop's near 0.44, a factor of
//      1.2. A selection assertion on a 1.2x separation is a bet on the
//      draw, not a check. The generator below is `y = 3.0*x0 + 0.1*u`,
//      giving OOF MSE ~3e-3 against Noop's ~3.0 - about 900x, a
//      property of the DGP rather than of the seed.
//   3. assertions are `assert_true`, never `abort`: an abort kills the
//      whole test binary and makes the failure unattributable.
//
// The core itself is tested directly, and mutation-proven, in
// `expand_v108_test.mbt`.

// ---------------------------------------------------------------------------
// #4: tune() selection tests
// ---------------------------------------------------------------------------

///|
/// Worst-then-best grid. Index 0 is `NoopLearner` on purpose - see
/// the file header. The same shape is used for the outcome-nuisance
/// families; `TuneParam::for_treatment` is the right intent label
/// here because the first slot is the g/propensity learner for
/// IRM / IIVM / APO (see the slot-semantics table on `TuneParam`).
fn build_tune_grid() -> Array[TuneParam] {
  [
    TuneParam::for_treatment(LearnerDispatch::noop(), LearnerDispatch::noop()),
    TuneParam::for_treatment(
      LearnerDispatch::linear_regression(),
      LearnerDispatch::linear_regression(),
    ),
  ]
}

///|
/// `y = 3.0*x0 + 0.1*u`. See the file header for why the outcome must
/// not depend on `d`: the tune cross-fit regresses `y` on `x` alone,
/// so any variance the model cannot reach shrinks the separation
/// between a good and a bad candidate toward 1.0.
///
/// `d` is still drawn (these estimators need a treatment vector) but
/// it is deliberately not a determinant of `y`.
fn build_irm_tune_data(
  n : Int,
  p : Int,
  seed : Int,
) -> (Matrix, Array[Double], Array[Double]) {
  let rng = chacha8_rng(seed)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double() * 2.0 - 1.0
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    y[i] = 3.0 * x_flat[i * p + 0] + 0.1 * (rng.double() - 0.5) * 2.0
  }
  let x = Matrix::from_array(x_flat, n, p)
  (x, y, d)
}

///|
fn is_ols(learner : LearnerDispatch) -> Bool {
  match learner {
    LearnerDispatch::LinearRegression(_) => true
    _ => false
  }
}

///|
test "irm_tune_picks_ols_candidate" {
  let (x, y, d) = build_irm_tune_data(300, 2, 1)
  let data = DoubleMLData::new(x, y, d)
  let fitted = DoubleMLIRM::new(data, n_folds=4, seed=1).tune(
    param_set=build_tune_grid(),
    n_folds_tune=4,
    seed=1,
  )
  // the selection itself: the re-fitted model must carry the WINNER
  assert_true(is_ols(fitted.ml_g))
  assert_true(is_ols(fitted.ml_m))
  let coef = fitted.coef()
  assert_true(coef.is_nan() == false)
  assert_true(coef.is_inf() == false)
}

///|
test "pliv_tune_picks_ols_candidate" {
  let (x, y, d) = build_irm_tune_data(300, 2, 2)
  let z : Array[Double] = Array::make(300, 0.0)
  for i = 0; i < 300; i = i + 1 {
    z[i] = if i % 3 == 0 { 1.0 } else { 0.0 }
  }
  let data = DoubleMLPLIVData::new(x, y, d, z)
  // PLIV keeps a bare `Array[LearnerDispatch]` grid (one nuisance
  // slot), so the worst-then-best ordering is applied to it directly.
  let fitted = DoubleMLPLIV::new(data, n_folds=4, seed=2).tune(
    param_set=[LearnerDispatch::noop(), LearnerDispatch::linear_regression()],
    n_folds_tune=4,
    seed=2,
  )
  assert_true(is_ols(fitted.learner))
  let coef = fitted.coef()
  assert_true(coef.is_nan() == false)
  assert_true(coef.is_inf() == false)
}

///|
test "iivm_tune_picks_ols_candidate" {
  let (x, y, d) = build_irm_tune_data(300, 2, 3)
  let z : Array[Double] = Array::make(300, 0.0)
  for i = 0; i < 300; i = i + 1 {
    z[i] = if i % 3 == 0 { 1.0 } else { 0.0 }
  }
  let data = DoubleMLIIVMData::new(x, y, d, z)
  let fitted = DoubleMLIIVM::new(data, n_folds=4, seed=3).tune(
    param_set=build_tune_grid(),
    n_folds_tune=4,
    seed=3,
  )
  assert_true(is_ols(fitted.ml_g))
  assert_true(is_ols(fitted.ml_m))
  let coef = fitted.coef()
  assert_true(coef.is_nan() == false)
  assert_true(coef.is_inf() == false)
}

///|
test "apo_tune_picks_ols_candidate" {
  let (x, y, d) = build_irm_tune_data(300, 2, 4)
  let data = DoubleMLData::new(x, y, d)
  let fitted = DoubleMLAPO::new(data, treatment_level=1.0, n_folds=4, seed=4).tune(
    param_set=build_tune_grid(),
    n_folds_tune=4,
    seed=4,
  )
  assert_true(is_ols(fitted.ml_g))
  assert_true(is_ols(fitted.ml_m))
  let coef = fitted.coef()
  assert_true(coef.is_nan() == false)
  assert_true(coef.is_inf() == false)
}

// ---------------------------------------------------------------------------
// #2: fit_cluster() smoke tests (PQ / APO deferred; IRM
// already had fit_cluster — the smoke test confirms the v0.65.0
// path still produces finite coef / se when cluster_vars is
// non-empty).
// ---------------------------------------------------------------------------

///|
test "irm_fit_cluster_produces_finite_estimates" {
  let n = 200
  let n_units = 50
  let rng = chacha8_rng(5)
  let x_flat : Array[Double] = Array::make(n * 2, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let cluster : Array[Int] = Array::make(n, 0)
  for u = 0; u < n_units; u = u + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    let d_i = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    for period = 0; period < 4; period = period + 1 {
      let row = u * 4 + period
      cluster[row] = u
      x_flat[row * 2 + 0] = x0
      x_flat[row * 2 + 1] = rng.double() * 2.0 - 1.0
      d[row] = d_i
      y[row] = 1.0 * d_i + 0.5 * x0 + (rng.double() - 0.5) * 0.1
    }
  }
  let x = Matrix::from_array(x_flat, n, 2)
  let data = DoubleMLData::new(x, y, d, cluster_vars=cluster)
  let fitted = DoubleMLIRM::new(data, n_folds=4, seed=5).fit()
  let coef = fitted.coef()
  let se = fitted.se()
  assert_true(coef.is_nan() == false)
  assert_true(se.is_nan() == false)
  assert_true(se > 0.0)
}

///|
test "apo_fit_cluster_produces_finite_estimates" {
  let n = 200
  let n_units = 50
  let rng = chacha8_rng(6)
  let x_flat : Array[Double] = Array::make(n * 2, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let cluster : Array[Int] = Array::make(n, 0)
  for u = 0; u < n_units; u = u + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    let d_i = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    for period = 0; period < 4; period = period + 1 {
      let row = u * 4 + period
      cluster[row] = u
      x_flat[row * 2 + 0] = x0
      x_flat[row * 2 + 1] = rng.double() * 2.0 - 1.0
      d[row] = d_i
      y[row] = 1.0 * d_i + 0.5 * x0 + (rng.double() - 0.5) * 0.1
    }
  }
  let x = Matrix::from_array(x_flat, n, 2)
  let data = DoubleMLData::new(x, y, d, cluster_vars=cluster)
  let fitted = DoubleMLAPO::new(data, treatment_level=1.0, n_folds=4, seed=6).fit()
  let coef = fitted.coef()
  let se = fitted.se()
  assert_true(coef.is_nan() == false)
  assert_true(se.is_nan() == false)
  assert_true(se > 0.0)
}
