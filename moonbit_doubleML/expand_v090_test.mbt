///|
// v0.90.0: the psi evaluation order in the sandwich + bootstrap
// paths.
//
// THE FINDING THIS RELEASE FIXES
// ==============================
// `var_est.mbt` defines the package's estimating function as
//
//     f(theta) = E[theta * psi_a + psi_b]
//     theta_hat = -mean(psi_b) / mean(psi_a)
//     J      = d f / d theta = mean(psi_a)
//     gamma  = mean(psi(theta_hat)^2),  psi(theta) = theta*psi_a + psi_b
//     sigma2 = gamma / (J^2 * n)
//
// and `M_inv = [[1 / mean(psi_a)]] = 1 / J` is exactly `d f / d
// theta`, so every `M_inv` the sandwich methods build was already
// consistent with that convention.
//
// Through v0.89.0 the sandwich family and the multiplier bootstrap
// evaluated a DIFFERENT function,
//
//     g(theta) = E[psi_a + theta * psi_b]
//
// whose root is `-E[psi_a] / E[psi_b]`, not `theta_hat`. At the
// solution `mean(coef*psi_a + psi_b) = 0` by construction, but
// `mean(psi_a + coef*psi_b)` is not zero in general, so the
// bootstrap was resampling a score with a large spurious mean and
// the sandwich was integrating the wrong quadratic form.
//
// v0.90.0 routes every one of those sites through the single new
// `psi_at(coef, psi_a, psi_b)` helper in `sandwich.mbt`, which
// evaluates `var_est`'s function. `se()` is unchanged and remains
// the reference.
//
// THE DECISIVE FALSIFIABLE INVARIANT
// ==================================
// v0.91.0 INVERTED THE IDENTITY BELOW. Through v0.90.0 this
// test pinned
//
//   se() == sandwich_se(HC0) / sqrt(n)
//
// which was the best that could be true while the accumulator
// still had two errors (see `sandwich.mbt`): the spurious
// `psi_a[i]` weight and a missing outer `1 / n`. With both
// corrected the invariant is stronger and needs no factor at
// all -- `se() == sandwich_se(HC0)` for EVERY estimator -- and
// `expand_v091_test.mbt` is where that is pinned now. This file
// keeps the bootstrap, `psi_at` and HC-relationship coverage;
// the se-vs-sandwich comparison survives below in its corrected
// form so a regression cannot hide here either.
//
// The `3 * coef` bias pin is also gone: `bias_corrected_coef`
// is a documented no-op as of v0.91.0 and returns `coef`.

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

///|
/// Relative closeness at the 1e-12 level (the tolerance this
/// package uses for "same number, different accumulation order").
fn expand_v090_close(x : Double, y : Double) -> Bool {
  let scale = if x.abs() > y.abs() { x.abs() } else { y.abs() }
  if scale == 0.0 {
    return (x - y).abs() < 1.0e-300
  }
  (x - y).abs() / scale < 1.0e-12
}

///|
/// Absolute closeness at the 1e-12 level. Used where the expected
/// value is (or should be) exactly zero and a RELATIVE comparison
/// is undefined -- e.g. `mean(psi(theta_hat))`, which is zero by
/// construction but only to accumulated floating-point round-off.
fn expand_v090_near_zero(x : Double) -> Bool {
  x.abs() < 1.0e-12
}

///|
/// `DoubleMLData` DGP shared by the IRM / PLR tests below:
/// `d = 1{x_0 + 0.3 u > 0}` (monotone in `x_0`, so a linear
/// propensity learner stays inside `(0, 1)` away from the clip),
/// `y = 1.0 + 0.4 x_0 + 0.1 * sum_{j>0} x_j + 2.0 d + noise`.
/// True ATE = 2.0.
fn expand_v090_data(n : Int, p : Int) -> DoubleMLData {
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  for i = 0; i < n * p; i = i + 1 {
    x_flat[i] = chacha8_rng(11 + i).double()
  }
  let rng = chacha8_rng(7)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u = rng.double() * 2.0 - 1.0
    let x0 = x_flat[i * p]
    d[i] = if x0 + 0.3 * u > 0.0 { 1.0 } else { 0.0 }
    let mut lin = 1.0 + 0.4 * x0
    for j = 1; j < p; j = j + 1 {
      lin = lin + 0.1 * x_flat[i * p + j]
    }
    y[i] = lin + 2.0 * d[i] + 0.4 * (rng.double() - 0.5)
  }
  DoubleMLData::new(Matrix::from_array(x_flat, n, p), y, d)
}

