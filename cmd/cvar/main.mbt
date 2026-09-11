///|
// v0.50.0: 2-level discrete-treatment DGP, run the
// `DoubleMLCVAR` at q=0.5, print the coef + se + 95% CI.
//
// The DGP matches the canonical one in
// `quantile_test.mbt::quantile_test_data`: n=400, alternating
// `d`, `y = d + (i%100)/100`, no covariates. The true
// CVaR at q=0.5 of the treated y is 1.74 (the mean of the
// upper 50% of the alternating-treated y sequence, which
// spans 1.00, 1.02, ..., 1.98).
//
// `LinearRegression` (closed-form Cholesky + ridge 1e-10)
// is the regressor for both `ml_g` and `ml_m`; the
// propensity is the regression of `d` on `X` clipped to
// `[1e-6, 1 - 1e-6]`. No sklearn models, no classifiers.

///|
fn main {
  let n = 400
  let n_features = 2
  let x = @mavis/dml.Matrix::zeros(n, n_features)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    d[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
    y[i] = d[i] + (i % 100).to_double() / 100.0
  }
  let data = @mavis/dml.DoubleMLData::new(x, y, d)
  // Run CVaR at q = 0.5. Use 2 folds (matches the rest
  // of the package) and 1 repetition for determinism.
  let fitted = @mavis/dml.DoubleMLCVAR::new(
    data,
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let c = fitted.coef()
  let s = fitted.se()
  let (lo, hi) = fitted.confint()
  println(
    "DoubleMLCVAR  v0.50.0  (Conditional Value at Risk, Kallus/Mao/Uehara 2024)",
  )
  println("DGP: n=400, alternating d, y = d + (i%100)/100, no covariates")
  println("Treatment: 1,  Quantile: 0.5,  Folds: 2,  Reps: 1")
  println("")
  println("coef (point estimate): " + c.to_string())
  println("se   (DML SE):         " + s.to_string())
  println(
    "95% CI:                (" + lo.to_string() + ", " + hi.to_string() + ")",
  )
  println("")
  println("True CVaR at q=0.5:     1.74")
  println("Recovered coef:         " + c.to_string())
  println("|coef - 1.74|:          " + (c - 1.74).abs().to_string())
  if (c - 1.74).abs() < 2.0 * s + 0.05 {
    println("Result:                 PASS  (within 2*se + 0.05 of 1.74)")
  } else {
    println("Result:                 FAIL  (outside 2*se + 0.05 of 1.74)")
  }
}
