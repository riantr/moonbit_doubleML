///|
/// Cholesky decomposition. Computes a lower triangular matrix `L` such
/// that `A = L * L^T` for a symmetric positive-definite matrix `A`.
///
/// The decomposition is performed in place. `L` is stored in the lower
/// triangle of `a` (the upper triangle is not referenced and may contain
/// garbage). Panics if `a` is not square or if the matrix is not positive
/// definite (a non-positive pivot is treated as a fatal error).
///
/// This is a textbook implementation. For the small problem sizes used in
/// the DoubleML examples it is more than fast enough.
pub fn cholesky(a : Matrix) -> Matrix {
  require(a.nrows == a.ncols)
  let n = a.nrows
  let l = a.copy()
  for i = 0; i < n; i = i + 1 {
    // diagonal element
    // s = sum_{k < i} l[i][k]^2 (Kahan-compensated; see kahan.mbt)
    let mut s = 0.0
    let mut s_c = 0.0
    for k = 0; k < i; k = k + 1 {
      let lik = l.data[i * n + k]
      let prod = lik * lik
      let y = prod - s_c
      let t = s + y
      s_c = t - s - y
      s = t
    }
    let diag = l.data[i * n + i] - s
    require(diag > 0.0) // matrix must be positive definite
    let d = diag.sqrt()
    l.data[i * n + i] = d
    // off-diagonal elements in column i
    if d == 0.0 {
      continue
    }
    for j = i + 1; j < n; j = j + 1 {
      // t = sum_{k < i} l[j][k] * l[i][k] (Kahan-compensated)
      let mut t = 0.0
      let mut t_c = 0.0
      for k = 0; k < i; k = k + 1 {
        let prod = l.data[j * n + k] * l.data[i * n + k]
        let y = prod - t_c
        let tt = t + y
        t_c = tt - t - y
        t = tt
      }
      l.data[j * n + i] = (l.data[j * n + i] - t) / d
    }
  }
  // zero out the upper triangle (entries with col > row) for cleanliness
  for i = 0; i < n; i = i + 1 {
    for j = i + 1; j < n; j = j + 1 {
      l.data[i * n + j] = 0.0
    }
  }
  l
}

///|
/// Solve `A x = b` for a symmetric positive-definite `A` using the
/// Cholesky factorisation `A = L L^T`. The system is solved in two steps:
/// forward substitution for `L y = b`, then back substitution for
/// `L^T x = y`.
pub fn solve_spd(a : Matrix, b : Array[Double]) -> Array[Double] {
  let n = a.nrows
  require(a.nrows == a.ncols)
  require(a.nrows == b.length())
  let l = cholesky(a)
  // forward substitution: L y = b
  let y = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let mut s = b[i]
    for k = 0; i > 0 && k < i; k = k + 1 {
      s = s - l.data[i * n + k] * y[k]
    }
    y[i] = s / l.data[i * n + i]
  }
  // back substitution: L^T x = y
  let x = Array::make(n, 0.0)
  for ri = 0; ri < n; ri = ri + 1 {
    let i = n - 1 - ri
    let mut s = y[i]
    for k = i + 1; k < n; k = k + 1 {
      s = s - l.data[k * n + i] * x[k]
    }
    x[i] = s / l.data[i * n + i]
  }
  x
}

///|
/// Add a small ridge `lambda * I` to a square matrix and return a copy.
/// Useful for guarding `X^T X` against singularity when the design matrix
/// is near-collinear.
pub fn add_ridge(a : Matrix, lambda : Double) -> Matrix {
  require(a.nrows == a.ncols)
  let out = a.copy()
  let n = a.nrows
  for i = 0; i < n; i = i + 1 {
    out.data[i * n + i] = out.data[i * n + i] + lambda
  }
  out
}

///|
/// Invert a symmetric positive-definite matrix using the Cholesky
/// factorisation `A = L L^T`. Returns the full inverse matrix. Used by
/// `LinearRegression::fit` to populate the `(X^T X)^{-1}` diagonal that
/// drives the per-coefficient standard errors. Small (≤ a few hundred
/// rows in DML) so the `O(n^3)` cost is invisible at the test scale.
pub fn inv_spd(a : Matrix) -> Matrix {
  let n = a.nrows
  require(a.nrows == a.ncols)
  let l = cholesky(a)
  // inv(A) = inv(L^T) * inv(L). Build it column-by-column by solving
  // A * e_i = b for each standard basis vector b. Using `solve_spd`
  // would be cleaner but we have already factorised; solve the two
  // triangular systems directly to avoid re-cholesky-ing n times.
  let inv = Matrix::zeros(n, n)
  // inv(L): for i >= j, L[i, j] * inv_L[j, k] = delta(i, k); back-solve
  // L_inv[i, k] = (delta(i, k) - sum_{j < i} L[i, j] * L_inv[j, k]) / L[i, i]
  let l_inv = Matrix::zeros(n, n)
  for i = 0; i < n; i = i + 1 {
    let diag = l.data[i * n + i]
    for k = 0; k < n; k = k + 1 {
      let mut s = if i == k { 1.0 } else { 0.0 }
      for j = 0; j < i; j = j + 1 {
        s = s - l.data[i * n + j] * l_inv.data[j * n + k]
      }
      l_inv.data[i * n + k] = s / diag
    }
  }
  // inv(A) = inv(L^T) * inv(L) = (inv(L))^T * inv(L)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < n; j = j + 1 {
      let mut s = 0.0
      for k = 0; k < n; k = k + 1 {
        s = s + l_inv.data[k * n + i] * l_inv.data[k * n + j]
      }
      inv.data[i * n + j] = s
    }
  }
  inv
}
