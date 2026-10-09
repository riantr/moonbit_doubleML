///|
// v0.124.0 -- `ps_processor_config` reaches `DoubleMLPQ`.
//
// WHAT THIS RELEASE CHANGES
//
//   * `ps_processor_config?` added to `DoubleMLPQ`, carried through
//     every rebuild of the struct and into the memoize key.
//
//   * `fit_propensity` -- the helper shared by `DoubleMLPQ` and
//     `DoubleMLLPQ` -- routes its transform through
//     `PSProcessor::adjust_ps` instead of an inline `clip_vec`. When
//     `ps_processor_config` is `None` it resolves a default config from
//     the `clip` argument, and under the default config `adjust_ps` is
//     exactly `clip_vec` (max |diff| = 0.0, measured on the v0.121.0
//     oracle fixture). `DoubleMLLPQ` and `DoubleMLQTE` still pass only
//     the deprecated scalar, so they are BYTE-IDENTICAL -- which the
//     full pre-existing suite confirms, and which the harness pins from
//     the other side by mutating the default path.
//
//   * `solve_pq` gained a matching optional parameter. It is `pub`
//     (documented at `quantile.mbt:173`) and is called by PQ, QTE and
//     `quantile_test.mbt`, so the parameter defaults to `None` and no
//     caller had to change.
//
// THE CALIBRATION TARGET IS `treated`, NOT `data.d`
//
// `m` is fitted by regressing `treated` on X, so it is the propensity
// of the indicator being estimated. Upstream `pq.py:410` passes `d`,
// because upstream's `m` is `P(d = 1 | x)`; here `m` is
// `P(d == treatment | x)` and `treated` is `indicator_level(d, treatment)`,
// the 0/1 indicator of exactly that. Both are binary, so `adjust_ps`'s
// treatment precondition holds either way.
//
// ONE SITE, NOT TWO
//
// Upstream `pq.py` adjusts twice: `m_hat_prelim` on the first sample
// split's training rows (`pq.py:365`) and `m_hat["preds"]` on the full
// data (`pq.py:410`). This port's `solve_pq` performs exactly ONE
// propensity cross-fit on the full data (`quantile.mbt:190`), so there
// is one site here and no preliminary stage to route. Recorded rather
// than papered over: this is a genuine structural difference from
// upstream, not a wiring omission.
//
// WHY THE FIXTURE IS EXTREME
//
// v0.122.0 shipped a completely load-free gate and v0.123.0 shipped a
// second one, both because the fixture could not see what it claimed to
// test. So sensitivity was MEASURED first. On the DGP below
// (n=500, treatment=1.0, quantile=0.5, n_folds=2, seed=3141):
//
//   clip=1e-6 (default)  coef=4.210358504497275   se=0.04926765806453813
//   clip=0.05            coef=5.056132161845584   se=0.03231994217636388
//   clip=0.2             coef=5.271971071407467   se=0.03656532151121419
//   isotonic             coef=5.050725021104142   se=0.03277386482502175
//
// The default's propensity-weighted quantile is biased low (4.210)
// because the saturated tails carry tiny `m`; forcing the clip to 0.2
// moves it to 5.272 and isotonic to 5.051. Both difference gates below
// key on a gap of ~1.0 with a threshold of 0.1, i.e. a 10x margin, and
// the isotonic gap is ~20 standard errors.

// ---------------------------------------------------------------------------
// DGP
// ---------------------------------------------------------------------------

///|
/// Binary treatment with a SATURATED propensity (clamped to
/// [0.05, 0.95] before sampling), so the OLS-fitted `m` reaches the
/// clip range. The outcome is a pure location shift of 3.0 under
/// treatment, so the conditional q=0.5 quantile moves with `d` and the
/// estimate is well-identified.
fn v124_pq_data() -> DoubleMLData {
  let n = 500
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let s = chacha8_rng(2030)
  for i = 0; i < n; i = i + 1 {
    let x0 = s.double() * 2.0 - 1.0
    let x1 = s.double() * 2.0 - 1.0
    x.set(i, 0, x0)
    x.set(i, 1, x1)
    let raw = 0.5 + 1.2 * x0
    let pi = if raw < 0.05 { 0.05 } else if raw > 0.95 { 0.95 } else { raw }
    let di = if s.double() < pi { 1.0 } else { 0.0 }
    d[i] = di
    y[i] = 2.0 + 0.5 * x0 + 3.0 * di + (s.double() - 0.5)
  }
  DoubleMLData::new(x, y, d)
}

