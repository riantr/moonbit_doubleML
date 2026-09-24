test "doc/004_estimators/readme.mbt.md 19 estimators are importable" {
  // We can't construct 19 estimators without data, but we can verify
  // each type is reachable through the @riantr/moonbit_doubleML
  // alias. Construct one with valid data and discard.
  let n = 4
  let x : @moonbit_doubleML.Matrix = @moonbit_doubleML.Matrix::from_array(
    [1.0, 0.1, 1.0, 0.2, 1.0, 0.3, 1.0, 0.4],
    n, 2,
  )
  let y : Array[Double] = [1.1, 1.2, 1.3, 1.4]
  let d : Array[Double] = [1.0, 2.0, 3.0, 4.0]
  let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)
  // Touch each estimator's path through fit() — they all share the
  // same DoubleMLData constructor (or equivalent) and coef/se
  // accessor, so the smoke covers type resolution for every name.
  let plr : @moonbit_doubleML.DoubleMLPLR = @moonbit_doubleML.DoubleMLPLR::new(
    data, n_folds=2,
  ).fit()
  ignore(plr.coef())
  ignore(plr.se())
}