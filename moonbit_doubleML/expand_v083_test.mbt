///|
// v0.83.0+: white-box tests for the memoize + vectorize expand
// to 5 additional estimators (DoubleMLCVAR, DoubleMLSSM,
// DoubleMLBLP, DoubleMLPLPR, DoubleMLLPLR).
//
// Coverage:
//   #1: cvar_enable_memoize_smoke -- CVAR with memoize ON,
//       two fits produce coef / se within 1e-10 (cache hit
//       path is byte-equivalent to fresh path).
//   #2: ssm_enable_memoize_smoke -- SSM with memoize ON,
//       two fits produce coef / se within 1e-10.
//   #3: blp_enable_memoize_smoke -- BLP with memoize ON,
//       two fits produce coef / se within 1e-10.
//   #4: plpr_enable_memoize_smoke -- PLPR with memoize ON,
//       two fits produce coef / se within 1e-10.
//   #5: lplr_enable_memoize_smoke -- LPLR with memoize ON,
//       two fits produce coef / se within 1e-10.
//   #6: cvar_vectorize_residual_smoke -- CVAR coef within
//       band of true theta (the v0.83.0+ vectorise pass must
//       preserve the post-fold residual formula byte-for-byte).
//   #7: ssm_vectorize_residual_smoke -- SSM coef within band
//       of true theta.

///|
test "cvar_enable_memoize_smoke" {
  // CVAR DGP: use the same IRM-style DGP that v0.50.0+
  // CVaR tests rely on (Bernoulli D, y = theta * D + g(X) +
  // noise). theta = 1.0 so the upper-tail q=0.5 quantile
  // estimator recovers approximately the treatment effect
  // on the treated subgroup.
  let n = 400
  let p = 3
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let rng = chacha8_rng(8301)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = (rng.double() - 0.5) * 2.0
    }
  }
  let x = Matrix::from_array(x_flat, n, p)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let score = 0.5 * x_flat[i * p + 1] - 0.3 * x_flat[i * p + 2]
    let pd = 1.0 / (1.0 + @math.exp(-score))
    d[i] = if rng.double() < pd { 1.0 } else { 0.0 }
    y[i] = 1.0 * d[i] + 0.5 * x_flat[i * p + 1] + (rng.double() - 0.5) * 0.4
  }
  let data = DoubleMLData::new(x, y, d)
  let cvar = DoubleMLCVAR::new(
    data,
    quantile=0.5,
    n_folds=2,
    n_rep=1,
    seed=8301,
  ).enable_memoize()
  // First fit populates the cache.
  let fit1 = cvar.fit()
  inspect(fit1.has_cache(), content="true")
  // Second fit: cache hit (same seed / data / learners /
  // propensity clip / quantile).
  //
  // v0.99.0 fix: this MUST be `fit1.fit()`, not `cvar.fit()`.
  // `fit` takes `self` by value and RETURNS a new estimator, so
  // the cache writeback lands on `fit1` only. Re-fitting the
  // original `cvar` re-reads its own (empty) cache, so the
  // "cache hit" branch was never entered and the assertion
  // below was comparing fresh-vs-fresh. `fit1` is the only
  // value in scope that holds a populated cache.
  let fit2 = fit1.fit()
  inspect(fit2.has_cache(), content="true")
  // Both fits must agree to 1e-10 -- the cache-hit path is
  // byte-equivalent to the fresh cross-fit path.
  let d_coef = (fit1.coef() - fit2.coef()).abs()
  let d_se = (fit1.se() - fit2.se()).abs()
  inspect(d_coef < 1.0e-10, content="true")
  inspect(d_se < 1.0e-10, content="true")
}