// ---------------------------------------------------------------------------
// 1. THE DECISIVE ONE
// ---------------------------------------------------------------------------

///|
/// `se()` and `sandwich_se(HC0)` must be the SAME estimator of
/// the same variance, with no residual factor.
///
/// v0.91.0: this used to read
/// `se() == sandwich_se(HC0) / sqrt(n)`. The `sqrt(n)` was
/// real -- the shipped accumulator was missing the outer
/// `1 / n` of mean-root asymptotics -- so the corrected
/// comparison needs no factor at all. Against v0.90.0 this
/// test fails by exactly `sqrt(n) = 20` on the DGP below;
/// against v0.89.0 it fails by ~225x (IRM) / ~1096x (APO).
test "se_matches_sandwich_hc0_for_constant_psi_a" {
  let n = 400
  let data = expand_v090_data(n, 3)
  let irm = DoubleMLIRM::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  // Precondition for the identity: `psi_a` really is the constant
  // -1 on every row, so `mean(psi_a) == -1` and `M_inv == -1`.
  inspect(irm.psi_a.length() == n, content="true")
  inspect(expand_v090_close(mean(irm.psi_a), -1.0), content="true")
  let n_d = n.to_double()
  let se_hc0 = irm.sandwich_se(SandwichKind::hc0())
  inspect(expand_v090_close(se_hc0, irm.se()), content="true")
  // And explicitly NOT the v0.90.0 relation, so the test cannot
  // be satisfied by leaving the old `sqrt(n)` in place.
  inspect(
    expand_v090_close(se_hc0 / n_d.sqrt(), irm.se()) == false,
    content="true",
  )
  // APO: same `psi_a = -1` score, different `psi_b`.
  let apo = DoubleMLAPO::new(
    data,
    treatment_level=1.0,
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  inspect(expand_v090_close(mean(apo.psi_a), -1.0), content="true")
  inspect(
    expand_v090_close(apo.sandwich_se(SandwichKind::hc0()), apo.se()),
    content="true",
  )
  // A same-estimator sanity check that the two accessors are not
  // trivially equal to everything: the pre-v0.90 order still
  // gives a wildly different number, so this test is genuinely
  // discriminating rather than satisfied by any positive value.
  let mut ss_old = 0.0
  for i = 0; i < n; i = i + 1 {
    let p = irm.psi_a[i] + irm.coef() * irm.psi_b[i]
    ss_old = ss_old + p * p
  }
  let se_old = (ss_old / n_d).sqrt()
  inspect(se_old > 100.0 * irm.se(), content="true")
}

// ---------------------------------------------------------------------------
// 2. BOOTSTRAP ORDER, SEEDED AND EXACT
// ---------------------------------------------------------------------------

///|
/// The bootstrap's t-stat is
/// `sum_i w[b,i] * psi[i] / (sqrt(n) * sqrt(mean(psi^2)))`, i.e.
/// it is standardised by the psi's OWN root-mean-square, so its
/// DISTRIBUTION is `N(0, 1)` under either score order and a
/// "t-stat SD is close to 1" assertion cannot detect the bug (it
/// does not here: the v0.89.0 t-stat SD on the DGP below is
/// `1.0561`, indistinguishable from 1).
///
/// What IS order-sensitive, and what this test pins, is the
/// realisation-by-realisation value: for the same weight draw the
/// normalised inner product `sum_i w_i psi_i / sqrt(sum psi_i^2)`
/// depends on the psi vector. `draw_bootstrap_weights` is seeded,
/// so the comparison is EXACT (bit-for-bit), not a tolerance.
///
/// The test therefore recomputes the t-stats from the same seed
/// using the corrected score and requires bit-equality with the
/// estimator's `bootstrap(...)` output. Against v0.89.0 the first
/// t-stat is `-0.42061907999242576` (the old order) against
/// `0.9735330144697445` (the corrected order) -- a clear failure.
test "bootstrap_se_agrees_with_analytic_se" {
  let n = 400
  let irm = DoubleMLIRM::new(
    expand_v090_data(n, 3),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let n_rep = 16
  let seed = 99
  let fitted = irm.bootstrap(method_name="normal", n_rep_boot=n_rep, seed~)
  // Same weights, corrected score, recomputed independently.
  let n_d = n.to_double()
  let psi = psi_at(irm.coef(), irm.psi_a, irm.psi_b)
  let mut ss = 0.0
  for i = 0; i < n; i = i + 1 {
    ss = ss + psi[i] * psi[i]
  }
  let se_psi = (ss / n_d).sqrt()
  let weights = draw_bootstrap_weights("normal", n_rep, n, seed) catch {
    _ => abort("draw_bootstrap_weights failed on a known-good method name")
  }
  let expected = did_bootstrap_t_stat(weights, psi, [se_psi], n_rep, n, 1)
  inspect(expected.length() == n_rep, content="true")
  for b = 0; b < n_rep; b = b + 1 {
    inspect(fitted.boot_t_stat[b] == expected[b], content="true")
  }
  // The old order would give different realisations from the same
  // weights, so the loop above is not vacuous.
  let psi_old : Array[Double] = Array::make(n, 0.0)
  let mut ss_old = 0.0
  for i = 0; i < n; i = i + 1 {
    let v = irm.psi_a[i] + irm.coef() * irm.psi_b[i]
    psi_old[i] = v
    ss_old = ss_old + v * v
  }
  let se_psi_old = (ss_old / n_d).sqrt()
  let old = did_bootstrap_t_stat(weights, psi_old, [se_psi_old], n_rep, n, 1)
  let mut differs = false
  for b = 0; b < n_rep; b = b + 1 {
    if old[b] != fitted.boot_t_stat[b] {
      differs = true
    }
  }
  inspect(differs, content="true")
  // Distribution-level claim, with the tolerance justified: the
  // multiplier bootstrap t-stat is `N(0, 1)` by construction, so
  // with `n_rep = 2000` draws the sampling SD of the empirical SD
  // is about `1 / sqrt(2 * 2000) ~ 1.6%`. 10% is a wide but
  // safe band that still fails if the psi were left at a constant
  // (which would collapse the t-stats to exactly 0).
  let big = irm.bootstrap(method_name="normal", n_rep_boot=2000, seed=7)
  let t = big.boot_t_stat
  let mut acc = 0.0
  for b = 0; b < t.length(); b = b + 1 {
    acc = acc + t[b] * t[b]
  }
  let sd = (acc / t.length().to_double()).sqrt()
  inspect(sd > 0.9 && sd < 1.1, content="true")
}

// ---------------------------------------------------------------------------
// 3. THE HELPER REPRODUCES var_est
// ---------------------------------------------------------------------------

///|
/// `psi_at` must reproduce `var_est`'s per-observation score
/// EXACTLY -- not approximately -- because `var_est` is the
/// reference implementation and the whole point of routing the
/// 13 call sites through the helper is that they cannot drift
/// from it. `var_est` does not expose its per-observation psi, so
/// this pins the two against a third, independent recomputation
/// of `var_est`'s documented formula on synthetic inputs whose
/// root is known in closed form.
test "psi_at_helper_matches_var_est" {
  // psi_a = 1, psi_b = -0.5 + small i-dependent term, so
  // theta_hat = 0.5 and gamma is a closed form.
  let n = 64
  // A zero-sum perturbation, so `mean(psi_b)` is exactly `-0.5`
  // in floating point (each cancelling pair returns the running sum
  // to `-0.5`, and `-0.5` is a power of two, so the 64-term
  // accumulation is exact). `coef` is therefore exactly `0.5`.
  let pert : Array[Double] = [0.0, 0.02, -0.02, 0.05, -0.05, 0.01, -0.01, 0.0]
  let psi_a : Array[Double] = Array::make(n, 1.0)
  let psi_b : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    psi_b[i] = -0.5 + pert[i % 8]
  }
  let (coef, se) = var_est(psi_a, psi_b)
  // The root of `f(theta) = mean(theta * psi_a + psi_b)`.
  let n_d = n.to_double()
  let expected_coef = -mean(psi_b) / mean(psi_a)
  inspect(mean(psi_b) == -0.5, content="true")
  inspect(coef == expected_coef, content="true")
  inspect(coef == 0.5, content="true")
  // Independent recomputation of `var_est`'s sigma2.
  let psi = psi_at(coef, psi_a, psi_b)
  let mut ss = 0.0
  for i = 0; i < n; i = i + 1 {
    ss = ss + psi[i] * psi[i]
  }
  let j = mean(psi_a)
  let sigma2 = ss / n_d / (j * j * n_d)
  inspect(expand_v090_close(se, sigma2.sqrt()), content="true")
  // `psi_at` is exactly `coef * psi_a[i] + psi_b[i]`, elementwise.
  for i = 0; i < n; i = i + 1 {
    inspect(psi[i] == coef * psi_a[i] + psi_b[i], content="true")
  }
  // At the root the score is mean-zero (the whole point of the
  // corrected order: the wrong order is not). Zero only up to the
  // floating-point round-off of a 400-term accumulation, so this
  // is an ABSOLUTE check.
  inspect(expand_v090_near_zero(mean(psi)), content="true")
  let psi_old : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    psi_old[i] = psi_a[i] + coef * psi_b[i]
  }
  inspect(mean(psi_old).abs() > 0.5, content="true")
}

