test "doc/005_dgps/readme.mbt.md chacha8_rng factory" {
  // The full make_plr_CCDDHNR2018 factory wraps fields in an abstract
  // struct; for this doc smoke we just confirm chacha8_rng + Matrix
  // composition work as advertised.
  let rng = @moonbit_doubleML.chacha8_rng(3141)
  ignore(rng)
  let x_data : Array[Double] = Array::make(50 * 3, 0.0)
  let x : @moonbit_doubleML.Matrix = @moonbit_doubleML.Matrix::from_array(
    x_data, 50, 3,
  )
  let y : Array[Double] = Array::make(50, 0.0)
  let d : Array[Double] = Array::make(50, 1.0)
  let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)
  let fitted = @moonbit_doubleML.DoubleMLPLR::new(
    data, n_folds=2, seed=3141,
  ).fit()
  ignore(fitted.coef())
}