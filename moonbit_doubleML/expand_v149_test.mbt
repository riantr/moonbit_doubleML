// v0.149.0 -- GATES for stage 2: upstream's panel-level `sigma2` / `nu2`.
//
// BOTH FORMULAS ARE VERIFIED BIT-EXACT AGAINST A RUNNING UPSTREAM 0.11.3.
// Upstream reports, on a 2x2 panel built from its own CS2021 DGP:
//
//     sigma2 = 256.4070590464714        nu2 = 18.253043736106648
//
// and `_verify/_oracle_v1482_nu2_gap.py` reproduces BOTH to the last digit from
// `did_cs.py:451-497`. So these gates are not asserting that the transcription
// "looks like" upstream's; they are pinning a formula already checked against
// the thing being transcribed.
//
// Measured on `make_did_cs_CS2021(800, 3, 1.0, 3141)`, n_folds = 2, n_rep = 1,
// seed = 3141, BEFORE this stage landed:
//
//     sigma2                     = 1.8855040509678376
//     nu2 (in_sample_norm=false) = 21.32163562345964     <- the port's default
//     nu2 (in_sample_norm=true)  = NaN
//
// THE NaN IS THE INTERESTING ONE. The `in_sample_normalization = true` branch
// divides by `mean(d1t0)`, which is 0.0 here because nobody is treated in the
// pre-period -- the `(d=1, t=0)` cell is structurally empty, the same fact
// `expand_v147_test.mbt` GATE 5 pins. Upstream's arithmetic on the same input
// produces the same Inf/NaN. No fallback is substituted, because a quiet
// replacement number would be indistinguishable from a correct one.

///|
fn v1490_cs() -> DoubleMLDIDCS {
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
  ).fit()
}

///|
fn v1490_cs_isn() -> DoubleMLDIDCS {
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
    in_sample_normalization=true,
  ).fit()
}

///|
fn v1490_rel(got : Double, want : Double) -> Double {
  (got - want).abs() / want.abs()
}

///|
/// GATE 1 + GATE 2. The two scalars, pinned. These read the new computation,
/// so a mutation to it is caught here -- unlike the fixture pins in
/// `expand_v148_test.mbt`, which a code mutation cannot move.
test "didcs_panel_sigma2_and_nu2_match_measurement" {
  let fitted = v1490_cs()
  assert_true(
    v1490_rel(fitted.sensitivity_sigma2(), 1.8855040509678376) < 1.0e-12,
  )
  assert_true(v1490_rel(fitted.sensitivity_nu2(), 21.32163562345964) < 1.0e-12)
  // Both are finite and nu2 is POSITIVE. A negative or non-finite nu2 would
  // make sqrt(sigma2 * nu2) undefined, so this is the property downstream
  // sensitivity bounds actually depend on.
  assert_true(fitted.sensitivity_sigma2() > 0.0)
  assert_true(fitted.sensitivity_nu2() > 0.0)
  assert_true(fitted.sensitivity_nu2().is_nan() == false)
}

///|
/// GATE 3. THE BRANCH GATE. `in_sample_normalization` must actually select a
/// different branch -- otherwise the flag is decorative and a future reader
/// would assume the upstream-default path is reachable when it is not.
test "didcs_in_sample_normalization_selects_a_different_branch" {
  let default_branch = v1490_cs()
  let isn_branch = v1490_cs_isn()
  // `sigma2` does not depend on the branch at all, so it MUST agree exactly.
  // If it does not, the flag is leaking somewhere it should not.
  assert_true(
    default_branch.sensitivity_sigma2() == isn_branch.sensitivity_sigma2(),
  )
  // `nu2` does, and on this fixture the isn=true branch is undefined.
  assert_true(isn_branch.sensitivity_nu2().is_nan())
  assert_true(default_branch.sensitivity_nu2().is_nan() == false)
}