// ---------------------------------------------------------------------------
// 4. bias_per_obs
// ---------------------------------------------------------------------------

///|
/// `bias_corrected_coef` used to build
/// `bias_per_obs[i] = psi_b[i] - coef * psi_a[i]` and return
/// `coef + mean(bias_per_obs)`. That expression is NOT
/// `var_est`'s score at the estimate (which is
/// `psi_b[i] + coef * psi_a[i]`); it is the score at `-coef`, i.e.
/// the negated-argument form `f(theta) = E[psi_b - theta * psi_a]`
/// whose root is `+mean_b / mean_a`, not `var_est`'s
/// `-mean_b / mean_a`. The two conventions are not interchangable
/// and mixing them is why `bias_corrected_coef` on IRM / APO
/// returned `3 * coef` (the algebra collapses: with `psi_a = -1`,
/// `mean(psi_b - coef*psi_a) = coef + coef = 2*coef`).
///
/// v0.91.0: `bias_corrected_coef` is a documented NO-OP and
/// returns `coef` unchanged, because under `var_est`'s
/// convention the score at the estimate is identically
/// mean-zero -- any "correction" built from it is vacuous, and
/// the old accessor returned a number that was not a bias
/// estimate at all.
test "bias_corrected_coef_is_a_documented_noop" {
  let n = 400
  let irm = DoubleMLIRM::new(
    expand_v090_data(n, 3),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let bc = irm.bias_corrected_coef()
  // v0.91.0 form: `coef`, exactly.
  inspect(bc == irm.coef(), content="true")
  // The v0.90.0 form, recomputed here, is `3 * coef` on this
  // DGP: `coef + mean(psi_b - coef * psi_a)`. Pin the arithmetic
  // so the removal is documented rather than merely asserted.
  // (Deliberate REGRESSION PIN of the removed expression.)
  let bias : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    bias[i] = irm.psi_b[i] - irm.coef() * irm.psi_a[i]
  }
  let old = irm.coef() + mean(bias)
  inspect(expand_v090_close(irm.coef(), mean(irm.psi_b)), content="true")
  inspect(expand_v090_close(old, 3.0 * irm.coef()), content="true")
  inspect(old != irm.coef(), content="true")
  // The convention-A score at the estimate, for the record: its
  // mean is zero, so a `coef + mean(that)` "correction" is
  // identically `coef`. This is the derivation that says the
  // feature needs a no-op rather than a sign flip.
  let score_at_hat : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    score_at_hat[i] = irm.psi_b[i] + irm.coef() * irm.psi_a[i]
  }
  inspect(expand_v090_near_zero(mean(score_at_hat)), content="true")
  inspect(
    expand_v090_close(irm.coef() + mean(score_at_hat), irm.coef()),
    content="true",
  )
  // So the two forms are genuinely different, not two spellings.
  let mut differ = false
  for i = 0; i < n; i = i + 1 {
    if bias[i] != score_at_hat[i] {
      differ = true
    }
  }
  inspect(differ, content="true")
}

