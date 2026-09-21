// dgp_irm_heterogeneous_test.mbt

///|
test "IRMHeterogeneous_returns_correct_shapes" {
  let data = make_irm_heterogeneous_data(500, 20, 3141)
  let m = data.x_get()
  inspect(m.rows() == 500, content="true")
  inspect(m.cols() == 20, content="true")
  inspect(data.y_get().length() == 500, content="true")
  inspect(data.d_get().length() == 500, content="true")
}

///|
test "IRMHeterogeneous_ate_near_0_5" {
  // The ATE is E[theta_i] = 0.5 + 0.25 * E[X_1] = 0.5
  // (X_1 has mean 0 under N(0, Sigma)).
  let data = make_irm_heterogeneous_data(5000, 20, 3141)
  let theta = data.theta_get()
  // With 5000 obs, sample mean should be within 0.05 of 0.5.
  inspect((theta - 0.5).abs() < 0.05, content="true")
}

///|
test "IRMHeterogeneous_deterministic_in_seed" {
  let a = make_irm_heterogeneous_data(200, 10, 42)
  let b = make_irm_heterogeneous_data(200, 10, 42)
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
test "IRMHeterogeneous_estimator_recovers_ate" {
  let data = make_irm_heterogeneous_data(5000, 20, 3141)
  let dml_data = DoubleMLData::new(
    data.x_get(), data.y_get(), data.d_get(),
  )
  let irm = DoubleMLIRM::new(
    dml_data, n_folds=2, n_rep=1, seed=3141,
  )
  let fit = irm.fit()
  let theta_hat = fit.coef()
  let se = fit.se()
  // theta_hat should be within 10 SE of true ATE = 0.5.
  let err = (theta_hat - 0.5).abs()
  let tol = 10.0 * se
  inspect(err < tol, content="true")
}