///|
// v0.93.0: `DoubleMLLPQ` gets the sandwich API.
//
// WHY LPQ WAS SKIPPED TWICE
// =========================
// `DoubleMLLPQ` was left out of the sandwich rollout in v0.86.0 and
// again in v0.90.0 for the reason recorded in CHANGELOG.md: its
// Jacobian was a `fit()` local named `deriv` and was never persisted,
// and its stored `psi` is the centered IPW score with no
// `psi_a + coef * psi_b` split to reconstruct from.
//
// v0.93.0 persists that Jacobian as `self.psi_a` and adds the three
// standard methods. The payoff invariant, as it is for the other
// twelve estimators, is
//
//     sandwich_se(HC0) == se()
//
// and here it is EASY to get wrong, because of a false comment that
// sat next to the derivative code from v0.7.0 until this release. It
// read (in part):
//
//     "because the IPW score's `psi_a` is the constant `-1`, so
//      the derivative contribution from `psi_a` is zero and only
//      the `psi_b` part contributes"
//
// That is false. LPQ's estimating equation is a quantile
// FIRST-ORDER CONDITION, `mean(psi_ipw(theta)) = 0`, not the
// package-wide `f(theta) = E[theta * psi_a + psi_b]`. Its Jacobian
// is the data-dependent KDE quantity `f_theta / n`, which is what
// `fit` has always fed to `var_est_with_jacobian` -- that is WHY
// LPQ needs that helper at all. Taking the comment literally and
// building the sandwich with `psi_a = -1` / `M_inv = [[-1]]` yields
// an SE off by a factor `1 / deriv`. On the DGP below
// `deriv = 0.17063929187704086`, so the constant-`-1` reading
// SHRINKS the SE by 5.86x (0.29348 -> 0.05008). The v0.86.0 LPLR
// skip was the same class of mistake, worth ~60x there. Test 3
// below pins the correct reading.
//
// `se()` is the reference throughout: it is `var_est_with_jacobian`
// over the same `(self.psi, deriv)` pair, i.e.
// `sqrt((sum_i psi[i]^2 / n) / (deriv^2 * n))`, which is
// algebraically `M_inv[0,0]^2 * sum_i psi[i]^2 / n / n` -- the
// v0.91.0 accumulator at the same point.

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

///|
/// Relative closeness at the 1e-12 level (the package's tolerance
/// for "same number, different accumulation order" -- the same
/// helper `expand_v091_test.mbt` and `expand_v092_test.mbt` use).
fn expand_v093_close(x : Double, y : Double) -> Bool {
  let scale = if x.abs() > y.abs() { x.abs() } else { y.abs() }
  if scale == 0.0 {
    return (x - y).abs() < 1.0e-300
  }
  (x - y).abs() / scale < 1.0e-12
}

///|
/// The v0.93.0 LPQ DGP: `n = 500`, one bounded covariate
/// `x in [-1, 1]`, `z = 1{u < expit(0.3 x)}` (all compliers,
/// `d = z`), and a continuous outcome
/// `y = 2 d + 6 u'` with `u' ~ Uniform(0, 1)`.
///
/// Two properties of this DGP matter for the tests:
///
///   - The instrument depends LINEARLY on the single covariate the
///     propensity learner actually sees, so the cross-fitted `m`
///     lands in `[0.050, 0.755]` -- well inside the
///     `[1e-6, 1 - 1e-6]` clip. A DGP whose linear predictor is not
///     recoverable (e.g. `z` driven by `sin(x)` while the learner
///     sees raw `x`) sends some OLS predictions out of `[0, 1]`,
///     the clip pins them at `1e-6`, the `1 / (1 - m)` score terms
///     blow up to `1e6`, and `gamma = mean(psi^2)` reaches `~1e9`.
///     The sandwich identities still hold there, but every SE is
///     then a meaningless magnitude, so the fixture avoids it.
///   - The outcome support is wide (`6` units), which is what makes
///     the treated-arm density at the median -- and hence `deriv` --
///     decisively far from `1` in magnitude. That is what makes
///     test 3 bite.
fn expand_v093_lpq_data(n : Int) -> DoubleMLLPQData {
  let x_flat : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let z : Array[Double] = Array::make(n, 0.0)
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
    let pz = expit(0.3 * x_flat[i])
    let uz = rng.double()
    z[i] = if uz < pz { 1.0 } else { 0.0 }
    d[i] = z[i]
  }
  for i = 0; i < n; i = i + 1 {
    let u = rng.double()
    y[i] = d[i] * 2.0 + 6.0 * u
  }
  DoubleMLLPQData::new(Matrix::from_array(x_flat, n, 1), y, d, z)
}

