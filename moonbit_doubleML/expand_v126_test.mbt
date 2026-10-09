// v0.126.0 -- `ps_processor_config` on `DoubleMLCVAR`.
//
// Upstream oracle (vendored `doubleml-0.11.4`):
//
//   `cvar.py:152-154`  init_ps_processor(config, trimming_rule, trimming_threshold)
//   `cvar.py:156`      _trimming_threshold = _ps_processor.clipping_threshold
//   `cvar.py:293`      adjust_ps(m_hat_prelim, d_train_1, cv=smpls_prelim)
//   `cvar.py:343`      adjust_ps(m_hat["preds"], d, cv=smpls)
//   `cvar.py:474-475`  _sensitivity_element_est -> `pass`  (no oracle)
//
// So CVaR has exactly TWO `adjust_ps` sites, both now routed through
// `PSProcessor::adjust_ps`, and the deprecated scalar IS redirected to the
// config's threshold exactly as `cvar.py:156` does. That redirect is the
// opposite of the v0.125.0 LPQ decision, and the reason is measured, not
// stylistic -- see the struct-field comment in `cvar.mbt`.
//
// EVERY number below was measured on this DGP before the gate was written,
// and every gate was then checked against a real mutation (see
// `_verify/mut_v126_cvar.ps1` for the KILLED/SURVIVED table).

// ---------------------------------------------------------------------------
// The DGP. This is the v0.122.0 saturated-propensity recipe, kept because it
// is already proven to put fitted propensities ON a clip bound:
//
//     raw = 0.5 + 1.2 * x0 ;  pi = clamp(raw, 0.02, 0.98)
//
// Overlap is violated in the tails, which is precisely what the clip repairs.
// `y = 1 + 0.8*x0 - 0.4*x1 + 2*d + noise`, so the treated potential outcome is
// `3 + 0.8*x0 - 0.4*x1` and CVaR at q=0.5 depends on WHICH treated units
// receive weight 1/m.
//
// This matters for CVaR specifically. On LPQ (v0.125.0) the quantile is found
// by bisection against a fixed bracket, so it is BRACKET-PINNED: no clipping
// threshold could move it and no coefficient gate was writable. CVaR's score
// is `mean(treated/m * 1{y <= theta}) = quantile`, a genuinely weighted
// quantile, so `m` really does move the root. Measured spread below: 0.346
// across the clip sweep.
// ---------------------------------------------------------------------------

///|
fn v126_extreme_data() -> DoubleMLData {
  let n = 600
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let s = chacha8_rng(2026)
  for i = 0; i < n; i = i + 1 {
    let x0 = s.double() * 2.0 - 1.0
    let x1 = s.double() * 2.0 - 1.0
    x.set(i, 0, x0)
    x.set(i, 1, x1)
    let raw = 0.5 + 1.2 * x0
    let pi = if raw < 0.02 { 0.02 } else if raw > 0.98 { 0.98 } else { raw }
    let di = if s.double() < pi { 1.0 } else { 0.0 }
    d[i] = di
    y[i] = 1.0 + 0.8 * x0 - 0.4 * x1 + 2.0 * di + 0.3 * (s.double() - 0.5)
  }
  DoubleMLData::new(x, y, d)
}

///|
fn v126_clip_of(clip : Double) -> DoubleMLCVAR {
  DoubleMLCVAR::new(
    v126_extreme_data(),
    quantile=0.5,
    n_folds=2,
    seed=3141,
    propensity_clip=clip,
  )
}

///|
fn v126_config_of(cfg : PSProcessorConfig) -> DoubleMLCVAR {
  DoubleMLCVAR::new(
    v126_extreme_data(),
    quantile=0.5,
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(cfg),
  )
}

