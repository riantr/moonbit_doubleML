// v0.145.0 -- GATES for the LPLR non-convergence diagnostic.
//
// WHAT THIS GUARDS. `fit` used to end its damped-Newton loop with
// `let _ = converged`, discarding the flag, and then compute `coef` and `se` at
// whatever iterate the solver happened to stop on. A standard error that is
// computed at a non-solution does not look wrong: `se = sqrt(gamma/(j^2*n))`
// with `j = mean(psi_deriv)`, so moving away from the root can make the
// reported SE *smaller*. The failure therefore had to be made observable, and
// the gates below are the observable.
//
// THE FIXTURE is the package's own `make_lplr_LZZ2020` (p = 6, nonlinear r,
// known true coefficient), NOT a hand-built one. v0.140.0's lesson: a
// self-made fixture reported LPLR instrument coefficients of -51451 and
// +128068, and "both learners fail on a bad fixture" is the normal case rather
// than a finding.
//
// Two alphas bracket the measured cliff from v0.140.0, where the degenerate
// regime begins at alpha >= 1.25. Per that release's 2xN survival table, the
// verdict was drawn across several alphas rather than from one probe.

///|
fn v1450_lplr_fit(n : Int32, alpha : Double, seed : Int32) -> DoubleMLLPLR {
  let dgp = make_lplr_LZZ2020(n, alpha, seed)
  DoubleMLLPLR::new(dgp.data_get(), n_folds=2, n_folds_inner=2, seed~).fit()
}

///|
/// GATE 1. The healthy regime must stay SILENT. This is the control that makes
/// the diagnostic meaningful: a warning channel that fires everywhere is no
/// better than no warning channel, and it would also make GATE 2 pass for the
/// wrong reason.
///
/// Declared explicitly: this gate is SUPPOSED TO SURVIVE the regression it
/// looks like it guards. It asserts that the diagnostic does not misfire, not
/// that the solver works. If someone later breaks the solver so that healthy
/// designs start warning, this goes red -- correctly, because the channel has
/// become noise.
test "lplr_warnings_silent_on_a_healthy_design" {
  let model = v1450_lplr_fit(1000, 0.25, 11)
  let w = model.warnings()
  assert_true(w.length() == 0)
}

///|
/// GATE 2. The degenerate regime must be REPORTED. It must say so rather than
/// return a confident number.
///
/// v0.163.0: RE-BASED from `(1000, 1.5, 11)` to `(200, 1.5, 11)`, and the
/// reason is measured, not asserted. The old fixture asserted that the
/// objective goes rootless at `alpha >= 1.25` (v0.140.0). D2 gives `W_inner`
/// the INNER cross-fit of ml_M -- upstream's `M_hat["preds_inner"][i][train]`
/// at `plm/lplr.py:318` -- and that removes the alpha cliff: over a
/// 3 x 4 x 2 grid of n in {200,400,800,1000} x alpha in {0.25,1,1.5,2.5} x
/// seed in {11,17}, every n >= 800 cell is silent on both score names, and
/// the only cells that warn are n = 200 and one n = 400 cell. The warning
/// region became a SMALL-SAMPLE phenomenon, which is what a
/// non-convergence diagnostic should actually track.
///
/// So the guarantee is preserved on a fixture that still exercises it. What
/// is deliberately NOT claimed any more is "alpha = 1.5 is past the cliff" --
/// see GATE 6, whose alpha-suffix invariant died with that cliff.
test "lplr_warnings_report_the_degenerate_design" {
  let model = v1450_lplr_fit(200, 1.5, 11)
  let w = model.warnings()
  assert_true(w.length() > 0)
  // The warning must NAME THE REPETITION, so a caller running n_rep > 1 can
  // tell which draw produced the bad coefficient.
  assert_true(w[0].contains("rep 0"))
}

///|
/// GATE 3. The warning must carry the REASON, not just "it failed". The three
/// exits are different problems, and a bare flag is exactly what the old
/// `let _ = converged` was. This asserts the text distinguishes them by
/// requiring one of the three documented reasons to be present -- which fails
/// if someone reduces the message to a constant string.
test "lplr_warning_names_a_documented_stop_reason" {
  let model = v1450_lplr_fit(200, 1.5, 11)
  let w = model.warnings()
  assert_true(w.length() > 0)
  let known = ["degenerate_derivative", "diverged", "exhausted_step_budget"]
  let mut named = false
  for k in known {
    if w[0].contains(k) {
      named = true
    }
  }
  assert_true(named)
}

