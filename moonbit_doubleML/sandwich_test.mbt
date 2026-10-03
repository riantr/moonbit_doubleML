///|
// v0.79.0+: white-box tests for the sandwich-variance
// (HC0/HC1/HC2/HC3 + cluster-robust) and bias-correction
// helpers in `sandwich.mbt`. The tests cover both
// hand-computed closed-form cases (deterministic expected
// outputs) and end-to-end estimator paths
// (`DoubleMLIRM::sandwich_se` / `cluster_sandwich_se` /
// `bias_corrected_coef`).
//
// The hand-computed test inputs use a constant `psi_a` so
// the leverage `h_ii = psi_a[i] * M_inv * psi_a[i]` is
// trivially zero (or large, in the HC2 / HC3 widening case
// where one observation carries an outsize `psi_a[i]`); the
// numeric tests verify the formulas against the analytical
// formulas listed in `sandwich.mbt` "Formulas" section.

// ---------------------------------------------------------------------------
// Closed-form tests for the four HC estimators
// ---------------------------------------------------------------------------

///|
test "sandwich_variance_hc0_matches_formula" {
  // Hand-computed case:
  //   psi_a = [1, 1, 1, 1], psi = [0.5, -0.5, 0.3, -0.3],
  //   M_inv = [[4.0]], n = 4, k = 1
  //   HC0 = M_inv^2 * sum_i (psi_a[i]^2 * psi[i]^2) / n
  //       = 16 * (0.25 + 0.25 + 0.09 + 0.09) / 4
  //       = 16 * 0.68 / 4
  //       = 2.72
  let psi_a : Array[Double] = [1.0, 1.0, 1.0, 1.0]
  let psi : Array[Double] = [0.5, -0.5, 0.3, -0.3]
  let m_inv = Matrix::from_array([4.0], 1, 1)
  let v = sandwich_variance_hc0(psi_a, psi, m_inv, 4, 1)
  let expected = 2.72
  inspect((v - expected).abs() < 1.0e-12, content="true")
}

///|
test "sandwich_variance_hc1_corrects_hc0" {
  // HC1 = HC0 * n / (n - k). For n = 10, k = 1: scale = 10 / 9.
  // The constant `psi_a = 1` keeps leverage at the trivially
  // safe value `h_ii = 1 * (1 / 1) * 1 = 1`, which is at the
  // eps-clip boundary in HC2 / HC3 (we don't use them here).
  let n = 10
  let psi_a : Array[Double] = Array::make(n, 1.0)
  // psi = [1, -1, 1, -1, 1, -1, 1, -1, 1, -1] -> sum psi^2 = 10.
  let psi : Array[Double] = []
  for _ in 0..<n {
    let last = if psi.length() % 2 == 0 { 1.0 } else { -1.0 }
    psi.push(last)
  }
  let m_inv = Matrix::from_array([1.0], 1, 1)
  let v0 = sandwich_variance_hc0(psi_a, psi, m_inv, n, 1)
  let v1 = sandwich_variance_hc1(psi_a, psi, m_inv, n, 1)
  let scale = v1 / v0
  // 10/9 ~ 1.111...
  inspect((scale - 10.0 / 9.0).abs() < 1.0e-12, content="true")
  // HC1 should be > HC0 here.
  inspect(v1 > v0, content="true")
}