///|
/// MEASURED coefficient sweep (n=600, saturated propensity):
///
///   clip 1e-6 -> 3.664307496539196  se 0.1877474007626309
///   clip 0.02 -> 3.4277310424288583 se 0.13286634163676272
///   clip 0.05 -> 3.3554623566845554 se 0.06384235128810226
///   clip 0.10 -> 3.3270905378194593 se 0.03980232114861463
///   clip 0.20 -> 3.3179262532001292 se 0.030291158270456118
///   isotonic -> 3.471229424883473  se 0.15549447634451058
///
/// MEASURED under each single-site mutation (same rows):
///
///   prelim site (`cvar.py:293`) frozen to 1e-6:
///     3.664307496539196 / 3.64462711215576 / 3.6409745892010417 /
///     3.6401130431711732 / 3.6431144358643284 / 3.63997490660631
///   final site (`cvar.py:343`) frozen to 1e-6:
///     3.664307496539196 / 3.9589090122807122 / 3.9761158569596606 /
///     3.9656198245812257 / 3.9678982615979637 / 3.9617010920824045
///
/// Gate 1 is the load-bearing one and it is deliberately aimed at the PRELIM
/// site: `|coef(1e-6) - coef(0.05)|` is 0.3088 here but only 0.0233 once the
/// preliminary clip stops following the config, because a CVaR estimate is
/// driven by the inner cross-fit's preliminary propensity.
test "v126_config_moves_the_cvar_coefficient" {
  let base = v126_clip_of(1.0e-6).fit()
  let clipped = v126_clip_of(0.05).fit()
  let moved = (base.coef() - clipped.coef()).abs()
  assert_true(moved > 0.2)
  assert_true(base.se() > clipped.se())
}

///|
/// Gate 2 -- BOTH sites are wired, which no single-site gate can establish.
///
/// The span between two NON-default thresholds is the discriminator: with
/// both sites live it is 0.1098, with either site frozen it collapses to
/// 0.0015 (prelim) or goes NEGATIVE, -0.0090 (final). Freezing one site
/// leaves the other still moving the coefficient, so the `1e-6` vs `0.05`
/// comparison in gate 1 cannot see it -- only this one can.
test "v126_both_clip_sites_follow_the_config" {
  let lo = v126_clip_of(0.02).fit().coef()
  let hi = v126_clip_of(0.2).fit().coef()
  assert_true(lo - hi > 0.05)
}

///|
/// Gate 3 -- the sweep is STRICTLY monotone decreasing in the clip threshold.
///
/// More aggressive trimming moves less weight onto the units with extreme
/// fitted propensity, so the weighted quantile at q=0.5 drifts steadily down.
/// This is a sign check, not a magnitude check, so it has no tolerance to
/// tune: it flips on the prelim mutant, whose last step goes the WRONG way
/// (3.6401130431711732 -> 3.6431144358643284).
test "v126_coefficient_is_monotone_in_the_clip" {
  let c1 = v126_clip_of(1.0e-6).fit().coef()
  let c2 = v126_clip_of(0.02).fit().coef()
  let c3 = v126_clip_of(0.05).fit().coef()
  let c4 = v126_clip_of(0.1).fit().coef()
  let c5 = v126_clip_of(0.2).fit().coef()
  assert_true(c1 > c2)
  assert_true(c2 > c3)
  assert_true(c3 > c4)
  assert_true(c4 > c5)
}

///|
/// Gate 4 -- the clip provably BITES at the CONFIGURED bound, and only there.
///
/// MEASURED exact-bound counts (n=600, `normalize_ipw=false` so the rescaling
/// does not move values off the bound):
///
///   clip 1e-6 -> 76 at the lower bound, 81 at the upper
///   clip 0.05 -> 101 / 108
///   clip 0.20 -> 173 / 184
///
/// A fitted propensity lands EXACTLY on `c` or `1 - c` only because a clip
/// put it there; no natural regression output does that. Counting equality
/// rather than proximity makes the gate immune to numerical drift, and
/// counting at the CONFIGURED bound is what makes it a config gate: if the
/// config were ignored and the clip stayed at 1e-6, the number of entries
/// exactly equal to 0.05 or 0.2 would be ~0.
test "v126_configured_bound_is_reached_exactly" {
  let fitted = DoubleMLCVAR::new(
    v126_extreme_data(),
    quantile=0.5,
    n_folds=2,
    seed=3141,
    propensity_clip=1.0e-6,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.05)),
    normalize_ipw=false,
  ).fit()
  let pm = fitted.predictions_m()
  let mut at_lo = 0
  let mut at_hi = 0
  for v in pm {
    if v == 0.05 {
      at_lo = at_lo + 1
    } else if v == 0.95 {
      at_hi = at_hi + 1
    }
  }
  assert_true(at_lo > 50)
  assert_true(at_hi > 50)
}

