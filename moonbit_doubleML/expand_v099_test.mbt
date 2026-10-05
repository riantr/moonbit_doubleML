///|
// v0.99.0: corruption probes for the memoization read path.
//
// WHY THIS FILE EXISTS
// -------------------
// The `*_enable_memoize_smoke` tests shipped in v0.80-v0.85 were
// structurally incapable of failing. They read:
//
//     let fit1 = est.fit()      // cache written back onto `fit1`
//     let fit2 = est.fit()      // <-- `est` still has an EMPTY cache
//
// `fit` takes `self` by value and RETURNS a new estimator, so the
// writeback lands on `fit1` alone. `est.fit()` therefore re-entered
// the MISS branch and the assertions compared fresh-vs-fresh. That
// holds for 11 tests across `fit_cache_test.mbt`, `expand_v083_test.mbt`
// and `expand_v084_test.mbt`. (The v0.85 PolicyTree tests were
// already correct -- they say so in a comment -- and the v0.93-v0.98
// `*_after_memoize_cache_hit` tests were also correct, which is how
// the fix became known without being backfilled.)
//
// v0.99.0 fixed those 11 call sites. That makes them REAL, but it
// still does not give them teeth: they assert
//
//     HIT-on-intact-cache == MISS
//
// and a cache-read path that was DELETED OUTRIGHT also satisfies
// that, because MISS is deterministic and the fresh recompute
// reproduces the same bits. Replaying nothing and replaying
// something correctly look identical from the outside.
//
// So this file adds the missing direction. For each of five
// distinct cache layouts:
//
//   Point 1  MISS.  `est` carries the empty constructor cache.
//   Point 2  HIT on an INTACT cache reproduces Point 1 bit-for-bit.
//   Point 3  HIT on a CORRUPTED cache does NOT reproduce Point 1.
//
// Point 3 is the assertion with teeth. It writes a known-wrong
// value into one cached slot and requires the reported estimate to
// move. If the read path were dead, the corrupted slot would be
// ignored, Point 3 would equal Point 1, and the test would go red.
// The cache key is computed from (data, learners, fold params) and
// NOT from the prediction contents, so corrupting a slot leaves the
// key valid and forces the hit branch -- the probe isolates the
// read, it does not accidentally test a miss.
//
// One slot per estimator, chosen to be load-bearing and NOT
// post-processed on the way out:
//
//   IRM  `predictions[0]` = g0_hat   (unclipped outcome nuisance)
//   PLR  `predictions[0]` = g_hat
//   CVAR `predictions[0]` = g_hat
//   BLP  `predictions[0]` = coef      (cached coefficient array)
//   PQ   `predictions[0][0]` = theta  (cached theta scalar)
///

///|
/// The shared DGP for the single-coefficient binary-treatment
/// estimators. Binary `d`, linear outcome, so `y = d + X'1 + noise`
/// with a true ATE of 1.0. IRM / PLR / CVAR all consume this shape.
fn v099_dgp(seed : Int, n : Int, p : Int) -> DoubleMLData {
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let rng = chacha8_rng(seed)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    let mut s = 0.0
    for j = 0; j < p; j = j + 1 {
      s = s + x_flat[i * p + j]
    }
    y[i] = 1.0 * d[i] + s + (rng.double() - 0.5) * 0.1
  }
  DoubleMLData::new(Matrix::from_array(x_flat, n, p), y, d)
}

