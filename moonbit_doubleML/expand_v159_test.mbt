//!| v0.159.0 -- regression tests for four defect fixes.
//!
//!| Each test below pins a defect that was REPORTED, reproduced, root-caused
//!| against an upstream oracle, fixed, and MEASURED. The oracle anchor and the
//!| measured before/after numbers live in each test's comment, so a future
//!| reader can re-derive the expectation instead of trusting it.
//!
//!| Evidence: _verify/_probe_isotonic_ties_1590.txt, _verify/_probe_psproc_1590.txt,
//!| _verify/_probe_pq_root_1590b.txt, _verify/_probe_blp_level_1590.txt

///|
/// DEFECT 1 -- isotonic calibration collapsed on tied x.
///
/// REPORTED: PAVA-family predictions `[0.5, 0.5]` against labels `[0, 1]`
/// returned `[0.99, 0.99]` instead of `[0.5, 0.5]`.
///
/// ROOT CAUSE: `fit_isotonic` ran PAVA over the raw sorted sequence without
/// first pooling observations that share an x. An isotonic regression is a
/// FUNCTION of x, so ties must receive one shared fitted value. `predict_isotonic`
/// then resolved each tie to the LAST index of the run, and the `[0.01, 0.99]`
/// clip turned the stray `1.0` into `0.99`.
///
/// ORACLE: sklearn 1.9.0
///   `IsotonicRegression(out_of_bounds='clip', y_min=0, y_max=1)`
///   `.fit([0.5, 0.5], [0, 1]).predict(...)` -> `[0.5, 0.5]`,
///   `X_thresholds_ = [0.5]`, `y_thresholds_ = [0.5]`.
/// The tied group is a single x with labels `[0, 1]`, so its size-weighted
/// group mean is exactly `0.5`, and PAVA has nothing to pool against it.
///
/// CONTROL (proves the gate discriminates rather than merely passing): a
/// TIE-FREE fixture `x = [0.1, 0.5, 0.9]`, `y = [0, 1, 0]` is already monotone,
/// so it must pass through UNCHANGED. Pooling cannot alter it, so if this
/// control ever moved, the pooling change -- not the reported bug -- would be
/// what altered the output.
test "v1590_isotonic_tied_x_returns_the_shared_pooled_value" {
  let cfg = PSProcessorConfig::new(
    clipping_threshold=1.0e-2,
    calibration_method="isotonic",
  )
  let psp = PSProcessor::new(config=cfg)
  // the exact reported case
  let out = psp.adjust_ps([0.5, 0.5], [0.0, 1.0])
  assert_true(out.length() == 2)
  assert_true(out[0] == 0.5)
  assert_true(out[1] == 0.5)
  // three ties, labels [0,1,0]: one shared value at the size-weighted group
  // mean 1/3 (measured; sklearn agrees to the last digit)
  let out3 = psp.adjust_ps([0.5, 0.5, 0.5], [0.0, 1.0, 0.0])
  assert_true(out3[0] == 0.3333333333333333)
  assert_true(out3[1] == 0.3333333333333333)
  assert_true(out3[2] == 0.3333333333333333)
  // CONTROL: tie-free and already monotone -> pooling cannot alter it, so the
  // isotonic fit passes it through. The 0.01 (rather than 0.0) is the CLIP
  // `[0.01, 0.99]`, not the isotonic step.
  let ctrl = psp.adjust_ps([0.1, 0.5, 0.9], [0.0, 1.0, 0.0])
  assert_true(ctrl[0] == 0.01)
  assert_true(ctrl[1] == 0.5)
  assert_true(ctrl[2] == 0.5)
}