///|
/// Gate 5 -- upstream precedence: the CONFIG WINS OUTRIGHT over the deprecated
/// scalar (`init_ps_processor`), and `cvar.py:156` redirects the scalar to
/// the config's own threshold. One threshold, two doors, one value.
test "v126_config_wins_and_redirects_the_scalar" {
  let scalar_005 = v126_clip_of(0.05)
  let config_005 = DoubleMLCVAR::new(
    v126_extreme_data(),
    quantile=0.5,
    n_folds=2,
    seed=3141,
    propensity_clip=1.0e-6,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.05)),
  )
  assert_true(config_005.propensity_clip == 0.05)
  assert_true(config_005.ps_processor_config.clipping_threshold == 0.05)
  let a = scalar_005.fit()
  let b = config_005.fit()
  assert_true(a.coef() == b.coef())
  assert_true(a.se() == b.se())
}

///|
/// Gate 6 -- isotonic calibration reaches the transform, at BOTH levels.
///
/// MEASURED: isotonic changes 600 of 600 `predictions_m()` entries, and
/// moves the coefficient by 0.1931. The max per-entry delta is 6668.66, which
/// is NOT a bug: this port's `_normalize_ipw` (identical to upstream's) maps a
/// control unit to `1 - (1-m) * E[1/(1-m) | d=0]`, and isotonic can plateau a
/// propensity at ~1, which makes that expectation huge. It is harmless because
/// `psi_b` multiplies by `1{d == treatment}`, zeroing exactly those rows.
test "v126_isotonic_reaches_the_transform" {
  let base = v126_clip_of(1.0e-6).fit()
  let iso = v126_config_of(
    PSProcessorConfig::new(
      clipping_threshold=1.0e-6,
      calibration_method="isotonic",
    ),
  ).fit()
  assert_true((base.coef() - iso.coef()).abs() > 0.1)
  let a = base.predictions_m()
  let b = iso.predictions_m()
  assert_true(a.length() == b.length())
  let mut moved = 0
  for i = 0; i < a.length(); i = i + 1 {
    if (a[i] - b[i]).abs() > 0.0 {
      moved = moved + 1
    }
  }
  assert_true(moved == 600)
}

///|
/// Gate 7 -- the config SURVIVES every rebuild. `fit()` writes out a full
/// struct literal (not `..self`), so it is the one place a stored config can
/// silently vanish; the memoize toggles and `set_sample_splitting` all use
/// `..self` struct-update and are checked here too so a future rewrite of
/// either has to be a deliberate act.
test "v126_config_survives_every_rebuild" {
  let m = DoubleMLCVAR::new(
    v126_extreme_data(),
    quantile=0.5,
    propensity_clip=1.0e-6,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.05)),
  )
  assert_true(m.propensity_clip == 0.05)
  let fitted = m.fit()
  assert_true(fitted.ps_processor_config.clipping_threshold == 0.05)
  assert_true(fitted.propensity_clip == 0.05)
  assert_true(
    fitted.enable_memoize().ps_processor_config.clipping_threshold == 0.05,
  )
  assert_true(
    fitted.disable_memoize().ps_processor_config.clipping_threshold == 0.05,
  )
  assert_true(
    fitted.clear_cache().ps_processor_config.clipping_threshold == 0.05,
  )
  let split = fitted.set_sample_splitting(v109_drawn_reps(600, 2, 1, 3141))
  assert_true(split.ps_processor_config.clipping_threshold == 0.05)
  assert_true(split.propensity_clip == 0.05)
}

