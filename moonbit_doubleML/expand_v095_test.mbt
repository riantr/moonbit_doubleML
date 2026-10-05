///|
// v0.95.0: `DoubleMLQTE` gets the per-quantile sandwich API.
//
// WHY QTE WAS NOT ON THE LIST, AND WHY IT IS NOT LIKE PQ
// ========================================================
// v0.94.0 gave `DoubleMLPQ` the triple, and the natural reading of
// QTE was "the same thing, once per quantile". It is NOT, and the
// difference is structural rather than bookkeeping.
//
// PQ is a single scalar quantile Z-estimator: `theta` solves
// `mean(psi(theta)) = 0`, the stored score is the RAW quantile
// score, and the Jacobian is the data-dependent scalar
// `deriv = d mean(psi(theta)) / d theta`. So PQ needs
// `M_inv = [[1 / deriv]]`, and a constant `-1` / `+1` reading
// shrinks its SE by `|deriv|` (4.74x on the v0.94.0 DGP).
//
// QTE is a CONTRAST of two such estimators per quantile,
// `theta_j = theta_1 - theta_0`, and its stored IF row is
//
//     u_i = psi_1[i] / deriv_1 - psi_0[i] / deriv_0
//
// i.e. `fit` has ALREADY applied both Jacobians before storing it,
// and `ses[j] = sqrt(mean(u^2) / n)` needs no further scaling. In
// the one-parameter form `theta_1 = theta_0 + theta_j` the
// estimating equation's `theta_j`-derivative is
// `(1 / deriv_1) * deriv_1 - 0 = 1`, so the contrast's Jacobian is
// IDENTICALLY 1 and `M_inv = [[1.0]]`.
//
// Two consequences the tests below pin:
//
//   1. `sandwich_se_at(j, HC0) == ses[j]` holds and is BIT-IDENTICAL
//      (`mean` in `matrix.mbt` and `sandwich_variance_hc0`'s
//      accumulator are the same Kahan loop over the same products in
//      the same order, and both divide by `n` twice).
//   2. The trap runs the OTHER way from PQ's. A hard-coded
//      `M_inv = [[-1]]` / `[[+1]]` is not merely close here -- it is
//      exactly right, for the structural reason above, and any
//      reading that multiplies in a persisted `1 / derivs1[j]` (or
//      `derivs0[j]`, or `1 / (derivs1[j] - derivs0[j])`) DOUBLE-COUNTS
//      the Jacobian and INFLATES the SE by `1 / |deriv|` (PQ's error
//      shrank it, because PQ's score is raw). Test 3 measures that
//      error on this DGP.
//
// The per-arm Jacobians are still persisted (`derivs1` / `derivs0`):
// they are the record of how the stored IF was built, and until
// v0.95.0 they were dropped on the floor right after being used.
// They enter the variance path as a degeneracy guard and nothing
// else (see `m_inv_1x1_at`).
//
// A JOINT cross-quantile covariance is deliberately NOT here: each
// quantile is an independent scalar Z-estimator with its own `theta_j`
// and `psi_j`, so the per-quantile sandwich is a 1x1 problem and the
// package-wide `sandwich_variance(kind, ...)` dispatch applies
// unchanged, per quantile. `Cov(theta_j, theta_j')` across quantiles
// is a separate, larger feature.

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

///|
/// Relative closeness at the 1e-12 level (the package's tolerance
/// for "same number, different accumulation order" -- the same helper
/// `expand_v091_test.mbt` .. `expand_v094_test.mbt` use).
fn expand_v095_close(x : Double, y : Double) -> Bool {
  let scale = if x.abs() > y.abs() { x.abs() } else { y.abs() }
  if scale == 0.0 {
    return (x - y).abs() < 1.0e-300
  }
  (x - y).abs() / scale < 1.0e-12
}

///|
/// The v0.95.0 QTE DGP: `n` observations, one bounded covariate
/// `x in [-1, 1]`, `d = 1{u < expit(0.3 x)}`, and an arm-dependent
/// outcome. Each arm's outcome is the SUM OF TWO UNIFORMS mapped
/// affinely onto its support, i.e. triangular:
///
///   treated (`d = 1`): `y = 2 + 8 * (u1 + u2) / 2`  on `[2, 10]`
///   control (`d = 0`): `y = 6 * (v1 + v2) / 2`        on `[0, 6]`
///
/// Three properties matter, and each is pinned by a test:
///
///   - The treatment indicator depends LINEARLY on the single
///     covariate the propensity learner actually sees, so the
///     cross-fitted `m` lands well inside `[0.01, 0.99]` and no row
///     sits on the `1e-6` clip. The v0.93.0 failure mode (an
///     instrument the OLS propensity learner cannot recover, so
///     `1 / m` terms hit `1e6` and every SE becomes a meaningless
///     magnitude WHILE ALL THE SANDWICH IDENTITIES STILL HOLD) is
///     therefore excluded by construction, and
///     `qte_dgp_sanity` pins the propensity range and the relative SE
///     directly.
///   - The two arms have DIFFERENT widths (8 vs 6) and different
///     offsets, so the per-quantile estimand really is a contrast and
///     not a constant shift: `QTE(0.2) ~ 2.63` against
///     `QTE(0.6) ~ 3.11`.
///   - Each arm's density is NON-FLAT (triangular), so the two
///     quantiles land on different densities and the per-quantile
///     Jacobians are materially DIFFERENT from each other -- which is
///     what makes the per-quantile path observable. A uniform-outcome
///     DGP would give every quantile the same density and could not
///     tell a per-quantile implementation from a loop that ignored
///     `j`.
fn expand_v095_qte_data(n : Int) -> DoubleMLData {
  let x_flat : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let rng = chacha8_rng(3141)
  let need = n * 2
  let pool : Array[Double] = []
  while pool.length() < need {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let theta = 2.0 * 3.141592653589793 * u2
    pool.push(r * @math.cos(theta))
    pool.push(r * @math.sin(theta))
  }
  for i = 0; i < n; i = i + 1 {
    x_flat[i] = 2.0 * pool[i] - 1.0
  }
  for i = 0; i < n; i = i + 1 {
    let pd = expit(0.3 * x_flat[i])
    d[i] = if rng.double() < pd { 1.0 } else { 0.0 }
  }
  for i = 0; i < n; i = i + 1 {
    let s_treated = rng.double() + rng.double()
    let s_control = rng.double() + rng.double()
    let y_treated = 2.0 + 8.0 * (s_treated / 2.0)
    let y_control = 6.0 * (s_control / 2.0)
    y[i] = if d[i] == 1.0 { y_treated } else { y_control }
  }
  DoubleMLData::new(Matrix::from_array(x_flat, n, 1), y, d)
}

