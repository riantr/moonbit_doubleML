// v0.128.0 -- `ps_processor_config` on `DoubleMLDIDCSBinary`,
// `DoubleMLDIDCrossSection` and `DoubleMLDIDCS`.
//
// Upstream oracle (vendored `doubleml-0.11.4`):
//
//   did_cs_binary.py:123   trimming_threshold=1e-2   (deprecated scalar)
//   did_cs_binary.py:230   init_ps_processor(config, trimming_rule, threshold)
//   did_cs_binary.py:516   adjust_ps(m_hat["preds"], d, cv=smpls)   <- ONE site
//   did_cs.py              NO adjust_ps call at all -- a pure delegator
//
// So `DoubleMLDIDCSBinary` mirrors `DoubleMLDID`: one site, and the same
// resolution rule (the config wins outright; with no config the fallback is
// the `ps_processor` parameter's own config, NOT `propensity_clip`).
// `DoubleMLDIDCrossSection` has no upstream counterpart in 0.11.4 but already
// used the real `data.d`, so it keeps the same shape. `DoubleMLDIDCS` has no
// transform of its own and is wired purely so the knob is reachable
// end-to-end.
//
// MEASURED before any gate was written (see the `v128_*` numbers below), and
// every number was re-measured against v0.127.0 to prove byte-identity.

// ---------------------------------------------------------------------------
// Staggered-adoption fixture: 3 cohorts x 3 periods. Cohort 0 is
// never-treated; cohorts 1-2 are treated from period 1 onward, with the
// assignment probability driven through a SATURATED score
// (`pi = clamp(0.5 + 1.4*x0, 0.02, 0.98)`) so a fitted propensity can reach a
// clip bound.
// ---------------------------------------------------------------------------

///|
fn v128_cs_data(n_per_cohort : Int, p : Int, seed : Int) -> DoubleMLDIDCSData {
  let cohort_count = 3
  let n_periods = 3
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  let rng = chacha8_rng(seed)
  for u = 0; u < n_units; u = u + 1 {
    let cohort = u / n_per_cohort
    let xu : Array[Double] = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      xu[j] = rng.double() * 2.0 - 1.0
    }
    let raw = 0.5 + 1.4 * xu[0]
    let pi = if raw < 0.02 { 0.02 } else if raw > 0.98 { 0.98 } else { raw }
    let is_treated = if cohort > 0 {
      if rng.double() < pi {
        1
      } else {
        0
      }
    } else {
      0
    }
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = xu[j]
      }
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = is_treated
      d[row] = if is_treated == 1 && k >= 1 { 1.0 } else { 0.0 }
      let mut yv = xu[0] + 0.4 * xu[1] + 0.15 * (rng.double() - 0.5)
      if is_treated == 1 && k >= 1 {
        yv = yv + 1.0
      }
      y[row] = yv
    }
  }
  DoubleMLDIDCSData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
}

///|
fn v128_cs_fit(
  data : DoubleMLDIDCSData,
  cfg : PSProcessorConfig,
) -> DoubleMLDIDCSBinary {
  DoubleMLDIDCSBinary::new(
    data,
    1,
    0,
    2,
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(cfg),
  ).fit()
}

///|
/// GATE 1 -- the config reaches the transform, at BOTH levels.
///
/// MEASURED on the staggered fixture (n=720 evaluated rows):
/// exact-bound counts rise 100 -> 184 -> 373 as the clip goes
/// 0.01 -> 0.1 -> 0.3, and the coefficient is NOT pinned (it moves at the
/// 3rd decimal, so this is an exact inequality, the same reasoning as
/// `v127_panel_transform_is_not_inert`).
test "v128_cs_binary_config_reaches_the_transform" {
  let data = v128_cs_data(120, 2, 5)
  let a = v128_cs_fit(data, PSProcessorConfig::new(clipping_threshold=1.0e-2))
  let c = v128_cs_fit(data, PSProcessorConfig::new(clipping_threshold=0.3))
  assert_true(a.coef() != c.coef())
  let pm = c.predictions_m()
  let mut at_lo = 0
  let mut at_hi = 0
  for v in pm {
    if v == 0.3 {
      at_lo = at_lo + 1
    } else if v == 0.7 {
      at_hi = at_hi + 1
    }
  }
  assert_true(pm.length() == 720)
  assert_true(at_lo > 300)
  // the lower bound bites hard, the upper one barely at all -- recorded so a
  // future reader does not read the tiny at_hi as a broken gate.
  assert_true(at_hi > 0)
  assert_true(a.coef() == 0.9909760034277681)
  assert_true(c.coef() == 0.9912225682002018)
}