///|
test "ssm_enable_memoize_smoke" {
  // SSM DGP via `make_ssm_data`: theta = 1.0, n = 200,
  // dim_x = 4. The selection indicator `s` is binary;
  // outcome is observed on the latent scale (matches the
  // DGP convention).
  let dgp = make_ssm_data(200, 4, 1.0, 8302)
  let data = DoubleMLSSMData::new(
    dgp.x_get(),
    dgp.y_get(),
    dgp.d_get(),
    dgp.s_get(),
  )
  let ssm = DoubleMLSSM::new(data, n_folds=2, n_rep=1, seed=8302).enable_memoize()
  let fit1 = ssm.fit()
  inspect(fit1.has_cache(), content="true")
  // v0.99.0: `fit1.fit()`, not `ssm.fit()` -- see the CVAR test
  // above for why the pre-fit value can never hit the cache.
  let fit2 = fit1.fit()
  inspect(fit2.has_cache(), content="true")
  // Both fits must agree to 1e-10 (SSM's cache-hit path
  // reuses the LAST rep's per-observation nuisances).
  let d_coef = (fit1.coef() - fit2.coef()).abs()
  let d_se = (fit1.se() - fit2.se()).abs()
  inspect(d_coef < 1.0e-10, content="true")
  inspect(d_se < 1.0e-10, content="true")
}

///|
test "blp_enable_memoize_smoke" {
  // BLP is a single-pass OLS projection (no n_folds / n_rep).
  // We use the synthetic linear-DGP that the rest of the BLP
  // tests rely on: basis[i, 0] = x, orth_signal = 2 + 3x
  // + small Gaussian noise. With memoize ON, two fits must
  // produce byte-identical coef / se.
  let n = 200
  let p = 1
  let basis = Matrix::zeros(n, p)
  let orth : Array[Double] = Array::make(n, 0.0)
  let rng = chacha8_rng(8303)
  for i = 0; i < n; i = i + 1 {
    let x = (i.to_double() - 100.0) / 100.0
    basis.set(i, 0, x)
    let noise = 0.05 * (rng.double() - 0.5)
    orth[i] = 2.0 + 3.0 * x + noise
  }
  let blp = DoubleMLBLP::new(basis, orth, cov_type="HC0").enable_memoize()
  let fit1 = blp.fit()
  inspect(fit1.has_cache(), content="true")
  // v0.99.0: `fit1.fit()` -- BLP's cache carries
  // `(coef, s, rss, var_y, residuals)`, all of which are written
  // back onto the value `fit` returns.
  let fit2 = fit1.fit()
  inspect(fit2.has_cache(), content="true")
  // Both fits must agree to 1e-10 (BLP's cache-hit path
  // reuses the cached OLS projection byte-for-byte).
  let c1 = fit1.coef()
  let c2 = fit2.coef()
  let s1 = fit1.se()
  let s2 = fit2.se()
  for k = 0; k < c1.length(); k = k + 1 {
    let d_c = (c1[k] - c2[k]).abs()
    inspect(d_c < 1.0e-10, content="true")
    let d_s = (s1[k] - s2[k]).abs()
    inspect(d_s < 1.0e-10, content="true")
  }
}

///|
test "plpr_enable_memoize_smoke" {
  // PLPR panel DGP via `make_plpr_CP2025`: theta = 1.0,
  // n_obs = 800, dim_x = 3. Wrap into a
  // `DoubleMLPanelData` with the standard (t, id) layout
  // matching the v0.75.0 wbtest pattern.
  let dgp = make_plpr_CP2025(800, 3, 1.0, 8304)
  let y = dgp.y_get()
  let d = dgp.d_get()
  let t_arr : Array[Int] = Array::make(y.length(), 0)
  let id_arr : Array[Int] = Array::make(y.length(), 0)
  let n_periods = dgp.n_periods_get()
  let mut idx = 0
  for u = 0; u < dgp.n_units_get(); u = u + 1 {
    for p = 0; p < n_periods; p = p + 1 {
      t_arr[idx] = p
      id_arr[idx] = u
      idx = idx + 1
    }
  }
  let panel = DoubleMLPanelData::new(dgp.x_get(), y, d, t_arr, id_arr)
  let plpr = DoubleMLPLPR::new(
    panel,
    approach="fd_exact",
    score="partialling out",
    n_folds=2,
    n_rep=1,
    seed=8304,
  ).enable_memoize()
  let fit1 = plpr.fit()
  inspect(fit1.has_cache(), content="true")
  // v0.99.0: `fit1.fit()` -- see the CVAR test for the reason.
  let fit2 = fit1.fit()
  inspect(fit2.has_cache(), content="true")
  // Both fits must agree to 1e-10 (PLPR's cache-hit path
  // reuses the LAST rep's `(l_pred, m_pred, g_pred)` +
  // row-to-fold mapping; the cluster-robust SE pipeline
  // re-runs from cached values).
  let d_coef = (fit1.coef() - fit2.coef()).abs()
  let d_se = (fit1.se() - fit2.se()).abs()
  inspect(d_coef < 1.0e-10, content="true")
  inspect(d_se < 1.0e-10, content="true")
}

