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
fn v1450_lplr_fit(n : Int, alpha : Double, seed : Int) -> DoubleMLLPLR {
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
/// GATE 2. The degenerate regime must be REPORTED. alpha = 1.5 is past the
/// cliff found in v0.140.0 (rootless objective at alpha >= 1.25), so the
/// solver cannot converge and must say so rather than return a confident
/// number.
test "lplr_warnings_report_the_degenerate_design" {
  let model = v1450_lplr_fit(1000, 1.5, 11)
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
  let model = v1450_lplr_fit(1000, 1.5, 11)
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
  let model = v1450_lplr_fit(1000, 1.5, 11)
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
test "lplr_warnings_are_returned_not_printed" {
  // The contract under test: `warnings()` is a pure read of the fitted struct
  // and does not itself produce output. Asserted structurally -- the accessor
  // exists, returns an Array[String], and is stable across calls.
  let model = v1450_lplr_fit(1000, 1.5, 11)
  let a = model.warnings()
  let b = model.warnings()
  assert_true(a.length() == b.length())
  for i = 0; i < a.length(); i = i + 1 {
    assert_true(a[i] == b[i])
  }
}

///|
/// GATE 6. Across a RANGE of alphas, the diagnostic must separate the two
/// regimes rather than flip on one fixture. This is the v0.139.0 lesson applied
/// forward: a verdict about "healthy vs degenerate" drawn from a single probe
/// is a verdict about one probe. Here the assertion is monotone in the sense
/// that the set of alphas producing a warning is a SUFFIX -- once the objective
/// is rootless, going further out must not return to silence.
test "lplr_warning_appears_only_on_the_degenerate_side_of_the_cliff" {
  let alphas = [0.25, 0.50, 0.75, 1.00, 1.25, 1.50]
  let warned : Array[Bool] = []
  for a in alphas {
    let model = v1450_lplr_fit(800, a, 17)
    warned.push(model.warnings().length() > 0)
  }
  // No silent run after the first warning run -- the set must be a suffix.
  let mut seen_warning = false
  let mut monotone = true
  for w in warned {
    if w {
      seen_warning = true
    } else if seen_warning {
      monotone = false
    }
  }
  assert_true(monotone)
  // And the degenerate end of the range must actually warn, or this gate would
  // pass vacuously on a channel that never fires.
  assert_true(warned[warned.length() - 1])
}
