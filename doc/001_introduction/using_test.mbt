///|
test "doc/001_introduction/readme.mbt.md end-to-end smoke" {
  let n = 5
  let x_data : Array[Double] = [
    1.0, 2.0, 3.0, 4.0, 5.0, 1.0, 2.0, 3.0, 4.0, 5.0,
  ]
  let x : @moonbit_doubleML.Matrix = @moonbit_doubleML.Matrix::from_array(
    x_data, n, 2,
  )
  let y : Array[Double] = [3.0, 5.0, 7.0, 9.0, 11.0]
  let d : Array[Double] = [1.0, 2.0, 3.0, 4.0, 5.0]
  let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)
  let fitted = @moonbit_doubleML.DoubleMLPLR::new(
    data,
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  ignore(fitted.coef())
  ignore(fitted.se())
}
