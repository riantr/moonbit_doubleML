///|
// v0.100.0: `DoubleMLAPOS` gets the per-level sandwich API.
//
// WHERE APOS SITS IN THE FAMILY
// =============================
// Seventeen estimators now carry `sandwich_se` /
// `cluster_sandwich_se` / `bias_corrected_coef`. APOS was the one
// glaring omission next to its own child: `DoubleMLAPO` has had the
// triple since v0.89.0 / v0.91.0, and the per-level numbers it
// reports are literally that child's `coef` and `se` -- the parent
// loop reads `z.coef()` and `z.se()` and discards the rest of the
// child, including the `psi_a` / `psi_b` the child had ALREADY
// computed and persisted for its own multiplier bootstrap. Nothing
// had to be re-derived here; the IF components were being thrown
// away one level up.
//
// PER LEVEL, NOT JOINT
// --------------------
// Each treatment level is an independent scalar Z-estimator with
// its own cross-fit, its own score and its own root, so the
// methods are per level and the variance is 1x1 -- the
// `DoubleMLQTE::sandwich_se_at` shape (v0.95.0), not the joint
// multi-column `sandwich_se` of the DID family. A joint
// `Cov(theta_j, theta_j')` across treatment levels is a different,
// larger feature and is deliberately out of scope; note that the
// existing `causal_contrast` SEs (`sqrt(se_i^2 + se_ref^2)`) are
// an INDEPENDENCE approximation and would be the natural consumer
// of such a covariance, but that is not what this file builds.
//
// THE STRUCTURAL FACT: `M_inv = [[-1.0]]`
// ---------------------------------------
// APO's score has no treatment-side variation, so the child's
// `psi_a[i]` is the constant `-1` at every observation. Hence
// `mean(psi_a) == -1`, `M_inv = [[1 / mean(psi_a)]] = [[-1.0]]`,
// and `M_inv[0,0]^2 == 1` exactly. Only the square enters the
// variance, so the `+1` reading is equal here -- and unlike PQ or
// QTE (whose Jacobians are data-dependent) there is no
// fitted-derivative guard to get wrong. Test 2 pins both signs and
// the hand-computed quantity.
//
// BIT-IDENTITY, NOT A TOLERANCE
// -----------------------------
// `var_est` accumulates `gamma` as a Kahan sum of `psi[i]^2` and
// then divides by `n` TWICE, with `mean(psi_a)^2 == 1.0` exactly
// (so the `j * j` factor is the IEEE identity);
// `sandwich_variance_hc0` accumulates the same Kahan sum over the
// same products in the same index order and divides by `n` twice
// with `M_inv[0,0]^2 == 1.0`. `sandwich_se_at` builds `psi` with
// the same `psi_at(coef, psi_a, psi_b)` order `var_est` uses, and
// `coefs[j]` IS the child's `coef`. So the two sides run the
// identical sequence of IEEE operations and
//
//     sandwich_se_at(j, HC0) == ses[j]
//
// is asserted with `==`, not with a relative tolerance. Test 1
// prints the measured per-level discrepancy so the claim is
// checkable rather than asserted.
//
// THE MEMOIZE CACHE-HIT PATH
// --------------------------
// A parent cache hit skips the child loop entirely -- there is no
// live child to read `psi_b` from -- so the flattened per-level
// rows are cached as the THIRD `FitCache` predictions slot
// (`[coefs, ses, psi_b_flat]`) and restored on the hit path. This
// is not an optimisation detail: without it every
// `sandwich_se_at` call on a memoized APOS sees an empty
// `psi_b_flat` and ABORTS on the length guard. Re-fitting the
// children instead would defeat the cache, which is the entire
// point of the layer. Test 6 drives the second fit from the
// FIRST returned value (`fit1.fit()`), because `fit` takes `self`
// BY VALUE: calling `est.fit()` twice re-reads `est`'s own empty
// cache twice and the test would be vacuous.
//
// The clustered-fit caveat (shared with QTE): on non-empty
// `data.cluster_vars` the child routes to `DoubleMLAPO::fit_cluster`,
// where `ses[j]` is the unit-level cluster-robust SE divided by
// `n_units`, so the `== ses[j]` invariant does not hold there and
// `cluster_sandwich_se_at` is the row-level Arellano analogue. All
// the equality assertions here are IID-PATH ONLY, deliberately.
// The cluster method itself is exercised on the IID path, where
// all-singleton clusters collapse to HC0 and pooled clusters do
// NOT.

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

