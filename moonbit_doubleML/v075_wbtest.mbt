///|
// v0.75.0+: wbtests for the 4-item `bootstrap()` fill-in
// cycle. Closes the v0.64.0 bootstrap family: the 4
// estimators that previously lacked `bootstrap(...)` (PLPR,
// LPLR, RDD, CVaR) now expose the same
// `bootstrap(n_rep_boot?, method?, seed?, level?)` contract
// as the v0.61.0-v0.64.0 family.
//
// Each test:
//   1. Generates synthetic data + fit (small n to keep tests
//      fast; uses the canonical DGPs from dgp_plpr,
//      dgp_lplr, dgp_simple_rdd, and a CVaR-specific DGP
//      inline).
//   2. Calls `.bootstrap(n_rep_boot=200, method="Bayes",
//      seed=42)` (Bayes multiplier is a quick smoke check;
//      the IID multiplier default is exercised by the
//      existing v064_wbtest suite).
//   3. Asserts `boot_t_stat` length matches `n_rep_boot`,
//      `boot_method` / `n_rep_boot` / `boot_seed` round-trip,
//      and every entry is finite (no NaN, no Inf).
//
// The `assert_bootstrap_finite` helper is reused from
// `v064_wbtest.mbt` (same package).

// ---------------------------------------------------------------------------
// #1: PLPR bootstrap (single-theta, panel partialling-out)
// ---------------------------------------------------------------------------

///|
test "plpr_bootstrap_populates_boot_t_stat" {
  // Panel DGP: 16 units x 4 periods = 64 obs. theta = 1.0.
  // Use `cre_general` (smallest drop risk) and `n_folds=2`
  // for speed.
  let dgp = make_plpr_CP2025(64, 3, 1.0, 7501)
  let y = dgp.y_get()
  let d = dgp.d_get()
  let n = y.length()
  let t : Array[Int] = Array::makei(n, fn(i) { i % dgp.n_periods_get() })
  let id : Array[Int] = Array::makei(n, fn(i) { i / dgp.n_periods_get() })
  let panel = DoubleMLPanelData::new(dgp.x_get(), y, d, t, id)
  let fitted = DoubleMLPLPR::new(
    panel,
    approach="cre_general",
    n_folds=2,
    seed=7501,
  ).fit()
  let boot = fitted.bootstrap(n_rep_boot=200, method_name="Bayes", seed=42)
  assert_eq(boot.boot_method, "Bayes")
  assert_eq(boot.n_rep_boot, 200)
  assert_eq(boot.boot_seed, 42)
  assert_bootstrap_finite(boot.boot_t_stat, 200)
}

// ---------------------------------------------------------------------------
// #2: LPLR bootstrap (single-theta, simplified binary ATE)
// ---------------------------------------------------------------------------

///|
test "lplr_bootstrap_populates_boot_t_stat" {
  // LPLR LZZ2020 DGP, alpha = 0.5, n = 250 (slightly smaller
  // than the standard 500 to keep tests fast).
  let dgp = make_lplr_LZZ2020(250, 0.5, 7502)
  let fitted = DoubleMLLPLR::new(dgp.data_get(), n_folds=2, seed=7502).fit()
  let boot = fitted.bootstrap(n_rep_boot=200, method_name="Bayes", seed=42)
  assert_eq(boot.boot_method, "Bayes")
  assert_eq(boot.n_rep_boot, 200)
  assert_eq(boot.boot_seed, 42)
  assert_bootstrap_finite(boot.boot_t_stat, 200)
}

// ---------------------------------------------------------------------------
// #3: RDD bootstrap (kernel-weighted local-polynomial)
// ---------------------------------------------------------------------------

///|
test "rdd_bootstrap_populates_boot_t_stat" {
  // Inline RDD DGP (matches the rdd_test::rdd_sharp_local_linear
  // pattern). `make_simple_rdd_dgp` emits a *constant* score
  // (=1.0) which never falls inside the bandwidth; we use the
  // proper running-variable form here so `n_local > 0` and
  // the bootstrap has non-trivial IF.
  let n = 400
  let x_mat = Matrix::zeros(n, 1)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let score : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u = (i.to_double() + 0.5) / 200.0 - 1.0
    score[i] = u
    d[i] = if u >= 0.0 { 1.0 } else { 0.0 }
    // Sharp RDD jump of 1.0; outcome has a polynomial in u.
    y[i] = 0.5 * u * u + 1.0 * d[i]
  }
  let data = DoubleMLRDDData::new(x_mat, y, d, score)
  let fitted = DoubleMLRDD::new(data, bandwidth=0.8).fit()
  let boot = fitted.bootstrap(n_rep_boot=200, method_name="Bayes", seed=42)
  assert_eq(boot.boot_method, "Bayes")
  assert_eq(boot.n_rep_boot, 200)
  assert_eq(boot.boot_seed, 42)
  assert_bootstrap_finite(boot.boot_t_stat, 200)
}

// ---------------------------------------------------------------------------
// #4: CVaR bootstrap (IRM-style, single-theta)
// ---------------------------------------------------------------------------

///|
test "cvar_bootstrap_populates_boot_t_stat" {
  // Inline CVaR-friendly DGP (no canonical dgp_cvar.mbt
  // helper): n = 300, treatment ~ Bernoulli(0.5),
  // outcome = theta * D + g(X) + noise. theta = 1.0 so the
  // CVaR upper-tail at q=0.5 recovers roughly the same
  // treatment effect on the treated subgroup.
  let n = 300
  let p = 2
  let rng = chacha8_rng(7504)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double() * 2.0 - 1.0
    }
    d[i] = if rng.double() < 0.5 { 1.0 } else { 0.0 }
    let x_sum = x_flat[i * p + 0] + x_flat[i * p + 1]
    // Y in [-3, 5] roughly; upper tail of treated dominates
    // the CVaR at q=0.5.
    y[i] = 1.0 * d[i] + 0.3 * x_sum + (rng.double() - 0.2) * 2.0
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d)
  let fitted = DoubleMLCVAR::new(
    data,
    treatment=1.0,
    quantile=0.5,
    n_folds=4,
    seed=7504,
  ).fit()
  let boot = fitted.bootstrap(n_rep_boot=200, method_name="Bayes", seed=42)
  assert_eq(boot.boot_method, "Bayes")
  assert_eq(boot.n_rep_boot, 200)
  assert_eq(boot.boot_seed, 42)
  assert_bootstrap_finite(boot.boot_t_stat, 200)
}