///|
/// The fitted LPQ every test in this file shares. `n_rep` is
/// implicitly 1 for LPQ (a single-pass bisection), so `coef` is the
/// bisection root itself.
fn expand_v093_fit(n : Int) -> DoubleMLLPQ {
  DoubleMLLPQ::new(
    expand_v093_lpq_data(n),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
  ).fit()
}

///|
/// All-singleton (`singleton[i] = i`) and pooled-in-blocks-of-4
/// (`pooled[i] = i / 4`) cluster ids for a sample of `n`.
fn expand_v093_cluster_ids(n : Int) -> (Array[Int], Array[Int]) {
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
/// THE assertion that unblocks LPQ. With `self.psi` used AS the
/// score (it is already evaluated at `coef`; LPQ has no `psi_b` to
/// reconstruct it from, so `psi_at` is deliberately NOT called) and
/// the persisted data-dependent Jacobian
/// `M_inv = [[1 / self.psi_a[0]]]`, LPQ's HC0 equals its own
/// `se()`.
///
/// The mechanism: `se()` is `var_est_with_jacobian(self.psi, deriv)`
/// and `sandwich_variance_hc0` is
/// `M_inv[0,0]^2 * sum_i psi[i]^2 / n / n`. With
/// `M_inv[0,0] = 1 / deriv` the two are the same expression
/// accumulated with the same Kahan sum in the same order.
///
/// Fails to COMPILE against v0.92.2 (the methods do not exist),
/// which is the point: the invariant cannot even be expressed
/// without first getting the Jacobian role right.
test "lpq_se_equals_sandwich_hc0" {
  let n = 500
  let n_d = n.to_double()
  let m = expand_v093_fit(n)
  inspect(m.psi.length() == n, content="true")
  inspect(m.psi_a.length() == n, content="true")
  let se_hc0 = m.sandwich_se(SandwichKind::hc0())
  let se = m.se()
  // The invariant.
  inspect(expand_v093_close(se_hc0, se), content="true")
  // Equal to a much tighter tolerance than 1e-12: both sides
  // accumulate the same `psi[i]^2` with the same Kahan compensated
  // sum in the same index order, and differ only in where the
  // `1 / deriv^2` sits (`M_inv[0,0]^2 * acc / n / n` vs
  // `(acc / n) / (deriv * deriv * n)`). On this DGP that is
  // bit-identical on `native`; the 1e-14 bound is the portable
  // contract (the two spellings can round one ulp apart on `js`).
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
  // ... and it is NOT the *other* reading of the same persisted
  // state. The package-order reconstruction
  // `psi_at(coef, self.psi_a, self.psi)` -- the score the other
  // twelve estimators evaluate -- is a DIFFERENT function whose root
  // is not `coef`, so it must NOT reproduce `se()`.
  let psi_wrong = psi_at(m.coef(), m.psi_a, m.psi)
  let mut ss_wrong = 0.0
  for i = 0; i < n; i = i + 1 {
    ss_wrong = ss_wrong + psi_wrong[i] * psi_wrong[i]
  }
  let jac = m.psi_a[0]
  let se_wrong = (ss_wrong / n_d / (jac * jac * n_d)).sqrt()
  inspect(expand_v093_close(se_wrong, se) == false, content="true")
}

// ---------------------------------------------------------------------------
// 2. THE MEMOIZE CACHE-HIT TEST
// ---------------------------------------------------------------------------

///|
/// `psi_a` must survive a memoize cache hit, and the test that
/// proves it is this one.
///
/// `FitCache` stores only the nuisance predictions (`[g0, g1, m]`
/// for `"lpq"`), not the score or the Jacobian -- so `fit()`
/// RECOMPUTES `psi` and `deriv` on every call from the
/// (possibly cache-restored) nuisances. That is why `psi_a` is
/// built after the `cache_hit` branch in `fit` rather than being
/// read out of the cache: there is no separate restore path that
/// could silently omit it.
///
/// A regression that returned a `psi_a` of all zeros on the hit
/// path would make `sandwich_se` abort on the `|deriv| >= 1e-12`
/// guard; one that returned the un-cached constant would move the
/// SE. Both are caught here.
test "lpq_sandwich_after_memoize_cache_hit" {
  let n = 500
  let base = DoubleMLLPQ::new(
    expand_v093_lpq_data(n),
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
  // that fails if `psi_a` is left out of the cache.
  let se_hc0 = f2.sandwich_se(SandwichKind::hc0())
  inspect(expand_v093_close(se_hc0, f2.se()), content="true")
  inspect((se_hc0 - f2.se()).abs() / f2.se().abs() < 1.0e-14, content="true")
  // ... and the cache hit did not move the number: a cache hit must
  // be a no-op for the sandwich, which is the whole contract of the
  // memoize layer.
  let fresh = expand_v093_fit(n)
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
  // The cluster path agrees on the hit path too.
  let (singleton, _pooled) = expand_v093_cluster_ids(n)
  inspect(
    expand_v093_close(f2.cluster_sandwich_se(singleton), f2.se()),
    content="true",
  )
}

// ---------------------------------------------------------------------------
// 3. THE TRAP: the Jacobian is NOT the constant -1
// ---------------------------------------------------------------------------

///|
/// This test guards the trap that skipped LPQ in v0.86.0 and
/// v0.90.0. The removed v0.7.0 - v0.92.x comment claimed the IPW
/// score's `psi_a` is "the constant -1" and that only the `psi_b`
/// part contributes to the derivative. Following that claim when
/// building the sandwich gives `M_inv = [[1 / (-1)]] = [[-1]]`, a
/// Jacobian of `-1` instead of the data-dependent
/// `deriv = f_theta / n`.
///
/// On the DGP below `deriv = 0.17063929187704086`, so the constant
/// `-1` reading is off by `1 / 0.1706 = 5.86x` in the SE
/// (`0.29348` -> `0.05008`). Because the variance depends on the
/// Jacobian only through its SQUARE, a constant `-1` is exactly as
/// wrong as a constant `+1`; both are pinned below.
///
/// No finiteness-only assertion: every check compares two
/// independently computed numbers.
test "lpq_jacobian_is_not_minus_one" {
  let n = 500
  let n_d = n.to_double()
  let m = expand_v093_fit(n)
  let deriv = m.psi_a[0]
  let se = m.se()
  let shipped = m.sandwich_se(SandwichKind::hc0())
  // (1) The persisted Jacobian is not the constant -1 (nor +1,
  // which the SQUARE makes equally wrong), and is nowhere near
  // either: it is ~0.17, a factor of 5.86 away from unity.
  inspect(deriv != -1.0, content="true")
  inspect(deriv != 1.0, content="true")
  inspect(deriv.abs() > 0.1 && deriv.abs() < 0.3, content="true")
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
  inspect(expand_v093_close(shipped, jac_deriv), content="true")
  inspect(expand_v093_close(shipped, jac_minus_one) == false, content="true")
  inspect(expand_v093_close(shipped, jac_plus_one) == false, content="true")
  // (3) The measured size of the mistake on this DGP. Both wrong
  // constants give the same (wrong) SE, and it is the true SE
  // SHRUNK by exactly `|deriv|` -- i.e. `|deriv|` is what a
  // constant-`-1` Jacobian costs, a 5.86x under-statement here.
  inspect(jac_minus_one == jac_plus_one, content="true")
  let shrink = jac_minus_one / jac_deriv
  inspect(expand_v093_close(shrink, deriv.abs()), content="true")
  inspect(expand_v093_close(shrink, 0.17063929187704086), content="true")
  let inflation = jac_deriv / jac_minus_one
  inspect(expand_v093_close(inflation, 1.0 / deriv.abs()), content="true")
  inspect(inflation > 5.0 && inflation < 7.0, content="true")
  // (4) The payoff: the shipped value is `se()`, and `se()` is
  // nowhere near the constant-`-1` value.
  inspect(expand_v093_close(shipped, se), content="true")
  inspect(expand_v093_close(se, jac_minus_one) == false, content="true")
  // (5) The Jacobian is genuinely data-dependent, i.e. it is not a
  // constant this estimator happens to return. Refitting the SAME
  // estimator on a rescaled outcome (the DGP's `6.0` width doubled)
  // changes `deriv`, which a hard-coded constant could not do. This
  // is what "the IPW score's psi_a is the constant -1" gets wrong.
  let scaled = DoubleMLLPQ::new(
    expand_v093_lpq_data_scaled(n, 12.0),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
  ).fit()
  inspect(scaled.psi_a[0] != deriv, content="true")
  // It tracks the outcome DENSITY: doubling the outcome width halves
  // the treated-arm density at the median, and the Jacobian with it
  // (`1.9925` against an ideal `2`; not exactly `2` because the
  // Silverman bandwidth also scales with the spread). A
  // hard-coded constant `-1` (or any other constant) cannot move
  // with the data at all.
  let width_ratio = deriv / scaled.psi_a[0]
  inspect(width_ratio > 1.95 && width_ratio < 2.05, content="true")
  // Each fit carries its OWN Jacobian: the second model does not
  // inherit the first's.
  inspect(
    expand_v093_close(scaled.sandwich_se(SandwichKind::hc0()), scaled.se()),
    content="true",
  )
}

///|
/// The v0.93.0 DGP with a caller-chosen outcome width, so
/// `lpq_jacobian_is_not_minus_one` can refit on a rescaled outcome
/// and show the Jacobian is data-dependent.
fn expand_v093_lpq_data_scaled(n : Int, width : Double) -> DoubleMLLPQData {
  let x_flat : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let z : Array[Double] = Array::make(n, 0.0)
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
    let pz = expit(0.3 * x_flat[i])
    let uz = rng.double()
    z[i] = if uz < pz { 1.0 } else { 0.0 }
    d[i] = z[i]
  }
  for i = 0; i < n; i = i + 1 {
    let u = rng.double()
    y[i] = d[i] * 2.0 + width * u
  }
  DoubleMLLPQData::new(Matrix::from_array(x_flat, n, 1), y, d, z)
}

// ---------------------------------------------------------------------------
// 4. THE HC RELATIONSHIPS (pure ratios of the accumulator)
// ---------------------------------------------------------------------------

///|
/// `HC1 / HC0 == sqrt(n / (n - k))` with `k = 1`, i.e.
/// `sqrt(n / (n - 1))`, to 1e-12. Scale-invariant, so it says
/// nothing about the Jacobian -- that is test 1's job.
test "lpq_hc1_hc0_ratio" {
  let n = 500
  let n_d = n.to_double()
  let m = expand_v093_fit(n)
  let se0 = m.sandwich_se(SandwichKind::hc0())
  let se1 = m.sandwich_se(SandwichKind::hc1())
  inspect(
    expand_v093_close(se1 / se0, (n_d / (n_d - 1.0)).sqrt()),
    content="true",
  )
  inspect(se1 > se0, content="true")
}

///|
/// With the v0.88.0 leverage `h_ii = 1 / n_obs` every HC2 term is
/// divided by `(n - 1) / n`, algebraically the HC1 factor, so
/// `HC2 == HC1` to 1e-12.
test "lpq_hc2_equals_hc1" {
  let n = 500
  let m = expand_v093_fit(n)
  let se1 = m.sandwich_se(SandwichKind::hc1())
  let se2 = m.sandwich_se(SandwichKind::hc2())
  inspect(expand_v093_close(se2, se1), content="true")
  // The v0.79.0 - v0.87.0 signed "leverage"
  // `h_ii = psi_a[i] * M_inv[0,0] * psi_a[i]` goes NEGATIVE for
  // `mean(psi_a) < 0` and made HC2 SHRINK. LPQ's `psi_a` is a
  // positive constant here, so that old path would have produced
  // `1 - h_ii < 1` and a value below HC1; the equality above is
  // what rules it out.
  inspect(se2 >= se1, content="true")
}

///|
/// HC3 divides every term by `((n - 1) / n)^2`, so
/// `HC3 == HC1^2 / HC0` to 1e-12.
test "lpq_hc3_equals_hc1_squared_over_hc0" {
  let n = 500
  let n_d = n.to_double()
  let m = expand_v093_fit(n)
  let se0 = m.sandwich_se(SandwichKind::hc0())
  let se1 = m.sandwich_se(SandwichKind::hc1())
  let se3 = m.sandwich_se(SandwichKind::hc3())
  inspect(expand_v093_close(se3, se1 * se1 / se0), content="true")
  inspect(
    expand_v093_close(
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
/// `HC3 > HC1 == HC2 > HC0`, holds for LPQ too. `HC2` is EQUAL to
/// `HC1`, not strictly above it: any test written as `HC2 > HC1` is
/// asserting a falsehood.
test "lpq_ordering" {
  let n = 500
  let m = expand_v093_fit(n)
  let se0 = m.sandwich_se(SandwichKind::hc0())
  let se1 = m.sandwich_se(SandwichKind::hc1())
  let se2 = m.sandwich_se(SandwichKind::hc2())
  let se3 = m.sandwich_se(SandwichKind::hc3())
  inspect(se1 > se0, content="true")
  inspect(expand_v093_close(se2, se1), content="true")
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
test "lpq_singleton_cluster_equals_se" {
  let n = 500
  let (singleton, pooled) = expand_v093_cluster_ids(n)
  let m = expand_v093_fit(n)
  let se = m.se()
  let cl_single = m.cluster_sandwich_se(singleton)
  let cl_pooled = m.cluster_sandwich_se(pooled)
  inspect(expand_v093_close(cl_single, se), content="true")
  inspect(
    expand_v093_close(cl_single, m.sandwich_se(SandwichKind::hc0())),
    content="true",
  )
  inspect(expand_v093_close(cl_pooled, se) == false, content="true")
  inspect(cl_pooled > 0.0, content="true")
  // Pooling in blocks of 4 widens the SE here (the within-block
  // score sums carry positive cross terms), by ~22%.
  let pooled_ratio = cl_pooled / se
  inspect(pooled_ratio > 1.0 && pooled_ratio < 1.5, content="true")
  // The cluster path uses the persisted Jacobian, not the constant
  // -1, so the pooled value is not reproducible from an `M_inv` of
  // `[[-1]]` either.
  let cl_wrong = cluster_sandwich_variance(
    m.psi_a,
    m.psi,
    Matrix::from_array([-1.0], 1, 1),
    pooled,
    1,
  ).sqrt()
  inspect(expand_v093_close(cl_pooled, cl_wrong) == false, content="true")
}

// ---------------------------------------------------------------------------
// 7. bias_corrected_coef
// ---------------------------------------------------------------------------

///|
/// `bias_corrected_coef` returns `coef` EXACTLY -- the v0.91.0
/// design, identical to the twelve methods already shipped. The LPQ
/// estimating function `mean(psi_ipw(theta)) = 0` is orthogonal at
/// its root, so a correction built from the fitted scores is
/// vacuous by construction.
///
/// The `psi_a` of the moment for LPQ is the whole reason this is a
/// no-op: `mean(self.psi)` is the estimating function itself, and it
/// is `-0.007` here, not `0` -- `theta` is the IPW-bisection root,
/// while `self.psi` is the `g0`/`g1`-crossfit score at that `theta`.
/// So the naive "add the mean score" correction is NOT a no-op on
/// this estimator (it moves `coef` by `-0.007`), which is precisely
/// why returning the uncorrected estimate is the honest answer and
/// not merely the convenient one.
test "lpq_bias_corrected_coef_is_identity" {
  let n = 500
  let m = expand_v093_fit(n)
  inspect(m.bias_corrected_coef() == m.coef(), content="true")
  // The estimating function at the root is small but NOT zero, so
  // "add the mean score" is a real (and wrong) modification here,
  // and the shipped accessor deliberately does not make it.
  let mean_score = mean(m.psi)
  inspect(mean_score.abs() < 0.02, content="true")
  inspect(mean_score != 0.0, content="true")
  inspect(m.bias_corrected_coef() != m.coef() + mean_score, content="true")
  // ... and the honest no-op is not the point estimate times a
  // factor either (the pre-v0.91.0 `3 * coef` closed form).
  inspect(m.bias_corrected_coef() != 3.0 * m.coef(), content="true")
}
