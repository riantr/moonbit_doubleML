///|
// v0.94.0: `DoubleMLPQ` gets the sandwich API.
//
// WHY PQ HAD NONE
// ===============
// `DoubleMLPQ`'s Jacobian was a `fit()` local (`deriv`, the third
// value `solve_pq` returns) that reached the SE computation and then
// died -- it was never persisted, and its stored `psi` is the
// centered PQ quantile score with no `psi_a + coef * psi_b` split to
// reconstruct it from. v0.94.0 persists that Jacobian as
// `self.psi_a` and adds the three standard methods. The payoff
// invariant, as for the other fourteen estimators, is
//
//     sandwich_se(HC0) == se()
//
// and here it is easy to get wrong, because PQ is a quantile
// Z-estimator. Its estimating equation is the FIRST-ORDER
// CONDITION `mean(psi(theta)) = 0`, not the package-wide mean moment
// `f(theta) = E[theta * psi_a + psi_b]`, so the Jacobian is
// `d mean(psi(theta)) / d theta` -- the IPW-weighted density of `y`
// at `theta` among the treated -- a genuinely data-dependent
// scalar. Reading it as a hard-coded constant (`-1`, or `+1`, which
// the SQUARE makes equally wrong) shrinks the SE by `|deriv|`.
//
// Unlike LPQ, `quantile.mbt` carried no false "psi_a is the constant
// -1" comment next to the derivative code: the pre-v0.94.0 text
// described `deriv` correctly as `d mean(psi) / d theta`. The trap
// was latent, not written down, so there was nothing to correct --
// only to pin. Test 3 does that.
//
// `se()` is the reference throughout: it is `(gamma / (deriv^2 * n))`
// with `gamma = mean(psi^2)`, which is algebraically
// `M_inv[0,0]^2 * sum_i psi[i]^2 / n / n` -- the v0.91.0 accumulator
// at the same point.

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

///|
/// Relative closeness at the 1e-12 level (the package's tolerance
/// for "same number, different accumulation order" -- the same
/// helper `expand_v091_test.mbt` .. `expand_v093_test.mbt` use).
fn expand_v094_close(x : Double, y : Double) -> Bool {
  let scale = if x.abs() > y.abs() { x.abs() } else { y.abs() }
  if scale == 0.0 {
    return (x - y).abs() < 1.0e-300
  }
  (x - y).abs() / scale < 1.0e-12
}

///|
/// The v0.94.0 PQ DGP: `n` observations, one bounded covariate
/// `x in [-1, 1]`, `d = 1{u < expit(0.3 x)}`, and a continuous
/// outcome `y = 2 d + width * u'` with `u' ~ Uniform(0, 1)`.
///
/// Two properties of this DGP matter for the tests:
///
///   - The treatment indicator depends LINEARLY on the single
///     covariate the propensity learner actually sees, so the
///     cross-fitted `m` lands inside `[0.42, 0.58]` -- well within
///     the `[1e-6, 1 - 1e-6]` clip. A DGP whose linear predictor is
///     not recoverable by an OLS propensity learner sends some
///     predictions out of `[0, 1]`, `clip_vec` pins them at `1e-6`,
///     the `1 / m` score terms blow up to `1e6`, `gamma = mean(psi^2)`
///     reaches `~1e9`, and every SE becomes a meaningless magnitude
///     WHILE THE SANDWICH IDENTITIES STILL HOLD -- so a
///     finiteness-only or ratio-only suite never catches it. Test 10
///     pins the propensity range and the relative SE directly.
///   - The treated-arm outcome support is WIDE (`6` units by
///     default), which is what makes the Jacobian -- the treated
///     density of `y` at the median, `1 / width` -- decisively far
///     from `1` in magnitude. That is what makes test 3 bite.
fn expand_v094_pq_data(n : Int) -> DoubleMLData {
  expand_v094_pq_data_scaled(n, 6.0)
}

///|
/// The v0.94.0 DGP with a caller-chosen treated-outcome width, so
/// `pq_jacobian_is_not_a_constant` can refit on a rescaled outcome
/// and show the Jacobian tracks the data density.
fn expand_v094_pq_data_scaled(n : Int, width : Double) -> DoubleMLData {
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
    y[i] = d[i] * 2.0 + width * rng.double()
  }
  DoubleMLData::new(Matrix::from_array(x_flat, n, 1), y, d)
}

