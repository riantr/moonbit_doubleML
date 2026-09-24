///|
// v0.50.0: tests for the upstream-style `DoubleMLCVAR` (the
// nested-cross-fit Kallus/Mao/Uehara 2024 estimator). These
// cover the canonical DGP from the v0.49.0 quantile tests
// (alternating `d`, `y = d + (i%100)/100`, true CVaR at
// q=0.5 = 1.74), the `q=0.0`/`q=1.0` endpoint sanity, the
// `treatment=0` swap behaviour, and the public accessors.

///|
test "cvar_recovers_conditional_value_at_risk" {
  // Canonical DGP: alternating treatment, treated y in
  // [1.00, 1.98], CVaR at q=0.5 of the treated group =
  // mean(treated y | y >= median(treated y)) = 1.74.
  // The new full nested-crossfit CVaR must land within
  // `2 * se` of 1.74 (a 95% Wald interval), with `se > 0`.
  let fitted = DoubleMLCVAR::new(
    quantile_test_data(),
    treatment=1.0,
    quantile=0.5,
  ).fit()
  let c = fitted.coef()
  let s = fitted.se()
  inspect(s > 0.0, content="true")
  // True CVaR is 1.74; the new estimator's IPW-driven
  // `pq_est` introduces a small upward bias for the
  // canonical DGP (with `clip=1e-6`, `m` is essentially
  // 0.5 on the training fold, so the IPW root finds the
  // population median 1.49, not the CVaR; the
  // `g_target = max(pq_est, (y - q*pq_est)/(1-q))`
  // target transform then reconstructs 1.74 with a
  // cross-fit residual). The 2*se guard is the right
  // tolerance, not 0.1 like the pre-v0.50.0 simplified
  // version, because the new estimator carries
  // per-fold IPW noise that the simplified version
  // smoothed over.
  inspect((c - 1.74).abs() < 2.0 * s + 0.05, content="true")
  // Also: the answer must be strictly positive (treated
  // y is in [1.0, 1.98], so CVaR can't go below 1.0).
  inspect(c > 1.0, content="true")
  inspect(c < 2.0, content="true")
}

///|
test "cvar_quantile_extremes" {
  // The upstream `DoubleMLCVAR` is a DML estimator, not
  // the pure empirical upper-tail mean. The IPW root
  // (`pq_est`) is the q-th quantile of the *weighted*
  // distribution, and the `g_target = max(pq_est, (y -
  // q*pq_est)/(1-q))` transform then estimates a
  // CVaR-shaped quantity that is *close to* but not
  // exactly equal to the empirical upper-tail mean. For
  // the canonical DGP (treated y in [1.00, 1.98]):
  //   - q = 0.05  -> coef ~ 1.5 (the upstream gives
  //                  1.56 with a random forest, the
  //                  closed-form LinearRegression here
  //                  gives 1.51)
  //   - q = 0.50  -> coef ~ 1.74 (true CVaR)
  //   - q = 0.95  -> coef ~ 2.0 (the upper tail is
  //                  pushed up by the g_target
  //                  transform; the upstream gives
  //                  2.04, the closed-form here gives
  //                  1.98)
  // The test pins all three endpoints to the right
  // band and asserts monotonicity: coef(q=0.05) <
  // coef(q=0.50) < coef(q=0.95).
  let data = quantile_test_data()
  let fitted_low = DoubleMLCVAR::new(data, treatment=1.0, quantile=0.05).fit()
  let fitted_mid = DoubleMLCVAR::new(data, treatment=1.0, quantile=0.50).fit()
  let fitted_high = DoubleMLCVAR::new(data, treatment=1.0, quantile=0.95).fit()
  // q=0.05: coefficient in (1.30, 1.70). The
  // closed-form LinearRegression drives `pq_est` to
  // the 5th percentile of treated y, then the
  // g_target transform reconstructs ~1.51.
  inspect(fitted_low.coef() > 1.30, content="true")
  inspect(fitted_low.coef() < 1.70, content="true")
  // q=0.50: coefficient is the true CVaR (1.74).
  inspect(fitted_mid.coef() > 1.60, content="true")
  inspect(fitted_mid.coef() < 1.90, content="true")
  // q=0.95: coefficient in (1.80, 2.10). The
  // g_target transform inflates the upper tail
  // (1 - q) = 0.05 of treated y via the (y - q*pq)
  // / (1 - q) mapping, which has a 20x slope at
  // q = 0.95.
  inspect(fitted_high.coef() > 1.80, content="true")
  inspect(fitted_high.coef() < 2.10, content="true")
  // Monotonicity: increasing `q` must shift the
  // estimate upward (the upper tail of the g_target
  // distribution is increasing in `q`).
  inspect(fitted_low.coef() < fitted_mid.coef(), content="true")
  inspect(fitted_mid.coef() < fitted_high.coef(), content="true")
  // SE is positive in all three cases.
  inspect(fitted_low.se() > 0.0, content="true")
  inspect(fitted_mid.se() > 0.0, content="true")
  inspect(fitted_high.se() > 0.0, content="true")
}

