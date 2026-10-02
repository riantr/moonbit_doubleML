///|
// v0.74.0+: wbtests for the cluster-aware
// `sensitivity_analysis_cluster` additions on the 7
// remaining estimators (LPQ, PQ, QTE, APOS, SSM, BLP, CVaR)
// that previously only exposed the IID path. Reuses the
// v0.72 single-theta and v0.73 multi-theta helpers
// (`irm_style_sensitivity_cluster` and
// `irm_style_sensitivity_cluster_multi`) without further
// helper work; the per-estimator implementations only swap
// the variance helper against their existing IID
// `sensitivity_analysis` (v0.66-v0.71).
//
// Each test:
//   1. Generates a DGP with a known cluster structure
//      (3-5 clusters, treatment effect ~1.0, cluster-level
//      random effect so the cluster-aware sigma2/nu2 differ
//      from the IID ones).
//   2. Constructs the estimator + data and calls `.fit()`.
//   3. Calls `.sensitivity_analysis_cluster(cluster_ids)`
//      (with explicit cluster_ids; no defaults so the test
//      exercises the explicit path).
//   4. Asserts rv / sigma2 / nu2 / max_bias are finite and
//      non-negative (sensitivity is an unbiasedness-shape
//      test, not a point-estimate test).

// ---------------------------------------------------------------------------
// LPQ cluster sensitivity smoke test (v0.74.0)
// ---------------------------------------------------------------------------