// ---------------------------------------------------------------------------
// 5. THE v0.88 HC2 / HC3 IDENTITIES, PER ESTIMATOR
// ---------------------------------------------------------------------------

///|
/// The v0.88.0 leverage identities, evaluated in a fixed order so
/// a caller can report WHICH one broke. Returns ten `Bool`s; the
/// caller `inspect`s each. `inspect` is only legal inside a `test`
/// block, hence the array return instead of in-place assertions.
///
///   0. HC1 == HC0 * n / (n - 1)              (finite-sample widening)
///   1. HC2 == HC0 * n / (n - 1)              (h_ii = 1/n, so HC2 == HC1)
///   2. HC3 == HC0 * (n / (n - 1))^2          (== HC1^2 / HC0)
///   3. HC2 == HC1 (1e-12 relative)
///   4. HC3 == HC1^2 / HC0 (1e-12 relative)
///   5. HC1 > HC0
///   6. HC2 > HC0
///   7. HC3 > HC2
///   8. all-singleton cluster_ids == IID HC0
///   9. pooled clusters differ from IID HC0
///
/// On 3 and 4: HC1 scales the HC0 accumulation by `n / (n - 1)`
/// while HC2 divides each term by `(n - 1) / n` and re-divides by
/// `n`. Those are algebraically identical but not bit-identical in
/// general -- they differ in the last ulp on IIVM, so the package's
/// 1e-12 relative tolerance applies, exactly as the v0.86-v0.89
/// sandwich tests already use. HC2 was also not bit-equal to HC1
/// before v0.90.0, so this is not a regression.
///
/// These are properties of the accumulator, not of the score
/// order, so v0.90.0 must not move them.
fn expand_v090_hc_identities(
  n : Int,
  se_hc0 : Double,
  se_hc1 : Double,
  se_hc2 : Double,
  se_hc3 : Double,
  se_singleton : Double,
  se_pooled : Double,
) -> Array[Bool] {
  let n_d = n.to_double()
  let scale = n_d / (n_d - 1.0)
  let se_scale = scale.sqrt()
  [
    expand_v090_close(se_hc1, se_hc0 * se_scale),
    expand_v090_close(se_hc2, se_hc0 * se_scale),
    expand_v090_close(se_hc3, se_hc0 * se_scale * se_scale),
    expand_v090_close(se_hc2, se_hc1),
    expand_v090_close(se_hc3, se_hc1 * se_hc1 / se_hc0),
    se_hc1 > se_hc0,
    se_hc2 > se_hc0,
    se_hc3 > se_hc2,
    // All-singleton clusters are algebraically the HC0
    // accumulation (the `n_c <= 1` jackknife clip makes the
    // per-cluster scale 1).
    expand_v090_close(se_singleton, se_hc0),
    // Pooled clusters pick up the cross terms, so they differ.
    expand_v090_close(se_pooled, se_hc0) == false,
  ]
}