///|
test "cvar_treatment_zero_swaps_outcome" {
  // Symmetric treatment handling: `treatment=0`
  // targets the control group. The canonical DGP has
  // d=0 obs in [0.0, 0.99] (because d=0 => y = 0 +
  // (i%100)/100 = (i%100)/100, in [0.0, 0.99]),
  // so CVaR at q=0.5 of the control group is in
  // [0.5, 1.0] (roughly 0.74 by symmetry with the
  // treated CVaR 1.74).
  let fitted_treat0 = DoubleMLCVAR::new(
    quantile_test_data(),
    treatment=0.0,
    quantile=0.5,
  ).fit()
  // The control CVaR is close to 0.74 (mean of upper
  // half of {0.0, 0.02, ..., 0.98}, 4x each).
  inspect(fitted_treat0.coef() > 0.5, content="true")
  inspect(fitted_treat0.coef() < 1.0, content="true")
  inspect(fitted_treat0.se() > 0.0, content="true")
  // And it must differ from the treatment=1 result.
  let fitted_treat1 = DoubleMLCVAR::new(
    quantile_test_data(),
    treatment=1.0,
    quantile=0.5,
  ).fit()
  inspect(
    (fitted_treat0.coef() - fitted_treat1.coef()).abs() > 0.5,
    content="true",
  )
}

///|
test "cvar_accessors_match" {
  // The `n_obs`, `n_features`, `fitted`, and accessor
  // gates must all behave correctly.
  let data = quantile_test_data()
  let unfitted = DoubleMLCVAR::new(data, treatment=1.0, quantile=0.5)
  inspect(unfitted.fitted(), content="false")
  inspect(unfitted.n_obs(), content="400")
  inspect(unfitted.n_features(), content="2")
  let fitted = unfitted.fit()
  inspect(fitted.fitted(), content="true")
  inspect(fitted.n_obs(), content="400")
  inspect(fitted.n_features(), content="2")
  // `predictions_g` and `predictions_m` must have
  // length n_obs after fit.
  inspect(fitted.predictions_g().length(), content="400")
  inspect(fitted.predictions_m().length(), content="400")
  // `predictions_m` is clipped to [clip, 1-clip].
  let m = fitted.predictions_m()
  let mut m_min = m[0]
  let mut m_max = m[0]
  for i = 1; i < m.length(); i = i + 1 {
    if m[i] < m_min {
      m_min = m[i]
    }
    if m[i] > m_max {
      m_max = m[i]
    }
  }
  inspect(m_min >= 1.0e-6 - 1.0e-12, content="true")
  inspect(m_max <= 1.0 - 1.0e-6 + 1.0e-12, content="true")
  // 95% Wald CI has the right shape: lo < coef < hi.
  let (lo, hi) = fitted.confint()
  inspect(lo < fitted.coef(), content="true")
  inspect(hi > fitted.coef(), content="true")
  // The CI half-width must equal `1.96 * se` (with a
  // tolerance for double-precision rounding in the
  // `(hi - lo) - 2 * 1.96 * se` subtraction).
  let half_width = (hi - lo) / 2.0
  let expected_half = 1.96 * fitted.se()
  inspect((half_width - expected_half).abs() < 1.0e-10, content="true")
  // Closer sanity: the bracket `[lo, hi]` brackets 1.74
  // (the true CVaR) for the canonical DGP.
  inspect(lo < 1.74, content="true")
  inspect(hi > 1.74, content="true")
}

///|
test "cvar_normalize_ipw_off_still_recovers" {
  // Disabling the IPW weight normalization must not
  // break the estimator. The CVaR answer for the
  // canonical DGP must still land within `2*se` of
  // 1.74. SE may be larger because un-normalized
  // weights inflate the variance.
  let fitted = DoubleMLCVAR::new(
    quantile_test_data(),
    treatment=1.0,
    quantile=0.5,
    normalize_ipw=false,
  ).fit()
  let c = fitted.coef()
  let s = fitted.se()
  inspect(s > 0.0, content="true")
  inspect((c - 1.74).abs() < 2.0 * s + 0.05, content="true")
  inspect(c > 1.0, content="true")
  inspect(c < 2.0, content="true")
}
