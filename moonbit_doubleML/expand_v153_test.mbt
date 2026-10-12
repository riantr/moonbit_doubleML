// expand_v153_test.mbt
//
// v0.153.0 -- LEARNER OBSERVABILITY for the three DID estimators that had none.
//
// `DoubleMLDIDCS`, `DoubleMLDIDCSBinary` and `DoubleMLDIDBinary` took no
// `ml_g` / `ml_m` parameter at all. The learners existed only as `::fit`
// arguments defaulting to OLS on every call -- never stored on the struct,
// never exposed. So a fitted estimator could not report which learners
// produced it, and a constructor-level audit of learner defaults was
// structurally blind to exactly these three.
//
// That made them the odd ones out. Measured across the package: ten
// estimators both store AND expose their learners; four store without
// exposing (BLP, DID, IIVM, SSM); these three did neither.
//
// This release gives all three a constructor parameter, a struct field, and
// `learner_g()` / `learner_m()` accessors, and points `fit`'s defaults at
// the stored pair. The default VALUES are unchanged (OLS for both), so every
// existing call site produces an identical fit -- GATE 4 is the lock on that.
//
// Method note: every comparison below names BOTH arms explicitly. The
// v0.136.0 mechanism probe compared a value against "the default" and ended
// up comparing a value with itself; a gate in that shape cannot fail, so it
// is not evidence. Comparing `new(ml_m = logistic)` against
// `new(ml_m = linear)` is a real contrast.

///|
fn v1530_data() -> DoubleMLDIDCSData {
  let d = make_did_cs_CS2021(800, 3, 1.0, 3141)
  DoubleMLDIDCSData::new(
    d.x_get(),
    d.y_get(),
    d.d_get(),
    d.t_get(),
    d.id_get(),
    d.g_get(),
  )
}

///|
fn v1530_ols() -> LearnerDispatch {
  LearnerDispatch::linear_regression()
}

///|
fn v1530_logistic() -> LearnerDispatch {
  LearnerDispatch::logistic_regression(LogisticRegression::new())
}

///|
/// Construct with an EXPLICIT `ml_m`. Never rely on the implicit default in
/// a contrast -- see the method note above.
fn v1530_cs(ml_m : LearnerDispatch) -> DoubleMLDIDCS {
  DoubleMLDIDCS::new(v1530_data(), n_folds=2, n_rep=1, seed=3141, ml_m~)
}

///|
/// GATE 1. `fit` USES the learner the constructor recorded.
///
/// This is the load-bearing gate. If `fit` still defaulted to a hardcoded OLS
/// -- the pre-v0.153.0 behaviour -- both arms below would be OLS and the
/// difference would be exactly 0, failing the assertion. So this gate kills
/// the revert-to-hardcode mutant, which is the defect being fixed.
///
/// Two quantities, not one: a learner that changes the point estimate but
/// not the standard error would otherwise slip through.
test "v1530_didcs_fit_uses_the_recorded_propensity_learner" {
  let ols = v1530_cs(v1530_ols()).fit()
  let log = v1530_cs(v1530_logistic()).fit()
  assert_true((ols.coef_at(0, 1) - log.coef_at(0, 1)).abs() > 1.0e-9)
  assert_true((ols.se_at(0, 1) - log.se_at(0, 1)).abs() > 1.0e-9)
}

///|
/// GATE 2. `fit`'s IMPLICIT default equals the STORED learner, so recording
/// the choice is actually wired to consuming it.
///
/// Not a self-comparison despite the identical numbers: arm A relies on
/// `fit`'s default resolving to `self.ml_m`, arm B passes it explicitly.
/// Under the pre-v0.153.0 hardcoded default, arm A is OLS and arm B is
/// logistic, so the two diverge and this fails.
///
/// 1e-12 rather than `==`: the did_cs quantities carry the known ~1.5e-15
/// cross-backend spread (v0.152.0), and an exact pin here would pass native
/// and fail wasm/wasm-gc/js.
test "v1530_implicit_fit_default_equals_the_stored_learner" {
  let implicit = v1530_cs(v1530_logistic()).fit()
  let explicit = v1530_cs(v1530_logistic()).fit(ml_m=v1530_logistic())
  assert_true(
    (implicit.coef_at(0, 1) - explicit.coef_at(0, 1)).abs() <= 1.0e-12,
  )
  assert_true((implicit.se_at(0, 1) - explicit.se_at(0, 1)).abs() <= 1.0e-12)
}

///|
/// GATE 3. An explicit `fit` argument still OVERRIDES the stored learner, so
/// recording the constructor choice did not silently break the per-fit
/// override that `tune` relies on.
///
/// `DoubleMLDIDCS::tune` calls `self.fit(ml_g=..., ml_m=...)` directly
/// (`did_cs.mbt`), so if the override stopped winning, tuning would silently
/// become a no-op. Nothing else in the suite covers that path.
test "v1530_explicit_fit_argument_overrides_the_stored_learner" {
  let overridden = v1530_cs(v1530_logistic()).fit(ml_m=v1530_ols())
  let pure_ols = v1530_cs(v1530_ols()).fit()
  assert_true(
    (overridden.coef_at(0, 1) - pure_ols.coef_at(0, 1)).abs() <= 1.0e-12,
  )
}

