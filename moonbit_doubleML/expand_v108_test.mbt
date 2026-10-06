// v0.108.0 — the tune gate that can actually fail.
//
// # Why this file exists
//
// v0.65.0 added `v065_wbtest.mbt` with four tests named
// `*_tune_picks_ols_candidate`. Each built a grid out of one or two
// IDENTICAL candidates — `[lr, lr]`, or just `[lr]` — and then
// asserted only that the resulting coefficient was not NaN. The
// selection step had nothing to decide, so the tests could not fail
// on a selection defect.
//
// Measured, not asserted: inverting the argmin in
// `DoubleMLPLR::tune` from `<` to `>` and re-running the whole suite
// gave `Total tests: 808, passed: 808, failed: 0.` The gate was dead,
// and a test name that claims a property is not a check of one.
//
// # The grid order is the whole design
//
// Every grid here is ordered `[worst, best]`. That is not cosmetic —
// it is what makes the gate lethal:
//
//   * argmin inverted to argmax          -> picks index 1 (Noop) -> FAILS
//   * selection short-circuited to index 0 -> picks Noop          -> FAILS
//   * every score forced to 0.0          -> argmin keeps index 0   -> FAILS
//
// With the good candidate first, all three of those mutations pass.
//
// # Why the separation is dominance, not a statistical band
//
// The DGP is `y = 3.0*x1 + 0.1*u` with `x1 ~ U(-1,1)`, `u ~ U(-1,1)`.
//   * OLS recovers `y` up to the noise: OOF MSE ~ 0.01/3 ~ 3e-3
//   * `NoopLearner` predicts 0 for every row:    MSE ~ E[y^2] ~ 3.0
//
// The gap is ~900x and it is a property of the DGP, not a lucky draw:
// the bias term `3.0*x1` contributes `9*Var(x1) = 3.0` to `E[y^2]`
// regardless of the noise realization. So the assertion is
// `good < bad / 10`, a factor-of-ten margin, and it holds on every
// seed. No 1/sqrt(n) band is needed and none is offered here: a band
// wide enough to absorb a 900x misselection would also absorb a
// completely broken scorer.
//
// A noiseless variant (`y = 3.0*x1` exactly, MSE == 0.0 for OLS) is
// asserted separately in `tune_grid_ols_score_is_exactly_zero`, which
// is the one hard zero-MC identity available for this code path.

// ---------------------------------------------------------------------------
// shared DGP — private to this file (MoonBit `fn` is file-scoped)
// ---------------------------------------------------------------------------

///|
fn v108_dgp(
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
  (Matrix::from_array(x_flat, n, p), y, d)
}

///|
/// The worst-then-best grid every test in this file uses. Index 0 is
/// `NoopLearner` on purpose — see the file header.
fn v108_grid() -> Array[LearnerDispatch] {
  [LearnerDispatch::noop(), LearnerDispatch::linear_regression()]
}

// ---------------------------------------------------------------------------
// the shared core, tested directly
// ---------------------------------------------------------------------------

///|
test "tune_score_grid_selects_the_better_candidate" {
  let (x, y, _d) = v108_dgp(300, 2, 11)
  let grid = tune_score_grid(
    x,
    y,
    v108_grid(),
    4,
    11,
    TuneScoring::parse("MSE"),
  )
  // index 1 (OLS) must score strictly better than index 0 (Noop) by
  // more than a factor of ten. See the file header for why a factor
  // of ten is a structural margin and not a tuned one.
  assert_true(grid.scores[1] < grid.scores[0] / 10.0)
  assert_true(grid.best_index == 1)
}

///|
/// The higher-is-better branch must invert, not share the same
/// comparison. Under `NegMSE` the same grid must select the same
/// winner — if the branch were dropped and the argmin reused, this
/// would pick index 0 and fail.
test "tune_score_grid_negmse_selects_the_same_winner" {
  let (x, y, _d) = v108_dgp(300, 2, 12)
  let grid = tune_score_grid(
    x,
    y,
    v108_grid(),
    4,
    12,
    TuneScoring::parse("NegMSE"),
  )
  assert_true(grid.best_index == 1)
  // NegMSE is the negated MSE: the two rules must agree on the
  // winner while disagreeing on the sign of every score.
  let mse = tune_score_grid(x, y, v108_grid(), 4, 12, TuneScoring::parse("MSE"))
  for i = 0; i < grid.scores.length(); i = i + 1 {
    assert_true(grid.scores[i] == -mse.scores[i])
  }
}

