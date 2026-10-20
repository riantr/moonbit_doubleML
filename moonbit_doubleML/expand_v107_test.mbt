///|
/// v0.107.0: the SSM `HC0 == se()` identity, and PLPR's three
/// approaches that must coincide.
///
/// `validate_ssm_with_python.py` and
/// `validate_plpr_with_python.py` gained MoonBit-side checks in
/// v0.107.0, but those run in one CI job. These tests carry the same
/// facts into `moon test`, which runs on all four backends.
///
/// The ordering of the checks is the point, and it is the same
/// ordering v0.106.0 settled on for the cluster estimators:
///
///   1. ALGEBRA, asserted at a tolerance ~1e-15 or tighter. No
///      sampling content, so no Monte-Carlo band.
///   2. STATISTICS, asserted at a band measured from the run and
///      cross-checked against an independent implementation.

///|
/// Self-contained SSM MAR DGP, identical to
/// `examples/ssm/main.mbt::build_ssm_dgp`.
///
/// The pool layout is `n * (p + 2)`: covariates row-major, then the
/// selection noise, then the outcome noise. Getting that length wrong
/// is a bare `pool.at` panic rather than a wrong number, so the
/// indexing and the bound are stated together.
fn v107_ssm_dgp(
  rng : @random.Rand,
  n : Int32,
  p : Int32,
  theta0 : Double,
) -> DoubleMLSSMData {
  let pool : Array[Double] = []
  while pool.length() < n * (p + 2) {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let theta = 2.0 * 3.141592653589793 * u2
    pool.push(r * @math.cos(theta))
    pool.push(r * @math.sin(theta))
  }
  let x = Matrix::zeros(n, p)
  let d : Array[Double] = Array::make(n, 0.0)
  let s : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x.set(i, j, pool[i * p + j])
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    let mut linear = d[i] + 0.5 * x.get(i, 0)
    for j = 1; j < p; j = j + 1 {
      linear = linear + 0.05 * x.get(i, j)
    }
    linear = linear + pool[n * p + i]
    s[i] = if linear > 0.0 { 1.0 } else { 0.0 }
    y[i] = theta0 * d[i] + 0.3 * x.get(i, 0) * d[i] + 0.3 * pool[n * p + n + i]
  }
  DoubleMLSSMData::new(x, y, d, s)
}

///|
fn v107_ssm_fit(n : Int32, p : Int32, seed : Int32) -> DoubleMLSSM {
  DoubleMLSSM::new(
    v107_ssm_dgp(chacha8_rng(seed), n, p, 1.0),
    n_folds=2,
    n_rep=1,
    seed~,
  ).fit()
}

///|
/// v0.138.0 -- same fit with an EXPLICIT propensity learner.
///
/// Added because the SE-fragility gate below can no longer be phrased against
/// the default: v0.138.0 made that default a classifier, and a bounded
/// propensity is exactly what removes the fragility. `v107_ssm_fit` above is
/// kept and still used by the other tests in this file, so the default path
/// stays under test -- it just is not the arm the fragility claim is about.
fn v107_ssm_fit_ml(
  n : Int32,
  p : Int32,
  seed : Int32,
  ml_m : LearnerDispatch,
) -> DoubleMLSSM {
  DoubleMLSSM::new(
    v107_ssm_dgp(chacha8_rng(seed), n, p, 1.0),
    n_folds=2,
    n_rep=1,
    seed~,
    ml_m~,
  ).fit()
}

///|
/// `sandwich_se(HC0)` and `se()` compute the same quantity for a
/// `var_est`-shaped estimator, so they must agree to the last bit.
///
/// Measured on two seeds at two sample sizes: the difference is
/// exactly `0.0`, and the example prints `hc0_minus_se=0` for all
/// four lines. This is algebra, so the band is 1e-15 -- a future
/// last-ulp difference would be reported, a regression to a
/// different formula would be several orders of magnitude out.
///
/// This matters historically: `sandwich_variance_hc0` carried a `1/n`
/// the accumulator did not, so HC0 sat at `sqrt(n) * se()` through
/// v0.90.0, and `DoubleMLDIDCS` / `DoubleMLLPLR` were held out of the
/// sandwich API entirely for related reasons. The identity being
/// exactly true today is exactly why it needs a test.
test "v107_ssm_hc0_is_se" {
  for seed in [99, 7, 3141] {
    for n in [500, 2000] {
      let f = v107_ssm_fit(n, 5, seed)
      let row_se = f.se()
      let hc0 = f.sandwich_se(SandwichKind::hc0())
      assert_true(row_se > 0.0)
      let rel = (hc0 - row_se).abs() / row_se
      assert_true(rel < 1.0e-15)
    }
  }
}

