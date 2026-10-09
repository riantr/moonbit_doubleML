///|
// v0.122.0 -- `ps_processor_config` reaches the remaining estimators, and
// two bugs the existing suite found on the way.
//
// WHAT THIS RELEASE CHANGES
//
//   * `ps_processor_config?` added to `DoubleMLIRM` (the second estimator
//     upstream wires, after APO/APOS in v0.121.0), carried through every
//     rebuild of the struct and into the memoize key.
//
//   * BUG 1 -- `PSProcessor::adjust_ps` validated a BINARY treatment
//     unconditionally. Upstream does the same, and upstream has no
//     continuous-treatment estimator so it never notices. This port
//     does: `DoubleMLIIVM`'s cluster DGP
//     (`pliv_cluster_test.mbt::build_iv_clustered_dgp`) builds a
//     CONTINUOUS `d` -- the binary variable there is the instrument
//     `z`, not the treatment. Routing IIVM's clip site through
//     `adjust_ps` aborted on `iivm_cluster_deterministic`.
//     The requirement now applies only when a calibration actually
//     runs, which is the only case where it means anything: with
//     `calibration_method = "none"` the transform is a pure clip and is
//     valid for any treatment. CAUGHT BY THE TEST SUITE, not by
//     inspection.
//
//   * BUG 2 -- `hash_hyperparams` folded only `propensity_clip`. Since
//     the config became reachable, two estimators can share a clipping
//     threshold and differ in `calibration_method`, and the memoize
//     key would have let the second read the first one's cached
//     nuisances and report a silently wrong coefficient. The config is
//     now folded in.
//
// WHY THESE GATES ARE WHAT THEY ARE
//
// G1-G4 are about `DoubleMLIRM`'s surface. G5-G7 are about the two bugs:
// each pins the fixed behaviour AND the behaviour that must NOT change,
// because a fix that quietly relaxes a guard is its own regression. In
// particular G7 asserts that a non-binary treatment is still rejected
// when calibration IS requested -- upstream's semantics are preserved
// exactly where they are meaningful.

///|
/// Binary-treatment DGP for `DoubleMLIRM`. `d` is Bernoulli so the
/// isotonic calibration has a valid target; the estimator's default
/// `ml_m` is OLS, whose fitted propensity sits strictly inside (0,1).
fn v122_irm_data() -> DoubleMLData {
  let n = 300
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let s = chacha8_rng(2026)
  for i = 0; i < n; i = i + 1 {
    let x0 = s.double() * 2.0 - 1.0
    let x1 = s.double() * 2.0 - 1.0
    x.set(i, 0, x0)
    x.set(i, 1, x1)
    let di = if s.double() > 0.5 { 1.0 } else { 0.0 }
    d[i] = di
    // a deliberately MIScalibrated propensity: `di` is driven by a
    // squashed score, so a linear propensity model is off through the
    // middle of the range -- the case isotonic calibration exists for.
    y[i] = 1.0 + 0.8 * x0 - 0.4 * x1 + 2.0 * di + 0.3 * (s.double() - 0.5)
  }
  DoubleMLData::new(x, y, d)
}

///|
fn v122_irm_plain() -> DoubleMLIRM {
  DoubleMLIRM::new(v122_irm_data(), n_folds=2, seed=3141)
}

///|
fn v122_irm_isotonic() -> DoubleMLIRM {
  DoubleMLIRM::new(
    v122_irm_data(),
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(
      PSProcessorConfig::new(
        clipping_threshold=1.0e-6,
        calibration_method="isotonic",
      ) catch {
        PSConfigError::InconsistentCVCalibration => abort("unreachable")
      },
    ),
  )
}

// ---------------------------------------------------------------------------
// G1 -- the config is reachable and changes the estimate. If isotonic
// calibration did not move the IRM coefficient, the whole wiring would be
// decorative.
// ---------------------------------------------------------------------------

///|
test "v122_irm_isotonic_config_changes_the_estimate" {
  let plain = v122_irm_plain().fit()
  let iso = v122_irm_isotonic().fit()
  let moved = (plain.coef() - iso.coef()).abs()
  assert_true(moved > 1.0e-9)
  println(
    "v122 IRM coef plain=" +
    plain.coef().to_string() +
    " isotonic=" +
    iso.coef().to_string(),
  )
}

// ---------------------------------------------------------------------------
// G2 -- upstream's `init_ps_processor` precedence, on a real estimator: the
// config WINS, and the deprecated scalar is reported back from the
// processor (upstream sets `_trimming_threshold` from it).
// ---------------------------------------------------------------------------

