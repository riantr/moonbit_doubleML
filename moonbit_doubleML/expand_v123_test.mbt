///|
// v0.123.0 -- `ps_processor_config` reaches `DoubleMLIIVM` and
// `DoubleMLSSM`, and v0.122.0's BUG 1 is retracted at the root.
//
// WHAT THIS RELEASE CHANGES
//
//   * `ps_processor_config?` added to `DoubleMLIIVM` and `DoubleMLSSM`,
//     carried through every rebuild of the struct and into the
//     memoize key.
//
//   * THE IIVM CLIP SITE NOW PASSES THE INSTRUMENT `z`, NOT THE
//     TREATMENT `d`. Upstream does this (`iivm.py:371`:
//     `adjust_ps(m_hat["preds"], z, cv=smpls)`) and v0.122.0's notes on
//     the port missed it. `m` is the propensity OF THE INSTRUMENT --
//     `ml_m` is trained on `(x, z)` -- so `z` is both the correct
//     calibration target and, unlike `d`, genuinely binary.
//
//   * SSM's `m` AND `pi` ARE NOT SYMMETRIC. Upstream adjusts only `m`
//     (`ssm.py:407`); `pi_hat["preds"]` goes raw into `_score_elements`
//     (`ssm.py:414`). This port always clipped both, and now routes
//     only `m` through `adjust_ps`. G10 pins the asymmetry.
//
//   * `PSProcessor::adjust_ps`'s binary-treatment requirement is
//     UNCONDITIONAL again, matching upstream. v0.122.0 scoped it to
//     `calibration_method == "isotonic"`, which asserted a deviation
//     whose stated justification turned out to be wrong. See the
//     retraction note in G5 below and in `ps_processor.mbt`.
//
// WHY THE FIXTURES ARE EXTREME
//
// v0.122.0 shipped a gate that was completely load-free because its
// fixture could not see what it claimed to test (the
// `v122_irm_resolution_lets-the-scalar-win` mutation survived 940
// green tests). So sensitivity was MEASURED before these gates were
// written. On the DGPs below (n=400, n_folds=2, seed=3141):
//
//   IIVM  clip=1e-6 (default)  coef=  2.066549039129563   se=0.09876035703345087
//   IIVM  clip=0.02            coef=  4.753714107957456   se=1.5191055684317063
//   IIVM  clip=0.05            coef=  7.14609566376223    se=2.453942581591049
//   IIVM  clip=0.2             coef= 11.433861766061282   se=4.182861483160994
//   IIVM  isotonic             coef=  7.827732496888789   se=3.6147767813676905
//
//   SSM   clip=1e-6 (default)  coef= 30.374462673565066   se=28.32749988062885
//   SSM   clip=0.02            coef=  2.012861251839158   se=0.008075997019551364
//   SSM   clip=0.05            coef=  2.0120056836041798  se=0.008012773349507691
//   SSM   clip=0.2             coef=  2.0114767519674253  se=0.008368287329930852
//   SSM   isotonic             coef=  2.0132836573878383  se=0.009026133183748673
//
// Both blow up at the default threshold (SSM by 15x, IIVM moves 5.5x
// across the sweep), so every difference gate below has a gap of at
// least 0.36 and most are >2.7. The thresholds used are 1e-9 for
// equality and 1e-3 for "moved", i.e. 4-6 orders of magnitude below
// what was observed.

// ---------------------------------------------------------------------------
// DGPs
// ---------------------------------------------------------------------------