///|
fn v124_pq_iso() -> DoubleMLPQ {
  DoubleMLPQ::new(
    v124_pq_data(),
    treatment=1.0,
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
// G1 -- the config is REACHABLE and moves the estimate. Measured gap
// 0.840; the threshold is 0.1.
// ---------------------------------------------------------------------------

///|
test "v124_pq_calibration_is_not_cosmetic" {
  let plain = DoubleMLPQ::new(
    v124_pq_data(),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=3141,
  ).fit()
  let iso = v124_pq_iso().fit()
  assert_true((iso.coef() - plain.coef()).abs() > 0.1)
}

// ---------------------------------------------------------------------------
// G2 -- backward compatibility. The pre-v0.124.0 call must still mean
// exactly what it meant: no calibration, clip at the given scalar.
// ---------------------------------------------------------------------------

///|
test "v124_pq_default_construction_is_unchanged" {
  let a = DoubleMLPQ::new(
    v124_pq_data(),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=3141,
  ).fit()
  let b = DoubleMLPQ::new(
    v124_pq_data(),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=1.0e-6)),
  ).fit()
  assert_true(a.coef() == b.coef())
  assert_true(a.se() == b.se())
}

// ---------------------------------------------------------------------------
// G3 -- upstream's `init_ps_processor` precedence on a real estimator:
// the config WINS outright, the scalar is only the fallback.
// ---------------------------------------------------------------------------

///|
test "v124_pq_config_wins_over_the_scalar" {
  let both = DoubleMLPQ::new(
    v124_pq_data(),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=3141,
    propensity_clip=0.05,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.2)),
  ).fit()
  let only_cfg = DoubleMLPQ::new(
    v124_pq_data(),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.2)),
  ).fit()
  assert_true(both.coef() == only_cfg.coef())
  assert_true(both.se() == only_cfg.se())
}

// ---------------------------------------------------------------------------
// G4 -- the deprecated scalar is still LIVE. This is the gate whose
// absence bit v0.122.0: hardcoding the default must fail it. Measured
// gap 1.062, threshold 0.1.
// ---------------------------------------------------------------------------

///|
test "v124_pq_scalar_clip_reaches_the_estimator" {
  let dflt = DoubleMLPQ::new(
    v124_pq_data(),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=3141,
    propensity_clip=1.0e-6,
  ).fit()
  let clipped = DoubleMLPQ::new(
    v124_pq_data(),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=3141,
    propensity_clip=0.2,
  ).fit()
  assert_true((dflt.coef() - clipped.coef()).abs() > 0.1)
}

// ---------------------------------------------------------------------------
// G5 -- the config survives a rebuild. `fit` and `fit_cluster` each
// reconstruct the struct; dropping the field in either means the NEXT
// fit silently loses the calibration while still looking plausible.
// ---------------------------------------------------------------------------

///|
test "v124_pq_config_survives_a_refit" {
  let once = v124_pq_iso().fit()
  let twice = once.fit()
  let plain = DoubleMLPQ::new(
    v124_pq_data(),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=3141,
  ).fit()
  assert_true(twice.coef() == once.coef())
  assert_true(twice.se() == once.se())
  assert_true((once.coef() - plain.coef()).abs() > 0.1)
}

// ---------------------------------------------------------------------------
// G6 -- the memoize key identifies the model, not one knob.
// ---------------------------------------------------------------------------

///|
test "v124_pq_cache_key_separates_calibration_methods" {
  let ml_l = LearnerDispatch::linear_regression()
  let ml_m = LearnerDispatch::linear_regression()
  let none_cfg = PSProcessorConfig::new(clipping_threshold=0.05)
  let iso_cfg = PSProcessorConfig::new(
    clipping_threshold=0.05,
    calibration_method="isotonic",
  )
  let k_none = hash_hyperparams(
    "pq",
    ml_l,
    ml_m,
    0.05,
    ps_processor_config=Some(none_cfg),
  )
  let k_iso = hash_hyperparams(
    "pq",
    ml_l,
    ml_m,
    0.05,
    ps_processor_config=Some(iso_cfg),
  )
  assert_true(k_none != k_iso)
  // and the pre-v0.124.0 four-argument call still works
  assert_true(hash_hyperparams("pq", ml_l, ml_m, 0.05) != k_none)
}

// ---------------------------------------------------------------------------
// G7 -- the SHARED default path is untouched. `DoubleMLLPQ` and
// `DoubleMLQTE` call `fit_propensity` / `solve_pq` WITHOUT a config, so
// this release must not move them, and the `None` branch must still
// resolve its threshold from the `clip` ARGUMENT rather than from a
// hardcoded constant.
//
// There is deliberately NO direct gate on `fit_propensity` itself: it is
// file-private, and making it `pub` just to reach it would widen the
// public API for an internal helper. The stronger statement is made
// from the other side by the harness, which mutates the `None` branch to
// ignore `clip` entirely -- every pre-existing LPQ / QTE / PQ test then
// has to catch it, so all ~950 tests stand behind this claim instead of
// the four rows a direct unit test would have used.
// ---------------------------------------------------------------------------

///|
test "v124_pq_default_resolves_the_threshold_from_the_scalar" {
  // The same clip reached two ways: the deprecated scalar, and a config
  // carrying that same threshold. Under the default resolution these
  // are the same object, so this is bit-equality -- and it fails the
  // moment the `None` branch stops reading `clip`.
  let via_scalar = DoubleMLPQ::new(
    v124_pq_data(),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=3141,
    propensity_clip=0.2,
  ).fit()
  let via_cfg = DoubleMLPQ::new(
    v124_pq_data(),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.2)),
  ).fit()
  assert_true(via_scalar.coef() == via_cfg.coef())
  assert_true(via_scalar.se() == via_cfg.se())
}