///|
/// GATE 2 -- isotonic reaches the transform. MEASURED coefficient
/// 0.9931792566957861 against a default of 0.9909760034277681.
test "v128_cs_binary_isotonic_reaches_the_transform" {
  let data = v128_cs_data(120, 2, 5)
  let base = v128_cs_fit(
    data,
    PSProcessorConfig::new(clipping_threshold=1.0e-2),
  )
  let iso = v128_cs_fit(
    data,
    PSProcessorConfig::new(
      clipping_threshold=1.0e-2,
      calibration_method="isotonic",
    ),
  )
  let a = base.predictions_m()
  let b = iso.predictions_m()
  let mut moved = 0
  for i = 0; i < a.length(); i = i + 1 {
    if (a[i] - b[i]).abs() > 0.0 {
      moved = moved + 1
    }
  }
  assert_true(moved > 0)
  assert_true(iso.coef() == 0.9931792566957861)
  assert_true(base.coef() != iso.coef())
}

///|
/// GATE 3 -- the DID resolution rule: `propensity_clip` must NOT feed the
/// config. Upstream's deprecated scalar here is `trimming_threshold=1e-2`
/// (`did_cs_binary.py:123`); this port's `propensity_clip` defaults to 1e-6
/// and is the inner `clip_vec` safety clip. Exact assertions.
test "v128_propensity_clip_does_not_feed_the_config" {
  let data = v128_cs_data(120, 2, 5)
  let a = DoubleMLDIDCSBinary::new(
    data,
    1,
    0,
    2,
    propensity_clip=1.0e-6,
    n_folds=2,
    seed=3141,
  )
  let b = DoubleMLDIDCSBinary::new(
    data,
    1,
    0,
    2,
    propensity_clip=0.3,
    n_folds=2,
    seed=3141,
  )
  assert_true(a.ps_processor_config.clipping_threshold == 1.0e-2)
  assert_true(b.ps_processor_config.clipping_threshold == 1.0e-2)
  // ... but it still does its own job, so the two differ in output
  assert_true(a.fit().coef() != b.fit().coef())
  // an explicit config wins over both
  let c = DoubleMLDIDCSBinary::new(
    data,
    1,
    0,
    2,
    propensity_clip=1.0e-6,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.3)),
    n_folds=2,
    seed=3141,
  )
  assert_true(c.ps_processor_config.clipping_threshold == 0.3)
}

///|
/// GATE 4 -- the config wins outright over `ps_processor`, and survives the
/// rebuild. `DoubleMLDIDCSBinary::fit` writes `{ ..self, ... }`, so the
/// wrapper side is structurally safe; the resolved config must still be
/// reachable on the returned model.
test "v128_cs_binary_config_wins_and_survives" {
  let data = v128_cs_data(120, 2, 5)
  let cfg = PSProcessorConfig::new(clipping_threshold=0.1)
  let via_cfg = v128_cs_fit(data, cfg)
  let via_psp = DoubleMLDIDCSBinary::new(
    data,
    1,
    0,
    2,
    n_folds=2,
    seed=3141,
    ps_processor=PSProcessor::new(config=cfg),
  ).fit()
  assert_true(via_cfg.coef() == via_psp.coef())
  assert_true(via_cfg.se() == via_psp.se())
  assert_true(via_cfg.coef() == 0.9909907550255894)
  // a CONFLICTING processor loses
  let conflict = DoubleMLDIDCSBinary::new(
    data,
    1,
    0,
    2,
    n_folds=2,
    seed=3141,
    ps_processor=PSProcessor::new(
      config=PSProcessorConfig::new(clipping_threshold=0.3),
    ),
    ps_processor_config=Some(cfg),
  ).fit()
  assert_true(conflict.coef() == via_cfg.coef())
  // survives the rebuild and the memoize toggles
  let m = DoubleMLDIDCSBinary::new(
    data,
    1,
    0,
    2,
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(cfg),
  )
  let fitted = m.fit()
  assert_true(fitted.ps_processor_config.clipping_threshold == 0.1)
  assert_true(
    fitted.enable_memoize().ps_processor_config.clipping_threshold == 0.1,
  )
}

