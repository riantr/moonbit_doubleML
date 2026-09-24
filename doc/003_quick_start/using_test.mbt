test "doc/003_quick_start/readme.mbt.md end-to-end PLR" {
  let n = 100
  let x_data : Array[Double] = Array::make(n * 5, 0.0)
  for i = 0; i < n; i = i + 1 {
    x_data[i * 5 + 0] = i.to_double()
    x_data[i * 5 + 1] = (i % 2).to_double()
    x_data[i * 5 + 2] = ((i + 1) % 3).to_double()
    x_data[i * 5 + 3] = ((i + 2) % 5).to_double()
    x_data[i * 5 + 4] = ((i + 3) % 7).to_double()
  }
  let x : @moonbit_doubleML.Matrix = @moonbit_doubleML.Matrix::from_array(
    x_data, n, 5,
  )
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    d[i] = i.to_double() * 0.5
    y[i] = i.to_double() * 1.0 + (i % 2).to_double()
  }
  let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)
  let fitted = @moonbit_doubleML.DoubleMLPLR::new(
    data, n_folds=2, n_rep=1, seed=3141,
  ).fit()
  ignore(fitted.coef())
  ignore(fitted.se())
}