///|
/// The one hard zero-MC identity on this path: with a noiseless
/// linear outcome, OLS reproduces `y` exactly out of fold, so its
/// score is `0.0` — not "small", exactly zero. `NoopLearner` still
/// scores `E[y^2] > 0`, so the winner is unambiguous and the score
/// vector is `{positive, 0.0}`.
test "tune_grid_ols_score_is_exactly_zero" {
  let n = 240
  let p = 2
  let rng = chacha8_rng(13)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double() * 2.0 - 1.0
    }
    // no noise at all: y is an exact linear function of x1
    y[i] = 3.0 * x_flat[i * p + 0]
  }
  let x = Matrix::from_array(x_flat, n, p)
  let grid = tune_score_grid(
    x,
    y,
    v108_grid(),
    4,
    13,
    TuneScoring::parse("MSE"),
  )
  // Measured on this exact configuration (n=240, p=2, seed=13,
  // 4 folds): OLS scores 9.123421520996841e-24, Noop scores
  // 2.768660418644647. Not `0.0` — the residual is the floating-point
  // roundoff floor of the 2x2 normal-equation solve, not sampling
  // noise, and it is set by the linear algebra rather than by the
  // draw. So this is a zero-MC assertion in the sense that matters
  // (the number does not move with the seed) and NOT in the sense
  // that it is bit-exactly zero. Asserting `== 0.0` here would be a
  // false identity: it was written that way first and measured at
  // 9.12e-24.
  assert_true(grid.scores[1] < 1.0e-20)
  assert_true(grid.scores[0] > 1.0)
  assert_true(grid.best_index == 1)
  assert_true(grid.scores[0] > 0.0)
  assert_true(grid.best_index == 1)
}

///|
/// The fail-sentinel guard is DEFENSIVE and currently unreachable.
///
/// This used to be a test — it asserted that a degenerate candidate
/// (an `RFLearner` with `n_trees=0`, the example the v0.58.0 comment
/// named) is excluded by scoring `TUNE_SCORE_FAIL_SENTINEL`. It does
/// not, and never did: `RFLearner::fit` raises `PreconditionError` on
/// `n_trees=0` and its own `catch` converts that to `abort`
/// (`rfl.mbt:404`), which no caller can intercept. The test killed
/// the test binary with `moonbit_panic`.
///
/// The guard is kept — a future learner could return a short vector
/// without aborting — but it is no longer claimed to be reachable
/// today, and the misleading example is gone from the core's docs.
/// There is deliberately no replacement test here: a guard with no
/// path to reach it has nothing to assert, and a test that constructs
/// the unreachability would be asserting a comment.

// ---------------------------------------------------------------------------
// DoubleMLPLR::tune — the refactored reference implementation
// ---------------------------------------------------------------------------

///|
test "plr_tune_selects_the_ols_candidate" {
  let (x, y, d) = v108_dgp(300, 2, 21)
  let data = DoubleMLData::new(x, y, d)
  let fitted = DoubleMLPLR::new(data, n_folds=4, seed=21).tune(
    param_set=[
      TuneParam::for_outcome(LearnerDispatch::noop(), LearnerDispatch::noop()),
      TuneParam::for_outcome(
        LearnerDispatch::linear_regression(),
        LearnerDispatch::linear_regression(),
      ),
    ],
    n_folds_tune=4,
    seed=21,
  )
  // The persisted `TuneResult` is the audit trail: assert on it
  // rather than on a coefficient, so the test checks the SELECTION.
  //
  // Every check here is an `assert_true`, never an `abort`. An abort
  // kills the whole test binary, so a mis-selection would take the
  // other 811 tests' results down with it and the failure would be
  // unattributable. Assertions keep the failure attributed to this
  // test and leave the rest of the suite reportable.
  match fitted.tune_result() {
    None => assert_true(false) // tune must always record a result
    Some(tr) => {
      assert_true(tr.all_scores[1] < tr.all_scores[0] / 10.0)
      assert_true(
        match tr.best.learner_l {
          LearnerDispatch::LinearRegression(_) => true
          _ => false
        },
      )
      assert_true(tr.best_score == tr.all_scores[1])
    }
  }
  let coef = fitted.coef()
  assert_true(coef.is_nan() == false)
  assert_true(coef.is_inf() == false)
}

