// v0.147.0 -- GATES for stage 1b of the did_cs sensitivity migration: the four
// `(d, t)` outcome nuisances `g_dXtY = E[Y | D=d, T=t, X]`.
//
// Measured before these gates were written, so they describe reality:
//
//   make_did_CS2021(1600,3,1.0,3141)  (4 periods)
//     g_d0t0 len 1600  mean 24.49384281440472
//     g_d0t1 len 1600  mean 24.953959534582523
//     g_d1t0 len 1600  mean 26.16197119942422
//     g_d1t1 len 1600  mean 25.55760704456009
//     cell occupancy   300 / 200 / 100 / 200   outside the 2x2 = 800
//     exact 0.0 entries anywhere in any of the four: 0
//
//   make_did_cs_CS2021(800,3,1.0,3141)  (canonical 2-period DIDCS)
//     cell occupancy   400 / 200 /   0 / 200   outside the 2x2 = 0
//
// That second line is a PROPERTY OF THE DESIGN, not a defect: the canonical
// DIDCS fixture treats its cohort at t=1, so at the pre-period nobody is
// treated and the `(d=1, t=0)` cell is structurally empty. GATE 5 pins that.
//
// WHY THESE ARE FOUR NAMED ACCESSORS AND NOT A TUPLE, which is the one design
// decision here that measurement changed: a probe looked for a statistic that
// separates the four cells and there is a good one (GATE 7's means, 1.9%
// apart) -- but it first looked for the OBVIOUS one and it does not exist.
// Cell-wise RMSE has no minimal diagonal: `g_d0t1` beats `g_d0t0` on cell
// `(d0,t0)`, because RMSE ~14 is dominated by noise while the four conditional
// means differ by under 2. So "each nuisance predicts its own cell" is not a
// property this data even has, and a gate resting on it would be decorative.
// Worse, under a POSITIONAL tuple all four arrays have the same length, are
// all finite and all vary, so a swapped return literal would pass every
// length/finiteness/variation gate. The names remove the permutation instead of
// adding a gate to catch it.

///|
fn v1470_four_period_fit() -> DoubleMLDIDCS {
  let d = make_did_CS2021(1600, 3, 1.0, 3141)
  let dml = DoubleMLDIDCSData::new(
    d.x_get(),
    d.y_get(),
    d.d_get(),
    d.t_get(),
    d.id_get(),
    d.g_get(),
  )
  DoubleMLDIDCS::new(dml, n_folds=2, n_rep=1, seed=3141).fit()
}

///|
fn v1470_two_period_fit() -> DoubleMLDIDCS {
  let d = make_did_cs_CS2021(800, 3, 1.0, 3141)
  let dml = DoubleMLDIDCSData::new(
    d.x_get(),
    d.y_get(),
    d.d_get(),
    d.t_get(),
    d.id_get(),
    d.g_get(),
  )
  DoubleMLDIDCS::new(dml, n_folds=2, n_rep=1, seed=3141).fit()
}

///| The four nuisances in upstream's own `(d0t0, d0t1, d1t0, d1t1)` order,

///|
/// for the gates that sweep all four at once.
fn v1470_all(fitted : DoubleMLDIDCS) -> Array[Array[Double]] {
  [
    fitted.predictions_g_d0_t0(),
    fitted.predictions_g_d0_t1(),
    fitted.predictions_g_d1_t0(),
    fitted.predictions_g_d1_t1(),
  ]
}

///| (count00, count01, count10, count11, countOutside)

///|

///| The `else` branch is a REAL fourth outcome -- a row with `t >= 2` -- and

///| not a catch-all for "cell 3". An earlier probe conflated the two and

///| reported cell 3 as n=1000 when it is 200; the panel does not partition

