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
  learner : LearnerDispatch,
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
      let p = fit_predict_one_dispatch(
        learner,
        slice_matrix_rows(x, tr),
        slice_vector(target, tr),
        slice_matrix_rows(x, te),
      )
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
  learner : LearnerDispatch,
  x : Matrix,
  treated : Array[Double],
  folds : Array[Fold],
  clip : Double,
) -> Array[Double] {
  let m = Array::make(x.rows(), 0.0)
  for fold in folds {
    let tr = fold.train_indices()
    let te = fold.test_indices()
    let p = fit_predict_one_dispatch(
      learner,
      slice_matrix_rows(x, tr),
      slice_vector(treated, tr),
      slice_matrix_rows(x, te),
    )
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
  ml_l : LearnerDispatch,
  ml_m : LearnerDispatch,
  data : DoubleMLData,
  treatment : Double,
  q : Double,
  n_folds : Int,
  seed : Int,
  clip : Double,
  folds? : Array[Fold] = [],
) -> (Double, Array[Double], Double) raise BracketSignError {
  let treated = indicator_level(data.d, treatment)
  let folds = if folds.length() == 0 {
    kfold(data.n_obs(), n_folds, seed)
  } else {
    folds
  }
  let m = fit_propensity(ml_m, data.x, treated, folds, clip)
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
  let g = cross_fit_conditional(ml_l, data.x, iy, treated, folds)
  // Build the influence-function psi using g(theta).
  let psi = Array::make(data.n_obs(), 0.0)
  for i = 0; i < data.n_obs(); i = i + 1 {
    psi[i] = treated[i] * (iy[i] - g[i]) / m[i] + g[i] - q
  }
  // Numerical derivative via 2 more cross-fits at theta +/- h.
  let h = (y_max - y_min) * 1.0e-2 + 1.0e-8
  let iyp = outcome_indicator(data.y, theta + h)
  let iym = outcome_indicator(data.y, theta - h)
  let gp = cross_fit_conditional(ml_l, data.x, iyp, treated, folds)
  let gm = cross_fit_conditional(ml_l, data.x, iym, treated, folds)
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
  // v0.60.0+: injected nuisance learners (replaces the
  // v0.59.0 hardcoded `LinearRegression` used internally by
  // `solve_pq`). Defaults to OLS so v0.59.0 callers see
  // byte-identical results. v0.61.0+ will plumb these through
  // `solve_pq`; for v0.60.0 they're stored on the struct and
  // returned via `learner_l() / learner_m()` but not yet
  // consumed internally (`solve_pq` continues to use its own
  // `LinearRegression::new()` instances).
  ml_l : LearnerDispatch
  ml_m : LearnerDispatch
  coef : Double
  se : Double
  fitted : Bool
  // v0.64.0+: per-observation influence function at the fitted
  // `coef`. Persisted from `solve_pq(...)` so the multiplier
  // bootstrap can use it without recomputing.
  psi : Array[Double]
  // v0.64.0+: multiplier bootstrap state. `boot_t_stat` is a
  // length-`n_rep_boot` array of t-statistics for `coef`.
  // Populated by `bootstrap(...)`; empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
} derive(Debug)

///|
pub extend DoubleMLPQ with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLPQ::new(
  data : DoubleMLData,
  treatment? : Double = 1.0,
  quantile? : Double = 0.5,
  n_folds? : Int = 2,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
  ml_l? : LearnerDispatch = LearnerDispatch::linear_regression(),
  ml_m? : LearnerDispatch = LearnerDispatch::linear_regression(),
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
      ml_l,
      ml_m,
      coef: 0.0,
      se: 0.0,
      fitted: false,
      psi: Array::make(data.y.length(), 0.0),
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLPQ::fit(
  self : DoubleMLPQ,
  ml_l? : LearnerDispatch = self.ml_l,
  ml_m? : LearnerDispatch = self.ml_m,
) -> DoubleMLPQ {
  // v0.67.0+: cluster-data dispatch — when `cluster_vars` is
  // non-empty, route through `fit_cluster` (cluster-aware
  // folds, unit-level cluster-robust SE).
  if self.data.is_cluster_data() {
    return self.fit_cluster(ml_l~, ml_m~)
  }
  let (theta, psi, deriv) = solve_pq(
    ml_l,
    ml_m,
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
    ml_l,
    ml_m,
    coef: theta,
    se,
    fitted: true,
    psi,
    boot_t_stat: [],
    boot_method: "",
    n_rep_boot: 0,
    boot_seed: 0,
  }
}

///|
/// v0.67.0+: clustered-DML path for `DoubleMLPQ`. Builds
/// cluster folds via `kfold` on unique unit ids +
/// `expand_unit_folds_to_rows`, runs `solve_pq` with the
/// cluster folds for cross-fit (so the propensity and
/// outcome nuisances are computed without sibling-row
/// leakage), and computes a unit-level cluster-robust SE
/// from the per-observation IF `psi`. Aggregates
/// `theta` and `se` across reps via mean (matches the IRM
/// cluster path's `aggregate_coef_se`).
fn DoubleMLPQ::fit_cluster(
  self : DoubleMLPQ,
  ml_l~ : LearnerDispatch,
  ml_m~ : LearnerDispatch,
) -> DoubleMLPQ {
  try {
    let cluster = self.data.cluster_vars
    let n = self.n_obs()
    let uniq = unique_units(cluster)
    let n_units = uniq.length()
    require(self.n_folds <= n_units)
    let row_unit = build_row_unit_map(cluster, uniq) catch {
      ClusterDataError::MissingUnit(g) =>
        abort(
          "expand_unit_folds_to_rows: row without a unit id (unit_id=" +
          g.to_string() +
          ")",
        )
    }
    let unit_rows : Array[Array[Int]] = Array::makei(n_units, fn(_) {
      let rows : Array[Int] = []
      rows
    })
    for i = 0; i < n; i = i + 1 {
      unit_rows[row_unit[i]].push(i)
    }
    let coefs : Array[Double] = Array::make(1, 0.0)
    let ses : Array[Double] = Array::make(1, 0.0)
    let mut last_psi : Array[Double] = Array::make(n, 0.0)
    // PQ is a single-fit estimator (no `n_rep`). The cluster
    // path runs `solve_pq` once under cluster folds and
    // computes the cluster SE from that single rep.
    let rep_seed = self.seed
    let folds_u = kfold(n_units, self.n_folds, rep_seed)
    let (folds_row, _unit_fold, _fold_n_units) = expand_unit_folds_to_rows(
      cluster, folds_u, row_unit,
    )
    let (theta_r, psi_r, deriv_r) = solve_pq(
      ml_l,
      ml_m,
      self.data,
      self.treatment,
      self.quantile,
      self.n_folds,
      rep_seed,
      self.propensity_clip,
      folds=folds_row,
    ) catch {
      BracketSignError::UpperSignFailed =>
        abort(
          "solve_pq: upper bracket sign failed after 20 widens (cluster-aware folds)",
        )
    }
    let n_units_d = n_units.to_double()
    let mut sum_units = 0.0
    let mut ss_units = 0.0
    for u = 0; u < n_units; u = u + 1 {
      let mut s_u = 0.0
      for idx in unit_rows[u] {
        s_u = s_u + psi_r[idx]
      }
      sum_units = sum_units + s_u
      ss_units = ss_units + s_u * s_u
    }
    let mean_unit = sum_units / n_units_d
    let var_unit = (ss_units - n_units_d * mean_unit * mean_unit) / n_units_d
    let se_r = (var_unit / (deriv_r * deriv_r * n_units_d)).sqrt()
    coefs[0] = theta_r
    ses[0] = se_r
    last_psi = psi_r
    let (coef, se) = aggregate_coef_se(coefs, ses)
    {
      data: self.data,
      treatment: self.treatment,
      quantile: self.quantile,
      n_folds: self.n_folds,
      seed: self.seed,
      propensity_clip: self.propensity_clip,
      ml_l,
      ml_m,
      coef,
      se,
      fitted: true,
      psi: last_psi,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Accessor for the outcome-quantile-nuisance learner used by
/// the most recent `fit(...)` call. v0.60.0+.
pub fn DoubleMLPQ::learner_l(self : DoubleMLPQ) -> LearnerDispatch {
  self.ml_l
}

///|
/// Accessor for the propensity-score learner used by the most
/// recent `fit(...)` call. v0.60.0+.
pub fn DoubleMLPQ::learner_m(self : DoubleMLPQ) -> LearnerDispatch {
  self.ml_m
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
/// v0.67.0+: `joint` is a no-op for single-theta estimators;
/// accepted for API parity.
pub fn DoubleMLPQ::confint(
  self : DoubleMLPQ,
  joint? : Bool = false,
  level? : Double = 0.95,
) -> (Double, Double) {
  try {
    require(self.fitted)
    require(level > 0.0 && level < 1.0)
    let z = norm_ppf(1.0 - (1.0 - level) / 2.0)
    ignore(joint)
    (self.coef - z * self.se, self.coef + z * self.se)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.64.0+: multiplier bootstrap for `DoubleMLPQ`. The
/// per-observation influence function `psi` is the centered
/// IPW quantile score at the bisection root (mean 0,
/// `se_psi = sqrt(mean(psi^2))` is the bootstrap denominator).
/// Routes through the shared `generic_bootstrap_single_psi`
/// helper (see `bootstrap_helper.mbt`).
///
/// `method_name` selects the multiplier distribution:
/// `"normal"` (default), `"Bayes"`, `"wild"`. `seed` defaults
/// to `2024`; `n_rep_boot` defaults to `500`.
///
/// Calling on an un-fit model aborts via `PreconditionError`.
pub fn DoubleMLPQ::bootstrap(
  self : DoubleMLPQ,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLPQ {
  try {
    require(self.fitted)
    require(
      method_name == "normal" || method_name == "Bayes" || method_name == "wild",
    )
    require(n_rep_boot >= 2)
    let boot_t_stat = generic_bootstrap_single_psi(
      self.psi,
      method_name,
      n_rep_boot,
      seed,
    ) catch {
      BootstrapMethodError::UnknownMethod(m) =>
        abort(
          "draw_bootstrap_weights: unknown method (set in DoubleMLPQ::bootstrap): " +
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
/// v0.67.0+: Cinelli & Hazlett (2020) omitted-variable bias
/// analysis for `DoubleMLPQ` (partial quantile). The IF
/// `psi` is centered (mean 0 at the bisection root);
/// `nu2 = mean(psi^2)` and `sigma2 = Var(y)`. Routes
/// through the shared `single_psi_sensitivity` helper (see
/// sensitivity.mbt).
pub fn DoubleMLPQ::sensitivity_analysis(
  self : DoubleMLPQ,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  single_psi_sensitivity(self.coef, self.psi, self.data.y, cf_y, cf_d)
}

///|
pub struct DoubleMLQTE {
  data : DoubleMLData
  quantiles : Array[Double]
  n_folds : Int
  seed : Int
  propensity_clip : Double
  // v0.60.0+: injected nuisance learners (same forward-
  // compat story as `DoubleMLPQ`).
  ml_l : LearnerDispatch
  ml_m : LearnerDispatch
  coefs : Array[Double]
  ses : Array[Double]
  // v0.64.0+: per-quantile influence function flat matrix
  // `[n_quantiles * n_obs]` (`psi_flat[j * n_obs + i]` = IF
  // for the `theta_d1 - theta_d0` combination at observation
  // `i`). Populated by `fit`; required by the multiplier
  // bootstrap.
  psi_flat : Array[Double]
  // v0.64.0+: multiplier bootstrap state. `boot_t_stat` is
  // a flat `[n_rep_boot * n_quantiles]` array of t-statistics.
  // Populated by `bootstrap(...)`; empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
} derive(Debug)

///|
pub extend DoubleMLQTE with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLQTE::new(
  data : DoubleMLData,
  quantiles? : Array[Double] = [0.5],
  n_folds? : Int = 2,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
  ml_l? : LearnerDispatch = LearnerDispatch::linear_regression(),
  ml_m? : LearnerDispatch = LearnerDispatch::linear_regression(),
) -> DoubleMLQTE {
  {
    data,
    quantiles,
    n_folds,
    seed,
    propensity_clip,
    ml_l,
    ml_m,
    coefs: Array::make(quantiles.length(), 0.0),
    ses: Array::make(quantiles.length(), 0.0),
    psi_flat: Array::make(quantiles.length() * data.n_obs(), 0.0),
    boot_t_stat: [],
    boot_method: "",
    n_rep_boot: 0,
    boot_seed: 0,
  }
}

///|
pub fn DoubleMLQTE::fit(
  self : DoubleMLQTE,
  ml_l? : LearnerDispatch = self.ml_l,
  ml_m? : LearnerDispatch = self.ml_m,
) -> DoubleMLQTE {
  // v0.67.0+: cluster-data dispatch — when `cluster_vars` is
  // non-empty, route through `fit_cluster` (cluster-aware
  // folds, unit-level cluster-robust SE).
  if self.data.is_cluster_data() {
    return self.fit_cluster(ml_l~, ml_m~)
  }
  let c = Array::make(self.quantiles.length(), 0.0)
  let s = Array::make(self.quantiles.length(), 0.0)
  let n_obs = self.data.n_obs()
  let psi_flat : Array[Double] = Array::make(
    self.quantiles.length() * n_obs,
    0.0,
  )
  for j = 0; j < self.quantiles.length(); j = j + 1 {
    let (theta1, psi1, deriv1) = solve_pq(
      ml_l,
      ml_m,
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
      ml_l,
      ml_m,
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
    let n = self.data.n_obs().to_double()
    let mut gamma = 0.0
    for i = 0; i < psi1.length(); i = i + 1 {
      let u = psi1[i] / deriv1 - psi0[i] / deriv0
      psi_flat[j * n_obs + i] = u
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
    ml_l,
    ml_m,
    coefs: c,
    ses: s,
    psi_flat,
    boot_t_stat: [],
    boot_method: "",
    n_rep_boot: 0,
    boot_seed: 0,
  }
}

///|
/// v0.67.0+: clustered-DML path for `DoubleMLQTE`. Same
/// pattern as `DoubleMLPQ::fit_cluster` but with two
/// `solve_pq` calls per quantile (treated `d=1` and
/// control `d=0`) and the delta-method SE formula
/// `se_qte^2 = mean_unit((u)^2) / n_units` where
/// `u[i] = psi_d1[i] / deriv_d1 - psi_d0[i] / deriv_d0` is
/// the per-observation QTE influence function.
fn DoubleMLQTE::fit_cluster(
  self : DoubleMLQTE,
  ml_l~ : LearnerDispatch,
  ml_m~ : LearnerDispatch,
) -> DoubleMLQTE {
  try {
    let cluster = self.data.cluster_vars
    let n_obs = self.data.n_obs()
    let uniq = unique_units(cluster)
    let n_units = uniq.length()
    require(self.n_folds <= n_units)
    let row_unit = build_row_unit_map(cluster, uniq) catch {
      ClusterDataError::MissingUnit(g) =>
        abort(
          "expand_unit_folds_to_rows: row without a unit id (unit_id=" +
          g.to_string() +
          ")",
        )
    }
    let unit_rows : Array[Array[Int]] = Array::makei(n_units, fn(_) {
      let rows : Array[Int] = []
      rows
    })
    for i = 0; i < n_obs; i = i + 1 {
      unit_rows[row_unit[i]].push(i)
    }
    let c = Array::make(self.quantiles.length(), 0.0)
    let s = Array::make(self.quantiles.length(), 0.0)
    let psi_flat : Array[Double] = Array::make(
      self.quantiles.length() * n_obs,
      0.0,
    )
    let rep_seed = self.seed
    let folds_u = kfold(n_units, self.n_folds, rep_seed)
    let (folds_row, _unit_fold, _fold_n_units) = expand_unit_folds_to_rows(
      cluster, folds_u, row_unit,
    )
    let n_units_d = n_units.to_double()
    for j = 0; j < self.quantiles.length(); j = j + 1 {
      let (theta1, psi1, deriv1) = solve_pq(
        ml_l,
        ml_m,
        self.data,
        1.0,
        self.quantiles[j],
        self.n_folds,
        rep_seed,
        self.propensity_clip,
        folds=folds_row,
      ) catch {
        BracketSignError::UpperSignFailed =>
          abort(
            "solve_pq: upper bracket sign failed after 20 widens (cluster-aware folds)",
          )
      }
      let (theta0, psi0, deriv0) = solve_pq(
        ml_l,
        ml_m,
        self.data,
        0.0,
        self.quantiles[j],
        self.n_folds,
        rep_seed,
        self.propensity_clip,
        folds=folds_row,
      ) catch {
        BracketSignError::UpperSignFailed =>
          abort(
            "solve_pq: upper bracket sign failed after 20 widens (cluster-aware folds)",
          )
      }
      c[j] = theta1 - theta0
      let u : Array[Double] = Array::make(n_obs, 0.0)
      for i = 0; i < n_obs; i = i + 1 {
        u[i] = psi1[i] / deriv1 - psi0[i] / deriv0
        psi_flat[j * n_obs + i] = u[i]
      }
      let mut sum_units = 0.0
      let mut ss_units = 0.0
      for u_idx = 0; u_idx < n_units; u_idx = u_idx + 1 {
        let mut s_u = 0.0
        for idx in unit_rows[u_idx] {
          s_u = s_u + u[idx]
        }
        sum_units = sum_units + s_u
        ss_units = ss_units + s_u * s_u
      }
      let mean_unit = sum_units / n_units_d
      let var_unit = (ss_units - n_units_d * mean_unit * mean_unit) / n_units_d
      s[j] = (var_unit / n_units_d).sqrt()
    }
    {
      data: self.data,
      quantiles: self.quantiles,
      n_folds: self.n_folds,
      seed: self.seed,
      propensity_clip: self.propensity_clip,
      ml_l,
      ml_m,
      coefs: c,
      ses: s,
      psi_flat,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|

///|
/// Accessor for the outcome-quantile-nuisance learner used by
/// the most recent `fit(...)` call. v0.60.0+.
pub fn DoubleMLQTE::learner_l(self : DoubleMLQTE) -> LearnerDispatch {
  self.ml_l
}

///|
/// Accessor for the propensity-score learner used by the most
/// recent `fit(...)` call. v0.60.0+.
pub fn DoubleMLQTE::learner_m(self : DoubleMLQTE) -> LearnerDispatch {
  self.ml_m
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
/// v0.66.0+: Wald-style 95% pointwise confidence intervals
/// for `DoubleMLQTE`. Returns one `(lo, hi)` tuple per
/// quantile, in user-supplied order. `joint = true` uses a
/// max-|t|-bootstrap critical value (requires
/// `bootstrap(...)` to have been called); the returned CIs
/// are wider.
pub fn DoubleMLQTE::confint(
  self : DoubleMLQTE,
  level? : Double = 0.95,
  joint? : Bool = false,
) -> Array[(Double, Double)] {
  try {
    require(self.coefs.length() > 0)
    require(level > 0.0 && level < 1.0)
    if joint {
      require(self.boot_t_stat.length() > 0)
    }
    let alpha = 1.0 - level
    let mut z = norm_ppf(1.0 - alpha / 2.0)
    let n_q = self.quantiles.length()
    let out : Array[(Double, Double)] = Array::make(n_q, (0.0, 0.0))
    if joint {
      let n_boot = self.n_rep_boot
      let max_t_arr : Array[Double] = Array::make(n_boot, 0.0)
      for b = 0; b < n_boot; b = b + 1 {
        let mut mx = 0.0
        for j = 0; j < n_q; j = j + 1 {
          let t : Double = self.boot_t_stat[b * n_q + j]
          let abs_t : Double = if t < 0.0 { -t } else { t }
          if abs_t > mx {
            mx = abs_t
          }
        }
        max_t_arr[b] = mx
      }
      max_t_arr.sort()
      let idx = ((n_boot - 1).to_double() * (1.0 - alpha)).to_int()
      z = max_t_arr[idx]
    }
    for j = 0; j < n_q; j = j + 1 {
      let lo = self.coefs[j] - z * self.ses[j]
      let hi = self.coefs[j] + z * self.ses[j]
      out[j] = (lo, hi)
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.64.0+: multiplier bootstrap for `DoubleMLQTE`. The
/// per-quantile per-observation influence function is
/// `u[i, j] = psi_d1[i] / deriv_d1 - psi_d0[i] / deriv_d0` (the
/// delta-method IF for `theta_qte = theta_d1 - theta_d0`);
/// `psi_flat` is the flat `[n_quantiles * n_obs]` row-major
/// matrix that `fit` populates. Routes through the shared
/// `generic_bootstrap_psi_matrix` helper (see
/// `bootstrap_helper.mbt`).
///
/// `method_name` selects the multiplier distribution:
/// `"normal"` (default), `"Bayes"`, `"wild"`. `seed` defaults
/// to `2024`; `n_rep_boot` defaults to `500`.
///
/// `boot_t_stat` is a flat `[n_rep_boot * n_quantiles]` array
/// (row-major by rep, then by quantile). Calling on an un-fit
/// model aborts via `PreconditionError`.
pub fn DoubleMLQTE::bootstrap(
  self : DoubleMLQTE,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLQTE {
  try {
    require(self.coefs.length() > 0)
    require(
      method_name == "normal" || method_name == "Bayes" || method_name == "wild",
    )
    require(n_rep_boot >= 2)
    let n_obs = self.data.n_obs()
    let n_thetas = self.quantiles.length()
    let boot_t_stat = generic_bootstrap_psi_matrix(
      self.psi_flat,
      self.ses,
      method_name,
      n_rep_boot,
      n_obs,
      n_thetas,
      seed,
    ) catch {
      BootstrapMethodError::UnknownMethod(m) =>
        abort(
          "draw_bootstrap_weights: unknown method (set in DoubleMLQTE::bootstrap): " +
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
