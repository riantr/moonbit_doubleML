// v0.51.0: 2-period, 2-group DID DGP with binary Y.
// Estimate the ATT(g=1, t=1) via
// `DoubleMLDIDCSBinary` and print the point
// estimate, SE, and 95% CI.
//
// DGP:
//   - n_per_cohort = 200 treated + 200 control.
//   - 2 periods (t = 0, 1).
//   - 3 covariates X ~ U(-1, 1).
//   - Y = 1 if (cohort == 1 && t == 1) else 0.
//     ATT(g=1, t=1) = 1.0 (the post-period lift on
//     the treated cohort).

///|
fn main {
  let n_per_cohort = 200
  let p = 3
  let n_periods = 2
  let cohort_count = 2
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  let rng = @dml.chacha8_rng(7)
  for u = 0; u < n_units; u = u + 1 {
    let cohort = u / n_per_cohort
    let xu : Array[Double] = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      xu[j] = rng.double() * 2.0 - 1.0
    }
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = xu[j]
      }
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = cohort
      d[row] = if cohort > 0 && k >= cohort { 1.0 } else { 0.0 }
      y[row] = if cohort > 0 && k >= cohort { 1.0 } else { 0.0 }
    }
  }
  let data = @dml.DoubleMLDIDCSData::new(
    @dml.Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
  let fitted = @dml.DoubleMLDIDCSBinary::new(
    data,
    1,
    0,
    1,
    control_group="never_treated",
    n_folds=4,
    n_rep=1,
    seed=3141,
  ).fit()
  let (lo, hi) = fitted.confint()
  println(
    "=== MoonBit DML demo: DID CS Binary (panel, n_units=" +
    n_units.to_string() +
    ", p=" +
    p.to_string() +
    ") ===",
  )
  println("true ATT = 1.0")
  println("")
  println("--- DoubleMLDIDCSBinary (observational, never_treated control) ---")
  println("n_obs_subset = " + fitted.n_obs().to_string())
  println("n_g_subset   = " + fitted.n_g_subset().to_string())
  println("n_c_subset   = " + fitted.n_c_subset().to_string())
  println("ATT_hat      = " + fitted.coef().to_string())
  println("se           = " + fitted.se().to_string())
  println("95% CI       = [" + lo.to_string() + ", " + hi.to_string() + "]")
}
