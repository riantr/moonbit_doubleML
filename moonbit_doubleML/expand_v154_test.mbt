// expand_v154_test.mbt
//
// TRIPWIRES for the `DoubleMLDIDMulti` convention defect. NO behaviour change.
//
// This file pins a KNOWN DEFECT. Every gate here passes against the current,
// defective behaviour on purpose. Its job is to make the defect impossible to
// discover twice and impossible to "fix" silently: when `expand_gt_keyword` is
// corrected, these gates FAIL, and whoever corrects it must read this header
// and change each pin deliberately.
//
// WHEN YOU FIX THIS: INVERT the pins, do not delete them. Deleting a tripwire
// is how a defect leaves no trace; inverting it records what the corrected
// behaviour is. (Same rule as the `t_pre` inertness tripwire in
// `expand_v152_test.mbt`.)

///|
/// v0.150.0 corrected `DoubleMLDIDCS` to base period `g - 1` with live cells
/// `t >= g`, which made `ATT(g, g)` estimable. `DoubleMLDIDMulti` was never
/// updated: `did_multi.mbt:242` still emits `(g, g, t)` only when `t > g`, and
/// `:246` emits `(g, g, t)` for every `t != g`.
///
/// MEASURED on the 4-period panel (`make_did_CS2021(1600, 3, 1.0, 3141)`,
/// `groups=[1,2,3]`, `times=[0,1,2,3]`):
///
///   "standard" -> 3 cells: (1,1,2) (1,1,3) (2,2,3)
///                  t_pre == g in 3/3,  t_eval == g in 0/3
///   "all"      -> 9 cells,  t_pre == g in 9/9,  t_eval == g in 0/9
///
/// Under the corrected convention (base `g - 1`, live `t >= g`) "standard"
/// would yield SIX cells: (1,0,1) (1,0,2) (1,0,3) (2,1,2) (2,1,3) (3,2,3).
/// The three it is missing -- (1,0,1), (2,1,2), (3,2,3) -- are exactly the
/// `ATT(g, g)` cells v0.150.0 made estimable in DIDCS. DIDMulti cannot reach
/// any of them.
///
/// Note the combination counts are also why a fix is not a one-liner: several
/// existing tests pin 3 / 300 / `live[0..2]` and would need re-pinning.

///|
/// GATE 1. "standard" on the 4-period panel excludes every `t_eval == g` cell,
/// including the three `ATT(g, g)` cells DIDCS can now estimate.
///
/// INVERT ON FIX: `t_eval == g` should be 3 of 6, not 0 of 3.
test "v1540_didmulti_standard_excludes_the_att_g_g_cells" {
  let d = make_did_CS2021(1600, 3, 1.0, 3141)
  let m = DoubleMLDIDMulti::new(
    DoubleMLDIDCSData::new(
      d.x_get(),
      d.y_get(),
      d.d_get(),
      d.t_get(),
      d.id_get(),
      d.g_get(),
    ),
    gt_combinations_keyword="standard",
    n_folds=2,
    seed=3141,
  )
  assert_true(m.n_combinations() == 3)
  let mut t_eval_eq_g = 0
  let mut t_pre_eq_g = 0
  for i = 0; i < m.n_combinations(); i = i + 1 {
    let (g, t_pre, t_eval) = m.gt_combinations[i]
    if t_eval == g {
      t_eval_eq_g = t_eval_eq_g + 1
    }
    if t_pre == g {
      t_pre_eq_g = t_pre_eq_g + 1
    }
  }
  // The `t == g` cells are exactly what is missing.
  assert_true(t_eval_eq_g == 0)
  // And `t_pre` is the hardcoded baseline, not `g - 1`.
  assert_true(t_pre_eq_g == 3)
}

///|
/// GATE 2. "all" has the same two properties, so a fix to "standard" that
/// leaves "all" untouched would be caught here.
///
/// INVERT ON FIX: 12 cells, `t_eval == g` in 3 of 12, `t_pre == g` in 0.
test "v1540_didmulti_all_also_hardcodes_t_pre_to_g" {
  let d = make_did_CS2021(1600, 3, 1.0, 3141)
  let m = DoubleMLDIDMulti::new(
    DoubleMLDIDCSData::new(
      d.x_get(),
      d.y_get(),
      d.d_get(),
      d.t_get(),
      d.id_get(),
      d.g_get(),
    ),
    gt_combinations_keyword="all",
    n_folds=2,
    seed=3141,
  )
  assert_true(m.n_combinations() == 9)
  let mut t_eval_eq_g = 0
  let mut t_pre_eq_g = 0
  for i = 0; i < m.n_combinations(); i = i + 1 {
    let (g, t_pre, t_eval) = m.gt_combinations[i]
    if t_eval == g {
      t_eval_eq_g = t_eval_eq_g + 1
    }
    if t_pre == g {
      t_pre_eq_g = t_pre_eq_g + 1
    }
  }
  assert_true(t_eval_eq_g == 0)
  assert_true(t_pre_eq_g == 9)
}

///|
/// GATE 3. THE SHARPEST FORM. On a 2-period panel, `DoubleMLDIDMulti` cannot
/// produce a post-treatment ATT AT ALL.
///
/// MEASURED on `make_did_cs_CS2021(800, 3, 1.0, 3141)` (`groups=[1]`,
/// `times=[0,1]`):
///   "standard" -> 0 cells, and `require(resolved.length() > 0)` at
///                  `did_multi.mbt:117` ABORTS. Not catchable: MoonBit's
///                  `require` calls `abort`, it does not raise.
///   "all"      -> exactly 1 cell, `(1, 1, 0)` -- which is a PRE-TREATMENT
///                  PLACEBO (`t_eval = 0 < t_pre = 1`), not an effect.
///
/// So the one keyword meant to select post-treatment cells returns nothing and
/// kills the process, and the one that returns something returns a placebo.
/// The corrected convention would yield `(1, 0, 1)` -- the real ATT(1, 1),
/// which is precisely the cell v0.150.0 made estimable in DIDCS.
///
/// This gate deliberately does NOT invoke "standard": doing so would abort the
/// whole test binary and take every other gate in the package down with it.
/// INVERT ON FIX: "standard" must construct successfully and yield `(1, 0, 1)`.
test "v1540_didmulti_cannot_reach_any_post_treatment_att_on_two_periods" {
  let d = make_did_cs_CS2021(800, 3, 1.0, 3141)
  let m = DoubleMLDIDMulti::new(
    DoubleMLDIDCSData::new(
      d.x_get(),
      d.y_get(),
      d.d_get(),
      d.t_get(),
      d.id_get(),
      d.g_get(),
    ),
    gt_combinations_keyword="all",
    n_folds=2,
    seed=3141,
  )
  assert_true(m.n_combinations() == 1)
  let (g, t_pre, t_eval) = m.gt_combinations[0]
  assert_true(g == 1 && t_pre == 1 && t_eval == 0)
  // A placebo, not an effect: the base period is AFTER the evaluation period.
  assert_true(t_eval < t_pre)
}