///|
/// silently, it has to be counted.
fn v1470_cells(fitted : DoubleMLDIDCS) -> (Int32, Int32, Int32, Int32, Int32) {
  let d = fitted.data.d
  let t = fitted.data.t
  let n = fitted.predictions_m().length()
  let mut c00 = 0
  let mut c01 = 0
  let mut c10 = 0
  let mut c11 = 0
  let mut other = 0
  for i = 0; i < n; i = i + 1 {
    if t[i] == 0 && d[i] == 0.0 {
      c00 = c00 + 1
    } else if t[i] == 1 && d[i] == 0.0 {
      c01 = c01 + 1
    } else if t[i] == 0 && d[i] == 1.0 {
      c10 = c10 + 1
    } else if t[i] == 1 && d[i] == 1.0 {
      c11 = c11 + 1
    } else {
      other = other + 1
    }
  }
  (c00, c01, c10, c11, other)
}

///|
fn v1470_mean(a : Array[Double]) -> Double {
  let mut s = 0.0
  for i = 0; i < a.length(); i = i + 1 {
    s = s + a[i]
  }
  s / a.length().to_double()
}

///|
fn v1470_rel(got : Double, want : Double) -> Double {
  (got - want).abs() / want.abs()
}

///|
/// GATE 1. All four nuisances COVER every row, not just the cell they were
/// fitted on. This is upstream's `fit_predict` convention (fit on
/// `train_index_cond`, predict on the whole test fold,
/// `did/tests/_utils.py:41-43`) and it is the easiest thing in this release to
/// transcribe backwards.
///
/// LENGTH ALONE CANNOT SEE THIS MUTATION, and that was measured rather than
/// argued: `cross_fit_predict_conditional_dispatch` pre-sizes its output to `n`
/// and only skips a fold whose conditioned training set is empty, so
/// restricting the OUTPUT to the cell still returns four arrays of length `n`.
/// The first version of this gate asserted length only and would have survived.
/// So it asserts COVERAGE instead: measured on the 4-period panel there are
/// zero exact `0.0` entries anywhere in any of the four arrays, while
/// cell-restricted prediction would leave 1300 / 1400 / 1500 / 1400 of them.
test "didcs_four_g_cover_every_row_not_just_their_cell" {
  let fitted = v1470_four_period_fit()
  let n = fitted.predictions_m().length()
  for a in v1470_all(fitted) {
    assert_true(a.length() == n)
    for i = 0; i < n; i = i + 1 {
      assert_true((a[i] == 0.0) == false)
    }
  }
}

///|
/// GATE 2. Each nuisance that has training data is genuinely fitted: finite and
/// varying. A constant or all-NaN array here would mean the conditional fit
/// silently fell back to something, and would still satisfy GATE 1.
test "didcs_four_g_are_finite_and_vary_where_they_have_data" {
  let fitted = v1470_four_period_fit()
  for a in v1470_all(fitted) {
    let mut varies = false
    for i = 0; i < a.length(); i = i + 1 {
      assert_true(a[i].is_nan() == false)
      if a[i] != a[0] {
        varies = true
      }
    }
    assert_true(varies)
  }
}

///|
/// GATE 3. THE `t IN {0,1}` FIXTURE PIN. Upstream's `DoubleMLDIDCS` is the 2x2
/// repeated-cross-section design and its oracle selects on `t == 0` / `t == 1`
/// only; rows with `t >= 2` train none of the four. On this 4-period panel that
/// is 800 of 1600 rows.
///
/// This is the number a future reader needs in order to notice if someone
/// "helpfully" extends the cells to later periods -- which would be a new
/// modelling decision, not a port, and would change these counts.
///
/// DECLARED NON-DISCRIMINATING, and the mutation run is why. Every count here
/// is computed from `data.d` / `data.t`, i.e. from the FIXTURE. The data does
/// not change when the code does, so no mutation of the four-nuisance
/// computation can make this gate fail -- including M1, the one mutant that
/// actually breaks the `t in {0,1}` property. GATE 3 survived all six of them.
///
/// That is stated here rather than left for a reader to discover, because an
/// unexplained survivor is how a gate nobody understands ends up cited as
/// coverage. This gate earns its place as a fixture pin and a tripwire for a
/// future fixture change; it is NOT evidence that the cell assignment is
/// correct. The mutant that violates the cell assignment (M1) is caught by
/// GATE 7, which reads the numbers the assignment actually produces.
test "didcs_four_g_cells_are_t_in_01_and_rows_beyond_train_none" {
  let fitted = v1470_four_period_fit()
  let (c00, c01, c10, c11, other) = v1470_cells(fitted)
  assert_true(c00 == 300)
  assert_true(c01 == 200)
  assert_true(c10 == 100)
  assert_true(c11 == 200)
  assert_true(other == 800)
  assert_true(c00 + c01 + c10 + c11 + other == 1600)
}

