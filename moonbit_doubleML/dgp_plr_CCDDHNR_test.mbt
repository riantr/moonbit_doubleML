// dgp_plr_CCDDHNR_test.mbt
//
// Tests for the Chernozhukov et al. (2018) Figure 1 PLR DGP, fitted
// via DoubleMLPLR::fit().

///|
test "PLR_CCDDHNR_returns_correct_shapes" {
  let data = make_plr_CCDDHNR2018(500, 20, 0.5, 3141)
  let m = data.x_get()
  inspect(m.rows() == 500, content="true")
  inspect(m.cols() == 20, content="true")
  inspect(data.y_get().length() == 500, content="true")
  inspect(data.d_get().length() == 500, content="true")
  inspect(data.theta_get() == 0.5, content="true")
}

///|
test "PLR_CCDDHNR_values_finite" {
  let data = make_plr_CCDDHNR2018(500, 20, 0.5, 3141)
  let m = data.x_get()
  for i = 0; i < m.rows(); i = i + 1 {
    for j = 0; j < m.cols(); j = j + 1 {
      let v = m.get(i, j)
      inspect(v == v, content="true")
    }
  }
  let y = data.y_get()
  let d = data.d_get()
  for i = 0; i < y.length(); i = i + 1 {
    inspect(y[i] == y[i], content="true")
    inspect(d[i] == d[i], content="true")
  }
}

///|
test "PLR_CCDDHNR_deterministic_in_seed" {
  let a = make_plr_CCDDHNR2018(200, 10, 0.7, 42)
  let b = make_plr_CCDDHNR2018(200, 10, 0.7, 42)
  let ma = a.x_get()
  let mb = b.x_get()
  for i = 0; i < ma.rows(); i = i + 1 {
    for j = 0; j < ma.cols(); j = j + 1 {
      inspect(ma.get(i, j) == mb.get(i, j), content="true")
    }
  }
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
test "PLR_CCDDHNR_different_seeds_differ" {
  let a = make_plr_CCDDHNR2018(200, 10, 0.7, 1)
  let b = make_plr_CCDDHNR2018(200, 10, 0.7, 2)
  let ma = a.x_get()
  let mb = b.x_get()
  let mut differs = false
  let mut i = 0
  while i < ma.rows() {
    if differs {
      break
    }
    let mut j = 0
    while j < ma.cols() {
      if ma.get(i, j) != mb.get(i, j) {
        differs = true
        break
      }
      j = j + 1
    }
    i = i + 1
  }
  inspect(differs == true, content="true")
}

///|
test "PLR_CCDDHNR_estimator_recovers_true_theta" {
  let data = make_plr_CCDDHNR2018(5000, 20, 0.5, 3141)
  let dml_data = DoubleMLData::new(data.x_get(), data.y_get(), data.d_get())
  let plr = DoubleMLPLR::new(dml_data, n_folds=2, n_rep=1, seed=3141)
  let fit = plr.fit()
  let theta_hat = fit.coef()
  let se = fit.se()
  let err = (theta_hat - 0.5).abs()
  let tol = 10.0 * se
  inspect(err < tol, content="true")
}

///|
test "PLR_CCDDHNR_confint_well_formed" {
  let data = make_plr_CCDDHNR2018(5000, 20, 0.5, 3141)
  let dml_data = DoubleMLData::new(data.x_get(), data.y_get(), data.d_get())
  let plr = DoubleMLPLR::new(dml_data, n_folds=2, n_rep=1, seed=3141)
  let fit = plr.fit()
  let (lo, hi) = fit.confint()
  inspect(lo < hi, content="true")
}
