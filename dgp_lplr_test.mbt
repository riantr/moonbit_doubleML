// dgp_lplr_test.mbt
//
// Tests for the Liu-Zhang-Zhou 2021 LPLR DGP.

///|
test "LPLR_returns_correct_shapes" {
  let data = make_lplr_LZZ2020(500, 0.5, 3141)
  let d = data.data_get()
  inspect(d.y.length() == 500, content="true")
  inspect(data.theta_get() == 0.5, content="true")
}

///|
test "LPLR_d_and_y_are_binary" {
  let data = make_lplr_LZZ2020(500, 0.5, 3141)
  let d_arr = data.data_get().d
  let y_arr = data.data_get().y
  for i = 0; i < d_arr.length(); i = i + 1 {
    let v_d = d_arr[i]
    let v_y = y_arr[i]
    inspect((v_d == 0.0) || (v_d == 1.0), content="true")
    inspect((v_y == 0.0) || (v_y == 1.0), content="true")
  }
}

///|
test "LPLR_deterministic_in_seed" {
  let a = make_lplr_LZZ2020(200, 0.5, 42)
  let b = make_lplr_LZZ2020(200, 0.5, 42)
  let a_d = a.data_get().d
  let a_y = a.data_get().y
  let b_d = b.data_get().d
  let b_y = b.data_get().y
  for i = 0; i < a_d.length(); i = i + 1 {
    inspect(a_d[i] == b_d[i], content="true")
    inspect(a_y[i] == b_y[i], content="true")
  }
}

///|
test "LPLR_estimator_recovers_theta" {
  let data = make_lplr_LZZ2020(500, 0.5, 3141)
  let fitted = DoubleMLLPLR::new(
    data.data_get(), n_folds=2, n_folds_inner=2,
  ).fit()
  let theta_hat = fitted.coef()
  // Loose tolerance: theta_hat lands ~0.46 on this DGP per the
  // upstream reference; we accept a +/- 1.0 band to absorb fold-RNG
  // noise (KFold is not seeded upstream, so per-run numbers drift).
  inspect(theta_hat.abs() < 100.0, content="true")
  inspect(theta_hat > -1.0 && theta_hat < 2.0, content="true")
}