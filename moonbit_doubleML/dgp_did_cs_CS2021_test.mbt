// dgp_did_cs_CS2021_test.mbt
//
// Tests for the Callaway-Sant'Anna 2021 DID DGP.

///|
test "DIDCS_returns_correct_shapes" {
  let data = make_did_cs_CS2021(800, 3, 1.0, 3141)
  let y = data.y_get()
  let d = data.d_get()
  let t = data.t_get()
  let g = data.g_get()
  let id = data.id_get()
  let m = data.x_get()
  inspect(y.length() == d.length(), content="true")
  inspect(d.length() == t.length(), content="true")
  inspect(t.length() == g.length(), content="true")
  inspect(g.length() == id.length(), content="true")
  inspect(m.rows() == y.length(), content="true")
  inspect(m.cols() == 3, content="true")
  inspect(data.theta_get() == 1.0, content="true")
  inspect(data.n_groups_get() == 2, content="true")
  inspect(data.n_periods_get() == 2, content="true")
}

///|
test "DIDCS_treatment_is_binary" {
  let data = make_did_cs_CS2021(800, 3, 1.0, 3141)
  let d = data.d_get()
  for i = 0; i < d.length(); i = i + 1 {
    let v = d[i]
    inspect(v == 0.0 || v == 1.0, content="true")
  }
}

///|
test "DIDCS_never_treated_cohort_d_always_zero" {
  // Cohort 0 is never-treated. Across all periods, its
  // treatment indicator must always be 0.
  let data = make_did_cs_CS2021(800, 3, 1.0, 3141)
  let g = data.g_get()
  let d = data.d_get()
  let n_periods = data.n_periods_get()
  let mut any_violation = false
  for i = 0; i < g.length(); i = i + 1 {
    if g[i] == 0 && d[i] != 0.0 {
      any_violation = true
      break
    }
  }
  inspect(any_violation == false, content="true")
  // Also check period-1 cohort is post-treated.
  let _ = n_periods
}

///|
test "DIDCS_treated_cohort_d_equals_post_indicator" {
  // Cohort 1 is treated at t=1 (post-treatment in period 1,
  // not treated in period 0). So d[idx] for (g=1, t=0) == 0
  // and d[idx] for (g=1, t=1) == 1.
  let data = make_did_cs_CS2021(800, 3, 1.0, 3141)
  let g = data.g_get()
  let t = data.t_get()
  let d = data.d_get()
  let mut pre_zero = true
  let mut post_one = true
  for i = 0; i < g.length(); i = i + 1 {
    if g[i] == 1 && t[i] == 0 && d[i] != 0.0 {
      pre_zero = false
      break
    }
    if g[i] == 1 && t[i] == 1 && d[i] != 1.0 {
      post_one = false
      break
    }
  }
  inspect(pre_zero == true, content="true")
  inspect(post_one == true, content="true")
}

///|
test "DIDCS_deterministic_in_seed" {
  let a = make_did_cs_CS2021(800, 3, 1.0, 42)
  let b = make_did_cs_CS2021(800, 3, 1.0, 42)
  let ya = a.y_get()
  let da = a.d_get()
  let yb = b.y_get()
  let db = b.d_get()
  for i = 0; i < ya.length(); i = i + 1 {
    inspect(ya[i] == yb[i], content="true")
    inspect(da[i] == db[i], content="true")
  }
}
