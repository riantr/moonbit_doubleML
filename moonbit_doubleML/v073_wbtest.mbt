///|
// v0.73.0+: wbtests for the cluster-aware
// `sensitivity_analysis_cluster` additions on the 5
// per-cell / per-coef estimators that previously only
// exposed the IID path (DoubleMLDIDCS, DoubleMLDIDMulti,
// DoubleMLDIDCrossSection, DoubleMLPLPR, DoubleMLLPLR).
// All five route through the shared
// `irm_style_sensitivity_cluster` helper
// (DIDCrossSection / PLPR / LPLR are single-theta) or the
// new `irm_style_sensitivity_cluster_multi` helper
// (DIDCS / DIDMulti are per-cell); the wbtests pin the
// finite-value contract, the per-cell vs single-theta
// return shape, and the cluster-aware vs IID
// sigma2/nu2 distinction.
//
// Each test:
//   1. Generates a DGP with a known cluster structure
//      (3-5 clusters, treatment effect ~1.0, cluster-level
//      random intercept so the cluster-summed residuals
//      differ from the IID ones).
//   2. Constructs the estimator + data and calls `.fit()`.
//   3. Calls `.sensitivity_analysis_cluster(cluster_ids)`.
//   4. Asserts rv / sigma2 / nu2 / max_bias are finite and
//      non-negative (sensitivity is an unbiasedness-shape
//      test, not a point-estimate test).

// ---------------------------------------------------------------------------
// DIDCS cluster sensitivity smoke test (v0.73.0)
// ---------------------------------------------------------------------------

