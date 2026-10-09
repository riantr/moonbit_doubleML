// v0.127.0 -- `ps_processor_config` on `DoubleMLDID` and
// `DoubleMLDIDBinary`.
//
// Upstream oracle (vendored `doubleml-0.11.4`):
//
//   did_binary.py:123     trimming_threshold=1e-2   (the deprecated scalar)
//   did_binary.py:124     ps_processor_config=None
//   did_binary.py:241     init_ps_processor(config, trimming_rule, threshold)
//   did_binary.py:245     _trimming_threshold = _ps_processor.clipping_threshold
//   did_binary.py:537     adjust_ps(m_hat["preds"], d, cv=smpls)   <- ONE site
//
// So this family has a SINGLE `adjust_ps` call, and the port already had the
// call in the right place since v0.10.0 (`did.mbt`, applied to the
// cross-fitted `m_hat` with the full `d` as the second argument). What was
// missing was that the CALLER could not express a calibration method: the
// estimator stored a bare `PSProcessor` and there was no config route.
//
// EVERY number below was measured before the gate was written. The
// coefficient-level measurements are deliberately modest, and where the
// response is small the gate is written as an EXACT INEQUALITY rather than a
// threshold, because a threshold that tight would be a fiction.

// ---------------------------------------------------------------------------
// Fixtures.
//
// PANEL: a balanced 2-period panel with a SATURATED treatment-assignment
// propensity and a HETEROGENEOUS effect (2.0 for x0 < 0, 0.5 otherwise):
//
//     pi = clamp(0.5 + 2.0 * x0, 0.005, 0.995)
//
// Heterogeneity is what makes trimming non-neutral on the target; a constant
// effect lets the clipped units cancel out (measured: that is exactly what
// happens on the FLAT fixture below).
//
// RAW: a plain single-period `DoubleMLDIDData` with `pi = clamp(0.5 + 1.5*x0,
// 0.01, 0.99)` and a known `theta = 2.0`.
// ---------------------------------------------------------------------------

///|
fn v127_panel(
  n_units : Int,
  p : Int,
  slope : Double,
  seed : Int,
) -> DoubleMLDIDBinaryData {
  let n = n_units * 2
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t : Array[Int] = Array::make(n, 0)
  let g : Array[Int] = Array::make(n, 0)
  let id : Array[Int] = Array::make(n, 0)
  let rng = chacha8_rng(seed)
  for u = 0; u < n_units; u = u + 1 {
    let mut x0 = 0.0
    for j = 0; j < p; j = j + 1 {
      let v = rng.double() * 2.0 - 1.0
      x_flat[2 * u * p + j] = v
      x_flat[(2 * u + 1) * p + j] = v
      if j == 0 {
        x0 = v
      }
    }
    let raw = 0.5 + slope * x0
    let pi = if raw < 0.005 { 0.005 } else if raw > 0.995 { 0.995 } else { raw }
    let is_treated = if rng.double() < pi { 1 } else { 0 }
    for k = 0; k < 2; k = k + 1 {
      let row = 2 * u + k
      t[row] = k
      id[row] = u
      g[row] = is_treated
      d[row] = if is_treated == 1 && k == 1 { 1.0 } else { 0.0 }
      let het = if x0 < 0.0 { 2.0 } else { 0.5 }
      let mut yv = x0 + 0.3 * x_flat[row * p + 1] + 0.05 * (rng.double() - 0.5)
      if k == 1 && is_treated == 1 {
        yv = yv + het
      }
      y[row] = yv
    }
  }
  DoubleMLDIDBinaryData::new(Matrix::from_array(x_flat, n, p), y, d, t, g, id)
}

///|
fn v127_raw(n : Int) -> DoubleMLDIDData raise {
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let rng = chacha8_rng(23)
  for i = 0; i < n; i = i + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    let x1 = rng.double() * 2.0 - 1.0
    x.set(i, 0, x0)
    x.set(i, 1, x1)
    let raw = 0.5 + 1.5 * x0
    let pi = if raw < 0.01 { 0.01 } else if raw > 0.99 { 0.99 } else { raw }
    let di = if rng.double() < pi { 1.0 } else { 0.0 }
    d[i] = di
    y[i] = 1.0 + 0.5 * x0 + 2.0 * di + 0.2 * (rng.double() - 0.5)
  }
  DoubleMLDIDData::new(x, y, d)
}