///|
/// Relative closeness at the 1e-12 level (the package's tolerance
/// for "same number, different accumulation order" -- the same
/// helper `expand_v091_test.mbt` .. `expand_v095_test.mbt` use).
fn expand_v100_close(x : Double, y : Double) -> Bool {
  let scale = if x.abs() > y.abs() { x.abs() } else { y.abs() }
  if scale == 0.0 {
    return (x - y).abs() < 1.0e-300
  }
  (x - y).abs() / scale < 1.0e-12
}

///|
/// Fitted APOS every test in this file shares. The DGP is the
/// v0.84.0 shared APO / APOS / PQ / QTE DGP
/// (`v084_apo_dgp(seed)`), re-used rather than duplicated: `n =
/// 400`, `p = 3`, `d = Bernoulli(expit(0.5 x2 - 0.3 x3))`,
/// `y = d + 0.5 x2 + U(-0.2, 0.2)`. Both treatment levels `0.0` and
/// `1.0` occur, so `[0.0, 1.0]` is a legal request and the two
/// per-level scores are genuinely different functions of the data
/// (each is the potential outcome on ITS OWN treated subset) --
/// which is what makes the per-level path observable. A
/// single-level request would not: it would pass a loop that
/// ignored `treatment_index` entirely.
///
/// Seeds 9101 / 9102 are outside the 8000-range used by
/// `expand_v084_test.mbt`, so the datasets do not collide with
/// that suite's.
fn expand_v100_apos(seed : Int) -> DoubleMLAPOS {
  DoubleMLAPOS::new(v084_apo_dgp(seed), [0.0, 1.0], n_folds=2, n_rep=1, seed~).fit()
}

///|
/// Treatment level `j`'s persisted `psi_b` row, built independently
/// of the production slice helper so the field layout itself is
/// pinned.
fn expand_v100_psi_b_row(m : DoubleMLAPOS, j : Int, n : Int) -> Array[Double] {
  let row : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    row[i] = m.psi_b_flat[j * n + i]
  }
  row
}

