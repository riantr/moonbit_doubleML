// dgp_iivm_test.mbt
//
// Tests for the Chernozhukov et al. (2018) IIVM DGP.

///|
test "IIVM_returns_correct_shapes" {
  let data = make_iivm_data(500, 20, 1.0, 3141)
  let m = data.x_get()
  inspect(m.rows() == 500, content="true")
  inspect(m.cols() == 20, content="true")
  inspect(data.y_get().length() == 500, content="true")
  inspect(data.d_get().length() == 500, content="true")
  inspect(data.z_get().length() == 500, content="true")
  inspect(data.theta_get() == 1.0, content="true")
}

///|
test "IIVM_d_and_z_are_binary" {
  let data = make_iivm_data(500, 20, 1.0, 3141)
  let d = data.d_get()
  let z = data.z_get()
  for i = 0; i < d.length(); i = i + 1 {
    let v_d = d[i]
    let v_z = z[i]
    inspect((v_d == 0.0) || (v_d == 1.0), content="true")
    inspect((v_z == 0.0) || (v_z == 1.0), content="true")
  }
}

///|
test "IIVM_instrument_variation" {
  let data = make_iivm_data(500, 20, 1.0, 3141)
  let z = data.z_get()
  let mut n_pos = 0
  for i = 0; i < z.length(); i = i + 1 {
    if z[i] == 1.0 {
      n_pos = n_pos + 1
    }
  }
  inspect(n_pos > 0, content="true")
  inspect(n_pos < 500, content="true")
}

///|
test "IIVM_deterministic_in_seed" {
  let a = make_iivm_data(200, 10, 1.0, 42)
  let b = make_iivm_data(200, 10, 1.0, 42)
  let da = a.d_get()
  let za = a.z_get()
  let ya = a.y_get()
  let db = b.d_get()
  let zb = b.z_get()
  let yb = b.y_get()
  for i = 0; i < da.length(); i = i + 1 {
    inspect(da[i] == db[i], content="true")
    inspect(za[i] == zb[i], content="true")
    inspect(ya[i] == yb[i], content="true")
  }
}

///|
test "IIVM_values_finite" {
  let data = make_iivm_data(500, 20, 1.0, 3141)
  let m = data.x_get()
  for i = 0; i < m.rows(); i = i + 1 {
    for j = 0; j < m.cols(); j = j + 1 {
      let v = m.get(i, j)
      inspect(v == v, content="true")
    }
  }
  let y = data.y_get()
  for i = 0; i < y.length(); i = i + 1 {
    inspect(y[i] == y[i], content="true")
  }
}