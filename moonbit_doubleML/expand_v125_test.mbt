///|
// v0.125.0 -- `ps_processor_config` reaches `DoubleMLLPQ`, and the
// complier-share overload is measured rather than inherited blind.
//
// THE FINDING THAT DROVE THIS RELEASE'S DESIGN
//
// v0.124.0 flagged that LPQ overloads `propensity_clip`: it is the
// propensity clipping threshold AND a floor on the estimated complier
// share. Measured here, floor present vs disabled (n=500, quantile=0.5,
// n_folds=2, seed=3141):
//
//   clip=1e-6  floor ON  coef=1.123984742821626  se=156.07090279138626
//               floor OFF coef=1.123984742821626  se=156.07090279138626
//   clip=1e-2  floor ON  coef=1.123984742821626  se= 0.14203520008944565
//               floor OFF coef=1.123984742821626  se= 0.14203520008944565
//   clip=0.05  floor ON  coef=4.739060249576877  se= 4.140929971656726
//               floor OFF coef=1.123984742821626  se= 0.04049475763990414
//   clip=0.2   floor ON  coef=4.739060249576877  se= 2.4472021260225816
//               floor OFF coef=1.1055582239973947  se= 0.030997902259302088
//
// Read that carefully: at 1e-6 and 1e-2 the floor changes NOTHING --
// identical coefficient AND identical standard error. At 0.05 it takes
// over completely (4.739 vs 1.124, a 4.2x divergence) and then FREEZES,
// because a floor of 0.05 saturates the bisection.
//
// Upstream has no floor at all: `comp_prob_hat` is a plain mean
// (`lpq.py:550-555`) used directly as a divisor in `_compute_ipw_score`.
// And upstream's default `trimming_threshold` is **1e-2** (`lpq.py:121`),
// where this port's floor is measured inert.
//
// => The divergence is confined to `propensity_clip > ~1e-2`, and it is
// driven entirely by a guard upstream does not have.
//
// WHAT THIS RELEASE THEREFORE DOES
//
// `ps_processor_config?` added to `DoubleMLLPQ`, threaded into the
// shared `fit_propensity` like PQ in v0.124.0.
//
// `propensity_clip` is DELIBERATELY NOT overwritten with the config's
// threshold, which is what upstream does at `lpq.py:166`. Overwriting it
// would drag the complier floor along, so raising a calibration
// threshold to 0.05 would silently switch the estimator into the
// regime where it diverges 4.2x from upstream. G3 and G4 below pin that
// the config does not reach the floor.
//
// Two measured facts that shaped the gates:
//
// 1. LPQ's COEFFICIENT does not respond to the propensity transform at
//    all. On a strongly nonlinear, saturated DGP (n=600, 3 covariates,
//    instrument propensity driven through `1.6*x1^2 + 1.2*x2^3` and
//    saturated at 0.01/0.99), default, isotonic, scalar=0.05 and
//    config=0.05 ALL return coef=5.130825735051371, bit-identical. The
//    quantile is pinned by the bisection bracket, not by the weights.
//    So a "calibration moves the estimate" gate CANNOT be written for
//    LPQ, and asserting one would be asserting a fiction.
//
// 2. The transform IS observable on the NUISANCE: under isotonic,
//    600/600 entries of `predictions_m()` differ, max delta
//    0.2501072828284096. That is what G1 asserts, and it is the same
//    shape as the SSM `m`/`pi` gate from v0.123.0.
//
// A negative result recorded rather than hidden: the CLIPPING threshold
// is not observable on LPQ at all. Even with the propensity saturated at
// 0.01, 0 of 600 fitted values land on the 0.05 bound -- OLS shrinks
// fitted propensities away from the tails. So there is no LPQ gate for
// "the clip threshold takes effect", and the config's threshold is
// carried but currently cannot change LPQ's output on these fixtures.

// ---------------------------------------------------------------------------
// DGP A -- nonlinear + deeply saturated. Used for the calibration gate,
// because it is the only shape tried on which isotonic has work to do.
// ---------------------------------------------------------------------------