///|
fn v127_panel_fit(
  data : DoubleMLDIDBinaryData,
  cfg : PSProcessorConfig,
  pclip? : Double = 1.0e-6,
) -> DoubleMLDIDBinary {
  DoubleMLDIDBinary::new(
    data,
    1,
    0,
    1,
    propensity_clip=pclip,
    ps_processor_config=Some(cfg),
    n_folds=2,
    seed=3141,
  ).fit()
}

///|
/// GATE 1 -- the load-bearing one, on the RAW estimator, where the response
/// is large enough to carry a threshold.
///
/// MEASURED: clip 0.01 -> 2.0192176788033085, 0.1 -> 1.9981702250910853,
/// 0.3 -> 1.9966860307321121. Spread 0.0225 against a 0.01 threshold: a
/// mutation that freezes the config to the default gives exactly 0.0.
test "v127_raw_did_clip_moves_the_estimate" {
  let data = v127_raw(800)
  let a = DoubleMLDID::new(
    data,
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=1.0e-2)),
  ).fit()
  let b = DoubleMLDID::new(
    data,
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.3)),
  ).fit()
  assert_true((a.coef() - b.coef()).abs() > 0.01)
  assert_true(a.coef() == 2.0192176788033085)
  assert_true(b.coef() == 1.9966860307321121)
}

///|
/// GATE 2 -- the panel wrapper's coefficient moves far LESS than the raw
/// estimator's (measured spread 1.8e-3 vs 2.25e-2, a 12x damping): the
/// wide-format ATT averages the propensity over reps and the clipped units
/// largely cancel.
///
/// A 1.8e-3 response does not support a threshold gate, so this is written as
/// an EXACT INEQUALITY instead -- which is the strongest form available and
/// has no tolerance to tune. It is also exactly the test that LPQ needed and
/// could not pass: on LPQ the two numbers were EQUAL, and equal is the
/// signature of an inert transform.
test "v127_panel_transform_is_not_inert" {
  let data = v127_panel(2000, 2, 2.0, 7)
  let a = v127_panel_fit(
    data,
    PSProcessorConfig::new(clipping_threshold=1.0e-2),
  )
  let b = v127_panel_fit(data, PSProcessorConfig::new(clipping_threshold=0.3))
  assert_true(a.coef() != b.coef())
  assert_true(a.coef() == 0.5927768888493324)
  assert_true(b.coef() == 0.5909340605719968)
}

///|
/// GATE 3 -- the clip BITES at the configured bound. MEASURED exact-bound
/// counts on the panel (n=2000): 0.01 -> 335/298, 0.1 -> 463/421,
/// 0.3 -> 712/712. A fitted propensity lands EXACTLY on `c` or `1 - c` only
/// because a clip put it there, so counting equality is drift-proof; and
/// counting at the CONFIGURED bound is what makes it a config gate, since
/// with the config ignored the count at 0.3/0.7 would be zero.
test "v127_configured_bound_is_reached_exactly" {
  let data = v127_panel(2000, 2, 2.0, 7)
  let m = v127_panel_fit(data, PSProcessorConfig::new(clipping_threshold=0.3))
  let pm = m.predictions_m()
  let mut at_lo = 0
  let mut at_hi = 0
  for v in pm {
    if v == 0.3 {
      at_lo = at_lo + 1
    } else if v == 0.7 {
      at_hi = at_hi + 1
    }
  }
  assert_true(pm.length() == 2000)
  assert_true(at_lo > 500)
  assert_true(at_hi > 500)
  // the raw estimator bites too: MEASURED 0.3 -> 265/306 of 800.
  let raw = DoubleMLDID::new(
    v127_raw(800),
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.3)),
  ).fit()
  let rpm = raw.predictions_m()
  let mut rlo = 0
  let mut rhi = 0
  for v in rpm {
    if v == 0.3 {
      rlo = rlo + 1
    } else if v == 0.7 {
      rhi = rhi + 1
    }
  }
  assert_true(rlo > 200)
  assert_true(rhi > 200)
}

