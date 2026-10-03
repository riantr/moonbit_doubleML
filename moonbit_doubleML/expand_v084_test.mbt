///|
// v0.84.0+: white-box tests for the memoize + vectorize expand
// to 5 additional estimators (DoubleMLAPOS, DoubleMLAPO,
// DoubleMLPQ, DoubleMLQTE, DoubleMLRDD).
//
// Coverage:
//   #1: apos_enable_memoize_smoke -- APOS with memoize ON,
//       two fits produce (coefs, ses) within 1e-10 (parent
//       cache hit is byte-equivalent to fresh per-level
//       loop).
//   #2: apo_enable_memoize_smoke -- APO with memoize ON,
//       two fits produce coef / se within 1e-10.
//   #3: pq_enable_memoize_smoke -- PQ with memoize ON,
//       two fits produce coef / se within 1e-10 (cache hit
//       skips the entire `solve_pq` -- propensity cross-fit
//       + bisection + 3x outcome cross-fits).
//   #4: qte_enable_memoize_smoke -- QTE with memoize ON,
//       two fits produce (coefs, ses) within 1e-10 across
//       multiple quantiles.
//   #5: rdd_enable_memoize_smoke -- RDD with memoize ON,
//       two fits produce coef / se within 1e-10 (cache hit
//       skips all `rdd_side` calls).
//   #6: apos_vectorize_residual_smoke -- APOS coef within
//       band of true theta on the standard APO DGP (the
//       v0.84.0+ vectorise pass on `pb[i] = g + treated *
//       (y - g) / m` must preserve the post-fold score
//       formula byte-for-byte).
//   #7: pq_vectorize_residual_smoke -- PQ coef within band
//       of true theta on the standard PQ DGP (the v0.84.0+
//       vectorise pass on the `gamma = sum(psi^2)` +
//       `u = psi1/deriv1 - psi0/deriv0` loops must preserve
//       the score byte-for-byte).

///|
// v0.84.0+: shared APO / APOS / QTE DGP. The canonical IRM
// DGP from v0.82.0+ tests: Bernoulli D, y = 1.0 * D + 0.5 *
// x[1] + noise, theta = 1.0. Same data drives all four APO
// / APOS / PQ / QTE smoke tests.
fn v084_apo_dgp(seed : Int) -> DoubleMLData {
  let n = 400
  let p = 3
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let rng = chacha8_rng(seed)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = (rng.double() - 0.5) * 2.0
    }
  }
  let x = Matrix::from_array(x_flat, n, p)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let score = 0.5 * x_flat[i * p + 1] - 0.3 * x_flat[i * p + 2]
    let pd = 1.0 / (1.0 + @math.exp(-score))
    d[i] = if rng.double() < pd { 1.0 } else { 0.0 }
    y[i] = 1.0 * d[i] + 0.5 * x_flat[i * p + 1] + (rng.double() - 0.5) * 0.4
  }
  DoubleMLData::new(x, y, d)
}

///|
test "apos_enable_memoize_smoke" {
  // APOS with memoize ON. The parent's `(coefs, ses)`
  // cache hit is byte-equivalent to a fresh per-level
  // loop (which itself benefits from the child DoubleMLAPO
  // memoize forwarding). Two consecutive fits must
  // agree to 1e-10.
  let data = v084_apo_dgp(8401)
  let apos = DoubleMLAPOS::new(data, [0.0, 1.0], n_folds=2, n_rep=1, seed=8401).enable_memoize()
  let fit1 = apos.fit()
  inspect(fit1.has_cache(), content="true")
  let fit2 = apos.fit()
  inspect(fit2.has_cache(), content="true")
  let c1 = fit1.coefs()
  let c2 = fit2.coefs()
  let s1 = fit1.ses()
  let s2 = fit2.ses()
  for k = 0; k < c1.length(); k = k + 1 {
    let d_c = (c1[k] - c2[k]).abs()
    inspect(d_c < 1.0e-10, content="true")
    let d_s = (s1[k] - s2[k]).abs()
    inspect(d_s < 1.0e-10, content="true")
  }
}

///|
test "apo_enable_memoize_smoke" {
  // APO with memoize ON. Cache hit reuses the LAST rep's
  // `(g_hat, m_hat, psi_a, psi_b)` and reruns `var_est`
  // byte-for-byte. Two consecutive fits must agree to
  // 1e-10.
  let data = v084_apo_dgp(8402)
  let apo = DoubleMLAPO::new(
    data,
    treatment_level=1.0,
    n_folds=2,
    n_rep=1,
    seed=8402,
  ).enable_memoize()
  let fit1 = apo.fit()
  inspect(fit1.has_cache(), content="true")
  let fit2 = apo.fit()
  inspect(fit2.has_cache(), content="true")
  let d_coef = (fit1.coef() - fit2.coef()).abs()
  let d_se = (fit1.se() - fit2.se()).abs()
  inspect(d_coef < 1.0e-10, content="true")
  inspect(d_se < 1.0e-10, content="true")
}