///|
/// Elementwise bit-identity over two Double arrays. Used instead of
/// a tolerance so that "the cache replayed the stored numbers"
/// cannot be satisfied by a numerically-close recompute.
fn v099_identical(a : Array[Double], b : Array[Double]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
// Cache layout: `[g0_hat, g1_hat, m_hat, m_raw]`, four arrays of
// length n_obs.
test "v099_irm_cache_read_is_load_bearing" {
  let est = DoubleMLIRM::new(
    v099_dgp(9901, 400, 3),
    n_folds=2,
    n_rep=1,
    seed=9901,
  ).enable_memoize()
  // Point 1: MISS.
  let miss = est.fit()
  inspect(miss.has_cache(), content="true")
  // Point 2: HIT on an intact cache is bit-identical to the MISS.
  let hit = miss.fit()
  inspect(hit.has_cache(), content="true")
  inspect(hit.coef() == miss.coef(), content="true")
  inspect(hit.se() == miss.se(), content="true")
  // Point 3: corrupt the cached outcome nuisance `g0_hat[0]` by
  // +50 and refit. A live read path MUST move the estimate.
  let dirty = est.fit()
  dirty.fit_cache.predictions[0][0] = dirty.fit_cache.predictions[0][0] + 50.0
  let corrupted = dirty.fit()
  let moved = (corrupted.coef() - miss.coef()).abs()
  inspect(moved > 1.0e-6, content="true")
}

///|
// Cache layout: `[g_hat, m_hat]`, two arrays of length n_obs.
test "v099_plr_cache_read_is_load_bearing" {
  let est = DoubleMLPLR::new(
    v099_dgp(9902, 500, 5),
    n_folds=2,
    n_rep=1,
    seed=9902,
  ).enable_memoize()
  let miss = est.fit()
  inspect(miss.has_cache(), content="true")
  let hit = miss.fit()
  inspect(hit.coef() == miss.coef(), content="true")
  inspect(hit.se() == miss.se(), content="true")
  let dirty = est.fit()
  dirty.fit_cache.predictions[0][0] = dirty.fit_cache.predictions[0][0] + 50.0
  let corrupted = dirty.fit()
  let moved = (corrupted.coef() - miss.coef()).abs()
  inspect(moved > 1.0e-6, content="true")
}

///|
// Cache layout: `[g_hat, m_final, ipw_vec]`. Note `ipw_vec` is the
// odd one out -- it is indexed by FOLD, not by observation, so it
// has length `n_folds`, not `n_obs`. The probe targets `g_hat` to
// keep the length convention out of the picture.
test "v099_cvar_cache_read_is_load_bearing" {
  let est = DoubleMLCVAR::new(
    v099_dgp(9903, 400, 3),
    quantile=0.5,
    n_folds=2,
    n_rep=1,
    seed=9903,
  ).enable_memoize()
  let miss = est.fit()
  inspect(miss.has_cache(), content="true")
  let hit = miss.fit()
  inspect(hit.coef() == miss.coef(), content="true")
  inspect(hit.se() == miss.se(), content="true")
  let dirty = est.fit()
  dirty.fit_cache.predictions[0][0] = dirty.fit_cache.predictions[0][0] + 50.0
  let corrupted = dirty.fit()
  let moved = (corrupted.coef() - miss.coef()).abs()
  inspect(moved > 1.0e-6, content="true")
}

///|
// Cache layout: `[coef, se, [rss], [var_y], residuals]` -- a
// five-slot layout with no fold partition at all (BLP is a
// single-pass OLS projection, so `fold_ids` is a length-n_obs
// placeholder). `predictions[0]` IS the reported coefficient, so
// this probe is the sharpest of the five: the corrupted value
// should surface in the public API with the perturbation intact.
test "v099_blp_cache_read_is_load_bearing" {
  let n = 300
  let basis = Matrix::zeros(n, 1)
  let orth : Array[Double] = Array::make(n, 0.0)
  let rng = chacha8_rng(9904)
  for i = 0; i < n; i = i + 1 {
    let xv = (i.to_double() - 150.0) / 150.0
    basis.set(i, 0, xv)
    orth[i] = 2.0 + 3.0 * xv + 0.05 * (rng.double() - 0.5)
  }
  let est = DoubleMLBLP::new(basis, orth, cov_type="HC0").enable_memoize()
  let miss = est.fit()
  inspect(miss.has_cache(), content="true")
  let hit = miss.fit()
  inspect(v099_identical(hit.coef(), miss.coef()), content="true")
  inspect(v099_identical(hit.se(), miss.se()), content="true")
  let dirty = est.fit()
  dirty.fit_cache.predictions[0][0] = dirty.fit_cache.predictions[0][0] + 7.0
  let corrupted = dirty.fit()
  // The perturbation must appear verbatim in the reported
  // coefficient -- not merely "somehow different".
  inspect(
    (corrupted.coef()[0] - miss.coef()[0] - 7.0).abs() < 1.0e-12,
    content="true",
  )
}

///|
// Cache layout: `[[theta, deriv], psi_flat]`. A two-slot layout
// packing two scalars into slot 0 (so the hit path can read both
// back without reshaping) plus the length-n_obs score vector.
// `predictions[0][0]` is the cached `theta`, which the hit path
// returns directly as the point estimate, so the probe expects the
// perturbation to survive exactly.
test "v099_pq_cache_read_is_load_bearing" {
  let est = DoubleMLPQ::new(
    v099_dgp(9905, 500, 3),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=9905,
  ).enable_memoize()
  let miss = est.fit()
  inspect(miss.has_cache(), content="true")
  let hit = miss.fit()
  inspect(hit.coef() == miss.coef(), content="true")
  inspect(hit.se() == miss.se(), content="true")
  // Corrupt the cached theta. The hit path reads `preds[0][0]` and
  // returns it as `coef`, so the shift must be exact.
  let dirty = est.fit()
  dirty.fit_cache.predictions[0][0] = dirty.fit_cache.predictions[0][0] + 3.0
  let corrupted = dirty.fit()
  inspect(
    (corrupted.coef() - miss.coef() - 3.0).abs() < 1.0e-12,
    content="true",
  )
  // The cached `deriv` (slot 0, index 1) drives the IID SE as
  // `gamma / (deriv^2 * n)`, so perturbing it must move `se` while
  // leaving `coef` alone -- a second, independent load-bearing
  // slot in the same packed array.
  let dirty2 = est.fit()
  dirty2.fit_cache.predictions[0][1] = dirty2.fit_cache.predictions[0][1] * 2.0
  let corrupted2 = dirty2.fit()
  inspect(corrupted2.coef() == miss.coef(), content="true")
  inspect((corrupted2.se() / miss.se() - 0.5).abs() < 1.0e-12, content="true")
}