///|
/// GATE 4 -- isotonic reaches the transform, on BOTH estimators. MEASURED:
/// panel 1367 of 2000 entries moved (max 0.32036907052833014), raw 550 of 800
/// (max 0.3043291193344892).
///
/// This is what actually carries the isotonic route, and it is the same
/// shape as the LPQ and SSM nuisance gates earlier in this series.
test "v127_isotonic_reaches_the_transform" {
  let data = v127_panel(2000, 2, 2.0, 7)
  let base = v127_panel_fit(
    data,
    PSProcessorConfig::new(clipping_threshold=1.0e-2),
  )
  let iso = v127_panel_fit(
    data,
    PSProcessorConfig::new(
      clipping_threshold=1.0e-2,
      calibration_method="isotonic",
    ),
  )
  let a = base.predictions_m()
  let b = iso.predictions_m()
  let mut moved = 0
  let mut maxd = 0.0
  for i = 0; i < a.length(); i = i + 1 {
    let delta = (a[i] - b[i]).abs()
    if delta > 0.0 {
      moved = moved + 1
    }
    if delta > maxd {
      maxd = delta
    }
  }
  assert_true(moved > 1000)
  assert_true(maxd > 0.2)
}

///|
/// GATE 5 -- upstream's `init_ps_processor` precedence: THE CONFIG WINS
/// OUTRIGHT. One threshold, two doors, one value. The `ps_processor` parameter
/// is read only when no config is given.
test "v127_config_wins_over_ps_processor" {
  let data = v127_panel(2000, 2, 2.0, 7)
  let cfg = PSProcessorConfig::new(clipping_threshold=0.1)
  let via_cfg = v127_panel_fit(data, cfg)
  let via_psp = DoubleMLDIDBinary::new(
    data,
    1,
    0,
    1,
    ps_processor=PSProcessor::new(config=cfg),
    n_folds=2,
    seed=3141,
  ).fit()
  assert_true(via_cfg.coef() == via_psp.coef())
  assert_true(via_cfg.se() == via_psp.se())
  assert_true(via_cfg.coef() == 0.5910660619333195)
  // and the config beats a CONFLICTING processor
  let conflict = DoubleMLDIDBinary::new(
    data,
    1,
    0,
    1,
    ps_processor=PSProcessor::new(
      config=PSProcessorConfig::new(clipping_threshold=0.3),
    ),
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.1)),
    n_folds=2,
    seed=3141,
  ).fit()
  assert_true(conflict.coef() == via_cfg.coef())
}

///|
/// GATE 6 -- THE DISTINCTIVE DECISION OF THIS ROUND, pinned exactly.
///
/// Everywhere else in this series the resolution is
//  `resolve_ps_processor_config(cfg, trimming_threshold=propensity_clip)`.
//  Here it is NOT, because on DID the two knobs do DIFFERENT jobs:
//  upstream's deprecated scalar is `trimming_threshold`, default 1e-2
//  (`did_binary.py:123`), and this port's `PSProcessor::new()` also defaults
//  to 1e-2 -- but this port's `propensity_clip` defaults to 1e-6 and is read
//  ONLY by the inner `cross_fit_did`'s `clip_vec`, a numerical-safety clip on
//  the per-rep cross-fit. Redirecting it would silently turn the default
//  public clip from 1e-2 into 1e-6.
//
// So with no config supplied the stored threshold stays 1e-2 no matter what
// `propensity_clip` says. Exact assertions, no tolerance.
test "v127_propensity_clip_does_not_feed_the_config" {
  let data = v127_panel(2000, 2, 2.0, 7)
  let a = DoubleMLDIDBinary::new(
    data,
    1,
    0,
    1,
    propensity_clip=1.0e-6,
    n_folds=2,
    seed=3141,
  )
  let b = DoubleMLDIDBinary::new(
    data,
    1,
    0,
    1,
    propensity_clip=0.3,
    n_folds=2,
    seed=3141,
  )
  // the scalar does NOT leak into the public clip
  assert_true(a.ps_processor_config.clipping_threshold == 1.0e-2)
  assert_true(b.ps_processor_config.clipping_threshold == 1.0e-2)
  // but it DOES still do its own job -- the inner cross-fit clip.
  assert_true(a.fit().coef() != b.fit().coef())
  // and an explicit config still wins over both.
  let c = DoubleMLDIDBinary::new(
    data,
    1,
    0,
    1,
    propensity_clip=1.0e-6,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.3)),
    n_folds=2,
    seed=3141,
  )
  assert_true(c.ps_processor_config.clipping_threshold == 0.3)
  // the raw estimator obeys the same rule
  let r = DoubleMLDID::new(
    v127_raw(800),
    propensity_clip=0.3,
    n_folds=2,
    seed=3141,
  )
  assert_true(r.ps_processor_config.clipping_threshold == 1.0e-2)
}