///|
/// The SE falls like `1/sqrt(n)` across a 4x step.
///
/// Measured on the two seeds the cross-check uses: 0.5326 (seed 99)
/// and 0.4854 (seed 7), against `1/sqrt(4) = 0.5`. The band is
/// (0.40, 0.65) -- wide enough for the fold-level random component,
/// narrow enough to exclude a flat SE (~1.0) and a missing `n`
/// (~2.0, which is what the v0.90.0 HC0 defect produced).
///
/// The assertion below is on the RELATION (`0.40 < ratio < 0.65`), not on
/// these two numbers, which is why the test never failed when the port
/// moved and the quoted measurements went stale: 0.5255 / 0.4866 were
/// what this comment said until the numbers were re-measured. A quoted
/// measurement that no assertion reads cannot announce that the code
/// moved underneath it. `validate_ssm_with_python.py` prints the live
/// ratio for each seed on every run.
///
/// Seed 3141 is deliberately absent, and the next test says why.
test "v107_ssm_se_scales_like_inverse_sqrt_n" {
  for seed in [99, 7] {
    let small = v107_ssm_fit(500, 5, seed)
    let big = v107_ssm_fit(2000, 5, seed)
    let ratio = big.se() / small.se()
    assert_true(ratio > 0.40 && ratio < 0.65)
    // HC0 is the same number, so it must scale identically. If it
    // did not, the identity above would be a coincidence at one n
    // rather than a structural fact.
    let ratio_hc0 = big.sandwich_se(SandwichKind::hc0()) /
      small.sandwich_se(SandwichKind::hc0())
    assert_true(ratio_hc0 > 0.40 && ratio_hc0 < 0.65)
    // And the coefficient converges to the true 1.0.
    assert_true((small.coef() - 1.0).abs() < 0.10)
    assert_true((big.coef() - 1.0).abs() < 0.05)
    assert_true((big.coef() - 1.0).abs() < (small.coef() - 1.0).abs())
  }
}

///|
/// A negative control: SSM's variance is fragile with respect to the
/// fold split on this DGP, and that is worth writing down.
///
/// Measured, at p = 5, seed 3141:
///
///     n=500    theta   0.9543   se 0.15431
///     n=1000   theta   0.9890   se 0.02637
///     n=2000   theta   0.9891   se 0.01959
///     n=4000   theta   0.9874   se 0.01325
///     n=8000   theta -121.88    se 122.88     <- diverged
///
/// The 4x ratio 500 -> 2000 is 0.1270, not ~0.5, and the SE at
/// n=500 is ~4x the other seeds'. At n=8000 the fit diverges outright.
///
/// Two things follow, and both are asserted here so that a future
/// edit to the cross-check cannot quietly drop them:
///
///   1. This is NOT a scale error, and nothing in this version widens
///      a band to accommodate it. A band wide enough to hold a 4x
///      swing would also hold a flat SE, which is the defect the
///      check exists to catch.
///   2. The `HC0 == se()` identity still holds exactly at n=8000,
///      where the value itself is meaningless. The two have to be
///      diagnosed separately -- which is why the identity test above
///      includes seed 3141 at both sizes.
///
/// If a future change to `ssm.mbt` makes the SE well-behaved on this
/// seed, THIS test fails and the cross-check's `SE_RATIO` band can be
/// re-derived from the new measurements. That is the intended
/// direction of travel.
///
/// v0.138.0: that change arrived -- `DoubleMLSSM`'s default `ml_m`
/// became a classifier, and a bounded propensity is precisely what
/// removes the fragility. The table above is therefore retained as a
/// measurement of the REGRESSOR arm, and the test now asserts it there,
/// explicitly, via `v107_ssm_fit_ml`. Re-derived values are
/// bit-for-bit identical to the table (n=500 0.95431/0.15431, n=2000
/// 0.98914/0.01959, ratio 0.12697); the classifier arm measures
/// 1.06593/0.06713 and 0.98935/0.02006, ratio 0.29895.
test "v107_ssm_se_is_fragile_to_the_split" {
  let ols = LearnerDispatch::linear_regression()
  let logit = LearnerDispatch::logistic_regression(LogisticRegression::new())
  // (a) The regressor arm still shows the documented fragility: well off the
  //     1/sqrt(n) law of 0.5, and ~4x the other seeds at n=500.
  let small = v107_ssm_fit_ml(500, 5, 3141, ols)
  let big = v107_ssm_fit_ml(2000, 5, 3141, ols)
  let ratio = big.se() / small.se()
  assert_true(ratio < 0.20)
  assert_true(small.se() > 0.10)
  // (b) The classifier arm is out of that band, with margin: measured 0.29895
  //     against the regressor's 0.12697, a 2.36x separation.
  let csmall = v107_ssm_fit_ml(500, 5, 3141, logit)
  let cbig = v107_ssm_fit_ml(2000, 5, 3141, logit)
  let cratio = cbig.se() / csmall.se()
  assert_true(cratio > 2.0 * ratio)
  assert_true(cratio < 0.40)
  assert_true(csmall.se() < 0.7 * small.se())
  // (c) But the identity is unaffected in EITHER arm.
  let rel = (small.sandwich_se(SandwichKind::hc0()) - small.se()).abs() /
    small.se()
  assert_true(rel < 1.0e-15)
  let crel = (csmall.sandwich_se(SandwichKind::hc0()) - csmall.se()).abs() /
    csmall.se()
  assert_true(crel < 1.0e-15)
}

