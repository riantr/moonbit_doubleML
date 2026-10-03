///|
// Whitebox tests for the v0.81.0+ vectorized cross-fit helpers
// in `vectorized.mbt`. Each helper is verified against the
// reference inline loop on a small hand-checkable input, and
// `matrix_predict` is also verified against the Kahan-compensated
// `matvec` (the existing `LinearRegression::predict` core) on a
// adversarially-conditioned input. A blackbox regression test on
// `DoubleMLIRM::fit` confirms that swapping the per-fold residual
// loop for `vector_subtract` leaves the ATE point estimate within
// the pre-vectorisation tolerance band.

///|
test "matrix_predict_matches_loop" {
  // 3x4 feature matrix, 4-vec weights, zero bias. The loop
  // baseline:
  //   out[i] = sum_{j=0..3} X[i, j] * w[j]
  // which equals the standard matrix-vector product X @ w.
  let x = Matrix::from_array(
    [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0],
    3,
    4,
  )
  let w = [0.5, -1.0, 2.0, 0.25]
  let baseline = matvec(x, w)
  let got = matrix_predict(x, w, 0.0)
  inspect(got.length(), content="3")
  for i = 0; i < 3; i = i + 1 {
    let lhs = got[i]
    let rhs = baseline[i]
    let diff = if lhs > rhs { lhs - rhs } else { rhs - lhs }
    inspect(diff < 1.0e-10, content="true")
  }
}

///|
test "matrix_predict_with_bias" {
  // Same 3x4 matrix and weights, but bias = 7.5. Then
  //   out[i] = 7.5 + sum_{j} X[i, j] * w[j]
  // The first row gives 7.5 + (1*0.5 + 2*-1 + 3*2 + 4*0.25)
  //                = 7.5 + (0.5 - 2 + 6 + 1)
  //                = 7.5 + 5.5
  //                = 13.0
  let x = Matrix::from_array(
    [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0],
    3,
    4,
  )
  let w = [0.5, -1.0, 2.0, 0.25]
  let got = matrix_predict(x, w, 7.5)
  // Row 0
  inspect((got[0] - 13.0).abs() < 1.0e-10, content="true")
  // Row 1: 7.5 + (5*0.5 + 6*-1 + 7*2 + 8*0.25)
  //      = 7.5 + (2.5 - 6 + 14 + 2)
  //      = 7.5 + 12.5 = 20.0
  inspect((got[1] - 20.0).abs() < 1.0e-10, content="true")
  // Row 2: 7.5 + (9*0.5 + 10*-1 + 11*2 + 12*0.25)
  //      = 7.5 + (4.5 - 10 + 22 + 3)
  //      = 7.5 + 19.5 = 27.0
  inspect((got[2] - 27.0).abs() < 1.0e-10, content="true")
}

///|
test "matrix_predict_kahan_close_to_matvec" {
  // Adversarial: alternating-sign weights on a near-cancelling
  // accumulator. Kahan compensation in both matrix_predict and
  // matvec should produce results within 1e-9 of each other.
  let n = 32
  let p = 16
  let data : Array[Double] = Array::make(n * p, 0.0)
  for i = 0; i < n * p; i = i + 1 {
    // simple deterministic fill so the test is reproducible
    data[i] = (i + 1).to_double() * 0.01
  }
  let x = Matrix::from_array(data, n, p)
  let w : Array[Double] = Array::make(p, 0.0)
  for j = 0; j < p; j = j + 1 {
    // alternating 1 / -1 / 1 / -1 ... weights
    w[j] = if j % 2 == 0 { 1.0 } else { -1.0 }
  }
  let baseline = matvec(x, w)
  let got = matrix_predict(x, w, 0.0)
  for i = 0; i < n; i = i + 1 {
    let lhs = got[i]
    let rhs = baseline[i]
    let diff = if lhs > rhs { lhs - rhs } else { rhs - lhs }
    let mag = if lhs > rhs { lhs } else { rhs }
    let rel = if mag > 1.0e-12 { diff / mag } else { diff }
    inspect(rel < 1.0e-9, content="true")
  }
}

///|
test "vector_subtract_matches_loop" {
  let a = [1.0, 4.0, 9.0, 16.0, 25.0]
  let b = [0.5, 2.0, 4.0, 8.0, 13.0]
  let got = vector_subtract(a, b)
  let expected = [0.5, 2.0, 5.0, 8.0, 12.0]
  inspect(got.length(), content="5")
  for i = 0; i < 5; i = i + 1 {
    let lhs = got[i]
    let rhs = expected[i]
    let diff = if lhs > rhs { lhs - rhs } else { rhs - lhs }
    inspect(diff < 1.0e-10, content="true")
  }
}

///|
test "vector_add_matches_loop" {
  let a = [1.0, 2.0, 3.0, 4.0]
  let b = [0.5, 1.5, 2.5, 3.5]
  let got = vector_add(a, b)
  let expected = [1.5, 3.5, 5.5, 7.5]
  inspect(got.length(), content="4")
  for i = 0; i < 4; i = i + 1 {
    let lhs = got[i]
    let rhs = expected[i]
    let diff = if lhs > rhs { lhs - rhs } else { rhs - lhs }
    inspect(diff < 1.0e-10, content="true")
  }
}

///|
test "vector_scale_matches_loop" {
  let a = [1.0, 2.0, 3.0, 4.0, 5.0]
  let got = vector_scale(a, -2.5)
  let expected = [-2.5, -5.0, -7.5, -10.0, -12.5]
  inspect(got.length(), content="5")
  for i = 0; i < 5; i = i + 1 {
    let lhs = got[i]
    let rhs = expected[i]
    let diff = if lhs > rhs { lhs - rhs } else { rhs - lhs }
    inspect(diff < 1.0e-10, content="true")
  }
}

///|
test "panic_vector_subtract_length_mismatch_aborts" {
  // Different lengths must abort via the require(...)
  // PreconditionError path; the outer `try`/`catch` wrapper
  // converts the raise into an abort. The `panic_*` test name
  // tells MoonBit's panic driver to catch the abort.
  let a = [1.0, 2.0, 3.0]
  let b = [1.0, 2.0]
  let _ = vector_subtract(a, b)
}

///|
test "panic_vector_add_length_mismatch_aborts" {
  // Same length-mismatch abort expectation as `vector_subtract`.
  let a = [1.0, 2.0, 3.0]
  let b = [1.0, 2.0]
  let _ = vector_add(a, b)
}

///|
test "irm_fit_returns_same_coef_after_vectorize" {
  // Blackbox regression: after swapping the per-iteration
  // residual loop in DoubleMLIRM::fit for `vector_subtract`,
  // the ATE point estimate on the synthetic IRM DGP must
  // remain within the pre-vectorisation tolerance band.
  // We use the same DGP shape as the existing
  // `irm_recovers_true_theta_on_simple_dgp` test in
  // irm_test.mbt (n=500, p=5, theta0=1.0, Box-Muller
  // normals with a deterministic seed) and the same 0.5
  // absolute tolerance on the point estimate. The vectorised
  // residual computation must keep the point estimate
  // within the same band (no numerical drift beyond the
  // Kahan-compensated matvec the existing code path uses).
  let n = 500
  let p = 5
  let theta0 = 1.0
  let rng = chacha8_rng(1111)
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
  let ddata = DoubleMLData::new(x, y, d)
  let fitted = DoubleMLIRM::new(ddata, n_folds=2, n_rep=1, seed=3141).fit()
  let theta = fitted.coef()
  let se = fitted.se()
  inspect(se > 0.0, content="true")
  inspect((theta - theta0).abs() < 0.5, content="true")
}
