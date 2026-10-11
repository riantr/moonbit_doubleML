// v0.146.0 -- GATES for stage 1a of the did_cs sensitivity migration.
//
// Stage 1a persists and exposes the panel-wide cross-fitted group propensity
// `m_hat = E[D | X]`, which upstream's did_cs sensitivity decomposition needs
// (`did_cs.py:470`) and which nothing in the port could previously produce.
//
// THE GATE THAT MATTERS MOST IS GATE 5. Stage 1a is supposed to be STRICTLY
// ADDITIVE: the new cross-fit feeds nothing that already exists, so no
// reported coefficient, standard error, sandwich variance or bootstrap
// statistic may move. GATE 5 pins three `coef`/`se` pairs bit-for-bit against
// values recorded BEFORE this change existed. Without it, "I only added a
// field" is a claim, not a measurement.
//
// Measurements taken before writing any of these gates (so the assertions
// describe reality rather than an expectation):
//   m_hat length   1600          (the LONG panel: 400 units x 4 periods)
//   m_hat range    [0.46749..., 0.65512...]
//   mean(m_hat)    0.5627032315060088   vs   mean(D) = 0.5625
//   folds          2, with 800 test rows each -- exact, non-overlapping cover

///|
fn v1460_four_period_fit() -> DoubleMLDIDCS {
  let d = make_did_CS2021(1600, 3, 1.0, 3141)
  let dml = DoubleMLDIDCSData::new(
    d.x_get(),
    d.y_get(),
    d.d_get(),
    d.t_get(),
    d.id_get(),
    d.g_get(),
  )
  DoubleMLDIDCS::new(dml, n_folds=2, n_rep=1, seed=3141).fit()
}

///|
/// GATE 1. `predictions_m()` is defined on the LONG panel, not on units.
/// The two are easy to confuse and getting it wrong would silently misalign
/// every downstream consumer, so this pins the length against the long-panel
/// row count computed from the data itself.
test "didcs_panel_mhat_is_indexed_by_long_panel_rows" {
  let d = make_did_CS2021(1600, 3, 1.0, 3141)
  let dml = DoubleMLDIDCSData::new(
    d.x_get(),
    d.y_get(),
    d.d_get(),
    d.t_get(),
    d.id_get(),
    d.g_get(),
  )
  let fitted = DoubleMLDIDCS::new(dml, n_folds=2, n_rep=1, seed=3141).fit()
  let m_hat = fitted.predictions_m()
  // One row per unit-period observation, the same indexing the
  // `residuals_matrix` / `psi_a_matrix` rows use.
  assert_true(m_hat.length() == dml.y.length())
  assert_true(m_hat.length() == 1600)
}

///|
/// GATE 2. A propensity that is finite and strictly inside the unit interval.
/// Guards the two ways this can go wrong in practice: a `LinearRegression`
/// extrapolating outside [0,1] (upstream clips for exactly this reason), and
/// a degenerate fit producing NaN. Tolerances are deliberately loose -- the
/// gate is about validity, not precision.
test "didcs_panel_mhat_is_a_valid_propensity" {
  let fitted = v1460_four_period_fit()
  let m_hat = fitted.predictions_m()
  for i = 0; i < m_hat.length(); i = i + 1 {
    let v = m_hat[i]
    assert_true(v.is_nan() == false)
    assert_true(v > 0.0 && v < 1.0)
  }
}

///|
/// GATE 3. The nuisance is genuinely FITTED, not a constant or a leftover
/// placeholder. Two independent facts, because either alone is weak: it must
/// vary across rows, and its mean must track the observed treatment rate --
/// a cross-fitted propensity that disagrees wildly with `mean(D)` is a
/// mis-wired fit even when it varies.
test "didcs_panel_mhat_is_fitted_and_calibrated" {
  let fitted = v1460_four_period_fit()
  let m_hat = fitted.predictions_m()
  let d = fitted.data.d
  let n = m_hat.length()
  let mut varies = false
  for i = 1; i < n; i = i + 1 {
    if m_hat[i] != m_hat[0] {
      varies = true
    }
  }
  assert_true(varies)
  let mut ss_hat = 0.0
  let mut ss_d = 0.0
  for i = 0; i < n; i = i + 1 {
    ss_hat = ss_hat + m_hat[i]
    ss_d = ss_d + d[i]
  }
  let mean_hat = ss_hat / n.to_double()
  let mean_d = ss_d / n.to_double()
  println("mean(m_hat)=\{mean_hat}  mean(D)=\{mean_d}")
  assert_true((mean_hat - mean_d).abs() < 0.02)
}