///|
/// GATE 5 -- THE NUISANCE IS A GROUP PROPENSITY, AND THAT IS UPSTREAM.
///
/// v0.129.0 REWRITES THIS GATE. It was originally named
/// `v128_did_cs_binary_nuisance_is_a_group_propensity` and presented the fact
/// as a DIVERGENCE from upstream -- "upstream regresses `ml_m` on `d`
/// (`did_cs_binary.py:504-513`) and adjusts with `d` (`:516`)". That was
/// WRONG, and it was wrong in the most expensive way possible: it was right
/// about the measurement and wrong about the reference.
///
/// THE MEASUREMENT WAS FINE. On the staggered fixture, restricted to the
/// estimator's own `(g == 1 or never-treated) x (t in {0, 2})` subset,
/// **109 of 720** rows have `d != g_indicator`, and the two OLS fits of G and
/// of D on X differ by up to **0.365** in predicted probability. The two
/// candidate nuisances really are different functions.
///
/// THE REFERENCE WAS WRONG. Upstream's local variable at those lines is
/// spelled `d`, but it is not the data column `d`:
///
///   did_cs_binary.py:179   self._g_data_subset = data_subset["G_indicator"]
///   did_cs_binary.py:472   _, d = check_X_y(x, self._g_data_subset, ...)
///                          # and that very line's trailing comment says
///                          # "(d is the G_indicator)"
///
/// CONFIRMED AT RUNTIME, not by re-reading names. Instrumenting the vendored
/// upstream 0.11.4 and capturing the arguments at both call sites, on this
/// port's own fixture (`_verify/_oracle_1290.py`):
///     ml_m regression target == subset G_indicator   -> True
///     ml_m regression target == subset d            -> False
///     adjust_ps calibration target == subset G_indicator -> True
///     adjust_ps calibration target == subset d          -> False
/// with sum 218 = mean(G)*720 vs sum 109 = mean(d)*720, so the check is not
/// vacuous -- the two candidates are numerically far apart.
///
/// So this port was ALWAYS faithful. v0.129.0 briefly "fixed" it to `row.d`
/// and has reverted that; the behaviour is unchanged from v0.128.0. The
/// fixture premise below is kept because it is what makes the next gate
/// discriminating rather than vacuous.
test "v129_cs_binary_nuisance_is_a_group_propensity_like_upstream" {
  let data = v128_cs_data(120, 2, 5)
  let cohort_count = 3
  let n_periods = 3
  let n_units = 120 * cohort_count
  let n = n_units * n_periods
  let mut subset = 0
  let mut differ = 0
  for u = 0; u < n_units; u = u + 1 {
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      let tv = data.t[row]
      if tv != 0 && tv != 2 {
        continue
      }
      let gv = data.g[row]
      let gi = if gv == 1 { 1.0 } else { 0.0 }
      let ci = if gv == 0 { 1.0 } else { 0.0 }
      if gi + ci != 1.0 {
        continue
      }
      subset = subset + 1
      if data.d[row] != gi {
        differ = differ + 1
      }
    }
  }
  assert_true(n == 1080)
  assert_true(subset == 720)
  assert_true(differ > 100)
  assert_true(differ < subset)
}