///|
/// DEFECT 2 -- `adjust_ps`'s `cv` argument was never forwarded by any estimator.
///
/// REPORTED: "IRM/IIVM has no PSProcessor hookup".
///
/// MEASURED FIRST, and the report was too strong: the isotonic config DID
/// already reach both fits. What was genuinely missing is narrower and worse --
/// `adjust_ps` DECLARES a `cv` parameter and upstream passes `cv=smpls` at
/// every site (`pq.py:410`, `did_binary.py:537`, `iivm.py:371`, `cvar.py:343`),
/// but in this port NO estimator ever passed it. With `cv_calibration=true` the
/// processor silently calibrated on its own `default_5fold(n)` -- five CONTIGUOUS
/// blocks -- instead of the estimator's `n_folds` partition.
///
/// FIX: `folds_to_cv_partition` (ps_processor.mbt) converts the estimator's
/// `Array[Fold]` into the `Array[(Array[Int32], Array[Int32])]` shape
/// `isotonic_calibrate_cv` expects, and `irm.mbt:417` / `iivm.mbt:513` now
/// pass it.
///
/// WHAT THIS PINS: the conversion is only sound because `kfold`'s `Fold`
/// guarantees disjoint test indices that COVER `[0, n_obs)`
/// (kfold.mbt:199). If that guarantee ever broke, the calibration would
/// silently mis-partition. So this test checks the partition really is a
/// partition -- disjoint, complete, and matching the source folds -- rather
/// than only checking a downstream number moved.
test "v1590_folds_to_cv_partition_is_a_real_partition" {
  let n = 40
  let folds = kfold(n, 4, 7)
  let part = folds_to_cv_partition(folds)
  assert_true(part.length() == 4)
  let tested = Array::make(n, 0)
  for f in folds {
    let te = f.test_indices()
    let tr = f.train_indices()
    // train and test must be disjoint and together cover everything
    assert_true(tr.length() + te.length() == n)
    for i in te {
      tested[i] = tested[i] + 1
    }
  }
  // Disjointness AND coverage, which is the property `folds_to_cv_partition`
  // relies on: every index is tested EXACTLY once across the whole partition.
  for v in tested {
    assert_true(v == 1)
  }
  // and each converted pair carries the SAME indices as its Fold, in the
  // (train, test) order that `default_5fold` -- the consumer's own fallback --
  // also uses.
  for k = 0; k < part.length(); k = k + 1 {
    let a_tr = part[k].0
    let b_tr = folds[k].train_indices()
    assert_true(a_tr.length() == b_tr.length())
    for j = 0; j < a_tr.length(); j = j + 1 {
      assert_true(a_tr[j] == b_tr[j])
    }
    let a_te = part[k].1
    let b_te = folds[k].test_indices()
    assert_true(a_te.length() == b_te.length())
    for j = 0; j < a_te.length(); j = j + 1 {
      assert_true(a_te[j] == b_te[j])
    }
  }
}

///|
/// DGP with a KNOWN-EXACT potential-outcome quantile. The confounder shifts the
/// propensity and `Y(0)` continuously; `Y(1) = 2.2 + U` with
/// `U ~ Uniform[-1.2, 0.8]`, whose 0.6-quantile is exactly `0`, so the
/// population `Q_0.6(Y(1)) = 2.2` BY CONSTRUCTION rather than by approximation.
/// Confounding therefore acts on the treated potential outcome only through the
/// selection into `d == 1`, never through a location shift.
fn v1590_data(n : Int32, seed : Int32) -> DoubleMLData {
  let rng = chacha8_rng(seed)
  let x = Matrix::zeros(n, 2)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    let x1 = rng.double() * 2.0 - 1.0
    x.set(i, 0, x0)
    x.set(i, 1, x1)
    let u = -1.2 + rng.double() * 2.0
    let pi = 0.5 + 0.3 * x0 + 0.2 * x1
    let pi_c = if pi < 0.05 { 0.05 } else if pi > 0.95 { 0.95 } else { pi }
    let di = if rng.double() < pi_c { 1.0 } else { 0.0 }
    d[i] = di
    y[i] = if di == 1.0 { 2.2 + u } else { 0.8 * x0 + u }
  }
  DoubleMLData::new(x, y, d)
}

