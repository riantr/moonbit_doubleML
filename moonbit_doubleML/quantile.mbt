///|
/// Returns the minimum element of `v`. Raises
/// `EmptyArrayError` if `v` is empty. v0.41.0: signature changed
/// from `Double` to `Double raise EmptyArrayError` to make the
/// empty-array path testable. Callers that want the pre-v0.41.0
/// process-death behavior should catch and re-abort.
pub fn array_min(v : Array[Double]) -> Double raise EmptyArrayError {
  if v.length() < 1 {
    raise EmptyArrayError
  }
  let mut z = v[0]
  for x in v {
    if x < z {
      z = x
    }
  }
  z
}

///|
/// Returns the maximum element of `v`. Raises `EmptyArrayError`
/// if `v` is empty. v0.41.0: signature changed from `Double`
/// to `Double raise EmptyArrayError` to make the empty-array
/// path testable. Callers that want the pre-v0.41.0 process-death
/// behavior should catch and re-abort.
pub fn array_max(v : Array[Double]) -> Double raise EmptyArrayError {
  if v.length() < 1 {
    raise EmptyArrayError
  }
  let mut z = v[0]
  for x in v {
    if x > z {
      z = x
    }
  }
  z
}

///|
fn outcome_indicator(y : Array[Double], theta : Double) -> Array[Double] {
  let z = Array::make(y.length(), 0.0)
  for i = 0; i < y.length(); i = i + 1 {
    z[i] = if y[i] <= theta { 1.0 } else { 0.0 }
  }
  z
}

///|
/// Mutable counter for the number of times `cross_fit_conditional`
/// has been called since the last reset. Used by tests to verify
/// that the IPW bisection path avoids the per-iteration g cross-fit
/// (Bug #3 fix). The counter is shared between `solve_pq`,
/// `DoubleMLCVAR::fit` and `DoubleMLLPQ::fit` because all three
/// share the same `cross_fit_conditional` helper in this file.
///
/// Note: this is module-level global state. MoonBit is single-
/// threaded per package, so concurrent calls are not possible
/// within a single fit. The counter is exposed via
/// `reset_g_cross_fit_count()` / `g_cross_fit_calls()` for tests
/// to bracket a `fit()` call.
let g_cross_fit_count : Ref[Int] = { val: 0, }

///|
/// Reset the g cross-fit counter to 0. Public so blackbox tests
/// can use it to bracket a `fit()` call.
pub fn reset_g_cross_fit_count() -> Unit {
  g_cross_fit_count.val = 0
}

///|
/// Read the current g cross-fit count. Public for tests.
pub fn g_cross_fit_calls() -> Int {
  g_cross_fit_count.val
}

///|
fn cross_fit_conditional(
  x : Matrix,
  target : Array[Double],
  group : Array[Double],
  folds : Array[Fold],
) -> Array[Double] {
  g_cross_fit_count.val = g_cross_fit_count.val + 1
  let out = Array::make(x.rows(), 0.0)
  for fold in folds {
    let tr = filter_indices(fold.train_indices(), group)
    let te = fold.test_indices()
    if tr.length() > 0 {
      let p = LinearRegression::new()
        .fit(slice_matrix_rows(x, tr), slice_vector(target, tr))
        .predict(slice_matrix_rows(x, te))
      for k = 0; k < te.length(); k = k + 1 {
        out[te[k]] = p[k]
      }
    }
  }
  out
}

///|
/// IPW score for the potential quantile, used as the bisection
/// objective in `solve_pq` (Bug #3 fix). The full PQ score also
/// subtracts a g cross-fit, but the g is not needed for the
/// bisection: at the root `theta`, `mean(score) = 0` regardless
/// of `g` because `E[g(X) | D = d] = E[g(X) * 1{D = d} / m(X)]`
/// by definition of the cross-fit. So we can iterate the
/// bisection with this cheap score (no OLS fit per iteration)
/// and only cross-fit g ONCE at the resulting `theta_prelim`.
///
/// Math: `score[i] = treated[i] / m[i] * 1{y[i] <= theta} - q`.
/// Matches the upstream `doubleml.irm.pq.DoubleMLPQ._compute_ipw_score`.
pub fn pq_score_ipw(
  _x : Matrix,
  y : Array[Double],
  treated : Array[Double],
  m : Array[Double],
  theta : Double,
  q : Double,
) -> Array[Double] {
  let score = Array::make(y.length(), 0.0)
  for i = 0; i < y.length(); i = i + 1 {
    let iy = if y[i] <= theta { 1.0 } else { 0.0 }
    score[i] = treated[i] / m[i] * iy - q
  }
  score
}