///|
/// Binary `z` (instrument) whose propensity is saturated outside
/// [0.02, 0.98], so the fitted `m` actually reaches the clip range.
/// `d` is binary here; the CONTINUOUS-`d` variant is G12.
fn v123_iivm_data() -> DoubleMLIIVMData {
  let n = 400
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let z = Array::make(n, 0.0)
  let s = chacha8_rng(2026)
  for i = 0; i < n; i = i + 1 {
    let x0 = s.double() * 2.0 - 1.0
    let x1 = s.double() * 2.0 - 1.0
    x.set(i, 0, x0)
    x.set(i, 1, x1)
    let raw = 0.5 + 1.2 * x0
    let pz = if raw < 0.02 { 0.02 } else if raw > 0.98 { 0.98 } else { raw }
    let zi = if s.double() < pz { 1.0 } else { 0.0 }
    z[i] = zi
    let di = if s.double() < 0.5 { 1.0 } else { 0.0 }
    d[i] = di
    y[i] = 1.0 +
      0.8 * x0 -
      0.4 * x1 +
      2.0 * di +
      1.0 * zi +
      0.3 * (s.double() - 0.5)
  }
  DoubleMLIIVMData::new(x, y, d, z)
}

///|
/// Same shape for SSM: `d` is the treatment (saturated propensity),
/// `s` the selection indicator.
fn v123_ssm_data() -> DoubleMLSSMData {
  let n = 400
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let s = Array::make(n, 0.0)
  let r = chacha8_rng(2027)
  for i = 0; i < n; i = i + 1 {
    let x0 = r.double() * 2.0 - 1.0
    let x1 = r.double() * 2.0 - 1.0
    x.set(i, 0, x0)
    x.set(i, 1, x1)
    let raw = 0.5 + 1.2 * x0
    let pd = if raw < 0.02 { 0.02 } else if raw > 0.98 { 0.98 } else { raw }
    d[i] = if r.double() < pd { 1.0 } else { 0.0 }
    s[i] = if r.double() < 0.6 { 1.0 } else { 0.0 }
    y[i] = 1.0 +
      0.8 * x0 -
      0.4 * x1 +
      2.0 * d[i] +
      1.0 * s[i] +
      0.3 * (r.double() - 0.5)
  }
  DoubleMLSSMData::new(x, y, d, s)
}

///|
fn v123_iivm_iso() -> DoubleMLIIVM {
  DoubleMLIIVM::new(
    v123_iivm_data(),
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

///|
fn v123_ssm_iso() -> DoubleMLSSM {
  DoubleMLSSM::new(
    v123_ssm_data(),
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
// G1 / G2 -- the config is REACHABLE and moves the estimate. A gate that
// passes on both branches measures nothing.
// ---------------------------------------------------------------------------

///|
test "v123_iivm_calibration_is_not_cosmetic" {
  let plain = DoubleMLIIVM::new(v123_iivm_data(), n_folds=2, seed=3141).fit()
  let iso = v123_iivm_iso().fit()
  // measured gap 5.761
  assert_true((iso.coef() - plain.coef()).abs() > 1.0e-3)
}

///|
test "v123_ssm_calibration_is_not_cosmetic" {
  let plain = DoubleMLSSM::new(v123_ssm_data(), n_folds=2, seed=3141).fit()
  let iso = v123_ssm_iso().fit()
  // measured gap 28.361
  assert_true((iso.coef() - plain.coef()).abs() > 1.0e-3)
}

// ---------------------------------------------------------------------------
// G3 / G4 -- backward compatibility. The pre-v0.123.0 call must still
// mean exactly what it meant: no calibration, clip at the given scalar.
// ---------------------------------------------------------------------------

///|
test "v123_iivm_default_construction_is_unchanged" {
  let a = DoubleMLIIVM::new(v123_iivm_data(), n_folds=2, seed=3141).fit()
  let b = DoubleMLIIVM::new(
    v123_iivm_data(),
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=1.0e-6)),
  ).fit()
  assert_true(a.coef() == b.coef())
  assert_true(a.se() == b.se())
}

///|
test "v123_ssm_default_construction_is_unchanged" {
  let a = DoubleMLSSM::new(v123_ssm_data(), n_folds=2, seed=3141).fit()
  let b = DoubleMLSSM::new(
    v123_ssm_data(),
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=1.0e-6)),
  ).fit()
  assert_true(a.coef() == b.coef())
  assert_true(a.se() == b.se())
}

