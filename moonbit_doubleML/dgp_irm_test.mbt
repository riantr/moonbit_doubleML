// dgp_irm_test.mbt
//
// Tests for the Chernozhukov et al. (2018) IRM DGP, fitted via
// DoubleMLIRM::fit().

///|
test "IRM_returns_correct_shapes" {
  let data = make_irm_data(500, 20, 0.5, 3141)
  let m = data.x_get()
  inspect(m.rows() == 500, content="true")
  inspect(m.cols() == 20, content="true")
  inspect(data.y_get().length() == 500, content="true")
  inspect(data.d_get().length() == 500, content="true")
  inspect(data.theta_get() == 0.5, content="true")
}

///|
test "IRM_treatment_is_binary" {
  let data = make_irm_data(500, 20, 0.5, 3141)
  let d = data.d_get()
  for i = 0; i < d.length(); i = i + 1 {
    let v = d[i]
    inspect((v == 0.0) || (v == 1.0), content="true")
  }
}

///|
test "IRM_treatment_variation" {
  // With n=500 and balanced propensity, treatment should be a
  // mix of 0s and 1s (not all-zero / all-one).
  let data = make_irm_data(500, 20, 0.5, 3141)
  let d = data.d_get()
  let mut n_pos = 0
  for i = 0; i < d.length(); i = i + 1 {
    if d[i] == 1.0 {
      n_pos = n_pos + 1
    }
  }
  inspect(n_pos > 0, content="true")
  inspect(n_pos < 500, content="true")
}

///|
test "IRM_deterministic_in_seed" {
  let a = make_irm_data(200, 10, 0.7, 42)
  let b = make_irm_data(200, 10, 0.7, 42)
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
test "IRM_estimator_recovers_true_theta" {
  let data = make_irm_data(5000, 20, 0.5, 3141)
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

///|
test "IRM_confint_well_formed" {
  let data = make_irm_data(5000, 20, 0.5, 3141)
  let dml_data = DoubleMLData::new(
    data.x_get(), data.y_get(), data.d_get(),
  )
  let irm = DoubleMLIRM::new(
    dml_data, n_folds=2, n_rep=1, seed=3141,
  )
  let fit = irm.fit()
  let (lo, hi) = fit.confint()
  inspect(lo < hi, content="true")
}