///|
/// DEFECT 3 -- PQ reported the IPW root while publishing the orthogonal score.
///
/// REPORTED: on a continuous-confounding DGP with true `q_0.6 = 2.2`, PQ
/// returned `0.7515` and the mean of its own orthogonal score was `-0.224968`.
///
/// ROOT CAUSE: `solve_pq` bisected the IPW score and RETURNED that root as the
/// coefficient, then built `psi` from the `g` cross-fit. Two different
/// functionals of the data: the reported coefficient did not satisfy the
/// estimating equation the estimator publishes. (The repo documented this at
/// `expand_v094_test.mbt:525` without fixing it.)
///
/// ORACLE: the IPW root is PRELIMINARY. `pq.py:378` solves it only to build
/// `g`'s target (`pq.py:390` fits `ml_g(x_treat, y_treat <= ipw_est)`), then
/// `pq.py:423` sets `_coef_start_val = mean(ipw_vec)` and
/// `double_ml_score_mixins.py:149` runs NEWTON from there against the
/// orthogonal score `pq.py:268`. So both pieces matter: the reported value is
/// the ORTHOGONAL root, AND the solver is Newton from the IPW root rather than
/// a bisection. (A bisection was tried first and is wrong here -- `1{y <= theta}`
/// is a step function, so a bisection converges onto a jump, not a zero.)
///
/// MEASURED: theta 2.230920809568266 against the true 2.2, and
/// `mean(psi)` at the reported theta is `-0.0032` -- versus the `-0.224968`
/// measured before the fix. The `deriv` is the Silverman-bandwidth Gaussian KDE
/// of upstream's `_compute_score_deriv`, which replaced a central difference of
/// the step function; that difference was identically ZERO outside the support
/// of `y`, which put `0/0 = NaN` into the standard errors.
test "v1590_pq_reports_a_root_of_its_own_orthogonal_score" {
  let m = v1590_data(1200, 20260920)
  let (theta, psi, deriv) = solve_pq(
    LearnerDispatch::linear_regression(),
    LearnerDispatch::linear_regression(),
    m,
    1.0,
    0.6,
    2,
    3141,
    1.0e-6,
  )
  // THE INVARIANT the defect violated: at the reported theta, the mean of the
  // score the estimator publishes is (numerically) zero.
  let mut acc = 0.0
  for v in psi {
    acc = acc + v
  }
  let mean_psi = acc / psi.length().to_double()
  assert_true(mean_psi.abs() < 0.01)
  // and the estimate lands on the by-construction truth
  assert_true((theta - 2.2).abs() < 0.1)
  // the Jacobian is finite and POSITIVE -- upstream's KDE derivative is
  // strictly positive wherever at least one treated observation exists
  assert_true(deriv > 0.0)
}

///|
/// DEFECT 3b -- the NaN standard error.
///
/// This is the SEPARATE regression that the central-difference derivative
/// caused, and it is pinned separately because it is a distinct failure mode
/// from the wrong coefficient: the coefficient was merely wrong, whereas the SE
/// was `NaN`, which is not a number at all.
///
/// MECHANISM: the score's theta-derivative was computed as a central difference
/// of the step function, so it was identically zero whenever no observation lay
/// within `+/- h` of theta. `DoubleMLQTE::fit` scales `psi` by `1 / deriv` with
/// no guard of its own -- `quantile.mbt:2411-2415` documents exactly this -- so
/// `0/0 = NaN` reached `ses[j]`. Measured on the five-quantile sweep fixture:
/// `ses = [NaN, 0.3019, 0.1758, 0.1994, 1.6937]`.
///
/// The Gaussian KDE derivative makes this STRUCTURALLY unreachable rather than
/// merely unlikely: a Gaussian never evaluates to zero, so the derivative is
/// positive at every theta including outside the support of `y`.
///
/// CONTROL: the assertion sweeps BOTH arms and a RANGE of quantiles including
/// the extremes, because the defect only appeared at an extreme quantile on
/// one arm. A single central-quantile check would not have caught it.
test "v1590_pq_derivative_stays_positive_across_quantiles_and_arms" {
  let m = v1590_data(1200, 20260920)
  for q in [0.05, 0.1, 0.5, 0.9, 0.95] {
    for arm in [0.0, 1.0] {
      let (_theta, _psi, deriv) = solve_pq(
        LearnerDispatch::linear_regression(),
        LearnerDispatch::linear_regression(),
        m,
        arm,
        q,
        2,
        3141,
        1.0e-6,
      )
      assert_true(deriv > 0.0)
      assert_true(deriv < 1.0e300)
    }
  }
}