///|
/// GATE 4. The warning must say the reported numbers are not an estimate.
/// A caller reading only `coef()` has to be able to find out that it is
/// looking at a non-solution. This is the assertion that the diagnostic is
/// about MEANING and not merely about a boolean.
test "lplr_warning_states_the_numbers_are_not_a_solution" {
  let model = v1450_lplr_fit(200, 1.5, 11)
  let w = model.warnings()
  assert_true(w.length() > 0)
  assert_true(w[0].contains("not a solution"))
}

///|
/// GATE 5. The failure is still SILENT to the process. This package has no
/// output channel by design, and the convention v0.145.0 introduces is that
/// warnings are RETURNED, never printed. A gate that pins the library's silence
/// is what stops a later "let me just println it" from quietly reintroducing
/// unreadable test output for every downstream consumer.
///
/// v0.163.0: this gate was VACUOUS and stayed green through the D2 change,
/// which is how the change got past it in the first place. It compared
/// `model.warnings()` against itself, so it holds with equal ease on a
/// channel that returns nothing at all -- and `(1000, 1.5, 11)` had just
/// become exactly such a channel. It now asserts the fixture actually
/// produces a warning before asserting that reading it twice is stable,
/// so it cannot pass on an empty channel.
test "lplr_warnings_are_returned_not_printed" {
  // The contract under test: `warnings()` is a pure read of the fitted struct
  // and does not itself produce output. Asserted structurally -- the accessor
  // exists, returns an Array[String], and is stable across calls -- and
  // NON-TRIVIALLY, on a fixture that does warn.
  let model = v1450_lplr_fit(200, 1.5, 11)
  let a = model.warnings()
  let b = model.warnings()
  assert_true(a.length() > 0)
  assert_true(a.length() == b.length())
  for i = 0; i < a.length(); i = i + 1 {
    assert_true(a[i] == b[i])
  }
}

///|
/// GATE 6. REPLACED in v0.163.0. The old gate asserted that across a range of
/// alphas the set of warning-producing alphas is a SUFFIX, read off
/// `(800, alpha, 17)`. D2 removes the alpha cliff that invariant described,
/// and it does so completely: run unchanged, that sweep is
/// `[0.25, 0.5, 0.75, 1.0, 1.25, 1.5] -> [0, 0, 0, 0, 0, 0]`, i.e. the
/// invariant now holds VACUOUSLY -- monotone, yes, but with no warning
/// anywhere in it, which is why the old guard's `assert_true(warned[last])`
/// is what caught this rather than the monotonicity itself.
///
/// Keeping a monotonicity assertion that any all-zero sweep satisfies would be
/// exactly the "gate that cannot fail" this audit has been removing, so the
/// invariant is restated on the axis the measured region actually runs along:
/// SAMPLE SIZE. At fixed alpha and seed, small n warns and large n does not,
/// and both ends are asserted -- a suffix-style assertion that passes only
/// when the channel really is live at the small end and really is quiet at
/// the large end.
test "lplr_warning_tracks_sample_size_not_alpha" {
  let ns = [200, 400, 800, 1000]
  let warned : Array[Bool] = []
  for n in ns {
    let model = v1450_lplr_fit(n, 1.5, 11)
    warned.push(model.warnings().length() > 0)
  }
  // The small end must warn, or this gate would pass on a dead channel.
  assert_true(warned[0])
  // The large end must be silent: D2's whole point is that a well-powered
  // design at alpha = 1.5 no longer needs the warning.
  assert_true(!warned[warned.length() - 1])
  // And the channel must not come back at the large end -- once quiet, it
  // stays quiet as n grows.
  let mut seen_quiet = false
  let mut monotone = true
  for w in warned {
    if !w {
      seen_quiet = true
    } else if seen_quiet {
      monotone = false
    }
  }
  assert_true(monotone)
}