///|
/// GATE 4. THE ADDITIVITY GATE. Stage 1b changes no reported number, same as
/// stage 1a. Tolerance is relative and set from the measured backend spread
/// (~1.5e-15, two ULP) recorded in `expand_v146_test.mbt` GATE 5 -- the did_cs
/// estimates are not bit-identical across wasm and js, so `==` was never
/// available for them.
///
/// DECLARED: survives all six mutants, by design. Nothing consumes the four
/// nuisances yet -- the reported estimates still come from each cell's child
/// `DoubleMLDIDBinary` -- so corrupting a quantity no estimator reads cannot
/// move an old estimate. That uniform survival IS the property being certified.
test "didcs_stage_1b_does_not_move_any_estimate" {
  let fitted = v1470_four_period_fit()
  // v0.150.0 RE-PINNED for the new base period; all six measured off a real run.
  // Same caveat as `expand_v146_test.mbt` GATE 5: `make_did_CS2021` sets
  // `tau_g = g - 1`, so `g` is a cohort LABEL there, not a treatment period,
  // and these are regression locks rather than ATT recoveries.
  assert_true(v1470_rel(fitted.coef_at(0, 2), 0.6790989134518333) < 1.0e-12)
  assert_true(v1470_rel(fitted.se_at(0, 2), 1.576530184609983) < 1.0e-12)
  assert_true(v1470_rel(fitted.coef_at(0, 3), 0.3152673098384928) < 1.0e-12)
  assert_true(v1470_rel(fitted.se_at(0, 3), 1.5401197678254355) < 1.0e-12)
  assert_true(v1470_rel(fitted.coef_at(1, 3), -1.2811615117010642) < 1.0e-12)
  assert_true(v1470_rel(fitted.se_at(1, 3), 1.38899147615608) < 1.0e-12)
}

///|
/// GATE 5. The canonical 2-period DIDCS panel PARTITIONS EXACTLY -- outside the
/// 2x2 is zero, so the four weights `(1-d)(1-t), (1-d)t, d(1-t), dt` sum to 1
/// on every row and `g_hat` is well defined there. That is the claim that makes
/// stage 1b an exact transcription on the design upstream actually targets.
///
/// It also pins that `(d=1, t=0)` is STRUCTURALLY EMPTY: the fixture treats its
/// cohort at t=1, so no unit is treated in the pre-period. The helper leaves
/// that nuisance at `0.0` because there is nothing to fit on. This is harmless
/// for `g_hat` -- the weight `d*(1-t)` is identically zero wherever `t = 0` --
/// but a caller reading `predictions_g_d1_t0` directly would otherwise see a
/// plausible number that means nothing. Pinning the emptiness is the point,
/// and pinning it THROUGH THE NAMED ACCESSOR is what ties the name `d1t0` to
/// the structurally empty cell rather than merely to an occupancy count.
test "didcs_four_g_partition_the_canonical_two_period_panel_exactly" {
  let fitted = v1470_two_period_fit()
  let (c00, c01, c10, c11, other) = v1470_cells(fitted)
  assert_true(other == 0)
  assert_true(c00 + c01 + c10 + c11 == fitted.predictions_m().length())
  assert_true(c00 == 400)
  assert_true(c01 == 200)
  assert_true(c10 == 0)
  assert_true(c11 == 200)
  // The name `d1t0` must reach the array that is actually all zeros.
  let empty = fitted.predictions_g_d1_t0()
  assert_true(empty.length() == fitted.predictions_m().length())
  for i = 0; i < empty.length(); i = i + 1 {
    assert_true(empty[i] == 0.0)
  }
  // ...and no other one may be empty, or the name would be meaningless.
  //
  // This asserted `v1470_mean(a) > 1.0` until v0.148.0 broke it, correctly. The
  // threshold was an absolute scale smuggled in from the DGP it happened to be
  // written against: y had mean 49.87, so "> 1.0" looked like a safe proxy for
  // "populated". The v0.148.0 fixture fix moved mean(y) to 0.085 with sd 3.28,
  // and the gate went red on a nuisance that is perfectly well populated -- a
  // false alarm, not a catch.
  //
  // The property actually wanted is scale-free: NOT IDENTICALLY ZERO. Asserting
  // that directly means the gate survives any future rescaling of the outcome,
  // which is the whole point, and it distinguishes "no data in this cell" from
  // "this cell's conditional mean happens to be small".
  for
    a in [
      fitted.predictions_g_d0_t0(),
      fitted.predictions_g_d0_t1(),
      fitted.predictions_g_d1_t1(),
    ] {
    assert_true(a.length() == empty.length())
    let mut nonzero = false
    for i = 0; i < a.length(); i = i + 1 {
      if a[i] != 0.0 {
        nonzero = true
      }
    }
    assert_true(nonzero)
  }
}

