// expand_v152_test.mbt
//
// v0.152.0 -- the RECOVERY TOLERANCE, and the `t_pre` defect it exposed.
//
// `dgp_recovery_test.mbt`'s band was `max_abs_err < 5.0`, an absolute number
// inherited from before v0.150.0 and never examined. It had two problems at
// once, and measurement is the only thing that shows both.
//
// Measured across 12 seeds on make_did_cs_CS2021(800, 3, 1.0, seed):
//
//   max |att - 1.0| = 14.41      <- the band `< 5.0` FAILS on seeds 7, 77, 314
//   max |att - 1.0| / se = 2.41  <- in SE units the error IS bounded
//   se range 0.589 .. 8.837
//
// So `5.0` was simultaneously too loose (at the tested seed it permits 2.9x the
// error the estimator actually makes) and too tight (it rejects a quarter of
// the seeds). The error is large precisely when the SE is large -- which is what
// a correctly-scaled robust SE is for -- so the honest band is in SE units.

///|
fn v1520_fit(seed : Int) -> DoubleMLDIDCS {
  let d = make_did_cs_CS2021(800, 3, 1.0, seed)
  DoubleMLDIDCS::new(
    DoubleMLDIDCSData::new(
      d.x_get(),
      d.y_get(),
      d.d_get(),
      d.t_get(),
      d.id_get(),
      d.g_get(),
    ),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
}

///|
/// GATE 1. Recovery holds in SE units across a seed sweep. This is the property
/// that makes an SE-relative band meaningful rather than decorative: without it,
/// `|att - 1| < 5 * se` would be a number with nothing behind it.
///
/// Three seeds, chosen because they span the range measured above rather than
/// because they happen to pass: 3141 (the canonical seed, err 1.7275 / z 0.889),
/// 7 (err 9.0879 / z 1.367, the widest absolute error) and 314 (err 5.5136 /
/// z 0.802, which is what breaks the OLD band).
test "v1520_recovery_holds_in_se_units_across_seeds" {
  let seeds : Array[Int] = [3141, 7, 314]
  for s in seeds {
    let f = v1520_fit(s)
    let att = f.coef_at(0, 1)
    let se = f.se_at(0, 1)
    assert_true(se > 0.0)
    let z = (att - 1.0).abs() / se
    assert_true(z < 5.0)
  }
}

///|
/// GATE 2. THE OLD BAND WAS UNSOUND, pinned so the change cannot be quietly
/// reverted on the grounds that `5.0` was "always fine".
///
/// At seed 314 the estimate is 6.5136 against a true 1.0: an absolute error of
/// **5.5136**, which `max_abs_err < 5.0` REJECTS -- and that is a legitimate
/// estimate, since its SE is 6.8728 (z = 0.802). The band was not conservative,
/// it was arbitrary, and it happened to be violated by a correct answer.
test "v1520_the_old_absolute_band_would_have_failed" {
  let f = v1520_fit(314)
  let att = f.coef_at(0, 1)
  let se = f.se_at(0, 1)
  let err = (att - 1.0).abs()
  // It is a legitimately small z -- this is not a broken estimate.
  assert_true(err / se < 1.0)
  // And yet it exceeds the band that was in force until this release.
  assert_true(err > 5.0)
}

///|
/// GATE 3. Exact regression lock on the canonical cell, at 1e-12 relative
/// because the did_cs quantities carry the known ~1.5e-15 cross-backend spread
/// and were never available for `==` (the same reason `expand_v146_test.mbt`
/// GATE 5 uses a tolerance).
test "v1520_canonical_cell_is_pinned" {
  let f = v1520_fit(3141)
  let rel = fn(got : Double, want : Double) { (got - want).abs() / want.abs() }
  assert_true(rel(f.coef_at(0, 1), 2.727522673844541) < 1.0e-12)
  assert_true(rel(f.se_at(0, 1), 1.9428873717680928) < 1.0e-12)
}

///|
/// GATE 4. **`t_pre` IS INERT -- A DECLARED DEFECT, AND A TRIPWIRE.**
///
/// `DoubleMLDIDMulti`'s public API takes `(g, t_pre, t_eval)` triples and
/// promises control of the base period. It does not deliver one: `coef_at_idx`
/// calls `ignore(t_pre)` and the inner `DoubleMLDIDCS` derives its base period
/// as `g - 1`. Asking for two DIFFERENT base periods returns the IDENTICAL
/// coefficient -- measured below, bit for bit.
///
/// WHY THIS IS PINNED AS A PASSING TEST RATHER THAN LEFT AS A COMMENT: the
/// consequence is that `make_did_CS2021` cannot validate DIDMulti at all. That
/// DGP treats cohort `g` at `tau_g = g - 1`, so the inferred base `g - 1` is
/// the FIRST TREATED period -- contaminated -- and the coefficients come out
/// 1.4166 / 0.6791 / 0.3153 / -2.3785 / -1.2812 / -10.5035 against a true theta
/// of 1.0. Writing a recovery test on those numbers would enshrine the bug, so
/// none exists; the class most obviously associated with this DGP therefore has
/// no recovery coverage, and its misleadingly-named test was renamed in this
/// release rather than left claiming coverage it did not have.
///
/// **THIS GATE WILL FAIL THE MOMENT `t_pre` IS HONOURED. That is correct and
/// intended.** When the fix lands, invert this assertion rather than deleting
/// it: the new assertion is that two different base periods give DIFFERENT
/// coefficients, which is the property the API has always advertised.
test "v1520_didmulti_t_pre_is_inert_declared_defect" {
  let data = make_did_CS2021(1600, 3, 1.0, 3141)
  let mk = fn(combos : Array[(Int, Int, Int)]) -> Double {
    DoubleMLDIDMulti::new(
      DoubleMLDIDCSData::new(
        data.x_get(),
        data.y_get(),
        data.d_get(),
        data.t_get(),
        data.id_get(),
        data.g_get(),
      ),
      gt_combinations=combos,
      n_folds=2,
      n_rep=1,
      seed=3141,
    )
    .fit()
    .coef_at_idx(0)
  }
  let base0 = mk([(1, 0, 2)])
  let base1 = mk([(1, 1, 2)])
  // Identical to the last digit: the base period has no effect whatsoever.
  // `==` IS correct here and must not be loosened -- both values were computed
  // on the SAME backend, so a difference would mean the base period actually
  // mattered, not that the platform disagrees. That is the property.
  assert_true(base0 == base1)
  // The value itself, at 1e-12 relative. NOT `==`: this literal is the native
  // value, and the did_cs coefficients carry the known ~1.5e-15 cross-backend
  // spread. Caught by running all four targets -- native passed and wasm and
  // wasm-gc both failed this line, the same signature as the v0.150.0 pin.
  let rel = fn(got : Double, want : Double) { (got - want).abs() / want.abs() }
  assert_true(rel(base0, 0.6790989134518333) < 1.0e-12)
}
