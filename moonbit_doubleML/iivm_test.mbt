///|
test "iivm_recovers_true_late_on_simple_dgp" {
  // Simple IIVM DGP:
  //   z ~ Bernoulli(0.5)
  //   v ~ N(0, 1) (independent)
  //   d = 1{alpha * z + v > 0}
  //   y = theta * d + x @ 1 + noise
  // The true LATE equals theta (when alpha > 0 so there are compliers).
  let n = 1000
  let p = 5
  let theta0 = 1.0
  let alpha = 0.5
  let rng = chacha8_rng(1111)
  // need normals: x is n*p; v is n; y noise is n. total = n*p + 2*n.
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
  let mut noise_idx = n * p
  let v : Array[Double] = Array::make(n, 0.0)
  let eps : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    v[i] = pool[noise_idx]
    noise_idx = noise_idx + 1
  }
  for i = 0; i < n; i = i + 1 {
    eps[i] = pool[noise_idx]
    noise_idx = noise_idx + 1
  }
  let x = Matrix::from_array(x_flat, n, p)
  let z : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    // z is binary from a uniform draw
    let u = rng.double()
    z[i] = if u > 0.5 { 1.0 } else { 0.0 }
    // d = 1{alpha * z + v > 0}
    let score = alpha * z[i] + v[i]
    d[i] = if score > 0.0 { 1.0 } else { 0.0 }
    // y = theta * d + x @ 1 + eps
    let mut s = eps[i]
    for j = 0; j < p; j = j + 1 {
      s = s + x.get(i, j)
    }
    y[i] = theta0 * d[i] + s
  }
  let data = DoubleMLIIVMData::new(x, y, d, z)
  let fitted = DoubleMLIIVM::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let theta = fitted.coef()
  let se = fitted.se()
  let (lo, hi) = fitted.confint()
  // IIVM has higher variance than the other models (5 nuisances
  // vs 2-3); allow a wider band on the point estimate.
  inspect((theta - theta0).abs() < 0.5, content="true")
  // 95% CI should contain the truth
  inspect(lo < theta0, content="true")
  inspect(hi > theta0, content="true")
  // Anti-sign-flip guard: theta must be positive (true LATE = 1.0).
  inspect(theta > 0.0, content="true")
  inspect(se > 0.0, content="true")
  // SE must be within a sane order of magnitude for the n = 1000 DGP.
  inspect(se < 1.0, content="true")
}

///|
test "iivm_fitted_has_predictions" {
  let n = 200
  let p = 3
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let z : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    z[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
    d[i] = if (i + 1) % 3 == 0 { 1.0 } else { 0.0 }
    for j = 0; j < p; j = j + 1 {
      x.set(i, j, 0.1 * (i + 1).to_double() * (j + 1).to_double())
      y[i] = y[i] + x.get(i, j)
    }
    y[i] = y[i] + d[i]
  }
  let data = DoubleMLIIVMData::new(x, y, d, z)
  let fitted = DoubleMLIIVM::new(data, n_folds=2, seed=0).fit()
  inspect(fitted.predictions_g0().length(), content="200")
  inspect(fitted.predictions_g1().length(), content="200")
  inspect(fitted.predictions_m().length(), content="200")
  inspect(fitted.predictions_r0().length(), content="200")
  inspect(fitted.predictions_r1().length(), content="200")
}

///|
test "iivm_propensity_clipped_to_eps" {
  let n = 100
  let p = 2
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let z : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    z[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
  }
  let data = DoubleMLIIVMData::new(x, y, d, z)
  let fitted = DoubleMLIIVM::new(data, n_folds=2, seed=0, propensity_clip=0.1).fit()
  let m = fitted.predictions_m()
  for i = 0; i < n; i = i + 1 {
    inspect(m[i] >= 0.1, content="true")
    inspect(m[i] <= 0.9, content="true")
  }
}

///|
test "filter_by_value" {
  let idx = [0, 1, 2, 3, 4, 5]
  let cond = [1.0, 0.0, 1.0, 1.0, 0.0, 1.0]
  let out0 = filter_by_value(idx, cond, 0.0)
  inspect(out0.length(), content="2")
  inspect(out0[0], content="1")
  inspect(out0[1], content="4")
  let out1 = filter_by_value(idx, cond, 1.0)
  inspect(out1.length(), content="4")
  inspect(out1[0], content="0")
  inspect(out1[1], content="2")
  inspect(out1[2], content="3")
  inspect(out1[3], content="5")
}
