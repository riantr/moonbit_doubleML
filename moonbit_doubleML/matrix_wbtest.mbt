///|
// Whitebox tests for matrix.mbt internals.
//
// `matrix_test.mbt` covers the public surface (constructors,
// accessors, and the matmul identity / known-value paths).
// This file tests the structural contracts that the public
// surface relies on but does not exercise directly:
//
//   - `Matrix::ones` correctness (no blackbox test asserts the
//     actual contents of an `nrows x ncols` ones matrix).
//   - `Matrix::from_rows` (the row-list constructor; takes
//     `Array[Array[Double]]`, distinct from the flat
//     `from_array` constructor).
//   - `Matrix::copy` deep-copy semantics (the public surface
//     only sees copies through getter reads; the underlying
//     `data` array must be a fresh allocation).
//   - `matmul` precondition abort on dimension mismatch (the
//     `require(a.ncols == b.nrows)` path is exercised by the
//     `_ => abort("precondition failed ...")` fallback).
//
// These tests are scoped to package-internal symbols and
// would not compile if moved to `matrix_test.mbt`.

///|
test "matrix_ones_contents" {
  let m = Matrix::ones(3, 4)
  inspect(m.rows(), content="3")
  inspect(m.cols(), content="4")
  for i = 0; i < 3; i = i + 1 {
    for j = 0; j < 4; j = j + 1 {
      inspect(m.get(i, j), content="1")
    }
  }
}

///|
test "matrix_from_rows_2x3" {
  // Row-list constructor: takes Array[Array[Double]], distinct
  // from from_array (which takes a flat Array[Double] of length
  // nrows * ncols).
  let m = Matrix::from_rows([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])
  inspect(m.rows(), content="2")
  inspect(m.cols(), content="3")
  inspect(m.get(0, 0), content="1")
  inspect(m.get(0, 1), content="2")
  inspect(m.get(0, 2), content="3")
  inspect(m.get(1, 0), content="4")
  inspect(m.get(1, 1), content="5")
  inspect(m.get(1, 2), content="6")
}

///|
test "matrix_copy_is_deep" {
  // The data array must be a fresh allocation: mutating one
  // must not be observable through the other. The struct copy
  // shorthand would alias the underlying `data` array, so
  // `Matrix::copy` is implemented as a manual re-`make`.
  let m1 = Matrix::from_array([1.0, 2.0, 3.0, 4.0, 5.0, 6.0], 2, 3)
  let m2 = m1.copy()
  // Mutate m1; m2 must not see it.
  m1.set(0, 0, 99.0)
  inspect(m1.get(0, 0), content="99")
  inspect(m2.get(0, 0), content="1")
  // The structural fields (nrows, ncols) are Int copies by
  // value, so equality is automatic; the data array is the
  // one that needs verification.
  inspect(m2.rows(), content=m1.rows().to_string())
  inspect(m2.cols(), content=m1.cols().to_string())
}

///|
test "panic_matmul_dimension_mismatch_aborts" {
  // matmul's precondition `require(a.ncols == b.nrows)` must
  // abort when violated. The `try { ... } catch { abort(...) }`
  // wrapper converts the v0.48.0 `raise PreconditionError` to
  // a process abort. Test the abort path with the
  // `panic_*` naming convention so MoonBit's panic test
  // driver catches and reports the abort message.
  let a = Matrix::zeros(2, 3) // 2x3
  let b = Matrix::zeros(2, 2) // 2x2 -- inner 3 vs 2 mismatches
  let _ = matmul(a, b)
}

///|
test "matrix_transpose_involutive" {
  // The double-transpose is the identity: T(T(M)) == M for all
  // shapes. The single-transpose behaviour is covered by
  // `matrix_transpose_2x3`; this tests the round-trip.
  let m = Matrix::from_array([1.0, 2.0, 3.0, 4.0, 5.0, 6.0], 2, 3)
  let m_t = m.transpose()
  let m_tt = m_t.transpose()
  inspect(m_tt.rows(), content=m.rows().to_string())
  inspect(m_tt.cols(), content=m.cols().to_string())
  for i = 0; i < m.rows(); i = i + 1 {
    for j = 0; j < m.cols(); j = j + 1 {
      inspect(m_tt.get(i, j), content=m.get(i, j).to_string())
    }
  }
}

///|
test "matmul_associativity_2x2x2" {
  // (A * B) * C == A * (B * C) within 1e-9 relative tolerance.
  // This is the structural invariant that justifies the use of
  // compensated summation in `matmul` (per the v0.34.0+ kahan
  // comment in matrix.mbt). Without compensation, naive matmul
  // would drift at O(p * eps) and fail this test on adversarial
  // inputs.
  let a = Matrix::from_array([1.0, 2.0, 0.5, -1.0], 2, 2)
  let b = Matrix::from_array([3.0, 1.0, 2.0, 4.0], 2, 2)
  let c = Matrix::from_array([1.0, 0.0, -1.0, 2.0], 2, 2)
  let ab_c = matmul(matmul(a, b), c)
  let a_bc = matmul(a, matmul(b, c))
  for i = 0; i < 2; i = i + 1 {
    for j = 0; j < 2; j = j + 1 {
      let lhs = ab_c.get(i, j)
      let rhs = a_bc.get(i, j)
      let diff = if lhs > rhs { lhs - rhs } else { rhs - lhs }
      let mag = if lhs > rhs { lhs } else { rhs }
      let rel = if mag > 1.0e-12 { diff / mag } else { diff }
      inspect(rel < 1.0e-9, content="true")
    }
  }
}
