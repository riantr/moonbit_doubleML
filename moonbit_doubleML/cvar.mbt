///|
/// Conditional Value at Risk for a binary potential outcome,
/// following the Kallus, Mao & Uehara (2024) "Removing Hidden
/// Confounding by Supervised Gating" estimator (the upstream
/// `doubleml.irm.cvar.DoubleMLCVAR`).
///
/// The estimator solves the IPW score
///   `mean(1{d==treatment} / m(X) * 1{y <= theta} - quantile) = 0`
/// per outer fold (with a per-fold preliminary cross-fit of `m` on
/// the train side) to get a per-fold `ipw_est[i]`, averages these
/// for `pq_est`, and uses the cross-fitted `(g, m)` nuisances to
/// evaluate the DML influence function
///   `psi_a = -1`,
///   `psi_b = 1{d==treatment} * (g_target - g_hat) / m_hat + g_hat`
/// where `g_target = max(pq_est, (y - q*pq_est) / (1-q))`. The
/// point estimate and SE come from the shared `var_est(psi_a,
/// psi_b)` helper.
///
/// v0.50.0: full upstream parity. The pre-v0.50.0 simplified
/// version (which lived in `quantile.mbt::DoubleMLCVAR` and
/// computed the CVaR via a single `solve_pq` call + a "max"
/// target trick) has been removed; the canonical CVaR estimator
/// is this struct.
pub struct DoubleMLCVAR {
  data : DoubleMLData
  treatment : Double
  quantile : Double
  n_folds : Int
  n_rep : Int
  seed : Int
  propensity_clip : Double
  normalize_ipw : Bool
  // v0.60.0+: injected nuisance learners. Defaults to
  // `LearnerDispatch::linear_regression()` so v0.59.0 callers
  // see byte-identical results. v0.61.0+ will plumb these
  // through `cross_fit_cvar_inner` / `solve_for_cvar`. For
  // v0.60.0 they're stored on the struct and returned via
  // `learner_g() / learner_m()` but not yet consumed internally.
  ml_g : LearnerDispatch
  ml_m : LearnerDispatch
  g_hat : Array[Double]
  m_hat : Array[Double]
  coef : Double
  se : Double
  fitted : Bool
  // v0.75.0+: per-observation influence function components
  // for the multiplier bootstrap. Populated by `fit(...)` from
  // the LAST rep's cross-fitted nuisances, matching the
  // v0.71.0 sensitivity_analysis convention:
  //   psi_a[i] = -1 (constant IRM-style IF)
  //   psi_b[i] = 1{d==treatment} * (g_target - g_hat) / m_hat
  //            + g_hat
  // where g_target = max(coef, (y - q*coef) / (1 - q)).
  psi_a : Array[Double]
  psi_b : Array[Double]
  // v0.75.0+: multiplier bootstrap state. `boot_t_stat` is a
  // length-`n_rep_boot` array of t-statistics for `coef`.
  // Populated by `bootstrap(...)`; empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
  // v0.83.0+: memoization state. `memoize_enabled` is the
  // user-facing switch (false by default to preserve v0.82.0
  // behavior bit-for-bit). When true and `n_rep == 1`, `fit()`
  // caches the LAST rep's `(g_hat, m_final, ipw_vec)` plus
  // fold assignment in `fit_cache` and reuses them on the
  // next call when the data fingerprint, fold split, learner
  // configuration, and propensity clip are unchanged. Mirrors
  // the IRM / PLR plumbing.
  memoize_enabled : Bool
  fit_cache : FitCache
} derive(Debug)