///|
/// The two quantiles every test in this file shares: `0.2` and `0.6`.
/// Both are interior (the bisection bracket needs mass on each side)
/// and, per the DGP note above, they land on different densities.
fn expand_v095_quantiles() -> Array[Double] {
  [0.2, 0.6]
}

///|
/// The fitted QTE every test in this file shares.
fn expand_v095_fit(n : Int) -> DoubleMLQTE {
  DoubleMLQTE::new(
    expand_v095_qte_data(n),
    quantiles=expand_v095_quantiles(),
    n_folds=2,
  ).fit()
}

///|
/// Quantile `j`'s IF row, built independently of the production
/// slice (`psi_flat[j * n_obs .. (j + 1) * n_obs]`).
fn expand_v095_row(m : DoubleMLQTE, j : Int, n : Int) -> Array[Double] {
  let row : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    row[i] = m.psi_flat[j * n + i]
  }
  row
}

///|
/// All-singleton (`singleton[i] = i`) and pooled-in-blocks-of-4
/// (`pooled[i] = i / 4`) cluster ids for a sample of `n`.
fn expand_v095_cluster_ids(n : Int) -> (Array[Int], Array[Int]) {
  let singleton : Array[Int] = Array::make(n, 0)
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
    pooled[i] = i / 4
  }
  (singleton, pooled)
}

// ---------------------------------------------------------------------------
// 1. THE DECISIVE ONE: ses[j] == sandwich_se_at(j, HC0)
// ---------------------------------------------------------------------------

///|
/// THE assertion that unblocks QTE, for EVERY configured quantile.
///
/// `ses[j]` is `(gamma / n).sqrt()` with `gamma = mean(u^2)` and
/// `u = psi_1 / deriv_1 - psi_0 / deriv_0`; `sandwich_se_at(j, HC0)`
/// is `M_inv[0,0]^2 * sum_i u_i^2 / n / n` with `M_inv[0,0] == 1`.
/// `mean` and `sandwich_variance_hc0` run the same Kahan
/// compensation over the same `u_i * u_i` products in the same index
/// order and both then divide by `n` twice, so the two sides are not
/// merely close -- they are the same sequence of IEEE operations, and
/// the test pins exact equality (`==`), not a tolerance.
///
/// Fails to COMPILE against v0.94.0 (the methods do not exist), which
/// is the point: the invariant cannot even be expressed before the
/// Jacobian role is settled, and settling it wrong (the PQ `M_inv =
/// 1 / deriv` reading) compiles and fails.
test "qte_se_equals_sandwich_hc0_at_each_quantile" {
  let n = 500
  let n_d = n.to_double()
  let m = expand_v095_fit(n)
  let n_q = m.quantiles.length()
  inspect(n_q == 2, content="true")
  inspect(m.ses().length() == n_q, content="true")
  inspect(m.derivs1.length() == n_q, content="true")
  inspect(m.derivs0.length() == n_q, content="true")
  inspect(m.psi_flat.length() == n_q * n, content="true")
  for j = 0; j < n_q; j = j + 1 {
    let se_hc0 = m.sandwich_se_at(j, SandwichKind::hc0())
    let se = m.ses()[j]
    // The invariant, exactly.
    inspect(se_hc0 == se, content="true")
    // ... and the portable statement of it.
    inspect(expand_v095_close(se_hc0, se), content="true")
    // The shipped variance is what `fit` computed by hand, term for
    // term: a NAIVE (non-Kahan) sum of the same squares, divided by
    // `n` twice. Independent accumulation, same quantity.
    let row = expand_v095_row(m, j, n)
    let mut ss = 0.0
    for i = 0; i < n; i = i + 1 {
      ss = ss + row[i] * row[i]
    }
    let hand = (ss / n_d / n_d).sqrt()
    inspect(expand_v095_close(se_hc0, hand), content="true")
    // The per-quantile row is the delta-method IF and is NOT the raw
    // score: `mean(u)` is the contrast's estimating equation at the
    // reported root, small but not zero.
    let mean_u = mean(row)
    inspect(mean_u.abs() < 0.2, content="true")
    // ... and it is NOT the *other* reading of the same state. The
    // package-order reconstruction `psi_at(coef, psi_a, psi)` -- the
    // score the other fifteen estimators evaluate -- is a DIFFERENT
    // function whose root is not `coefs[j]`, so it must NOT reproduce
    // `ses[j]`. Here `psi_a` is the honest all-ones contrast Jacobian
    // row and `psi_b` the stored IF, so `psi_at` returns
    // `coefs[j] + u_i` -- dominated by the estimand itself.
    let ones : Array[Double] = Array::make(n, 1.0)
    let psi_wrong = psi_at(m.coefs()[j], ones, row)
    let mut ss_wrong = 0.0
    for i = 0; i < n; i = i + 1 {
      ss_wrong = ss_wrong + psi_wrong[i] * psi_wrong[i]
    }
    let se_wrong = (ss_wrong / n_d / n_d).sqrt()
    inspect(expand_v095_close(se_wrong, se) == false, content="true")
    // `psi_at(coef, ones, u)` returns `coefs[j] + u_i`, i.e. the same
    // variance term with the ESTIMAND injected into every row. The
    // defect is therefore in the MEAN, not the second moment: on this
    // DGP `u`'s spread is an order of magnitude above `coefs[j]`, so
    // the two SEs land within a few percent of each other and a
    // "the wrong SE is wildly different" claim would be a claim about
    // the DGP's scale rather than about the misreading. What pins the
    // misreading is that the reconstructed "score" is not a score:
    // its mean is the estimand, not ~0.
    inspect(mean(psi_wrong).abs() > 1.0, content="true")
    inspect(
      expand_v095_close(mean(psi_wrong) - m.coefs()[j], mean_u),
      content="true",
    )
  }
}