///|
/// GATE 7 -- the config survives the rebuild and reaches the inner model.
/// `DoubleMLDIDBinary::fit` writes `{ ..self, inner, ... }` and
/// `DoubleMLDID::fit` writes a FULL struct literal, so the latter is the one
/// place a stored config can silently vanish.
test "v127_config_survives_every_rebuild" {
  let data = v127_panel(2000, 2, 2.0, 7)
  let m = DoubleMLDIDBinary::new(
    data,
    1,
    0,
    1,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.1)),
    n_folds=2,
    seed=3141,
  )
  assert_true(m.ps_processor_config.clipping_threshold == 0.1)
  let fitted = m.fit()
  assert_true(fitted.ps_processor_config.clipping_threshold == 0.1)
  assert_true(fitted.inner.ps_processor_config.clipping_threshold == 0.1)
  assert_true(
    fitted.enable_memoize().ps_processor_config.clipping_threshold == 0.1,
  )
  assert_true(
    fitted.disable_memoize().ps_processor_config.clipping_threshold == 0.1,
  )
  assert_true(
    fitted.clear_cache().ps_processor_config.clipping_threshold == 0.1,
  )
  let raw = DoubleMLDID::new(
    v127_raw(800),
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.1)),
  )
  let raw_fitted = raw.fit()
  assert_true(raw_fitted.ps_processor_config.clipping_threshold == 0.1)
}

///|
/// GATE 8 -- BACKWARD COMPATIBILITY, byte-identical, verified by running the
/// same `ps_processor=`-only probe against v0.126.0's `did.mbt` /
// `did_binary.mbt` restored from git HEAD and against this one. Every number
// matched exactly, including all five clip rows on both fixtures and the raw
// estimator's three.
test "v127_default_construction_is_byte_identical" {
  let panel = v127_panel(2000, 2, 2.0, 7)
  let d = DoubleMLDIDBinary::new(panel, 1, 0, 1, n_folds=2, seed=3141).fit()
  assert_true(d.coef() == 0.5927768888493324)
  assert_true(d.se() == 0.011770409674456547)
  let a = DoubleMLDID::new(v127_raw(800), n_folds=2, seed=3141).fit()
  assert_true(a.coef() == 2.0192176788033085)
  assert_true(a.se() == 0.02335850345571139)
  let loose = DoubleMLDIDBinary::new(
    panel,
    1,
    0,
    1,
    ps_processor=PSProcessor::new(
      config=PSProcessorConfig::new(clipping_threshold=0.2),
    ),
    n_folds=2,
    seed=3141,
  ).fit()
  assert_true(loose.coef() == 0.5909443948537486)
}

///|
/// GATE 9 -- a NEGATIVE RESULT, asserted so it stays true and so the next
/// reader does not re-derive the wrong fixture.
///
/// On a FLAT treatment-assignment DGP (slope 0, n=600) the panel ATT is
/// BIT-IDENTICAL at clip 0.01, 0.05, 0.1, 0.2 and 0.3 -- every row reads
/// `coef = 1.2225927742754341`. Nothing reaches the clip, because with
/// treatment independent of the covariates the fitted propensity sits near
/// `mean(d)` in the interior.
///
/// So the saturated + heterogeneous fixture is not decoration: it is the
/// only reason gates 1-4 mean anything.
test "v127_flat_fixture_is_inert_by_construction" {
  let flat = v127_panel(600, 2, 0.0, 11)
  let c1 = v127_panel_fit(
    flat,
    PSProcessorConfig::new(clipping_threshold=1.0e-2),
  )
  let c2 = v127_panel_fit(flat, PSProcessorConfig::new(clipping_threshold=0.1))
  let c3 = v127_panel_fit(flat, PSProcessorConfig::new(clipping_threshold=0.3))
  assert_true(c1.coef() == c2.coef())
  assert_true(c2.coef() == c3.coef())
  assert_true(c1.coef() == 1.2225927742754341)
  // ... but isotonic still reaches it, so "inert" means "the CLIP cannot
  // bite here", not "this fixture is immune to the processor".
  let iso = v127_panel_fit(
    flat,
    PSProcessorConfig::new(
      clipping_threshold=1.0e-2,
      calibration_method="isotonic",
    ),
  )
  assert_true(iso.coef() != c1.coef())
}
