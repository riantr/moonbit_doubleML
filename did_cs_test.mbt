///|
/// End-to-end Callaway-Sant'Anna staggered DID on a multi-cohort
/// panel. Three treatment groups (g=1, 2, 3) plus a never-treated
/// cohort (g=0). The true ATT = 1.0 is added to every treated unit's
/// post-treatment period (t > g). For every (g, t_eval) cell with
/// t_eval > g, the CS-DID estimate should be close to 1.0 (within a
/// few SE).
test "did_cs_recovers_known_att_per_cell" {
  // Panel: n_units per cohort, 4 periods (t = 0, 1, 2, 3).
  let n_per_cohort = 50
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
  let bytes = seed_to_bytes(11)
  let rng = @random.Rand::chacha8(seed=Bytes::from_array(bytes))
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
  let data = DoubleMLDIDCSData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
  let fitted = DoubleMLDIDCS::new(
    data,
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  // n_groups = 3 (g = 1, 2, 3), n_periods = 4.
  inspect(fitted.n_groups(), content="3")
  inspect(fitted.n_periods(), content="4")
  // Group values: 1, 2, 3 (sorted ascending).
  inspect(fitted.group_at(0), content="1")
  inspect(fitted.group_at(1), content="2")
  inspect(fitted.group_at(2), content="3")
  // Period values: 0, 1, 2, 3.
  inspect(fitted.period_at(0), content="0")
  inspect(fitted.period_at(3), content="3")
  // For each (g, t) cell with t > g, the ATT should be close to 1.0.
  // 3 cells total: (1,2), (1,3), (2,3).
  let mut recovered = 0
  let mut checked = 0
  for gi = 0; gi < fitted.n_groups(); gi = gi + 1 {
    let g_value = fitted.group_at(gi)
    for pi = 0; pi < fitted.n_periods(); pi = pi + 1 {
      let t_eval = fitted.period_at(pi)
      if t_eval <= g_value {
        continue
      }
      checked = checked + 1
      let att = fitted.coef_at(gi, pi)
      let se = fitted.se_at(gi, pi)
      // ATT should be finite (NaN != NaN) and within ~0.5 of true.
      inspect(att == att && att.abs() < 1.0e10, content="true")
      inspect(se > 0.0, content="true")
      if (att - theta0).abs() < 0.5 {
        recovered = recovered + 1
      }
    }
  }
  inspect(checked >= 3, content="true")
  inspect(recovered, content="\{checked}")
}

///|
/// Pre-treatment cells (t_eval <= g) should remain at 0.0 (no
/// estimate; CS-DID does not define pre-treatment effects).
test "did_cs_pre_treatment_cells_remain_zero" {
  let n_per_cohort = 40
  let p = 2
  let n_periods = 4
  let cohort_count = 2 // g = 0 (control), g = 1 (treated at t=1)
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  for u = 0; u < n_units; u = u + 1 {
    let cohort = u / n_per_cohort
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = cohort
      d[row] = if cohort > 0 && k >= cohort { 1.0 } else { 0.0 }
      y[row] = (k + cohort).to_double()
    }
  }
  let data = DoubleMLDIDCSData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
  let fitted = DoubleMLDIDCS::new(data, n_folds=2, seed=3141).fit()
  // For g = 1, t_eval = 0, 1 are pre-treatment. coef_at(0, 0)
  // and coef_at(0, 1) should remain 0.0.
  inspect(fitted.coef_at(0, 0), content="0")
  inspect(fitted.coef_at(0, 1), content="0")
  inspect(fitted.se_at(0, 0), content="0")
  inspect(fitted.se_at(0, 1), content="0")
  // g = 1, t_eval = 2, 3 are post-treatment; should be filled.
  inspect(fitted.coef_at(0, 2) != 0.0, content="true")
  inspect(fitted.coef_at(0, 3) != 0.0, content="true")
}

///|
/// `discover_groups_times` should drop the never-treated sentinel
/// (min of g) from the groups list, but keep all unique time
/// indices including the sentinel.
test "did_cs_data_groups_excludes_never_treated" {
  let n = 6
  let p = 1
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
  let d : Array[Double] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
  let t_arr : Array[Int] = [0, 1, 2, 0, 1, 2]
  let g_arr : Array[Int] = [0, 0, 0, 2, 2, 2] // g=0 is never-treated; g=2 is treated
  let id_arr : Array[Int] = [0, 0, 0, 1, 1, 1]
  let data = DoubleMLDIDCSData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
  // groups = [2] (only the non-sentinel cohort).
  inspect(data.groups.length(), content="1")
  inspect(data.groups[0], content="2")
  // times = [0, 1, 2] (all unique periods observed).
  inspect(data.times.length(), content="3")
  inspect(data.times[0], content="0")
  inspect(data.times[1], content="1")
  inspect(data.times[2], content="2")
}

///|
/// d must be binary {0, 1}. `require` should abort otherwise.
test "panic_did_cs_data_rejects_non_binary_d" {
  let n = 2
  let p = 1
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = [0.0, 0.0]
  let d : Array[Double] = [0.0, 0.5] // not binary
  let t_arr : Array[Int] = [0, 1]
  let g_arr : Array[Int] = [0, 0]
  let id_arr : Array[Int] = [0, 0]
  let _ = DoubleMLDIDCSData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
}

///|
/// Constructor argument validation: only `"never_treated"` and
/// `"not_yet_treated"` are valid `control_group` values.
test "panic_did_cs_rejects_invalid_control_group" {
  let n = 2
  let p = 1
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = [0.0, 0.0]
  let d : Array[Double] = [0.0, 0.0]
  let t_arr : Array[Int] = [0, 1]
  let g_arr : Array[Int] = [0, 0]
  let id_arr : Array[Int] = [0, 0]
  let data = DoubleMLDIDCSData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
  let _ = DoubleMLDIDCS::new(data, control_group="bogus")
}
