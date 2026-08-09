///|
test "plr_recovers_true_theta_on_simple_dgp" {
  // DGP: y = 1.0 * d + x @ 1 + noise,  n = 500, p = 5, d binary.
  // The port should produce a theta within a few SE of 1.0 and
  // the 95% CI should contain 1.0.
  let n = 500
  let p = 5
  let theta0 = 1.0
  // build deterministic data using a chacha8-seeded PRNG. We do
  // not care about matching numpy — we only check the *statistical*
  // properties of the estimator.
  let bytes = seed_to_bytes(1111)
  let rng = @random.Rand::chacha8(seed=Bytes::from_array(bytes))
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  // generate enough Box-Muller normals for x_flat + noise
  let pool : Array[Double] = []
  while pool.length() < n * p + n {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let theta = 2.0 * 3.141592653589793 * u2
    pool.push(r * @math.cos(theta))
    pool.push(r * @math.sin(theta))
  }
  for i = 0; i < n * p; i = i + 1 {
    x_flat[i] = pool[i]
  }
  // noise -> y part
  let mut noise_idx = n * p
  for i = 0; i < n; i = i + 1 {
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    let mut s = pool[noise_idx]
    noise_idx = noise_idx + 1
    for j = 0; j < p; j = j + 1 {
      s = s + x_flat[i * p + j]
    }
    y[i] = theta0 * d[i] + s
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d)
  let fitted = DoubleMLPLR::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  // theta_hat should be in [0.5, 1.5] (true=1.0) with high probability
  let theta = fitted.coef()
  let se = fitted.se()
  let (lo, hi) = fitted.confint()
  // Test 1: estimate is within +/- 0.2 of the true theta (tightened from 0.5
  // after the TODO #5 5-seed pre-flight probe: max |theta - 1.0| = 0.050).
  inspect((theta - theta0).abs() < 0.2, content="true")
  // Test 2: 95% CI contains the true theta
  inspect(lo < theta0, content="true")
  inspect(hi > theta0, content="true")
  // Test 3: anti-sign-flip guard — theta must be positive (true theta = 1.0).
  inspect(theta > 0.0, content="true")
  // Test 4: SE is positive
  inspect(se > 0.0, content="true")
  // Test 5: SE is within a sane order of magnitude for the n = 500 DGP
  // (5-seed pre-flight probe: max SE = 0.088).
  inspect(se < 1.0, content="true")
}

///|
test "plr_fitted_has_predictions" {
  // Make sure the cross-fit predictions are populated and have the
  // right length after fit().
  let n = 100
  let p = 3
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  // set y = x @ ones + d, so true theta = 1
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x.set(i, j, 0.1 * (i + 1).to_double() * (j + 1).to_double())
      y[i] = y[i] + x.get(i, j)
    }
    if i % 2 == 0 {
      d[i] = 1.0
      y[i] = y[i] + 1.0
    }
  }
  let data = DoubleMLData::new(x, y, d)
  let fitted = DoubleMLPLR::new(data, n_folds=2, seed=0).fit()
  inspect(fitted.predictions_l().length(), content="100")
  inspect(fitted.predictions_m().length(), content="100")
}
