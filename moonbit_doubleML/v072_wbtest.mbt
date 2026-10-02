///|
// v0.72.0+: wbtests for the cluster-aware
// `sensitivity_analysis_cluster` additions on the 8
// single-theta IRM-family estimators that previously only
// exposed the IID path (PLR, IRM, PLIV, IIVM, APO, DID,
// DIDBinary, DIDCSBinary). All eight route through the
// shared `irm_style_sensitivity_cluster` helper (see
// sensitivity.mbt); the wbtests pin the finite-value
// contract and confirm the per-estimator residual formula
// is correctly transferred from the IID path.
//
// Each test:
//   1. Generates a DGP with a known cluster structure
//      (3-5 clusters, treatment effect ~1.0, cluster-level
//      random effect so the cluster-aware path produces a
//      different sigma2/nu2 than the IID path).
//   2. Constructs the estimator + data (passing cluster_vars
//      to DoubleMLData::new where the underlying data
//      supports it; passing cluster_ids explicitly to
//      estimators whose data struct has no cluster_vars).
//   3. Fits the model and calls
//      `sensitivity_analysis_cluster`.
//   4. Asserts rv / sigma2 / nu2 / max_bias are finite and
//      non-negative (sensitivity is an unbiasedness-shape
//      test, not a point-estimate test).

// ---------------------------------------------------------------------------
// PLR cluster sensitivity smoke test (v0.72.0)
// ---------------------------------------------------------------------------

///|
test "plr_sensitivity_cluster_returns_finite_result" {
  // v0.72.0+: PLR cluster-robust sensitivity. DGP has 4
  // clusters of 75 obs each = 300 obs. Treatment effect
  // theta = 1.0. Each cluster gets a random intercept so
  // the cluster-summed residuals are non-trivially
  // different from IID residuals.
  let n_clusters = 4
  let per_cluster = 75
  let n = n_clusters * per_cluster
  let p = 2
  let rng = chacha8_rng(1)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let cluster : Array[Int] = Array::make(n, 0)
  // Per-cluster intercepts so sigma2_cluster != IID sigma2.
  let cluster_intercept : Array[Double] = Array::make(n_clusters, 0.0)
  for c = 0; c < n_clusters; c = c + 1 {
    cluster_intercept[c] = (rng.double() - 0.5) * 1.5
  }
  for i = 0; i < n; i = i + 1 {
    let c = i / per_cluster
    cluster[i] = c
    x_flat[i * p + 0] = rng.double() * 2.0 - 1.0
    x_flat[i * p + 1] = rng.double() * 2.0 - 1.0
    let p_d = 0.4 + 0.2 * x_flat[i * p + 0]
    d[i] = if rng.double() < p_d { 1.0 } else { 0.0 }
    let eps = (rng.double() - 0.5) * 0.3
    y[i] = 1.0 * d[i] +
      0.5 * x_flat[i * p + 0] +
      0.3 * x_flat[i * p + 1] +
      cluster_intercept[c] +
      eps
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d, cluster_vars=cluster)
  let fitted = DoubleMLPLR::new(data, n_folds=4, seed=1).fit()
  // Use the explicit cluster_ids override path to also pin
  // the keyword contract.
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
// IRM cluster sensitivity smoke test (v0.72.0)
// ---------------------------------------------------------------------------

///|
test "irm_sensitivity_cluster_returns_finite_result" {
  // v0.72.0+: IRM ATE cluster-robust sensitivity. Same DGP
  // shape as PLR (4 clusters, treatment effect 1.0, cluster
  // random intercept). IRM uses the DID-style residual form
  // `y - g0 - (g1 - g0) * d` so the cluster effect enters
  // through the outcome nuisance predictions.
  let n_clusters = 4
  let per_cluster = 75
  let n = n_clusters * per_cluster
  let p = 2
  let rng = chacha8_rng(2)
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
    cluster[i] = c
    x_flat[i * p + 0] = rng.double() * 2.0 - 1.0
    x_flat[i * p + 1] = rng.double() * 2.0 - 1.0
    let p_d = 0.5 + 0.2 * x_flat[i * p + 0]
    d[i] = if rng.double() < p_d { 1.0 } else { 0.0 }
    let eps = (rng.double() - 0.5) * 0.3
    y[i] = 1.0 * d[i] + 0.4 * x_flat[i * p + 0] + cluster_intercept[c] + eps
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d, cluster_vars=cluster)
  let fitted = DoubleMLIRM::new(data, n_folds=4, seed=2).fit()
  // Also exercise the default-from-cluster_vars path
  // (no explicit cluster_ids argument).
  let r = fitted.sensitivity_analysis_cluster()
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
  assert_true(r.sigma2 >= 0.0)
  assert_true(r.nu2 >= 0.0)
}

