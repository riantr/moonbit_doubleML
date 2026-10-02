///|
// v0.78.0+: white-box tests for
// `DoubleMLRDD::sensitivity_analysis_cluster`. Closes the
// v0.72-v0.74 cluster-aware sensitivity family for the
// kernel-weighted local-polynomial RDD estimator. RDD was
// excluded from the v0.72-v0.74 IRM-style helpers because
// the bandwidth-based weighting does not fit the v0.72
// baseline's uniform per-observation scaling. v0.78.0
// extends `irm_style_sensitivity_cluster` with an optional
// `kernel_weights` parameter (default empty = uniform
// weights, v0.72 behavior); when non-empty, each
// observation's residual and Riesz row are scaled by
// `w[k] = 1 - |u_k| / h` (triangular kernel weight on the
// bandwidth-restricted sample) before the cluster sum.
//
// Each test builds a synthetic clustered DGP with
// within-cluster Y correlation (cluster-level random
// effect), so the cluster-aware `sigma2_cluster` /
// `nu2_cluster` differ from the IID `mean(residuals^2)` /
// `mean(psi_a^2)` baselines.

// ---------------------------------------------------------------------------
// Smoke test
// ---------------------------------------------------------------------------

///|
test "rdd_sensitivity_cluster_returns_finite_result" {
  // Synthetic clustered DGP: 30 clusters of 30 obs each
  // (n = 900). Each cluster gets a cluster-level random
  // effect on Y, so within-cluster Y correlation > 0.
  // Cutoff at score = 0, bandwidth h = 0.5 (kernel =
  // triangular).
  let n_clusters = 30
  let per_cluster = 30
  let n = n_clusters * per_cluster
  let h = 0.5
  let x_mat = Matrix::zeros(n, 1)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let score : Array[Double] = Array::make(n, 0.0)
  let cluster_id : Array[Int] = Array::make(n, 0)
  let rng = chacha8_rng(78001)
  let cluster_effect : Array[Double] = Array::make(n_clusters, 0.0)
  for c = 0; c < n_clusters; c = c + 1 {
    cluster_effect[c] = (rng.double() - 0.5) * 1.0
  }
  // Build the data. Each cluster occupies a contiguous
  // block of `per_cluster` obs. Score spans [-1, 1] so
  // the bandwidth picks up roughly half on each side.
  // Y = 1 + 2 * X + 0.5 * cluster_effect + N(0, 0.25).
  for i = 0; i < n; i = i + 1 {
    let u = -1.0 + (i.to_double() + 0.5) * (2.0 / n.to_double())
    score[i] = u
    cluster_id[i] = i / per_cluster
    d[i] = if u >= 0.0 { 1.0 } else { 0.0 }
    let eps = (rng.double() - 0.5) * 0.5
    y[i] = 1.0 + 2.0 * u + 0.5 * cluster_effect[cluster_id[i]] + eps
  }
  let data = DoubleMLRDDData::new(x_mat, y, d, score)
  let fitted = DoubleMLRDD::new(data, bandwidth=h).fit()
  // Build cluster_ids for the bandwidth-restricted
  // (local) sample. The local sample is left-then-right
  // concatenated, matching the ordering of `residuals` /
  // `psi_a` on the fitted RDD.
  let n_local = fitted.n_local()
  let local_cluster : Array[Int] = Array::make(n_local, 0)
  let mut k = 0
  // Left side: u < 0.
  for i = 0; i < n; i = i + 1 {
    let u = score[i]
    if u < 0.0 && u.abs() <= h {
      local_cluster[k] = cluster_id[i]
      k = k + 1
    }
  }
  // Right side: u >= 0.
  for i = 0; i < n; i = i + 1 {
    let u = score[i]
    if u >= 0.0 && u.abs() <= h {
      local_cluster[k] = cluster_id[i]
      k = k + 1
    }
  }
  let r = fitted.sensitivity_analysis_cluster(local_cluster)
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
  assert_true(r.sigma2 >= 0.0)
  assert_true(r.nu2 >= 0.0)
  assert_true(r.max_bias >= 0.0)
}

// ---------------------------------------------------------------------------
// Cluster-aware sigma2 differs from IID sigma2 on a clustered DGP
// ---------------------------------------------------------------------------