///|
/// GATE 6. An unfitted model reports all four as EMPTY rather than zeros. The
/// "absent vs zero" distinction matters more here than for `m_hat`, because a
/// zero-filled outcome nuisance is indistinguishable from a legitimately
/// predicted `E[Y|D,T,X] = 0`.
///
/// DECLARED: survives M1-M5, which none of which touch the constructor's `[]`
/// initialisation. It guards the absent/zero boundary, not the fit.
test "didcs_four_g_are_empty_before_fit" {
  let d = make_did_CS2021(1600, 3, 1.0, 3141)
  let dml = DoubleMLDIDCSData::new(
    d.x_get(),
    d.y_get(),
    d.d_get(),
    d.t_get(),
    d.id_get(),
    d.g_get(),
  )
  let unfitted = DoubleMLDIDCS::new(dml, n_folds=2)
  assert_true(unfitted.predictions_g_d0_t0().length() == 0)
  assert_true(unfitted.predictions_g_d0_t1().length() == 0)
  assert_true(unfitted.predictions_g_d1_t0().length() == 0)
  assert_true(unfitted.predictions_g_d1_t1().length() == 0)
}

///|
/// GATE 7. THE IDENTITY GATE -- one measured number per named accessor, so an
/// accessor that returned the wrong field would be caught rather than merely
/// looking plausible.
///
/// Tolerance is the minimum separation, not a guess. The four means span
/// 24.4938 / 24.9540 / 25.5576 / 26.1620, so the closest pair is 1.8% apart;
/// at 1e-12 relative any swap moves a pinned value by at least ten orders of
/// magnitude more than the tolerance and is caught, while the measured backend
/// spread for THIS quantity is 0 for three of the four and 2e-16 for the
/// fourth (see below), so nothing is loosened further than it must be.
///
/// EXACTNESS IS RESTORED WHERE IT IS AVAILABLE, per the same rule as
/// `expand_v146_test.mbt` GATE 5b. Re-measured on all four backends for
/// v0.151.0: the mean of `g_d1t1` is `0.7510479216157833` on native, wasm,
/// wasm-gc AND js -- bit for bit -- so that one is asserted with `==`. The other
/// three differ from native in the last one or two digits (worst case
/// `g_d0t0`: `...719974` on native vs `...71996` elsewhere, about 3.7e-16
/// relative) and are asserted with a tolerance.
test "didcs_four_g_accessors_each_carry_their_own_measured_mean" {
  let fitted = v1470_four_period_fit()
  assert_true(
    v1470_rel(v1470_mean(fitted.predictions_g_d0_t0()), -0.37832303330719974) <
    1.0e-12,
  )
  assert_true(
    v1470_rel(v1470_mean(fitted.predictions_g_d0_t1()), 0.07138677844604216) <
    1.0e-12,
  )
  assert_true(
    v1470_rel(v1470_mean(fitted.predictions_g_d1_t0()), 0.8106089238918825) <
    1.0e-12,
  )
  assert_true(v1470_mean(fitted.predictions_g_d1_t1()) == 0.7510479216157833)
}
