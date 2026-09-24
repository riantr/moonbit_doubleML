///|
test "cholesky_2x2_known" {
  // A = [[2, 1], [1, 3]] is SPD
  // L = [[sqrt(2), 0], [1/sqrt(2), sqrt(2.5)]]
  let a = Matrix::from_array([2.0, 1.0, 1.0, 3.0], 2, 2)
  let l = cholesky(a)
  // L L^T should reconstruct A
  let lt = l.transpose()
  let prod = matmul(l, lt)
  // First row of A: [2, 1]; second row: [1, 3]
  let v = (prod.get(0, 0) - 2.0).abs()
  inspect(v < 1.0e-12, content="true")
  let v = (prod.get(0, 1) - 1.0).abs()
  inspect(v < 1.0e-12, content="true")
  let v = (prod.get(1, 0) - 1.0).abs()
  inspect(v < 1.0e-12, content="true")
  let v = (prod.get(1, 1) - 3.0).abs()
  inspect(v < 1.0e-12, content="true")
}

///|
test "solve_spd_2x2_known" {
  // A = [[2, 1], [1, 3]], b = [5, 10] -> x = [1, 3]
  let a = Matrix::from_array([2.0, 1.0, 1.0, 3.0], 2, 2)
  let x = solve_spd(a, [5.0, 10.0])
  inspect((x[0] - 1.0).abs() < 1.0e-10, content="true")
  inspect((x[1] - 3.0).abs() < 1.0e-10, content="true")
}

///|
test "solve_spd_identity_is_b" {
  let id = Matrix::identity(3)
  let x = solve_spd(id, [1.0, 2.0, 3.0])
  inspect(x[0], content="1")
  inspect(x[1], content="2")
  inspect(x[2], content="3")
}

///|
test "solve_spd_3x3_diag" {
  // A = diag(1, 2, 3), b = [1, 4, 9] -> x = [1, 2, 3]
  let a = Matrix::from_array(
    [1.0, 0.0, 0.0, 0.0, 2.0, 0.0, 0.0, 0.0, 3.0],
    3,
    3,
  )
  let x = solve_spd(a, [1.0, 4.0, 9.0])
  inspect((x[0] - 1.0).abs() < 1.0e-10, content="true")
  inspect((x[1] - 2.0).abs() < 1.0e-10, content="true")
  inspect((x[2] - 3.0).abs() < 1.0e-10, content="true")
}

///|
test "add_ridge" {
  let a = Matrix::identity(2)
  let a2 = add_ridge(a, 5.0)
  inspect(a2.get(0, 0), content="6")
  inspect(a2.get(1, 1), content="6")
  inspect(a2.get(0, 1), content="0")
  inspect(a2.get(1, 0), content="0")
}