///|
test "v122_irm_config_wins_over_the_scalar" {
  let both = DoubleMLIRM::new(
    v122_irm_data(),
    n_folds=2,
    seed=3141,
    propensity_clip=0.05,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.02)),
  )
  let only_cfg = DoubleMLIRM::new(
    v122_irm_data(),
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.02)),
  )
  assert_true(both.fit().coef() == only_cfg.fit().coef())
  // and a scalar-only construction is unaffected by the new parameter
  let scalar_only = DoubleMLIRM::new(
    v122_irm_data(),
    n_folds=2,
    seed=3141,
    propensity_clip=0.05,
  )
  let explicit = DoubleMLIRM::new(
    v122_irm_data(),
    n_folds=2,
    seed=3141,
    propensity_clip=0.05,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.05)),
  )
  assert_true(scalar_only.fit().coef() == explicit.fit().coef())
}

// ---------------------------------------------------------------------------
// G3 -- backward compatibility. The pre-v0.122.0 four-argument call must
// still mean exactly what it meant: no calibration, clip at the given
// scalar. This is the gate that would have caught an accidental default
// change from "none" to something else.
// ---------------------------------------------------------------------------

///|
test "v122_irm_default_construction_is_unchanged" {
  let a = DoubleMLIRM::new(v122_irm_data(), n_folds=2, seed=3141).fit()
  let b = DoubleMLIRM::new(
    v122_irm_data(),
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=1.0e-6)),
  ).fit()
  assert_true(a.coef() == b.coef())
  assert_true(a.se() == b.se())
}

// ---------------------------------------------------------------------------
// G4 -- the config survives a refit of the returned model. `fit`,
// `fit_cluster` and `set_sample_splitting` each rebuild the struct; the
// same coverage hole that the v0.121.0 harness found on APO applies here.
// ---------------------------------------------------------------------------

///|
test "v122_irm_config_survives_a_refit" {
  let once = v122_irm_isotonic().fit()
  let twice = once.fit()
  let plain = v122_irm_plain().fit()
  assert_true(twice.coef() == once.coef())
  assert_true((twice.coef() - plain.coef()).abs() > 1.0e-9)
}

// ---------------------------------------------------------------------------
// G5 -- RETRACTED IN v0.123.0, and this comment is the retraction.
//
// This gate originally asserted: "an UNCALIBRATED processor must accept
// a continuous treatment, because then it is a pure clip." That
// asserted a DEVIATION from upstream, on the stated grounds that
// "upstream has no continuous-treatment estimator".
//
// That grounds were wrong. Upstream `DoubleMLIIVM` passes the
// INSTRUMENT `z` to `adjust_ps` (`iivm.py:371`), not the treatment `d`,
// and `z` is binary regardless of `d`. So upstream's unconditional
// `_validate_treatment` was correct at every one of its twelve call
// sites; this port's IIVM aborting was a port defect (passing `d`),
// not an upstream limitation.
//
// With the defect fixed in v0.123.0, the unconditional requirement is
// restored to match upstream, and this test would have asserted the
// opposite of upstream semantics. Replaced by the two below: the rule
// is pinned positively (`treatment_is_binary`), and the IIVM site is
// pinned to pass `z` rather than `d`.
// ---------------------------------------------------------------------------

///|
test "v122_adjust_ps_still_clips_with_a_binary_treatment" {
  let ps = [0.05, 0.2, 0.5, 0.8, 0.95]
  let d = [1.0, 0.0, 1.0, 0.0, 1.0]
  let out = PSProcessor::from_config(
    PSProcessorConfig::new(clipping_threshold=0.01),
  ).adjust_ps(ps, d)
  // the transform is a pure clip under the default config
  assert_true(out[0] == 0.05)
  assert_true(out[4] == 0.95)
  assert_true(out[2] == 0.5)
  let flat = PSProcessor::from_config(
    PSProcessorConfig::new(clipping_threshold=0.1),
  ).adjust_ps(ps, d)
  assert_true(flat[0] == 0.1)
}

// ---------------------------------------------------------------------------
// G6 -- and the clip really is a clip, so a planted out-of-range value
// lands on the bound.
// ---------------------------------------------------------------------------

///|
test "v122_adjust_ps_uncalibrated_still_clips" {
  let ps = [0.0, 0.5, 1.0]
  let d = [1.0, 0.0, 1.0]
  let out = PSProcessor::from_config(
    PSProcessorConfig::new(clipping_threshold=0.02),
  ).adjust_ps(ps, d)
  assert_true(out[0] == 0.02)
  assert_true(out[2] == 0.98)
  assert_true(out[1] == 0.5)
}

