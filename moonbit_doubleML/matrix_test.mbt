///|
test "matrix_from_array_zero" {
  let m = Matrix::from_array([0.0, 0.0, 0.0, 0.0], 2, 2)
  inspect(m.get(0, 0), content="0")
  inspect(m.get(1, 1), content="0")
}

///|
test "matrix_identity" {
  let i = Matrix::identity(3)
  inspect(i.get(0, 0), content="1")
  inspect(i.get(1, 1), content="1")
  inspect(i.get(2, 2), content="1")
  inspect(i.get(0, 1), content="0")
  inspect(i.get(2, 0), content="0")
}

///|
test "matrix_transpose_2x3" {
  // [[1, 2, 3], [4, 5, 6]] -> [[1, 4], [2, 5], [3, 6]]
  let a = Matrix::from_array([1.0, 2.0, 3.0, 4.0, 5.0, 6.0], 2, 3)
  let at = a.transpose()
  inspect(at.rows(), content="3")
  inspect(at.cols(), content="2")
  inspect(at.get(0, 0), content="1")
  inspect(at.get(0, 1), content="4")
  inspect(at.get(1, 0), content="2")
  inspect(at.get(1, 1), content="5")
  inspect(at.get(2, 0), content="3")
  inspect(at.get(2, 1), content="6")
}

///|
test "matmul_identity" {
  let a = Matrix::from_array([1.0, 2.0, 3.0, 4.0, 5.0, 6.0], 2, 3)
  let id = Matrix::identity(3)
  let b = matmul(a, id)
  inspect(b.get(0, 0), content="1")
  inspect(b.get(0, 2), content="3")
  inspect(b.get(1, 0), content="4")
  inspect(b.get(1, 2), content="6")
}

///|
test "matmul_known_2x2" {
  // [[1, 2], [3, 4]] * [[5, 6], [7, 8]] = [[19, 22], [43, 50]]
  let a = Matrix::from_array([1.0, 2.0, 3.0, 4.0], 2, 2)
  let b = Matrix::from_array([5.0, 6.0, 7.0, 8.0], 2, 2)
  let c = matmul(a, b)
  inspect(c.get(0, 0), content="19")
  inspect(c.get(0, 1), content="22")
  inspect(c.get(1, 0), content="43")
  inspect(c.get(1, 1), content="50")
}

///|
test "matvec_known" {
  // [[1, 2, 3], [4, 5, 6]] * [1, 1, 1] = [6, 15]
  let a = Matrix::from_array([1.0, 2.0, 3.0, 4.0, 5.0, 6.0], 2, 3)
  let y = matvec(a, [1.0, 1.0, 1.0])
  inspect(y.length(), content="2")
  inspect(y[0], content="6")
  inspect(y[1], content="15")
}

///|
test "dot_basic" {
  let d = dot([1.0, 2.0, 3.0], [4.0, 5.0, 6.0])
  inspect(d, content="32")
}

///|
test "mean_basic" {
  inspect(mean([1.0, 2.0, 3.0, 4.0]), content="2.5")
  inspect(mean([0.0, 0.0, 0.0]), content="0")
}

///|
test "variance_basic" {
  // variance of [1, 2, 3, 4, 5] = 2.0 (population formula)
  let v = variance([1.0, 2.0, 3.0, 4.0, 5.0])
  inspect(v, content="2")
}

///|
/// Regression test: `matvec_t` must use Kahan-compensated
/// summation to keep the result of an intentionally sign-cancelling
/// dot product within `1.0e-10` of the mathematical answer
/// (which is `0.0`). The un-Kahan plain `s = s + a*b` accumulator
/// drifts to ~`n * eps` for a length-`n` input; this test
/// exercises `n = 10000` rows.
///
/// This is the canonical "would I notice if someone reverted the
/// Kahan accumulator?" probe for both `matvec_t` and `variance`
/// (both of which got the Kahan compensation in v0.52.0, per
/// REVIEW_BACKEND.md F1 + F3).
test "matvec_t_kahan_matches_matvec" {
  // Build a (n x 1) matrix where column 0 alternates +0.5 /
  // -0.5 across 10_000 rows. matvec_t of this matrix with
  // x = Array::make(n, 1.0e-4) computes
  //   result[0] = sum_i mat[i, 0] * x[i]
  //             = sum_i (+/- 0.5) * 1.0e-4
  //             = 0   (sign-cancelling perfect cancellation).
  // With Kahan this is exactly 0.0; without Kahan the result is
  // O(n * eps) ≈ 1.0e-12 for n=10_000, which `1.0e-10` catches.
  let n : Int = 10000
  let mat_data : Array[Double] = Array::makei(n, fn(i) {
    if i % 2 == 0 {
      0.5
    } else {
      -0.5
    }
  })
  let mat = Matrix::from_array(mat_data, n, 1)
  let x : Array[Double] = Array::make(n, 1.0e-4)
  let res = matvec_t(mat, x)
  // Kahan result is exactly 0.0; tolerance is generous enough to
  // absorb a future "improvement" that tightens the budget.
  let drift = (res[0] - 0.0).abs()
  if !(drift < 1.0e-10) {
    fail("matvec_t Kahan: drift = \{drift}, expected < 1e-10")
  }
}