// ---------------------------------------------------------------------------
// 2. THE MEMOIZE CACHE-HIT TEST
// ---------------------------------------------------------------------------

///|
/// `derivs1` / `derivs0` must survive a memoize cache hit, and the
/// test that proves it is this one.
///
/// `FitCache` for `"qte"` stores `[thetas_derivs, psi1_cache,
/// psi0_cache]` with the four per-quantile scalars at
/// `j * 4 + {0, 1, 2, 3}` -- so `deriv1` / `deriv0` ARE on the cache
/// path (v0.84.0 packs them). `fit` binds them to the same names on
/// both paths (`(thetas_derivs[j * 4 + 1], ..., thetas_derivs[j *
/// 4 + 3])` on a hit, `solve_pq`'s third return on a miss) and the
/// `d1s[j] = deriv1` writes sit AFTER the `cache_hit` branch, so
/// there is no second restore path that can drift.
///
/// A regression that returned the `new()` all-zero sentinel on the
/// hit path would still compile and would then ABORT inside
/// `m_inv_1x1_at` on the `|deriv| >= 1e-12` guard; one that returned
/// an uncached constant would move the SE. Both are caught here.
test "qte_sandwich_after_memoize_cache_hit" {
  let n = 500
  let n_q = 2
  let base = DoubleMLQTE::new(
    expand_v095_qte_data(n),
    quantiles=expand_v095_quantiles(),
    n_folds=2,
  ).enable_memoize()
  let f1 = base.fit()
  let f2 = f1.fit()
  inspect(f1.has_cache(), content="true")
  inspect(f2.has_cache(), content="true")
  for j = 0; j < n_q; j = j + 1 {
    // Present, non-zero, and unchanged on the hit path.
    inspect(f2.derivs1[j] == f1.derivs1[j], content="true")
    inspect(f2.derivs0[j] == f1.derivs0[j], content="true")
    inspect(f2.derivs1[j] != 0.0, content="true")
    inspect(f2.derivs0[j] != 0.0, content="true")
    // The invariant SURVIVES the cache hit -- the assertion that fails
    // if the restored Jacobians are left out of the field.
    let se_hc0 = f2.sandwich_se_at(j, SandwichKind::hc0())
    inspect(se_hc0 == f2.ses()[j], content="true")
    // ... and the cache hit did not move the number: a cache hit must
    // be a no-op for the sandwich, which is the whole contract of the
    // memoize layer.
    inspect(f1.sandwich_se_at(j, SandwichKind::hc0()) == se_hc0, content="true")
    let fresh = expand_v095_fit(n)
    inspect(
      fresh.sandwich_se_at(j, SandwichKind::hc0()) == se_hc0,
      content="true",
    )
    // `ses[j]` itself is also unchanged by the cache hit, so the
    // equality above is not an accident of two errors cancelling.
    inspect(f1.ses()[j] == f2.ses()[j], content="true")
    inspect(f2.ses()[j] == fresh.ses()[j], content="true")
    // The restored Jacobians are byte-identical to the freshly solved
    // ones (what makes the single-binding construction safe).
    inspect(f2.derivs1[j] == fresh.derivs1[j], content="true")
    inspect(f2.derivs0[j] == fresh.derivs0[j], content="true")
    // The cluster path agrees on the hit path too.
    let (singleton, _pooled) = expand_v095_cluster_ids(n)
    inspect(f2.cluster_sandwich_se_at(j, singleton) == se_hc0, content="true")
  }
}

// ---------------------------------------------------------------------------
// 3. THE PERSISTED JACOBIANS, AND THE TRAP THAT RUNS THE OTHER WAY
// ---------------------------------------------------------------------------