///|
test "hc_identities_constant_psi_a_irm" {
  let n = 400
  let irm = DoubleMLIRM::new(
    expand_v090_data(n, 3),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let singleton : Array[Int] = Array::make(n, 0)
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
    pooled[i] = i / 4
  }
  let checks = expand_v090_hc_identities(
    n,
    irm.sandwich_se(SandwichKind::hc0()),
    irm.sandwich_se(SandwichKind::hc1()),
    irm.sandwich_se(SandwichKind::hc2()),
    irm.sandwich_se(SandwichKind::hc3()),
    irm.cluster_sandwich_se(singleton),
    irm.cluster_sandwich_se(pooled),
  )
  for k = 0; k < checks.length(); k = k + 1 {
    inspect(checks[k], content="true")
  }
}

///|
test "hc_identities_nonconstant_psi_a_plr" {
  let n = 400
  let plr = DoubleMLPLR::new(
    expand_v090_data(n, 3),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  // PLR's `psi_a[i] = -v_i^2` genuinely varies across rows, so this
  // exercises the non-degenerate case of the accumulator.
  let mut varies = false
  for i = 1; i < n; i = i + 1 {
    if plr.psi_a[i] != plr.psi_a[0] {
      varies = true
    }
  }
  inspect(varies, content="true")
  inspect(mean(plr.psi_a) < 0.0, content="true")
  let singleton : Array[Int] = Array::make(n, 0)
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
    pooled[i] = i / 4
  }
  let checks = expand_v090_hc_identities(
    n,
    plr.sandwich_se(SandwichKind::hc0()),
    plr.sandwich_se(SandwichKind::hc1()),
    plr.sandwich_se(SandwichKind::hc2()),
    plr.sandwich_se(SandwichKind::hc3()),
    plr.cluster_sandwich_se(singleton),
    plr.cluster_sandwich_se(pooled),
  )
  for k = 0; k < checks.length(); k = k + 1 {
    inspect(checks[k], content="true")
  }
}

///|

