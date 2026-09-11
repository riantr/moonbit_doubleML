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
  g_hat : Array[Double]
  m_hat : Array[Double]
  coef : Double
  se : Double
  fitted : Bool
} derive(Debug)

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
    g_hat: Array::make(data.n_obs(), 0.0),
    m_hat: Array::make(data.n_obs(), 0.0),
    coef: 0.0,
    se: 0.0,
    fitted: false,
  }
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
/// Stratum 50/50 split of `train` on the values of `d[train]`,
/// using a deterministic Fisher-Yates shuffle keyed by `seed`.
/// Returns `(s1, s2)` such that `s1 ∪ s2 = train`,
/// `s1 ∩ s2 = ∅`, and within each stratum the partition is
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
  // for `q` close to 1 with sparse treatment — same condition
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
    let fitted = LinearRegression::new().fit(
      slice_matrix_rows(x, prelim_train_global),
      slice_vector(treated, prelim_train_global),
    )
    let p = fitted.predict(slice_matrix_rows(x, prelim_test_global))
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
    LinearRegression::new()
    .fit(
      slice_matrix_rows(x, train_2_treat),
      slice_vector(g_target, train_2_treat),
    )
    .predict(slice_matrix_rows(x, eval_set))
  } else {
    Array::make(eval_set.length(), 0.0)
  }
  // 6) refit `ml_m` on the full `train` and predict on `eval_set`.
  let m_hat_test = LinearRegression::new()
    .fit(slice_matrix_rows(x, train), slice_vector(d, train))
    .predict(slice_matrix_rows(x, eval_set))
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
pub fn DoubleMLCVAR::fit(self : DoubleMLCVAR) -> DoubleMLCVAR {
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
  for r = 0; r < self.n_rep; r = r + 1 {
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
    // `pq_est = mean(ipw_vec)`. Matches the upstream
    // `pq_est = np.mean(ipw_vec)` (Kallus et al., p.4).
    let pq_est = mean(ipw_vec)
    // psi_a, psi_b with `g_target = max(pq_est, (y - q*pq_est)
    // / (1-q))`.
    let psi_a = Array::make(n, -1.0)
    let psi_b = Array::make(n, 0.0)
    let q_comp = 1.0 - self.quantile
    for i = 0; i < n; i = i + 1 {
      let z = (self.data.y[i] - self.quantile * pq_est) / q_comp
      let g_target = if z > pq_est { z } else { pq_est }
      psi_b[i] = treated[i] * (g_target - g_hat[i]) / m_final[i] + g_hat[i]
    }
    let (theta_r, se_r) = var_est(psi_a, psi_b)
    coefs[r] = theta_r
    ses[r] = se_r
    // The public accessors return the *last* rep's
    // `g_hat` / `m_hat`, matching the rest of the package's
    // convention (and the upstream `doubleml.DoubleML` summary
    // table, which only carries the last rep's nuisances).
    last_g = g_hat
    last_m = m_final
  }
  let (theta, se) = aggregate_coef_se(coefs, ses)
  {
    data: self.data,
    treatment: self.treatment,
    quantile: self.quantile,
    n_folds: self.n_folds,
    n_rep: self.n_rep,
    seed: self.seed,
    propensity_clip: self.propensity_clip,
    normalize_ipw: self.normalize_ipw,
    g_hat: last_g,
    m_hat: last_m,
    coef: theta,
    se,
    fitted: true,
  }
}