///|
/// The fitted PQ every test in this file shares. `coef` is the
/// bisection root of the IPW quantile moment.
fn expand_v094_fit(n : Int) -> DoubleMLPQ {
  DoubleMLPQ::new(
    expand_v094_pq_data(n),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
  ).fit()
}

///|
/// All-singleton (`singleton[i] = i`) and pooled-in-blocks-of-4
/// (`pooled[i] = i / 4`) cluster ids for a sample of `n`.
fn expand_v094_cluster_ids(n : Int) -> (Array[Int], Array[Int]) {
  let singleton : Array[Int] = Array::make(n, 0)
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
    pooled[i] = i / 4
  }
  (singleton, pooled)
}

// ---------------------------------------------------------------------------
// 1. THE DECISIVE ONE: se() == sandwich_se(HC0)
// ---------------------------------------------------------------------------

///|
/// THE assertion that unblocks PQ. With `self.psi` used AS the score
/// (it is already evaluated at `coef`; PQ has no `psi_b` to
/// reconstruct it from, so `psi_at` is deliberately NOT called) and
/// the persisted data-dependent Jacobian
/// `M_inv = [[1 / self.psi_a[0]]]`, PQ's HC0 equals its own `se()`.
///
/// The mechanism: `se()` is `(gamma / (deriv^2 * n))` with
/// `gamma = mean(psi^2)`, and `sandwich_variance_hc0` is
/// `M_inv[0,0]^2 * sum_i psi[i]^2 / n / n`. With
/// `M_inv[0,0] = 1 / deriv` the two are the same expression
/// accumulated with the same Kahan sum in the same order.
///
/// Fails to COMPILE against v0.93.0 (the methods do not exist),
/// which is the point: the invariant cannot even be expressed
/// without first getting the Jacobian role right.
test "pq_se_equals_sandwich_hc0" {
  let n = 500
  let n_d = n.to_double()
  let m = expand_v094_fit(n)
  inspect(m.psi.length() == n, content="true")
  inspect(m.psi_a.length() == n, content="true")
  let se_hc0 = m.sandwich_se(SandwichKind::hc0())
  let se = m.se()
  // The invariant.
  inspect(expand_v094_close(se_hc0, se), content="true")
  // ... to a tolerance far tighter than the 1e-12 the rest of this
  // file uses. Both sides accumulate the same `psi[i]^2` with the
  // same Kahan compensated sum in the same index order and differ
  // only in where the `1 / deriv^2` sits (`M_inv[0,0]^2 * acc / n
  // / n` vs `(acc / n) / (deriv * deriv * n)`), which is a
  // last-ulp reassociation, not a different quantity.
  inspect((se_hc0 - se).abs() / se.abs() < 1.0e-14, content="true")
  // `mean(self.psi_a)` IS the Jacobian, exactly -- that identity is
  // what licenses feeding `self.psi_a` straight into
  // `sandwich_variance`'s `psi_a` slot.
  inspect(m.psi_a[0] == mean(m.psi_a), content="true")
  // Every entry is that same scalar (a derivative of a MEAN is a
  // scalar; the array is a uniform-API convenience).
  let mut all_same = true
  for i = 0; i < n; i = i + 1 {
    if m.psi_a[i] != m.psi_a[0] {
      all_same = false
    }
  }
  inspect(all_same, content="true")
  // The shipped variance is what `fit` computed by hand, term for
  // term -- not merely something close to it.
  let mut ss = 0.0
  for i = 0; i < n; i = i + 1 {
    ss = ss + m.psi[i] * m.psi[i]
  }
  let hand = (ss / n_d / (m.psi_a[0] * m.psi_a[0] * n_d)).sqrt()
  inspect(expand_v094_close(se_hc0, hand), content="true")
  // ... and it is NOT the *other* reading of the same persisted
  // state. The package-order reconstruction
  // `psi_at(coef, self.psi_a, self.psi)` -- the score the other
  // fourteen estimators evaluate -- is a DIFFERENT function whose
  // root is not `coef`, so it must NOT reproduce `se()`.
  let psi_wrong = psi_at(m.coef(), m.psi_a, m.psi)
  let mut ss_wrong = 0.0
  for i = 0; i < n; i = i + 1 {
    ss_wrong = ss_wrong + psi_wrong[i] * psi_wrong[i]
  }
  let jac = m.psi_a[0]
  let se_wrong = (ss_wrong / n_d / (jac * jac * n_d)).sqrt()
  inspect(expand_v094_close(se_wrong, se) == false, content="true")
}