///|
/// Second non-constant-`psi_a` estimator. IIVM's DGP needs a valid
/// exclusion restriction (`z ~ Bernoulli(0.5)`,
/// `d = 1{alpha z + v > 0}` with `v` independent, `y = theta d + x@1
/// + eps`), so it is built here rather than reused from
/// `expand_v090_data`; a random instrument with a monotone
/// propensity diverges the fit and trips the clip precondition
/// before any sandwich is reached.
test "hc_identities_nonconstant_psi_a_iivm" {
  let n = 1000
  let p = 5
  let rng = chacha8_rng(1111)
  let pool : Array[Double] = []
  while pool.length() < n * p + 2 * n {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let theta = 2.0 * 3.141592653589793 * u2
    pool.push(r * @math.cos(theta))
    pool.push(r * @math.sin(theta))
  }
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  for i = 0; i < n * p; i = i + 1 {
    x_flat[i] = pool[i]
  }
  let mut idx = n * p
  let v : Array[Double] = Array::make(n, 0.0)
  let eps : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    v[i] = pool[idx]
    idx = idx + 1
  }
  for i = 0; i < n; i = i + 1 {
    eps[i] = pool[idx]
    idx = idx + 1
  }
  let x = Matrix::from_array(x_flat, n, p)
  let z : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u = rng.double()
    z[i] = if u > 0.5 { 1.0 } else { 0.0 }
    d[i] = if 0.5 * z[i] + v[i] > 0.0 { 1.0 } else { 0.0 }
    let mut s = eps[i]
    for j = 0; j < p; j = j + 1 {
      s = s + x.get(i, j)
    }
    y[i] = 1.0 * d[i] + s
  }
  let iivm = DoubleMLIIVM::new(
    DoubleMLIIVMData::new(x, y, d, z),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let mut varies = false
  for i = 1; i < n; i = i + 1 {
    if iivm.psi_a[i] != iivm.psi_a[0] {
      varies = true
    }
  }
  inspect(varies, content="true")
  let singleton : Array[Int] = Array::make(n, 0)
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
    pooled[i] = i / 10
  }
  let checks = expand_v090_hc_identities(
    n,
    iivm.sandwich_se(SandwichKind::hc0()),
    iivm.sandwich_se(SandwichKind::hc1()),
    iivm.sandwich_se(SandwichKind::hc2()),
    iivm.sandwich_se(SandwichKind::hc3()),
    iivm.cluster_sandwich_se(singleton),
    iivm.cluster_sandwich_se(pooled),
  )
  for k = 0; k < checks.length(); k = k + 1 {
    inspect(checks[k], content="true")
  }
}

// ---------------------------------------------------------------------------
// 6. LPLR: still not wired up, and here is why
// ---------------------------------------------------------------------------