///|
test "rdd_sensitivity_cluster_sigma2_differs_from_iid" {
  // Same shape as the smoke test, but with a stronger
  // cluster effect (cluster-level Y variance = 1.5) so
  // sigma2_cluster / sigma2_iid are visibly different.
  let n_clusters = 30
  let per_cluster = 30
  let n = n_clusters * per_cluster
  let h = 0.5
  let x_mat = Matrix::zeros(n, 1)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let score : Array[Double] = Array::make(n, 0.0)
  let cluster_id : Array[Int] = Array::make(n, 0)
  let rng = chacha8_rng(78002)
  let cluster_effect : Array[Double] = Array::make(n_clusters, 0.0)
  for c = 0; c < n_clusters; c = c + 1 {
    cluster_effect[c] = (rng.double() - 0.5) * 1.5
  }
  for i = 0; i < n; i = i + 1 {
    let u = -1.0 + (i.to_double() + 0.5) * (2.0 / n.to_double())
    score[i] = u
    cluster_id[i] = i / per_cluster
    d[i] = if u >= 0.0 { 1.0 } else { 0.0 }
    let eps = (rng.double() - 0.5) * 0.5
    y[i] = 1.0 + 2.0 * u + 0.5 * cluster_effect[cluster_id[i]] + eps
  }
  let data = DoubleMLRDDData::new(x_mat, y, d, score)
  let fitted = DoubleMLRDD::new(data, bandwidth=h).fit()
  let n_local = fitted.n_local()
  let local_cluster : Array[Int] = Array::make(n_local, 0)
  let mut k = 0
  for i = 0; i < n; i = i + 1 {
    let u = score[i]
    if u < 0.0 && u.abs() <= h {
      local_cluster[k] = cluster_id[i]
      k = k + 1
    }
  }
  for i = 0; i < n; i = i + 1 {
    let u = score[i]
    if u >= 0.0 && u.abs() <= h {
      local_cluster[k] = cluster_id[i]
      k = k + 1
    }
  }
  let r_iid = fitted.sensitivity_analysis()
  let r_cluster = fitted.sensitivity_analysis_cluster(local_cluster)
  // sigma2_cluster should differ from sigma2_iid on a
  // clustered DGP. Allow a small relative tolerance (the
  // two formulas only agree when within-cluster
  // residual correlation is exactly 0; under our DGP
  // it is strictly positive).
  let diff = (r_iid.sigma2 - r_cluster.sigma2).abs()
  let rel_diff = diff / r_iid.sigma2
  assert_true(rel_diff > 0.001)
  // Same for nu2: the cluster-aware form aggregates
  // `sum_{i in c} w[i] * psi_a[i]` per cluster, which
  // differs from `mean(psi_a^2)` under clustered psi_a.
  let diff_nu2 = (r_iid.nu2 - r_cluster.nu2).abs()
  let rel_diff_nu2 = diff_nu2 / r_iid.nu2
  assert_true(rel_diff_nu2 > 0.001)
}

// ---------------------------------------------------------------------------
// Panic tests
// ---------------------------------------------------------------------------

///|
test "panic_rdd_sensitivity_cluster_cluster_ids_length_mismatch" {
  // Build a simple RDD DGP (matches rdd_test::rdd_sharp_local_linear).
  let n = 600
  let x_mat = Matrix::zeros(n, 1)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let score : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u = (i.to_double() + 0.5) / 300.0 - 1.0
    score[i] = u
    d[i] = if u >= 0.0 { 1.0 } else { 0.0 }
    y[i] = 2.0 + u + 2.0 * d[i]
  }
  let data = DoubleMLRDDData::new(x_mat, y, d, score)
  let fitted = DoubleMLRDD::new(data, bandwidth=0.8).fit()
  // Wrong-length cluster_ids (5 vs n_local which is
  // much larger). The helper raises via
  // `require(cluster_ids.length() == n_local)`.
  let wrong_cluster : Array[Int] = [0, 0, 0, 0, 0]
  let _ = fitted.sensitivity_analysis_cluster(wrong_cluster)
}

///|
test "panic_rdd_sensitivity_cluster_no_valid_cluster" {
  // Same DGP as the length-mismatch panic test. The
  // cluster_ids here are all -1, which violates the
  // helper's `max_cid >= 0` precondition (the helper
  // raises with no valid cluster index).
  let n = 600
  let x_mat = Matrix::zeros(n, 1)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let score : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u = (i.to_double() + 0.5) / 300.0 - 1.0
    score[i] = u
    d[i] = if u >= 0.0 { 1.0 } else { 0.0 }
    y[i] = 2.0 + u + 2.0 * d[i]
  }
  let data = DoubleMLRDDData::new(x_mat, y, d, score)
  let fitted = DoubleMLRDD::new(data, bandwidth=0.8).fit()
  let n_local = fitted.n_local()
  let bad : Array[Int] = Array::make(n_local, -1)
  let _ = fitted.sensitivity_analysis_cluster(bad)
}

///|
test "panic_rdd_sensitivity_cluster_before_fit" {
  // Pre-fit precondition: `require(self.fitted)` raises.
  let n = 600
  let x_mat = Matrix::zeros(n, 1)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let score : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u = (i.to_double() + 0.5) / 300.0 - 1.0
    score[i] = u
    d[i] = if u >= 0.0 { 1.0 } else { 0.0 }
    y[i] = 2.0 + u + 2.0 * d[i]
  }
  let data = DoubleMLRDDData::new(x_mat, y, d, score)
  let model = DoubleMLRDD::new(data, bandwidth=0.8)
  let cluster : Array[Int] = Array::makei(600, fn(i) { i / 20 })
  let _ = model.sensitivity_analysis_cluster(cluster)
}