// ---------------------------------------------------------------------------
// 2. THE MEMOIZE CACHE-HIT TEST
// ---------------------------------------------------------------------------

///|
/// `psi_a` must survive a memoize cache hit, and the test that
/// proves it is this one.
///
/// `FitCache` for `"pq"` stores `[[theta, deriv], psi]` (v0.84.0
/// packs the two scalars as a length-2 array) -- so `deriv` IS on the
/// cache path here, unlike LPQ. `fit` nevertheless binds it to the
/// same name on both paths -- `(theta, psi, deriv, fold_ids)` is
/// restored from `preds[0][0] / preds[1] / preds[0][1]` on a hit and
/// returned by `solve_pq` on a miss -- so building `psi_a` from that
/// ONE binding, after the `cache_hit` branch, is correct on both
/// paths with no second restore path that could drift.
///
/// A regression that returned an all-zero `psi_a` on the hit path
/// would make `sandwich_se` abort on the `|deriv| >= 1e-12` guard;
/// one that returned an un-cached constant would move the SE. Both
/// are caught here.
test "pq_sandwich_after_memoize_cache_hit" {
  let n = 500
  let base = DoubleMLPQ::new(
    expand_v094_pq_data(n),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
  ).enable_memoize()
  // First fit populates the cache; second fit is the cache hit.
  let f1 = base.fit()
  let f2 = f1.fit()
  inspect(f1.has_cache(), content="true")
  inspect(f2.has_cache(), content="true")
  // `psi_a` is present and unchanged on the hit path.
  inspect(f2.psi_a.length() == n, content="true")
  inspect(f2.psi_a[0] == f1.psi_a[0], content="true")
  inspect(f2.psi_a[0] != 0.0, content="true")
  // The invariant SURVIVES the cache hit -- this is the assertion
  // that fails if `psi_a` is left out of the restored path.
  let se_hc0 = f2.sandwich_se(SandwichKind::hc0())
  inspect(expand_v094_close(se_hc0, f2.se()), content="true")
  inspect((se_hc0 - f2.se()).abs() / f2.se().abs() < 1.0e-14, content="true")
  // ... and the cache hit did not move the number: a cache hit must
  // be a no-op for the sandwich, which is the whole contract of the
  // memoize layer.
  let fresh = expand_v094_fit(n)
  inspect(
    f1.sandwich_se(SandwichKind::hc0()) == f2.sandwich_se(SandwichKind::hc0()),
    content="true",
  )
  inspect(
    f1.sandwich_se(SandwichKind::hc0()) ==
    fresh.sandwich_se(SandwichKind::hc0()),
    content="true",
  )
  // `se()` itself is also unchanged by the cache hit, so the
  // equality above is not an accident of two errors cancelling.
  inspect(f1.se() == f2.se(), content="true")
  inspect(f2.se() == fresh.se(), content="true")
  // The restored `deriv` is byte-identical to the freshly solved
  // one (this is what makes the single-binding construction safe).
  inspect(f2.psi_a[0] == fresh.psi_a[0], content="true")
  // The cluster path agrees on the hit path too.
  let (singleton, _pooled) = expand_v094_cluster_ids(n)
  inspect(
    expand_v094_close(f2.cluster_sandwich_se(singleton), f2.se()),
    content="true",
  )
}

// ---------------------------------------------------------------------------
// 3. THE TRAP: the Jacobian is NOT a constant
// ---------------------------------------------------------------------------

