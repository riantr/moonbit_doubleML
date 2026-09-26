// dgp_did_SZ2020_test.mbt

///|
test "DIDSZ_returns_correct_shapes" {
  let data = make_did_SZ2020(800, 3, 1.0, 3141)
  let y = data.y_get()
  inspect(y.length() > 0, content="true")
  inspect(data.y_get().length() == data.d_get().length(), content="true")
  inspect(data.g_get().length() == data.t_get().length(), content="true")
  inspect(data.n_groups_get() == 2, content="true")
  inspect(data.n_periods_get() == 2, content="true")
}

///|
test "DIDSZ_never_treated_d_always_zero" {
  let data = make_did_SZ2020(800, 3, 1.0, 3141)
  let g = data.g_get()
  let d = data.d_get()
  let mut any_violation = false
  for i = 0; i < g.length(); i = i + 1 {
    if g[i] == 0 && d[i] != 0.0 {
      any_violation = true
      break
    }
  }
  inspect(any_violation == false, content="true")
}

///|
test "DIDSZ_treated_cohort_d_equals_post_indicator" {
  let data = make_did_SZ2020(800, 3, 1.0, 3141)
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
test "DIDSZ_deterministic_in_seed" {
  let a = make_did_SZ2020(800, 3, 1.0, 42)
  let b = make_did_SZ2020(800, 3, 1.0, 42)
  let ya = a.y_get()
  let da = a.d_get()
  let yb = b.y_get()
  let db = b.d_get()
  for i = 0; i < ya.length(); i = i + 1 {
    inspect(ya[i] == yb[i], content="true")
    inspect(da[i] == db[i], content="true")
  }
}
