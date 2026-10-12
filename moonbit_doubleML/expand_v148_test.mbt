// v0.148.0 -- GATES for the `make_did_cs_CS2021` fixture fix.
//
// `alpha_i = 0.5 * unit_in_cohort` gave every unit a DETERMINISTIC intercept
// ramping to 99.5 (SD ~ 28.8). It dominated the outcome, and the consequences
// were measured rather than argued:
//
//                       before (ramp)      after (draw)
//     var(y)                828.42              10.76
//     r^2  X_1 vs y          7e-4               0.670
//     r^2  X_2 vs y          1.4e-4             0.572
//     r^2  X_3 vs y          1.0e-4             0.451
//     corr(id, y)            ~1.0               -0.063
//     mse(g_hat)/mse(const)  1.052  (WORSE)     0.185 / 0.163 / 0.190
//
// The ratio row is the one that matters. Before, no conditional nuisance could
// beat a constant, so `E[Y | D, T, X]` carried no covariate signal and
// `sigma2 = mean((y - g_hat)^2)` collapsed onto `var(y)` -- which would have
// made Stage 2's sensitivity analysis untestable on this fixture. After, the
// nuisance explains ~82% of within-cell variance.
//
// A standard-normal draw was chosen over deleting the term, because
// unobserved unit heterogeneity IS the hidden confounding `nu2` exists to
// price. SD 1 puts it on the same scale as `theta = 1.0` and makes it ~19% of
// the covariate signal: a minority to be partialled out, not a majority that
// drowns everything.

///|
fn v1480_data() -> DidCsData {
  make_did_cs_CS2021(800, 3, 1.0, 3141)
}

///|
fn v1480_fit() -> DoubleMLDIDCS {
  let d = v1480_data()
  let fitted = DoubleMLDIDCS::new(
    DoubleMLDIDCSData::new(
      d.x_get(),
      d.y_get(),
      d.d_get(),
      d.t_get(),
      d.id_get(),
      d.g_get(),
    ),
    n_folds=2,
    n_rep=1,
    seed=3141,
  )
  fitted.fit()
}

///|
fn v1480_rel(got : Double, want : Double) -> Double {
  (got - want).abs() / want.abs()
}

///|
fn v1480_corr(xs : Array[Double], ys : Array[Double]) -> Double {
  let n = xs.length()
  let pn = n.to_double()
  let mut sx = 0.0
  let mut sy = 0.0
  for i = 0; i < n; i = i + 1 {
    sx = sx + xs[i]
    sy = sy + ys[i]
  }
  let mx = sx / pn
  let my = sy / pn
  let mut sxx = 0.0
  let mut syy = 0.0
  let mut sxy = 0.0
  for i = 0; i < n; i = i + 1 {
    let a = xs[i] - mx
    let b = ys[i] - my
    sxx = sxx + a * a
    syy = syy + b * b
    sxy = sxy + a * b
  }
  if sxx > 0.0 && syy > 0.0 {
    sxy / (sxx.sqrt() * syy.sqrt())
  } else {
    0.0
  }
}

///|
/// (mse of the nuisance, mse of the cell mean, cell size)
fn v1480_cell_fit(
  fitted : DoubleMLDIDCS,
  d_val : Double,
  t_val : Int,
  g : Array[Double],
) -> (Double, Double, Int) {
  let n = fitted.data.y.length()
  let mut yv = 0.0
  let mut cnt = 0
  for i = 0; i < n; i = i + 1 {
    if fitted.data.d[i] == d_val && fitted.data.t[i] == t_val {
      yv = yv + fitted.data.y[i]
      cnt = cnt + 1
    }
  }
  let cm = yv / cnt.to_double()
  let mut mg = 0.0
  let mut mc = 0.0
  for i = 0; i < n; i = i + 1 {
    if fitted.data.d[i] == d_val && fitted.data.t[i] == t_val {
      let a = fitted.data.y[i] - g[i]
      let b = fitted.data.y[i] - cm
      mg = mg + a * a
      mc = mc + b * b
    }
  }
  (mg / cnt.to_double(), mc / cnt.to_double(), cnt)
}

///|
/// GATE 1. THE HEADLINE GATE, and the only one here that reads code output
/// rather than the fixture. The conditional nuisance must BEAT A CONSTANT on
/// every populated cell. Before the fix it lost (ratio 1.052); the threshold
/// below is 0.25, roughly 4x clear of the measured 0.185 / 0.163 / 0.190 and
/// ~4x above the old 1.052, so it separates the two regimes without sitting on
/// either.
///
/// This is the property Stage 2 depends on: if `g_hat` cannot beat the cell
/// mean, `sigma2 = mean((y - g_hat)^2)` is just `var(y)` and the sensitivity
/// analysis has nothing to condition on.
test "didcs_fixture_nuisance_beats_a_constant_in_every_populated_cell" {
  let fitted = v1480_fit()
  let cells = [
    ("d0t0", 0.0, 0, fitted.predictions_g_d0_t0()),
    ("d0t1", 0.0, 1, fitted.predictions_g_d0_t1()),
    ("d1t1", 1.0, 1, fitted.predictions_g_d1_t1()),
  ]
  for c in cells {
    let (name, d_val, t_val, g) = c
    let (mse_g, mse_const, cnt) = v1480_cell_fit(fitted, d_val, t_val, g)
    assert_true(cnt > 0)
    assert_true(mse_g / mse_const < 0.25)
    let _ = name
  }
}