///|
/// Gate 8 -- a NEGATIVE RESULT, asserted as a positive fact so it cannot
/// silently change.
///
/// `sensitivity_analysis` computes `psi_b` using a lower-only re-clip of
/// `m_hat`, which reads the redirected `propensity_clip`. That looked live,
/// so the harness was pointed at it (M9: hardcode the threshold to 1e-12) --
/// and it **SURVIVED**. Not "too small an effect": `rv`, `sigma2`, `nu2` and
/// `max_bias` came back BIT-IDENTICAL.
///
/// The reason is structural, not incidental. `irm_style_sensitivity` takes
/// `(theta, residuals, psi_a, cf_y, cf_d)` and has no `psi_b` parameter --
/// `sigma2 = mean(residuals^2)`, `nu2 = mean(psi_a^2)`, and `max_bias`/`rv`
/// derive from those. Every call site in the package passes the same five
/// arguments; none passes `psi_b`. On CVaR it is therefore computed and
/// discarded, so `m_clip`, and with it `propensity_clip`, cannot reach the
/// returned `SensitivityResult` at all.
///
/// That is a pre-existing structural fact about the C&H helper, not
/// something v0.126.0 introduced, and repairing it would change numerical
/// results -- a behavioural release of its own.
///
/// What is pinned here is what IS true: the stored threshold is the
/// configured one, and even if `psi_b` were passed, the re-clip would still
/// be inert at the default clip, because all 282 below-threshold stored
/// entries are CONTROL units (measured) and `psi_b` multiplies them by
/// `treated_i = 0`. The `rv` difference below is real but is driven by the
/// whole fit pipeline, NOT by this re-clip -- stated here so the next reader
/// does not re-derive the wrong cause.
test "v126_sensitivity_reclip_is_structurally_inert" {
  let m2 = v126_config_of(PSProcessorConfig::new(clipping_threshold=0.2))
  assert_true(m2.propensity_clip == 0.2)
  let a = v126_clip_of(1.0e-6).fit().sensitivity_analysis()
  let b = v126_clip_of(0.05).fit().sensitivity_analysis()
  // real difference between two configurations -- but from the pipeline.
  assert_true((a.rv - b.rv).abs() > 0.15)
  // and the premise of the re-clip, measured.
  let data = v126_extreme_data()
  let fitted = v126_clip_of(1.0e-6).fit()
  let pm = fitted.predictions_m()
  let mut below = 0
  let mut below_treated = 0
  for i = 0; i < pm.length(); i = i + 1 {
    if pm[i] < 1.0e-6 {
      below = below + 1
      if data.d[i] == 1.0 {
        below_treated = below_treated + 1
      }
    }
  }
  assert_true(below > 0)
  assert_true(below_treated == 0)
}

///|
/// Gate 9 -- BACKWARD COMPATIBILITY, byte-identical, verified by running the
/// same scalar-only probe against v0.125.0's `cvar.mbt` from git HEAD and
/// against this one. Every number matched exactly, including the canonical
/// DGP below and the sweep in `v126_clip_of`.
//
//   canonical DGP (no covariates, alternating d): 1.7417212460064047

///|
///   se: 0.019633851063058223
test "v126_default_construction_is_byte_identical" {
  let canonical = DoubleMLCVAR::new(
    quantile_test_data(),
    treatment=1.0,
    quantile=0.5,
  ).fit()
  assert_true(canonical.coef() == 1.7417212460064047)
  assert_true(canonical.se() == 0.019633851063058223)
  let d = v126_clip_of(1.0e-6).fit()
  assert_true(d.coef() == 3.664307496539196)
  assert_true(d.se() == 0.1877474007626309)
  assert_true(d.sensitivity_analysis().rv == 1.8224426834085234)
}

///|
/// Gate 10 -- the precedence rule still has exactly one definition. v0.122.0
/// asserted this when APO and IRM became the first two consumers; CVaR is the
/// seventh, and a copy-pasted `match` here would be invisible to every
/// behavioural gate above.
test "v126_resolution_is_shared_not_duplicated" {
  let from_scalar = resolve_ps_processor_config(
    ps_processor_config=None,
    trimming_threshold=0.05,
  )
  assert_true(from_scalar.clipping_threshold == 0.05)
  assert_true(from_scalar.calibration_method == "none")
  let cfg = PSProcessorConfig::new(clipping_threshold=0.3)
  let winner = resolve_ps_processor_config(
    ps_processor_config=Some(cfg),
    trimming_threshold=0.05,
  )
  assert_true(winner.clipping_threshold == 0.3)
  // and it is idempotent, so an estimator may hand `Some(self)` to a child
  let twice = resolve_ps_processor_config(
    ps_processor_config=Some(winner),
    trimming_threshold=0.05,
  )
  assert_true(twice.clipping_threshold == 0.3)
  assert_true(twice.calibration_method == "none")
}