///|
test "sandwich_variance_hc2_widens_hc0" {
  // psi_a = [2.0, 0.5, 0.5, 0.5] (one high-leverage row at i=0)
  // M_inv = [[1.0]] -> h_ii = psi_a[i]^2 * M_inv
  //   h_00 = 4 * 1 = 4  (clipped to eps denominator)
  //   h_11 = h_22 = h_33 = 0.25 * 1 = 0.25
  // For row i=0 the HC2 denominator (1 - h_00) = (1 - 4) is
  // negative; the eps-clipping (1e-10) makes its contribution
  // enormous, so HC2 must exceed HC0.
  let psi_a : Array[Double] = [2.0, 0.5, 0.5, 0.5]
  let psi : Array[Double] = [1.0, -1.0, 1.0, -1.0]
  let m_inv = Matrix::from_array([1.0], 1, 1)
  let v0 = sandwich_variance_hc0(psi_a, psi, m_inv, 4, 1)
  let v2 = sandwich_variance_hc2(psi_a, psi, m_inv, 4, 1)
  inspect(v2 > v0, content="true")
  // Variance must stay finite on the clipped h_ii input.
  inspect(v2.is_nan() == false, content="true")
  inspect(v2.is_inf() == false, content="true")
}

///|
test "sandwich_variance_hc3_widens_hc2" {
  // Same inputs as the HC2 widening test. With h_00 clipped,
  // HC3 divides by (1 - h_ii)^2 instead of (1 - h_ii), so
  // HC3 > HC2 (the same row gets divided by an even smaller
  // epsilon, blowing up the same term further).
  let psi_a : Array[Double] = [2.0, 0.5, 0.5, 0.5]
  let psi : Array[Double] = [1.0, -1.0, 1.0, -1.0]
  let m_inv = Matrix::from_array([1.0], 1, 1)
  let v2 = sandwich_variance_hc2(psi_a, psi, m_inv, 4, 1)
  let v3 = sandwich_variance_hc3(psi_a, psi, m_inv, 4, 1)
  inspect(v3 > v2, content="true")
  inspect(v3.is_nan() == false, content="true")
  inspect(v3.is_inf() == false, content="true")
}

// ---------------------------------------------------------------------------
// Cluster-robust sandwich: independent clusters
// ---------------------------------------------------------------------------

///|
test "cluster_sandwich_variance_independent_clusters" {
  // 2 clusters of 5 obs each; psi_a = 1 everywhere; psi =
  // small-noise observations, identical within each cluster
  // (so the cluster-level random effect is visible).
  //   Cluster 0: psi = [+a, +a, +a, +a, +a]
  //   Cluster 1: psi = [-b, -b, -b, -b, -b]
  // Per-cluster sums:
  //   S_0 = sum_{i in 0} psi = 5 * a
  //   S_1 = sum_{i in 1} psi = -5 * b
  //   n_0 = n_1 = 5, n = 10.
  // Jackknife correction n_c / (n_c - 1) = 5/4.
  // var = M_inv^2 * (S_0^2 * 5/4 + S_1^2 * 5/4) / 10
  //     = M_inv^2 * (5/4) * (25 a^2 + 25 b^2) / 10
  //     = M_inv^2 * (5/4) * 5/2 * (a^2 + b^2)
  //     = M_inv^2 * (25/8) * (a^2 + b^2)
  let a = 0.3
  let b = 0.4
  let psi_a : Array[Double] = Array::make(10, 1.0)
  let psi : Array[Double] = [a, a, a, a, a, -b, -b, -b, -b, -b]
  let cluster_ids : Array[Int] = [0, 0, 0, 0, 0, 1, 1, 1, 1, 1]
  let m_inv = Matrix::from_array([1.0], 1, 1)
  let v = cluster_sandwich_variance(psi_a, psi, m_inv, cluster_ids, 1)
  let expected = 25.0 / 8.0 * (a * a + b * b)
  inspect((v - expected).abs() < 1.0e-12, content="true")
  // And finite (no overflow / NaN from the jackknife).
  inspect(v.is_nan() == false, content="true")
}

// ---------------------------------------------------------------------------
// bias_corrected_theta
// ---------------------------------------------------------------------------

///|
test "bias_corrected_theta_sum" {
  // theta = 0.5, biases = [0.1, 0.2] -> 0.5 + (0.3 / 2) = 0.65.
  let biases : Array[Double] = [0.1, 0.2]
  let t = bias_corrected_theta(0.5, biases)
  inspect((t - 0.65).abs() < 1.0e-12, content="true")
}