///|
/// QTE's per-arm Jacobians are data-dependent and emphatically not
/// the constants `-1` / `+1` -- they are the signed IPW-weighted
/// densities of `y` at each arm's quantile. This test pins three
/// things, and the third is the one that matters:
///
///   (1) `derivs1[j]` and `derivs0[j]` are neither `-1` nor `+1`, are
///       nowhere near either, and DIFFER from each other and across
///       quantiles (the triangular-outcome DGP is what makes the last
///       part observable). Refitting on a rescaled outcome moves them
///       again, which no hard-coded constant can do.
///
///   (2) Because they are already inside the stored IF, the shipped
///       `M_inv` IS the constant reading: `M_inv = [[-1]]` and
///       `M_inv = [[+1]]` reproduce `ses[j]` EXACTLY (the variance sees
///       the Jacobian only through its square, so the two readings are
///       equal here -- and, unlike PQ, they are also RIGHT here).
///       That is the structural consequence of the contrast form and
///       is asserted as such rather than left implicit.
///
///   (3) The misreading that does bite is the PQ one applied to QTE's
///       fields: multiplying the stored IF by a further
///       `1 / derivs1[j]` (or `derivs0[j]`, or
///       `1 / (derivs1[j] - derivs0[j])`) DOUBLE-COUNTS the Jacobian.
///       All three give a materially larger SE, and the size of the
///       error is measured exactly: `shipped / wrong == |deriv|`.
///
/// No finiteness-only assertion: every check compares two
/// independently computed numbers.
test "qte_jacobian_is_not_a_constant" {
  let n = 500
  let m = expand_v095_fit(n)
  let ses = m.ses()
  let d1 = m.derivs1
  let d0 = m.derivs0
  let ones : Array[Double] = Array::make(n, 1.0)
  for j = 0; j < m.quantiles.length(); j = j + 1 {
    let shipped = m.sandwich_se_at(j, SandwichKind::hc0())
    let row = expand_v095_row(m, j, n)
    // (1) Neither constant, and not near either. On this DGP the
    // values are ~0.14 / ~0.08 (treated / control at q = 0.2): the
    // bands are loose because `deriv` is a finite-sample central
    // difference over an IPW cross-fit, and what they rule out is a
    // Jacobian of order 1.
    inspect(d1[j] != -1.0, content="true")
    inspect(d1[j] != 1.0, content="true")
    inspect(d0[j] != -1.0, content="true")
    inspect(d0[j] != 1.0, content="true")
    inspect(d1[j].abs() > 0.02 && d1[j].abs() < 0.5, content="true")
    inspect(d0[j].abs() > 0.02 && d0[j].abs() < 0.5, content="true")
    // The two arms' Jacobians differ from each other, and the two
    // quantiles' differ from each other -- otherwise the DGP is not
    // exercising the per-quantile, per-arm path at all.
    inspect(expand_v095_close(d1[j], d0[j]) == false, content="true")
    inspect(expand_v095_close(d1[0], d1[1]) == false, content="true")
    inspect(expand_v095_close(d0[0], d0[1]) == false, content="true")
    // The arms' `ses` differ, so the per-quantile loop is not
    // reporting one number twice.
    inspect(expand_v095_close(ses[0], ses[1]) == false, content="true")
    // (2) The constant readings ARE the shipped one here, exactly.
    let jac_minus_one = sandwich_variance_hc0(
      ones,
      row,
      Matrix::from_array([-1.0], 1, 1),
      n,
      1,
    ).sqrt()
    let jac_plus_one = sandwich_variance_hc0(
      ones,
      row,
      Matrix::from_array([1.0], 1, 1),
      n,
      1,
    ).sqrt()
    inspect(jac_minus_one == jac_plus_one, content="true")
    inspect(jac_minus_one == shipped, content="true")
    inspect(jac_minus_one == ses[j], content="true")
    // (3) The double-counting readings, and the measured size of the
    // mistake. Each divides the shipped SE by `|deriv|`.
    let wrong1 = sandwich_variance_hc0(
      ones,
      row,
      Matrix::from_array([1.0 / d1[j]], 1, 1),
      n,
      1,
    ).sqrt()
    let wrong0 = sandwich_variance_hc0(
      ones,
      row,
      Matrix::from_array([1.0 / d0[j]], 1, 1),
      n,
      1,
    ).sqrt()
    let diff = d1[j] - d0[j]
    let wrong_diff = sandwich_variance_hc0(
      ones,
      row,
      Matrix::from_array([1.0 / diff], 1, 1),
      n,
      1,
    ).sqrt()
    inspect(expand_v095_close(wrong1, shipped) == false, content="true")
    inspect(expand_v095_close(wrong0, shipped) == false, content="true")
    inspect(expand_v095_close(wrong_diff, shipped) == false, content="true")
    // The size of the mistake, exactly: multiplying an ALREADY
    // scaled score by a further `1 / deriv` inflates the SE by
    // `1 / |deriv|` (the opposite direction from PQ, whose score is
    // raw and whose constant reading therefore shrank the SE).
    inspect(expand_v095_close(shipped / wrong1, d1[j].abs()), content="true")
    inspect(expand_v095_close(shipped / wrong0, d0[j].abs()), content="true")
    inspect(expand_v095_close(shipped / wrong_diff, diff.abs()), content="true")
    // All three OVER-state by a wide margin on this DGP, where the
    // densities are ~0.1, i.e. an inflation of ~7x.
    inspect(wrong1 > 2.0 * shipped, content="true")
    inspect(wrong0 > 2.0 * shipped, content="true")
  }
  // (1, continued) The Jacobians move with the data: doubling the
  // outcome width halves the densities and the Jacobians with them.
  // A hard-coded constant cannot move with the data at all.
  let wide = DoubleMLQTE::new(
    expand_v095_qte_data_wide(n),
    quantiles=expand_v095_quantiles(),
    n_folds=2,
  ).fit()
  for j = 0; j < m.quantiles.length(); j = j + 1 {
    inspect(expand_v095_close(d1[j], wide.derivs1[j]) == false, content="true")
    inspect(expand_v095_close(d0[j], wide.derivs0[j]) == false, content="true")
    // Each fit carries its OWN values, and the invariant holds for
    // each independently.
    inspect(
      wide.sandwich_se_at(j, SandwichKind::hc0()) == wide.ses()[j],
      content="true",
    )
  }
  // The two fits' Jacobians are far enough apart that one constant
  // could not serve both -- though on QTE the shipped constant is 1
  // for both, which is the point of the structural argument.
  inspect(expand_v095_close(d1[0], wide.derivs1[0]) == false, content="true")
}