///|
/// GATE 5b -- THE DISCRIMINATING GATE. v0.128.0's GATE 5 only pinned a
/// fixture property; nothing made the CODE answer to it. This one does.
///
/// The invariant upstream implies is strong and exactly checkable: NOTHING in
/// `DoubleMLDIDCSBinary`'s fit path reads `data.d`. Both nuisances -- the
/// `ml_m` regression target and the `adjust_ps` calibration target -- are
/// defined on G, and the fold strata are `g_indicator + 2*t_indicator`. So if
/// you scramble the treatment column and leave everything else alone, the
/// estimate must come back BIT-IDENTICAL.
///
/// A treatment-based nuisance would move; a group-based one cannot. This is
/// the gate that would have caught the v0.129.0 "fix": it turns the reverted
/// change from an opinion into a test failure.
///
/// MEASURED: scrambling `d` to `1 - d` (and to a coin flip) changes neither
/// `coef()` nor `se()` nor any of the 720 `predictions_m()` entries, while the
/// scrambled column really does differ from `g` on the 109 rows above.
test "v129_cs_binary_never_reads_the_treatment_column" {
  let data = v128_cs_data(120, 2, 5)
  let n = data.y.length()
  // A scrambled panel whose ONLY difference from `data` is the `d` column.
  let inverted = DoubleMLDIDCSData::new(
    data.x,
    data.y,
    {
      let d2 : Array[Double] = Array::make(n, 0.0)
      for i = 0; i < n; i = i + 1 {
        d2[i] = 1.0 - data.d[i]
      }
      d2
    },
    data.t,
    data.id,
    data.g,
  )
  let a = v128_cs_fit(data, PSProcessorConfig::new(clipping_threshold=0.3))
  let b = v128_cs_fit(inverted, PSProcessorConfig::new(clipping_threshold=0.3))
  // the perturbation is real ...
  let mut diff_rows = 0
  for i = 0; i < n; i = i + 1 {
    if data.d[i] != 1.0 - data.d[i] {
      diff_rows = diff_rows + 1
    }
  }
  assert_true(diff_rows > 500)
  // ... and the estimate is untouched, bit for bit
  assert_true(a.coef() == b.coef())
  assert_true(a.se() == b.se())
  let pa = a.predictions_m()
  let pb = b.predictions_m()
  assert_true(pa.length() == 720)
  assert_true(pa.length() == pb.length())
  for i = 0; i < pa.length(); i = i + 1 {
    assert_true(pa[i] == pb[i])
  }
}

///|
/// Cross-section fixture. `t` MUST be binary {0,1} -- a first attempt used
/// `i % 3` and the constructor aborted, which is worth writing down because
/// the failure surfaces as a bare PanicError rather than a type error.
fn v128_xs_data(n : Int, p : Int, seed : Int) -> DoubleMLDIDCrossSectionData {
  let x = Matrix::zeros(n, p)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let t = Array::make(n, 0)
  let rng = chacha8_rng(seed)
  for i = 0; i < n; i = i + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    let x1 = rng.double() * 2.0 - 1.0
    x.set(i, 0, x0)
    x.set(i, 1, x1)
    let raw = 0.5 + 1.4 * x0
    let pi = if raw < 0.02 { 0.02 } else if raw > 0.98 { 0.98 } else { raw }
    let di = if rng.double() < pi { 1.0 } else { 0.0 }
    d[i] = di
    let ti = if rng.double() < 0.5 { 1 } else { 0 }
    t[i] = ti
    y[i] = di * ti.to_double() * 2.0 +
      x0 +
      0.5 * x1 +
      0.2 * (rng.double() - 0.5)
  }
  DoubleMLDIDCrossSectionData::new(x, y, d, t)
}

///|
/// GATE 6 -- `DoubleMLDIDCrossSection`: the config reaches the transform.
///
/// This gate exists because the mutation harness CAUGHT ITS ABSENCE: the
/// first v0.128.0 harness run reported `M2-cross-section-forward-frozen`
/// SURVIVED, because the cross-section estimator had been wired with no
/// behavioural gate at all. Three estimators were wired and only one was
/// covered.
///
/// MEASURED (n=900, saturated assignment propensity) -- note BOTH clip bounds
/// bite here, unlike the CS-DID panel:
///   clip 0.01 -> coef 2.0352954866073563, exact-bound 127 / 125
///   clip 0.10 -> coef 2.028302438259842,  exact-bound 188 / 199
///   clip 0.30 -> coef 2.0310372325770096,  exact-bound 316 / 335
test "v128_cross_section_config_reaches_the_transform" {
  let data = v128_xs_data(900, 2, 17)
  let a = DoubleMLDIDCrossSection::new(
    data,
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=1.0e-2)),
  ).fit()
  let c = DoubleMLDIDCrossSection::new(
    data,
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.3)),
  ).fit()
  assert_true(a.coef() != c.coef())
  assert_true(a.coef() == 2.0352954866073563)
  let pm = c.predictions_m()
  let mut at_lo = 0
  let mut at_hi = 0
  for v in pm {
    if v == 0.3 {
      at_lo = at_lo + 1
    } else if v == 0.7 {
      at_hi = at_hi + 1
    }
  }
  assert_true(pm.length() == 900)
  assert_true(at_lo > 300)
  assert_true(at_hi > 300)
}