///|
test "lpq_sensitivity_cluster_returns_finite_result" {
  // v0.74.0+: cluster-robust LPQ sensitivity. The IID path
  // uses `single_psi_sensitivity(self.coef, self.psi, y,
  // ...)` (centered-IF formulation: sigma2 = Var(y),
  // nu2 = mean(psi^2)). The cluster variant replicates
  // that inside `irm_style_sensitivity_cluster` by passing
  // `residuals = y - mean(y)` (so `mean(residuals^2) =
  // Var(y)`) and `psi_a = psi`. `DoubleMLLPQData` has no
  // `cluster_vars` field, so the test passes `cluster_ids`
  // explicitly. Treatment assignment is deterministic via
  // `z` (instrument) so all observations are compliers.
  let n_clusters = 4
  let per_cluster = 75
  let n = n_clusters * per_cluster
  let p = 2
  let rng = chacha8_rng(201)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let z : Array[Double] = Array::make(n, 0.0)
  let cluster : Array[Int] = Array::make(n, 0)
  let cluster_intercept : Array[Double] = Array::make(n_clusters, 0.0)
  for c = 0; c < n_clusters; c = c + 1 {
    cluster_intercept[c] = (rng.double() - 0.5) * 1.5
  }
  for i = 0; i < n; i = i + 1 {
    let c = i / per_cluster
    let ci = if c >= n_clusters { n_clusters - 1 } else { c }
    cluster[i] = ci
    x_flat[i * p + 0] = rng.double() * 2.0 - 1.0
    x_flat[i * p + 1] = rng.double() * 2.0 - 1.0
    z[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
    d[i] = z[i] // all-complier DGP keeps the bisection stable
    let x_sum = x_flat[i * p + 0] + x_flat[i * p + 1]
    let eps = (rng.double() - 0.5) * 0.3
    y[i] = 1.0 * d[i] + 0.3 * x_sum + cluster_intercept[ci] + eps
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLLPQData::new(x, y, d, z)
  let fitted = DoubleMLLPQ::new(
    data,
    treatment=1.0,
    quantile=0.5,
    n_folds=4,
    seed=1,
  ).fit()
  let r = fitted.sensitivity_analysis_cluster(cluster)
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
  assert_true(r.sigma2 >= 0.0)
  assert_true(r.nu2 >= 0.0)
  assert_true(r.max_bias >= 0.0)
}

// ---------------------------------------------------------------------------
// PQ cluster sensitivity smoke test (v0.74.0)
// ---------------------------------------------------------------------------

///|
test "pq_sensitivity_cluster_returns_finite_result" {
  // v0.74.0+: cluster-robust PQ sensitivity. Mirrors the
  // LPQ pattern: centered-IF formulation routed through
  // `irm_style_sensitivity_cluster` with
  // `residuals = y - mean(y)` and `psi_a = psi`. PQ
  // persists only the centered IF, not the IRM-style
  // residuals/psi_a decomposition, so the cluster variant
  // builds the same centered-y "residual" as the LPQ
  // variant. `DoubleMLData` carries `cluster_vars`
  // (defaultable) but we pass `cluster_ids` explicitly so
  // the test exercises the explicit path.
  let n_clusters = 4
  let per_cluster = 75
  let n = n_clusters * per_cluster
  let p = 2
  let rng = chacha8_rng(202)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let cluster : Array[Int] = Array::make(n, 0)
  let cluster_intercept : Array[Double] = Array::make(n_clusters, 0.0)
  for c = 0; c < n_clusters; c = c + 1 {
    cluster_intercept[c] = (rng.double() - 0.5) * 1.5
  }
  for i = 0; i < n; i = i + 1 {
    let c = i / per_cluster
    let ci = if c >= n_clusters { n_clusters - 1 } else { c }
    cluster[i] = ci
    x_flat[i * p + 0] = rng.double() * 2.0 - 1.0
    x_flat[i * p + 1] = rng.double() * 2.0 - 1.0
    let p_d = 0.4 + 0.2 * x_flat[i * p + 0]
    d[i] = if rng.double() < p_d { 1.0 } else { 0.0 }
    let x_sum = x_flat[i * p + 0] + x_flat[i * p + 1]
    let eps = (rng.double() - 0.5) * 0.3
    y[i] = 1.0 * d[i] + 0.3 * x_sum + cluster_intercept[ci] + eps
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d, cluster_vars=cluster)
  let fitted = DoubleMLPQ::new(
    data,
    treatment=1.0,
    quantile=0.5,
    n_folds=4,
    seed=1,
  ).fit()
  let r = fitted.sensitivity_analysis_cluster(cluster_ids=cluster)
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
  assert_true(r.sigma2 >= 0.0)
  assert_true(r.nu2 >= 0.0)
  assert_true(r.max_bias >= 0.0)
}

// ---------------------------------------------------------------------------
// QTE cluster sensitivity smoke test (v0.74.0)
// ---------------------------------------------------------------------------

///|
test "qte_sensitivity_cluster_returns_per_quantile_results" {
  // v0.74.0+: cluster-robust QTE sensitivity. Routes the
  // per-quantile centered IF (`psi_flat[j * n_obs + i]`)
  // through `irm_style_sensitivity_cluster_multi` with
  // `residuals = y - mean(y)` shared across all quantiles.
  // Result length must match `quantiles.length()`.
  let n_clusters = 4
  let per_cluster = 75
  let n = n_clusters * per_cluster
  let p = 2
  let quantiles : Array[Double] = [0.25, 0.5, 0.75]
  let rng = chacha8_rng(203)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let cluster : Array[Int] = Array::make(n, 0)
  let cluster_intercept : Array[Double] = Array::make(n_clusters, 0.0)
  for c = 0; c < n_clusters; c = c + 1 {
    cluster_intercept[c] = (rng.double() - 0.5) * 1.5
  }
  for i = 0; i < n; i = i + 1 {
    let c = i / per_cluster
    let ci = if c >= n_clusters { n_clusters - 1 } else { c }
    cluster[i] = ci
    x_flat[i * p + 0] = rng.double() * 2.0 - 1.0
    x_flat[i * p + 1] = rng.double() * 2.0 - 1.0
    let p_d = 0.4 + 0.2 * x_flat[i * p + 0]
    d[i] = if rng.double() < p_d { 1.0 } else { 0.0 }
    let x_sum = x_flat[i * p + 0] + x_flat[i * p + 1]
    let eps = (rng.double() - 0.5) * 0.3
    y[i] = 1.0 * d[i] + 0.3 * x_sum + cluster_intercept[ci] + eps
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d, cluster_vars=cluster)
  let fitted = DoubleMLQTE::new(data, quantiles~, n_folds=4, seed=1).fit()
  let results = fitted.sensitivity_analysis_cluster(cluster_ids=cluster)
  assert_eq(results.length(), quantiles.length())
  for k = 0; k < results.length(); k = k + 1 {
    assert_true(results[k].rv.is_nan() == false)
    assert_true(results[k].sigma2.is_nan() == false)
    assert_true(results[k].nu2.is_nan() == false)
    assert_true(results[k].max_bias.is_nan() == false)
    assert_true(results[k].sigma2 >= 0.0)
    assert_true(results[k].nu2 >= 0.0)
    assert_true(results[k].max_bias >= 0.0)
  }
}

// ---------------------------------------------------------------------------
// APOS cluster sensitivity smoke test (v0.74.0)
// ---------------------------------------------------------------------------

///|
test "apos_sensitivity_cluster_returns_per_level_results" {
  // v0.74.0+: cluster-robust APOS sensitivity. Re-fits a
  // child `DoubleMLAPO` at each treatment level and
  // delegates to its `sensitivity_analysis_cluster(...)`.
  // The per-level result length must match
  // `treatment_levels.length()`. Test uses a 3-level
  // discrete treatment so the per-level decomposition
  // exercises all three child fits.
  let n_clusters = 4
  let per_cluster = 75
  let n = n_clusters * per_cluster
  let p = 2
  let treatment_levels : Array[Double] = [0.0, 1.0, 2.0]
  let rng = chacha8_rng(204)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let cluster : Array[Int] = Array::make(n, 0)
  let cluster_intercept : Array[Double] = Array::make(n_clusters, 0.0)
  for c = 0; c < n_clusters; c = c + 1 {
    cluster_intercept[c] = (rng.double() - 0.5) * 1.5
  }
  for i = 0; i < n; i = i + 1 {
    let c = i / per_cluster
    let ci = if c >= n_clusters { n_clusters - 1 } else { c }
    cluster[i] = ci
    x_flat[i * p + 0] = rng.double() * 2.0 - 1.0
    x_flat[i * p + 1] = rng.double() * 2.0 - 1.0
    d[i] = (i % 3).to_double()
    let x_sum = x_flat[i * p + 0] + x_flat[i * p + 1]
    let eps = (rng.double() - 0.5) * 0.3
    y[i] = 0.5 * d[i] + 0.3 * x_sum + cluster_intercept[ci] + eps
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d, cluster_vars=cluster)
  let fitted = DoubleMLAPOS::new(data, treatment_levels, n_folds=4, seed=1).fit()
  let results = fitted.sensitivity_analysis_cluster(cluster_ids=cluster)
  assert_eq(results.length(), treatment_levels.length())
  for k = 0; k < results.length(); k = k + 1 {
    assert_true(results[k].rv.is_nan() == false)
    assert_true(results[k].sigma2.is_nan() == false)
    assert_true(results[k].nu2.is_nan() == false)
    assert_true(results[k].max_bias.is_nan() == false)
    assert_true(results[k].sigma2 >= 0.0)
    assert_true(results[k].nu2 >= 0.0)
    assert_true(results[k].max_bias >= 0.0)
  }
}

// ---------------------------------------------------------------------------
// SSM cluster sensitivity smoke test (v0.74.0)
// ---------------------------------------------------------------------------

///|
test "ssm_sensitivity_cluster_returns_finite_result" {
  // v0.74.0+: cluster-robust SSM sensitivity. Outcome
  // residual `y - g_d1_hat` and `psi_a = -1` constant, same
  // as the IID path; only the variance / bias computation
  // is cluster-aware. `DoubleMLSSMData` has no
  // `cluster_vars` field, so the test passes `cluster_ids`
  // explicitly. Selection indicator `s` is the cluster
  // id itself (> 0) so each cluster has at least one
  // observed outcome.
  let n_clusters = 4
  let per_cluster = 75
  let n = n_clusters * per_cluster
  let p = 2
  let rng = chacha8_rng(205)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let s : Array[Double] = Array::make(n, 0.0)
  let cluster : Array[Int] = Array::make(n, 0)
  let cluster_intercept : Array[Double] = Array::make(n_clusters, 0.0)
  for c = 0; c < n_clusters; c = c + 1 {
    cluster_intercept[c] = (rng.double() - 0.5) * 1.5
  }
  for i = 0; i < n; i = i + 1 {
    let c = i / per_cluster
    let ci = if c >= n_clusters { n_clusters - 1 } else { c }
    cluster[i] = ci
    x_flat[i * p + 0] = rng.double() * 2.0 - 1.0
    x_flat[i * p + 1] = rng.double() * 2.0 - 1.0
    let p_d = 0.4 + 0.2 * x_flat[i * p + 0]
    d[i] = if rng.double() < p_d { 1.0 } else { 0.0 }
    s[i] = 1.0 // MAR: selection is observed for all rows
    let x_sum = x_flat[i * p + 0] + x_flat[i * p + 1]
    let eps = (rng.double() - 0.5) * 0.3
    y[i] = 1.0 * d[i] + 0.3 * x_sum + cluster_intercept[ci] + eps
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLSSMData::new(x, y, d, s)
  let fitted = DoubleMLSSM::new(data, n_folds=4, seed=1).fit()
  let r = fitted.sensitivity_analysis_cluster(cluster)
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
  assert_true(r.sigma2 >= 0.0)
  assert_true(r.nu2 >= 0.0)
  assert_true(r.max_bias >= 0.0)
}

// ---------------------------------------------------------------------------
// BLP cluster sensitivity smoke test (v0.74.0)
// ---------------------------------------------------------------------------

///|
test "blp_sensitivity_cluster_returns_per_coef_results" {
  // v0.74.0+: cluster-robust BLP sensitivity. The OLS
  // residuals (`self.residuals`) are shared across coefs;
  // the per-coef `psi_a_j` rows are computed from the
  // augmented design + precision matrix (`M[j, :] @ xa_i`)
  // exactly as in the IID path. Result length must match
  // `coef.length()` (= `n_features + 1`, including the
  // intercept at index 0). `DoubleMLBLP` has no `data`
  // field, so the test passes `cluster_ids` explicitly.
  let n_clusters = 4
  let per_cluster = 75
  let n = n_clusters * per_cluster
  let p = 2 // -> n_features + 1 = 3 coefs (intercept + 2 features)
  let rng = chacha8_rng(206)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let cluster : Array[Int] = Array::make(n, 0)
  let cluster_intercept : Array[Double] = Array::make(n_clusters, 0.0)
  for c = 0; c < n_clusters; c = c + 1 {
    cluster_intercept[c] = (rng.double() - 0.5) * 1.5
  }
  for i = 0; i < n; i = i + 1 {
    let c = i / per_cluster
    let ci = if c >= n_clusters { n_clusters - 1 } else { c }
    cluster[i] = ci
    x_flat[i * p + 0] = rng.double() * 2.0 - 1.0
    x_flat[i * p + 1] = rng.double() * 2.0 - 1.0
    let eps = (rng.double() - 0.5) * 0.3
    y[i] = 1.0 +
      0.5 * x_flat[i * p + 0] +
      0.3 * x_flat[i * p + 1] +
      cluster_intercept[ci] +
      eps
  }
  let basis = Matrix::from_array(x_flat, n, p)
  let fitted = DoubleMLBLP::new(basis, y).fit()
  let results = fitted.sensitivity_analysis_cluster(cluster)
  assert_eq(results.length(), p + 1) // intercept + 2 features
  for k = 0; k < results.length(); k = k + 1 {
    assert_true(results[k].rv.is_nan() == false)
    assert_true(results[k].sigma2.is_nan() == false)
    assert_true(results[k].nu2.is_nan() == false)
    assert_true(results[k].max_bias.is_nan() == false)
    assert_true(results[k].sigma2 >= 0.0)
    assert_true(results[k].nu2 >= 0.0)
    assert_true(results[k].max_bias >= 0.0)
  }
}

// ---------------------------------------------------------------------------
// CVaR cluster sensitivity smoke test (v0.74.0)
// ---------------------------------------------------------------------------

///|
test "cvar_sensitivity_cluster_returns_finite_result" {
  // v0.74.0+: cluster-robust CVaR sensitivity. Outcome
  // residual `y - g_hat` and `psi_a = -1` constant, same
  // as the IID path; only the variance / bias computation
  // is cluster-aware. `DoubleMLData` carries `cluster_vars`
  // (defaultable) but we pass `cluster_ids` explicitly so
  // the test exercises the explicit path.
  let n_clusters = 4
  let per_cluster = 75
  let n = n_clusters * per_cluster
  let p = 2
  let rng = chacha8_rng(207)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let cluster : Array[Int] = Array::make(n, 0)
  let cluster_intercept : Array[Double] = Array::make(n_clusters, 0.0)
  for c = 0; c < n_clusters; c = c + 1 {
    cluster_intercept[c] = (rng.double() - 0.5) * 1.5
  }
  for i = 0; i < n; i = i + 1 {
    let c = i / per_cluster
    let ci = if c >= n_clusters { n_clusters - 1 } else { c }
    cluster[i] = ci
    x_flat[i * p + 0] = rng.double() * 2.0 - 1.0
    x_flat[i * p + 1] = rng.double() * 2.0 - 1.0
    let p_d = 0.4 + 0.2 * x_flat[i * p + 0]
    d[i] = if rng.double() < p_d { 1.0 } else { 0.0 }
    let x_sum = x_flat[i * p + 0] + x_flat[i * p + 1]
    let eps = (rng.double() - 0.5) * 0.5
    y[i] = 1.0 * d[i] + 0.3 * x_sum + cluster_intercept[ci] + eps
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d, cluster_vars=cluster)
  let fitted = DoubleMLCVAR::new(
    data,
    treatment=1.0,
    quantile=0.5,
    n_folds=4,
    seed=1,
  ).fit()
  let r = fitted.sensitivity_analysis_cluster(cluster_ids=cluster)
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
  assert_true(r.sigma2 >= 0.0)
  assert_true(r.nu2 >= 0.0)
  assert_true(r.max_bias >= 0.0)
}