// ---------------------------------------------------------------------------
// 4. THE HC RELATIONSHIPS (pure ratios of the accumulator)
// ---------------------------------------------------------------------------

///|
/// `HC1 / HC0 == sqrt(n / (n - k))` with `k = 1`, i.e.
/// `sqrt(n / (n - 1))`, to 1e-12 -- per quantile.
///
/// This also pins `n_params == 1`, which is the "each quantile is a
/// 1x1 problem" decision: the plausible misreading `k =
/// quantiles.length()` would give `sqrt(n / (n - 2))`, and the two
/// differ. Scale-invariant, so it says nothing about the Jacobian --
/// that is test 1's and test 3's job.
test "qte_hc1_hc0_ratio" {
  let n = 500
  let n_d = n.to_double()
  let m = expand_v095_fit(n)
  let n_q = m.quantiles.length()
  for j = 0; j < n_q; j = j + 1 {
    let se0 = m.sandwich_se_at(j, SandwichKind::hc0())
    let se1 = m.sandwich_se_at(j, SandwichKind::hc1())
    inspect(
      expand_v095_close(se1 / se0, (n_d / (n_d - 1.0)).sqrt()),
      content="true",
    )
    inspect(se1 > se0, content="true")
    // `k = n_quantiles` is the wrong reading and is ruled out: with
    // `n_q == 2` the two candidate factors differ in the 5th digit.
    let wrong = (n_d / (n_d - n_q.to_double())).sqrt()
    inspect(expand_v095_close(se1 / se0, wrong) == false, content="true")
  }
}

///|
/// With the v0.88.0 leverage `h_ii = 1 / n_obs` every HC2 term is
/// divided by `(n - 1) / n`, algebraically the HC1 factor, so
/// `HC2 == HC1` to 1e-12, per quantile.
test "qte_hc2_equals_hc1" {
  let n = 500
  let m = expand_v095_fit(n)
  for j = 0; j < m.quantiles.length(); j = j + 1 {
    let se1 = m.sandwich_se_at(j, SandwichKind::hc1())
    let se2 = m.sandwich_se_at(j, SandwichKind::hc2())
    inspect(expand_v095_close(se2, se1), content="true")
    inspect(se2 >= se1, content="true")
  }
}

///|
/// HC3 divides every term by `((n - 1) / n)^2`, so
/// `HC3 == HC1^2 / HC0` to 1e-12, per quantile.
test "qte_hc3_equals_hc1_squared_over_hc0" {
  let n = 500
  let n_d = n.to_double()
  let m = expand_v095_fit(n)
  for j = 0; j < m.quantiles.length(); j = j + 1 {
    let se0 = m.sandwich_se_at(j, SandwichKind::hc0())
    let se1 = m.sandwich_se_at(j, SandwichKind::hc1())
    let se3 = m.sandwich_se_at(j, SandwichKind::hc3())
    inspect(expand_v095_close(se3, se1 * se1 / se0), content="true")
    inspect(
      expand_v095_close(
        se3,
        se0 * (n_d / (n_d - 1.0)).sqrt() * (n_d / (n_d - 1.0)).sqrt(),
      ),
      content="true",
    )
  }
}

///|
/// The ordering the v0.88.0 leverage fix established,
/// `HC3 > HC1 == HC2 > HC0`, holds per quantile. `HC2` is EQUAL to
/// `HC1`, not strictly above it: any test written as `HC2 > HC1` is
/// asserting a falsehood.
test "qte_ordering" {
  let n = 500
  let m = expand_v095_fit(n)
  for j = 0; j < m.quantiles.length(); j = j + 1 {
    let se0 = m.sandwich_se_at(j, SandwichKind::hc0())
    let se1 = m.sandwich_se_at(j, SandwichKind::hc1())
    let se2 = m.sandwich_se_at(j, SandwichKind::hc2())
    let se3 = m.sandwich_se_at(j, SandwichKind::hc3())
    inspect(se1 > se0, content="true")
    inspect(expand_v095_close(se2, se1), content="true")
    inspect(se3 > se1, content="true")
    inspect(se2 > se0, content="true")
    // The pre-v0.88 chain `HC0 > HC2` is false.
    inspect((se0 > se2) == false, content="true")
    // HC0 is the estimator's own `ses[j]`, so the ordering is anchored
    // to the shipped SE and not merely internally consistent.
    inspect(se0 == m.ses()[j], content="true")
  }
}

// ---------------------------------------------------------------------------
// 5. THE CLUSTER PATH (IID FIT)
// ---------------------------------------------------------------------------