///|
test "lplr_enable_memoize_smoke" {
  // LPLR LZZ2020 DGP via `make_lplr_LZZ2020`: alpha = 0.5,
  // n = 200 (slightly smaller than the standard 500 to keep
  // tests fast).
  let dgp = make_lplr_LZZ2020(200, 0.5, 8305)
  let lplr = DoubleMLLPLR::new(
    dgp.data_get(),
    n_folds=2,
    n_folds_inner=2,
    n_rep=1,
    seed=8305,
  ).enable_memoize()
  let fit1 = lplr.fit()
  inspect(fit1.has_cache(), content="true")
  // v0.99.0: `fit1.fit()` -- see the CVAR test for the reason.
  let fit2 = fit1.fit()
  inspect(fit2.has_cache(), content="true")
  // Both fits must agree to 1e-10 (LPLR's cache-hit path
  // reuses the LAST rep's `(t_pred, m_pred, a_pred)` plus
  // `beta_start`; the Newton / score / SE pipeline re-runs
  // from cached values).
  let d_coef = (fit1.coef() - fit2.coef()).abs()
  let d_se = (fit1.se() - fit2.se()).abs()
  inspect(d_coef < 1.0e-10, content="true")
  inspect(d_se < 1.0e-10, content="true")
}

///|
test "cvar_vectorize_residual_smoke" {
  // Sanity check that the v0.83.0+ vectorise pass on CVAR's
  // post-fold residual loops still recovers a sensible causal
  // parameter on a CVaR-friendly DGP. The CVaR upper-tail
  // quantile estimator at q=0.5 should land within a few SEs
  // of the true treatment effect (=1.0).
  let n = 400
  let p = 3
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let rng = chacha8_rng(8306)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = (rng.double() - 0.5) * 2.0
    }
  }
  let x = Matrix::from_array(x_flat, n, p)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let score = 0.5 * x_flat[i * p + 1] - 0.3 * x_flat[i * p + 2]
    let pd = 1.0 / (1.0 + @math.exp(-score))
    d[i] = if rng.double() < pd { 1.0 } else { 0.0 }
    y[i] = 1.0 * d[i] + 0.5 * x_flat[i * p + 1] + (rng.double() - 0.5) * 0.4
  }
  let data = DoubleMLData::new(x, y, d)
  // Default (memoize OFF) path -- exercises the new vectorised
  // residual loops on a fresh cross-fit.
  let fitted = DoubleMLCVAR::new(data, quantile=0.5, n_folds=2, seed=8306).fit()
  let theta_hat = fitted.coef()
  // Within 3 SEs of true theta = 1.0 + absolute fallback.
  let err = (theta_hat - 1.0).abs()
  let tol = 3.0 * fitted.se() + 0.5
  inspect(err <= tol, content="true")
  // And the SE itself should be finite / positive.
  inspect(fitted.se().is_nan() == false, content="true")
  inspect(fitted.se() > 0.0, content="true")
}

///|
test "ssm_vectorize_residual_smoke" {
  // Sanity check that the v0.83.0+ vectorise pass on SSM's
  // psi_a / psi_b computation still recovers the true causal
  // parameter (=1.0) on the SSM DGP.
  let dgp = make_ssm_data(400, 4, 1.0, 8307)
  let data = DoubleMLSSMData::new(
    dgp.x_get(),
    dgp.y_get(),
    dgp.d_get(),
    dgp.s_get(),
  )
  // Default (memoize OFF) path -- exercises the new
  // vectorised psi_b loop on a fresh cross-fit.
  let fitted = DoubleMLSSM::new(data, n_folds=2, seed=8307).fit()
  let theta_hat = fitted.coef()
  // SSM is high-variance on small n; allow a wide band
  // (3 SEs + 0.5 absolute).
  let err = (theta_hat - 1.0).abs()
  let tol = 3.0 * fitted.se() + 0.5
  inspect(err <= tol, content="true")
  inspect(fitted.se().is_nan() == false, content="true")
  inspect(fitted.se() > 0.0, content="true")
}