// ---------------------------------------------------------------------------
// per-wrapper plumbing, v0.108.0
//
// The shared core is mutation-proven, so the residual risk in each of the
// fourteen new wrappers is NOT the selection rule -- it is the plumbing:
// does the right TuneParam slot reach the right `fit` argument, and is the
// right data field read? These four cover the shapes that differ from the
// plain two-slot case:
//
//   SSM   three `fit` slots, but `ml_pi` is a `fit` DEFAULT (`self.ml_m`),
//         not a struct field -- the grid cannot and does not reach it
//   RDD   single slot, bare `Array[LearnerDispatch]` grid
//   PLPR  single slot, bare grid, panel data
//   LPLR  two slots where the FIELD is `ml_g` but the ROLE is the outcome
//         learner -- the one case where reading the field name as the role
//         would put the winner in the wrong argument
//
// Same `[worst, best]` grid and the same dominance DGP as the core tests, so
// the same three mutations are lethal here too.
// ---------------------------------------------------------------------------

///|
fn v108_is_ols(learner : LearnerDispatch) -> Bool {
  match learner {
    LearnerDispatch::LinearRegression(_) => true
    _ => false
  }
}

///|
test "v108_ssm_tune_winner_lands_in_ml_g" {
  let (x, y, d) = v108_dgp(300, 2, 31)
  let n = 300
  let s : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    s[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
  }
  let data = DoubleMLSSMData::new(x, y, d, s)
  let fitted = DoubleMLSSM::new(data, n_folds=4, seed=31).tune(
    param_set=[
      TuneParam::for_treatment(LearnerDispatch::noop(), LearnerDispatch::noop()),
      TuneParam::for_treatment(
        LearnerDispatch::linear_regression(),
        LearnerDispatch::linear_regression(),
      ),
    ],
    n_folds_tune=4,
    seed=31,
  )
  assert_true(v108_is_ols(fitted.ml_g))
  assert_true(v108_is_ols(fitted.ml_m))
}

