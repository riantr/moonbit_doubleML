// dgp_ssm_test.mbt
//
// Tests for the SSM DGP.

///|
test "SSM_returns_correct_shapes" {
  let data = make_ssm_data(500, 20, 0.5, 3141)
  let m = data.x_get()
  inspect(m.rows() == 500, content="true")
  inspect(m.cols() == 20, content="true")
  inspect(data.y_get().length() == 500, content="true")
  inspect(data.d_get().length() == 500, content="true")
  inspect(data.s_get().length() == 500, content="true")
  inspect(data.theta_get() == 0.5, content="true")
}

///|
test "SSM_d_and_s_are_binary" {
  let data = make_ssm_data(500, 20, 0.5, 3141)
  let d = data.d_get()
  let s = data.s_get()
  for i = 0; i < d.length(); i = i + 1 {
    let v_d = d[i]
    let v_s = s[i]
    inspect(v_d == 0.0 || v_d == 1.0, content="true")
    inspect(v_s == 0.0 || v_s == 1.0, content="true")
  }
}

///|
test "SSM_deterministic_in_seed" {
  let a = make_ssm_data(200, 10, 0.7, 42)
  let b = make_ssm_data(200, 10, 0.7, 42)
  let ya = a.y_get()
  let da = a.d_get()
  let sa = a.s_get()
  let yb = b.y_get()
  let db = b.d_get()
  let sb = b.s_get()
  for i = 0; i < ya.length(); i = i + 1 {
    inspect(ya[i] == yb[i], content="true")
    inspect(da[i] == db[i], content="true")
    inspect(sa[i] == sb[i], content="true")
  }
}

///|
test "SSM_d_and_s_variation" {
  let data = make_ssm_data(500, 20, 0.5, 3141)
  let d = data.d_get()
  let s = data.s_get()
  let mut n_d_pos = 0
  let mut n_s_pos = 0
  for i = 0; i < d.length(); i = i + 1 {
    if d[i] == 1.0 {
      n_d_pos = n_d_pos + 1
    }
    if s[i] == 1.0 {
      n_s_pos = n_s_pos + 1
    }
  }
  inspect(n_d_pos > 0, content="true")
  inspect(n_d_pos < 500, content="true")
  inspect(n_s_pos > 0, content="true")
  inspect(n_s_pos < 500, content="true")
}
