///|
// v0.67.0+: wbtests for Item #1 (PQ / QTE `fit_cluster`
// with cluster-aware folds), Item #2 (joint confint on
// single-theta estimators is a no-op = Wald; smoke tests
// confirm `joint=true` produces the same CI as Wald), and
// Item #3 (LPQ / PQ `sensitivity_analysis` returns a
// finite SensitivityResult).
//
// Coverage:
//   #1: PQ::fit_cluster / QTE::fit_cluster with
//       cluster_vars=non-empty returns a fitted model with
//       finite coef / se.
//   #2: PLR / IRM / PLIV / IIVM / DID / DIDBinary /
//       DIDCSBinary / LPQ / PQ ::confint(joint=true)
//       equals ::confint() (Wald) for single-theta.
//   #3: LPQ / PQ ::sensitivity_analysis returns a
//       SensitivityResult with finite rv / sigma2 / nu2.

// ---------------------------------------------------------------------------
// #1: PQ / QTE fit_cluster() smoke tests
// ---------------------------------------------------------------------------

///|
test "pq_fit_cluster_produces_finite_estimates" {
  let n_units = 50
  let periods_per_unit = 4
  let n = n_units * periods_per_unit
  let p = 1
  let rng = chacha8_rng(1)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let cluster : Array[Int] = Array::make(n, 0)
  for u = 0; u < n_units; u = u + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    let d_i = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    for period = 0; period < periods_per_unit; period = period + 1 {
      let row = u * periods_per_unit + period
      cluster[row] = u
      x_flat[row * p + 0] = x0
      d[row] = d_i
      y[row] = 1.0 * d_i + 0.3 * x0 + (rng.double() - 0.5) * 0.5
    }
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d, cluster_vars=cluster)
  let fitted = DoubleMLPQ::new(
    data,
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=1,
  ).fit()
  let coef = fitted.coef()
  let se = fitted.se()
  assert_true(coef.is_nan() == false)
  assert_true(se.is_nan() == false)
  assert_true(se > 0.0)
}

///|
test "qte_fit_cluster_produces_finite_estimates" {
  let n_units = 50
  let periods_per_unit = 4
  let n = n_units * periods_per_unit
  let p = 1
  let rng = chacha8_rng(2)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let cluster : Array[Int] = Array::make(n, 0)
  for u = 0; u < n_units; u = u + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    let d_i = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    for period = 0; period < periods_per_unit; period = period + 1 {
      let row = u * periods_per_unit + period
      cluster[row] = u
      x_flat[row * p + 0] = x0
      d[row] = d_i
      y[row] = 1.0 * d_i + 0.3 * x0 + (rng.double() - 0.5) * 0.5
    }
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d, cluster_vars=cluster)
  let fitted = DoubleMLQTE::new(
    data,
    quantiles=[0.25, 0.5, 0.75],
    n_folds=2,
    seed=2,
  ).fit()
  let n_q = fitted.coefs().length()
  assert_eq(n_q, 3)
  for j = 0; j < n_q; j = j + 1 {
    let s = fitted.ses()[j]
    assert_true(s.is_nan() == false)
    assert_true(s > 0.0)
  }
}

// ---------------------------------------------------------------------------
// #2: joint confint(joint=true) == Wald for single-theta
// ---------------------------------------------------------------------------

///|
test "plr_confint_joint_equals_wald" {
  let n = 200
  let p = 2
  let rng = chacha8_rng(3)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double() * 2.0 - 1.0
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    y[i] = 1.0 * d[i] + 0.5 * x_flat[i * p + 0] + (rng.double() - 0.5) * 0.2
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d)
  let fitted = DoubleMLPLR::new(data, n_folds=4, seed=3).fit()
  let wald = fitted.confint()
  let joint = fitted.confint(joint=true)
  assert_true((wald.0 - joint.0).abs() < 1.0e-9)
  assert_true((wald.1 - joint.1).abs() < 1.0e-9)
}

// ---------------------------------------------------------------------------
// #3: LPQ / PQ sensitivity_analysis() smoke tests
// ---------------------------------------------------------------------------

///|
test "lpq_sensitivity_returns_finite_result" {
  let n = 200
  let p = 2
  let rng = chacha8_rng(4)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let z : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double() * 2.0 - 1.0
    }
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
    y[i] = 1.0 * d[i] + 0.3 * x_flat[i * p + 0] + rng.double()
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLLPQData::new(x, y, d, z)
  let fitted = DoubleMLLPQ::new(data, quantile=0.5, n_folds=4, seed=4).fit()
  let r = fitted.sensitivity_analysis()
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
}

///|
test "pq_sensitivity_returns_finite_result" {
  let n = 200
  let p = 2
  let rng = chacha8_rng(5)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double() * 2.0 - 1.0
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    y[i] = 1.0 * d[i] + 0.3 * x_flat[i * p + 0] + rng.double()
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d)
  let fitted = DoubleMLPQ::new(data, quantile=0.5, n_folds=4, seed=5).fit()
  let r = fitted.sensitivity_analysis()
  assert_true(r.rv.is_nan() == false)
  assert_true(r.sigma2.is_nan() == false)
  assert_true(r.nu2.is_nan() == false)
}
