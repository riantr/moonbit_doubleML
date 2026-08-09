///|
test "pliv_recovers_true_theta_on_simple_dgp" {
  // DGP: z = Pi @ x + xi
  //      d = x @ gamma + z @ delta + u
  //      y = alpha * d + x @ beta + eps
  // with alpha = 1.0, n = 500, p = 5.
  let n = 500
  let p = 5
  let alpha0 = 1.0
  let bytes = seed_to_bytes(1111)
  let rng = @random.Rand::chacha8(seed=Bytes::from_array(bytes))
  // Pool of normals: n*p for x, n for (eps, u, xi)  + 1 more noise var
  // generate via Box-Muller: need (n*p + 3*n + 1) normals = 500*5 + 1500 + 1 = 4001
  let pool : Array[Double] = []
  while pool.length() < n * p + 3 * n {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let theta = 2.0 * 3.141592653589793 * u2
    pool.push(r * @math.cos(theta))
    pool.push(r * @math.sin(theta))
  }
  // Slice the pool: x uses n*p normals; the rest goes to noise/eps/u/xi
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  for i = 0; i < n * p; i = i + 1 {
    x_flat[i] = pool[i]
  }
  // eps, u, xi: each is n normals
  // pool is 2x oversupplied by Box-Muller; pick 3n entries sequentially
  // (Box-Muller produces pairs of independent normals, so any 3n
  // entries from the front are valid i.i.d. normals).
  let mut noise_idx = n * p
  let eps : Array[Double] = Array::make(n, 0.0)
  let u : Array[Double] = Array::make(n, 0.0)
  let xi : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    eps[i] = pool[noise_idx]
    noise_idx = noise_idx + 1
  }
  for i = 0; i < n; i = i + 1 {
    u[i] = pool[noise_idx]
    noise_idx = noise_idx + 1
  }
  for i = 0; i < n; i = i + 1 {
    xi[i] = pool[noise_idx]
    noise_idx = noise_idx + 1
  }
  // Build x as a matrix
  let x = Matrix::from_array(x_flat, n, p)
  // Use the *first column* of x to drive the instrument (z = x[:,0] + xi)
  // This is a single-instrument version of Pi = (1, 0, ..., 0).
  let z : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    // z = x_0 + xi
    z[i] = x.get(i, 0) + xi[i]
    // d = 0.5 * x_0 + 0.5 * z + u (so z is a relevant instrument for d)
    let mut d_part = 0.5 * x.get(i, 0) + 0.5 * z[i] + u[i]
    // add small contribution from other x columns
    for j = 1; j < p; j = j + 1 {
      d_part = d_part + 0.1 * x.get(i, j)
    }
    d[i] = d_part
    // y = alpha * d + x @ 1 + eps
    let mut y_part = eps[i]
    for j = 0; j < p; j = j + 1 {
      y_part = y_part + x.get(i, j)
    }
    y[i] = alpha0 * d[i] + y_part
  }
  let data = DoubleMLPLIVData::new(x, y, d, z)
  let fitted = DoubleMLPLIV::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let theta = fitted.coef()
  let se = fitted.se()
  let (lo, hi) = fitted.confint()
  // The estimator should be within +/- 0.5 of the truth and the CI
  // should contain 1.0.
  inspect((theta - alpha0).abs() < 0.5, content="true")
  inspect(lo < alpha0, content="true")
  inspect(hi > alpha0, content="true")
  // Anti-sign-flip guard: theta must be positive (true alpha = 1.0).
  inspect(theta > 0.0, content="true")
  inspect(se > 0.0, content="true")
  // SE must be within a sane order of magnitude for the n = 500 DGP.
  inspect(se < 1.0, content="true")
}

///|
test "pliv_fitted_has_predictions" {
  let n = 200
  let p = 3
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let z : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x.set(i, j, 0.1 * (i + 1).to_double() * (j + 1).to_double())
      y[i] = y[i] + x.get(i, j)
    }
    z[i] = x.get(i, 0)
    d[i] = 0.5 * z[i] + 0.5 * x.get(i, 1) + 0.1 * (i + 1).to_double()
    if i % 2 == 0 {
      d[i] = d[i] + 1.0
      y[i] = y[i] + 1.0
    }
  }
  let data = DoubleMLPLIVData::new(x, y, d, z)
  let fitted = DoubleMLPLIV::new(data, n_folds=2, seed=0).fit()
  inspect(fitted.predictions_l().length(), content="200")
  inspect(fitted.predictions_r().length(), content="200")
  inspect(fitted.predictions_m().length(), content="200")
}

///|
test "pliv_recovers_theta_with_strong_iv" {
  // DGP: z is a strong instrument for d (z -> d through a causal link).
  // The estimator should still recover alpha in a finite sample.
  let n = 200
  let p = 3
  let alpha0 = 1.0
  // use chacha8-seeded RNG for reproducibility
  let bytes = seed_to_bytes(2222)
  let rng = @random.Rand::chacha8(seed=Bytes::from_array(bytes))
  // generate 3n uniforms, transform to normals via Box-Muller pairs
  let pool : Array[Double] = []
  while pool.length() < 3 * n {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let theta = 2.0 * 3.141592653589793 * u2
    pool.push(r * @math.cos(theta))
    pool.push(r * @math.sin(theta))
  }
  // build x as a constant-then-zeros matrix (x doesn't carry signal)
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let z : Array[Double] = Array::make(n, 0.0)
  let eps = pool // use as noise for d and y
  for i = 0; i < n; i = i + 1 {
    // z is a fresh normal, not a function of x
    z[i] = pool[i]
    // d = 0.7 * z + small noise; no x contribution so x is genuinely exogenous
    d[i] = 0.7 * z[i] + 0.1 * pool[n + i]
    // y = alpha * d + noise
    y[i] = alpha0 * d[i] + 0.1 * eps[2 * n + i]
  }
  let data = DoubleMLPLIVData::new(x, y, d, z)
  let fitted = DoubleMLPLIV::new(data, n_folds=2, seed=3141).fit()
  // The PLIV estimator with a strong instrument should still
  // recover the truth approximately.
  let theta = fitted.coef()
  inspect((theta - alpha0).abs() < 0.5, content="true")
}