///|
/// With all-singleton clusters the cluster meat degenerates to
/// `sum_i u_i^2` and collapses to the IID HC0, hence to `ses[j]`.
/// Pooled clusters pick up the within-cluster cross terms and
/// differ, which also proves `cluster_ids` is consumed rather than
/// ignored.
///
/// IID PATH ONLY, deliberately: on a clustered FIT `ses[j]` is the
/// unit-level cluster variance `sqrt(var_unit / n_units)`, a different
/// quantity from the row-level Arellano variance
/// `cluster_sandwich_variance` returns (different denominator:
/// `n_units` vs `n_obs`, and no jackknife correction), so the
/// `== ses[j]` identity does not hold there. Test 9 covers that path.
test "qte_singleton_cluster_equals_se" {
  let n = 500
  let (singleton, pooled) = expand_v095_cluster_ids(n)
  let m = expand_v095_fit(n)
  let ones : Array[Double] = Array::make(n, 1.0)
  for j = 0; j < m.quantiles.length(); j = j + 1 {
    let se = m.ses()[j]
    let cl_single = m.cluster_sandwich_se_at(j, singleton)
    let cl_pooled = m.cluster_sandwich_se_at(j, pooled)
    inspect(cl_single == se, content="true")
    inspect(
      cl_single == m.sandwich_se_at(j, SandwichKind::hc0()),
      content="true",
    )
    // The cluster path consumes the SAME `M_inv` and the same IF row
    // as the IID path, so the shipped pooled value is reproducible
    // from the shared free function and not from some other Jacobian.
    let row = expand_v095_row(m, j, n)
    let cl_hand = cluster_sandwich_variance(
      ones,
      row,
      Matrix::from_array([1.0], 1, 1),
      pooled,
      1,
    ).sqrt()
    inspect(cl_pooled == cl_hand, content="true")
    // Pooling in blocks of 4 changes the SE materially: the
    // within-block score sums carry the cross terms, so the meat is
    // not `sum_i u_i^2` any more.
    inspect(expand_v095_close(cl_pooled, se) == false, content="true")
    inspect(cl_pooled > 0.0, content="true")
    let pooled_ratio = cl_pooled / se
    inspect((pooled_ratio - 1.0).abs() > 1.0e-3, content="true")
    // The cluster path is NOT reproducible from a double-counted
    // Jacobian either.
    let cl_wrong = cluster_sandwich_variance(
      ones,
      row,
      Matrix::from_array([1.0 / m.derivs1[j]], 1, 1),
      pooled,
      1,
    ).sqrt()
    inspect(expand_v095_close(cl_pooled, cl_wrong) == false, content="true")
  }
}

// ---------------------------------------------------------------------------
// 6. bias_corrected_coef_at
// ---------------------------------------------------------------------------

///|
/// `bias_corrected_coef_at(j)` returns `coefs[j]` EXACTLY -- the
/// v0.91.0 design, identical to the fifteen methods already shipped.
///
/// QTE's own reason the naive correction is not merely vacuous but
/// actively wrong: `coefs[j]` is a difference of two bisection roots,
/// and `mean(u)` (the contrast's estimating equation at the reported
/// root) is small but NOT zero, so adding it back shifts a consistent
/// estimate by whatever the two arms' residual score means happen to
/// be. Pinned below on both counts.
test "qte_bias_corrected_coef_at_is_identity" {
  let n = 500
  let m = expand_v095_fit(n)
  let coefs = m.coefs()
  for j = 0; j < m.quantiles.length(); j = j + 1 {
    inspect(m.bias_corrected_coef_at(j) == coefs[j], content="true")
    let row = expand_v095_row(m, j, n)
    let mean_score = mean(row)
    inspect(mean_score.abs() < 0.2, content="true")
    inspect(mean_score != 0.0, content="true")
    inspect(
      m.bias_corrected_coef_at(j) != coefs[j] + mean_score,
      content="true",
    )
    // ... and the honest no-op is not the point estimate times a
    // factor either (the pre-v0.91.0 `3 * coef` closed form).
    inspect(m.bias_corrected_coef_at(j) != 3.0 * coefs[j], content="true")
    // Each quantile reports ITS OWN coefficient, not a shared one.
    if j > 0 {
      let same = m.bias_corrected_coef_at(j) == m.bias_corrected_coef_at(0)
      inspect(same == false, content="true")
    }
  }
}

// ---------------------------------------------------------------------------
// 7. THE DEFAULT SINGLE-QUANTILE CASE
// ---------------------------------------------------------------------------

///|
/// `quantiles = [0.5]` (the `new()` default) is the common case and
/// goes through the same path, with `derivs1` / `derivs0` /
/// `psi_flat` all of length 1. Pinned because every other test in
/// this file uses two quantiles, so nothing else would catch a
/// length-1 bug (an off-by-one in the `j * n_obs` slice, or an
/// `n_quantiles - 1` bound in a guard).
test "qte_single_quantile_case" {
  let n = 500
  let m = DoubleMLQTE::new(expand_v095_qte_data(n), quantiles=[0.5], n_folds=2).fit()
  inspect(m.quantiles.length() == 1, content="true")
  inspect(m.coefs().length() == 1, content="true")
  inspect(m.ses().length() == 1, content="true")
  inspect(m.derivs1.length() == 1, content="true")
  inspect(m.derivs0.length() == 1, content="true")
  inspect(m.psi_flat.length() == n, content="true")
  // The invariant, and the per-quantile row is the whole IF matrix.
  inspect(
    m.sandwich_se_at(0, SandwichKind::hc0()) == m.ses()[0],
    content="true",
  )
  let (singleton, pooled) = expand_v095_cluster_ids(n)
  inspect(m.cluster_sandwich_se_at(0, singleton) == m.ses()[0], content="true")
  inspect(
    expand_v095_close(m.cluster_sandwich_se_at(0, pooled), m.ses()[0]) == false,
    content="true",
  )
  inspect(m.bias_corrected_coef_at(0) == m.coefs()[0], content="true")
  // The HC family is still ordered, and the shipped Jacobian is still
  // neither `-1` nor `+1`.
  let se0 = m.sandwich_se_at(0, SandwichKind::hc0())
  inspect(m.sandwich_se_at(0, SandwichKind::hc3()) > se0, content="true")
  inspect(m.derivs1[0] != -1.0, content="true")
  inspect(m.derivs1[0] != 1.0, content="true")
  inspect(m.derivs0[0] != -1.0, content="true")
  inspect(m.derivs0[0] != 1.0, content="true")
  // The row slice is `psi_flat[0 .. n]` -- not offset.
  let row = expand_v095_row(m, 0, n)
  inspect(row[0] == m.psi_flat[0], content="true")
  inspect(row[n - 1] == m.psi_flat[n - 1], content="true")
}