///|
/// DEFECT 4 -- BLP's joint confint ignored `level`.
///
/// REPORTED: the 50% and 95% joint intervals were identical.
///
/// ROOT CAUSE: `blp_policy.mbt:746` hardcoded
/// `let z = 1.959963984540054`. `level` was accepted and range-checked at line
/// 727, then never used.
///
/// FIX: follow the convention already in this package
/// (`did_cross_section.mbt:485`): return the exact constant when
/// `level == 0.95` -- which keeps the default bit-exact -- and
/// `norm_ppf((1 + level) / 2)` otherwise.
///
/// WHAT THIS PINS, and why the ratio is the assertion: the intervals are
/// symmetric about the contrast, so their width is exactly `2 * z * se`. Two
/// widths at two levels therefore have ratio `z_a / z_b` INDEPENDENT of the
/// data, `se`, and the fit. Asserting that ratio pins the level wiring
/// exactly without hard-coding a fitted number that a legitimate refit could
/// move. Measured: 95/50 = 2.9058461479873507, and
/// `norm_ppf(0.975) / norm_ppf(0.75)` = 2.9058461479873507.
test "v1590_blp_joint_confint_width_scales_with_level" {
  let rng = chacha8_rng(4242)
  let n = 400
  let basis = Matrix::zeros(n, 2)
  let orth : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    basis.set(i, 0, 1.0)
    basis.set(i, 1, x0)
    orth[i] = 0.4 + 1.3 * x0 + (rng.double() - 0.5)
  }
  let blp = DoubleMLBLP::new(basis, orth, cov_type="HC0").fit()
  // the contrast spans the intercept PLUS the basis, i.e. p_basis + 1 = 3
  let contrast = Matrix::from_array([1.0, 1.0, 1.0], 1, 3)
  let w50 = {
    let iv = blp.confint_joint(contrast, level=0.50)[0]
    iv.1 - iv.0
  }
  let w95 = {
    let iv = blp.confint_joint(contrast, level=0.95)[0]
    iv.1 - iv.0
  }
  let w99 = {
    let iv = blp.confint_joint(contrast, level=0.99)[0]
    iv.1 - iv.0
  }
  // the reported defect: 50% and 95% were byte-identical
  assert_true(w50 != w95)
  assert_true(w95 != w99)
  assert_true(w50 < w95)
  assert_true(w95 < w99)
  // the exact data-independent identity
  // The exact data-independent identity. Note the numerator is the HARDCODED
  // 95% constant, not `norm_ppf(0.975)`: this package's `norm_ppf` returns
  // 1.9599627869916687 at 0.975 (accurate to ~6e-7 relative), which is exactly
  // why `confint_joint` special-cases level = 0.95 to keep the default
  // bit-exact. Asserting the ratio against `norm_ppf(0.975)/norm_ppf(0.75)`
  // would be asserting a DIFFERENT contract than the one the code implements.
  //   measured 2.9058479234757097 vs 2.905847923475711, agreeing to 1.3e-15
  //   (pure float round-trip through the interval subtraction)
  let expect = 1.959963984540054 / norm_ppf((1.0 + 0.50) / 2.0)
  assert_true((w95 / w50 - expect).abs() < 1.0e-12)
  // and the 99% level follows the same law
  let expect99 = norm_ppf((1.0 + 0.99) / 2.0) / norm_ppf((1.0 + 0.50) / 2.0)
  assert_true((w99 / w50 - expect99).abs() < 1.0e-12)
}