///|
fn v125_lpq_nonlinear() -> DoubleMLLPQData {
  let n = 600
  let x = Matrix::zeros(n, 3)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let z = Array::make(n, 0.0)
  let s = chacha8_rng(2033)
  for i = 0; i < n; i = i + 1 {
    let x0 = s.double() * 2.0 - 1.0
    let x1 = s.double() * 2.0 - 1.0
    let x2 = s.double() * 2.0 - 1.0
    x.set(i, 0, x0)
    x.set(i, 1, x1)
    x.set(i, 2, x2)
    // strongly nonlinear -> a linear propensity model is misspecified,
    // which is the situation calibration exists for
    let score = 1.6 * x1 * x1 + 1.2 * x2 * x2 * x2 + 0.6 * x0
    let pz = if score < -3.2 {
      0.01
    } else if score > 3.2 {
      0.99
    } else {
      0.5 + 0.5 * score / 3.2
    }
    z[i] = if s.double() < pz { 1.0 } else { 0.0 }
    d[i] = if s.double() < 0.6 { 1.0 } else { 0.0 }
    y[i] = 2.0 + 0.5 * x0 + 1.5 * z[i] + 0.4 * x1 + (s.double() - 0.5)
  }
  DoubleMLLPQData::new(x, y, d, z)
}

///|
fn v125_lpq_iso() -> DoubleMLLPQ {
  DoubleMLLPQ::new(
    v125_lpq_nonlinear(),
    quantile=0.5,
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
// G1 -- the config REACHES the transform. Asserted on the nuisance,
// because the coefficient provably does not move.
// ---------------------------------------------------------------------------

///|
test "v125_lpq_calibration_reaches_the_propensity" {
  let plain = DoubleMLLPQ::new(
    v125_lpq_nonlinear(),
    quantile=0.5,
    n_folds=2,
    seed=3141,
  ).fit()
  let iso = v125_lpq_iso().fit()
  let pm = plain.predictions_m()
  let im = iso.predictions_m()
  let mut differing = 0
  let mut max_delta = 0.0
  for i = 0; i < pm.length(); i = i + 1 {
    if pm[i] != im[i] {
      differing = differing + 1
      let delta = (pm[i] - im[i]).abs()
      if delta > max_delta {
        max_delta = delta
      }
    }
  }
  // measured 600/600 differing, max delta 0.2501072828284096
  assert_true(differing > 0)
  assert_true(max_delta > 0.01)
}

// ---------------------------------------------------------------------------
// G2 -- backward compatibility. The pre-v0.125.0 call must still mean
// exactly what it meant: no calibration, clip at the given scalar.
// ---------------------------------------------------------------------------

///|
test "v125_lpq_default_construction_is_unchanged" {
  let a = DoubleMLLPQ::new(
    v125_lpq_nonlinear(),
    quantile=0.5,
    n_folds=2,
    seed=3141,
  ).fit()
  let b = DoubleMLLPQ::new(
    v125_lpq_nonlinear(),
    quantile=0.5,
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=1.0e-6)),
  ).fit()
  assert_true(a.coef() == b.coef())
  assert_true(a.se() == b.se())
}

// ---------------------------------------------------------------------------
// G3 -- THE INVARIANT. A config threshold must NOT reach the complier
// floor. If this release had done what upstream does (`lpq.py:166`
// overwrites the scalar with the config threshold), then
// config=0.05 + scalar=1e-6 would put the floor at 0.05 and collapse
// onto the `scalar=0.05` answer.
//
// Measured on the floor-dominant DGP below (n=500, linear propensity
// saturated to [0.05, 0.95]):
//   scalar=0.05 (floor 0.05) coef=4.739060249576877
//   config=0.05 (floor 1e-6) coef=1.123984742821626
// gap 3.615, threshold 0.1.
// ---------------------------------------------------------------------------