// ---------------------------------------------------------------------------
// G8 / G9 -- FOUND BY THE HARNESS, third instance of the same mistake.
//
// `v124-fit-propensity-ignores-the-clip-argument` -- freezing the
// `None` branch to the default 1e-6 -- SURVIVED 961/961. The reason was
// not a weak gate: NO TEST ANYWHERE passes a non-default
// `propensity_clip` to `DoubleMLLPQ` or `DoubleMLQTE`. Every one of
// their tests runs at the default, so ignoring the argument was
// literally indistinguishable from honouring it.
//
// `propensity_clip` is a user-facing parameter on both estimators, so
// this is a real coverage gap rather than a harness artefact. MEASURED
// on the DGPs below that the parameter is live:
//
//   LPQ clip=1e-6 (default)  coef=1.123984742821626  se=156.07090279138626
//   LPQ clip=0.05            coef=4.739060249576877  se=  4.140929971656726
//   LPQ clip=0.2             coef=4.739060249576877  se=  2.4472021260225816
//
//   QTE clip=1e-6 (default)  c0  =2.2283675671949696 se0=0.12339938991061847
//   QTE clip=0.05            c0  =3.129274728439124  se0=0.0359513925519582
//   QTE clip=0.2             c0  =3.271472429652198  se0=0.024227336475237504
//
// LPQ's gap is 3.615 and QTE's is 0.901, so the thresholds below are 0.1
// and 0.1 -- 36x and 9x margins. With these two gates present the
// mutation is KILLED, and the "LPQ and QTE are byte-identical" claim
// rests on something observable.
//
// Worth noting what LPQ's numbers say: `clip=0.05` and `clip=0.2` give
// an IDENTICAL coefficient (4.739060249576877) but different standard
// errors. `propensity_clip` is overloaded on LPQ -- it also floors the
// estimated complier share (`lpq.mbt`: `if comp.abs() <
// self.propensity_clip`), which saturates the bisection once the floor
// stops binding. That overload is pre-existing and is NOT touched here;
// it is flagged for its own round.
// ---------------------------------------------------------------------------

///|
fn v124_lpq_data() -> DoubleMLLPQData {
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
    // LPQ's `m` is the propensity of the INSTRUMENT z, so saturate that
    let raw = 0.5 + 1.2 * x0
    let pz = if raw < 0.05 { 0.05 } else if raw > 0.95 { 0.95 } else { raw }
    z[i] = if s.double() < pz { 1.0 } else { 0.0 }
    d[i] = if s.double() < 0.6 { 1.0 } else { 0.0 }
    y[i] = 2.0 + 0.5 * x0 + 1.5 * z[i] + (s.double() - 0.5)
  }
  DoubleMLLPQData::new(x, y, d, z)
}

///|
fn v124_qte_data() -> DoubleMLData {
  let n = 500
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let s = chacha8_rng(2032)
  for i = 0; i < n; i = i + 1 {
    let x0 = s.double() * 2.0 - 1.0
    let x1 = s.double() * 2.0 - 1.0
    x.set(i, 0, x0)
    x.set(i, 1, x1)
    let raw = 0.5 + 1.2 * x0
    let pi = if raw < 0.05 { 0.05 } else if raw > 0.95 { 0.95 } else { raw }
    d[i] = if s.double() < pi { 1.0 } else { 0.0 }
    y[i] = 2.0 + 0.5 * x0 + 3.0 * d[i] + (s.double() - 0.5)
  }
  DoubleMLData::new(x, y, d)
}

///|
test "v124_lpq_propensity_clip_is_live" {
  let dflt = DoubleMLLPQ::new(
    v124_lpq_data(),
    quantile=0.5,
    n_folds=2,
    seed=3141,
    propensity_clip=1.0e-6,
  ).fit()
  let clipped = DoubleMLLPQ::new(
    v124_lpq_data(),
    quantile=0.5,
    n_folds=2,
    seed=3141,
    propensity_clip=0.05,
  ).fit()
  // measured 3.615
  assert_true((dflt.coef() - clipped.coef()).abs() > 0.1)
}

///|
test "v124_qte_propensity_clip_is_live" {
  let dflt = DoubleMLQTE::new(
    v124_qte_data(),
    quantiles=[0.5],
    n_folds=2,
    seed=3141,
    propensity_clip=1.0e-6,
  ).fit()
  let clipped = DoubleMLQTE::new(
    v124_qte_data(),
    quantiles=[0.5],
    n_folds=2,
    seed=3141,
    propensity_clip=0.05,
  ).fit()
  // measured 0.901
  assert_true((dflt.coefs()[0] - clipped.coefs()[0]).abs() > 0.1)
}
