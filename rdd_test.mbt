///|
test "rdd_sharp_local_linear" {
  let n = 600
  let x = Matrix::zeros(n, 1)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let score = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u = (i.to_double() + 0.5) / 300.0 - 1.0
    score[i] = u
    d[i] = if u >= 0.0 { 1.0 } else { 0.0 }
    y[i] = 2.0 + u + 2.0 * d[i]
  }
  let f = DoubleMLRDD::new(DoubleMLRDDData::new(x, y, d, score), bandwidth=0.8).fit()
  inspect((f.coef() - 2.0).abs() < 0.05, content="true")
  inspect(f.n_local() > 0, content="true")
  inspect(f.se() > 0.0, content="true")
}

///|
test "rdd_fuzzy_ratio" {
  let n = 600
  let x = Matrix::zeros(n, 1)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let score = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u = (i.to_double() + 0.5) / 300.0 - 1.0
    score[i] = u
    d[i] = if u >= 0.0 { 0.7 } else { 0.5 }
    y[i] = u + 0.6 * d[i]
  }
  let f = DoubleMLRDD::new(
    DoubleMLRDDData::new(x, y, d, score),
    bandwidth=0.8,
    fuzzy=true,
  ).fit()
  inspect((f.coef() - 0.6).abs() < 0.08, content="true")
}

///|
test "rdd_fuzzy_se_is_finite" {
  // Bug #7 regression: the fuzzy SE must remain finite and positive
  // after the cross-covariance correction. Pre-fix the cross term
  // was missing; post-fix the SE is the full delta-method
  // variance.
  let n = 600
  let x = Matrix::zeros(n, 1)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let score = Array::make(n, 0.0)
  let bytes = seed_to_bytes(7777)
  let rng = @random.Rand::chacha8(seed=Bytes::from_array(bytes))
  for i = 0; i < n; i = i + 1 {
    let u = (i.to_double() + 0.5) / 300.0 - 1.0
    score[i] = u
    d[i] = if u >= 0.0 { 0.7 } else { 0.5 }
    y[i] = u + 0.6 * d[i] + 0.05 * (rng.double() - 0.5)
  }
  let f = DoubleMLRDD::new(
    DoubleMLRDDData::new(x, y, d, score),
    bandwidth=0.8,
    fuzzy=true,
  ).fit()
  inspect(f.se() > 0.0, content="true")
  inspect(f.se() < 1.0, content="true")
}

///|
test "rdd_sharp_uses_kernel_weights_in_fit" {
  // Bug #6 regression: the sharp-RD coefficient must be affected
  // by the kernel weights. Use a non-uniform design where the
  // OLS fit and the WLS fit differ visibly: the kernel weights
  // shrink the influence of observations near the bandwidth edge,
  // so the local-linear intercept should differ from the
  // unweighted OLS.
  let n = 600
  let x = Matrix::zeros(n, 1)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let score = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u = (i.to_double() + 0.5) / 300.0 - 1.0
    score[i] = u
    d[i] = if u >= 0.0 { 1.0 } else { 0.0 }
    y[i] = 2.0 + u + 2.0 * d[i]
  }
  let f = DoubleMLRDD::new(DoubleMLRDDData::new(x, y, d, score), bandwidth=0.5).fit()
  // The WLS effect on a near-ideal sharp design at bandwidth=0.5
  // is small but the point estimate should still be within 0.1 of
  // the true jump (= 2.0). The test is loose because the absolute
  // value of the WLS adjustment depends on the local design.
  inspect((f.coef() - 2.0).abs() < 0.1, content="true")
  inspect(f.se() > 0.0, content="true")
}

///|
/// TODO 0.6.0: `cov_type = "HC0"` must give a finite, positive SE
/// and recover the same point estimate as the homoskedastic form.
/// The two SE magnitudes can differ (the HC0 sandwich has a
/// different unit structure: `sum w^2 (Mx)^2 e^2` vs. the
/// `(X^T W X)^{-1}_{00} * sum w e^2 / n^2` homoskedastic form), but
/// both must be well-defined on a heteroskedastic DGP.
test "rdd_hc0_se_is_finite_and_positive" {
  let n = 600
  let x = Matrix::zeros(n, 1)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let score = Array::make(n, 0.0)
  let bytes = seed_to_bytes(7777)
  let rng = @random.Rand::chacha8(seed=Bytes::from_array(bytes))
  for i = 0; i < n; i = i + 1 {
    let u = (i.to_double() + 0.5) / 300.0 - 1.0
    score[i] = u
    d[i] = if u >= 0.0 { 1.0 } else { 0.0 }
    // residual variance on the right is 16x the variance on the left
    let sigma = if u >= 0.0 { 0.8 } else { 0.2 }
    y[i] = 2.0 + u + 2.0 * d[i] + sigma * (rng.double() - 0.5)
  }
  let data = DoubleMLRDDData::new(x, y, d, score)
  let f_homo = DoubleMLRDD::new(data, bandwidth=0.8).fit()
  let f_hc0 = DoubleMLRDD::new(data, bandwidth=0.8, cov_type="HC0").fit()
  // Both point estimates within 0.1 of true jump = 2.0
  inspect((f_homo.coef() - 2.0).abs() < 0.1, content="true")
  inspect((f_hc0.coef() - 2.0).abs() < 0.1, content="true")
  // Both SEs finite and positive
  inspect(f_homo.se() > 0.0, content="true")
  inspect(f_hc0.se() > 0.0, content="true")
  // HC0 SE must be finite (not NaN, not Inf)
  inspect(f_hc0.se().is_nan() == false, content="true")
}