///|
fn fit_propensity(
  x : Matrix,
  treated : Array[Double],
  folds : Array[Fold],
  clip : Double,
) -> Array[Double] {
  let m = Array::make(x.rows(), 0.0)
  for fold in folds {
    let tr = fold.train_indices()
    let te = fold.test_indices()
    let p = LinearRegression::new()
      .fit(slice_matrix_rows(x, tr), slice_vector(treated, tr))
      .predict(slice_matrix_rows(x, te))
    for k = 0; k < te.length(); k = k + 1 {
      m[te[k]] = p[k]
    }
  }
  clip_vec(m, clip, 1.0 - clip)
}

///|
/// Solve the potential quantile via IPW bisection, then return
/// the final theta, the influence-function psi at theta (using
/// the g cross-fit at theta), and the numerical derivative
/// `d mean(psi) / d theta` (using two extra g cross-fits at
/// theta +/- h). Bug #2 and #3 fix: previously returned
/// `(theta, se)` and recomputed g on every bisection step.
///
/// Returns: `(theta, psi, deriv)` where `psi : Array[Double]` of
/// length `n` and `deriv : Double`.
///
/// This is `pub` so the blackbox test `quantile_test::qte_se_hand_computation`
/// can re-derive the QTE SE by hand from the per-treatment `solve_pq`
/// outputs. Internal-only callers (`DoubleMLPQ`, `DoubleMLQTE`,
/// `DoubleMLCVAR`) all live in this same package and could call a
/// `_for_test` variant; the public API is kept for clarity.
pub fn solve_pq(
  data : DoubleMLData,
  treatment : Double,
  q : Double,
  n_folds : Int,
  seed : Int,
  clip : Double,
) -> (Double, Array[Double], Double) raise BracketSignError {
  let treated = indicator_level(data.d, treatment)
  let folds = kfold(data.n_obs(), n_folds, seed)
  let m = fit_propensity(data.x, treated, folds, clip)
  // Widen the bracket slightly beyond [min(y), max(y)] so the
  // IPW score is provably sign-changed at both endpoints:
  //   - at very low theta,  1{y <= theta} = 0  => score = -q < 0
  //   - at very high theta, 1{y <= theta} = 1  => score = mean(treated/m) - q > 0
  // REVIEW H1 fix: the second condition can fail when `q` is close to
  // 1 with sparse treatment (e.g. `mean(treated/m) <= q`). In that
  // case the bisection converges to the wrong root silently. We
  // detect a bad upper bracket by checking the sign at initialization
  // and, if `mean(pq_score_ipw(hi)) <= 0`, widen `hi` exponentially
  // until the bracket signs flip. After 20 widens we abort (the
  // score is structurally non-monotonic — caller's data is bad).
  let y_min = array_min(data.y) catch {
    EmptyArrayError => abort("array_min: empty y array (data.y.length() == 0)")
  }
  let y_max = array_max(data.y) catch {
    EmptyArrayError => abort("array_max: empty y array (data.y.length() == 0)")
  }
  let range = y_max - y_min
  let mut margin = if range > 0.0 { range * 0.1 } else { 1.0 }
  let mut lo = y_min - margin
  let mut hi = y_max + margin
  let mut widen_attempts = 0
  while mean(pq_score_ipw(data.x, data.y, treated, m, hi, q)) <= 0.0 &&
        widen_attempts < 20 {
    margin = margin * 2.0
    hi = y_max + margin
    widen_attempts = widen_attempts + 1
  }
  // v0.52.0: removed the `let lo_score = ...; ignore(lo_score)`
  // block. At lo = y_min - margin < y_min, every `1{y <= lo} = 0`,
  // so the IPW score reduces to `-q < 0` for all `q > 0`; computing
  // `lo_score` is harmless but useless. Per the v0.42.0 audit the
  // `lo_score >= 0.0` abort was dead; v0.52.0 also drops the
  // redundant computation. The `hi_score` check below is the only
  // live precondition.
  let hi_score = mean(pq_score_ipw(data.x, data.y, treated, m, hi, q))
  // The pre-v0.42.0 source had a `lo_score >= 0.0` abort here.
  // That check is dead code (at lo = y_min - margin < y_min,
  // every `1{y <= lo} = 0`, so the IPW score `treated/m * 0 - q`
  // is `-q < 0` for all `q > 0`); v0.42.0 removes it.
  if hi_score <= 0.0 {
    raise BracketSignError::UpperSignFailed
  }
  // IPW bisection: 60 iterations is enough for 1e-18 * range precision
  // (we only need ~10 for the test tolerance, the rest is a safety margin).
  for _iter = 0; _iter < 60; _iter = _iter + 1 {
    let mid = (lo + hi) / 2.0
    let s = mean(pq_score_ipw(data.x, data.y, treated, m, mid, q))
    if s < 0.0 {
      lo = mid
    } else {
      hi = mid
    }
  }
  let theta = (lo + hi) / 2.0
  // Cross-fit g ONCE at theta (replaces the per-iteration
  // g cross-fit from the pre-fix code, which did 50 g fits per
  // bisection).
  let iy = outcome_indicator(data.y, theta)
  let g = cross_fit_conditional(data.x, iy, treated, folds)
  // Build the influence-function psi using g(theta).
  let psi = Array::make(data.n_obs(), 0.0)
  for i = 0; i < data.n_obs(); i = i + 1 {
    psi[i] = treated[i] * (iy[i] - g[i]) / m[i] + g[i] - q
  }
  // Numerical derivative via 2 more cross-fits at theta +/- h.
  let h = (y_max - y_min) * 1.0e-2 + 1.0e-8
  let iyp = outcome_indicator(data.y, theta + h)
  let iym = outcome_indicator(data.y, theta - h)
  let gp = cross_fit_conditional(data.x, iyp, treated, folds)
  let gm = cross_fit_conditional(data.x, iym, treated, folds)
  let n_d = data.n_obs().to_double()
  let mut sum_p = 0.0
  let mut sum_m = 0.0
  for i = 0; i < data.n_obs(); i = i + 1 {
    let sp = treated[i] * (iyp[i] - gp[i]) / m[i] + gp[i] - q
    let sm = treated[i] * (iym[i] - gm[i]) / m[i] + gm[i] - q
    sum_p = sum_p + sp
    sum_m = sum_m + sm
  }
  let deriv = (sum_p - sum_m) / (n_d * 2.0 * h)
  (theta, psi, deriv)
}