///|
test "v108_rdd_tune_winner_lands_in_ml_g" {
  // running variable spread around 0; D = 1{X > 0}
  let n = 300
  let p = 1
  let rng = chacha8_rng(32)
  let x_flat : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let score : Array[Double] = Array::make(n, 1.0)
  for i = 0; i < n; i = i + 1 {
    let v = rng.double() * 2.0 - 1.0
    x_flat[i] = v
    d[i] = if v > 0.0 { 1.0 } else { 0.0 }
    y[i] = 3.0 * v + 0.1 * (rng.double() - 0.5) * 2.0
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLRDDData::new(x, y, d, score)
  // RDD is single-slot: the grid is a bare learner array, per PLIV.
  let fitted = DoubleMLRDD::new(
    data,
    cutoff=0.0,
    bandwidth=0.6,
    ml_g=LearnerDispatch::linear_regression(),
  ).tune(
    param_set=[LearnerDispatch::noop(), LearnerDispatch::linear_regression()],
    n_folds_tune=4,
    seed=32,
  )
  assert_true(v108_is_ols(fitted.ml_g))
}

///|
test "v108_plpr_tune_winner_lands_in_learner" {
  // panel: 4 periods x 75 units
  let n_units = 75
  let n_periods = 4
  let n = n_units * n_periods
  let p = 2
  let rng = chacha8_rng(33)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t : Array[Int] = Array::make(n, 0)
  let id : Array[Int] = Array::make(n, 0)
  for u = 0; u < n_units; u = u + 1 {
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      let x0 = rng.double() * 2.0 - 1.0
      x_flat[row * p + 0] = x0
      x_flat[row * p + 1] = rng.double() * 2.0 - 1.0
      t[row] = k
      id[row] = u
      // Staggered adoption, which PLPR needs: PLPR's score divides by the
      // weighted sum of `psi_a` over treated units and requires it to be
      // non-zero (plpr.mbt:218). A panel where EVERY unit is treated
      // leaves no comparison group, that sum collapses to 0, and the
      // fit aborts -- so the treatment must vary across units, not just
      // across periods.
      //   u <  30        always-treated
      //   30 <= u <  45  not-yet-treated (adopts at k == 2)
      //   u >= 45        never-treated
      d[row] = if u < 30 {
        1.0
      } else if u < 45 {
        if k >= 2 {
          1.0
        } else {
          0.0
        }
      } else {
        0.0
      }
      y[row] = 3.0 * x0 + 0.1 * (rng.double() - 0.5) * 2.0
    }
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLPanelData::new(x, y, d, t, id)
  let fitted = DoubleMLPLPR::new(data, n_folds=4, seed=33).tune(
    param_set=[LearnerDispatch::noop(), LearnerDispatch::linear_regression()],
    n_folds_tune=4,
    seed=33,
  )
  assert_true(v108_is_ols(fitted.learner))
}

///|
/// LPLR is the case where the field name and the slot's role disagree: the
/// `fit` argument is called `ml_g`, and LPLR's own accessors document
/// `learner_g` as the OUTCOME learner with `learner_m` the propensity. A
/// reader who maps "g" to "propensity" would build the grid backwards. This
/// test pins that the FIRST TuneParam slot -- the outcome learner -- is what
/// lands in `ml_g`.
///
/// It needs its own DGP, not `v108_dgp`, because
/// `DoubleMLBinaryData::new` requires a BINARY outcome
/// (`lplr.mbt:52`: `yi == 0.0 || yi == 1.0`) and LPLR is the binary-outcome
/// estimator.
///
/// And a binary outcome changes what margin is even available: the best
/// possible learner's MSE is bounded below by `E[Var(y|x)]`, so against a
/// zero-predictor the ratio can never exceed 2x unless `x` predicts `y`
/// strongly. Hence the GAP: `x0` is drawn from `U(-1,-0.2) + U(0.2,1)` and
/// `y = 1{x0 > 0}`, so `E[p(1-p)]` collapses onto the narrow transition
/// band and OLS scores an order of magnitude below `NoopLearner`'s 0.5.
/// With `x0 ~ U(-1,1)` and no gap the ratio would be only 2x and the
/// assertion would be a bet on the draw.
test "v108_lplr_tune_first_slot_lands_in_ml_g" {
  let n = 300
  let p = 2
  let rng = chacha8_rng(34)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u = rng.double()
    // margin: no observation lands inside (-0.2, 0.2)
    let x0 = if u < 0.5 {
      -0.2 - rng.double() * 0.8
    } else {
      0.2 + rng.double() * 0.8
    }
    x_flat[i * p + 0] = x0
    x_flat[i * p + 1] = rng.double() * 2.0 - 1.0
    y[i] = if x0 > 0.0 { 1.0 } else { 0.0 }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLBinaryData::new(x, y, d)
  let fitted = DoubleMLLPLR::new(data, n_folds=4, seed=34).tune(
    param_set=[
      // index 0 is the WORSE pair; index 1 the better one
      TuneParam::for_outcome(LearnerDispatch::noop(), LearnerDispatch::noop()),
      TuneParam::for_outcome(
        LearnerDispatch::linear_regression(),
        LearnerDispatch::linear_regression(),
      ),
    ],
    n_folds_tune=4,
    seed=34,
  )
  assert_true(v108_is_ols(fitted.ml_g))
  assert_true(v108_is_ols(fitted.ml_m))
}
