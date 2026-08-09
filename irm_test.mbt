///|
test "irm_recovers_true_theta_on_simple_dgp" {
  // DGP: y = theta * d + x @ 1 + noise, with binary d, n=500, p=5.
  // ATE = theta = 1.0. The estimator should land within a few SE of
  // 1.0 and the 95% CI should contain 1.0.
  let n = 500
  let p = 5
  let theta0 = 1.0
  let bytes = seed_to_bytes(1111)
  let rng = @random.Rand::chacha8(seed=Bytes::from_array(bytes))
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  // generate normals via Box-Muller
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
  let fitted = DoubleMLIRM::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let theta = fitted.coef()
  let se = fitted.se()
  let (lo, hi) = fitted.confint()
  // IRM has higher variance than PLR because it estimates 3 nuisances
  // instead of 2; allow a wider band on the point estimate.
  // Per TODO #5 spec, IRM tolerance is still < 0.5 (same as the other 4
  // estimators); the 5-seed pre-flight probe confirmed max |theta - 1.0| is
  // well below 0.5 across seeds 3141..3145.
  inspect((theta - theta0).abs() < 0.5, content="true")
  // 95% CI should contain the truth
  inspect(lo < theta0, content="true")
  inspect(hi > theta0, content="true")
  // Anti-sign-flip guard: theta must be positive (true theta = 1.0).
  inspect(theta > 0.0, content="true")
  inspect(se > 0.0, content="true")
  // SE must be within a sane order of magnitude for the n = 500 DGP.
  inspect(se < 1.0, content="true")
}

///|
test "irm_fitted_has_predictions" {
  let n = 200
  let p = 3
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
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
  let fitted = DoubleMLIRM::new(data, n_folds=2, seed=0).fit()
  inspect(fitted.predictions_g0().length(), content="200")
  inspect(fitted.predictions_g1().length(), content="200")
  inspect(fitted.predictions_m().length(), content="200")
}

///|
test "irm_propensity_clipped_to_eps" {
  // After fit, all propensity predictions should be in
  // [propensity_clip, 1 - propensity_clip].
  let n = 100
  let p = 2
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    d[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
  }
  let data = DoubleMLData::new(x, y, d)
  let fitted = DoubleMLIRM::new(data, n_folds=2, seed=0, propensity_clip=0.1).fit()
  let m = fitted.predictions_m()
  for i = 0; i < n; i = i + 1 {
    inspect(m[i] >= 0.1, content="true")
    inspect(m[i] <= 0.9, content="true")
  }
}

///|
test "filter_indices" {
  let idx = [0, 1, 2, 3, 4, 5]
  let mask = [1.0, 0.0, 1.0, 1.0, 0.0, 1.0]
  let out = filter_indices(idx, mask)
  inspect(out.length(), content="4")
  inspect(out[0], content="0")
  inspect(out[1], content="2")
  inspect(out[2], content="3")
  inspect(out[3], content="5")
}

///|
test "clip_vec_basic" {
  let v = [0.0, 0.05, 0.5, 0.95, 1.0]
  let out = clip_vec(v, 0.1, 0.9)
  inspect(out[0], content="0.1")
  inspect(out[1], content="0.1")
  inspect(out[2], content="0.5")
  inspect(out[3], content="0.9")
  inspect(out[4], content="0.9")
}
