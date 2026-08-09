///|
test "linear_regression_perfect_fit" {
  // y = 1 + 2*x1 + 3*x2; closed-form OLS recovers the exact coefficients
  let x = Matrix::from_array(
    [1.0, 2.0, 1.0, 3.0, 2.0, 5.0, 3.0, 4.0, 0.5, 1.0, 4.0, 6.0, 7.0, 8.0],
    7,
    2,
  )
  let y = [
    1.0 + 2.0 * 1.0 + 3.0 * 2.0,
    1.0 + 2.0 * 1.0 + 3.0 * 3.0,
    1.0 + 2.0 * 2.0 + 3.0 * 5.0,
    1.0 + 2.0 * 3.0 + 3.0 * 4.0,
    1.0 + 2.0 * 0.5 + 3.0 * 1.0,
    1.0 + 2.0 * 4.0 + 3.0 * 6.0,
    1.0 + 2.0 * 7.0 + 3.0 * 8.0,
  ]
  let model = LinearRegression::new()
  let fitted = model.fit(x, y)
  // coef = [intercept, slope_x1, slope_x2] = [1, 2, 3]
  inspect((fitted.coef_[0] - 1.0).abs() < 1.0e-8, content="true")
  inspect((fitted.coef_[1] - 2.0).abs() < 1.0e-8, content="true")
  inspect((fitted.coef_[2] - 3.0).abs() < 1.0e-8, content="true")
}

///|
test "linear_regression_predict" {
  // y = 4 + 0.5*x; simple line
  let x = Matrix::from_array([0.0, 2.0, 4.0, 6.0, 8.0], 5, 1)
  let y = [4.0, 5.0, 6.0, 7.0, 8.0]
  let fitted = LinearRegression::new().fit(x, y)
  // prediction at x = 10: 4 + 0.5*10 = 9
  let xt = Matrix::from_array([10.0], 1, 1)
  let pred = fitted.predict(xt)
  inspect((pred[0] - 9.0).abs() < 1.0e-8, content="true")
}

///|
test "linear_regression_more_features_than_obs" {
  // Ridge keeps the solve from failing on near-singular X^T X
  let x = Matrix::from_array([1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0], 4, 2)
  // y is all the same value
  let y = [3.0, 3.0, 3.0, 3.0]
  let fitted = LinearRegression::new().fit(x, y)
  // Both features are constant across rows so coef_1 and coef_2
  // are under-determined. The fit should at least return finite
  // numbers and predict y correctly.
  let xt = x
  let pred = fitted.predict(xt)
  for i = 0; i < 4; i = i + 1 {
    inspect((pred[i] - 3.0).abs() < 1.0e-6, content="true")
  }
}

