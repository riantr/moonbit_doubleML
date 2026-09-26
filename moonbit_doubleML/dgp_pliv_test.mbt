// dgp_pliv_test.mbt
//
// Tests for the Chernozhukov-Hansen-Spindler 2015 PLIV DGP.

///|
test "PLIV_returns_correct_shapes" {
  let data = make_pliv_CHS2015(500, 20, 1.0, 3141)
  let m = data.x_get()
  inspect(m.rows() == 500, content="true")
  inspect(m.cols() == 20, content="true")
  inspect(data.y_get().length() == 500, content="true")
  inspect(data.d_get().length() == 500, content="true")
  inspect(data.z_get().length() == 500, content="true")
  inspect(data.theta_get() == 1.0, content="true")
}

///|
test "PLIV_d_and_z_are_binary" {
  let data = make_pliv_CHS2015(500, 20, 1.0, 3141)
  let d = data.d_get()
  let z = data.z_get()
  for i = 0; i < d.length(); i = i + 1 {
    let v_d = d[i]
    let v_z = z[i]
    inspect(v_d == 0.0 || v_d == 1.0, content="true")
    inspect(v_z == 0.0 || v_z == 1.0, content="true")
  }
}

///|
test "PLIV_deterministic_in_seed" {
  let a = make_pliv_CHS2015(200, 10, 1.0, 42)
  let b = make_pliv_CHS2015(200, 10, 1.0, 42)
  let ya = a.y_get()
  let da = a.d_get()
  let za = a.z_get()
  let yb = b.y_get()
  let db = b.d_get()
  let zb = b.z_get()
  for i = 0; i < ya.length(); i = i + 1 {
    inspect(ya[i] == yb[i], content="true")
    inspect(da[i] == db[i], content="true")
    inspect(za[i] == zb[i], content="true")
  }
}

///|
test "PLIV_values_finite" {
  let data = make_pliv_CHS2015(500, 20, 1.0, 3141)
  let y = data.y_get()
  for i = 0; i < y.length(); i = i + 1 {
    inspect(y[i] == y[i], content="true")
  }
}