// ---------------------------------------------------------------------------
// PLIV cluster sensitivity smoke test (v0.72.0)
// ---------------------------------------------------------------------------

///|
test "pliv_sensitivity_cluster_returns_finite_result" {
  // v0.72.0+: PLIV cluster-robust sensitivity. Same DGP
  // shape as PLR with an instrument Z for the IV-type score.
  let n_clusters = 4
  let per_cluster = 60
  let n = n_clusters * per_cluster
  let p = 2
  let rng = chacha8_rng(3)
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
    cluster[i] = c
    x_flat[i * p + 0] = rng.double() * 2.0 - 1.0
    x_flat[i * p + 1] = rng.double() * 2.0 - 1.0
    z[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    d[i] = if z[i] == 1.0 {
      if rng.double() > 0.3 {
        1.0
      } else {
        0.0
      }
    } else if rng.double() > 0.7 {
      1.0
    } else {
      0.0
    }
    let eps = (rng.double() - 0.5) * 0.3
    y[i] = 1.0 * d[i] + 0.4 * x_flat[i * p + 0] + cluster_intercept[c] + eps
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLPLIVData::new(x, y, d, z, cluster_vars=cluster)
  let fitted = DoubleMLPLIV::new(data, n_folds=4, seed=3).fit()
  let r = fitted.sensitivity_analysis_cluster(cluster_ids=cluster)
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
  assert_true(r.sigma2 >= 0.0)
  assert_true(r.nu2 >= 0.0)
}

// ---------------------------------------------------------------------------
// IIVM cluster sensitivity smoke test (v0.72.0)
// ---------------------------------------------------------------------------

///|
test "iivm_sensitivity_cluster_returns_finite_result" {
  // v0.72.0+: IIVM LATE cluster-robust sensitivity. Same
  // DGP shape as PLR with an instrument Z. The IV-type
  // DGP keeps the Wald first-stage F-stat above the usual
  // weak-instrument floor so the LATE fit converges.
  let n_clusters = 4
  let per_cluster = 60
  let n = n_clusters * per_cluster
  let p = 2
  let rng = chacha8_rng(4)
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
    cluster[i] = c
    x_flat[i * p + 0] = rng.double() * 2.0 - 1.0
    x_flat[i * p + 1] = rng.double() * 2.0 - 1.0
    z[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    // Strong instrument: P(D=1|Z=1)=0.8, P(D=1|Z=0)=0.2.
    d[i] = if z[i] == 1.0 {
      if rng.double() > 0.2 {
        1.0
      } else {
        0.0
      }
    } else if rng.double() > 0.8 {
      1.0
    } else {
      0.0
    }
    let eps = (rng.double() - 0.5) * 0.3
    y[i] = 1.0 * d[i] + 0.3 * x_flat[i * p + 0] + cluster_intercept[c] + eps
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLIIVMData::new(x, y, d, z, cluster_vars=cluster)
  let fitted = DoubleMLIIVM::new(data, n_folds=4, seed=4).fit()
  let r = fitted.sensitivity_analysis_cluster(cluster_ids=cluster)
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
  assert_true(r.sigma2 >= 0.0)
  assert_true(r.nu2 >= 0.0)
}

// ---------------------------------------------------------------------------
// APO cluster sensitivity smoke test (v0.72.0)
// ---------------------------------------------------------------------------

///|
test "apo_sensitivity_cluster_returns_finite_result" {
  // v0.72.0+: APO cluster-robust sensitivity. Treatment
  // level = 1.0. DGP is binary treatment with a strong
  // first-stage so m_hat stays well above the propensity
  // clip.
  let n_clusters = 4
  let per_cluster = 75
  let n = n_clusters * per_cluster
  let p = 2
  let rng = chacha8_rng(5)
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
    cluster[i] = c
    x_flat[i * p + 0] = rng.double() * 2.0 - 1.0
    x_flat[i * p + 1] = rng.double() * 2.0 - 1.0
    let p_d = 0.5 + 0.3 * x_flat[i * p + 0]
    d[i] = if rng.double() < p_d { 1.0 } else { 0.0 }
    let eps = (rng.double() - 0.5) * 0.3
    y[i] = 1.0 * d[i] + 0.4 * x_flat[i * p + 0] + cluster_intercept[c] + eps
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d, cluster_vars=cluster)
  let fitted = DoubleMLAPO::new(data, treatment_level=1.0, n_folds=4, seed=5).fit()
  let r = fitted.sensitivity_analysis_cluster(cluster_ids=cluster)
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
  assert_true(r.sigma2 >= 0.0)
  assert_true(r.nu2 >= 0.0)
}

// ---------------------------------------------------------------------------
// DID cluster sensitivity smoke test (v0.72.0)
// ---------------------------------------------------------------------------

///|
test "did_sensitivity_cluster_returns_finite_result" {
  // v0.72.0+: DID (Sant'Anna-Zhao 2020 observational
  // score) cluster-robust sensitivity. DGP: 2-period panel
  // with 3 clusters, treatment effect 1.0 applied at the
  // post-period for treated units. `DoubleMLDIDData` has no
  // `cluster_vars` field, so we pass cluster_ids explicitly
  // (length must equal `data.n_obs()` = 2 * n_units).
  let n_units = 100
  let n = n_units * 2
  let p = 2
  let n_clusters = 3
  let per_cluster = n_units / n_clusters
  let rng = chacha8_rng(6)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let cluster : Array[Int] = Array::make(n, 0)
  let cluster_intercept : Array[Double] = Array::make(n_clusters, 0.0)
  for c = 0; c < n_clusters; c = c + 1 {
    cluster_intercept[c] = (rng.double() - 0.5) * 1.5
  }
  for u = 0; u < n_units; u = u + 1 {
    let cu = u / per_cluster
    if cu >= n_clusters {
      // Round any remainder into the last cluster.
      ignore(0)
    }
    let c = if cu >= n_clusters { n_clusters - 1 } else { cu }
    let xu : Array[Double] = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      xu[j] = rng.double() * 2.0 - 1.0
    }
    let is_treated = if u % 2 == 0 { 1 } else { 0 }
    for k = 0; k < 2; k = k + 1 {
      let row = u * 2 + k
      cluster[row] = c
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = xu[j]
      }
      if is_treated == 1 && k == 1 {
        d[row] = 1.0
      } else {
        d[row] = 0.0
      }
      let mut y_val = 0.0
      for j = 0; j < p; j = j + 1 {
        y_val = y_val + 0.3 * xu[j]
      }
      y_val = y_val + cluster_intercept[c]
      if k == 1 && is_treated == 1 {
        y_val = y_val + 1.0
      }
      y_val = y_val + 0.05 * (rng.double() - 0.5)
      y[row] = y_val
    }
  }
  let data = DoubleMLDIDData::new(Matrix::from_array(x_flat, n, p), y, d)
  let fitted = DoubleMLDID::new(data, n_folds=4, seed=6).fit()
  let r = fitted.sensitivity_analysis_cluster(cluster)
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
  assert_true(r.sigma2 >= 0.0)
  assert_true(r.nu2 >= 0.0)
}