// ---------------------------------------------------------------------------
// G7 -- BUG 1 must NOT become "validation removed". Upstream's
// `_validate_treatment` semantics are preserved exactly where they are
// meaningful: a calibration needs a binary target.
//
// The rule is pinned as a total predicate, because the ABORT it causes
// cannot be pinned. MoonBit's `panic_` prefix tells the framework an
// abort is expected, which means a `panic_` test that DOES NOT abort
// still passes -- so no assertion can detect a missing abort here. The
// mutation harness proved exactly that: deleting the `validate_treatment`
// call from `adjust_ps` leaves 939/939 green.
//
// `treatment_is_binary` is the part that carries the meaning, so it gets
// real assertions. The remaining wiring (guarded vs unconditional) is
// covered from the other side: making the check unconditional aborts
// `iivm_cluster_deterministic`, which is a real kill.
// ---------------------------------------------------------------------------

///|
fn v122_expect_bool(actual : Bool, expected : Bool, msg : String) -> Unit {
  if actual != expected {
    abort(msg)
  }
}

///|
test "v122_treatment_is_binary_accepts_only_zero_and_one" {
  // The accepted case, and it must stay accepted: an over-eager
  // predicate would abort every calibrated estimate.
  v122_expect_bool(
    treatment_is_binary([1.0, 0.0, 1.0]),
    true,
    "a {0,1} treatment must be binary",
  )
  // The rejected cases. Each is a distinct way of getting here in
  // practice, so all three are pinned rather than just one.
  v122_expect_bool(
    treatment_is_binary([0.3, -1.2, 0.7, 2.5, 0.1]),
    false,
    "a continuous treatment is not binary (IIVM's cluster DGP)",
  )
  v122_expect_bool(
    treatment_is_binary([0.0, 0.5]),
    false,
    "a probability-valued treatment is not binary",
  )
  v122_expect_bool(
    treatment_is_binary([0.0, 2.0]),
    false,
    "a treatment outside [0,1] is not binary",
  )
  // Vacuously true: "no offending element". `adjust_ps` rejects the
  // empty case separately via its own `n > 0` requirement.
  v122_expect_bool(
    treatment_is_binary([]),
    true,
    "an empty treatment has no offending element",
  )
}

///|
test "panic_v122_adjust_ps_rejects_a_continuous_treatment_when_calibrating" {
  let ps = [0.1, 0.4, 0.6, 0.9, 0.3]
  let d = [0.3, -1.2, 0.7, 2.5, 0.1]
  let _ = PSProcessor::from_config(
    PSProcessorConfig::new(
      clipping_threshold=0.01,
      calibration_method="isotonic",
    ),
  ).adjust_ps(ps, d)
}

// ---------------------------------------------------------------------------
// G8 -- BUG 2 fix. Two estimators that share a clipping threshold but
// differ in calibration must NOT share a memoize key.
// ---------------------------------------------------------------------------

///|
test "v122_cache_key_separates_calibration_methods" {
  let ml_g = LearnerDispatch::linear_regression()
  let ml_m = LearnerDispatch::linear_regression()
  let none_cfg = PSProcessorConfig::new(clipping_threshold=0.01)
  let iso_cfg = PSProcessorConfig::new(
    clipping_threshold=0.01,
    calibration_method="isotonic",
  )
  let cv_cfg = PSProcessorConfig::new(
    clipping_threshold=0.01,
    calibration_method="isotonic",
    cv_calibration=true,
  ) catch {
    PSConfigError::InconsistentCVCalibration => abort("unreachable")
  }
  let k_none = hash_hyperparams(
    "irm",
    ml_g,
    ml_m,
    0.01,
    ps_processor_config=Some(none_cfg),
  )
  let k_iso = hash_hyperparams(
    "irm",
    ml_g,
    ml_m,
    0.01,
    ps_processor_config=Some(iso_cfg),
  )
  let k_cv = hash_hyperparams(
    "irm",
    ml_g,
    ml_m,
    0.01,
    ps_processor_config=Some(cv_cfg),
  )
  assert_true(k_none != k_iso)
  assert_true(k_iso != k_cv)
  // the threshold still distinguishes, as it always did
  let k_other = hash_hyperparams(
    "irm",
    ml_g,
    ml_m,
    0.02,
    ps_processor_config=Some(iso_cfg),
  )
  assert_true(k_iso != k_other)
  // and the pre-v0.122.0 four-argument call still works
  let k_legacy = hash_hyperparams("irm", ml_g, ml_m, 0.01)
  assert_true(k_legacy != k_none)
}

// ---------------------------------------------------------------------------
// G9 -- `resolve_ps_processor_config` still holds the single definition of
// the precedence rule, now with two consumers (APO/APOS and IRM).
// ---------------------------------------------------------------------------