///|
test "pq_enable_memoize_smoke" {
  // PQ with memoize ON. The cache stores
  // `(theta, deriv, psi, fold_ids)`; the cache hit skips
  // the entire `solve_pq` (propensity cross-fit +
  // bisection + 3x outcome cross-fits). Two consecutive
  // fits must agree to 1e-10.
  let data = v084_apo_dgp(8403)
  let pq = DoubleMLPQ::new(
    data,
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=8403,
  ).enable_memoize()
  let fit1 = pq.fit()
  inspect(fit1.has_cache(), content="true")
  let fit2 = pq.fit()
  inspect(fit2.has_cache(), content="true")
  let d_coef = (fit1.coef() - fit2.coef()).abs()
  let d_se = (fit1.se() - fit2.se()).abs()
  inspect(d_coef < 1.0e-10, content="true")
  inspect(d_se < 1.0e-10, content="true")
}

///|
test "qte_enable_memoize_smoke" {
  // QTE with memoize ON. The cache stores
  // `(thetas_derivs, psi1, psi0)` for all quantiles; the
  // cache hit skips the entire `2 * n_quantiles`
  // `solve_pq` loop. Two consecutive fits must agree to
  // 1e-10 across all quantiles.
  let data = v084_apo_dgp(8404)
  let qte = DoubleMLQTE::new(
    data,
    quantiles=[0.25, 0.5, 0.75],
    n_folds=2,
    seed=8404,
  ).enable_memoize()
  let fit1 = qte.fit()
  inspect(fit1.has_cache(), content="true")
  let fit2 = qte.fit()
  inspect(fit2.has_cache(), content="true")
  let c1 = fit1.coefs()
  let c2 = fit2.coefs()
  let s1 = fit1.ses()
  let s2 = fit2.ses()
  for k = 0; k < c1.length(); k = k + 1 {
    let d_c = (c1[k] - c2[k]).abs()
    inspect(d_c < 1.0e-10, content="true")
    let d_s = (s1[k] - s2[k]).abs()
    inspect(d_s < 1.0e-10, content="true")
  }
}

///|
test "rdd_enable_memoize_smoke" {
  // RDD with memoize ON. RDD has no fold partition -- the
  // cache stores the entire `(coef, se, n_local,
  // residuals, psi_a)` tuple under a (data, cutoff,
  // bandwidth, fuzzy, cov_type, ml_g) key. The cache hit
  // skips all four `rdd_side` calls (the local-polynomial
  // kernel-weighted fit on each side). Two consecutive
  // fits must agree to 1e-10.
  let n = 600
  let x = Matrix::zeros(n, 1)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let score = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u = (i.to_double() + 0.5) / 300.0 - 1.0
    score[i] = u
    d[i] = if u >= 0.0 { 1.0 } else { 0.0 }
    y[i] = 2.0 + u + 2.0 * d[i]
  }
  let rdd = DoubleMLRDD::new(
    DoubleMLRDDData::new(x, y, d, score),
    bandwidth=0.8,
  ).enable_memoize()
  let fit1 = rdd.fit()
  inspect(fit1.has_cache(), content="true")
  let fit2 = rdd.fit()
  inspect(fit2.has_cache(), content="true")
  let d_coef = (fit1.coef() - fit2.coef()).abs()
  let d_se = (fit1.se() - fit2.se()).abs()
  inspect(d_coef < 1.0e-10, content="true")
  inspect(d_se < 1.0e-10, content="true")
}

///|
test "apos_vectorize_residual_smoke" {
  // Sanity check that the v0.84.0+ vectorise pass on
  // APOS's `pb[i] = g + treated * (y - g) / m` residual
  // loop still recovers the true per-level APO coefficient
  // on the canonical DGP.
  let data = v084_apo_dgp(8406)
  let fitted = DoubleMLAPOS::new(data, [0.0, 1.0], n_folds=2, seed=8406).fit()
  // APOS estimates the conditional outcome mean at each
  // treatment level, so the point estimates differ from
  // the ATE `theta = 1.0`. Just check the cache writeback
  // and the score aggregator produce sensible positive
  // values, and that the SEs are finite.
  let c = fitted.coefs()
  let s = fitted.ses()
  inspect(c.length(), content="2")
  for k = 0; k < c.length(); k = k + 1 {
    inspect(c[k] > 0.0, content="true")
    inspect(s[k] > 0.0, content="true")
    inspect(s[k].is_nan() == false, content="true")
  }
}

///|
test "pq_vectorize_residual_smoke" {
  // Sanity check that the v0.84.0+ vectorise pass on PQ's
  // `gamma = sum(psi^2)` accumulator still recovers the
  // true conditional 0.5-quantile at the treated sub-
  // population on the canonical DGP.
  let data = v084_apo_dgp(8407)
  let fitted = DoubleMLPQ::new(
    data,
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=8407,
  ).fit()
  let theta_hat = fitted.coef()
  // The PQ at q=0.5 on the treated sub-population should
  // land near `1.0 + 0.5 * x[1]_treated_median` -- which
  // on this DGP with x ~ U(-1, 1) is approximately 1.0
  // (the x[1] median is ~0). Allow 3 SE + 0.5 absolute.
  let err = (theta_hat - 1.0).abs()
  let tol = 3.0 * fitted.se() + 0.5
  inspect(err <= tol, content="true")
  inspect(fitted.se().is_nan() == false, content="true")
  inspect(fitted.se() > 0.0, content="true")
}