// ---------------------------------------------------------------------------
// End-to-end smoke tests on DoubleMLIRM
// ---------------------------------------------------------------------------

///|
test "irm_sandwich_se_smoke" {
  // Build a synthetic DGP, fit IRM, call `sandwich_se(HC0)`
  // and verify the returned SE is finite and > 0.
  let n = 200
  let p = 3
  let x_mat = Matrix::zeros(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let rng = chacha8_rng(7911)
  // Draw normals via Box-Muller into the feature matrix.
  let mut drawn = 0
  while drawn < n * p {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let theta = 2.0 * 3.141592653589793 * u2
    let z1 = r * @math.cos(theta)
    let z2 = r * @math.sin(theta)
    let row = drawn / p
    if drawn + 1 < n * p {
      x_mat.set(row, drawn % p, z1)
      drawn = drawn + 1
      x_mat.set(drawn / p, drawn % p, z2)
      drawn = drawn + 1
    } else {
      x_mat.set(row, drawn % p, z1)
      drawn = drawn + 1
    }
  }
  for i = 0; i < n; i = i + 1 {
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    let mut s = 0.0
    for j = 0; j < p; j = j + 1 {
      s = s + x_mat.get(i, j)
    }
    y[i] = s + 0.5 * d[i]
  }
  let data = DoubleMLData::new(x_mat, y, d)
  let fitted = DoubleMLIRM::new(data, n_folds=2, seed=0).fit()
  let se_hc0 = fitted.sandwich_se(SandwichKind::hc0())
  inspect(se_hc0.is_nan() == false, content="true")
  inspect(se_hc0.is_inf() == false, content="true")
  inspect(se_hc0 > 0.0, content="true")
  // HC1 (n / (n - k) inflation) should widen HC0.
  let se_hc1 = fitted.sandwich_se(SandwichKind::hc1())
  inspect(se_hc1 > se_hc0, content="true")
}

///|
test "irm_cluster_sandwich_se_smoke" {
  // Same DGP, with synthetic cluster ids (each obs in its
  // own cluster of size 1 -> no jackknife correction, raw
  // per-cluster variance). The returned SE must be finite
  // and >= 0.
  let n = 100
  let p = 2
  let x_mat = Matrix::zeros(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let cluster_ids : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    cluster_ids[i] = i
    x_mat.set(i, 0, i.to_double() * 0.1)
    x_mat.set(i, 1, i.to_double() * 0.05)
    d[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
    y[i] = x_mat.get(i, 0) + x_mat.get(i, 1) + 0.5 * d[i]
  }
  let data = DoubleMLData::new(x_mat, y, d, cluster_vars=cluster_ids)
  let fitted = DoubleMLIRM::new(data, n_folds=2, seed=0).fit()
  let se = fitted.cluster_sandwich_se(cluster_ids)
  inspect(se.is_nan() == false, content="true")
  inspect(se.is_inf() == false, content="true")
  inspect(se >= 0.0, content="true")
}

///|
test "irm_bias_corrected_coef_smoke" {
  // Synthetic DGP, fit IRM, call `bias_corrected_coef`,
  // verify the result is finite.
  let n = 150
  let p = 2
  let x_mat = Matrix::zeros(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    x_mat.set(i, 0, i.to_double() * 0.1)
    x_mat.set(i, 1, i.to_double() * 0.05)
    d[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
    y[i] = x_mat.get(i, 0) + x_mat.get(i, 1) + 0.5 * d[i]
  }
  let data = DoubleMLData::new(x_mat, y, d)
  let fitted = DoubleMLIRM::new(data, n_folds=2, seed=0).fit()
  let bc = fitted.bias_corrected_coef()
  inspect(bc.is_nan() == false, content="true")
  inspect(bc.is_inf() == false, content="true")
}