///|
test "linear_regression_covariance_diagonal" {
  // y = 1 + 2*x_1 + 3*x_2 + noise; n=100, p=2. Verify that
  // `covariance_diagonal(sigma2)` returns sigma^2 * diag((X'X)^-1)
  // and that the per-coefficient SE matches sqrt(cov_diag[j]).
  let n = 100
  let p = 2
  let bytes = seed_to_bytes(4242)
  let rng = @random.Rand::chacha8(seed=Bytes::from_array(bytes))
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n * p; i = i + 1 {
    // 2 uniforms per Box-Muller
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let t = 2.0 * 3.141592653589793 * u2
    x_flat[i] = if i % 2 == 0 { r * @math.cos(t) } else { r * @math.sin(t) }
  }
  for i = 0; i < n; i = i + 1 {
    let noise = 0.3 * rng.double()
    y[i] = 1.0 + 2.0 * x_flat[i * p] + 3.0 * x_flat[i * p + 1] + noise
  }
  let x = Matrix::from_array(x_flat, n, p)
  let fitted = LinearRegression::new().fit(x, y)
  // compute sigma^2 = RSS / (n - (p + 1)) = RSS / (n - 3)
  let pred = fitted.predict(x)
  let mut rss = 0.0
  for i = 0; i < n; i = i + 1 {
    let e = y[i] - pred[i]
    rss = rss + e * e
  }
  let sigma2 = rss / (n.to_double() - 3.0)
  let cov_diag = fitted.covariance_diagonal(sigma2)
  // length matches intercept + 2 slopes
  inspect(cov_diag.length(), content="3")
  // each diagonal entry must be positive
  for j = 0; j < 3; j = j + 1 {
    inspect(cov_diag[j] > 0.0, content="true")
  }
  // sanity check: re-fit via a hand-rolled (X'X) inversion and
  // compare. The hand-rolled sigma^2 * diag((X'X)^{-1}) should
  // match the model output within tolerance.
  let xa = augment_with_intercept(x)
  let xt = xa.transpose()
  let xtx = matmul(xt, xa)
  let xtx_aug = add_ridge(xtx, fitted.ridge)
  let xtx_inv = inv_spd(xtx_aug)
  for j = 0; j < 3; j = j + 1 {
    let hand = sigma2 * xtx_inv.get(j, j)
    inspect((cov_diag[j] - hand).abs() < 1.0e-8, content="true")
  }
  // SE = sqrt(cov_diag) should be finite and positive
  for j = 0; j < 3; j = j + 1 {
    let se_j = cov_diag[j].sqrt()
    inspect(se_j > 0.0 && se_j < 100.0, content="true")
  }
}

///|
test "linear_regression_fit_weighted_equal_weights_matches_ols" {
  // WLS with all-equal weights must reduce to OLS.
  let x = Matrix::from_array(
    [1.0, 2.0, 1.0, 3.0, 2.0, 5.0, 3.0, 4.0, 0.5, 1.0, 4.0, 6.0, 7.0, 8.0],
    7,
    2,
  )
  let y = [
    1.0 + 2.0 * 1.0 + 3.0 * 2.0,
    1.0 + 2.0 * 1.0 + 3.0 * 3.0,
    1.0 + 2.0 * 2.0 + 3.0 * 5.0,
    1.0 + 2.0 * 3.0 + 3.0 * 4.0,
    1.0 + 2.0 * 0.5 + 3.0 * 1.0,
    1.0 + 2.0 * 4.0 + 3.0 * 6.0,
    1.0 + 2.0 * 7.0 + 3.0 * 8.0,
  ]
  let w_ones = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
  let ols = LinearRegression::new().fit(x, y)
  let wls = LinearRegression::new().fit_weighted(x, y, w_ones)
  let oc = ols.coefficients()
  let wc = wls.coefficients()
  for j = 0; j < 3; j = j + 1 {
    inspect((oc[j] - wc[j]).abs() < 1.0e-8, content="true")
  }
}

///|
test "linear_regression_fit_weighted_changes_coefficients" {
  // WLS with non-uniform weights must give a different fit from
  // OLS. Use a small example where the high-weight observation
  // pulls the fit.
  let x = Matrix::from_array([0.0, 1.0, 2.0, 3.0, 4.0, 5.0], 3, 2)
  // y is not perfectly linear; with one heavily-weighted outlier,
  // the WLS fit should differ.
  let y = [0.0, 1.0, 10.0]
  // uniform weights => OLS = WLS
  let ols = LinearRegression::new().fit(x, y).coefficients()
  // weights favour the outlier (index 2): y[0] ~ 0.0 from x[0]=0,
  // y[2] ~ 10.0 from x[2]=4 (out-of-pattern)
  let w_skewed = [0.1, 0.1, 100.0]
  let wls = LinearRegression::new().fit_weighted(x, y, w_skewed).coefficients()
  // at least one coefficient must differ
  let mut differs = false
  for j = 0; j < 3; j = j + 1 {
    if (ols[j] - wls[j]).abs() > 1.0e-4 {
      differs = true
    }
  }
  inspect(differs, content="true")
}
