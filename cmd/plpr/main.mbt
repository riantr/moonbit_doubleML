// Demo: static panel PLPR (DoubleMLPLPR, Clarke & Polselli 2025).
// 60 units x 4 periods with unit fixed effects correlated with the
// treatment; true theta = 1.0. All four approaches run the
// clustered DML path: unit-level folds, fold-weighted cluster
// coefficient, unit-level cluster-robust SE.

///|
fn build_panel(
  rng : @random.Rand,
  n_units : Int,
  n_periods : Int,
) -> @dml.DoubleMLPanelData {
  let p = 2
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  let theta0 = 1.0
  for u = 0; u < n_units; u = u + 1 {
    let alpha = (rng.double() - 0.5) * 4.0
    let unit_trait = rng.double() * 2.0 - 1.0
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      let x1 = unit_trait + (rng.double() - 0.5)
      let x2 = rng.double() * 2.0 - 1.0
      x_flat[row * p] = x1
      x_flat[row * p + 1] = x2
      t_arr[row] = k
      id_arr[row] = u
      d[row] = 0.6 * x1 + 0.3 * x2 + 0.5 * alpha / 2.0 + (rng.double() - 0.5)
      y[row] = theta0 * d[row] +
        0.8 * x1 -
        0.5 * x2 +
        alpha +
        (rng.double() - 0.5) * 0.25
    }
  }
  @dml.DoubleMLPanelData::new(
    @dml.Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
  )
}

///|
fn main {
  let panel = build_panel(@dml.chacha8_rng(3141), 60, 4)
  println("=== MoonBit DML demo: static panel PLPR (60 units x 4 periods) ===")
  println("true theta = 1.0 (unit FE correlated with treatment)")
  println("")
  let approaches = [
    ("cre_general", "CRE, general (Mundlak augmentation)"),
    ("cre_normal", "CRE, normal restriction"),
    ("fd_exact", "exact first differences"),
    ("wg_approx", "approximate within transformation"),
  ]
  for i = 0; i < approaches.length(); i = i + 1 {
    let name = approaches[i].0
    let desc = approaches[i].1
    let fitted = @dml.DoubleMLPLPR::new(
      panel,
      approach=name,
      n_folds=2,
      seed=3141,
    ).fit()
    let (lo, hi) = fitted.confint()
    println("--- \{name} (\{desc}) ---")
    println("theta_hat = \{fitted.coef()}")
    println("se        = \{fitted.se()}  (cluster-robust, unit level)")
    println("95% CI    = [\{lo}, \{hi}]")
    println("")
  }
}