// ---------------------------------------------------------------------------
// G5 / G6 -- upstream's `init_ps_processor` precedence on a real
// estimator: the config WINS outright, the scalar is only the fallback.
// ---------------------------------------------------------------------------

///|
test "v123_iivm_config_wins_over_the_scalar" {
  let both = DoubleMLIIVM::new(
    v123_iivm_data(),
    n_folds=2,
    seed=3141,
    propensity_clip=0.05,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.2)),
  ).fit()
  let only_cfg = DoubleMLIIVM::new(
    v123_iivm_data(),
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.2)),
  ).fit()
  assert_true(both.coef() == only_cfg.coef())
}

///|
test "v123_ssm_config_wins_over_the_scalar" {
  let both = DoubleMLSSM::new(
    v123_ssm_data(),
    n_folds=2,
    seed=3141,
    propensity_clip=0.05,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.2)),
  ).fit()
  let only_cfg = DoubleMLSSM::new(
    v123_ssm_data(),
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.2)),
  ).fit()
  assert_true(both.coef() == only_cfg.coef())
}

// ---------------------------------------------------------------------------
// G7 / G8 -- the deprecated scalar is still LIVE. This is the gate
// v0.122.0 was missing: hardcoding the default must fail it. Measured
// gaps are 9.367 (IIVM) and 28.363 (SSM); the threshold is 1.0, four
// orders of magnitude below.
// ---------------------------------------------------------------------------

///|
test "v123_iivm_scalar_clip_reaches_the_estimator" {
  let dflt = DoubleMLIIVM::new(
    v123_iivm_data(),
    n_folds=2,
    seed=3141,
    propensity_clip=1.0e-6,
  ).fit()
  let clipped = DoubleMLIIVM::new(
    v123_iivm_data(),
    n_folds=2,
    seed=3141,
    propensity_clip=0.2,
  ).fit()
  assert_true((dflt.coef() - clipped.coef()).abs() > 1.0)
}

///|
test "v123_ssm_scalar_clip_reaches_the_estimator" {
  let dflt = DoubleMLSSM::new(
    v123_ssm_data(),
    n_folds=2,
    seed=3141,
    propensity_clip=1.0e-6,
  ).fit()
  let clipped = DoubleMLSSM::new(
    v123_ssm_data(),
    n_folds=2,
    seed=3141,
    propensity_clip=0.2,
  ).fit()
  assert_true((dflt.coef() - clipped.coef()).abs() > 1.0)
}

// ---------------------------------------------------------------------------
// G9 -- the config survives a rebuild. `fit`, `fit_cluster` and
// `set_sample_splitting` each reconstruct the struct; dropping the
// field in any of them means the NEXT fit silently loses the
// calibration. This is the v0.121.0 coverage hole, re-applied.
// ---------------------------------------------------------------------------

///|
test "v123_config_survives_a_refit" {
  let iivm_once = v123_iivm_iso().fit()
  let iivm_twice = iivm_once.fit()
  let iivm_plain = DoubleMLIIVM::new(v123_iivm_data(), n_folds=2, seed=3141).fit()
  assert_true(iivm_twice.coef() == iivm_once.coef())
  assert_true((iivm_once.coef() - iivm_plain.coef()).abs() > 1.0e-3)
  let ssm_once = v123_ssm_iso().fit()
  let ssm_twice = ssm_once.fit()
  let ssm_plain = DoubleMLSSM::new(v123_ssm_data(), n_folds=2, seed=3141).fit()
  assert_true(ssm_twice.coef() == ssm_once.coef())
  assert_true((ssm_once.coef() - ssm_plain.coef()).abs() > 1.0e-3)
}