///|
/// LPLR persists its IF components in the INVERTED (offset, slope)
/// order: `psi_a` is the offset at `theta_hat` and `psi_b` is the
/// slope `sc.psi_deriv`. v0.90.0's `psi_at` expects
/// `(coefficient, offset)`, so LPLR's bootstrap call passes
/// `(self.psi_b, self.psi_a)` -- the swap the v0.87.0 note
/// anticipated.
///
/// Two things are pinned here:
///
///   1. `se()` is `var_est` applied to `(slope, offset)`, and the
///      score it integrates, `psi_at(coef, slope, offset)`, is
///      EXACTLY `sc.psi` -- the raw score at the fitted theta. The
///      v0.75.0 - v0.89.0 bootstrap reached the same number by two
///      cancelling errors, so v0.90.0 must leave the bootstrap
///      output bit-identical. A seeded exact comparison against a
///      hand-rolled `did_bootstrap_t_stat` on the corrected psi is
///      the check.
///
///   2. The v0.87.0 blocker is GONE: `mean(slope)` is a genuine
///      Jacobian (strictly negative here), not the
///      catastrophic-cancellation residual `mean(offset)` that
///      inflated HC0 by ~60x. `mean(offset) = 0.01899446...` on
///      this DGP against a true Jacobian of `-0.03638724...`.
///
/// LPLR still has no `sandwich_se`, and v0.91.0 does not add
/// one -- but the reason has changed. With the corrected score
/// order, the true Jacobian and the v0.91.0 accumulator, its
/// HC0 now equals its `se()` to the last ulp (see (4) below).
/// Exposing the accessor is a separate API decision and is
/// tracked as its own report item.
test "lplr_inverted_roles_are_handled" {
  let n = 500
  let p = 6
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let rng = chacha8_rng(3141)
  let need = n * p + n
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
  for i = 0; i < n * p; i = i + 1 {
    x_flat[i] = pool[i]
  }
  for i = 0; i < n; i = i + 1 {
    let x1 = x_flat[i * p]
    let x2 = x_flat[i * p + 1]
    let a = 0.5 * @math.sin(x1) + 0.5 * @math.cos(x2) + 0.5 * pool[n * p + i]
    let p_t = expit(a)
    let u = rng.double()
    d[i] = if u < p_t { 1.0 } else { 0.0 }
  }
  for i = 0; i < n; i = i + 1 {
    let x1 = x_flat[i * p]
    let x2 = x_flat[i * p + 1]
    let x3 = x_flat[i * p + 2]
    let x4 = x_flat[i * p + 3]
    let x5 = x_flat[i * p + 4]
    let x6 = x_flat[i * p + 5]
    let r0 = x1 * x2 / 4.0 +
      0.25 * x3 * x3 +
      @math.cos(x4) / 4.0 -
      0.5 * @math.sin(x5) +
      (if x6 > 0.0 { 1.0 } else { 0.0 }) -
      0.5
    let a0 = @math.sin(x1) / 2.0 + @math.cos(x2) / 2.0
    let p_y = expit(0.5 * (d[i] - a0) + r0)
    let uy = rng.double()
    y[i] = if uy < p_y { 1.0 } else { 0.0 }
  }
  let data = DoubleMLBinaryData::new(Matrix::from_array(x_flat, n, p), y, d)
  let lplr = DoubleMLLPLR::new(data, n_folds=2, n_folds_inner=2).fit()
  let offset = lplr.psi_a
  let slope = lplr.psi_b
  let coef = lplr.coef()
  // (1) `se()` is `var_est` over `(slope, offset)`.
  let n_d = n.to_double()
  let psi = psi_at(coef, slope, offset)
  let mut ss = 0.0
  for i = 0; i < n; i = i + 1 {
    ss = ss + psi[i] * psi[i]
  }
  let j = mean(slope)
  let se_recomputed = (ss / n_d / (j * j * n_d)).sqrt()
  inspect(expand_v090_close(se_recomputed, lplr.se()), content="true")
  // (2) The old and new call sites both produce `sc.psi`, so the
  // bootstrap output is bit-identical across v0.89.0 / v0.90.0.
  let psi_old : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    psi_old[i] = offset[i] + coef * slope[i]
  }
  for i = 0; i < n; i = i + 1 {
    inspect(psi[i] == psi_old[i], content="true")
  }
  let n_rep = 16
  let seed = 99
  let fitted = lplr.bootstrap(method_name="normal", n_rep_boot=n_rep, seed~)
  let weights = draw_bootstrap_weights("normal", n_rep, n, seed) catch {
    _ => abort("draw_bootstrap_weights failed on a known-good method name")
  }
  let expected = did_bootstrap_t_stat(
    weights,
    psi,
    [(ss / n_d).sqrt()],
    n_rep,
    n,
    1,
  )
  for b = 0; b < n_rep; b = b + 1 {
    inspect(fitted.boot_t_stat[b] == expected[b], content="true")
  }
  // (3) The v0.87.0 blocker is resolved: the true Jacobian is
  // negative and materially different from the cancellation
  // residual that `mean(offset)` would have supplied.
  inspect(j < 0.0, content="true")
  inspect(mean(offset) > 0.0, content="true")
  inspect(mean(offset) / j < 0.0, content="true")
  // (4) THE REASON LPLR HAD NO `sandwich_se` IS GONE. Through
  // v0.90.0 the corrected order with the true Jacobian put HC0
  // at 0.879 * se() here -- a data-dependent factor from the
  // open accumulator defect, which is why wiring LPLR up was
  // refused. With the accumulator corrected (v0.91.0) HC0 ==
  // se() to the last ulp. The decision to expose
  // `DoubleMLLPLR::sandwich_se` is deliberately NOT taken here;
  // this test only records that the blocker is resolved.
  let m_inv = Matrix::from_array([1.0 / j], 1, 1)
  let h0 = sandwich_variance_hc0(slope, psi, m_inv, n, 1).sqrt()
  let ratio = h0 / se_recomputed
  inspect(ratio > 0.5 && ratio < 2.0, content="true")
  inspect(expand_v090_close(h0, se_recomputed), content="true")
}