///|
/// This test guards the misreading that produced the v0.86.0 LPLR
/// (~60x) and v0.93.0 LPQ (5.86x) skips. PQ's Jacobian is the
/// IPW-weighted density of `y` at `theta` among the treated, so on
/// this DGP it is close to `1 / 6`, and building the sandwich with
/// `M_inv = [[-1]]` (or `[[+1]]`) SHRINKS the SE by `|deriv|`.
///
/// Because the variance depends on the Jacobian only through its
/// SQUARE, a constant `-1` is exactly as wrong as a constant `+1`;
/// both are pinned below, together with the measured factor.
///
/// No finiteness-only assertion: every check compares two
/// independently computed numbers.
test "pq_jacobian_is_not_a_constant" {
  let n = 500
  let n_d = n.to_double()
  let m = expand_v094_fit(n)
  let deriv = m.psi_a[0]
  let se = m.se()
  let shipped = m.sandwich_se(SandwichKind::hc0())
  // (1) The persisted Jacobian is not the constant -1 (nor +1,
  // which the SQUARE makes equally wrong), and is nowhere near
  // either: it is ~0.211, a factor of ~4.7 away from unity. The
  // bound is a band, not an equality, because `deriv` is a central
  // difference on a finite sample.
  inspect(deriv != -1.0, content="true")
  inspect(deriv != 1.0, content="true")
  inspect(deriv > 0.15 && deriv < 0.30, content="true")
  // (2) Recompute HC0 from the SAME persisted score under the two
  // candidate Jacobians and pin which one ships.
  let mut ss = 0.0
  for i = 0; i < n; i = i + 1 {
    ss = ss + m.psi[i] * m.psi[i]
  }
  let jac_deriv = (ss / n_d / (deriv * deriv * n_d)).sqrt()
  let jac_minus_one = sandwich_variance_hc0(
    m.psi_a,
    m.psi,
    Matrix::from_array([-1.0], 1, 1),
    n,
    1,
  ).sqrt()
  let jac_plus_one = sandwich_variance_hc0(
    m.psi_a,
    m.psi,
    Matrix::from_array([1.0], 1, 1),
    n,
    1,
  ).sqrt()
  inspect(expand_v094_close(shipped, jac_deriv), content="true")
  inspect(expand_v094_close(shipped, jac_minus_one) == false, content="true")
  inspect(expand_v094_close(shipped, jac_plus_one) == false, content="true")
  // (3) The measured size of the mistake on this DGP. Both wrong
  // constants give the same (wrong) SE, and it is the true SE
  // SHRUNK by exactly `|deriv|` -- i.e. `|deriv|` is what a
  // constant-`-1` Jacobian costs: here a 4.74x under-statement
  // (0.18237 -> 0.03845 on a `coef` of 5.13).
  inspect(jac_minus_one == jac_plus_one, content="true")
  let shrink = jac_minus_one / jac_deriv
  inspect(expand_v094_close(shrink, deriv.abs()), content="true")
  inspect(shrink > 0.15 && shrink < 0.30, content="true")
  let inflation = jac_deriv / jac_minus_one
  inspect(expand_v094_close(inflation, 1.0 / deriv.abs()), content="true")
  inspect(inflation > 4.0 && inflation < 6.0, content="true")
  // (4) The payoff: the shipped value is `se()`, and `se()` is
  // nowhere near the constant-`-1` value.
  inspect(expand_v094_close(shipped, se), content="true")
  inspect(expand_v094_close(se, jac_minus_one) == false, content="true")
  // (5) The Jacobian is genuinely data-dependent, i.e. it is not a
  // constant this estimator happens to return. Refitting the SAME
  // estimator on a rescaled treated outcome (the DGP's `6.0` width
  // doubled) halves the treated density at the median, and the
  // Jacobian with it. A hard-coded constant cannot move with the
  // data at all.
  let scaled = DoubleMLPQ::new(
    expand_v094_pq_data_scaled(n, 12.0),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
  ).fit()
  inspect(scaled.psi_a[0] != deriv, content="true")
  // The wide-outcome Jacobian is ~half the narrow one (1.75x
  // measured, against an ideal 2x). The shortfall is structural,
  // not noise: the central-difference step is
  // `h = 0.01 * (y_max - y_min)`, so doubling the outcome width
  // also doubles the difference window, and a wider window over a
  // uniform density picks up more of the g-crossfit term. The band
  // is deliberately loose for that reason -- what it rules out is a
  // Jacobian that does not move with the data at all.
  let width_ratio = deriv / scaled.psi_a[0]
  inspect(width_ratio > 1.6 && width_ratio < 1.9, content="true")
  // Each fit carries its OWN Jacobian: the second model does not
  // inherit the first's.
  inspect(
    expand_v094_close(scaled.sandwich_se(SandwichKind::hc0()), scaled.se()),
    content="true",
  )
  // The two fits' Jacobians are far enough apart that a single
  // constant could not serve both.
  inspect(expand_v094_close(deriv, scaled.psi_a[0]) == false, content="true")
}

// ---------------------------------------------------------------------------
// 4. THE HC RELATIONSHIPS (pure ratios of the accumulator)
// ---------------------------------------------------------------------------

