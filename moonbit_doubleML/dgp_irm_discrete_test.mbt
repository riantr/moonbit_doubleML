// dgp_irm_discrete_test.mbt

///|
test "IRMDiscrete_returns_correct_shapes" {
  let data = make_irm_discrete_treatments(500, 20, 0.5, 3141)
  let m = data.x_get()
  inspect(m.rows() == 500, content="true")
  inspect(m.cols() == 20, content="true")
  inspect(data.y_get().length() == 500, content="true")
  inspect(data.d_get().length() == 500, content="true")
  inspect(data.theta_get() == 0.5, content="true")
}

///|
test "IRMDiscrete_d_in_set" {
  let data = make_irm_discrete_treatments(500, 20, 0.5, 3141)
  let d = data.d_get()
  for i = 0; i < d.length(); i = i + 1 {
    let v = d[i]
    inspect(v == 0.0 || v == 1.0 || v == 2.0 || v == 3.0, content="true")
  }
}

///|
test "IRMDiscrete_deterministic_in_seed" {
  let a = make_irm_discrete_treatments(200, 10, 0.5, 42)
  let b = make_irm_discrete_treatments(200, 10, 0.5, 42)
  let ya = a.y_get()
  let da = a.d_get()
  let yb = b.y_get()
  let db = b.d_get()
  for i = 0; i < ya.length(); i = i + 1 {
    inspect(ya[i] == yb[i], content="true")
    inspect(da[i] == db[i], content="true")
  }
}
