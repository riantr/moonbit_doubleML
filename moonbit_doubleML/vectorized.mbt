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

///|
/// Element-wise multiplication `a * b`. v0.82.0+. Inputs must
/// share length; returns a freshly-allocated `Array[Double]` of
/// that length. Aborts via `require` if the lengths disagree.
/// Used by the per-fold score-element accumulation in the
/// quantiled DID / IRM / IIVM score functions where the per-
/// observation residual contribution is a product of a residual
/// vector and a scalar / vector factor (e.g.
/// `psi_b += d * u1 / m` where each factor can be extracted via
/// `vector_multiply` + `vector_divide` instead of an inlined
/// per-iteration scalar multiply).
pub fn vector_multiply(a : Array[Double], b : Array[Double]) -> Array[Double] {
  try {
    let n = a.length()
    require(b.length() == n)
    let out : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      out[i] = a[i] * b[i]
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Element-wise division `a / max(b, eps)`. v0.82.0+. Inputs
/// must share length; returns a freshly-allocated
/// `Array[Double]` of that length. `eps` (default `1.0e-12`)
/// guards against a near-zero denominator in the propensity /
/// complier-prob / instrument-propensity factors that the IRM /
/// IIVM / LPQ scores divide by. Aborts via `require` if the
/// input lengths disagree or `eps <= 0`.
///
/// The denominator is clipped (NOT the numerator) so the score
/// preserves the original numerator scale when the denominator
/// is well-behaved, and only folds in the `eps` floor when
/// truly necessary. This matches the upstream `doubleml-for-py`
/// convention of clipping `m_hat` to `[eps, 1 - eps]` BEFORE
/// division (rather than clipping the score after division).
pub fn vector_divide(
  a : Array[Double],
  b : Array[Double],
  eps? : Double = 1.0e-12,
) -> Array[Double] {
  try {
    let n = a.length()
    require(b.length() == n)
    require(eps > 0.0)
    let out : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      let bi = b[i]
      let denom = if bi >= 0.0 && bi < eps {
        eps
      } else if bi < 0.0 && bi > -eps {
        -eps
      } else {
        bi
      }
      out[i] = a[i] / denom
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
