///|
test "apo_recovers_average_potential_outcome" {
  let n = 400
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    d[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
    y[i] = 2.0 + 3.0 * d[i]
  }
  let data = DoubleMLData::new(x, y, d)
  let apo1 = DoubleMLAPO::new(data, treatment_level=1.0, seed=3141).fit()
  inspect((apo1.coef() - 5.0).abs() < 1.0e-8, content="true")
  inspect(apo1.predictions_g().length(), content="400")
  inspect(apo1.predictions_m().length(), content="400")
}

///|
test "apos_fits_each_treatment_level" {
  let n = 400
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    d[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
    y[i] = 2.0 + 3.0 * d[i]
  }
  let fitted = DoubleMLAPOS::new(
    DoubleMLData::new(x, y, d),
    [0.0, 1.0],
    seed=3141,
  ).fit()
  let coefs = fitted.coefs()
  inspect((coefs[0] - 2.0).abs() < 1.0e-8, content="true")
  inspect((coefs[1] - 5.0).abs() < 1.0e-8, content="true")
  inspect(fitted.ses().length(), content="2")
}