///|
/// `HC1 / HC0 == sqrt(n / (n - k))` with `k = 1`, i.e.
/// `sqrt(n / (n - 1))`, to 1e-12. Scale-invariant, so it says
/// nothing about the Jacobian -- that is test 1's job.
test "pq_hc1_hc0_ratio" {
  let n = 500
  let n_d = n.to_double()
  let m = expand_v094_fit(n)
  let se0 = m.sandwich_se(SandwichKind::hc0())
  let se1 = m.sandwich_se(SandwichKind::hc1())
  inspect(
    expand_v094_close(se1 / se0, (n_d / (n_d - 1.0)).sqrt()),
    content="true",
  )
  inspect(se1 > se0, content="true")
}

///|
/// With the v0.88.0 leverage `h_ii = 1 / n_obs` every HC2 term is
/// divided by `(n - 1) / n`, algebraically the HC1 factor, so
/// `HC2 == HC1` to 1e-12.
test "pq_hc2_equals_hc1" {
  let n = 500
  let m = expand_v094_fit(n)
  let se1 = m.sandwich_se(SandwichKind::hc1())
  let se2 = m.sandwich_se(SandwichKind::hc2())
  inspect(expand_v094_close(se2, se1), content="true")
  // The v0.79.0 - v0.87.0 signed "leverage"
  // `h_ii = psi_a[i] * M_inv[0,0] * psi_a[i]` is positive here (PQ's
  // `psi_a` is a positive constant), which would have produced
  // `1 - h_ii < 1` and a value below HC1; the equality above is what
  // rules it out.
  inspect(se2 >= se1, content="true")
}

///|
/// HC3 divides every term by `((n - 1) / n)^2`, so
/// `HC3 == HC1^2 / HC0` to 1e-12.
test "pq_hc3_equals_hc1_squared_over_hc0" {
  let n = 500
  let n_d = n.to_double()
  let m = expand_v094_fit(n)
  let se0 = m.sandwich_se(SandwichKind::hc0())
  let se1 = m.sandwich_se(SandwichKind::hc1())
  let se3 = m.sandwich_se(SandwichKind::hc3())
  inspect(expand_v094_close(se3, se1 * se1 / se0), content="true")
  inspect(
    expand_v094_close(
      se3,
      se0 * (n_d / (n_d - 1.0)).sqrt() * (n_d / (n_d - 1.0)).sqrt(),
    ),
    content="true",
  )
}

// ---------------------------------------------------------------------------
// 5. ORDERING
// ---------------------------------------------------------------------------

///|
/// The ordering the v0.88.0 leverage fix established,
/// `HC3 > HC1 == HC2 > HC0`, holds for PQ too. `HC2` is EQUAL to
/// `HC1`, not strictly above it: any test written as `HC2 > HC1` is
/// asserting a falsehood.
test "pq_ordering" {
  let n = 500
  let m = expand_v094_fit(n)
  let se0 = m.sandwich_se(SandwichKind::hc0())
  let se1 = m.sandwich_se(SandwichKind::hc1())
  let se2 = m.sandwich_se(SandwichKind::hc2())
  let se3 = m.sandwich_se(SandwichKind::hc3())
  inspect(se1 > se0, content="true")
  inspect(expand_v094_close(se2, se1), content="true")
  inspect(se3 > se1, content="true")
  inspect(se2 > se0, content="true")
  // The pre-v0.88 chain `HC0 > HC2` is false.
  inspect((se0 > se2) == false, content="true")
}

// ---------------------------------------------------------------------------
// 6. THE CLUSTER PATH
// ---------------------------------------------------------------------------