///|
fn v125_lpq_floor_dominant() -> DoubleMLLPQData {
  let n = 500
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let z = Array::make(n, 0.0)
  let s = chacha8_rng(2031)
  for i = 0; i < n; i = i + 1 {
    let x0 = s.double() * 2.0 - 1.0
    let x1 = s.double() * 2.0 - 1.0
    x.set(i, 0, x0)
    x.set(i, 1, x1)
    let raw = 0.5 + 1.2 * x0
    let pz = if raw < 0.05 { 0.05 } else if raw > 0.95 { 0.95 } else { raw }
    z[i] = if s.double() < pz { 1.0 } else { 0.0 }
    d[i] = if s.double() < 0.6 { 1.0 } else { 0.0 }
    y[i] = 2.0 + 0.5 * x0 + 1.5 * z[i] + (s.double() - 0.5)
  }
  DoubleMLLPQData::new(x, y, d, z)
}

///|
test "v125_lpq_config_does_not_reach_the_complier_floor" {
  let scalar_only = DoubleMLLPQ::new(
    v125_lpq_floor_dominant(),
    quantile=0.5,
    n_folds=2,
    seed=3141,
    propensity_clip=0.05,
  ).fit()
  let cfg_only = DoubleMLLPQ::new(
    v125_lpq_floor_dominant(),
    quantile=0.5,
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.05)),
  ).fit()
  // DIFFERENT, because the floor differs: 0.05 vs 1e-6. If these ever
  // become equal, the config has leaked into the floor.
  assert_true((scalar_only.coef() - cfg_only.coef()).abs() > 0.1)
}

// ---------------------------------------------------------------------------
// G4 -- the other half of the same invariant. When the caller passes the
// SAME value both ways there is no divergence to observe, and the
// config must win the transform as everywhere else: bit-equal to the
// scalar-only construction.
// ---------------------------------------------------------------------------

///|
test "v125_lpq_config_wins_when_the_scalar_agrees" {
  let scalar_only = DoubleMLLPQ::new(
    v125_lpq_floor_dominant(),
    quantile=0.5,
    n_folds=2,
    seed=3141,
    propensity_clip=0.05,
  ).fit()
  let both = DoubleMLLPQ::new(
    v125_lpq_floor_dominant(),
    quantile=0.5,
    n_folds=2,
    seed=3141,
    propensity_clip=0.05,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.05)),
  ).fit()
  assert_true(both.coef() == scalar_only.coef())
  assert_true(both.se() == scalar_only.se())
}

// ---------------------------------------------------------------------------
// G5 -- the config survives a rebuild of the returned struct.
// ---------------------------------------------------------------------------

///|
test "v125_lpq_config_survives_a_refit" {
  let once = v125_lpq_iso().fit()
  let twice = once.fit()
  let pm_once = once.predictions_m()
  let pm_twice = twice.predictions_m()
  let mut same = true
  for i = 0; i < pm_once.length(); i = i + 1 {
    if pm_once[i] != pm_twice[i] {
      same = false
      break
    }
  }
  assert_true(same)
  assert_true(once.coef() == twice.coef())
}

// ---------------------------------------------------------------------------
// G6 -- the memoize key identifies the model, not one knob.
// ---------------------------------------------------------------------------

///|
test "v125_lpq_cache_key_separates_calibration_methods" {
  let ml = LearnerDispatch::linear_regression()
  let none_cfg = PSProcessorConfig::new(clipping_threshold=0.05)
  let iso_cfg = PSProcessorConfig::new(
    clipping_threshold=0.05,
    calibration_method="isotonic",
  )
  let k_none = hash_hyperparams(
    "lpq",
    ml,
    ml,
    0.05,
    ps_processor_config=Some(none_cfg),
  )
  let k_iso = hash_hyperparams(
    "lpq",
    ml,
    ml,
    0.05,
    ps_processor_config=Some(iso_cfg),
  )
  assert_true(k_none != k_iso)
  // and the pre-v0.125.0 four-argument call still works
  assert_true(hash_hyperparams("lpq", ml, ml, 0.05) != k_none)
}