///|
/// GATE 4. Cross-fitting must be a genuine partition: every long-panel row is
/// a test row in EXACTLY ONE fold. Under-coverage would leak training rows
/// into their own prediction; over-coverage would predict some rows twice and
/// leave others fitted on data that includes them. This is the property that
/// makes `m_hat` cross-fitted rather than merely fitted.
test "didcs_panel_folds_partition_every_row_exactly_once" {
  let fitted = v1460_four_period_fit()
  let folds = fitted.sensitivity_folds()
  let n = fitted.predictions_m().length()
  assert_true(folds.length() == 2)
  let counts : Array[Int] = Array::make(n, 0)
  for f = 0; f < folds.length(); f = f + 1 {
    for idx in folds[f].test_indices() {
      counts[idx] = counts[idx] + 1
    }
  }
  for i = 0; i < n; i = i + 1 {
    assert_true(counts[i] == 1)
  }
}

///|
/// GATE 5. THE ADDITIVITY GATE. Stage 1a changes no reported number.
///
/// A first draft pinned these bit-for-bit and FAILED on wasm, wasm-gc and js.
/// That was worth chasing rather than loosening blindly, so the four backends
/// were measured:
///
///   coef(0,2)  native 0.719493089978081  wasm/wasm-gc ...806  js ...821
///   se(0,2)    native 1.436337096130982  wasm/wasm-gc  identical js ...834
///
/// The spread is ~1.5e-15 RELATIVE -- two ULP -- and it is a PRE-EXISTING
/// property of the did_cs estimator, which stage 1a does not touch (the new
/// cross-fit feeds nothing that already exists). So bit-exactness was never
/// available across backends for these quantities.
///
/// The tolerance below is set FROM that measurement at 1e-12 relative: ~700x
/// above the observed platform spread, and still ~10 orders of magnitude below
/// the smallest change a real regression of this estimator could produce
/// (perturbing a fold assignment moves `coef` by percent). The weakness is
/// declared rather than hidden: a perturbation smaller than the platform noise
/// floor is not distinguishable from the platform on this target set, so
/// asserting on it would be asserting on nothing.
///
/// GATE 5b then does pin something EXACTLY, because it can: the NEW nuisance
/// has no inherited platform spread and is bit-identical everywhere.
test "didcs_stage_1a_does_not_move_any_estimate" {
  let fitted = v1460_four_period_fit()
  let rel = fn(got : Double, want : Double) { (got - want).abs() / want.abs() }
  assert_true(rel(fitted.coef_at(0, 2), 0.719493089978081) < 1.0e-12)
  assert_true(rel(fitted.se_at(0, 2), 1.436337096130982) < 1.0e-12)
  assert_true(rel(fitted.coef_at(0, 3), 0.35566148636473893) < 1.0e-12)
  assert_true(rel(fitted.se_at(0, 3), 1.2174113759994636) < 1.0e-12)
  assert_true(rel(fitted.coef_at(1, 3), 0.15902160278807542) < 1.0e-12)
  assert_true(rel(fitted.se_at(1, 3), 1.4409600613450697) < 1.0e-12)
}

///|
/// GATE 5b. The panel-wide `m_hat` is NEW in this release, so it carries no
/// inherited platform spread -- and measurably it does not: `mean(m_hat)` is
/// `0.5627032315060088` on native, wasm, wasm-gc AND js, bit for bit. So this
/// quantity CAN be pinned exactly, and is.
test "didcs_stage_1a_panel_mhat_is_bit_identical_across_backends" {
  let fitted = v1460_four_period_fit()
  let m_hat = fitted.predictions_m()
  let n = m_hat.length()
  let mut ss = 0.0
  for i = 0; i < n; i = i + 1 {
    ss = ss + m_hat[i]
  }
  assert_true(ss / n.to_double() == 0.5627032315060088)
}

///|
/// GATE 6. An unfitted model reports an EMPTY nuisance rather than zeros or
/// an error. This is the "absent" vs "zero" distinction that the estimator
/// already gets right for `cell_psi_a` -- `sensitivity_analysis` skips cells
/// whose `se` is 0 by returning a zero sentinel, and an accessor that returned
/// `0.0` here would be indistinguishable from a fitted zero propensity.
test "didcs_panel_mhat_is_empty_before_fit" {
  let d = make_did_CS2021(1600, 3, 1.0, 3141)
  let dml = DoubleMLDIDCSData::new(
    d.x_get(),
    d.y_get(),
    d.d_get(),
    d.t_get(),
    d.id_get(),
    d.g_get(),
  )
  let unfitted = DoubleMLDIDCS::new(dml, n_folds=2)
  assert_true(unfitted.predictions_m().length() == 0)
  assert_true(unfitted.sensitivity_folds().length() == 0)
}
