// dgp_plr_turrell_test.mbt

///|
test "PLRTurrell_returns_correct_shapes" {
  let data = make_plr_turrell2018(500, 0.5, 3141)
  let m = data.x_get()
  inspect(m.rows() == 500, content="true")
  inspect(m.cols() == 20, content="true")
  inspect(data.y_get().length() == 500, content="true")
  inspect(data.d_get().length() == 500, content="true")
}

///|
test "PLRTurrell_d_is_binary" {
  let data = make_plr_turrell2018(500, 0.5, 3141)
  let d = data.d_get()
  for i = 0; i < d.length(); i = i + 1 {
    let v = d[i]
    inspect(v == 0.0 || v == 1.0, content="true")
  }
}

///|
test "PLRTurrell_deterministic_in_seed" {
  let a = make_plr_turrell2018(200, 0.5, 42)
  let b = make_plr_turrell2018(200, 0.5, 42)
  let ya = a.y_get()
  let da = a.d_get()
  let yb = b.y_get()
  let db = b.d_get()
  for i = 0; i < ya.length(); i = i + 1 {
    inspect(ya[i] == yb[i], content="true")
    inspect(da[i] == db[i], content="true")
  }
}