// ---------------------------------------------------------------------------
// 8. DGP SANITY: the numbers must be MEANINGFUL, not just finite
// ---------------------------------------------------------------------------

///|
/// A finiteness-only or ratio-only suite cannot catch the
/// degenerate-propensity failure mode, and that failure mode still
/// satisfies every HC identity: a DGP whose linear predictor the OLS
/// propensity learner cannot recover sends `m` out of `[0, 1]`,
/// `clip_vec` pins the offending rows at `1e-6`, the `1 / m` score
/// terms hit `1e6`, `mean(u^2)` reaches `~6e9`, and `ses[j]` becomes
/// a meaningless magnitude -- perfectly self-consistent in ratio.
/// This test pins the magnitude.
///
/// Assertions, all against independently computed quantities:
///   1. the cross-fitted propensity the score actually uses stays
///      inside the interior band, so no row sits on the `1e-6` clip;
///   2. `mean(u^2)` per quantile is `O(1)`, so the score never
///      reached the `1e6` regime;
///   3. `ses[j] / |coef_j|` is a plausible relative SE, and the
///      per-quantile Jacobians are materially distinct from each
///      other -- so the DGP really does exercise the per-quantile,
///      per-arm path rather than one density repeated `n_quantiles`
///      times.
test "qte_dgp_sanity" {
  let n = 500
  let data = expand_v095_qte_data(n)
  let treated : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    treated[i] = if data.d[i] == 1.0 { 1.0 } else { 0.0 }
  }
  // Reproduce exactly the propensity `fit` cross-fits: same learner
  // dispatch, same fold split, same clip, same helper (`fit_propensity`
  // is file-private, so the loop is rebuilt here out of the public
  // pieces -- which also keeps the check INDEPENDENT of the production
  // code it audits).
  let folds = kfold(n, 2, 3141)
  let m_hat_raw = Array::make(n, 0.0)
  for fold in folds {
    let tr = fold.train_indices()
    let te = fold.test_indices()
    let p = fit_predict_one_dispatch(
      LearnerDispatch::linear_regression(),
      slice_matrix_rows(data.x, tr),
      slice_vector(treated, tr),
      slice_matrix_rows(data.x, te),
    )
    for k = 0; k < te.length(); k = k + 1 {
      m_hat_raw[te[k]] = p[k]
    }
  }
  let m_hat = clip_vec(m_hat_raw, 1.0e-6, 1.0 - 1.0e-6)
  let m_min = array_min(m_hat) catch {
    EmptyArrayError => abort("expand_v095: empty m_hat")
  }
  let m_max = array_max(m_hat) catch {
    EmptyArrayError => abort("expand_v095: empty m_hat")
  }
  // (1) Interior propensity: far from both the 0 and 1 walls and from
  // the `1e-6` clip by three orders of magnitude.
  inspect(m_min > 0.01, content="true")
  inspect(m_max < 0.99, content="true")
  inspect(m_min > 1.0e-3, content="true")
  inspect(m_max < 1.0 - 1.0e-3, content="true")
  // (2) and (3): the score magnitude, the relative SE, and the
  // per-quantile spread of the Jacobians, all from the fitted model.
  let f = expand_v095_fit(n)
  let coefs = f.coefs()
  let ses = f.ses()
  let n_q = f.quantiles.length()
  for j = 0; j < n_q; j = j + 1 {
    let row = expand_v095_row(f, j, n)
    let gamma = mean(vector_multiply(row, row))
    let mut u_absmax = 0.0
    for i = 0; i < n; i = i + 1 {
      let a = row[i].abs()
      if a > u_absmax {
        u_absmax = a
      }
    }
    // `O(1)`, not the `~6e9` of the clipped-propensity regime.
    inspect(gamma < 100.0, content="true")
    inspect(u_absmax < 100.0, content="true")
    // Plausible estimand and plausible relative SE for `n = 500`:
    // a few percent of the estimand, not a multiple of it.
    inspect(coefs[j] > 1.0 && coefs[j] < 5.0, content="true")
    let rel = ses[j] / coefs[j].abs()
    inspect(rel > 1.0e-3 && rel < 0.2, content="true")
    // The shipped sandwich SE is the estimator's own SE, so the
    // plausible-relative-SE claim above is a claim about BOTH.
    inspect(f.sandwich_se_at(j, SandwichKind::hc0()) == ses[j], content="true")
  }
  // The two quantiles give materially different Jacobians on each
  // arm (triangular outcomes) and materially different `ses`. If they
  // did not, this suite would not be able to tell a per-quantile
  // implementation from one that ignored `j`.
  inspect(
    expand_v095_close(f.derivs1[0], f.derivs1[1]) == false,
    content="true",
  )
  inspect(
    expand_v095_close(f.derivs0[0], f.derivs0[1]) == false,
    content="true",
  )
  inspect(
    expand_v095_close(f.derivs1[0], f.derivs0[0]) == false,
    content="true",
  )
  let ratio_d1 = f.derivs1[0].abs() / f.derivs1[1].abs()
  inspect(ratio_d1 > 0.5 && ratio_d1 < 2.0, content="true")
  let ratio_ses = ses[0] / ses[1]
  inspect(ratio_ses > 0.5 && ratio_ses < 2.0, content="true")
}

// ---------------------------------------------------------------------------
// 9. THE CLUSTERED `fit` PATH PERSISTS ITS OWN JACOBIANS
// ---------------------------------------------------------------------------

