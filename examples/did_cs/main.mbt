// Demo: Callaway-Sant'Anna staggered DID. 4 cohorts (g=0 control,
// g=1, 2, 3 treated in their respective period), 4 periods
// (t = 0, 1, 2, 3). True ATT = 1.0 applied to each unit's
// post-treatment period (t > g).
//
// The CS-DID estimator iterates over (g, t) cells with t > g
// and runs a DoubleMLDIDBinary on each. Expected output: 3 cells
// (g=1, t=2), (g=1, t=3), (g=2, t=3) should all recover ~1.0.

///|
fn main {
  let n_per_cohort = 50
  let p = 3
  let theta0 = 1.0
  let n_periods = 4
  let cohort_count = 4
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  let rng = @moonbit_doubleML.chacha8_rng(11)
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
      let mut y_val = 0.0
      for j = 0; j < p; j = j + 1 {
        y_val = y_val + xu[j]
      }
      if cohort > 0 && k > cohort {
        y_val = y_val + theta0
      }
      y_val = y_val + 0.05 * (rng.double() - 0.5)
      y[row] = y_val
    }
  }
  let data = @moonbit_doubleML.DoubleMLDIDCSData::new(
    @moonbit_doubleML.Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
  let fitted = @moonbit_doubleML.DoubleMLDIDCS::new(
    data,
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  println(
    "=== MoonBit DML demo: Callaway-Sant'Anna DID (staggered, n_units=\{n_units}, p=\{p}) ===",
  )
  println("true ATT = \{theta0}")
  println("")
  println("n_groups = \{fitted.n_groups()}, n_periods = \{fitted.n_periods()}")
  println("")
  println("--- Per-(g, t) ATT estimates (post-treatment cells) ---")
  for gi = 0; gi < fitted.n_groups(); gi = gi + 1 {
    let g_value = fitted.group_at(gi)
    for pi = 0; pi < fitted.n_periods(); pi = pi + 1 {
      let t_eval = fitted.period_at(pi)
      if t_eval <= g_value {
        continue
      }
      let att = fitted.coef_at(gi, pi)
      let se = fitted.se_at(gi, pi)
      let lo = att - 1.96 * se
      let hi = att + 1.96 * se
      let covered = lo <= theta0 && theta0 <= hi
      println(
        "  (g=\{g_value}, t=\{t_eval}): ATT_hat=\{att}, se=\{se}, 95% CI=[\{lo}, \{hi}] covers=\{covered}",
      )
    }
  }
}