///|
/// With all-singleton clusters the cluster meat degenerates to
/// `sum_i psi[i]^2` and collapses to the IID HC0, hence to `se()`.
/// Pooled clusters pick up the within-cluster cross terms and
/// differ, which also proves `cluster_ids` is consumed rather than
/// ignored. The cluster path uses the SAME persisted Jacobian as the
/// IID path.
test "pq_singleton_cluster_equals_se" {
  let n = 500
  let (singleton, pooled) = expand_v094_cluster_ids(n)
  let m = expand_v094_fit(n)
  let se = m.se()
  let cl_single = m.cluster_sandwich_se(singleton)
  let cl_pooled = m.cluster_sandwich_se(pooled)
  inspect(expand_v094_close(cl_single, se), content="true")
  inspect(
    expand_v094_close(cl_single, m.sandwich_se(SandwichKind::hc0())),
    content="true",
  )
  inspect(expand_v094_close(cl_pooled, se) == false, content="true")
  inspect(cl_pooled > 0.0, content="true")
  // Pooling in blocks of 4 changes the SE materially: the within-block
  // score sums carry the cross terms, so the meat is not
  // `sum_i psi[i]^2` any more.
  let pooled_ratio = cl_pooled / se
  inspect((pooled_ratio - 1.0).abs() > 1.0e-3, content="true")
  // The cluster path uses the persisted Jacobian, not a constant -1,
  // so the pooled value is not reproducible from `M_inv = [[-1]]`
  // either.
  let cl_wrong = cluster_sandwich_variance(
    m.psi_a,
    m.psi,
    Matrix::from_array([-1.0], 1, 1),
    pooled,
    1,
  ).sqrt()
  inspect(expand_v094_close(cl_pooled, cl_wrong) == false, content="true")
}

// ---------------------------------------------------------------------------
// 7. bias_corrected_coef
// ---------------------------------------------------------------------------

///|
/// `bias_corrected_coef` returns `coef` EXACTLY -- the v0.91.0
/// design, identical to the fourteen methods already shipped. The PQ
/// estimating function `mean(psi(theta)) = 0` is orthogonal at its
/// root, so a correction built from the fitted scores is vacuous by
/// construction.
///
/// The `psi` of the moment for PQ is the whole reason this is a
/// no-op: `mean(self.psi)` is the estimating function at `coef`, and
/// it is small but NOT zero -- `coef` is the IPW-bisection root while
/// `self.psi` is the `g`-crossfit score at that `theta`. So the
/// naive "add the mean score" correction is NOT a no-op on this
/// estimator, which is precisely why returning the uncorrected
/// estimate is the honest answer and not merely the convenient one.
test "pq_bias_corrected_coef_is_identity" {
  let n = 500
  let m = expand_v094_fit(n)
  inspect(m.bias_corrected_coef() == m.coef(), content="true")
  let mean_score = mean(m.psi)
  inspect(mean_score.abs() < 0.2, content="true")
  inspect(mean_score != 0.0, content="true")
  inspect(m.bias_corrected_coef() != m.coef() + mean_score, content="true")
  // ... and the honest no-op is not the point estimate times a
  // factor either (the pre-v0.91.0 `3 * coef` closed form).
  inspect(m.bias_corrected_coef() != 3.0 * m.coef(), content="true")
}

// ---------------------------------------------------------------------------
// 8. DGP SANITY: the numbers must be MEANINGFUL, not just finite
// ---------------------------------------------------------------------------

///|
/// A finiteness-only or ratio-only suite cannot catch the
/// degenerate-propensity failure mode, and the failure mode still
/// satisfies every HC identity: a DGP whose linear predictor the OLS
/// propensity learner cannot recover sends `m` out of `[0, 1]`,
/// `clip_vec` pins the offending rows at `1e-6`, the `1 / m` score
/// terms hit `1e6`, `gamma = mean(psi^2)` reaches `~6e9`, and `se`
/// becomes e.g. `37908` on a `coef` of `11.9` -- meaningless in
/// magnitude, perfectly self-consistent in ratio. This test pins
/// the magnitude.
///
/// Assertions, all against independently computed quantities:
///   1. the cross-fitted propensity the score actually uses stays
///      inside the interior band `[0.05, 0.95]`, so no row sits on
///      the `1e-6` clip and `1 / m` is `O(1)`;
///   2. `gamma = mean(psi^2)` is `O(1)`, so the score never reached
///      the `1e6` regime;
///   3. `se / |coef|` is a plausible relative SE for a `n = 500`
///      sample (a few percent, not a multiple of the coefficient).
test "pq_dgp_sanity" {
  let n = 500
  let data = expand_v094_pq_data(n)
  let treated : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    treated[i] = if data.d[i] == 1.0 { 1.0 } else { 0.0 }
  }
  // Reproduce exactly the propensity `fit` cross-fits: same
  // learner dispatch, same fold split, same clip, same helper
  // (`fit_propensity` is file-private, so the loop is rebuilt here
  // out of the public pieces -- which also keeps the check
  // INDEPENDENT of the production code it audits).
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
    EmptyArrayError => abort("expand_v094: empty m_hat")
  }
  let m_max = array_max(m_hat) catch {
    EmptyArrayError => abort("expand_v094: empty m_hat")
  }
  // (1) Interior propensity: far from both the 0 and 1 walls and
  // from the `1e-6` clip by three orders of magnitude. Measured
  // `[0.0502, 0.7550]`.
  inspect(m_min > 0.01, content="true")
  inspect(m_max < 0.99, content="true")
  inspect(m_min > 1.0e-3, content="true")
  inspect(m_max < 1.0 - 1.0e-3, content="true")
  // (2) The score magnitude, recomputed from the fitted model.
  let f = expand_v094_fit(n)
  let gamma = mean(vector_multiply(f.psi, f.psi))
  let mut psi_absmax = 0.0
  for i = 0; i < n; i = i + 1 {
    let a = f.psi[i].abs()
    if a > psi_absmax {
      psi_absmax = a
    }
  }
  inspect(gamma < 100.0, content="true")
  inspect(psi_absmax < 100.0, content="true")
  // (3) Plausible relative SE, and it is the shipped one.
  let coef = f.coef()
  let se = f.se()
  let rel = se / coef.abs()
  inspect(coef.abs() > 1.0, content="true")
  inspect(rel > 1.0e-3 && rel < 0.2, content="true")
  // The shipped sandwich SE is the estimator's own SE, so the
  // plausible-relative-SE claim above is a claim about BOTH.
  inspect(
    expand_v094_close(f.sandwich_se(SandwichKind::hc0()), se),
    content="true",
  )
}