// ---------------------------------------------------------------------------
// G10 -- THE SSM ASYMMETRY. Upstream adjusts `m` only; `pi` is never
// calibrated. Pinned directly on the nuisance predictions, because it
// is the one place this release could have invented behaviour: routing
// `pi` through `adjust_ps` as well would have "worked" and produced
// plausible numbers while silently calibrating the SELECTION
// propensity against the treatment -- something upstream never does.
//
// So: under isotonic, `predictions_m()` must MOVE and
// `predictions_pi()` must be BIT-IDENTICAL to the uncalibrated run.
// ---------------------------------------------------------------------------

///|
test "v123_ssm_calibrates_m_but_never_pi" {
  let plain = DoubleMLSSM::new(v123_ssm_data(), n_folds=2, seed=3141).fit()
  let iso = v123_ssm_iso().fit()
  // m is calibrated -> it moves
  let pm = plain.predictions_m()
  let im = iso.predictions_m()
  let mut moved = false
  for i = 0; i < pm.length(); i = i + 1 {
    if pm[i] != im[i] {
      moved = true
      break
    }
  }
  assert_true(moved)
  // pi is NOT calibrated -> bit-identical
  let pp = plain.predictions_pi()
  let ip = iso.predictions_pi()
  let mut same = true
  for i = 0; i < pp.length(); i = i + 1 {
    if pp[i] != ip[i] {
      same = false
      break
    }
  }
  assert_true(same)
}

// ---------------------------------------------------------------------------
// G11 -- the memoize key identifies the model, not one knob. Two SSM
// models sharing a clipping threshold but differing in calibration must
// not collide.
// ---------------------------------------------------------------------------

///|
test "v123_cache_key_separates_calibration_methods" {
  let ml_g = LearnerDispatch::linear_regression()
  let ml_m = LearnerDispatch::linear_regression()
  let none_cfg = PSProcessorConfig::new(clipping_threshold=0.01)
  let iso_cfg = PSProcessorConfig::new(
    clipping_threshold=0.01,
    calibration_method="isotonic",
  )
  let k_iivm_none = hash_hyperparams(
    "iivm",
    ml_g,
    ml_m,
    0.01,
    ps_processor_config=Some(none_cfg),
  )
  let k_iivm_iso = hash_hyperparams(
    "iivm",
    ml_g,
    ml_m,
    0.01,
    ps_processor_config=Some(iso_cfg),
  )
  assert_true(k_iivm_none != k_iivm_iso)
  let k_ssm_none = hash_hyperparams(
    "ssm",
    ml_g,
    ml_m,
    0.01,
    ps_processor_config=Some(none_cfg),
  )
  let k_ssm_iso = hash_hyperparams(
    "ssm",
    ml_g,
    ml_m,
    0.01,
    ps_processor_config=Some(iso_cfg),
  )
  assert_true(k_ssm_none != k_ssm_iso)
  // and the legacy four-argument call still works
  assert_true(hash_hyperparams("iivm", ml_g, ml_m, 0.01) != k_iivm_none)
}

// ---------------------------------------------------------------------------
// G13 -- the SELECTION propensity really is clipped. Found by the
// harness: `v123-ssm-drops-the-pi-clip-entirely` SURVIVED 953/953.
//
// The cause is the fixture, again. `v123_ssm_data` sets `s` ~
// Bernoulli(0.6) INDEPENDENTLY of X, which makes the fitted `pi_hat` a
// near-constant 0.6 that never approaches the bound, so deleting the
// clip changed nothing. This DGP makes selection nearly deterministic
// given X, so the fitted pi saturates and lands ON the bound.
//
// MEASURED on this DGP (n=400, n_folds=2, seed=3141):
//   clip=1e-6  min_pi=1e-6  max_pi=0.999999  45 at the lower bound,
//             44 at the upper, coef=-525.7603444463953
//   clip=0.2   min_pi=0.2   max_pi=0.8       106 at 0.2, 139 at 0.8,
//             coef=2.0201480268046885
//
// The assertion is deliberately "some element equals the bound
// EXACTLY" rather than "the coefficient moved": only a clip can
// manufacture that value, and 106/400 elements carry it, so this is
// immune to numerical drift. The default clip also shows what the
// selection clip is worth -- unclipped, the IPW score divides by
// ~0 and the coefficient runs away to -525.
// ---------------------------------------------------------------------------

