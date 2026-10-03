///|
// Vectorized building blocks for the per-fold cross-fit predict
// and residual computation in DML score functions (v0.81.0+).
//
// The DML per-fold predict / residual step is the inner loop of
// `DoubleMLIRM::fit` and `DoubleMLPLR::fit`:
//   - per fold: train learner on `(x_train, y_train)`, then
//     predict on `x_test`,
//   - per fold: compute per-observation residuals
//     `u_hat = y - y_pred` and `v_hat = d - m_pred`.
// Today's per-fold predictive step uses `LinearRegression::predict`
// which already calls `matvec` (Kahan-compensated matrix-vector
// product from `matrix.mbt`), but the post-fit score-element
// accumulation in the IRM / PLR `fit()` body is an O(n) loop
// over the test observations doing element-wise subtract, add,
// and scale. This file exposes those element-wise operations as
// named, public functions so the per-fold score loop can be
// written in terms of vectorised building blocks rather than
// per-iteration scalars.
//
// The bodies are identical to the inline loops they replace --
// the value is in exposing the named building blocks rather
// than the micro-optimisation. v0.82+ will swap the bodies to
// a SIMD-vectorised backend (or external call to a BLAS-style
// library) without breaking callers.
//
// All helpers are pure (no mutation of the inputs) and return
// freshly-allocated `Array[Double]` of the same length as the
// inputs (or `X.rows()` for `matrix_predict`).

///|
/// Predict `y = X @ weights + bias` for an `n x p` feature matrix
/// `X`, length-`p` coefficient vector `weights`, and scalar
/// intercept `bias`. Returns a length-`n` vector.
///
/// Equivalent to:
///   for i = 0; i < n; i = i + 1 {
///     let mut s = bias
///     for j = 0; j < p; j = j + 1 {
///       s = s + X[i, j] * weights[j]
///     }
///     out[i] = s
///   }
///
/// The accumulator uses Kahan compensated summation so the
/// partial sum does not drift by `O(p * eps)` when terms of
/// opposite sign nearly cancel, matching the `matvec` helper
/// that `LinearRegression::predict` already uses for the
/// augmented `(X | 1) @ coef` path.
pub fn matrix_predict(
  mat : Matrix,
  weights : Array[Double],
  bias : Double,
) -> Array[Double] {
  let p = mat.cols()
  let n = mat.rows()
  let out : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let mut s = bias
    let mut c = 0.0
    for j = 0; j < p; j = j + 1 {
      let prod = mat.data[i * p + j] * weights[j]
      let y = prod - c
      let t = s + y
      c = t - s - y
      s = t
    }
    out[i] = s
  }
  out
}

///|
/// Element-wise subtraction `a - b`. Inputs must share length;
/// returns a freshly-allocated `Array[Double]` of that length.
/// Aborts via `require` if the lengths disagree.
pub fn vector_subtract(a : Array[Double], b : Array[Double]) -> Array[Double] {
  try {
    let n = a.length()
    require(b.length() == n)
    let out : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      out[i] = a[i] - b[i]
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Element-wise addition `a + b`. Inputs must share length;
/// returns a freshly-allocated `Array[Double]` of that length.
/// Aborts via `require` if the lengths disagree.
pub fn vector_add(a : Array[Double], b : Array[Double]) -> Array[Double] {
  try {
    let n = a.length()
    require(b.length() == n)
    let out : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      out[i] = a[i] + b[i]
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Element-wise scalar multiplication `a * s`. Returns a
/// freshly-allocated `Array[Double]` of the same length as
/// `a`. `s` is a scalar applied to every entry.
pub fn vector_scale(a : Array[Double], s : Double) -> Array[Double] {
  let n = a.length()
  let out : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    out[i] = a[i] * s
  }
  out
}