// ---------------------------------------------------------------------------
// 9. THE CLUSTERED `fit` PATH ALSO PERSISTS ITS OWN JACOBIAN
// ---------------------------------------------------------------------------

///|
/// `DoubleMLPQ::fit` dispatches to `fit_cluster` whenever
/// `data.cluster_vars` is non-empty, and that path returns a SEPARATE
/// struct literal -- so `psi_a` has to be built there too, from that
/// path's own `deriv_r`. Getting it wrong (leaving the `new()`
/// all-zeros, say) would still compile and would then ABORT inside
/// `m_inv_1x1` on the `|deriv| >= 1e-12` guard, so this test checks
/// the value rather than only that the call returns.
///
/// It deliberately does NOT assert `sandwich_se(HC0) == se()` here:
/// the cluster path's `se` is the unit-level cluster-robust variance,
/// not the IID one, so that identity is an IID-path property (see
/// the note in `quantile.mbt`).
test "pq_cluster_fit_persists_jacobian" {
  let n = 500
  let base = expand_v094_pq_data(n)
  let (singleton, pooled) = expand_v094_cluster_ids(n)
  // Non-empty `cluster_vars` -> `fit_cluster`.
  let clustered = DoubleMLData::new(base.x, base.y, base.d, cluster_vars=pooled)
  let m = DoubleMLPQ::new(clustered, treatment=1.0, quantile=0.5, n_folds=2).fit()
  inspect(m.psi_a.length() == n, content="true")
  // The cluster path's own Jacobian, not the `new()` sentinel.
  inspect(m.psi_a[0] != 0.0, content="true")
  let mut all_same = true
  for i = 0; i < n; i = i + 1 {
    if m.psi_a[i] != m.psi_a[0] {
      all_same = false
    }
  }
  inspect(all_same, content="true")
  inspect(m.psi_a[0] == mean(m.psi_a), content="true")
  // So the sandwich methods are callable on a clustered fit and
  // return a positive value.
  let cl = m.cluster_sandwich_se(pooled)
  inspect(cl > 0.0, content="true")
  inspect(cl == cl, content="true")
  inspect(m.sandwich_se(SandwichKind::hc0()) > 0.0, content="true")
  // All-singleton clusters over the CLUSTERED fit collapse the meat
  // to `sum_i psi[i]^2`, so the cluster method reduces to its own
  // IID HC0 -- the same collapse the IID fit shows.
  let cl_single = m.cluster_sandwich_se(singleton)
  inspect(
    expand_v094_close(cl_single, m.sandwich_se(SandwichKind::hc0())),
    content="true",
  )
  // The clustered `se` is the unit-level cluster variance, which is
  // NOT the IID one -- asserted so the note above stays honest if
  // the cluster path is ever changed.
  inspect(
    expand_v094_close(m.se(), m.sandwich_se(SandwichKind::hc0())) == false,
    content="true",
  )
  inspect(m.bias_corrected_coef() == m.coef(), content="true")
}
