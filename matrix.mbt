///|
/// Dense 2D matrix stored in row-major order as a flat Array[Double].
///
/// This is a minimal matrix type used by the DoubleML port. It is *not*
/// intended to be a general-purpose linear algebra library; only the
/// operations needed for the closed-form LinearRegression learner and the
/// DML score have been implemented.
struct Matrix {
  nrows : Int
  ncols : Int
  data : Array[Double] // length = nrows * ncols, row-major
} derive(Debug)

///|
/// Create a zero matrix of the given shape.
pub fn Matrix::zeros(nrows : Int, ncols : Int) -> Matrix {
  let data = Array::make(nrows * ncols, 0.0)
  { nrows, ncols, data, }
}

///|
/// Create a matrix filled with ones.
pub fn Matrix::ones(nrows : Int, ncols : Int) -> Matrix {
  let data = Array::make(nrows * ncols, 1.0)
  { nrows, ncols, data, }
}

///|
/// Create a matrix from a flat row-major array. Panics if length does not
/// match `nrows * ncols`.
pub fn Matrix::from_array(
  data : Array[Double],
  nrows : Int,
  ncols : Int,
) -> Matrix {
  try {
    require(data.length() == nrows * ncols)
    { nrows, ncols, data, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Create an `n x n` identity matrix.
pub fn Matrix::identity(n : Int) -> Matrix {
  let m = Matrix::zeros(n, n)
  for i = 0; i < n; i = i + 1 {
    m.data[i * n + i] = 1.0
  }
  m
}

///|
/// Number of rows (accessor — `nrows` is a private field).
pub fn Matrix::rows(self : Matrix) -> Int {
  self.nrows
}

///|
/// Number of columns (accessor — `ncols` is a private field).
pub fn Matrix::cols(self : Matrix) -> Int {
  self.ncols
}

///|
/// Element access (get). Panics if indices are out of range.
pub fn Matrix::get(self : Matrix, i : Int, j : Int) -> Double {
  self.data[i * self.ncols + j]
}

///|
/// Element access (set). Panics if indices are out of range.
pub fn Matrix::set(self : Matrix, i : Int, j : Int, v : Double) -> Unit {
  self.data[i * self.ncols + j] = v
}

///|
/// Copy this matrix into a new Matrix.
pub fn Matrix::copy(self : Matrix) -> Matrix {
  let data = Array::make(self.data.length(), 0.0)
  for i = 0; i < self.data.length(); i = i + 1 {
    data[i] = self.data[i]
  }
  { nrows: self.nrows, ncols: self.ncols, data, }
}

///|
/// Matrix transpose.
pub fn Matrix::transpose(self : Matrix) -> Matrix {
  let out = Matrix::zeros(self.ncols, self.nrows)
  for i = 0; i < self.nrows; i = i + 1 {
    for j = 0; j < self.ncols; j = j + 1 {
      out.data[j * out.ncols + i] = self.data[i * self.ncols + j]
    }
  }
  out
}

///|
/// Build a matrix from a list of row vectors. Returns an `nrows x ncols`
/// matrix where `ncols = rows[0].length()`. Panics if the rows do not all
/// share the same length.
pub fn Matrix::from_rows(rows : Array[Array[Double]]) -> Matrix {
  try {
    let nrows = rows.length()
    require(nrows > 0)
    let ncols = rows[0].length()
    let data = Array::make(nrows * ncols, 0.0)
    for i = 0; i < nrows; i = i + 1 {
      let row = rows[i]
      require(row.length() == ncols)
      for j = 0; j < ncols; j = j + 1 {
        data[i * ncols + j] = row[j]
      }
    }
    { nrows, ncols, data, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// `A * B` matrix-matrix product. Panics if inner dimensions do not match.
///
/// The inner product over the shared `k` dimension uses
/// `kahan.mbt`-style compensated summation so the partial sum does not
/// drift by `O(p * eps)` when terms of opposite sign nearly cancel.
pub fn matmul(a : Matrix, b : Matrix) -> Matrix {
  try {
    require(a.ncols == b.nrows)
    let out = Matrix::zeros(a.nrows, b.ncols)
    for i = 0; i < a.nrows; i = i + 1 {
      for j = 0; j < b.ncols; j = j + 1 {
        // Kahan-compensated inner-product accumulator: for fixed
        // (i, j), sum_{k=0..a.ncols-1} a[i][k] * b[k][j].
        let mut sum = 0.0
        let mut c = 0.0
        for k = 0; k < a.ncols; k = k + 1 {
          let prod = a.data[i * a.ncols + k] * b.data[k * b.ncols + j]
          let y = prod - c
          let t = sum + y
          c = t - sum - y
          sum = t
        }
        out.data[i * b.ncols + j] = sum
      }
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// `A * x` matrix-vector product. `x` length must equal `A.ncols`. Returns
/// a vector of length `A.nrows`.
///
/// The inner-product accumulator is Kahan-compensated (see `kahan.mbt`).
pub fn matvec(a : Matrix, x : Array[Double]) -> Array[Double] {
  try {
    require(a.ncols == x.length())
    let out = Array::make(a.nrows, 0.0)
    for i = 0; i < a.nrows; i = i + 1 {
      let mut s = 0.0
      let mut c = 0.0
      for j = 0; j < a.ncols; j = j + 1 {
        let prod = a.data[i * a.ncols + j] * x[j]
        let y = prod - c
        let t = s + y
        c = t - s - y
        s = t
      }
      out[i] = s
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// `A^T * x` matrix-vector product.
pub fn matvec_t(a : Matrix, x : Array[Double]) -> Array[Double] {
  try {
    require(a.nrows == x.length())
    let out = Array::make(a.ncols, 0.0)
    for j = 0; j < a.ncols; j = j + 1 {
      let mut s = 0.0
      let mut s_c = 0.0
      for i = 0; i < a.nrows; i = i + 1 {
        let prod = a.data[i * a.ncols + j] * x[i]
        let y = prod - s_c
        let t = s + y
        s_c = t - s - y
        s = t
      }
      out[j] = s
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Dot product of two equal-length vectors.
///
/// The accumulator is Kahan-compensated so the result is robust to
/// near-cancellation between terms (see `kahan.mbt`).
pub fn dot(a : Array[Double], b : Array[Double]) -> Double {
  try {
    require(a.length() == b.length())
    let mut s = 0.0
    let mut c = 0.0
    for i = 0; i < a.length(); i = i + 1 {
      let prod = a[i] * b[i]
      let y = prod - c
      let t = s + y
      c = t - s - y
      s = t
    }
    s
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Mean of a vector.
///
/// The accumulator is Kahan-compensated so the running sum does not
/// drift by `O(n * eps)` for long inputs. The empty-input branch
/// short-circuits to 0.0 (the package convention).
pub fn mean(a : Array[Double]) -> Double {
  if a.length() == 0 {
    return 0.0
  }
  let mut s = 0.0
  let mut c = 0.0
  for i = 0; i < a.length(); i = i + 1 {
    let y = a[i] - c
    let t = s + y
    c = t - s - y
    s = t
  }
  s / a.length().to_double()
}

///|
/// Sample variance (population formula `sum((x - mean)^2) / n`).
///
/// The `sum((a[i] - m) * (a[i] - m))` accumulator is
/// Kahan-compensated to match the sibling `mean`. Without
/// compensation, `(a[i] - m)` vanishes near `0` and the
/// accumulator loses low-order bits; Kahan keeps the running
/// sum accurate to `O(eps)` independent of `n`.
pub fn variance(a : Array[Double]) -> Double {
  if a.length() == 0 {
    return 0.0
  }
  let m = mean(a)
  let mut s = 0.0
  let mut c = 0.0
  for i = 0; i < a.length(); i = i + 1 {
    let d = a[i] - m
    let prod = d * d
    let y = prod - c
    let t = s + y
    c = t - s - y
    s = t
  }
  s / a.length().to_double()
}