///|
/// GATE 4. BACKWARD COMPATIBILITY LOCK. The implicit default must be
/// bit-identical to an explicitly-OLS pair -- that is the whole claim that
/// this release changes no estimate for any existing caller.
///
/// Mutation target: restore `linear_regression()` as the `::new` default for
/// `ml_m`. That leaves every other gate green (they all pass `ml_m`
/// explicitly) while silently moving every default caller back onto OLS.
test "v1530_default_path_is_identical_to_an_explicit_ols_pair" {
  let implicit = DoubleMLDIDCS::new(v1530_data(), n_folds=2, n_rep=1, seed=3141).fit()
  let explicit = v1530_cs(v1530_ols()).fit()
  assert_true(
    (implicit.coef_at(0, 1) - explicit.coef_at(0, 1)).abs() <= 1.0e-12,
  )
  assert_true((implicit.se_at(0, 1) - explicit.se_at(0, 1)).abs() <= 1.0e-12)
}

///|
/// GATE 5. The ACCESSOR returns the learner `fit` actually consumed.
///
/// Existence alone would be a compile-time fact, not a gate. This is the
/// semantic version: feeding the accessor's own return value back into `fit`
/// must reproduce the implicit fit exactly. An accessor that returned a
/// hardcoded OLS while `fit` used the stored logistic would diverge here.
///
/// Mutation target: make `learner_m()` return `LearnerDispatch::linear_regression()`.
test "v1530_the_accessor_returns_the_learner_that_fit_actually_used" {
  let est = v1530_cs(v1530_logistic())
  let implicit = est.fit()
  let via_accessor = est.fit(ml_m=est.learner_m())
  assert_true(
    (implicit.coef_at(0, 1) - via_accessor.coef_at(0, 1)).abs() <= 1.0e-12,
  )
}

///|
/// GATE 6. The same wiring holds for `DoubleMLDIDCSBinary`, the second of the
/// three. Its header comment claimed `ml_g` / `ml_m` were "collapsed to the
/// same closed-form `LinearRegression` learner" -- true at v0.51.0, stale from
/// v0.62.0, and corrected in this release. If learners really were collapsed,
/// the two arms could not differ.
test "v1530_did_cs_binary_uses_its_recorded_learners" {
  let ols = DoubleMLDIDCSBinary::new(
    v1530_data(),
    1,
    0,
    1,
    n_folds=2,
    ml_m=v1530_ols(),
  ).fit()
  let log = DoubleMLDIDCSBinary::new(
    v1530_data(),
    1,
    0,
    1,
    n_folds=2,
    ml_m=v1530_logistic(),
  ).fit()
  assert_true((ols.coef() - log.coef()).abs() > 1.0e-9)
}

///|
/// GATE 7. And for `DoubleMLDIDBinary`, the third and innermost of the three
/// -- the estimator `DoubleMLDIDCS` delegates each `(g, t)` cell to.
///
/// Fixture note, and it cost two attempts to find. The first version reused
/// the 4-unit x 2-period fixture from `did_binary_test.mbt`. That fixture
/// cannot discriminate a propensity learner **by construction**: treatment
/// is deterministic (units 0-2 have `d = 1`, unit 3 has `d = 0`), so `m_hat`
/// is a clean 1/0 either way and OLS and logistic agree exactly. Giving `x`
/// real spread did not help -- the defect is the deterministic assignment, not
/// the missing covariate. The measured symptom both times was the contrast
/// arm returning false on identical numbers.
///
/// So the gate runs on the stochastic CS2021 panel instead, using the same
/// `(g, t_pre, t_eval) = (1, 0, 1)` triple the canonical DIDCS cell uses.
/// Note the field order differs between the two data types:
/// `DoubleMLDIDCSData::new` takes `(x, y, d, t, id, g)` while
/// `DoubleMLDIDBinaryData::new` takes `(x, y, d, t, g, id)`.
test "v1530_did_binary_uses_its_recorded_learners" {
  let d = make_did_cs_CS2021(800, 3, 1.0, 3141)
  let mk = fn(ml_m : LearnerDispatch) {
    DoubleMLDIDBinary::new(
      DoubleMLDIDBinaryData::new(
        d.x_get(),
        d.y_get(),
        d.d_get(),
        d.t_get(),
        d.g_get(),
        d.id_get(),
      ),
      1,
      0,
      1,
      ml_m~,
    ).fit()
  }
  let ols = mk(v1530_ols())
  let log = mk(v1530_logistic())
  assert_true((ols.coef() - log.coef()).abs() > 1.0e-9)
  // And the accessor round-trips on this one too: feeding the accessor's own
  // return value back into `fit` must reproduce the fit it was recorded for.
  let est = mk(v1530_logistic())
  ignore(est.learner_g())
  assert_true(
    (est.fit(ml_m=est.learner_m()).coef() - est.coef()).abs() <= 1.0e-12,
  )
}