///|
/// GATE 2. THE RAMP IS GONE. `corr(within-cohort index, y)` was ~1.0 while
/// `alpha_i` was a ramp over that index; a draw leaves it at the noise floor.
/// Measured -0.063. The bound is deliberately loose (0.25) because this is a
/// signature test, not a value pin: it must fail loudly if a ramp returns, and
/// must not fire on ordinary sampling noise.
///
/// Self-check on the statistic: `corr(id, id)` is asserted to be 1 first, so a
/// gate that goes green because the correlation routine is broken cannot pass
/// silently.
test "didcs_fixture_outcome_no_longer_ramps_in_the_within_cohort_index" {
  let fitted = v1480_fit()
  let n = fitted.data.y.length()
  let idf : Array[Double] = []
  for i = 0; i < n; i = i + 1 {
    idf.push(fitted.data.id[i].to_double())
  }
  // The statistic itself, before it is trusted.
  assert_true(v1480_corr(idf, idf) > 0.999999)
  assert_true(v1480_corr(idf, fitted.data.y).abs() < 0.25)
}

///|
/// GATE 3. The covariates carry signal again. Before the fix every column sat
/// at r^2 <= 7e-4; the floor below is 0.35, against measured 0.451 / 0.572 /
/// 0.670. A five-order-of-magnitude separation, so the bound is not delicate.
test "didcs_fixture_covariates_carry_outcome_signal" {
  let fitted = v1480_fit()
  let n = fitted.data.y.length()
  let p = fitted.data.x.cols()
  for c = 0; c < p; c = c + 1 {
    let col : Array[Double] = []
    for i = 0; i < n; i = i + 1 {
      col.push(fitted.data.x.get(i, c))
    }
    let r = v1480_corr(col, fitted.data.y)
    assert_true(r * r > 0.35)
  }
}

///|
/// GATE 4. The outcome's scale, pinned. This is the fixture tripwire: any future
/// edit that moves `var(y)` by more than a part in 1e6 lands here first, before
/// it silently invalidates some downstream estimate.
test "didcs_fixture_outcome_scale_is_pinned" {
  let fitted = v1480_fit()
  let n = fitted.data.y.length()
  let mut sy = 0.0
  for i = 0; i < n; i = i + 1 {
    sy = sy + fitted.data.y[i]
  }
  let my = sy / n.to_double()
  let mut ss = 0.0
  for i = 0; i < n; i = i + 1 {
    let e = fitted.data.y[i] - my
    ss = ss + e * e
  }
  assert_true(v1480_rel(my, 0.08493305336769225) < 1.0e-9)
  assert_true(v1480_rel(ss / n.to_double(), 10.755469018704527) < 1.0e-9)
}

///|
/// GATE 5. THE FIX TOUCHED `y` AND NOTHING ELSE. Occupancy is the design, and
/// the v0.147.0 stage-1b gates depend on it: if the cell counts moved, the
/// stage-1b conclusions would need re-measuring rather than carrying over. Same
/// counts as v0.147.0 GATE 5 (400 / 200 / 0 / 200 on the canonical panel),
/// with `(d1, t0)` still structurally empty because nobody is treated in the
/// pre-period.
test "didcs_fixture_design_is_unchanged_by_the_fix" {
  let fitted = v1480_fit()
  let n = fitted.data.y.length()
  let mut c00 = 0
  let mut c01 = 0
  let mut c10 = 0
  let mut c11 = 0
  for i = 0; i < n; i = i + 1 {
    if fitted.data.t[i] == 0 && fitted.data.d[i] == 0.0 {
      c00 = c00 + 1
    } else if fitted.data.t[i] == 1 && fitted.data.d[i] == 0.0 {
      c01 = c01 + 1
    } else if fitted.data.t[i] == 0 && fitted.data.d[i] == 1.0 {
      c10 = c10 + 1
    } else {
      c11 = c11 + 1
    }
  }
  assert_true(c00 == 400)
  assert_true(c01 == 200)
  assert_true(c10 == 0)
  assert_true(c11 == 200)
  assert_true(v1480_data().theta_get() == 1.0)
  assert_true(fitted.n_groups() == 1)
  assert_true(fitted.n_periods() == 2)
}