///|
/// GATE 7 -- `DoubleMLDIDCrossSection` isotonic. MEASURED coefficient
/// 2.007602866977095 against a default of 2.0352954866073563, with 648 of 900
/// `predictions_m()` entries moved (max delta 0.2558919925694387).
test "v128_cross_section_isotonic_reaches_the_transform" {
  let data = v128_xs_data(900, 2, 17)
  let base = DoubleMLDIDCrossSection::new(data, n_folds=2, seed=3141).fit()
  let iso = DoubleMLDIDCrossSection::new(
    data,
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(
      PSProcessorConfig::new(
        clipping_threshold=1.0e-2,
        calibration_method="isotonic",
      ),
    ),
  ).fit()
  let a = base.predictions_m()
  let b = iso.predictions_m()
  let mut moved = 0
  for i = 0; i < a.length(); i = i + 1 {
    if (a[i] - b[i]).abs() > 0.0 {
      moved = moved + 1
    }
  }
  assert_true(moved == 648)
  assert_true(iso.coef() == 2.007602866977095)
  assert_true(base.coef() != iso.coef())
}

///|
/// GATE 8 -- the resolution rule on `DoubleMLDIDCrossSection`, plus
/// config-wins-over-processor. This is the gate `M5` could not pass before.
test "v128_cross_section_config_wins_and_clip_does_not_feed" {
  let data = v128_xs_data(900, 2, 17)
  let a = DoubleMLDIDCrossSection::new(
    data,
    propensity_clip=1.0e-6,
    n_folds=2,
    seed=3141,
  )
  let b = DoubleMLDIDCrossSection::new(
    data,
    propensity_clip=0.3,
    n_folds=2,
    seed=3141,
  )
  assert_true(a.ps_processor_config.clipping_threshold == 1.0e-2)
  assert_true(b.ps_processor_config.clipping_threshold == 1.0e-2)
  assert_true(a.fit().coef() != b.fit().coef())
  let cfg = PSProcessorConfig::new(clipping_threshold=0.3)
  let via_cfg = DoubleMLDIDCrossSection::new(
    data,
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(cfg),
  ).fit()
  let via_psp = DoubleMLDIDCrossSection::new(
    data,
    n_folds=2,
    seed=3141,
    ps_processor=PSProcessor::new(config=cfg),
  ).fit()
  assert_true(via_cfg.coef() == via_psp.coef())
  let conflict = DoubleMLDIDCrossSection::new(
    data,
    n_folds=2,
    seed=3141,
    ps_processor=PSProcessor::new(
      config=PSProcessorConfig::new(clipping_threshold=1.0e-2),
    ),
    ps_processor_config=Some(cfg),
  ).fit()
  assert_true(conflict.coef() == via_cfg.coef())
}

///|
fn v128_cs_fit_nrep(
  data : DoubleMLDIDCSData,
  cfg : PSProcessorConfig,
  n_rep : Int,
) -> DoubleMLDIDCSBinary {
  DoubleMLDIDCSBinary::new(
    data,
    1,
    0,
    2,
    n_folds=2,
    n_rep~,
    seed=3141,
    ps_processor_config=Some(cfg),
  ).fit()
}