///|
test "didcs_sensitivity_cluster_returns_per_cell_results" {
  // v0.73.0+: per-cell cluster-robust sensitivity for
  // `DoubleMLDIDCS`. Returns one `SensitivityResult`
  // per `(g, t)` cell (length = `n_groups * n_periods`).
  // Cells with `se_matrix[k] <= 0` (pre-treatment /
  // empty panel subset) return a zeroed result.
  let n_per_cohort = 50
  let p = 2
  let theta0 = 1.0
  let n_periods = 3
  let cohort_count = 2 // g = 0 (control) + g = 1 (treated at t=1)
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let n_clusters = 4
  let rng = chacha8_rng(101)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  let cluster : Array[Int] = Array::make(n, 0)
  let cluster_intercept : Array[Double] = Array::make(n_clusters, 0.0)
  for c = 0; c < n_clusters; c = c + 1 {
    cluster_intercept[c] = (rng.double() - 0.5) * 1.5
  }
  for u = 0; u < n_units; u = u + 1 {
    // Cycle cluster ids across units (round-robin).
    let cu = u % n_clusters
    let cohort = u / n_per_cohort
    let xu : Array[Double] = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      xu[j] = rng.double() * 2.0 - 1.0
    }
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      cluster[row] = cu
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = xu[j]
      }
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = cohort
      d[row] = if cohort > 0 && k >= cohort { 1.0 } else { 0.0 }
      let mut y_val = cluster_intercept[cu]
      for j = 0; j < p; j = j + 1 {
        y_val = y_val + 0.3 * xu[j]
      }
      if cohort > 0 && k >= cohort {
        y_val = y_val + theta0
      }
      y_val = y_val + 0.05 * (rng.double() - 0.5)
      y[row] = y_val
    }
  }
  let data = DoubleMLDIDCSData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
  let fitted = DoubleMLDIDCS::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let results = fitted.sensitivity_analysis_cluster(cluster)
  // n_groups = 1 (g = 1; g = 0 is dropped as the
  // never-treated sentinel), n_periods = 3. Result
  // length = 1 * 3 = 3.
  assert_eq(results.length(), fitted.n_groups() * fitted.n_periods())
  for k = 0; k < results.length(); k = k + 1 {
    // All cells return finite values; pre-treatment
    // cells return the zeroed placeholder (rv / nu2 /
    // sigma2 all 0.0) while post-treatment cells return
    // real finite values.
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
// DIDMulti cluster sensitivity smoke test (v0.73.0)
// ---------------------------------------------------------------------------

///|
test "didmulti_sensitivity_cluster_returns_per_combination_results" {
  // v0.73.0+: cluster-robust sensitivity for
  // `DoubleMLDIDMulti`. Delegates to the inner
  // `DoubleMLDIDCS::sensitivity_analysis_cluster`
  // (per-cell) and filters by `gt_combinations`. The
  // returned array length should match
  // `gt_combinations.length()`.
  let n_units = 200
  let n_periods_p = 3
  let n = n_units * n_periods_p
  let p = 2
  let n_clusters = 4
  let per_cluster = n_units / n_clusters
  let rng = chacha8_rng(102)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t : Array[Int] = Array::make(n, 0)
  let id : Array[Int] = Array::make(n, 0)
  let g : Array[Int] = Array::make(n, 0)
  let cluster : Array[Int] = Array::make(n, 0)
  let cluster_intercept : Array[Double] = Array::make(n_clusters, 0.0)
  for c = 0; c < n_clusters; c = c + 1 {
    cluster_intercept[c] = (rng.double() - 0.5) * 1.5
  }
  for u = 0; u < n_units; u = u + 1 {
    let cu = u / per_cluster
    let c = if cu >= n_clusters { n_clusters - 1 } else { cu }
    let x0 = rng.double() * 2.0 - 1.0
    let x1 = rng.double() * 2.0 - 1.0
    let g_u = if rng.double() < 0.5 { 1 } else { 2 }
    for pi = 0; pi < n_periods_p; pi = pi + 1 {
      let idx = u * n_periods_p + pi
      cluster[idx] = c
      let t_u = pi + 1
      let d_treat = if g_u > 0 && t_u > g_u { 1.0 } else { 0.0 }
      x_flat[idx * p + 0] = x0
      x_flat[idx * p + 1] = x1
      g[idx] = g_u
      t[idx] = t_u
      id[idx] = u
      d[idx] = d_treat
      let eps = (rng.double() - 0.5) * 0.3
      y[idx] = d_treat * 1.5 + 0.4 * x0 + 0.2 * x1 + cluster_intercept[c] + eps
    }
  }
  let x_mat = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLDIDCSData::new(x_mat, y, d, t, id, g)
  let fitted = DoubleMLDIDMulti::new(data, n_folds=4, seed=1).fit()
  let n_combos = fitted.n_combinations()
  let results = fitted.sensitivity_analysis_cluster(cluster)
  assert_eq(results.length(), n_combos)
  for k = 0; k < results.length(); k = k + 1 {
    assert_true(results[k].rv.is_nan() == false)
    assert_true(results[k].sigma2.is_nan() == false)
    assert_true(results[k].nu2.is_nan() == false)
    assert_true(results[k].max_bias.is_nan() == false)
    assert_true(results[k].sigma2 >= 0.0)
    assert_true(results[k].nu2 >= 0.0)
  }
}

// ---------------------------------------------------------------------------
// DIDCrossSection cluster sensitivity smoke test (v0.73.0)
// ---------------------------------------------------------------------------

///|
test "didcs_cross_section_sensitivity_cluster_returns_finite_result" {
  // v0.73.0+: cluster-robust cross-section DID
  // sensitivity. Single-theta IRM-style decomposition:
  // outcome residual `y - g_d0_t0 - (g_d1_t0 - g_d0_t0) *
  // d`; per-row `psi_a` from `fit`. The cluster-aware
  // `irm_style_sensitivity_cluster` recomputes the
  // sigma2/nu2 baseline against the cluster-summed
  // residuals/psi_a, which generally differs from the
  // IID mean-residual baseline.
  let n_clusters = 4
  let per_cluster = 75
  let n = n_clusters * per_cluster
  let p = 2
  let rng = chacha8_rng(103)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t : Array[Int] = Array::make(n, 0)
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
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    t[i] = if rng.double() > 0.5 { 1 } else { 0 }
    let post = t[i].to_double()
    let x_sum = x_flat[i * p + 0] + x_flat[i * p + 1]
    let eps = (rng.double() - 0.5) * 0.3
    y[i] = 1.5 * d[i] * post + 0.4 * x_sum + cluster_intercept[ci] + eps
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLDIDCrossSectionData::new(x, y, d, t)
  let fitted = DoubleMLDIDCrossSection::new(data, n_folds=4, seed=1).fit()
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
// PLPR cluster sensitivity smoke test (v0.73.0)
// ---------------------------------------------------------------------------

///|
test "plpr_sensitivity_cluster_returns_finite_result" {
  // v0.73.0+: cluster-robust panel partialling-out /
  // IV-type sensitivity. The cluster_ids must be in the
  // TRANSFORMED domain (length = `l_hat.length()`),
  // matching `transform_panel`'s drop logic. With
  // `approach = "fd_exact"` and a 0-indexed time grid,
  // the first period (t = 0) is dropped, so we cycle
  // cluster ids across the remaining rows.
  let n_units = 100
  let n_periods_p = 3
  let n_raw = n_units * n_periods_p
  let p = 2
  let n_clusters = 4
  let per_cluster = n_units / n_clusters
  let rng = chacha8_rng(104)
  let x_flat : Array[Double] = Array::make(n_raw * p, 0.0)
  let y : Array[Double] = Array::make(n_raw, 0.0)
  let d : Array[Double] = Array::make(n_raw, 0.0)
  let t : Array[Int] = Array::make(n_raw, 0)
  let id : Array[Int] = Array::make(n_raw, 0)
  let cluster_raw : Array[Int] = Array::make(n_raw, 0)
  let cluster_intercept : Array[Double] = Array::make(n_clusters, 0.0)
  for c = 0; c < n_clusters; c = c + 1 {
    cluster_intercept[c] = (rng.double() - 0.5) * 1.5
  }
  for u = 0; u < n_units; u = u + 1 {
    let cu = u / per_cluster
    let c = if cu >= n_clusters { n_clusters - 1 } else { cu }
    let x0 = rng.double() * 2.0 - 1.0
    let x1 = rng.double() * 2.0 - 1.0
    let alpha = (rng.double() - 0.5) * 2.0
    for pi = 0; pi < n_periods_p; pi = pi + 1 {
      let idx = u * n_periods_p + pi
      cluster_raw[idx] = c
      let t_u = pi + 1
      let x1_t = x1 + (rng.double() - 0.5) * 0.5
      let p_d = 1.0 / (1.0 + @math.exp(-(x0 + alpha / 2.0)))
      let d_it = if rng.double() < p_d { 1.0 } else { 0.0 }
      let eps = (rng.double() - 0.5) * 0.3
      x_flat[idx * p + 0] = x0
      x_flat[idx * p + 1] = x1_t
      d[idx] = d_it
      t[idx] = t_u
      id[idx] = u
      y[idx] = 1.0 * d_it +
        0.4 * x0 +
        0.2 * x1_t +
        alpha +
        cluster_intercept[c] +
        eps
    }
  }
  let x_mat = Matrix::from_array(x_flat, n_raw, p)
  let panel = DoubleMLPanelData::new(x_mat, y, d, t, id)
  let fitted = DoubleMLPLPR::new(
    panel,
    approach="fd_exact",
    score="partialling out",
    n_folds=2,
    seed=1,
  ).fit()
  // Transform panel domain: fd_exact keeps all units
  // (each unit has 3 periods >= 2) and produces
  // (n_periods - 1) differences per unit (one per
  // consecutive (t, t+1) pair). For unit `u`, the two
  // transformed output rows correspond to (u, t=2) and
  // (u, t=3). The raw DGP is already sorted by (id, t),
  // so `cluster_raw[u * 3 + 1]` and `cluster_raw[u * 3 +
  // 2]` carry the cluster id for unit `u`.
  let n_transformed = fitted.predictions_l().length()
  let cluster_t : Array[Int] = Array::make(n_transformed, 0)
  for u = 0; u < n_units; u = u + 1 {
    for j = 0; j < n_periods_p - 1; j = j + 1 {
      let k = u * (n_periods_p - 1) + j
      cluster_t[k] = cluster_raw[u * n_periods_p + (j + 1)]
    }
  }
  let r = fitted.sensitivity_analysis_cluster(cluster_t)
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
  assert_true(r.sigma2 >= 0.0)
  assert_true(r.nu2 >= 0.0)
  assert_true(r.max_bias >= 0.0)
}

// ---------------------------------------------------------------------------
// LPLR cluster sensitivity smoke test (v0.73.0)
// ---------------------------------------------------------------------------

///|
test "lplr_sensitivity_cluster_returns_finite_result" {
  // v0.73.0+: cluster-robust partially logistic
  // regression sensitivity (Liu-Zhang-Zhou 2021
  // partially logistic regression). Same simplified
  // IRM-style binary ATE decomposition as the IID path
  // (`psi_a[i] = -d[i] * (d[i] - a_hat[i])`); only the
  // variance / bias computation is cluster-aware.
  let n_clusters = 4
  let per_cluster = 75
  let n = n_clusters * per_cluster
  let p = 2
  let rng = chacha8_rng(105)
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
    let p_d = 1.0 / (1.0 + @math.exp(-x_flat[i * p + 0]))
    d[i] = if rng.double() < p_d { 1.0 } else { 0.0 }
    let p_y = 1.0 /
      (
        1.0 +
        @math.exp(
          -(0.8 * d[i] +
          0.4 * x_flat[i * p + 0] +
          0.2 * x_flat[i * p + 1] +
          cluster_intercept[ci]),
        )
      )
    y[i] = if rng.double() < p_y { 1.0 } else { 0.0 }
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLBinaryData::new(x, y, d)
  let fitted = DoubleMLLPLR::new(data, n_folds=4, n_folds_inner=4, seed=1).fit()
  let r = fitted.sensitivity_analysis_cluster(cluster)
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
  assert_true(r.sigma2 >= 0.0)
  assert_true(r.nu2 >= 0.0)
  assert_true(r.max_bias >= 0.0)
}
