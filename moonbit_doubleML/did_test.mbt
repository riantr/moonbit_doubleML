///|
test "did_recovers_true_theta_on_simple_dgp" {
  // Simple DID DGP:
  //   y_pre  = x @ beta + u_pre
  //   d      = Bernoulli(p_x)
  //   y_post = x @ beta + theta * d + u_post,  u_post ~ N(0,1)
  // We observe the *first difference* y = y_post - y_pre, so
  //   y = theta * d + (u_post - u_pre)
  // After cross-fit:
  //   g0 = E[y | d=0]  �? 0          (no treatment effect for untreated)
  //   g1 = E[y | d=1]  �? theta
  //   m  = P(d=1 | x)
  // The DID estimator recovers theta.
  let n = 1000
  let p = 5
  let theta0 = 1.0
  let rng = chacha8_rng(1111)
  let pool : Array[Double] = []
  while pool.length() < n * p + 2 * n {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let t = 2.0 * 3.141592653589793 * u2
    pool.push(r * @math.cos(t))
    pool.push(r * @math.sin(t))
  }
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  for i = 0; i < n * p; i = i + 1 {
    x_flat[i] = pool[i]
  }
  let mut noise_idx = n * p
  let u_pre : Array[Double] = Array::make(n, 0.0)
  let u_post : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    u_pre[i] = pool[noise_idx]
    noise_idx = noise_idx + 1
  }
  for i = 0; i < n; i = i + 1 {
    u_post[i] = pool[noise_idx]
    noise_idx = noise_idx + 1
  }
  let x = Matrix::from_array(x_flat, n, p)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    // propensity: linear in x[:,0]
    let p_x = 0.3 + 0.2 * x.get(i, 0)
    let p_x_ = if p_x < 0.05 { 0.05 } else if p_x > 0.95 { 0.95 } else { p_x }
    d[i] = if rng.double() < p_x_ { 1.0 } else { 0.0 }
    // y_pre: latent (we don't observe), y = y_post - y_pre = theta * d + noise
    let noise = u_post[i] - u_pre[i]
    y[i] = theta0 * d[i] + noise
  }
  let data = DoubleMLDIDData::new(x, y, d)
  let fitted = DoubleMLDID::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let theta = fitted.coef()
  let se = fitted.se()
  let (lo, hi) = fitted.confint()
  inspect((theta - theta0).abs() < 0.5, content="true")
  inspect(lo < theta0, content="true")
  inspect(hi > theta0, content="true")
  // Anti-sign-flip guard: theta must be positive (true theta = 1.0).
  inspect(theta > 0.0, content="true")
  inspect(se > 0.0, content="true")
  // SE must be within a sane order of magnitude for the n = 1000 DGP.
  inspect(se < 1.0, content="true")
}

///|
test "did_fitted_has_predictions" {
  let n = 200
  let p = 3
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    d[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
    y[i] = d[i]
  }
  let data = DoubleMLDIDData::new(x, y, d)
  let fitted = DoubleMLDID::new(data, n_folds=2, seed=0).fit()
  inspect(fitted.predictions_g0().length(), content="200")
  inspect(fitted.predictions_g1().length(), content="200")
  inspect(fitted.predictions_m().length(), content="200")
}

///|
/// Regression test for the v0.43.0 abort → raise conversion in
/// `DoubleMLDIDData::new`. The previous
/// `abort("DoubleMLDIDData.d must be binary {0, 1}")` was
/// silently skipped on native/wasm-gc (MoonBit's `panic_*`
/// driver skips panic-prefixed tests; see
/// `_verify/WHITEBOX_T_REPORT.md`). The new test calls
/// `DoubleMLDIDData::new` directly with a non-binary `d` entry
/// and asserts the error fires. The `noraise` branch fails the
/// test if no error fires, the `catch` branch asserts the
/// exact variant + payload (catches any future mutation
/// that strips the variant identity or the index).
test "did_data_raises_on_non_binary_treatment" {
  // 3-row dataset; entry 1 is 0.5 (non-binary).
  let x = Matrix::zeros(3, 1)
  let y : Array[Double] = [0.0, 0.0, 0.0]
  let d : Array[Double] = [0.0, 0.5, 1.0]
  try ignore(DoubleMLDIDData::new(x, y, d)) catch {
    DIDDataError::NonBinaryTreatment(i) => inspect(i, content="1")
  } noraise {
    _ =>
      fail(
        "expected DoubleMLDIDData::new to raise DIDDataError::NonBinaryTreatment on d=[0,0.5,1]",
      )
  }
}