///|
/// All-singleton (`singleton[i] = i`) and pooled-in-blocks-of-4
/// (`pooled[i] = i / 4`) cluster ids for a sample of `n`.
fn expand_v100_cluster_ids(n : Int) -> (Array[Int], Array[Int]) {
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
/// THE assertion that puts APOS in the sandwich family, for EVERY
/// requested treatment level. Exact equality, and the measured
/// per-level discrepancy is PRINTED so the "bit-identical" claim
/// is checkable from the test log rather than taken on faith.
///
/// MEASURED on seed 9101 (`n = 400`, levels `[0.0, 1.0]`): the
/// absolute and relative differences are exactly `0.0` for both
/// levels, i.e. `hc0 - ses == 0.0` bit for bit. See the
/// `APOS100` lines in the test output.
test "apos_sandwich_hc0_equals_se_per_level" {
  let n = 400
  let n_d = n.to_double()
  let m = expand_v100_apos(9101)
  let n_levels = m.treatment_levels.length()
  inspect(n_levels == 2, content="true")
  inspect(m.coefs().length() == n_levels, content="true")
  inspect(m.ses().length() == n_levels, content="true")
  inspect(m.psi_b_flat.length() == n_levels * n, content="true")
  for j = 0; j < n_levels; j = j + 1 {
    let se_hc0 = m.sandwich_se_at(j, SandwichKind::hc0())
    let se = m.ses()[j]
    let abs_diff = se_hc0 - se
    let rel_diff = if se == 0.0 { 0.0 } else { abs_diff / se }
    println(
      "APOS100 level=" +
      j.to_string() +
      " lvl=" +
      m.treatment_levels[j].to_string() +
      " hc0=" +
      se_hc0.to_string() +
      " ses=" +
      se.to_string() +
      " abs_diff=" +
      abs_diff.to_string() +
      " rel_diff=" +
      rel_diff.to_string(),
    )
    // The invariant, exactly -- NOT a tolerance.
    inspect(se_hc0 == se, content="true")
    // ... and the portable statement of it.
    inspect(expand_v100_close(se_hc0, se), content="true")
    // The shipped variance is what `fit`'s child computed by hand
    // (`var_est`): a NAIVE (non-Kahan) sum of the same squares,
    // divided by `n` twice. Independent accumulation, same
    // quantity, and the two differ only in the last bits of the
    // compensated sum -- which is why the shipped-vs-shipped
    // comparison above is `==` and this one is not.
    let pb = expand_v100_psi_b_row(m, j, n)
    let pa : Array[Double] = Array::make(n, -1.0)
    let psi = psi_at(m.coefs()[j], pa, pb)
    let mut ss = 0.0
    for i = 0; i < n; i = i + 1 {
      ss = ss + psi[i] * psi[i]
    }
    let hand = (ss / n_d / n_d).sqrt()
    inspect(expand_v100_close(se_hc0, hand), content="true")
    // Each level reports ITS OWN number. The two levels' scores are
    // built from different treated subsets, so a loop that ignored
    // `treatment_index` (always returning level 0) is ruled out.
    if j > 0 {
      inspect(
        expand_v100_close(m.ses()[0], m.ses()[j]) == false,
        content="true",
      )
      inspect(
        expand_v100_close(m.coefs()[0], m.coefs()[j]) == false,
        content="true",
      )
    }
    // The row slice is `psi_b_flat[j * n_obs .. (j+1) * n_obs]`,
    // not offset -- pinned at both ends.
    inspect(pb[0] == m.psi_b_flat[j * n], content="true")
    inspect(pb[n - 1] == m.psi_b_flat[j * n + n - 1], content="true")
  }
}

// ---------------------------------------------------------------------------
// 2. `M_inv` IS -1, AND IT IS WHAT REPRODUCES THE CHILD'S se
// ---------------------------------------------------------------------------

///|
/// `M_inv = [[1 / mean(psi_a)]] = [[-1.0]]` is the reading that
/// reproduces the child's `se`, for three independent reasons:
///
///   (1) `mean(psi_a)` is exactly `-1` (the child's `pa` is the
///       constant `-1` at every index), so `M_inv[0,0] == -1.0`.
///   (2) The variance sees the Jacobian only through its SQUARE, so
///       the `+1` reading is numerically identical -- both are
///       asserted to equal the shipped `ses[j]` EXACTLY. This is
///       asserted as a property of the constant, not left implicit:
///       it is precisely the thing that makes APOS safe against the
///       sign of the up-to-sign Jacobian inverse.
///   (3) A double-counted Jacobian (`M_inv = [[1 / mean(psi_a)^2]]`,
///       `[[2]]`, i.e. any reading other than a unit square) does
///       NOT reproduce `se` -- so the test would fail if the
///       implementation silently picked some other constant.
///
/// Also pins that the score really is the package-order
/// `theta * psi_a + psi_b`: the SWAPPED reading
/// `psi_a + theta * psi_b` (the form some DID-family comments use)
/// is a different function whose root is not `coefs[j]`, so its
/// variance must differ materially.
test "apos_m_inv_is_minus_one_and_reproduces_se" {
  let n = 400
  let m = expand_v100_apos(9101)
  let pa : Array[Double] = Array::make(n, -1.0)
  // (1) The Jacobian is exactly the constant `-1`, so
  // `1 / mean(psi_a) == -1.0`. (`m_inv_1x1_at` is module-private
  // and deliberately so; the shipped observable is `se` below, and
  // that the shipped `M_inv` is this value is what (2) checks.)
  inspect(mean(pa) == -1.0, content="true")
  inspect(1.0 / mean(pa) == -1.0, content="true")
  for j = 0; j < m.treatment_levels.length(); j = j + 1 {
    let pb = expand_v100_psi_b_row(m, j, n)
    let psi = psi_at(m.coefs()[j], pa, pb)
    let se = m.ses()[j]
    // (2) `+1` and `-1` are the same number to the variance.
    let minus_one = sandwich_variance_hc0(
      pa,
      psi,
      Matrix::from_array([-1.0], 1, 1),
      n,
      1,
    ).sqrt()
    let plus_one = sandwich_variance_hc0(
      pa,
      psi,
      Matrix::from_array([1.0], 1, 1),
      n,
      1,
    ).sqrt()
    inspect(minus_one == plus_one, content="true")
    inspect(minus_one == se, content="true")
    inspect(plus_one == se, content="true")
    // (3) Any other unit-scale constant is ruled out. `M_inv = 2`
    // squares to 4 and inflates the variance (and the SE) by 2x.
    let double_counted = sandwich_variance_hc0(
      pa,
      psi,
      Matrix::from_array([2.0], 1, 1),
      n,
      1,
    ).sqrt()
    inspect(expand_v100_close(double_counted, se) == false, content="true")
    inspect(expand_v100_close(double_counted / se, 2.0), content="true")
    // The package-order score, versus the swapped form
    // `psi_a + theta * psi_b`. The latter's mean is dominated by
    // the estimand itself rather than ~0, which is the real defect
    // -- its variance lands within a few percent of `se`, so a
    // "the wrong score gives a wildly different SE" claim would be
    // a claim about the DGP's scale, not about the misreading.
    let psi_swapped = psi_at(m.coefs()[j], pb, pa)
    let mut ss_swapped = 0.0
    for i = 0; i < n; i = i + 1 {
      ss_swapped = ss_swapped + psi_swapped[i] * psi_swapped[i]
    }
    let se_swapped = sandwich_variance_hc0(
      pa,
      psi_swapped,
      Matrix::from_array([-1.0], 1, 1),
      n,
      1,
    ).sqrt()
    inspect(expand_v100_close(se_swapped, se) == false, content="true")
    inspect(mean(psi_swapped).abs() > mean(psi).abs(), content="true")
    // The honest score's mean IS the estimating equation at the
    // reported root: small, and zero only in expectation.
    inspect(mean(psi).abs() < 0.2, content="true")
  }
}

// ---------------------------------------------------------------------------
// 3. THE HC FAMILY
// ---------------------------------------------------------------------------

///|
/// HC1 / HC0 == `sqrt(n / (n - 1))` to 1e-12 -- per level, with
/// `n_params == 1`. This pins the "one scalar estimand per
/// treatment level, NOT `treatment_levels.length()`" decision: the
/// plausible misreading `k = n_levels` gives `sqrt(n / (n - 2))`,
/// which is a different number and is ruled out below.
///
/// HC2 == HC1 (the v0.88.0 constant leverage `h_ii = 1 / n_obs`
/// makes every HC2 term divide by `(n - 1) / n`), and
/// HC3 == HC1^2 / HC0. The ordering is
/// `HC3 > HC1 == HC2 > HC0`, so `HC2 >= HC0` holds -- but
/// STRICTLY, not weakly: any test written as `HC2 > HC0` passes
/// here only because HC1 > HC0. `HC2 == HC0` is false, and that
/// (the pre-v0.88 chain `HC0 > HC2`) is ruled out too.
test "apos_hc_family_ordering" {
  let n = 400
  let n_d = n.to_double()
  let m = expand_v100_apos(9101)
  let n_levels = m.treatment_levels.length()
  for j = 0; j < n_levels; j = j + 1 {
    let se0 = m.sandwich_se_at(j, SandwichKind::hc0())
    let se1 = m.sandwich_se_at(j, SandwichKind::hc1())
    let se2 = m.sandwich_se_at(j, SandwichKind::hc2())
    let se3 = m.sandwich_se_at(j, SandwichKind::hc3())
    // HC1: the finite-sample correction, with k = 1.
    inspect(
      expand_v100_close(se1 / se0, (n_d / (n_d - 1.0)).sqrt()),
      content="true",
    )
    // `k = n_levels` is the wrong reading and is ruled out.
    let wrong = (n_d / (n_d - n_levels.to_double())).sqrt()
    inspect(expand_v100_close(se1 / se0, wrong) == false, content="true")
    // HC2 == HC1; HC3 == HC1^2 / HC0.
    inspect(expand_v100_close(se2, se1), content="true")
    inspect(expand_v100_close(se3, se1 * se1 / se0), content="true")
    // The ordering, including the two inequalities the brief calls
    // out (`HC2 >= HC0`, and the per-kind differences).
    inspect(se1 > se0, content="true")
    inspect(se2 > se0, content="true")
    inspect(se3 > se1, content="true")
    inspect((se0 > se2) == false, content="true")
    inspect(se1 != se0, content="true")
    inspect(expand_v100_close(se3, se1) == false, content="true")
    // Anchored to the shipped SE, not merely internally consistent.
    inspect(se0 == m.ses()[j], content="true")
  }
}

// ---------------------------------------------------------------------------
// 4. THE CLUSTER PATH
// ---------------------------------------------------------------------------

///|
/// `cluster_sandwich_se_at` runs, is finite, and consumes the SAME
/// `psi_a` / `psi` / `M_inv` as the IID path -- checked by
/// reproducing the shipped value from the shared free function.
///
/// NOTABLE, AND THE POINT OF THE COMMENT: with POOLED clusters this
/// is NOT equal to the IID `sandwich_se_at(j, HC0)`, for two
/// independent reasons.
///   (1) The within-cluster cross terms enter the meat, so the
///       cluster score sums are not `sum_i psi_i^2`.
///   (2) The variance is divided by `n_obs` (the ROW count) while a
///       clustered FIT's `ses[j]` is divided by `n_units`. So even
///       with all-singleton clusters -- where (1) vanishes -- the
///       two agree on an IID fit but NOT on a clustered one.
/// With all-singleton clusters the meat degenerates to
/// `sum_i psi_i^2` and the formula collapses to the IID HC0, hence
/// to `ses[j]`, which is the one equality asserted here.
test "apos_cluster_sandwich_per_level" {
  let n = 400
  let m = expand_v100_apos(9101)
  let (singleton, pooled) = expand_v100_cluster_ids(n)
  let pa : Array[Double] = Array::make(n, -1.0)
  for j = 0; j < m.treatment_levels.length(); j = j + 1 {
    let se = m.ses()[j]
    let se0 = m.sandwich_se_at(j, SandwichKind::hc0())
    let cl_single = m.cluster_sandwich_se_at(j, singleton)
    let cl_pooled = m.cluster_sandwich_se_at(j, pooled)
    // All-singleton clusters collapse to the IID HC0 exactly.
    inspect(cl_single == se, content="true")
    inspect(cl_single == se0, content="true")
    // Pooled clusters do NOT: the within-block cross terms change
    // the meat, and the value is not the IID number. Finite, and
    // materially different (> 0.1% away).
    inspect(cl_pooled.is_nan() == false, content="true")
    inspect(cl_pooled.is_inf() == false, content="true")
    inspect(cl_pooled > 0.0, content="true")
    inspect(expand_v100_close(cl_pooled, se0) == false, content="true")
    inspect((cl_pooled / se0 - 1.0).abs() > 1.0e-3, content="true")
    // Reproducible from the shared free function with the same
    // inputs -- so the cluster method is not secretly using a
    // different score or a different Jacobian.
    let pb = expand_v100_psi_b_row(m, j, n)
    let psi = psi_at(m.coefs()[j], pa, pb)
    let cl_hand = cluster_sandwich_variance(
      pa,
      psi,
      Matrix::from_array([-1.0], 1, 1),
      pooled,
      1,
    ).sqrt()
    inspect(cl_pooled == cl_hand, content="true")
    // The `n_units` vs `n_obs` denominator is why a clustered FIT's
    // `ses[j]` is a different quantity. Here, on the IID fit, the
    // row count and the singleton-cluster count coincide
    // (`n_units == n_obs`), so the two degeneracies cannot be told
    // apart -- the doc comment's claim is about a clustered fit and
    // is deliberately not asserted here.
    let n_singleton_clusters = n
    inspect(n_singleton_clusters == n, content="true")
  }
}

// ---------------------------------------------------------------------------
// 5. bias_corrected_coef_at
// ---------------------------------------------------------------------------

///|
/// `bias_corrected_coef_at(j)` returns `coefs[j]` EXACTLY -- the
/// v0.91.0 design that `DoubleMLAPO::bias_corrected_coef` already
/// ships for the child, and that the fifteen other estimators
/// follow. Under an orthogonal estimating function any score-based
/// bias correction is provably vacuous, so the accessor reports the
/// uncorrected point estimate rather than a number that merely
/// looks like a correction.
///
/// The pre-v0.91.0 form `coef + mean(psi_b - coef * psi_a)` is
/// pinned as the thing this is NOT: for APO's constant `psi_a = -1`
/// that closed form is exactly `3 * coef`, and it is not a bias
/// estimate.
test "apos_bias_corrected_coef_at_is_identity" {
  let n = 400
  let m = expand_v100_apos(9102)
  let coefs = m.coefs()
  for j = 0; j < m.treatment_levels.length(); j = j + 1 {
    inspect(m.bias_corrected_coef_at(j) == coefs[j], content="true")
    // Each level reports ITS OWN coefficient.
    if j > 0 {
      inspect(
        (m.bias_corrected_coef_at(j) == m.bias_corrected_coef_at(0)) == false,
        content="true",
      )
    }
    // The honest no-op is not the pre-v0.91.0 `3 * coef` closed
    // form. (With `mean(psi_a) == -1`, the old expression
    // `coef * (1 - 2 * mean(psi_a))` is `3 * coef`; the
    // coefficients here are ~O(1) and non-zero, so the two differ.)
    inspect(coefs[j] != 0.0, content="true")
    inspect(m.bias_corrected_coef_at(j) != 3.0 * coefs[j], content="true")
    // Nor is it the old expression evaluated on this data.
    let pb = expand_v100_psi_b_row(m, j, n)
    let pa : Array[Double] = Array::make(n, -1.0)
    let mean_pb = mean(pb)
    let old = coefs[j] + (mean_pb - coefs[j] * mean(pa))
    inspect(m.bias_corrected_coef_at(j) != old, content="true")
  }
}

// ---------------------------------------------------------------------------
// 6. THE MEMOIZE CACHE-HIT TEST
// ---------------------------------------------------------------------------

///|
/// The per-level IF components must survive a memoize cache hit,
/// and this is the test that proves it.
///
/// `fit` takes `self` BY VALUE and returns a new value, so
/// `est.fit()` called twice never touches the cache: the writeback
/// lands on the FIRST returned value, and the second call must be
/// driven from it (`fit1.fit()`), exactly as
/// `expand_v084_test.mbt::apos_enable_memoize_smoke` does. Driving
/// it from `est` instead would re-read `est`'s own empty cache and
/// every assertion below would be vacuous.
///
/// A parent cache hit skips the per-level child loop entirely --
/// there is no live child left to read `psi_b` from -- so the rows
/// travel as the third `FitCache` predictions slot and are restored
/// on the hit path. A regression that returned the `new()`
/// all-empty sentinel on the hit path would ABORT inside
/// `psi_b_row_at` on the length guard; one that returned a
/// wrong-but-right-length row would move the SE. Both are caught
/// here, and the last two assertions tie the restored value to a
/// FRESH (non-memoized) fit so it cannot be satisfied by two
/// consistent errors.
test "apos_sandwich_after_memoize_cache_hit" {
  let n = 400
  let base = DoubleMLAPOS::new(
    v084_apo_dgp(9102),
    [0.0, 1.0],
    n_folds=2,
    n_rep=1,
    seed=9102,
  ).enable_memoize()
  let f1 = base.fit()
  // The cache-hit fit. `f1`, NOT `base`.
  let f2 = f1.fit()
  inspect(f1.has_cache(), content="true")
  inspect(f2.has_cache(), content="true")
  // The IF components are present on BOTH paths.
  inspect(f1.psi_b_flat.length() == 2 * n, content="true")
  inspect(f2.psi_b_flat.length() == 2 * n, content="true")
  // Fresh, non-memoized reference fit on the same data.
  let fresh = DoubleMLAPOS::new(
    v084_apo_dgp(9102),
    [0.0, 1.0],
    n_folds=2,
    n_rep=1,
    seed=9102,
  ).fit()
  for j = 0; j < 2; j = j + 1 {
    // The invariant SURVIVES the cache hit -- the assertion that
    // fails if the third slot is not restored.
    let se_hc0 = f2.sandwich_se_at(j, SandwichKind::hc0())
    inspect(se_hc0 == f2.ses()[j], content="true")
    // ... and the cache hit did not move the number: a hit must be
    // a no-op for the sandwich, which is the whole contract of the
    // memoize layer.
    inspect(f1.sandwich_se_at(j, SandwichKind::hc0()) == se_hc0, content="true")
    inspect(
      fresh.sandwich_se_at(j, SandwichKind::hc0()) == se_hc0,
      content="true",
    )
    // `ses[j]` is itself unchanged, so the equality above is not an
    // accident of two errors cancelling.
    inspect(f1.ses()[j] == f2.ses()[j], content="true")
    inspect(f2.ses()[j] == fresh.ses()[j], content="true")
    // The restored rows are byte-identical to the freshly fitted
    // ones -- which is what makes the single-binding construction
    // (`preds[2]` on a hit, `pb_flat` on a miss) safe.
    let pb2 = expand_v100_psi_b_row(f2, j, n)
    let pb_fresh = expand_v100_psi_b_row(fresh, j, n)
    for i = 0; i < n; i = i + 1 {
      inspect(pb2[i] == pb_fresh[i], content="true")
    }
    // The full HC family and the cluster path agree on the hit
    // path too -- a restored-but-mislabelled row would break the
    // HC1 ratio before it broke anything else.
    let n_d = n.to_double()
    inspect(
      expand_v100_close(
        f2.sandwich_se_at(j, SandwichKind::hc1()) / se_hc0,
        (n_d / (n_d - 1.0)).sqrt(),
      ),
      content="true",
    )
    let (singleton, _pooled) = expand_v100_cluster_ids(n)
    inspect(f2.cluster_sandwich_se_at(j, singleton) == se_hc0, content="true")
    // ... and the bias accessor, per level, on the hit path.
    inspect(f2.bias_corrected_coef_at(j) == f2.coefs()[j], content="true")
  }
}

// ---------------------------------------------------------------------------
// 7. THE DEFAULT SINGLE-LEVEL CASE
// ---------------------------------------------------------------------------

///|
/// `treatment_levels = [1.0]` is the degenerate-but-legal case: one
/// scalar estimand, so the flattened IF matrix is a single row and
/// the `j * n_obs` slice is the whole array. Every other test here
/// uses two levels, so nothing else would catch an off-by-one in the
/// slice or an `n_levels - 1` bound in a guard.
test "apos_single_treatment_level_case" {
  let n = 400
  let m = DoubleMLAPOS::new(
    v084_apo_dgp(9101),
    [1.0],
    n_folds=2,
    n_rep=1,
    seed=9101,
  ).fit()
  inspect(m.n_treatment_levels() == 1, content="true")
  inspect(m.coefs().length() == 1, content="true")
  inspect(m.ses().length() == 1, content="true")
  inspect(m.psi_b_flat.length() == n, content="true")
  // The invariant.
  inspect(
    m.sandwich_se_at(0, SandwichKind::hc0()) == m.ses()[0],
    content="true",
  )
  // The row slice is `psi_b_flat[0 .. n]` -- not offset.
  let row = expand_v100_psi_b_row(m, 0, n)
  inspect(row[0] == m.psi_b_flat[0], content="true")
  inspect(row[n - 1] == m.psi_b_flat[n - 1], content="true")
  // The HC family and the bias accessor.
  inspect(
    m.sandwich_se_at(0, SandwichKind::hc3()) >
    m.sandwich_se_at(0, SandwichKind::hc0()),
    content="true",
  )
  inspect(m.bias_corrected_coef_at(0) == m.coefs()[0], content="true")
  // The cluster path.
  let (singleton, pooled) = expand_v100_cluster_ids(n)
  inspect(m.cluster_sandwich_se_at(0, singleton) == m.ses()[0], content="true")
  inspect(
    expand_v100_close(m.cluster_sandwich_se_at(0, pooled), m.ses()[0]) == false,
    content="true",
  )
}

// ---------------------------------------------------------------------------
// 8. THE NUMBERS MUST BE MEANINGFUL, NOT JUST FINITE
// ---------------------------------------------------------------------------

///|
/// A ratio-only suite cannot catch the degenerate-propensity failure
/// mode, and that failure mode still satisfies every HC identity: a
/// DGP the OLS propensity learner cannot recover sends `m` out of
/// `[0, 1]`, `clip_vec` pins the offending rows at `1e-6`, the
/// `1 / m` score terms hit `1e6`, and `ses[j]` becomes a
/// meaningless magnitude -- perfectly self-consistent in ratio. So
/// the magnitude is pinned here, on a second seed: `mean(psi^2)` is
/// `O(1)`, the SEs are plausible for a conditional-outcome mean, and
/// both levels are finite and positive. If the score ever reaches
/// the `1e6` regime this is the test that fails.
test "apos_sandwich_magnitudes_are_meaningful" {
  let n = 400
  let m = expand_v100_apos(9102)
  let pa : Array[Double] = Array::make(n, -1.0)
  for j = 0; j < m.treatment_levels.length(); j = j + 1 {
    let pb = expand_v100_psi_b_row(m, j, n)
    let psi = psi_at(m.coefs()[j], pa, pb)
    let m2 = mean(expand_v100_square(psi))
    inspect(m2.is_nan() == false, content="true")
    inspect(m2.is_inf() == false, content="true")
    // O(1): not the `1e6` regime, not collapsed to ~0 either.
    inspect(m2 > 1.0e-3 && m2 < 1.0e3, content="true")
    let se = m.ses()[j]
    inspect(se.is_nan() == false, content="true")
    inspect(se.is_inf() == false, content="true")
    inspect(se > 0.0, content="true")
    // The OUTCOME SCALE, not the coefficient: the shipped SE of a
    // conditional-outcome mean must be a small fraction of the
    // outcome's own spread. On this DGP `y = d + 0.5 x2 + U(-.2,
    // .2)` so `sd(y) ~ 0.75` and the SE of a mean of 400 rows is
    // well under a tenth of that. (Asserting against `|coef|`
    // instead would be a DGP artefact, not a check: level `0.0`'s
    // potential-outcome mean is ~0 BY CONSTRUCTION -- it is the
    // pure confounding residual -- so `|coef|` there is small and
    // its relative SE is meaningless.)
    inspect(se > 1.0e-3 && se < 0.1, content="true")
    // Level 1's estimand IS O(1) (`E[y | d = 1] ~ 1`), so its
    // relative SE is the meaningful one and it is small.
    if m.treatment_levels[j] == 1.0 {
      inspect(m.coefs()[j] > 0.5, content="true")
      inspect(se / m.coefs()[j] < 0.2, content="true")
    }
    println(
      "APOS100M level=" +
      j.to_string() +
      " coef=" +
      m.coefs()[j].to_string() +
      " se=" +
      se.to_string() +
      " mean_psi2=" +
      m2.to_string(),
    )
    // And the shipped HC0 is anchored to it.
    inspect(m.sandwich_se_at(j, SandwichKind::hc0()) == se, content="true")
  }
}

///|
/// Elementwise square, in a fresh array. Written out rather than
/// borrowed so the "independent accumulation" claim in test 1 is
/// the only place that hand-rolls an IF; this one only needs the
/// second moment's magnitude.
fn expand_v100_square(xs : Array[Double]) -> Array[Double] {
  let out : Array[Double] = Array::make(xs.length(), 0.0)
  for i = 0; i < xs.length(); i = i + 1 {
    out[i] = xs[i] * xs[i]
  }
  out
}