///|
/// PLPR: on a linear, homogeneous-effect panel, `cre_general`,
/// `cre_normal` and `wg_approx` all reduce to the same estimator, so
/// they must agree. Measured spread on `examples/plpr`: 8.0e-11.
///
/// This is algebra on the DGP, not a statistical band, and it is the
/// check that `validate_plpr_with_python.py` could not make when it
/// printed four literals and compared them against nothing: a
/// per-approach "theta ~ 1.03" band would not notice one of the three
/// drifting.
///
/// `fd_exact` must NOT be one of them -- first differences are a
/// different estimator, and if they coincided the "four approaches"
/// would be one.
test "v107_plpr_three_approaches_coincide_and_the_fourth_does_not" {
  let data = v107_plpr_data()
  let thetas = []
  for approach in ["cre_general", "cre_normal", "wg_approx", "fd_exact"] {
    let f = DoubleMLPLPR::new(data, n_folds=2, approach~, seed=3141).fit()
    assert_true(f.coef() > 0.9 && f.coef() < 1.15)
    // Cluster-robust, so ~0.017 -- not the ~0.32 a row-level
    // variance would report.
    assert_true(f.se() > 0.004 && f.se() < 0.08)
    thetas.push(f.coef())
  }
  let base = thetas[0]
  let mut spread = 0.0
  for i in [1, 2] {
    let d = (thetas[i] - base).abs()
    if d > spread {
      spread = d
    }
  }
  assert_true(spread < 1.0e-8)
  // fd_exact is a different estimator.
  assert_true((thetas[3] - base).abs() > 1.0e-8)
}

///|
/// The `examples/plpr` panel: 60 units x 4 periods, unit fixed effect
/// correlated with treatment, so the clustered path is required.
///
/// Mirrors `examples/plpr/main.mbt::build_panel` exactly -- the
/// example is a separate module and MoonBit scopes a private `fn` to
/// its own file, so this is a second copy rather than a call into it.
/// Matching the DGP matters here rather than merely tidily: the
/// three-way agreement asserted above only holds because this panel
/// is linear in `d` with a homogeneous effect.
fn v107_plpr_data() -> DoubleMLPanelData {
  let p = 2
  let n_units = 60
  let n_periods = 4
  let n = n_units * n_periods
  let rng = chacha8_rng(3141)
  let x_flat = Array::make(n * p, 0.0)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let t_arr = Array::make(n, 0)
  let id_arr = Array::make(n, 0)
  let theta0 = 1.0
  for u = 0; u < n_units; u = u + 1 {
    let alpha = (rng.double() - 0.5) * 4.0
    let unit_trait = rng.double() * 2.0 - 1.0
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      let x1 = unit_trait + (rng.double() - 0.5)
      let x2 = rng.double() * 2.0 - 1.0
      x_flat[row * p] = x1
      x_flat[row * p + 1] = x2
      t_arr[row] = k
      id_arr[row] = u
      d[row] = 0.6 * x1 + 0.3 * x2 + 0.5 * alpha / 2.0 + (rng.double() - 0.5)
      y[row] = theta0 * d[row] +
        0.8 * x1 -
        0.5 * x2 +
        alpha +
        (rng.double() - 0.5) * 0.25
    }
  }
  DoubleMLPanelData::new(Matrix::from_array(x_flat, n, p), y, d, t_arr, id_arr)
}