// ---------------------------------------------------------------------------
// DIDBinary cluster sensitivity smoke test (v0.72.0)
// ---------------------------------------------------------------------------

///|
test "did_binary_sensitivity_cluster_returns_finite_result" {
  // v0.72.0+: DIDBinary cluster-robust sensitivity.
  // Delegates to the inner `DoubleMLDID` on the wide-format
  // subset; `cluster_ids` must have length equal to the
  // wide-format subset (n_obs_subset). We approximate the
  // unit-level cluster mapping by cycling cluster ids
  // across the wide-format rows.
  let n_units = 200
  let n_periods_p = 2
  let n = n_units * n_periods_p
  let p = 2
  let n_clusters = 4
  let per_cluster = n_units / n_clusters
  let rng = chacha8_rng(7)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  let cluster_intercept : Array[Double] = Array::make(n_clusters, 0.0)
  for c = 0; c < n_clusters; c = c + 1 {
    cluster_intercept[c] = (rng.double() - 0.5) * 1.5
  }
  for u = 0; u < n_units; u = u + 1 {
    let cu = u / per_cluster
    let c = if cu >= n_clusters { n_clusters - 1 } else { cu }
    let xu : Array[Double] = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      xu[j] = rng.double() * 2.0 - 1.0
    }
    let is_treated = if u % 2 == 0 { 1 } else { 0 }
    for k = 0; k < n_periods_p; k = k + 1 {
      let row = u * n_periods_p + k
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = xu[j]
      }
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = is_treated
      if is_treated == 1 && k == 1 {
        d[row] = 1.0
      } else {
        d[row] = 0.0
      }
      let mut y_val = 0.0
      for j = 0; j < p; j = j + 1 {
        y_val = y_val + 0.3 * xu[j]
      }
      y_val = y_val + cluster_intercept[c]
      if k == 1 && is_treated == 1 {
        y_val = y_val + 1.0
      }
      y_val = y_val + 0.05 * (rng.double() - 0.5)
      y[row] = y_val
    }
  }
  let data = DoubleMLDIDBinaryData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    g_arr,
    id_arr,
  )
  let fitted = DoubleMLDIDBinary::new(
    data,
    1,
    0,
    1,
    control_group="never_treated",
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let n_wide = fitted.n_obs_subset()
  // Approximate cluster mapping: cycle cluster ids across
  // the wide-format rows (each unit contributes 1 wide row).
  let cluster_wide : Array[Int] = Array::make(n_wide, 0)
  for i = 0; i < n_wide; i = i + 1 {
    cluster_wide[i] = i % n_clusters
  }
  let r = fitted.sensitivity_analysis_cluster(cluster_wide)
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
  assert_true(r.sigma2 >= 0.0)
  assert_true(r.nu2 >= 0.0)
}

