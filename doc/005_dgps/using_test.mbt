///|
test "doc/005_dgps/readme.mbt.md DGP factory usage pattern" {
  // The readme's "Usage pattern" section, executed: the DGP struct is
  // not a `DoubleMLData`, so it has to be wrapped first, and the
  // accessors `x_get()` / `y_get()` / `d_get()` are public on the
  // factory's return type -- `make_plr_CCDDHNR2018` is not opaque.
  let dgp = @moonbit_doubleML.make_plr_CCDDHNR2018(5000, 20, 0.5, 3141)
  // The design carries the true causal parameter.
  inspect(dgp.theta_get() == 0.5, content="true")
  // The accessors expose the generated sample.
  let x = dgp.x_get()
  inspect(x.rows() == 5000, content="true")
  inspect(x.cols() == 20, content="true")
  inspect(dgp.y_get().length() == 5000, content="true")
  inspect(dgp.d_get().length() == 5000, content="true")
  // The same randomness source the readme names is what the factory
  // draws from, and it is reproducible from the seed alone.
  let rng = @moonbit_doubleML.chacha8_rng(3141)
  ignore(rng)
  // Wrap, fit, and check the estimate recovers theta.
  let data = @moonbit_doubleML.DoubleMLData::new(
    dgp.x_get(),
    dgp.y_get(),
    dgp.d_get(),
  )
  let fitted = @moonbit_doubleML.DoubleMLPLR::new(
    data,
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  // Measured: coef = 0.4805230410998485 (true theta 0.5),
  // se = 0.014355641550069779 -- identical on native and wasm-gc.
  inspect((fitted.coef() - 0.5).abs() < 0.1, content="true")
  inspect(fitted.se() > 0.0 && fitted.se() < 1.0e300, content="true")
}