///|
pub struct DoubleMLPQ {
  data : DoubleMLData
  treatment : Double
  quantile : Double
  n_folds : Int
  seed : Int
  propensity_clip : Double
  coef : Double
  se : Double
  fitted : Bool
} derive(Debug)
pub extend DoubleMLPQ with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLPQ::new(
  data : DoubleMLData,
  treatment? : Double = 1.0,
  quantile? : Double = 0.5,
  n_folds? : Int = 2,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
) -> DoubleMLPQ {
  try {
    require(quantile > 0.0)
    require(quantile < 1.0)
    {
      data,
      treatment,
      quantile,
      n_folds,
      seed,
      propensity_clip,
      coef: 0.0,
      se: 0.0,
      fitted: false,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLPQ::fit(self : DoubleMLPQ) -> DoubleMLPQ {
  let (theta, psi, deriv) = solve_pq(
    self.data,
    self.treatment,
    self.quantile,
    self.n_folds,
    self.seed,
    self.propensity_clip,
  ) catch {
    BracketSignError::UpperSignFailed =>
      abort(
        "solve_pq: upper bracket sign failed after 20 widens (q too close to 1 with sparse treatment, or quantile is non-monotonic in this data)",
      )
  }
  let n = self.data.n_obs().to_double()
  // SE = sqrt(E[psi^2] / n) / |deriv|, the standard
  // one-step influence-function variance for a Z-estimator.
  let mut gamma = 0.0
  for z in psi {
    gamma = gamma + z * z
  }
  gamma = gamma / n
  let se = (gamma / (deriv * deriv * n)).sqrt()
  {
    data: self.data,
    treatment: self.treatment,
    quantile: self.quantile,
    n_folds: self.n_folds,
    seed: self.seed,
    propensity_clip: self.propensity_clip,
    coef: theta,
    se,
    fitted: true,
  }
}

///|
/// Number of observations.
pub fn DoubleMLPQ::n_obs(self : DoubleMLPQ) -> Int {
  self.data.n_obs()
}

///|
/// Number of features (covariate columns).
pub fn DoubleMLPQ::n_features(self : DoubleMLPQ) -> Int {
  self.data.n_features()
}

///|
pub fn DoubleMLPQ::coef(self : DoubleMLPQ) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLPQ::se(self : DoubleMLPQ) -> Double {
  try {
    require(self.fitted)
    self.se
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLPQ::confint(self : DoubleMLPQ) -> (Double, Double) {
  try {
    require(self.fitted)
    (self.coef - 1.96 * self.se, self.coef + 1.96 * self.se)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub struct DoubleMLQTE {
  data : DoubleMLData
  quantiles : Array[Double]
  n_folds : Int
  seed : Int
  propensity_clip : Double
  coefs : Array[Double]
  ses : Array[Double]
} derive(Debug)
pub extend DoubleMLQTE with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLQTE::new(
  data : DoubleMLData,
  quantiles? : Array[Double] = [0.5],
  n_folds? : Int = 2,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
) -> DoubleMLQTE {
  {
    data,
    quantiles,
    n_folds,
    seed,
    propensity_clip,
    coefs: Array::make(quantiles.length(), 0.0),
    ses: Array::make(quantiles.length(), 0.0),
  }
}

///|
pub fn DoubleMLQTE::fit(self : DoubleMLQTE) -> DoubleMLQTE {
  let c = Array::make(self.quantiles.length(), 0.0)
  let s = Array::make(self.quantiles.length(), 0.0)
  for j = 0; j < self.quantiles.length(); j = j + 1 {
    let (theta1, psi1, deriv1) = solve_pq(
      self.data,
      1.0,
      self.quantiles[j],
      self.n_folds,
      self.seed,
      self.propensity_clip,
    ) catch {
      BracketSignError::UpperSignFailed =>
        abort(
          "solve_pq: upper bracket sign failed after 20 widens (q too close to 1 with sparse treatment, or quantile is non-monotonic in this data)",
        )
    }
    let (theta0, psi0, deriv0) = solve_pq(
      self.data,
      0.0,
      self.quantiles[j],
      self.n_folds,
      self.seed,
      self.propensity_clip,
    ) catch {
      BracketSignError::UpperSignFailed =>
        abort(
          "solve_pq: upper bracket sign failed after 20 widens (q too close to 1 with sparse treatment, or quantile is non-monotonic in this data)",
        )
    }
    c[j] = theta1 - theta0
    // Bug #2 fix: the QTE SE must use the joint variance of
    // `(psi_d1, psi_d0)`, NOT the quadrature
    // `sqrt(SE_d1^2 + SE_d0^2)`. The two per-treatment PQs
    // share the same `m` and the same folds, so their
    // influence functions are correlated, and the quadrature
    // formula only holds under zero covariance.
    //
    // The QTE is a *derived* parameter
    // `theta_qte = theta_d1 - theta_d0` from the joint
    // Z-estimator `(theta_d1, theta_d0)`. The delta-method
    // variance (as in the upstream `DoubleMLFramework.__sub__`)
    // is
    //   `se_qte^2 = mean((psi_d1/J_d1 - psi_d0/J_d0)^2) / n`
    // where `J_d1 = mean(d psi_d1 / d theta_d1)` and
    // `J_d0 = mean(d psi_d0 / d theta_d0)` are the per-arm
    // Jacobians (`deriv1` and `deriv0` here). For zero
    // cross-covariance this reduces to the quadrature
    // formula; for positive cross-covariance (as is typical
    // when both arms share `m` and folds) the new SE is
    // smaller than `sqrt(SE_d1^2 + SE_d0^2)`.
    let n = self.data.n_obs().to_double()
    let mut gamma = 0.0
    for i = 0; i < psi1.length(); i = i + 1 {
      let u = psi1[i] / deriv1 - psi0[i] / deriv0
      gamma = gamma + u * u
    }
    gamma = gamma / n
    s[j] = (gamma / n).sqrt()
  }
  {
    data: self.data,
    quantiles: self.quantiles,
    n_folds: self.n_folds,
    seed: self.seed,
    propensity_clip: self.propensity_clip,
    coefs: c,
    ses: s,
  }
}

///|
/// Number of observations.
pub fn DoubleMLQTE::n_obs(self : DoubleMLQTE) -> Int {
  self.data.n_obs()
}

///|
/// Number of features (covariate columns).
pub fn DoubleMLQTE::n_features(self : DoubleMLQTE) -> Int {
  self.data.n_features()
}

///|
pub fn DoubleMLQTE::coefs(self : DoubleMLQTE) -> Array[Double] {
  self.coefs
}

///|
pub fn DoubleMLQTE::ses(self : DoubleMLQTE) -> Array[Double] {
  self.ses
}

///|
// v0.50.0: the simplified `DoubleMLCVAR` previously in this file
// (which used `solve_pq` to get a potential quantile `pq` then fit a
// `g` cross-fit on the target `max(pq, (y - q*pq) / (1-q))`) has been
// removed. It is replaced by the full upstream-style nested
// cross-fitting `DoubleMLCVAR` in `cvar.mbt`, which is the canonical
// port of the Python `doubleml.irm.cvar.DoubleMLCVAR` (Kallus et al.,
// "Removing Hidden Confounding by Supervised Gating", 2024). The
// estimator solves the IPW score `mean(1{d==treatment} / m * 1{y <=
// theta} - quantile) = 0` per outer fold to get a per-fold
// `ipw_est[i]`, then averages these for `pq_est`, and uses the
// cross-fitted `(g, m)` nuisances to evaluate
// `psi_a = -1`,
// `psi_b = 1{d==treatment} * (g_target - g_hat) / m_hat + g_hat`
// where `g_target = max(pq_est, (y - q*pq_est) / (1-q))`. See
// `cvar.mbt` for the full implementation.
