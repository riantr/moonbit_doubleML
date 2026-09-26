// dgp_plpr_test.mbt

///|
test "PLPR_returns_correct_shapes" {
  let data = make_plpr_CP2025(800, 3, 1.0, 3141)
  let y = data.y_get()
  inspect(y.length() > 0, content="true")
  inspect(data.y_get().length() == data.d_get().length(), content="true")
  inspect(data.x_get().rows() == y.length(), content="true")
  inspect(data.x_get().cols() == 3, content="true")
  inspect(data.n_periods_get() == 4, content="true")
  inspect(data.theta_get() == 1.0, content="true")
}

///|
test "PLPR_deterministic_in_seed" {
  let a = make_plpr_CP2025(800, 3, 1.0, 42)
  let b = make_plpr_CP2025(800, 3, 1.0, 42)
  let ya = a.y_get()
  let da = a.d_get()
  let yb = b.y_get()
  let db = b.d_get()
  for i = 0; i < ya.length(); i = i + 1 {
    inspect(ya[i] == yb[i], content="true")
    inspect(da[i] == db[i], content="true")
  }
}

///|
test "PLPR_values_finite" {
  let data = make_plpr_CP2025(800, 3, 1.0, 3141)
  let y = data.y_get()
  for i = 0; i < y.length(); i = i + 1 {
    inspect(y[i] == y[i], content="true")
  }
}
