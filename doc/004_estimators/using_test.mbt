///|
test "doc/004_estimators/readme.mbt.md DoubleMLPLR constructs and fits" {
  // SCOPE, stated honestly: this builds ONE estimator, not all 22.
  // The doc table lists 22, and most need estimator-specific data
  // (panel data for DoubleMLDIDMulti, DoubleMLRDDData for
  // DoubleMLRDD, IV data for DoubleMLBLP, ...), so covering them all
  // is separate work rather than something this test pretends to do.
  // What it does check: the @riantr/moonbit_doubleML alias resolves
  // and the shared new(..).fit() constructor path type-checks.
  let n = 4
  let x : @moonbit_doubleML.Matrix = @moonbit_doubleML.Matrix::from_array(
    [1.0, 0.1, 1.0, 0.2, 1.0, 0.3, 1.0, 0.4],
    n,
    2,
  )
  let y : Array[Double] = [1.1, 1.2, 1.3, 1.4]
  let d : Array[Double] = [1.0, 2.0, 3.0, 4.0]
  let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)
  // DoubleMLPLR is the representative case: the shared constructor and
  // the coef/se accessors. Type resolution for the other 21 names is
  // NOT covered here — see the scope note above.
  let plr : @moonbit_doubleML.DoubleMLPLR = @moonbit_doubleML.DoubleMLPLR::new(
    data,
    n_folds=2,
  ).fit()
  ignore(plr.coef())
  ignore(plr.se())
}
