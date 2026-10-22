// expand_v154b_test.mbt
//
// TRIPWIRES for the MULTI-PERIOD SENSITIVITY-ELEMENT defect. NO behaviour change.
//
// This file pins a KNOWN CORRECTNESS DEFECT. Every gate here PASSES against the
// current, defective behaviour on purpose. Its job is to make the defect
// impossible to discover twice and impossible to "fix" silently.
//
// WHEN YOU FIX THIS: INVERT the pins, do not delete them. See the note at the
// bottom of each gate for what the corrected assertion should be.
//
// ---------------------------------------------------------------------------
// THE DEFECT
//
// `cond_d0_t0` (`did_cs.mbt:1336-1348`) builds the four g-function condition
// masks hardcoded to period labels 0 and 1:
//
//     let ti = self.data.t[i]
//     if ti == 0 { ... cond_d0_t0 / cond_d1_t0 }
//     else if ti == 1 { ... cond_d0_t1 / cond_d1_t1 }
//     // ti >= 2 falls through and is DISCARDED
//
// and `let ti = self.data.t[i].to_double()` (`did_cs.mbt:1428`) then uses
// `t[i]` as a 0/1 post-treatment INDICATOR:
//
//     let ti = self.data.t[i].to_double()
//     let c = di * (1.0 - ti)          // negative when ti > 1
//     _s10 += c   ->   _m10 = mean(d * (1 - t))
//
// On a 2-period panel the period labels happen to be [0, 1], so both are exact.
// On a multi-period panel the code is structurally inapplicable: half the panel
// is dropped from all four g-functions, and the survivors carry a malformed
// indicator.
//
// MEASURED. Accumulating the same sums directly from `d` and `t` (no fitting):
//
//   panel      t range   _m11     _m10     1/_m11   1/_m10
//   4-period   [0, 3]    1.0625   -0.5     0.9412   -2
//   2-period   [0, 1]    0.25     0        4        Infinity
//
// The v0.147.0 census corroborates the discard independently: occupancy
// 300 / 200 / 100 / 200 = 800 of a 1600-row panel, i.e. exactly half the rows
// are used. Those 800 are the periods 0-1 rows; periods 2-3 are dropped.
//
// CONSEQUENCE: `DoubleMLDIDCS` reports `sigma2` and `nu2` on a multi-period
// panel that are computed from half the rows with a malformed indicator.
// `sigma2` feeds the sensitivity interval, so this is a wrong number for any
// staggered-adoption user -- not a tuning default.

///|
fn v154b_cs4(isn : Bool) -> DoubleMLDIDCS {
  let d = make_did_CS2021(1600, 3, 1.0, 3141)
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
    in_sample_normalization=isn,
  ).fit()
}

///|
fn v154b_cs2(isn : Bool) -> DoubleMLDIDCS {
  let d = make_did_cs_CS2021(800, 3, 1.0, 3141)
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
    in_sample_normalization=isn,
  ).fit()
}

///|
/// GATE 1. On the 2-period panel the upstream branch yields NaN, because
/// `_m10 = 0` (the `(d=1, t=0)` cell is empty) and `1/_m10 = Infinity`.
///
/// INVERT ON FIX: `nu2` must be finite under `in_sample_normalization = true`.
test "v154b_upstream_branch_is_nan_on_two_period_panel" {
  let nu = v154b_cs2(true).sensitivity_nu2()
  // The canonical NaN test: a value is NaN iff it does not equal itself.
  assert_true(nu != nu)
}

///|
/// GATE 2. On the 4-period panel the same branch yields a large NEGATIVE
/// value, because `_m10 = -0.5` puts a negative denominator where a positive
/// frequency was assumed.
///
/// INVERT ON FIX: `nu2` must be positive and O(1), not ~ -1e5.
test "v154b_upstream_branch_is_large_and_negative_on_four_period_panel" {
  let nu = v154b_cs4(true).sensitivity_nu2()
  assert_true(nu < 0.0)
  assert_true(nu.abs() > 100000.0)
}

///|
/// GATE 3. The exact -112652.994 value, so a regression that changes the
/// magnitude silently is visible. Relative 1e-9 rather than `==` because the
/// did_cs quantities carry the known ~1.5e-15 cross-backend spread.
test "v154b_four_period_nu2_has_a_pinned_signature_value" {
  let nu = v154b_cs4(true).sensitivity_nu2()
  assert_true((nu + 112652.99406321559).abs() / 112652.99406321559 <= 1.0e-9)
}

///|
/// GATE 4. The defect is in the SENSITIVITY path, not the estimator. The ATT
/// on the same 4-period panel is finite and close to the true 1.0, so this
/// cannot be waved off as "the whole fit is broken".
///
/// This also matters for scoping: it is why a restriction to 2-period panels
/// for the sensitivity elements is a small, non-behavioural change, while the
/// ATT path needs no work at all.
test "v154b_the_att_path_is_unaffected_on_four_period_panel" {
  let f = v154b_cs4(false)
  let att = f.coef_at(0, 1)
  assert_true(att == att) // finite
  assert_true((att - 1.0).abs() < 1.0)
}

///|
/// GATE 5. WHY THE `in_sample_normalization` CONTRAST CANNOT VALIDATE `sigma2`.
///
/// `sigma2` is identical under both branches on both panels -- it does not read
/// the flag. So "the two arms agree" is NOT evidence that `sigma2` is correct:
/// on the 4-period panel it is computed from the same discarded rows and the
/// same malformed indicator, and the contrast is simply blind to it.
///
/// INVERT ON FIX: if `sigma2` is ever made period-aware, this gate should be
/// replaced by one asserting the two arms DIFFER.
test "v154b_sigma2_cannot_be_validated_by_the_isn_contrast" {
  let a = v154b_cs4(false).sensitivity_sigma2()
  let b = v154b_cs4(true).sensitivity_sigma2()
  assert_true((a - b).abs() <= 1.0e-12)
  let c = v154b_cs2(false).sensitivity_sigma2()
  let d = v154b_cs2(true).sensitivity_sigma2()
  assert_true((c - d).abs() <= 1.0e-12)
}