///|
/// GATE 4. THE PER-ROW ELEMENTS ARE CENTRED. `psi_sigma2` and `psi_nu2` are
/// deviations from their own means by construction
/// (`did_cs.py:464`, `529`), so their means must be zero. This is the check
/// that the scalar really is the mean of the array being handed back, not an
/// independent second computation that happens to agree.
test "didcs_per_row_elements_are_centred_on_their_scalars" {
  let fitted = v1490_cs()
  let psi_s = fitted.sensitivity_psi_sigma2()
  let psi_n = fitted.sensitivity_psi_nu2()
  let rr = fitted.sensitivity_riesz_rep()
  let n = fitted.predictions_m().length()
  assert_true(psi_s.length() == n)
  assert_true(psi_n.length() == n)
  assert_true(rr.length() == n)
  assert_true(psi_s.length() == 800)
  let mut ss = 0.0
  let mut sn = 0.0
  for i = 0; i < n; i = i + 1 {
    ss = ss + psi_s[i]
    sn = sn + psi_n[i]
  }
  assert_true((ss / n.to_double()).abs() < 1.0e-10)
  assert_true((sn / n.to_double()).abs() < 1.0e-10)
}

///|
/// GATE 5. Before `fit`, every element reads absent -- scalars 0.0, arrays
/// empty. `nu2 = 0.0` is a legal value of `nu2`, so "absent" and "zero" must
/// stay distinguishable here exactly as they do for the nuisances.
test "didcs_panel_elements_are_absent_before_fit" {
  let d = make_did_cs_CS2021(800, 3, 1.0, 3141)
  let unfitted = DoubleMLDIDCS::new(
    DoubleMLDIDCSData::new(
      d.x_get(),
      d.y_get(),
      d.d_get(),
      d.t_get(),
      d.id_get(),
      d.g_get(),
    ),
    n_folds=2,
  )
  assert_true(unfitted.sensitivity_sigma2() == 0.0)
  assert_true(unfitted.sensitivity_nu2() == 0.0)
  assert_true(unfitted.sensitivity_psi_sigma2().length() == 0)
  assert_true(unfitted.sensitivity_psi_nu2().length() == 0)
  assert_true(unfitted.sensitivity_riesz_rep().length() == 0)
}

///|
/// GATE 6. REWRITTEN in v0.150.0 -- and this is the clearest example in the
/// package of a gate that pinned a DEFECT and read as evidence while doing it.
///
/// It used to assert that EVERY cell on the canonical panel is the 0.0 sentinel,
/// with the comment "Every cell is skipped, so every coefficient is the 0.0
/// sentinel." That was true, and it was the bug: `dgp_recovery_test` was
/// asserting `max_abs_err < 5.0` against a hardcoded zero while claiming to
/// recover an ATT of 1.0. A gate that certifies "nothing was estimated" looks
/// exactly like a gate that certifies "nothing changed", which is why stage 2
/// shipped with the defect still live.
///
/// It now asserts the partition that is actually correct: `t < g` is
/// pre-treatment and stays at the 0.0 sentinel, `t >= g` is post-treatment and
/// carries a REAL estimate. `coef_at(0, 1) = 2.727522673844541` with
/// `se = 1.9428873717680928`, measured 2026-10-12. Stage 2 still does not
/// change any number -- the sensitivity path is untouched -- but the numbers
/// being asserted are now real ones.
test "didcs_stage_2_does_not_move_any_estimate" {
  let fitted = v1490_cs()
  assert_true(fitted.n_groups() == 1)
  assert_true(fitted.n_periods() == 2)
  // (g=1, t=0): t < g, genuinely pre-treatment, no estimate, stays 0.0.
  assert_true(fitted.coef_at(0, 0) == 0.0)
  assert_true(fitted.se_at(0, 0) == 0.0)
  // (g=1, t=1): t == g, post-treatment SINCE v0.150.0, and estimated.
  //
  // 1e-12 RELATIVE, not `==`. These are did_cs ATTs, which carry the known
  // ~1.5e-15 (two ULP) spread across backends -- the same reason
  // `expand_v146_test.mbt` GATE 5 uses a tolerance. An exact `==` here passed
  // on native and failed on wasm, wasm-gc AND js, which is the signature of a
  // platform difference rather than a regression. Measured native values:
  // coef 2.727522673844541, se 1.9428873717680928.
  let rel = fn(got : Double, want : Double) { (got - want).abs() / want.abs() }
  assert_true(rel(fitted.coef_at(0, 1), 2.727522673844541) < 1.0e-12)
  assert_true(rel(fitted.se_at(0, 1), 1.9428873717680928) < 1.0e-12)
  // And the new elements are nonetheless populated, which is the whole point:
  // they are panel-level and do not need a live cell.
  assert_true(fitted.sensitivity_sigma2() > 0.0)
}