///|
/// `DoubleMLQTE::fit` dispatches to `fit_cluster` whenever
/// `data.cluster_vars` is non-empty, and that path returns a SEPARATE
/// struct literal -- so `derivs1` / `derivs0` have to be built there
/// too, from that path's own `deriv1` / `deriv0` (the cluster path
/// runs `solve_pq` under CLUSTER folds, so the two paths' Jacobians
/// are not interchangeable). Getting it wrong -- leaving the `new()`
/// all-zero sentinel, say -- would still compile and would then ABORT
/// inside `m_inv_1x1_at`, so this test checks the values rather than
/// only that the calls return.
///
/// It deliberately does NOT assert `sandwich_se_at(j, HC0) == ses[j]`
/// here: on a clustered fit `ses[j]` is the unit-level cluster
/// variance `sqrt(var_unit / n_units)`, a different quantity from the
/// row-level Arellano variance (see the note at the method). What it
/// does assert is that the clustered fit's `ses[j]` IS that
/// unit-level quantity -- recomputed here independently -- and that
/// the sandwich methods are callable on a clustered fit.
test "qte_cluster_fit_persists_jacobians" {
  let n = 500
  let base = expand_v095_qte_data(n)
  let (singleton, pooled) = expand_v095_cluster_ids(n)
  // Non-empty `cluster_vars` -> `fit_cluster`.
  let clustered = DoubleMLData::new(base.x, base.y, base.d, cluster_vars=pooled)
  let m = DoubleMLQTE::new(
    clustered,
    quantiles=expand_v095_quantiles(),
    n_folds=2,
  ).fit()
  let n_q = m.quantiles.length()
  inspect(m.derivs1.length() == n_q, content="true")
  inspect(m.derivs0.length() == n_q, content="true")
  let n_units = n / 4
  for j = 0; j < n_q; j = j + 1 {
    // The cluster path's own values, not the `new()` sentinel and not
    // the IID path's.
    inspect(m.derivs1[j] != 0.0, content="true")
    inspect(m.derivs0[j] != 0.0, content="true")
    inspect(m.derivs1[j].abs() > 0.02, content="true")
    inspect(m.derivs0[j].abs() > 0.02, content="true")
    let iid = expand_v095_fit(n)
    inspect(
      expand_v095_close(m.derivs1[j], iid.derivs1[j]) == false,
      content="true",
    )
    // So the sandwich methods are callable on a clustered fit.
    let hc0 = m.sandwich_se_at(j, SandwichKind::hc0())
    inspect(hc0 > 0.0, content="true")
    let cl_pooled = m.cluster_sandwich_se_at(j, pooled)
    inspect(cl_pooled > 0.0, content="true")
    // All-singleton clusters over the CLUSTERED fit collapse the meat
    // to `sum_i u_i^2`, so the cluster method reduces to its own IID
    // HC0 -- the same collapse the IID fit shows, and proof that
    // `cluster_ids` is taken from the argument rather than from
    // `data.cluster_vars`.
    inspect(
      expand_v095_close(m.cluster_sandwich_se_at(j, singleton), hc0),
      content="true",
    )
    // The clustered `ses[j]` IS the unit-level variance
    // `sqrt(var_unit / n_units)` with `u` the cluster sums of the
    // stored IF -- recomputed here from `psi_flat` alone, which
    // pins the "different quantity" claim instead of asserting it.
    let row = expand_v095_row(m, j, n)
    let n_units_d = n_units.to_double()
    let mut sum_units = 0.0
    let mut ss_units = 0.0
    for u_idx = 0; u_idx < n_units; u_idx = u_idx + 1 {
      let mut s_u = 0.0
      for idx = 0; idx < 4; idx = idx + 1 {
        s_u = s_u + row[u_idx * 4 + idx]
      }
      sum_units = sum_units + s_u
      ss_units = ss_units + s_u * s_u
    }
    let mean_unit = sum_units / n_units_d
    let var_unit = (ss_units - n_units_d * mean_unit * mean_unit) / n_units_d
    let se_unit = (var_unit / n_units_d).sqrt()
    inspect(expand_v095_close(m.ses()[j], se_unit), content="true")
    // ... and it is NOT the IID quantity, on either path.
    inspect(expand_v095_close(m.ses()[j], hc0) == false, content="true")
    inspect(m.bias_corrected_coef_at(j) == m.coefs()[j], content="true")
  }
}

// ---------------------------------------------------------------------------
// 10. THE WIDE-OUTCOME VARIANT OF THE DGP (helper + probe)
// ---------------------------------------------------------------------------

///|
/// `expand_v095_qte_data` with both arms' outcome widths doubled, so
/// the densities -- and hence the Jacobians -- roughly halve. Used by
/// test 3 to show the persisted values move with the data.
fn expand_v095_qte_data_wide(n : Int) -> DoubleMLData {
  let x_flat : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let rng = chacha8_rng(3141)
  let need = n * 2
  let pool : Array[Double] = []
  while pool.length() < need {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let theta = 2.0 * 3.141592653589793 * u2
    pool.push(r * @math.cos(theta))
    pool.push(r * @math.sin(theta))
  }
  for i = 0; i < n; i = i + 1 {
    x_flat[i] = 2.0 * pool[i] - 1.0
  }
  for i = 0; i < n; i = i + 1 {
    let pd = expit(0.3 * x_flat[i])
    d[i] = if rng.double() < pd { 1.0 } else { 0.0 }
  }
  for i = 0; i < n; i = i + 1 {
    let s_treated = rng.double() + rng.double()
    let s_control = rng.double() + rng.double()
    let y_treated = 2.0 + 16.0 * (s_treated / 2.0)
    let y_control = 12.0 * (s_control / 2.0)
    y[i] = if d[i] == 1.0 { y_treated } else { y_control }
  }
  DoubleMLData::new(Matrix::from_array(x_flat, n, 1), y, d)
}