///|
pub extend DoubleMLCVAR with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Construct a `DoubleMLCVAR` estimator.
///
/// Parameters mirror the upstream `DoubleMLCVAR.__init__`:
///   - `treatment`     : binary potential outcome to target
///                       (0 or 1; default 1)
///   - `quantile`      : upper-tail level `q` of the conditional
///                       value at risk (strictly in (0, 1);
///                       default 0.5)
///   - `n_folds`       : number of outer / inner folds
///                       (default 2, matching the rest of the
///                       package's IRM family)
///   - `n_rep`         : number of sample-splitting repetitions
///                       (default 1)
///   - `seed`          : PRNG seed for the outer fold partition
///                       (default 3141)
///   - `propensity_clip`: lower / upper clip bound for the
///                       propensity `m` (strictly in (0, 0.5);
///                       default 1e-6)
///   - `normalize_ipw` : if `true`, normalize the IPW weights so
///                       they sum to `n` within each treatment
///                       group, matching the upstream default
///                       (default `true`).
pub fn DoubleMLCVAR::new(
  data : DoubleMLData,
  treatment? : Double = 1.0,
  quantile? : Double = 0.5,
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
  normalize_ipw? : Bool = true,
  ml_g? : LearnerDispatch = LearnerDispatch::linear_regression(),
  ml_m? : LearnerDispatch = LearnerDispatch::linear_regression(),
) -> DoubleMLCVAR {
  try {
    require(treatment == 0.0 || treatment == 1.0)
    require(quantile > 0.0)
    require(quantile < 1.0)
    require(n_folds >= 2)
    require(n_folds <= data.n_obs())
    require(n_rep >= 1)
    require(propensity_clip > 0.0)
    require(propensity_clip < 0.5)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
  {
    data,
    treatment,
    quantile,
    n_folds,
    n_rep,
    seed,
    propensity_clip,
    normalize_ipw,
    ml_g,
    ml_m,
    g_hat: Array::make(data.n_obs(), 0.0),
    m_hat: Array::make(data.n_obs(), 0.0),
    coef: 0.0,
    se: 0.0,
    fitted: false,
    psi_a: [],
    psi_b: [],
    boot_t_stat: [],
    boot_method: "",
    n_rep_boot: 0,
    boot_seed: 0,
    // v0.83.0+: default memoize off so v0.82.0 callers see
    // byte-identical fit() output. Enable explicitly via
    // `.enable_memoize()` for caching.
    memoize_enabled: false,
    fit_cache: FitCache::empty(),
  }
}

///|
/// v0.83.0+: turn on memoization for subsequent `fit()` calls.
/// When enabled, `fit()` will cache the LAST rep's per-fold
/// nuisance predictions (`g_hat`, `m_final`), the per-fold
/// `ipw_vec` (needed to recompute `pq_est` on a cache hit),
/// and the fold assignment; on a repeat call whose data +
/// learner fingerprint + fold split is identical, the entire
/// per-fold inner crossfit is skipped and the cached values
/// feed the post-fold `psi_a / psi_b / coef / se` pipeline.
///
/// `enable_memoize()` is honored only when `n_rep == 1`; for
/// `n_rep > 1` the per-rep cross-fit must run each time (the
/// cache would otherwise need to thread `n_rep` independent
/// per-rep nuisance arrays, which the `FitCache` layout does
/// not accommodate).
///
/// Default is OFF. When OFF, every `fit()` call runs the full
/// per-fold inner crossfit and the cache is neither read nor
/// written, so v0.82.0 callers see byte-identical output.
pub fn DoubleMLCVAR::enable_memoize(self : DoubleMLCVAR) -> DoubleMLCVAR {
  { ..self, memoize_enabled: true, }
}

///|
/// v0.83.0+: turn off memoization. Same immutability contract
/// as `enable_memoize()`. After this, `fit()` will not read or
/// write the cache; the existing `fit_cache` is preserved on
/// the returned struct (call `clear_cache()` to drop it).
pub fn DoubleMLCVAR::disable_memoize(self : DoubleMLCVAR) -> DoubleMLCVAR {
  { ..self, memoize_enabled: false, }
}

///|
/// v0.83.0+: drop any cached nuisance predictions, fold
/// assignment, and `ipw_vec`. Forces the next `fit()` to
/// recompute from scratch.
pub fn DoubleMLCVAR::clear_cache(self : DoubleMLCVAR) -> DoubleMLCVAR {
  { ..self, fit_cache: FitCache::empty(), }
}

///|
/// v0.83.0+: `true` iff `fit_cache` holds at least one cached
/// observation (i.e. at least one prior `fit()` call with
/// `memoize_enabled = true` has populated the cache). Note
/// that the cache may still be stale relative to the current
/// data + learner configuration -- check `memoize_enabled`
/// before assuming a cache hit.
pub fn DoubleMLCVAR::has_cache(self : DoubleMLCVAR) -> Bool {
  !self.fit_cache.is_empty()
}

///|
/// Number of observations.
pub fn DoubleMLCVAR::n_obs(self : DoubleMLCVAR) -> Int {
  self.data.n_obs()
}

///|
/// Number of features (covariate columns).
pub fn DoubleMLCVAR::n_features(self : DoubleMLCVAR) -> Int {
  self.data.n_features()
}

///|
/// v0.50.0: `True` iff `fit` has been called.
pub fn DoubleMLCVAR::fitted(self : DoubleMLCVAR) -> Bool {
  self.fitted
}

///|
/// Accessor for the outcome-quantile-nuisance learner used by
/// the most recent `fit(...)` call. v0.60.0+.
pub fn DoubleMLCVAR::learner_g(self : DoubleMLCVAR) -> LearnerDispatch {
  self.ml_g
}

///|
/// Accessor for the propensity-score learner used by the most
/// recent `fit(...)` call. v0.60.0+.
pub fn DoubleMLCVAR::learner_m(self : DoubleMLCVAR) -> LearnerDispatch {
  self.ml_m
}

///|
/// Point estimate (the upper-tail conditional mean of `Y(treatment)`).
pub fn DoubleMLCVAR::coef(self : DoubleMLCVAR) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Standard error (DML influence-function SE; see `var_est`).
pub fn DoubleMLCVAR::se(self : DoubleMLCVAR) -> Double {
  try {
    require(self.fitted)
    self.se
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// 95% Wald confidence interval `(coef - 1.96 * se, coef + 1.96 * se)`.
pub fn DoubleMLCVAR::confint(self : DoubleMLCVAR) -> (Double, Double) {
  try {
    require(self.fitted)
    (self.coef - 1.96 * self.se, self.coef + 1.96 * self.se)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.50.0: cross-fitted `g` nuisance predictions (length `n_obs`).
/// Only meaningful after `fit`.
pub fn DoubleMLCVAR::predictions_g(self : DoubleMLCVAR) -> Array[Double] {
  try {
    require(self.fitted)
    self.g_hat
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.50.0: cross-fitted `m` (propensity) nuisance predictions
/// (length `n_obs`). Values are already clipped to
/// `[propensity_clip, 1 - propensity_clip]`. If `treatment == 0`,
/// the values are flipped to `1 - m` (the symmetric treatment
/// swap from the upstream API). Only meaningful after `fit`.
pub fn DoubleMLCVAR::predictions_m(self : DoubleMLCVAR) -> Array[Double] {
  try {
    require(self.fitted)
    self.m_hat
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.71.0: sensitivity analysis on `DoubleMLCVAR`. CVaR's
/// DML influence function is the IRM-style form documented in
/// the struct-level comment:
///
///   psi_a[i] = -1   (constant)
///   psi_b[i] = 1{d[i] == treatment} * (g_target - g_hat[i])
///            / m_hat[i] + g_hat[i]
///
/// where `g_target = max(coef, (y - q*coef) / (1 - q))` and
/// `q = self.quantile`. The constant `psi_a = -1` and the
/// residual `y - g_hat` let us reuse the shared
/// `irm_style_sensitivity` helper (see `sensitivity.mbt`):
/// `cf_y` / `cf_d` are the confounding-strength upper bounds
/// (defaults 0.05) and are passed through to the result for
/// upstream parity.
pub fn DoubleMLCVAR::sensitivity_analysis(
  self : DoubleMLCVAR,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let n = self.n_obs()
  let y = self.data.y
  let d = self.data.d
  let g_hat = self.g_hat
  let m_hat = self.m_hat
  let treatment = self.treatment
  let q = self.quantile
  let coef = self.coef
  // psi_a is the constant -1 vector (IRM-style IF for CVaR).
  let psi_a : Array[Double] = Array::make(n, -1.0)
  // g_target = max(coef, (y - q*coef) / (1 - q)).
  // Mirror of fit()'s g_target = max(pq_est, (y - q*pq_est)/(1-q))
  // with pq_est collapsed to coef (= pq_est in the standard
  // n_rep=1 case).
  let g_target : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let alt = (y[i] - q * coef) / (1.0 - q)
    g_target[i] = if coef > alt { coef } else { alt }
  }
  // psi_b + residuals in one loop.
  let psi_b : Array[Double] = Array::make(n, 0.0)
  let residuals : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let treated_i = if d[i] == treatment { 1.0 } else { 0.0 }
    let m_i = m_hat[i]
    // Mirror fit()'s m-clip behaviour (propensity_clip, not
    // 1e-12; downstream irm_style_sensitivity treats
    // zero-clipped residuals gracefully).
    let m_clip = if m_i < self.propensity_clip {
      self.propensity_clip
    } else {
      m_i
    }
    psi_b[i] = treated_i * (g_target[i] - g_hat[i]) / m_clip + g_hat[i]
    residuals[i] = y[i] - g_hat[i]
  }
  irm_style_sensitivity(coef, residuals, psi_a, cf_y, cf_d)
}

///|
/// v0.74.0+: cluster-robust analogue of
/// `DoubleMLCVAR::sensitivity_analysis`. Same outcome
/// residual formula (`y - g_hat`) and same `psi_a = -1`
/// (constant) as the IID path; only the variance / bias
/// computation is cluster-aware (sigma2_cluster and
/// nu2_cluster are the `G / n_clusters` sums of squared
/// cluster sums).
///
/// `cluster_ids` defaults to `DoubleMLData::cluster_vars`.
pub fn DoubleMLCVAR::sensitivity_analysis_cluster(
  self : DoubleMLCVAR,
  cluster_ids? : Array[Int] = self.data.cluster_vars,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let n = self.n_obs()
  let y = self.data.y
  let g_hat = self.g_hat
  let coef = self.coef
  require(cluster_ids.length() == n)
  // psi_a is the constant -1 vector (IRM-style IF for CVaR).
  let psi_a : Array[Double] = Array::make(n, -1.0)
  // Outcome residual `y - g_hat`; same as the IID path.
  let residuals : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    residuals[i] = y[i] - g_hat[i]
  }
  irm_style_sensitivity_cluster(coef, residuals, psi_a, cluster_ids, cf_y, cf_d)
}

///|
/// Stratum 50/50 split of `train` on the values of `d[train]`,
/// using a deterministic Fisher-Yates shuffle keyed by `seed`.
/// Returns `(s1, s2)` such that `s1 ++ s2 = train`,
/// `s1 ** s2 = []`, and within each stratum the partition is
/// balanced (mirrors `sklearn.model_selection.train_test_split(
/// train, test_size=0.5, random_state=seed, stratify=...)`).
///
/// This is the inner 50/50 split the upstream CVaR uses to
/// separate the preliminary propensity cross-fit
/// (`smpls_prelim = StratifiedKFold(n_splits=n_folds).split(
/// train_1, ...)`) from the `ml_g` fit on `train_2`.
fn stratified_half_split(
  train : Array[Int],
  d : Array[Double],
  seed : Int,
) -> (Array[Int], Array[Int]) {
  // Group train indices by stratum. Strata are keyed by their
  // string representation (handles non-integer d, though the
  // CVaR API restricts d to {0, 1}).
  let by_stratum : Array[(String, Array[Int])] = []
  for i in train {
    let key = d[i].to_string()
    let mut found = false
    for j = 0; j < by_stratum.length(); j = j + 1 {
      if by_stratum[j].0 == key {
        by_stratum[j].1.push(i)
        found = true
        break
      }
    }
    if !found {
      by_stratum.push((key, [i]))
    }
  }
  // Shuffle each stratum independently with its own sub-seed.
  let rng = chacha8_rng(seed)
  for k_idx = 0; k_idx < by_stratum.length(); k_idx = k_idx + 1 {
    let arr = by_stratum[k_idx].1
    for i = arr.length() - 1; i > 0; i = i - 1 {
      let j = rng.int(limit=i + 1)
      let tmp = arr[i]
      arr[i] = arr[j]
      arr[j] = tmp
    }
  }
  // Round-robin the first half of each stratum to s1, the
  // second half to s2 (matches the sklearn
  // `train_test_split(test_size=0.5)` semantics for the
  // "balanced" branch). If a stratum has an odd length, the
  // extra element lands in s1.
  let s1 : Array[Int] = []
  let s2 : Array[Int] = []
  for k_idx = 0; k_idx < by_stratum.length(); k_idx = k_idx + 1 {
    let arr = by_stratum[k_idx].1
    let half = arr.length() / 2
    for k = 0; k < half; k = k + 1 {
      s1.push(arr[k])
    }
    for k = half; k < arr.length(); k = k + 1 {
      s2.push(arr[k])
    }
  }
  (s1, s2)
}

///|
/// IPW score at `theta` for the CVaR preliminary estimator,
/// restricted to a parallel slice of `(y, treated, m)`:
///   `score[k] = treated[k] / m[k] * 1{y[k] <= theta} - quantile`
/// Returns `mean(score)` over the slice. The score is
/// monotonically non-decreasing in `theta`, with a clean
/// sign change between `[y_min - margin, y_max + margin]`, so
/// a 60-step bisection converges to ~1e-18 * range precision.
///
/// `y_slice`, `treated_slice`, and `m_slice` must be
/// parallel arrays of equal length (the per-prelim-fold
/// row set), so the inner loop can index all three by the
/// same position. This is the per-fold "subset" view; the
/// upstream `compute_ipw_score` is `np.mean(1{d==1}/m *
/// 1{y <= theta} - q)` on a row subset, so slicing
/// first and then averaging is semantically identical.
fn cvar_ipw_score(
  y_slice : Array[Double],
  treated_slice : Array[Double],
  m_slice : Array[Double],
  theta : Double,
  quantile : Double,
) -> Double {
  let n = y_slice.length()
  if n == 0 {
    return 0.0
  }
  let mut acc = 0.0
  for k = 0; k < n; k = k + 1 {
    let m_k = m_slice[k]
    let m_clip = if m_k < 1.0e-12 { 1.0e-12 } else { m_k }
    let iy = if y_slice[k] <= theta { 1.0 } else { 0.0 }
    acc = acc + treated_slice[k] / m_clip * iy - quantile
  }
  acc / n.to_double()
}

///|
/// Bisection-based root finder for the IPW score, on a
/// parallel `(y_slice, treated_slice, m_slice)`. Bracket is
/// `[y_min - margin, y_max + margin]`, widened exponentially
/// (matching `solve_pq`'s REVIEW H1 fix) if the upper-bracket
/// score remains non-positive. Returns the bisection midpoint
/// after 60 iterations.
///
/// v0.50.0: matches the upstream `_get_bracket_guess` +
/// `_solve_ipw_score` pair in spirit, with the bracketing
/// strategy borrowed from `solve_pq` (which already
/// solves the same kind of IPW quantile root and has the
/// `BracketSignError` path tested). For CVaR the score is
/// structurally non-negative at `theta >= y_max` (because
/// `mean(1{d=1}/m) >= 1` by AM-GM), so the upper-bracket
/// widening is included for the edge case where the
/// propensity weighting produces a sub-unit mean.
fn solve_ipw_root(
  y_slice : Array[Double],
  treated_slice : Array[Double],
  m_slice : Array[Double],
  quantile : Double,
) -> Double {
  // Find y_min / y_max over the slice.
  let mut y_min = y_slice[0]
  let mut y_max = y_slice[0]
  for k = 1; k < y_slice.length(); k = k + 1 {
    let v = y_slice[k]
    if v < y_min {
      y_min = v
    }
    if v > y_max {
      y_max = v
    }
  }
  let range = y_max - y_min
  let mut margin = if range > 0.0 { range * 0.1 } else { 1.0 }
  let mut lo = y_min - margin
  let mut hi = y_max + margin
  // Widen `hi` exponentially if the upper-bracket score is
  // non-positive (a structural failure mode of the IPW score
  // for `q` close to 1 with sparse treatment -- same condition
  // as `solve_pq`'s REVIEW H1 fix).
  let mut widen_attempts = 0
  while cvar_ipw_score(y_slice, treated_slice, m_slice, hi, quantile) <= 0.0 &&
        widen_attempts < 20 {
    margin = margin * 2.0
    hi = y_max + margin
    widen_attempts = widen_attempts + 1
  }
  // 60-step bisection. The IPW score is monotonically
  // non-decreasing in `theta`, so the bracket never flips back
  // and the midpoint is the root to ~1e-18 * range precision.
  for _iter = 0; _iter < 60; _iter = _iter + 1 {
    let mid = (lo + hi) / 2.0
    let s = cvar_ipw_score(y_slice, treated_slice, m_slice, mid, quantile)
    if s < 0.0 {
      lo = mid
    } else {
      hi = mid
    }
  }
  (lo + hi) / 2.0
}

///|
/// Normalize inverse probability weights so that the mean
/// weight within each treatment group equals 1. Matches the
/// upstream `doubleml.utils._propensity_score._normalize_ipw`:
///   `mean_treat1 = mean(treatment / propensity)`
///   `mean_treat0 = mean((1 - treatment) / (1 - propensity))`
///   `normalized = treatment * propensity * mean_treat1
///               + (1 - treatment) * (1 - (1 - propensity) * mean_treat0)`
///
/// Intuition: the raw IPW weight `treatment / propensity` is
/// unbiased for the treated fraction; multiplying by
/// `mean_treat1 = E[treatment / propensity]` turns it into a
/// weight that sums to `n_treated` instead of `n_treated / m`,
/// eliminating a constant-of-proportionality bias in the
/// cross-fit score.
fn normalize_ipw_weights(
  propensity : Array[Double],
  treatment : Array[Double],
) -> Array[Double] {
  let n = propensity.length()
  let mut sum_t1 = 0.0
  let mut sum_t0 = 0.0
  for i = 0; i < n; i = i + 1 {
    let m = propensity[i]
    let m_clip = if m < 1.0e-12 { 1.0e-12 } else { m }
    let om = 1.0 - m_clip
    let om_clip = if om < 1.0e-12 { 1.0e-12 } else { om }
    sum_t1 = sum_t1 + treatment[i] / m_clip
    sum_t0 = sum_t0 + (1.0 - treatment[i]) / om_clip
  }
  let mean_t1 = sum_t1 / n.to_double()
  let mean_t0 = sum_t0 / n.to_double()
  let out = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let m = propensity[i]
    let m_clip = if m < 1.0e-12 { 1.0e-12 } else { m }
    let om = 1.0 - m_clip
    let om_clip = if om < 1.0e-12 { 1.0e-12 } else { om }
    let w1 = treatment[i] * m_clip * mean_t1
    let w0 = (1.0 - treatment[i]) * (1.0 - om_clip * mean_t0)
    out[i] = w1 + w0
  }
  out
}

///|
/// v0.50.0: per-outer-fold inner crossfit for CVaR. For each
/// outer fold `(train, test)`:
///   1. Split `train` 50/50 stratified by `d` into `(train_1,
///      train_2)`.
///   2. On `train_1`, run a stratified `n_folds`-fold CV to
///      cross-fit the propensity `m_hat_prelim`.
///   3. Clip and (optionally) normalize `m_hat_prelim`; flip
///      if `treatment == 0`.
///   4. Solve the IPW score for `ipw_est` on `(train_1,
///      m_hat_prelim)`.
///   5. Form `g_target = max(ipw_est, (y - q*ipw_est) / (1-q))`
///      on `train_2` and fit `ml_g` on `(x_train_2, g_target)`
///      restricted to `d == treatment`.
///   6. Predict `g_hat[test]` and refit `ml_m` on full `train`
///      to predict `m_hat[test]`.
///   7. Append `ipw_est` to `ipw_vec` (the per-fold preliminary
///      potential-quantile estimates).
fn cvar_inner_crossfit(
  ml_g : LearnerDispatch,
  ml_m : LearnerDispatch,
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  treated : Array[Double],
  train : Array[Int],
  eval_set : Array[Int],
  n_folds : Int,
  seed : Int,
  quantile : Double,
  treatment : Double,
  propensity_clip : Double,
  normalize_ipw : Bool,
) -> (Array[Double], Array[Double], Double) {
  // 1) stratified 50/50 split of `train`.
  let (train_1, train_2) = stratified_half_split(train, d, seed)
  // 2) cross-fit a preliminary `m_hat_prelim` on `train_1` via
  //    stratified k-fold (using `kfold_stratified` so each
  //    stratum is balanced across prelim folds).
  let prelim_folds = kfold_stratified(
    train_1.length(),
    slice_vector(d, train_1),
    n_folds,
    seed + 1,
  )
  // Map each `train_1` position back to a global index so the
  // prelim crossfit's predictions can be written to the right
  // row of the preliminary `m_hat` array.
  let m_prelim = Array::make(train_1.length(), 0.0)
  for fold in prelim_folds {
    // `prelim_train_idx` and `prelim_test_idx` are positions
    // into `train_1`; convert to global indices by indirect
    // indexing through `train_1[pos]`.
    let prelim_train_pos = fold.train_indices()
    let prelim_test_pos = fold.test_indices()
    let prelim_train_global : Array[Int] = Array::makei(
      prelim_train_pos.length(),
      fn(k) { train_1[prelim_train_pos[k]] },
    )
    let prelim_test_global : Array[Int] = Array::makei(
      prelim_test_pos.length(),
      fn(k) { train_1[prelim_test_pos[k]] },
    )
    let p = fit_predict_one_dispatch(
      ml_m,
      slice_matrix_rows(x, prelim_train_global),
      slice_vector(treated, prelim_train_global),
      slice_matrix_rows(x, prelim_test_global),
    )
    for k = 0; k < prelim_test_global.length(); k = k + 1 {
      // `prelim_test_pos[k]` is the position in `train_1`,
      // and `train_1[prelim_test_pos[k]]` is the global index
      // we need to map back to a position in `m_prelim`. Use
      // the supplied `prelim_test_pos[k]` directly.
      m_prelim[prelim_test_pos[k]] = p[k]
    }
  }
  // 3) clip the preliminary propensity and (optionally)
  //    normalize the IPW weights. `clip_vec` returns a new
  //    array, so we don't mutate `m_prelim`.
  let m_prelim_clipped = clip_vec(
    m_prelim,
    propensity_clip,
    1.0 - propensity_clip,
  )
  // `m_prelim_for_score` is the preliminary propensity used
  // in the IPW score (post-clip, post-normalize, post-treat=0
  // flip). The m_prelim_clipped array is the per-prelim-fold
  // cross-fit; we re-apply normalize and the treat=0 flip
  // once, on the full `train_1` row set.
  let m_prelim_for_score = if normalize_ipw {
    let norm = normalize_ipw_weights(
      m_prelim_clipped,
      slice_vector(treated, train_1),
    )
    if treatment == 0.0 {
      let flipped = Array::make(norm.length(), 0.0)
      for i = 0; i < norm.length(); i = i + 1 {
        flipped[i] = 1.0 - norm[i]
      }
      flipped
    } else {
      norm
    }
  } else if treatment == 0.0 {
    let flipped = Array::make(m_prelim_clipped.length(), 0.0)
    for i = 0; i < m_prelim_clipped.length(); i = i + 1 {
      flipped[i] = 1.0 - m_prelim_clipped[i]
    }
    flipped
  } else {
    m_prelim_clipped
  }
  // 4) solve the IPW score for `ipw_est`. The score is taken
  //    on `(y, treated, m_prelim_for_score)` restricted to
  //    the `train_1` row set, so all three arrays must be
  //    parallel slices of the global data. The score's
  //    root is the per-fold preliminary potential-quantile
  //    estimate that the upstream `pq_est = mean(ipw_vec)`
  //    later averages across outer folds.
  let y_train_1 = slice_vector(y, train_1)
  let treated_train_1 = slice_vector(treated, train_1)
  let ipw_est = solve_ipw_root(
    y_train_1, treated_train_1, m_prelim_for_score, quantile,
  )
  // 5) form `g_target = max(ipw_est, (y - q*ipw_est) / (1-q))`
  //    on the full data set (per the upstream `_nuisance_est`),
  //    restrict to `(train_2, d == treatment)`, fit `ml_g`.
  let g_target = Array::make(y.length(), 0.0)
  let q_comp = 1.0 - quantile
  for i = 0; i < y.length(); i = i + 1 {
    let z = (y[i] - quantile * ipw_est) / q_comp
    g_target[i] = if z > ipw_est { z } else { ipw_est }
  }
  // Build (train_2, d == treatment) subset.
  let train_2_treat : Array[Int] = []
  for i in train_2 {
    if d[i] == treatment {
      train_2_treat.push(i)
    }
  }
  // Fit ml_g. If the subset is empty (extreme D imbalance
  // pulls every treated row into `train_1`), the test side
  // receives `g = 0.0`, matching the upstream convention
  // (`g_hat["preds"][test_inds] = fitted_models["ml_g"][i_fold]
  // .predict(x_test)` raises sklearn's "not fitted" error
  // if called, so in practice the upstream also short-circuits
  // via `g_hat["targets"]` filtering; we just skip the fit
  // and leave g[eval] = 0.0).
  let g_hat_test : Array[Double] = if train_2_treat.length() > 0 {
    fit_predict_one_dispatch(
      ml_g,
      slice_matrix_rows(x, train_2_treat),
      slice_vector(g_target, train_2_treat),
      slice_matrix_rows(x, eval_set),
    )
  } else {
    Array::make(eval_set.length(), 0.0)
  }
  // 6) refit `ml_m` on the full `train` and predict on `eval_set`.
  let m_hat_test = fit_predict_one_dispatch(
    ml_m,
    slice_matrix_rows(x, train),
    slice_vector(d, train),
    slice_matrix_rows(x, eval_set),
  )
  (g_hat_test, m_hat_test, ipw_est)
}

///|
/// v0.50.0: fit the `DoubleMLCVAR` estimator. Implements the
/// upstream `_nuisance_est` flow:
///   1. For each rep `r`, draw `n_folds` outer folds with
///      `kfold(n, self.n_folds, self.seed + r)`.
///   2. For each outer fold, run the inner cross-fit
///      (see `cvar_inner_crossfit`) to get per-fold `(g_hat,
///      m_hat, ipw_est)`.
///   3. After all folds, clip `m_hat` to `[clip, 1-clip]`,
///      optionally normalize the IPW weights, and (if
///      `treatment == 0`) flip `1 - m_hat`.
///   4. Compute `pq_est = mean(ipw_vec)` and the final
///      `psi_a, psi_b` with `g_target = max(pq_est, (y - q*
///      pq_est) / (1-q))`.
///   5. `var_est(psi_a, psi_b)` gives the per-rep `(theta, se)`;
///      aggregate across reps with `aggregate_coef_se`.
pub fn DoubleMLCVAR::fit(
  self : DoubleMLCVAR,
  ml_g? : LearnerDispatch = self.ml_g,
  ml_m? : LearnerDispatch = self.ml_m,
) -> DoubleMLCVAR {
  try {
    require(self.quantile > 0.0 && self.quantile < 1.0)
    let n = self.n_obs()
    let treated = indicator_level(self.data.d, self.treatment)
    // Per-rep accumulators. The per-rep nuisances are discarded
    // except for the final rep's (which become the public
    // `g_hat` / `m_hat`); the per-rep `(theta_r, se_r)` are
    // aggregated.
    let coefs : Array[Double] = Array::make(self.n_rep, 0.0)
    let ses : Array[Double] = Array::make(self.n_rep, 0.0)
    let mut last_g : Array[Double] = Array::make(n, 0.0)
    let mut last_m : Array[Double] = Array::make(n, 0.0)
    // v0.83.0+: track the LAST rep's `ipw_vec` so a memoize
    // writeback can persist it for cache-hit reuse. Without
    // this, the cache-hit path can't recompute `pq_est =
    // mean(ipw_vec)` from cached nuisances alone.
    let mut last_ipw_vec : Array[Double] = []
    // v0.83.0+: track the LAST rep's row-to-fold mapping for
    // the cache writeback.
    let fold_ids : Array[Int] = Array::make(n, 0)
    // v0.75.0+: capture psi_a / psi_b from the LAST rep for the
    // multiplier bootstrap. Same convention as `last_g` /
    // `last_m`: each rep overwrites, so the post-loop values
    // match the last rep's nuisances (which are the ones
    // persisted on the struct).
    let last_psi_a : Array[Double] = Array::make(n, -1.0)
    let mut last_psi_b : Array[Double] = Array::make(n, 0.0)
    // v0.83.0+: memoize check (mirrors the PLR / IRM pattern).
    // The cache stores the LAST rep's `(g_hat, m_final, ipw_vec)`
    // plus the row-to-fold mapping. We honor the cache only when:
    //   (a) the user opted in (`self.memoize_enabled`),
    //   (b) n_rep == 1 (multi-rep aggregations must run every
    //       rep fresh -- we cannot cache individual rep scores).
    //   (c) `is_valid(...)` matches every dimension of the
    //       data + learner + cluster fingerprint.
    // When memoize_enabled is false (the default), the entire
    // cache code path is skipped so v0.82.0 callers see a
    // byte-identical fit() output.
    let memoize = self.memoize_enabled && self.n_rep == 1
    let data_hash : UInt64 = if memoize {
      hash_data(
        self.data.x,
        self.data.y,
        self.data.d,
        z=self.data.z,
        cluster_vars=self.data.cluster_vars,
      )
    } else {
      0UL
    }
    let hparams_hash : UInt64 = if memoize {
      hash_hyperparams("cvar", ml_g, ml_m, self.propensity_clip)
    } else {
      0UL
    }
    let cluster_hash : UInt64 = if memoize {
      hash_cluster_ids(self.data.cluster_vars)
    } else {
      0UL
    }
    let cache_hit = memoize &&
      self.fit_cache.is_valid(
        self.seed,
        self.n_folds,
        self.n_rep,
        n,
        data_hash,
        hparams_hash,
        cluster_hash,
        "cvar",
      )
    for r = 0; r < self.n_rep; r = r + 1 {
      let (g_hat, m_final, ipw_vec) = if cache_hit && r == self.n_rep - 1 {
        // Reuse the cached LAST-rep nuisances + ipw_vec. v0.83.0+
        // fix: without caching `ipw_vec` (just `g_hat` / `m_final`),
        // the cache-hit path can't recompute `pq_est = mean(ipw_vec)`
        // for the psi_a / psi_b / var_est pipeline.
        let preds = self.fit_cache.predictions
        let cached_fold_ids = self.fit_cache.fold_ids
        for i = 0; i < n; i = i + 1 {
          fold_ids[i] = cached_fold_ids[i]
        }
        (preds[0], preds[1], preds[2])
      } else {
        let folds = kfold(n, self.n_folds, self.seed + r)
        let g_hat = Array::make(n, 0.0)
        let m_hat = Array::make(n, 0.0)
        let ipw_vec : Array[Double] = Array::make(folds.length(), 0.0)
        for i_fold = 0; i_fold < folds.length(); i_fold = i_fold + 1 {
          let train = folds[i_fold].train_indices()
          let eval_set = folds[i_fold].test_indices()
          // Per-fold sub-seed for the inner 50/50 split. The
          // upstream `train_test_split` uses `random_state=42`
          // (constant); we mirror that choice with a fixed
          // constant seed so the deterministic test replay
          // matches.
          let inner_seed = 42 + r * 1000 + i_fold * 17
          let (g_test, m_test, ipw_est) = cvar_inner_crossfit(
            ml_g,
            ml_m,
            self.data.x,
            self.data.y,
            self.data.d,
            treated,
            train,
            eval_set,
            self.n_folds,
            inner_seed,
            self.quantile,
            self.treatment,
            self.propensity_clip,
            self.normalize_ipw,
          )
          for k = 0; k < eval_set.length(); k = k + 1 {
            g_hat[eval_set[k]] = g_test[k]
            m_hat[eval_set[k]] = m_test[k]
          }
          ipw_vec[i_fold] = ipw_est
        }
        // Post-fold adjustments: clip, normalize, treat=0 flip.
        // These match the upstream
        // `m_hat["preds"] = ps_processor.adjust_ps(m_hat["preds"],
        // d, cv=smpls); if normalize: m_hat_adj = _normalize_ipw(
        // ...); if treatment==0: m_hat_adj = 1 - m_hat_adj`.
        let m_clipped = clip_vec(
          m_hat,
          self.propensity_clip,
          1.0 - self.propensity_clip,
        )
        let m_adj = if self.normalize_ipw {
          normalize_ipw_weights(m_clipped, self.data.d)
        } else {
          m_clipped
        }
        let m_final = if self.treatment == 0.0 {
          let flipped = Array::make(m_adj.length(), 0.0)
          for i = 0; i < m_adj.length(); i = i + 1 {
            flipped[i] = 1.0 - m_adj[i]
          }
          flipped
        } else {
          m_adj
        }
        // Build row->fold_id map for the LAST rep (used by the
        // cache writeback below).
        if r == self.n_rep - 1 {
          for f = 0; f < folds.length(); f = f + 1 {
            for i in folds[f].test_indices() {
              fold_ids[i] = f
            }
          }
        }
        (g_hat, m_final, ipw_vec)
      }
      // `pq_est = mean(ipw_vec)`. Matches the upstream
      // `pq_est = np.mean(ipw_vec)` (Kallus et al., p.4).
      let pq_est = mean(ipw_vec)
      // psi_a, psi_b with `g_target = max(pq_est, (y - q*pq_est)
      // / (1-q))`. v0.83.0+: the residual loops are written in
      // terms of the `vectorized.mbt` building blocks
      // (`vector_subtract`, `vector_scale`, `vector_divide`,
      // `vector_multiply`, `vector_add`); the only remaining
      // per-element loop is the `max(z, pq_est)` step, which
      // is a scalar compare (no vector_max helper available).
      let psi_a = Array::make(n, -1.0)
      let q_comp = 1.0 - self.quantile
      let pq_target_arr : Array[Double] = Array::make(n, pq_est)
      let shifted_y = vector_subtract(
        self.data.y,
        vector_scale(pq_target_arr, self.quantile),
      )
      let z_arr = vector_scale(shifted_y, 1.0 / q_comp)
      let g_target_arr : Array[Double] = Array::make(n, 0.0)
      for i = 0; i < n; i = i + 1 {
        g_target_arr[i] = if z_arr[i] > pq_est { z_arr[i] } else { pq_est }
      }
      let residual_g = vector_subtract(g_target_arr, g_hat)
      let ratio = vector_divide(residual_g, m_final, eps=1.0e-10)
      let weighted = vector_multiply(treated, ratio)
      let psi_b = vector_add(weighted, g_hat)
      let (theta_r, se_r) = var_est(psi_a, psi_b)
      coefs[r] = theta_r
      ses[r] = se_r
      // The public accessors return the *last* rep's
      // `g_hat` / `m_hat`, matching the rest of the package's
      // convention (and the upstream `doubleml.DoubleML` summary
      // table, which only carries the last rep's nuisances).
      last_g = g_hat
      last_m = m_final
      last_ipw_vec = ipw_vec
      // v0.75.0+: persist the last rep's IF components for the
      // bootstrap. psi_a is constant -1 (IRM-style IF). psi_b
      // mirrors the v0.71.0 sensitivity_analysis formula:
      //   psi_b[i] = 1{d==treatment} * (g_target - g_hat) / m + g_hat
      // where g_target = max(coef, (y - q*coef) / (1 - q)) for the
      // *post-aggregate* coef (= pq_est in the n_rep=1 case).
      // We rebuild psi_b from the last rep's (g_hat, m_final)
      // using `pq_est = coef_r` so the bootstrap sees the
      // single-rep IF consistent with the converged coef.
      // v0.83.0+: same vectorised residual pattern as above
      // (subtract, scale, max, multiply-add) for the second
      // psi_b recomputation.
      let pq_est_for_b = theta_r
      let pq_target_arr_b : Array[Double] = Array::make(n, pq_est_for_b)
      let shifted_y_b = vector_subtract(
        self.data.y,
        vector_scale(pq_target_arr_b, self.quantile),
      )
      let z_arr_b = vector_scale(shifted_y_b, 1.0 / q_comp)
      let g_target_arr_b : Array[Double] = Array::make(n, 0.0)
      for i = 0; i < n; i = i + 1 {
        g_target_arr_b[i] = if z_arr_b[i] > pq_est_for_b {
          z_arr_b[i]
        } else {
          pq_est_for_b
        }
      }
      let residual_g_b = vector_subtract(g_target_arr_b, g_hat)
      let ratio_b = vector_divide(residual_g_b, m_final, eps=1.0e-10)
      let weighted_b = vector_multiply(treated, ratio_b)
      last_psi_b = vector_add(weighted_b, g_hat)
    }
    let (theta, se) = aggregate_coef_se(coefs, ses)
    // v0.83.0+: when memoize is on and the cache missed, write
    // the freshly-computed fold_ids + nuisances (incl. ipw_vec,
    // needed for the cache-hit path's `pq_est` recomputation)
    // to the cache.
    let next_cache = if memoize && !cache_hit && self.n_rep == 1 {
      FitCache::from_fit(
        fold_ids,
        [last_g, last_m, last_ipw_vec],
        self.seed,
        self.n_folds,
        self.n_rep,
        n,
        data_hash,
        hparams_hash,
        cluster_hash,
        "cvar",
      )
    } else {
      self.fit_cache
    }
    {
      data: self.data,
      treatment: self.treatment,
      quantile: self.quantile,
      n_folds: self.n_folds,
      n_rep: self.n_rep,
      seed: self.seed,
      propensity_clip: self.propensity_clip,
      normalize_ipw: self.normalize_ipw,
      ml_g,
      ml_m,
      g_hat: last_g,
      m_hat: last_m,
      coef: theta,
      se,
      fitted: true,
      psi_a: last_psi_a,
      psi_b: last_psi_b,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      memoize_enabled: self.memoize_enabled,
      fit_cache: next_cache,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.75.0+: multiplier bootstrap for `DoubleMLCVAR`. The
/// per-observation influence function is
///
///   psi[i] = theta * psi_a[i] + psi_b[i]
///          = -1 + theta * psi_b[i]
///
/// where `psi_b[i] = 1{d==treatment} * (g_target - g_hat) /
/// m_hat + g_hat` is computed at the fitted `coef` from the
/// last rep's cross-fitted nuisances `(g_hat, m_hat)` and
/// `g_target = max(coef, (y - q*coef) / (1 - q))`. `psi_a` is
/// the constant `-1` vector. Same IRM-style IF shape as
/// `DoubleMLIRM` (constant derivative + offset score); the
/// score-form IF identical to the v0.71.0
/// `DoubleMLCVAR::sensitivity_analysis` psi_a = -1
/// decomposition.
///
/// `method_name` selects the multiplier distribution:
/// `"normal"` (default), `"Bayes"`, `"wild"`; `seed` defaults
/// to `2024`; `n_rep_boot` defaults to `500`.
///
/// Calling on an un-fit model aborts via `PreconditionError`.
/// Returns a new `DoubleMLCVAR` with `boot_t_stat` /
/// `boot_method` / `n_rep_boot` / `boot_seed` populated.
pub fn DoubleMLCVAR::bootstrap(
  self : DoubleMLCVAR,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLCVAR {
  try {
    require(self.fitted)
    require(
      method_name == "normal" || method_name == "Bayes" || method_name == "wild",
    )
    require(n_rep_boot >= 2)
    let boot_t_stat = generic_bootstrap_t_stat(
      self.psi_a,
      self.psi_b,
      self.coef,
      method_name,
      n_rep_boot,
      seed,
    ) catch {
      BootstrapMethodError::UnknownMethod(m) =>
        abort(
          "draw_bootstrap_weights: unknown method (set in DoubleMLCVAR::bootstrap): " +
          m,
        )
    }
    {
      ..self,
      boot_t_stat,
      boot_method: method_name,
      n_rep_boot,
      boot_seed: seed,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.86.0+: Huber-White sandwich standard error for the
/// fitted CVAR. Returns `sqrt(var)` where `var` comes from
/// the shared `sandwich_variance(kind, ...)` dispatch in
/// `sandwich.mbt` (HC0 / HC1 / HC2 / HC3).
///
/// The three inputs are the ones `fit(...)` already persists
/// for the multiplier bootstrap (see the `psi_a` / `psi_b`
/// field docs on `DoubleMLCVAR`):
///   - `psi_a`  = `self.psi_a` -- the constant `-1` IRM-style
///     Riesz representer, so `mean(psi_a) = -1` and
///     `M_inv = -1`.
///   - `psi`    = `psi_at(self.coef, self.psi_a, self.psi_b)`
///     -- the per-observation influence function evaluated at
///     the fitted `coef`, where `psi_b` carries the IPW
///     weighting:
///     `1{d == treatment} * (g_target - g_hat) / m_hat + g_hat`
///     with `g_target = max(coef, (y - q * coef) / (1 - q))`.
///     Same `psi_at` score order as IRM / PLR.
///   - `M_inv`  = `[[1 / mean(psi_a)]]` (1x1). Only
///     `M_inv[0, 0]^2` enters the variance, so the sign of
///     the (up-to-sign) Jacobian inverse is irrelevant.
///
/// Preconditions: `self.fitted`, `mean(psi_a) != 0`.
pub fn DoubleMLCVAR::sandwich_se(
  self : DoubleMLCVAR,
  kind : SandwichKind,
) -> Double {
  try {
    require(self.fitted)
    let n = self.n_obs()
    let psi = psi_at(self.coef, self.psi_a, self.psi_b)
    let mean_a = mean(self.psi_a)
    require(mean_a.abs() > 0.0)
    let m_inv = Matrix::from_array([1.0 / mean_a], 1, 1)
    let variance_val = sandwich_variance(kind, self.psi_a, psi, m_inv, n, 1)
    require(variance_val >= 0.0)
    variance_val.sqrt()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.86.0+: cluster-robust sandwich standard error for the
/// fitted CVAR. Routes through `cluster_sandwich_variance`
/// with the same `psi_a` / `psi` / `M_inv` inputs as the IID
/// `sandwich_se` path.
///
/// Preconditions: `self.fitted`,
/// `cluster_ids.length() == n_obs`.
pub fn DoubleMLCVAR::cluster_sandwich_se(
  self : DoubleMLCVAR,
  cluster_ids : Array[Int],
) -> Double {
  try {
    require(self.fitted)
    let n = self.n_obs()
    require(cluster_ids.length() == n)
    let psi = psi_at(self.coef, self.psi_a, self.psi_b)
    let mean_a = mean(self.psi_a)
    require(mean_a.abs() > 0.0)
    let m_inv = Matrix::from_array([1.0 / mean_a], 1, 1)
    let variance_val = cluster_sandwich_variance(
      self.psi_a,
      psi,
      m_inv,
      cluster_ids,
      1,
    )
    require(variance_val >= 0.0)
    variance_val.sqrt()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.86.0+: finite-sample bias-corrected CVAR coefficient.
/// Same `psi_b - coef * psi_a` per-observation bias form as
/// `DoubleMLIRM::bias_corrected_coef`:
///
///     bias_per_obs[i] = psi_b[i] - coef * psi_a[i]
///     theta_corrected = coef + mean(bias_per_obs)
///
/// Because CVAR's `psi_a` is the constant `-1`, this reduces
/// to `2 * coef + mean(psi_b)`.
///
/// Preconditions: `self.fitted`.
pub fn DoubleMLCVAR::bias_corrected_coef(self : DoubleMLCVAR) -> Double {
  try {
    require(self.fitted)
    let n = self.n_obs()
    let bias : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      bias[i] = self.psi_b[i] - self.coef * self.psi_a[i]
    }
    bias_corrected_theta(self.coef, bias)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