///|
fn v123_ssm_selection_extreme() -> DoubleMLSSMData {
  let n = 400
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let s = Array::make(n, 0.0)
  let r = chacha8_rng(2029)
  for i = 0; i < n; i = i + 1 {
    let x0 = r.double() * 2.0 - 1.0
    let x1 = r.double() * 2.0 - 1.0
    x.set(i, 0, x0)
    x.set(i, 1, x1)
    let raw = 0.5 + 1.2 * x0
    let pd = if raw < 0.02 { 0.02 } else if raw > 0.98 { 0.98 } else { raw }
    d[i] = if r.double() < pd { 1.0 } else { 0.0 }
    // selection nearly deterministic given X
    let ps = if x0 > 0.2 { 0.97 } else if x0 < -0.2 { 0.03 } else { 0.5 }
    s[i] = if r.double() < ps { 1.0 } else { 0.0 }
    y[i] = 1.0 +
      0.8 * x0 -
      0.4 * x1 +
      2.0 * d[i] +
      1.0 * s[i] +
      0.3 * (r.double() - 0.5)
  }
  DoubleMLSSMData::new(x, y, d, s)
}

///|
test "v123_ssm_clips_the_selection_propensity" {
  let f = DoubleMLSSM::new(
    v123_ssm_selection_extreme(),
    n_folds=2,
    seed=3141,
    propensity_clip=0.2,
  ).fit()
  let pi = f.predictions_pi()
  let mut at_lo = 0
  let mut at_hi = 0
  for v in pi {
    if v == 0.2 {
      at_lo = at_lo + 1
    }
    if v == 0.8 {
      at_hi = at_hi + 1
    }
  }
  // measured 106 and 139; the assertion only needs "more than zero"
  assert_true(at_lo > 0)
  assert_true(at_hi > 0)
}

// ---------------------------------------------------------------------------
// G12 -- THE IIVM CORRECTION. `d` is CONTINUOUS here while `z` stays
// binary, exactly like `pliv_cluster_test.mbt::build_iv_clustered_dgp`.
// The fit must SUCCEED, and it can only succeed because the clip site
// passes `z`: `adjust_ps` validates the treatment argument
// unconditionally (restored in this release to match upstream), so
// handing it `d` aborts.
//
// This gate is what the v0.122.0 scoping destroyed. With the check
// skipped under the default config, passing `d` here would have been
// UNDETECTABLE and this test would have passed either way.
// ---------------------------------------------------------------------------

///|
test "v123_iivm_clip_site_validates_the_instrument_not_the_treatment" {
  let n = 300
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let z = Array::make(n, 0.0)
  let s = chacha8_rng(2028)
  for i = 0; i < n; i = i + 1 {
    let x0 = s.double() * 2.0 - 1.0
    let x1 = s.double() * 2.0 - 1.0
    x.set(i, 0, x0)
    x.set(i, 1, x1)
    z[i] = if s.double() > 0.5 { 1.0 } else { 0.0 }
    // CONTINUOUS treatment, on purpose
    d[i] = 0.6 * x0 + 0.3 * x1 + (s.double() - 0.5)
    y[i] = 1.0 + 0.8 * x0 - 0.4 * x1 + 1.0 * z[i] + 0.3 * (s.double() - 0.5)
  }
  let data = DoubleMLIIVMData::new(x, y, d, z)
  // the precondition: d really is non-binary, so this test has teeth
  assert_true(treatment_is_binary(d) == false)
  assert_true(treatment_is_binary(z))
  let fitted = DoubleMLIIVM::new(data, n_folds=2, seed=3141).fit()
  // and it produced a real, finite estimate rather than silently
  // degrading (NaN fails both halves: NaN == NaN is false)
  let c = fitted.coef()
  assert_true(c == c && c.abs() < 1.0e10)
}
