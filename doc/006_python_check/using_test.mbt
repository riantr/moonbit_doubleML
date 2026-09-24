test "doc/006_python_check/readme.mbt.md PLR cross-check shape" {
  let x : @moonbit_doubleML.Matrix = @moonbit_doubleML.Matrix::from_array(
    [1.0, 0.1, 1.0, 0.2, 1.0, 0.3, 1.0, 0.4],
    4, 2,
  )
  let y : Array[Double] = [1.1, 1.2, 1.3, 1.4]
  let d : Array[Double] = [1.0, 2.0, 3.0, 4.0]
  let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)
  let fitted = @moonbit_doubleML.DoubleMLPLR::new(
    data, n_folds=2, n_rep=1, seed=3141,
  ).fit()
  ignore(fitted.coef())
}