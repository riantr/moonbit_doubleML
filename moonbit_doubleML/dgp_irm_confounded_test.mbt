// dgp_irm_confounded_test.mbt

///|
test "IRMConfounded_returns_correct_shapes" {
  let data = make_irm_confounded_data(500, 20, 0.5, 3141)
  let m = data.x_get()
  inspect(m.rows() == 500, content="true")
  inspect(m.cols() == 20, content="true")
  inspect(data.y_get().length() == 500, content="true")
  inspect(data.d_get().length() == 500, content="true")
  inspect(data.c_get().length() == 500, content="true")
  inspect(data.theta_get() == 0.5, content="true")
}

///|
test "IRMConfounded_c_and_d_are_binary" {
  let data = make_irm_confounded_data(500, 20, 0.5, 3141)
  let c = data.c_get()
  let d = data.d_get()
  for i = 0; i < c.length(); i = i + 1 {
    let v_c = c[i]
    let v_d = d[i]
    inspect((v_c == 0.0) || (v_c == 1.0), content="true")
    inspect((v_d == 0.0) || (v_d == 1.0), content="true")
  }
}

///|
test "IRMConfounded_deterministic_in_seed" {
  let a = make_irm_confounded_data(200, 10, 0.5, 42)
  let b = make_irm_confounded_data(200, 10, 0.5, 42)
  let ya = a.y_get()
  let da = a.d_get()
  let ca = a.c_get()
  let yb = b.y_get()
  let db = b.d_get()
  let cb = b.c_get()
  for i = 0; i < ya.length(); i = i + 1 {
    inspect(ya[i] == yb[i], content="true")
    inspect(da[i] == db[i], content="true")
    inspect(ca[i] == cb[i], content="true")
  }
}

///|
test "IRMConfounded_estimator_recovers_theta" {
  let data = make_irm_confounded_data(5000, 20, 0.5, 3141)
  let dml_data = DoubleMLData::new(
    data.x_get(), data.y_get(), data.d_get(),
  )
  let irm = DoubleMLIRM::new(
    dml_data, n_folds=2, n_rep=1, seed=3141,
  )
  let fit = irm.fit()
  let theta_hat = fit.coef()
  let se = fit.se()
  let err = (theta_hat - 0.5).abs()
  let tol = 10.0 * se
  inspect(err < tol, content="true")
}