///|
/// GATE 10 -- THE MULTI-REP FOLD RE-DRAW IS LIVE, AND WAS NOT COVERED.
///
/// The v0.129.0 harness mutated `strata[i] = rows[i].g_indicator +
/// 2.0 * rows[i].t_indicator` inside the `if r > 0` branch and the mutation
/// SURVIVED. The expected explanation was checked before it was accepted:
/// that whole block only runs for repetition `r >= 1`, every estimator test in
/// this package passes `n_rep = 1`, and there was no test anywhere that fit
/// `DoubleMLDIDCSBinary` with `n_rep >= 2` -- so the site was structurally
/// unreachable, not merely ungated.
///
/// Two consequences, both acted on:
///   1. this gate fits at `n_rep = 2` and asserts the estimate MOVES, which
///      makes the re-draw path observable for the first time;
///   2. the harness's M4 mutation is re-anchored to the rep-0 draw at
///      `cs_bin_crossfit` (the one that runs on every fit), and the dead-site
///      mutation is kept as a separate, now-expected-KILLED probe.
///
/// A survival that is explained is allowed. A survival that is only explained
/// is not -- it is a coverage hole, and the hole gets filled.
test "v129_cs_binary_multi_rep_redraws_folds" {
  let data = v128_cs_data(120, 2, 5)
  let cfg = PSProcessorConfig::new(clipping_threshold=0.3)
  let one = v128_cs_fit_nrep(data, cfg, 1)
  let two = v128_cs_fit_nrep(data, cfg, 2)
  // The inequality alone is NOT enough. On the first attempt GATE 10 asserted
  // only `one.coef() != two.coef()`, and the harness mutation
  // `M5-per-rep-redraw-drop-g` still SURVIVED -- because dropping G from the
  // rep-1 strata changes WHICH rows land in which fold but still leaves rep 1
  // different from rep 0, so a coarse inequality cannot see it.
  //
  // What discriminates is pinning the rep-1 result exactly: the rep-1 folds
  // are drawn with `seed + 1` from the G-aware strata, and the mutation
  // produces a different (still self-consistent) partition, hence a different
  // coefficient. Measured at clip 0.3, n_folds=2, seed=3141:
  //
  //   n_rep=1  coef 0.9912225682002018   se 0.009379007817934814
  //   n_rep=2  coef 0.991686661219762     se 0.00953229085629481
  //
  // `n_rep=1` also equals the `v128_cs_binary_config_reaches_the_transform`
  // clip-0.3 value, which is a useful independent cross-check that this
  // fixture is the same one.
  assert_true(one.coef() == 0.9912225682002018)
  assert_true(two.coef() == 0.991686661219762)
  assert_true(two.se() == 0.00953229085629481)
  assert_true(one.coef() != two.coef())
  // and the averaged nuisance moves with it, not just the point estimate
  let p1 = one.predictions_m()
  let p2 = two.predictions_m()
  assert_true(p1.length() == 720)
  assert_true(p1.length() == p2.length())
  let mut moved = 0
  for i = 0; i < p1.length(); i = i + 1 {
    if p1[i] != p2[i] {
      moved = moved + 1
    }
  }
  assert_true(moved > 0)
}

///|
/// GATE 9 -- `DoubleMLDIDCS` forwards the config to its children, so the
/// knob is reachable end-to-end. The aggregate has NO `coef`/`se`; it exposes
/// `coef_at(group_idx, period_idx)`, and `n_groups` counts only TREATED
/// cohorts (measured 1 on the staggered fixture, not 2).
///
/// MEASURED: clip 0.01 -> -0.0019323640007233803, 0.1 -> -0.0016556901067222715,
/// 0.3 -> -0.0013883780810574286, isotonic -> -0.001710502053024229.
/// Small in absolute terms but all four distinct, so an exact inequality is
/// the honest gate.
test "v128_did_cs_forwards_the_config" {
  let data = v128_cs_data(120, 2, 5)
  let base = DoubleMLDIDCS::new(data, n_folds=2, seed=3141).fit()
  assert_true(base.n_groups() == 1)
  let gi = base.n_groups() - 1
  let pi = base.n_periods() - 1
  let a = DoubleMLDIDCS::new(
    data,
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=1.0e-2)),
  ).fit()
  let c = DoubleMLDIDCS::new(
    data,
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.3)),
  ).fit()
  let iso = DoubleMLDIDCS::new(
    data,
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(
      PSProcessorConfig::new(
        clipping_threshold=1.0e-2,
        calibration_method="isotonic",
      ),
    ),
  ).fit()
  assert_true(a.coef_at(gi, pi) != c.coef_at(gi, pi))
  assert_true(a.coef_at(gi, pi) != iso.coef_at(gi, pi))
  assert_true(a.coef_at(gi, pi) == -0.0019323640007233803)
  assert_true(c.coef_at(gi, pi) == -0.0013883780810574286)
  assert_true(iso.coef_at(gi, pi) == -0.001710502053024229)
  // stored config survives the rebuild
  let m = DoubleMLDIDCS::new(
    data,
    n_folds=2,
    seed=3141,
    ps_processor_config=Some(PSProcessorConfig::new(clipping_threshold=0.1)),
  )
  assert_true(m.ps_processor_config.clipping_threshold == 0.1)
  assert_true(m.fit().ps_processor_config.clipping_threshold == 0.1)
}
