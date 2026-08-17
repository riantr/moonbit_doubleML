// Demo: DoubleMLDIDMulti end-to-end on a 4-cohort × 4-period
// staggered panel. True ATT = 1.0 for every post-treatment
// (g, t) cell. After `fit`, the per-(g, t) ATT matrix is
// aggregated by group, time, and event-time.

///|
fn main {
  let n_per_cohort = 60
  let p = 3
  let theta0 = 1.0
  let n_periods = 4
  let cohort_count = 4 // g = 0, 1, 2, 3
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  let rng = @dml.chacha8_rng(11)
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
  let data = @dml.DoubleMLDIDCSData::new(
    @dml.Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
  let fitted = @dml.DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  println(
    "=== MoonBit DML demo: DoubleMLDIDMulti (n_units=\{n_units}, p=\{p}, true ATT=\{theta0}) ===",
  )
  println("n_combinations = \{fitted.n_combinations()}")
  println("")
  println("--- Per-(g, t) ATT matrix ---")
  for i = 0; i < fitted.n_combinations(); i = i + 1 {
    let att = fitted.coef_at_idx(i)
    let se = fitted.se_at_idx(i)
    let lo = att - 1.96 * se
    let hi = att + 1.96 * se
    let covered = lo <= theta0 && theta0 <= hi
    println(
      "  combo \{i}: ATT_hat=\{att}, se=\{se}, 95% CI=[\{lo}, \{hi}] covers=\{covered}",
    )
  }
  println("")
  println("--- Aggregation by group ---")
  let g_agg = fitted.aggregate_group()
  for i = 0; i < g_agg.theta.length(); i = i + 1 {
    let g_name = g_agg.agg_names[i]
    let att = g_agg.theta[i]
    let se = g_agg.se[i]
    println("  g=\{g_name}: ATT_hat=\{att}, se=\{se}")
  }
  println("")
  println("--- Aggregation by time period ---")
  let t_agg = fitted.aggregate_time()
  for i = 0; i < t_agg.theta.length(); i = i + 1 {
    let t_name = t_agg.agg_names[i]
    let att = t_agg.theta[i]
    let se = t_agg.se[i]
    println("  t=\{t_name}: ATT_hat=\{att}, se=\{se}")
  }
  println("")
  println("--- Event-study aggregation (post-treatment only) ---")
  let e_agg = fitted.aggregate_event()
  for i = 0; i < e_agg.theta.length(); i = i + 1 {
    let e_name = e_agg.agg_names[i]
    let att = e_agg.theta[i]
    let se = e_agg.se[i]
    println("  e=\{e_name}: ATT_hat=\{att}, se=\{se}")
  }
}