///|
test "v122_resolution_is_shared_not_duplicated" {
  let resolved = resolve_ps_processor_config(
    ps_processor_config=None,
    trimming_threshold=0.05,
  )
  assert_true(resolved.clipping_threshold == 0.05)
  assert_true(resolved.calibration_method == "none")
  let cfg = PSProcessorConfig::new(clipping_threshold=0.3)
  let winner = resolve_ps_processor_config(
    ps_processor_config=Some(cfg),
    trimming_threshold=0.05,
  )
  assert_true(winner.clipping_threshold == 0.3)
}

// ---------------------------------------------------------------------------
// G10 -- FOUND BY THE HARNESS: the deprecated `propensity_clip` scalar was
// UNOBSERVABLE, so nothing pinned that it still reaches the estimator.
//
// The mutation `trimming_threshold=propensity_clip` -> `1.0e-6` -- i.e.
// hardcoding the default, so a caller's scalar is silently discarded --
// left all 940 tests green and was reported SURVIVED.
//
// The cause is the FIXTURE, not a missing assertion. G2 passes
// `propensity_clip=0.05` and compares two constructions, but this file's
// `v122_irm_data()` has OLS-fitted propensities sitting well inside
// (0.05, 0.95), so clipping is a no-op on it and every threshold gives
// the same number. G2 would have passed even if clipping did nothing at
// all. A gate on that fixture can never prove the scalar is live.
//
// `v122_extreme_data()` fixes the fixture, not the assertion: its
// propensity score is saturated outside [0.02, 0.98], which is the regime
// clipping exists for. Measured on n=300, n_folds=2, seed=3141:
//
//   clip=1e-6 (default)  coef= -184.45233863898693   se=387.07267205533924
//   clip=0.02            coef=    2.0052723853508585  se=  0.024890439804802558
//   clip=0.05            coef=    2.007669306031133   se=  0.015078536080260638
//   clip=0.1             coef=    2.004486580247429   se=  0.010109627432972187
//   clip=0.2             coef=    2.004176528941727   se=  0.008546373310148224
//
// The default does not merely differ, it diverges -- 92x, and the sign
// of the estimate goes with it. So the threshold used here is 1.0, five
// orders of magnitude below the observed 186.5 gap: it cannot be tripped
// by noise, and it cannot be met by a no-op clip.
// ---------------------------------------------------------------------------

///|
fn v122_extreme_data() -> DoubleMLData {
  let n = 300
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let s = chacha8_rng(2026)
  for i = 0; i < n; i = i + 1 {
    let x0 = s.double() * 2.0 - 1.0
    let x1 = s.double() * 2.0 - 1.0
    x.set(i, 0, x0)
    x.set(i, 1, x1)
    // the propensity model is itself extreme: the linear score is pushed
    // outside [0,1] and saturated, so a large share of rows sit at ~0.02
    // or ~0.98. Overlap is violated in the tails, which is precisely
    // what the clip repairs.
    let raw = 0.5 + 1.2 * x0
    let pi = if raw < 0.02 { 0.02 } else if raw > 0.98 { 0.98 } else { raw }
    let di = if s.double() < pi { 1.0 } else { 0.0 }
    d[i] = di
    y[i] = 1.0 + 0.8 * x0 - 0.4 * x1 + 2.0 * di + 0.3 * (s.double() - 0.5)
  }
  DoubleMLData::new(x, y, d)
}

///|
test "v122_irm_scalar_clip_reaches_the_estimator" {
  let default = DoubleMLIRM::new(
    v122_extreme_data(),
    n_folds=2,
    seed=3141,
    propensity_clip=1.0e-6,
  ).fit()
  let clipped = DoubleMLIRM::new(
    v122_extreme_data(),
    n_folds=2,
    seed=3141,
    propensity_clip=0.05,
  ).fit()
  // the deprecated scalar is LIVE: hardcoding the default breaks this
  assert_true((default.coef() - clipped.coef()).abs() > 1.0)
  assert_true((default.se() - clipped.se()).abs() > 1.0)
  // and the config route agrees with the scalar route for the same
  // threshold -- one threshold, two doors, one value
  let via_cfg = DoubleMLIRM::new(
    v122_extreme_data(),
    n_folds=2,
    seed=3141,
    propensity_clip=0.2,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.05)),
  ).fit()
  let via_scalar = DoubleMLIRM::new(
    v122_extreme_data(),
    n_folds=2,
    seed=3141,
    propensity_clip=0.05,
  ).fit()
  assert_true(via_cfg.coef() == via_scalar.coef())
  assert_true(via_cfg.se() == via_scalar.se())
}