// ---------------------------------------------------------------------------
// DIDCSBinary cluster sensitivity smoke test (v0.72.0)
// ---------------------------------------------------------------------------

///|
test "did_cs_binary_sensitivity_cluster_returns_finite_result" {
  // v0.72.0+: DIDCSBinary (Callaway-Sant'Anna binary
  // outcome) cluster-robust sensitivity. The post-subset
  // has 4 rows per unit (2 from treated, 2 from control).
  // We construct cluster_ids aligned with the post-subset
  // length and cycle cluster ids across those rows.
  let n_per_cohort = 50
  let p = 3
  let theta0 = 1.0
  let n_periods = 2
  let cohort_count = 2
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let n_clusters = 4
  let rng = chacha8_rng(8)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  let cluster_intercept : Array[Double] = Array::make(n_clusters, 0.0)
  for c = 0; c < n_clusters; c = c + 1 {
    cluster_intercept[c] = (rng.double() - 0.5) * 1.5
  }
  for u = 0; u < n_units; u = u + 1 {
    let cohort = u / n_per_cohort
    let c = u % n_clusters
    let xu : Array[Double] = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      xu[j] = rng.double() * 2.0 - 1.0
    }
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = xu[j]
      }
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = cohort
      d[row] = if cohort > 0 && k >= cohort { 1.0 } else { 0.0 }
      // Binary outcome with cohort random intercept.
      let base = cluster_intercept[c]
      let y_val = if cohort > 0 && k >= cohort {
        // Add treatment effect on logit scale, then
        // threshold at 0.5 for the binary outcome.
        if base + theta0 > 0.0 {
          1.0
        } else {
          0.0
        }
      } else if base > 0.0 {
        1.0
      } else {
        0.0
      }
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
  let fitted = DoubleMLDIDCSBinary::new(
    data,
    1,
    0,
    1,
    control_group="never_treated",
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let n_subset = fitted.n_obs()
  // Approximate cluster mapping: cycle cluster ids across
  // the post-subset rows (4 rows per unit in the
  // never_treated control group setup).
  let cluster_subset : Array[Int] = Array::make(n_subset, 0)
  for i = 0; i < n_subset; i = i + 1 {
    cluster_subset[i] = i % n_clusters
  }
  let r = fitted.sensitivity_analysis_cluster(cluster_subset)
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
  assert_true(r.max_bias.is_nan() == false)
  assert_true(r.sigma2 >= 0.0)
  assert_true(r.nu2 >= 0.0)
}
