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
  // score is structurally non-monotonic -- caller's data is bad).
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
  // v0.94.0+: the PQ score's theta-derivative at `coef`, i.e.
  // `d mean(psi(theta)) / d theta` (the central-difference
  // `deriv` `solve_pq` returns -- the IPW-weighted density of
  // `y` at `theta` among the treated). Persisted because the
  // sandwich variance needs it as the Jacobian
  // (`M_inv = 1 / deriv`) and it cannot be recovered after
  // `fit()` returns. Length `n_obs`, every entry equal to the
  // same scalar -- the derivative of a MEAN is a scalar, so a
  // per-observation array here is a uniform-API convenience,
  // not a claim of per-observation variation. It is emphatically
  // NOT a constant: see the section comment above the sandwich
  // methods.
  psi_a : Array[Double]
  // v0.64.0+: multiplier bootstrap state. `boot_t_stat` is a
  // length-`n_rep_boot` array of t-statistics for `coef`.
  // Populated by `bootstrap(...)`; empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
  // v0.84.0+: memoization state. `memoize_enabled` is the
  // user-facing opt-in (set via `DoubleMLPQ::enable_memoize()`);
  // when true, `fit()` caches the LAST solve_pq's `(theta,
  // psi, deriv)` plus row-to-fold mapping in `fit_cache` and
  // reuses them on the next `fit()` call (skipping the entire
  // propensity cross-fit + bisection + 3x outcome cross-fits).
  // The `(coef, se)` aggregation from cached values still runs
  // on every `fit()`, so changing the propensity-clip / quantile
  // configuration always takes effect through the data hash.
  memoize_enabled : Bool
  fit_cache : FitCache
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
      psi_a: Array::make(data.y.length(), 0.0),
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      // v0.84.0+: memoize starts disabled; opt in via
      // `.enable_memoize()` for caching.
      memoize_enabled: false,
      fit_cache: FitCache::empty(),
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
  // v0.67.0+: cluster-data dispatch -- when `cluster_vars` is
  // non-empty, route through `fit_cluster` (cluster-aware
  // folds, unit-level cluster-robust SE).
  if self.data.is_cluster_data() {
    return self.fit_cluster(ml_l~, ml_m~)
  }
  let n = self.data.n_obs()
  // v0.84.0+: memoize check (mirrors the per-estimator
  // pattern). PQ is a single-fit estimator (no `n_rep`),
  // so memoize is honored unconditionally when enabled --
  // the cache stores the LAST (and only) `solve_pq` call's
  // `(theta, psi, deriv)` plus row-to-fold mapping. On a
  // cache hit we skip the entire `solve_pq` (propensity
  // cross-fit + bisection + 3x outcome cross-fits) and just
  // recompute the `(coef, se)` aggregation from cached
  // values.
  let memoize = self.memoize_enabled
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
    hash_hyperparams("pq", ml_l, ml_m, self.propensity_clip)
  } else {
    0UL
  }
  let cluster_hash : UInt64 = if memoize {
    hash_cluster_ids(self.data.cluster_vars)
  } else {
    0UL
  }
  // PQ's `solve_pq` uses `n_folds` outer folds with no
  // rep loop, so the cache key matches the IID path's
  // `(n_folds=2..k, n_rep=1, n_obs=n)` shape.
  let cache_hit = memoize &&
    self.fit_cache.is_valid(
      self.seed,
      self.n_folds,
      1,
      n,
      data_hash,
      hparams_hash,
      cluster_hash,
      "pq",
    )
  let (theta, psi, deriv, fold_ids) = if cache_hit {
    // Reuse the cached `(theta, deriv)` pair and `psi`
    // vector. The row-to-fold map is also pulled (we
    // don't actually need it for PQ's score, but it
    // anchors the FitCache contract that
    // `fold_ids.length() == n_obs`).
    let preds = self.fit_cache.predictions
    let cached_fold_ids = self.fit_cache.fold_ids
    let local_fold_ids : Array[Int] = Array::make(n, 0)
    for i = 0; i < n; i = i + 1 {
      local_fold_ids[i] = cached_fold_ids[i]
    }
    (preds[0][0], preds[1], preds[0][1], local_fold_ids)
  } else {
    let folds = kfold(n, self.n_folds, self.seed)
    let (t, p, d) = solve_pq(
      ml_l,
      ml_m,
      self.data,
      self.treatment,
      self.quantile,
      self.n_folds,
      self.seed,
      self.propensity_clip,
      folds~,
    ) catch {
      BracketSignError::UpperSignFailed =>
        abort(
          "solve_pq: upper bracket sign failed after 20 widens (q too close to 1 with sparse treatment, or quantile is non-monotonic in this data)",
        )
    }
    let local_fold_ids : Array[Int] = Array::make(n, 0)
    for f = 0; f < folds.length(); f = f + 1 {
      for i in folds[f].test_indices() {
        local_fold_ids[i] = f
      }
    }
    (t, p, d, local_fold_ids)
  }
  let n_d = n.to_double()
  // v0.94.0+: persist the Jacobian as a uniform-API length-`n_obs`
  // array of the SAME scalar on every row, so `mean(psi_a) == deriv`
  // and `sandwich_variance`'s `psi_a` slot can be filled directly.
  //
  // Placement is load-bearing for the memoize path. `deriv` is
  // RECONPUTED only on a cache MISS (on a hit it is restored from
  // `FitCache.predictions[0][1]`, packed alongside `theta` since
  // v0.84.0), but it is bound to the SAME name on BOTH paths by the
  // `(theta, psi, deriv, fold_ids)` destructuring above. Building
  // `psi_a` from that single binding -- after the `cache_hit` branch
  // -- is therefore correct on both paths by construction, and there
  // is no second restore path that can drift.
  // `expand_v094_test.mbt::pq_sandwich_after_memoize_cache_hit` pins
  // that.
  let psi_a : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    psi_a[i] = deriv
  }
  // SE = sqrt(E[psi^2] / n) / |deriv|, the standard
  // one-step influence-function variance for a Z-estimator.
  // v0.84.0+: vectorise the `gamma = sum(psi^2)` accumulator
  // by multiplying psi by itself and summing via `vector_*`
  // helpers. Because `psi * psi` is element-wise square,
  // `vector_multiply(psi, psi)` and `mean()` give the same
  // sum-of-squares as the inline loop.
  //
  // v0.94.0: `deriv` is `d mean(psi(theta)) / d theta` at the
  // bisection root -- the IPW-weighted density of `y` at `theta`
  // among the treated, from the central difference in `solve_pq`.
  // It is DATA-DEPENDENT, not a constant of the estimator: PQ is a
  // quantile Z-estimator whose estimating equation is the
  // FIRST-ORDER CONDITION `mean(psi(theta)) = 0`, not the
  // package-wide `f(theta) = E[theta * psi_a + psi_b]` mean moment,
  // so there is no per-observation coefficient row to read a
  // constant off. Reading `M_inv` as `-1` (or `+1`) instead of
  // `1 / deriv` shrinks the SE by `|deriv|`; on the v0.94.0 DGP
  // that is 4.74x (0.18237 -> 0.03845 on a `coef` of 5.13). Pinned
  // by `expand_v094_test.mbt`.
  let psi_sq = vector_multiply(psi, psi)
  let gamma = mean(psi_sq)
  let se = (gamma / (deriv * deriv * n_d)).sqrt()
  // v0.84.0+: when memoize is on and the cache missed, write
  // the freshly-computed `(theta, deriv, psi, fold_ids)` to
  // the cache. Pack `theta` and `deriv` as a length-2
  // array (`predictions[0]`) so the cache-hit path can pull
  // both scalars back without reshaping.
  let next_cache = if memoize && !cache_hit {
    FitCache::from_fit(
      fold_ids,
      [[theta, deriv], psi],
      self.seed,
      self.n_folds,
      1,
      n,
      data_hash,
      hparams_hash,
      cluster_hash,
      "pq",
    )
  } else {
    self.fit_cache
  }
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
    psi_a,
    boot_t_stat: [],
    boot_method: "",
    n_rep_boot: 0,
    boot_seed: 0,
    memoize_enabled: self.memoize_enabled,
    fit_cache: next_cache,
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
    // v0.94.0+: same uniform-API Jacobian array as the IID path,
    // built from this path's own `deriv_r` (the cluster path runs
    // `solve_pq` under cluster folds, so the two paths' Jacobians
    // are NOT interchangeable and each must persist its own).
    //
    // Note that `se` here is the UNIT-LEVEL cluster-robust variance
    // `sqrt(var_unit / (deriv_r^2 * n_units))`, not the IID
    // `sqrt(mean(psi^2) / (deriv^2 * n))`. The
    // `sandwich_se(HC0) == se()` invariant is therefore an IID-path
    // property only -- on a clustered fit the caller should compare
    // against `cluster_sandwich_se(self.data.cluster_vars)` (or the
    // unit-level variance directly), which is what `se` already is.
    let psi_a : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      psi_a[i] = deriv_r
    }
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
      psi_a,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      // v0.84.0+: memoize state carried through the cluster
      // path; the cluster folds are deterministic for fixed
      // (seed, n_folds, cluster_vars), so the same hash
      // pipeline as the IID path applies (the cluster_hash
      // captures the `cluster_vars` fingerprint).
      memoize_enabled: self.memoize_enabled,
      fit_cache: self.fit_cache,
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
/// v0.84.0+: turn on memoization. When enabled, the next
/// `fit()` caches the `solve_pq(...)` outputs (`theta`,
/// `psi`, `deriv`) plus row-to-fold mapping; subsequent
/// `fit()` calls with the same data fingerprint, fold split,
/// learner configuration, propensity clip, and cluster
/// partition reuse the cached outputs. The `(coef, se)`
/// aggregation from cached values still runs on every `fit()`.
pub fn DoubleMLPQ::enable_memoize(self : DoubleMLPQ) -> DoubleMLPQ {
  { ..self, memoize_enabled: true, }
}

///|
/// v0.84.0+: turn off memoization. After this, `fit()` will not
/// read or write the cache; the existing `fit_cache` is preserved
/// on the returned struct (call `clear_cache()` to drop it).
pub fn DoubleMLPQ::disable_memoize(self : DoubleMLPQ) -> DoubleMLPQ {
  { ..self, memoize_enabled: false, }
}

///|
/// v0.84.0+: drop the cached `solve_pq(...)` outputs. After
/// this, the next `fit()` will run the full `solve_pq` (and
/// repopulate the cache if memoize is still enabled).
pub fn DoubleMLPQ::clear_cache(self : DoubleMLPQ) -> DoubleMLPQ {
  { ..self, fit_cache: FitCache::empty(), }
}

///|
/// v0.84.0+: `true` iff `fit_cache` holds at least one cached
/// `solve_pq(...)` result (i.e. a previous `fit()` with
/// `memoize_enabled = true` has populated the cache). Note that
/// `has_cache()` does NOT verify the cache key matches the
/// current data + learner configuration -- check `memoize_enabled`
/// if you also need to know whether the next `fit()` will hit.
pub fn DoubleMLPQ::has_cache(self : DoubleMLPQ) -> Bool {
  !self.fit_cache.is_empty()
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
/// v0.74.0+: cluster-robust analogue of
/// `DoubleMLPQ::sensitivity_analysis`. Mirrors the LPQ
/// pattern: the centered-IF formulation
/// (`sigma2 = Var(y)`, `nu2 = mean(psi^2)`) is replicated
/// inside `irm_style_sensitivity_cluster` by passing
/// `residuals = y - mean(y)` and `psi_a = self.psi`. Only
/// the variance / bias computation is cluster-aware.
///
/// `cluster_ids` defaults to `DoubleMLData::cluster_vars`
/// (empty array for the non-clustered constructor path, in
/// which case the caller's explicit `cluster_ids` is required
/// to produce a meaningful cluster-robust estimate).
pub fn DoubleMLPQ::sensitivity_analysis_cluster(
  self : DoubleMLPQ,
  cluster_ids? : Array[Int] = self.data.cluster_vars,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let y = self.data.y
  let n = y.length()
  require(cluster_ids.length() == n)
  let mut y_sum = 0.0
  for i = 0; i < n; i = i + 1 {
    y_sum = y_sum + y[i]
  }
  let y_bar = y_sum / n.to_double()
  let residuals : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    residuals[i] = y[i] - y_bar
  }
  irm_style_sensitivity_cluster(
    self.coef,
    residuals,
    self.psi,
    cluster_ids,
    cf_y,
    cf_d,
  )
}

// ---------------------------------------------------------------------------
// v0.94.0: the sandwich API
// ---------------------------------------------------------------------------
//
// WHY PQ IS NOT ONE OF THE ORDINARY 12
// =====================================
//
// `var_est.mbt` defines the package's estimating function as
//     f(theta) = E[theta * psi_a + psi_b]
// a mean moment whose root is `-mean(psi_b) / mean(psi_a)` and whose
// Jacobian is `J = mean(psi_a)`. For the twelve estimators that
// follow that convention, the sandwich is a mechanical three-liner:
// evaluate the score with `psi_at(coef, self.psi_a, self.psi_b)` and
// set `M_inv = [[1 / mean(self.psi_a)]]`.
//
// PQ does not fit that template, and forcing it to is what kept it
// off the list:
//
//   1. PQ's estimating equation is a quantile FIRST-ORDER
//      CONDITION, `mean(psi(theta)) = 0`, found by bisection. It
//      has no `psi_b` to solve for, and no `psi_at` split to
//      reconstruct the score from. `self.psi` is ALREADY the score
//      evaluated at `coef`, and this method therefore uses it
//      directly. Calling `psi_at` here would evaluate a DIFFERENT
//      function whose root is not `coef`.
//
//   2. Its Jacobian is `d mean(psi(theta)) / d theta`, a genuinely
//      data-dependent scalar -- the IPW-weighted density of `y` at
//      `theta` among the treated, computed in `solve_pq` as the
//      central difference `(sum_p - sum_m) / (n * 2h)`. It is NOT a
//      constant, and it is NOT `mean` of any per-observation array.
//
// The payoff invariant, and the whole reason for persisting the
// Jacobian in v0.94.0:
//
//     sandwich_variance_hc0 = M_inv[0,0]^2 * sum_i psi[i]^2 / n^2
//                           = (1/deriv^2) * sum_i psi[i]^2 / n^2
//
// which is exactly what `fit` computes for `se`,
// `(gamma / (deriv^2 * n))` with `gamma = mean(psi^2)`. So:
//
//     sandwich_se(HC0) == se()
//
// to floating-point tolerance, and `se()` remains the reference.
//
// `self.psi_a` is the length-`n_obs` array whose every entry is the
// same scalar `deriv`, so `mean(self.psi_a) == deriv` exactly.
// `sandwich_variance` reads that array only to satisfy its length
// preconditions (the v0.91.0 accumulator carries no `psi_a` weight);
// the Jacobian enters solely through `M_inv`.

///|
/// The Jacobian inverse `M_inv = [[1 / deriv]]` (1x1), where
/// `deriv` is the data-dependent `d mean(psi(theta)) / d theta` at
/// `coef` (the IPW-weighted treated density of `y` at `theta`).
/// Only `M_inv[0,0]^2` enters the variance, so the sign of the
/// inverse is irrelevant.
///
/// The degenerate-input guard is `require(deriv.abs() >= 1e-12)`,
/// which ABORTS rather than clips. Two reasons:
///
///   - `fit` already uses the same `deriv` in
///     `(gamma / (deriv * deriv * n_d)).sqrt()`, where `deriv == 0`
///     makes the SE `+inf` -- a fitted model can still reach this
///     method with such a `deriv`, and a clip here would silently
///     return a number `se()` does not.
///   - Clipping to `1e-12` would break the `sandwich_se(HC0) == se()`
///   invariant for small-but-nonzero `deriv`, because `se()` uses
///   the unclipped value. Aborting keeps the two paths honest
///   rather than quietly returning a different number.
///
/// The `1e-12` floor (rather than `!= 0`) also catches the
/// sub-normal case where `1 / deriv` overflows to infinity and the
/// variance would come back `inf` while still passing a
/// `>= 0.0` check.
fn DoubleMLPQ::m_inv_1x1(self : DoubleMLPQ) -> Matrix {
  try {
    require(self.fitted)
    require(self.psi_a.length() == self.psi.length())
    require(self.psi.length() >= 1)
    let deriv = self.psi_a[0]
    require(deriv.abs() >= 1.0e-12)
    Matrix::from_array([1.0 / deriv], 1, 1)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.94.0+: heteroskedasticity-consistent (Huber-White) sandwich
/// standard error for the fitted PQ. Routes through the shared
/// `sandwich_variance` dispatch, so the HC0 / HC1 / HC2 / HC3
/// relationships are the package-wide ones (see the file header in
/// `sandwich.mbt` and the identities pinned in
/// `expand_v088_test.mbt`).
///
/// The two inputs are NOT the usual `(psi_at(...), 1/mean(psi_a))`
/// pair, and the deviation is deliberate -- see the section comment
/// above. `self.psi` is used AS the score (it is already evaluated
/// at `coef`; there is no `psi_b` to reconstruct it from, and
/// `psi_at` would evaluate a different function whose root is not
/// `coef`), and the Jacobian is the persisted data-dependent
/// `deriv` in `self.psi_a[0]`, NOT a hard-coded constant.
///
/// `n_obs` is `self.psi.length()`, the full sample: PQ has no
/// transformed or subset domain.
///
/// On a CLUSTERED fit (non-empty `data.cluster_vars`,
/// `DoubleMLPQ::fit_cluster`) `se()` is the unit-level
/// cluster-robust variance, not the IID one, so the
/// `sandwich_se(HC0) == se()` invariant does not hold there; use
/// `cluster_sandwich_se(self.data.cluster_vars)`, which is the
/// unit-level analogue of this method.
///
/// Preconditions: `self.fitted`, `|psi_a[0]| >= 1e-12`.
pub fn DoubleMLPQ::sandwich_se(
  self : DoubleMLPQ,
  kind : SandwichKind,
) -> Double {
  try {
    let m_inv = self.m_inv_1x1()
    let n = self.psi.length()
    let variance_val = sandwich_variance(
      kind,
      self.psi_a,
      self.psi,
      m_inv,
      n,
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
/// v0.94.0+: cluster-robust sandwich standard error for the fitted
/// PQ (Arellano 1987, Cameron-Gelbach-Miller 2011). Routes through
/// `cluster_sandwich_variance` with the SAME `self.psi` and `M_inv`
/// inputs as the IID `sandwich_se` path -- see the section comment
/// above for why those are not the ordinary `(psi_at(...),
/// 1/mean(psi_a))` pair.
///
/// `DoubleMLData` carries `cluster_vars`, so a clustered fit can pass
/// `self.data.cluster_vars` directly; on the IID constructor path
/// (`cluster_vars = []`) the caller must supply the grouping
/// variable explicitly -- any clustering the application has: region,
/// site, panel unit. With all-singleton clusters the meat
/// degenerates to `sum_i psi[i]^2` and the formula collapses to
/// `sandwich_se(HC0)`, hence to `se()` on an IID fit.
///
/// Preconditions: `self.fitted`, `|psi_a[0]| >= 1e-12`,
/// `cluster_ids.length() == psi.length()`.
pub fn DoubleMLPQ::cluster_sandwich_se(
  self : DoubleMLPQ,
  cluster_ids : Array[Int],
) -> Double {
  try {
    let m_inv = self.m_inv_1x1()
    let n = self.psi.length()
    require(cluster_ids.length() == n)
    let variance_val = cluster_sandwich_variance(
      self.psi_a,
      self.psi,
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
/// v0.94.0+: returns `coef` UNCHANGED -- a documented no-op, not a
/// bias correction. Identical in reasoning to the thirteen
/// `bias_corrected_coef` methods added in v0.86.0 - v0.93.0; see
/// `DoubleMLIRM::bias_corrected_coef` and `bias_corrected_theta`
/// in `sandwich.mbt` for the full argument.
///
/// `coef` is the bisection root of the PQ quantile moment
/// `mean(psi(theta)) = 0`. That estimating function is orthogonal
/// at its root by construction -- and that orthogonality IS what
/// makes the estimator consistent -- so no correction built from
/// the fitted scores is a bias estimate for this class of
/// estimator. This accessor therefore reports the uncorrected point
/// estimate rather than a number that merely looks like a
/// correction.
///
/// The pre-v0.91.0 form `coef + mean(psi_b - coef * psi_a)` is
/// algebraically `3 * coef` for a constant-`psi_a` estimator and is
/// not a bias estimate for ANY of them; the v0.91.0 argument applies
/// here unchanged.
///
/// Preconditions: `self.fitted`.
pub fn DoubleMLPQ::bias_corrected_coef(self : DoubleMLPQ) -> Double {
  try {
    require(self.fitted)
    self.coef
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
  // v0.95.0+: the two per-quantile Jacobians that built
  // `psi_flat`, one per treatment arm -- `derivs1[j]` is
  // `d mean(psi_1(theta)) / d theta` at `coefs[j]` for the
  // treated arm and `derivs0[j]` the same for the control arm,
  // i.e. each the negative IPW-weighted density of `y` at that
  // arm's quantile among that arm's rows (as in `DoubleMLPQ`).
  // Length `n_quantiles` each.
  //
  // They are persisted because they used to die: `fit` read them
  // out of `solve_pq`, divided them into `psi_flat`, and dropped
  // them, so a caller had no way to see how far the quantile
  // roots sat from a flat density, nor to notice that the IF
  // scaling `1 / deriv` was already applied.
  //
  // There are TWO per quantile, not one, because a quantile
  // treatment effect is a CONTRAST of two independent
  // scalar Z-estimators (`theta_1 - theta_0`), not one. Any
  // single "the QTE Jacobian" would have to be either a
  // difference of derivatives taken at two different parameter
  // values (the Jacobian of nothing) or a fabricated constant.
  // See the section comment above `sandwich_se_at` for why the
  // variance must NOT re-apply them either.
  derivs1 : Array[Double]
  derivs0 : Array[Double]
  // v0.64.0+: multiplier bootstrap state. `boot_t_stat` is
  // a flat `[n_rep_boot * n_quantiles]` array of t-statistics.
  // Populated by `bootstrap(...)`; empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
  // v0.84.0+: memoization state. `memoize_enabled` is the
  // user-facing opt-in (set via `DoubleMLQTE::enable_memoize()`);
  // when true, `fit()` caches per-quantile `(theta1, psi1, deriv1,
  // theta0, psi0, deriv0)` plus row-to-fold mapping in `fit_cache`
  // and reuses them on the next `fit()` call (skipping the
  // `2 * n_quantiles` `solve_pq` calls -- propensity cross-fit +
  // bisection + 3x outcome cross-fits per quantile-treatment).
  // The `(coefs, ses, psi_flat)` aggregation from cached values
  // still runs on every `fit()` call.
  memoize_enabled : Bool
  fit_cache : FitCache
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
    // v0.95.0+: sentinel zeros; `fit` (both the IID path and
    // `fit_cluster`) replaces them with the per-arm Jacobians.
    derivs1: Array::make(quantiles.length(), 0.0),
    derivs0: Array::make(quantiles.length(), 0.0),
    boot_t_stat: [],
    boot_method: "",
    n_rep_boot: 0,
    boot_seed: 0,
    // v0.84.0+: memoize starts disabled; opt in via
    // `.enable_memoize()` for caching.
    memoize_enabled: false,
    fit_cache: FitCache::empty(),
  }
}

///|
pub fn DoubleMLQTE::fit(
  self : DoubleMLQTE,
  ml_l? : LearnerDispatch = self.ml_l,
  ml_m? : LearnerDispatch = self.ml_m,
) -> DoubleMLQTE {
  // v0.67.0+: cluster-data dispatch -- when `cluster_vars` is
  // non-empty, route through `fit_cluster` (cluster-aware
  // folds, unit-level cluster-robust SE).
  if self.data.is_cluster_data() {
    return self.fit_cluster(ml_l~, ml_m~)
  }
  let n_obs = self.data.n_obs()
  let n_q = self.quantiles.length()
  let c = Array::make(n_q, 0.0)
  let s = Array::make(n_q, 0.0)
  let psi_flat : Array[Double] = Array::make(n_q * n_obs, 0.0)
  // v0.95.0+: the per-quantile per-arm Jacobians, persisted so the
  // sandwich API can guard on them and callers can read them back.
  let d1s : Array[Double] = Array::make(n_q, 0.0)
  let d0s : Array[Double] = Array::make(n_q, 0.0)
  // v0.84.0+: memoize check (mirrors the per-estimator
  // pattern). QTE is a single-fit estimator (no `n_rep`),
  // so memoize is honored unconditionally when enabled --
  // the cache stores per-quantile per-treatment
  // `(theta1, deriv1, theta0, deriv0)` plus the flat
  // `(psi1, psi0)` matrices. On a cache hit we skip all
  // `2 * n_quantiles` `solve_pq` calls and just recompute
  // the `(coefs, ses, psi_flat)` aggregation from cached
  // values.
  let memoize = self.memoize_enabled
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
    hash_hyperparams("qte", ml_l, ml_m, self.propensity_clip)
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
      1,
      n_obs,
      data_hash,
      hparams_hash,
      cluster_hash,
      "qte",
    )
  // v0.84.0+: per-quantile scalars `(theta1, deriv1,
  // theta0, deriv0)` cached as a length-`4 * n_q` flat
  // array. Per-quantile per-treatment IF vectors cached
  // as flat `[n_q * n_obs]` arrays.
  let thetas_derivs : Array[Double] = if cache_hit {
    self.fit_cache.predictions[0]
  } else {
    Array::make(n_q * 4, 0.0)
  }
  let psi1_cache : Array[Double] = if cache_hit {
    self.fit_cache.predictions[1]
  } else {
    Array::make(n_q * n_obs, 0.0)
  }
  let psi0_cache : Array[Double] = if cache_hit {
    self.fit_cache.predictions[2]
  } else {
    Array::make(n_q * n_obs, 0.0)
  }
  // Row-to-fold mapping: drawn once per `n_folds` for the
  // IID path (used for the cache-key contract that
  // `fold_ids.length() == n_obs`).
  let fold_ids : Array[Int] = if cache_hit {
    self.fit_cache.fold_ids
  } else {
    let folds = kfold(n_obs, self.n_folds, self.seed)
    let local_fold_ids : Array[Int] = Array::make(n_obs, 0)
    for f = 0; f < folds.length(); f = f + 1 {
      for i in folds[f].test_indices() {
        local_fold_ids[i] = f
      }
    }
    local_fold_ids
  }
  let n = self.data.n_obs().to_double()
  for j = 0; j < n_q; j = j + 1 {
    let offset = j * n_obs
    // Compute or pull `theta1`, `psi1`, `deriv1` for quantile `j`.
    // On cache-hit we copy from the flat cache; otherwise we run
    // `solve_pq` once and write back into the cache.
    let (theta1, psi1, deriv1) = if cache_hit {
      let arr : Array[Double] = Array::make(n_obs, 0.0)
      for i = 0; i < n_obs; i = i + 1 {
        arr[i] = psi1_cache[offset + i]
      }
      (thetas_derivs[j * 4 + 0], arr, thetas_derivs[j * 4 + 1])
    } else {
      let (t1, p1, d1) = solve_pq(
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
      thetas_derivs[j * 4 + 0] = t1
      thetas_derivs[j * 4 + 1] = d1
      for i = 0; i < n_obs; i = i + 1 {
        psi1_cache[offset + i] = p1[i]
      }
      (t1, p1, d1)
    }
    let (theta0, psi0, deriv0) = if cache_hit {
      let arr : Array[Double] = Array::make(n_obs, 0.0)
      for i = 0; i < n_obs; i = i + 1 {
        arr[i] = psi0_cache[offset + i]
      }
      (thetas_derivs[j * 4 + 2], arr, thetas_derivs[j * 4 + 3])
    } else {
      let (t0, p0, d0) = solve_pq(
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
      thetas_derivs[j * 4 + 2] = t0
      thetas_derivs[j * 4 + 3] = d0
      for i = 0; i < n_obs; i = i + 1 {
        psi0_cache[offset + i] = p0[i]
      }
      (t0, p0, d0)
    }
    // v0.95.0+: persist this quantile's two arm Jacobians. Placed
    // AFTER both destructurings and OUTSIDE the `cache_hit` branch,
    // so it is correct on both paths by the same single-binding
    // argument as PQ's `psi_a`: `deriv1` / `deriv0` are restored
    // from `thetas_derivs[j * 4 + 1] / [j * 4 + 3]` on a hit and
    // returned by `solve_pq` on a miss, and they are bound to the
    // SAME names on both.
    // `expand_v095_test.mbt::qte_sandwich_after_memoize_cache_hit`
    // pins that.
    d1s[j] = deriv1
    d0s[j] = deriv0
    c[j] = theta1 - theta0
    // v0.84.0+: vectorise the per-observation `u` IF
    // computation as `psi1/deriv1 - psi0/deriv0`. The
    // original scalar loop is rewritten as
    // `vector_scale(psi1, 1/deriv1) - vector_scale(psi0,
    // 1/deriv0)`; both are O(n) flat operations and
    // byte-identical to the original because `deriv1` /
    // `deriv0` are scalar (not array) factors.
    let psi1_scaled = vector_scale(psi1, 1.0 / deriv1)
    let psi0_scaled = vector_scale(psi0, 1.0 / deriv0)
    let u = vector_subtract(psi1_scaled, psi0_scaled)
    for i = 0; i < n_obs; i = i + 1 {
      psi_flat[j * n_obs + i] = u[i]
    }
    // `gamma = sum(u^2) / n`. v0.84.0+: same vectorised
    // pattern as PQ: `vector_multiply(u, u)` element-wise
    // square + `mean()` for `sum / n`.
    let u_sq = vector_multiply(u, u)
    let gamma = mean(u_sq)
    s[j] = (gamma / n).sqrt()
  }
  // v0.84.0+: when memoize is on and the cache missed,
  // write the freshly-computed per-quantile scalars + IF
  // vectors + row-to-fold mapping to the cache.
  let next_cache = if memoize && !cache_hit {
    FitCache::from_fit(
      fold_ids,
      [thetas_derivs, psi1_cache, psi0_cache],
      self.seed,
      self.n_folds,
      1,
      n_obs,
      data_hash,
      hparams_hash,
      cluster_hash,
      "qte",
    )
  } else {
    self.fit_cache
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
    // v0.95.0+: the per-quantile per-arm Jacobians this fit used.
    derivs1: d1s,
    derivs0: d0s,
    boot_t_stat: [],
    boot_method: "",
    n_rep_boot: 0,
    boot_seed: 0,
    memoize_enabled: self.memoize_enabled,
    fit_cache: next_cache,
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
    // v0.95.0+: the cluster path runs `solve_pq` under CLUSTER
    // folds, so its Jacobians are NOT the IID path's and this
    // struct literal needs its own wiring from its own `deriv1` /
    // `deriv0` (the same separate-wiring requirement v0.94.0 hit
    // for PQ's `psi_a`). Leaving these at the `new()` zeros would
    // still compile, and the sandwich methods would then abort on
    // the `|deriv| >= 1e-12` guard.
    let d1s : Array[Double] = Array::make(self.quantiles.length(), 0.0)
    let d0s : Array[Double] = Array::make(self.quantiles.length(), 0.0)
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
      d1s[j] = deriv1
      d0s[j] = deriv0
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
      // v0.95.0+: this path's own per-quantile per-arm Jacobians.
      derivs1: d1s,
      derivs0: d0s,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      // v0.84.0+: memoize state carried through the cluster
      // path; the cluster folds are deterministic for fixed
      // (seed, n_folds, cluster_vars), so the same hash
      // pipeline as the IID path applies (the cluster_hash
      // captures the `cluster_vars` fingerprint).
      memoize_enabled: self.memoize_enabled,
      fit_cache: self.fit_cache,
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
/// v0.84.0+: turn on memoization. When enabled, the next
/// `fit()` caches per-quantile per-treatment
/// `(theta1, psi1, deriv1, theta0, psi0, deriv0)` plus
/// row-to-fold mapping; subsequent `fit()` calls with the
/// same data fingerprint, fold split, learner configuration,
/// propensity clip, and cluster partition reuse the cached
/// outputs (skipping the entire `2 * n_quantiles` `solve_pq`
/// loop). The `(coefs, ses, psi_flat)` aggregation from
/// cached values still runs on every `fit()` call.
pub fn DoubleMLQTE::enable_memoize(self : DoubleMLQTE) -> DoubleMLQTE {
  { ..self, memoize_enabled: true, }
}

///|
/// v0.84.0+: turn off memoization. After this, `fit()` will not
/// read or write the cache; the existing `fit_cache` is preserved
/// on the returned struct (call `clear_cache()` to drop it).
pub fn DoubleMLQTE::disable_memoize(self : DoubleMLQTE) -> DoubleMLQTE {
  { ..self, memoize_enabled: false, }
}

///|
/// v0.84.0+: drop the cached per-quantile outputs. After this,
/// the next `fit()` will run the full `2 * n_quantiles`
/// `solve_pq` loop (and repopulate the cache if memoize is
/// still enabled).
pub fn DoubleMLQTE::clear_cache(self : DoubleMLQTE) -> DoubleMLQTE {
  { ..self, fit_cache: FitCache::empty(), }
}

///|
/// v0.84.0+: `true` iff `fit_cache` holds at least one cached
/// per-quantile-solver result (i.e. a previous `fit()` with
/// `memoize_enabled = true` has populated the cache). Note
/// that `has_cache()` does NOT verify the cache key matches the
/// current data + learner configuration -- check `memoize_enabled`
/// if you also need to know whether the next `fit()` will hit.
pub fn DoubleMLQTE::has_cache(self : DoubleMLQTE) -> Bool {
  !self.fit_cache.is_empty()
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

// ---------------------------------------------------------------------------
// Sensitivity (v0.70.0+)
// ---------------------------------------------------------------------------

///|
/// v0.70.0+: per-quantile Cinelli & Hazlett (2020)
/// omitted-variable bias analysis for `DoubleMLQTE`. The
/// per-quantile influence function
/// `psi_j[i] = psi_flat[j * n_obs + i]` is already centered
/// (mean 0 at the bisection root; see `solve_pq`), so each
/// quantile routes through the shared
/// `single_psi_sensitivity` helper (the v0.67.0+ path used by
/// `DoubleMLPQ`): `nu2 = mean(psi_j^2)`,
/// `sigma2 = Var(y)`, with the centered-IF convention.
///
/// Returns an `Array[SensitivityResult]` of length
/// `quantiles.length()`. Calling on an un-fit model aborts via
/// `PreconditionError` (`coefs.length() > 0` proxy, matching
/// the convention used by `DoubleMLQTE::bootstrap`).
pub fn DoubleMLQTE::sensitivity_analysis(
  self : DoubleMLQTE,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> Array[SensitivityResult] raise {
  // QTE does not persist a `fitted : Bool` field (its
  // bootstrap uses the same `coefs.length() > 0` proxy); the
  // helper itself raises `n > 0` on an empty psi, which
  // covers the genuinely-empty case.
  require(self.coefs.length() > 0)
  let n_quantiles = self.quantiles.length()
  let n_obs = self.data.n_obs()
  let y = self.data.y
  let out : Array[SensitivityResult] = Array::make(n_quantiles, {
    rv: 0.0,
    sigma2: 0.0,
    nu2: 0.0,
    cf_y: 0.0,
    cf_d: 0.0,
    max_bias: 0.0,
  })
  // Slice psi_flat row-major: `psi_flat[j * n_obs + i]` is the
  // IF for the `theta_d1 - theta_d0` combination at
  // observation `i` for quantile index `j`.
  let psi_flat = self.psi_flat
  for j = 0; j < n_quantiles; j = j + 1 {
    let psi_j : Array[Double] = Array::make(n_obs, 0.0)
    for i = 0; i < n_obs; i = i + 1 {
      psi_j[i] = psi_flat[j * n_obs + i]
    }
    out[j] = single_psi_sensitivity(self.coefs[j], psi_j, y, cf_y, cf_d)
  }
  out
}

///|
/// v0.74.0+: cluster-robust analogue of
/// `DoubleMLQTE::sensitivity_analysis`. The centered-IF
/// formulation per quantile (`sigma2 = Var(y)`,
/// `nu2 = mean(psi_j^2)`) is replicated inside
/// `irm_style_sensitivity_cluster_multi` by passing
/// `residuals = y - mean(y)` (the same for every quantile)
/// and `psi_a = psi_j` for each quantile. Only the variance /
/// bias computation is cluster-aware. The cluster-summed
/// `sigma2_cluster` / `nu2_cluster` are recomputed in each
/// per-quantile call (they only depend on the cluster
/// partition and the per-quantile `psi_a` row; the cluster
/// partition is shared across quantiles, so the cluster
/// sums only depend on the per-quantile `psi_a` row, but
/// the multi helper recomputes the cluster sums per theta
/// for clarity).
///
/// `cluster_ids` defaults to `DoubleMLData::cluster_vars`.
/// Returns an `Array[SensitivityResult]` of length
/// `quantiles.length()`. Calling on an un-fit model aborts
/// via `PreconditionError`.
pub fn DoubleMLQTE::sensitivity_analysis_cluster(
  self : DoubleMLQTE,
  cluster_ids? : Array[Int] = self.data.cluster_vars,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> Array[SensitivityResult] raise {
  require(self.coefs.length() > 0)
  let n_quantiles = self.quantiles.length()
  let n_obs = self.data.n_obs()
  let y = self.data.y
  require(cluster_ids.length() == n_obs)
  // Centered-y "residual" shared across all quantiles
  // (Var(y) doesn't depend on j).
  let mut y_sum = 0.0
  for i = 0; i < n_obs; i = i + 1 {
    y_sum = y_sum + y[i]
  }
  let y_bar = y_sum / n_obs.to_double()
  let residuals : Array[Double] = Array::make(n_obs, 0.0)
  for i = 0; i < n_obs; i = i + 1 {
    residuals[i] = y[i] - y_bar
  }
  // Build per-quantile psi_a matrix: row j is the centered
  // IF for the `theta_d1 - theta_d0` combination at
  // observation `i` for quantile index `j`.
  let residuals_arr : Array[Array[Double]] = Array::make(n_quantiles, [])
  let psi_a_arr : Array[Array[Double]] = Array::make(n_quantiles, [])
  let psi_flat = self.psi_flat
  for j = 0; j < n_quantiles; j = j + 1 {
    let psi_a_j : Array[Double] = Array::make(n_obs, 0.0)
    for i = 0; i < n_obs; i = i + 1 {
      psi_a_j[i] = psi_flat[j * n_obs + i]
    }
    residuals_arr[j] = residuals.copy()
    psi_a_arr[j] = psi_a_j
  }
  irm_style_sensitivity_cluster_multi(
    self.coefs,
    residuals_arr,
    psi_a_arr,
    cluster_ids,
    cf_y,
    cf_d,
  )
}

// ---------------------------------------------------------------------------
// v0.95.0: the per-quantile sandwich API
// ---------------------------------------------------------------------------
//
// WHY QTE IS NEITHER ONE OF THE ORDINARY 12 NOR PQ
// ===============================================
//
// `var_est.mbt` defines the package's estimating function as
//     f(theta) = E[theta * psi_a + psi_b]
// a mean moment whose root is `-mean(psi_b) / mean(psi_a)` and whose
// Jacobian is `J = mean(psi_a)`. For the twelve estimators that
// follow that convention the sandwich is a mechanical three-liner:
// `psi_at(coef, self.psi_a, self.psi_b)` with
// `M_inv = [[1 / mean(self.psi_a)]]`.
//
// `DoubleMLPQ` (v0.94.0) is a single scalar quantile Z-estimator:
// `theta` solves `mean(psi(theta)) = 0`, its stored score is the RAW
// quantile score, and its Jacobian is the data-dependent scalar
// `deriv = d mean(psi(theta)) / d theta`. PQ therefore needs
// `M_inv = [[1 / deriv]]`, and its SE carries a factor `1 / |deriv|`.
//
// QTE is a third shape: per quantile `j` it is a CONTRAST of two
// independent scalar Z-estimators, `theta_j = theta_1 - theta_0`,
// each of the PQ form. Its stored per-observation IF,
// `psi_flat[j * n_obs + i]`, is
//
//     u_i = psi_1[i] / deriv_1 - psi_0[i] / deriv_0
//
// which ALREADY carries both Jacobians: `fit` divides them in and
// then computes
//
//     ses[j] = (gamma / n).sqrt(),   gamma = mean(u^2)
//
// So QTE's Jacobian has already done its work inside the stored score.
//
// THE STRUCTURAL FACT: `M_inv` IS 1 HERE
// ---------------------------------------
// Write the contrast as a one-parameter Z-estimator by substituting
// `theta_1 = theta_0 + theta_j`. Its estimating equation is
//
//     mean( psi_1(theta_0 + theta_j) / deriv_1
//            - psi_0(theta_0) / deriv_0 ) = 0
//
// whose `theta_j`-derivative is
//
//     (1 / deriv_1) * d mean(psi_1) / d theta_j - 0
//   = (1 / deriv_1) * deriv_1
//   = 1.
//
// The contrast's Jacobian is therefore IDENTICALLY 1 -- per quantile,
// for every data set. That is an identity of the studentised score,
// not a constant this implementation picked. Equivalently, every
// per-observation Jacobian row of `u` is exactly 1, which is why
// `sandwich_se_at` hands `sandwich_variance` an all-ones `psi_a` and
// gets `M_inv = [[1 / mean(psi_a)]] = [[1.0]]` under the SAME
// convention as the other fifteen estimators.
//
// This is the one place QTE REJECTS the PQ template, and it is a trap
// in the opposite direction from PQ's: multiplying the stored
// `psi_flat` row by a further `1 / derivs1[j]` (or `derivs0[j]`, or
// `1 / (derivs1[j] - derivs0[j])`) DOUBLE-COUNTS the Jacobian and
// INFLATES the SE by `1 / |deriv|` (PQ's constant reading instead
// SHRANK its SE, because PQ's stored score is raw). The persisted
// per-arm Jacobians therefore enter the variance path as a degeneracy
// GUARD and nothing else; see `m_inv_1x1_at`. They remain persisted
// because they are the record of how the stored IF was built, and
// because until v0.95.0 they were dropped on the floor after doing
// that. `expand_v095_test.mbt::qte_jacobian_is_not_a_constant` pins
// both the guard's inputs and the measured size of the
// double-counting error.
//
// THE PAYOFF INVARIANT
// --------------------
//
//     sandwich_variance_hc0 = M_inv[0,0]^2 * sum_i u_i^2 / n / n
//                           = sum_i u_i^2 / n / n      (M_inv == 1)
//
// while `fit` computes `ses[j] = (gamma / n).sqrt()` with
// `gamma = mean(u^2)`. `mean` (`matrix.mbt`) and
// `sandwich_variance_hc0`'s accumulator are the SAME Kahan
// compensated loop over the same `u_i * u_i` products in the same
// index order, and both then divide by `n` twice. So the two sides
// are BIT-IDENTICAL, not merely equal to a tolerance:
//
//     sandwich_se_at(j, HC0) == ses[j]
//
// The score is used AS STORED and `psi_at` is deliberately NOT called:
// `psi_flat`'s row is already the score evaluated at `coefs[j]`,
// there is no `psi_b` to reconstruct it from, and `psi_at` would
// evaluate the different function `coef * psi_a + psi_b`, whose root
// is not `coefs[j]`.
//
// SCOPE
// -----
// These methods are per-quantile and stay that way. `quantiles` is a
// user-supplied array of separate scalar estimands, so no joint
// cross-quantile covariance is implied, computed, or needed; a joint
// `Cov(theta_j, theta_j')` is a different, larger feature and is
// deliberately out of scope.

///|
/// The Jacobian inverse `M_inv` (1x1) for quantile `quantile_index`.
///
/// For QTE this is `[[1.0]]`, NOT `[[1 / deriv]]` -- see the section
/// comment above: the contrast's Jacobian is identically 1 because
/// `psi_flat`'s row already carries the `1 / deriv_1` and
/// `1 / deriv_0` scaling, so `M_inv[0,0]^2` is the only entry the
/// variance ever inspects.
///
/// The two persisted per-arm Jacobians ARE read here, as the
/// degenerate-input guard, and the guard ABORTS rather than clips:
///
///   - `fit` scales each arm's score by `1 / deriv` with no guard of
///     its own, so a `deriv == 0` (or sub-normal) has already put
///     `inf` / `nan` into `psi_flat`'s row and left `ses[j]` at `inf`
///     or `nan`. Returning a finite number here would report a
///     sandwich over a score that is not finite.
///   - The `1e-12` floor (rather than `!= 0`) also catches the
///     sub-normal case where `1 / deriv` overflows to `inf` while the
///     resulting variance would still pass a `>= 0.0` check.
///
/// Note what this does NOT do: it does not put `1 / deriv` into the
/// variance. Clipping would additionally break the
/// `sandwich_se_at(j, HC0) == ses[j]` invariant for small-but-nonzero
/// Jacobians, since `ses[j]` uses the unclipped value.
fn DoubleMLQTE::m_inv_1x1_at(
  self : DoubleMLQTE,
  quantile_index : Int,
) -> Matrix {
  try {
    let n_q = self.quantiles.length()
    require(n_q >= 1)
    require(quantile_index >= 0)
    require(quantile_index < n_q)
    require(self.coefs.length() == n_q)
    require(self.ses.length() == n_q)
    require(self.derivs1.length() == n_q)
    require(self.derivs0.length() == n_q)
    let n_obs = self.data.n_obs()
    require(n_obs >= 1)
    require(self.psi_flat.length() == n_q * n_obs)
    require(self.derivs1[quantile_index].abs() >= 1.0e-12)
    require(self.derivs0[quantile_index].abs() >= 1.0e-12)
    Matrix::from_array([1.0], 1, 1)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Quantile `quantile_index`'s per-observation IF, extracted as the
/// slice `psi_flat[j * n_obs .. (j + 1) * n_obs]` of a fresh array.
fn DoubleMLQTE::psi_row(
  self : DoubleMLQTE,
  quantile_index : Int,
) -> Array[Double] {
  try {
    let n_q = self.quantiles.length()
    require(n_q >= 1)
    require(quantile_index >= 0)
    require(quantile_index < n_q)
    let n_obs = self.data.n_obs()
    require(n_obs >= 1)
    require(self.psi_flat.length() == n_q * n_obs)
    let row : Array[Double] = Array::make(n_obs, 0.0)
    let offset = quantile_index * n_obs
    for i = 0; i < n_obs; i = i + 1 {
      row[i] = self.psi_flat[offset + i]
    }
    row
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.95.0+: heteroskedasticity-consistent (Huber-White) sandwich
/// standard error for quantile `quantile_index` of a fitted QTE.
/// Routes through the shared `sandwich_variance` dispatch, so the
/// HC0 / HC1 / HC2 / HC3 relationships are the package-wide ones
/// (see the file header in `sandwich.mbt` and the identities pinned
/// in `expand_v088_test.mbt`).
///
/// The three inputs are NOT the usual `(psi_at(...), 1/mean(psi_a))`
/// pair, and both deviations are deliberate -- see the section
/// comment above:
///
///   - the score is `psi_flat`'s own row for this quantile, used AS
///     STORED (it is already evaluated at `coefs[j]`; there is no
///     `psi_b` to reconstruct it from, and `psi_at` would evaluate a
///     different function whose root is not `coefs[j]`);
///   - the Jacobian is `M_inv = [[1.0]]`, NOT `1 / derivs1[j]` or
///     `1 / derivs0[j]`. The per-arm Jacobians are already inside the
///     stored score; the contrast's Jacobian in the studentised form
///     is identically 1.
///
/// `psi_a` is therefore the all-ones array, which is the honest
/// per-observation Jacobian row of `u` (and satisfies
/// `sandwich_variance`'s length preconditions); the v0.91.0
/// accumulator carries no `psi_a` weight, so the Jacobian reaches the
/// variance only through `M_inv`.
///
/// `n_obs` is the full sample, the same `n_obs` `fit` divides by when
/// it computes `ses[j]`, and `n_params` is 1: one scalar estimand per
/// quantile, NOT `quantiles.length()`.
///
/// On a CLUSTERED fit (non-empty `data.cluster_vars`,
/// `DoubleMLQTE::fit_cluster`) `ses[j]` is the unit-level
/// cluster-robust variance `sqrt(var_unit / n_units)`, not the IID one,
/// so the `sandwich_se_at(j, HC0) == ses[j]` invariant does not hold
/// there; use `cluster_sandwich_se_at(j, self.data.cluster_vars)`, which
/// is the Arellano unit-level analogue (equal to `n_obs`-denominated
/// `cluster_sandwich_variance`, so the two agree only up to the
/// `n_units` vs `n_obs` denominator and the jackknife correction).
///
/// Preconditions: `0 <= quantile_index < quantiles.length()`,
/// `|derivs1[j]| >= 1e-12`, `|derivs0[j]| >= 1e-12`.
pub fn DoubleMLQTE::sandwich_se_at(
  self : DoubleMLQTE,
  quantile_index : Int,
  kind : SandwichKind,
) -> Double {
  try {
    let m_inv = self.m_inv_1x1_at(quantile_index)
    let n_obs = self.data.n_obs()
    let psi_j = self.psi_row(quantile_index)
    let psi_a : Array[Double] = Array::make(n_obs, 1.0)
    let variance_val = sandwich_variance(kind, psi_a, psi_j, m_inv, n_obs, 1)
    require(variance_val >= 0.0)
    variance_val.sqrt()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.95.0+: cluster-robust sandwich standard error for quantile
/// `quantile_index` of a fitted QTE (Arellano 1987, Cameron-Gelbach-
/// Miller 2011). Routes through `cluster_sandwich_variance` with the
/// SAME `psi_flat` row and `M_inv` as the IID `sandwich_se_at` path --
/// see the section comment above for why those are not the ordinary
/// `(psi_at(...), 1/mean(psi_a))` pair.
///
/// `DoubleMLData` carries `cluster_vars`, so a clustered fit can pass
/// `self.data.cluster_vars` directly; on the IID constructor path
/// (`cluster_vars = []`) the caller must supply the grouping variable
/// explicitly -- any clustering the application has: region, site,
/// panel unit. With all-singleton clusters the meat degenerates to
/// `sum_i u_i^2` and the formula collapses to `sandwich_se_at(j, HC0)`,
/// hence to `ses[j]` on an IID fit.
///
/// Preconditions: `0 <= quantile_index < quantiles.length()`,
/// `|derivs1[j]| >= 1e-12`, `|derivs0[j]| >= 1e-12`,
/// `cluster_ids.length() == n_obs`.
pub fn DoubleMLQTE::cluster_sandwich_se_at(
  self : DoubleMLQTE,
  quantile_index : Int,
  cluster_ids : Array[Int],
) -> Double {
  try {
    let m_inv = self.m_inv_1x1_at(quantile_index)
    let n_obs = self.data.n_obs()
    require(cluster_ids.length() == n_obs)
    let psi_j = self.psi_row(quantile_index)
    let psi_a : Array[Double] = Array::make(n_obs, 1.0)
    let variance_val = cluster_sandwich_variance(
      psi_a, psi_j, m_inv, cluster_ids, 1,
    )
    require(variance_val >= 0.0)
    variance_val.sqrt()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.95.0+: returns `coefs[quantile_index]` UNCHANGED -- a documented
/// no-op, not a bias correction. Identical in reasoning to the fifteen
/// `bias_corrected_coef` methods added in v0.86.0 - v0.94.0; see
/// `DoubleMLPQ::bias_corrected_coef` and `bias_corrected_theta` in
/// `sandwich.mbt` for the full argument.
///
/// `coefs[j]` is a difference of two bisection roots of the PQ
/// quantile moment `mean(psi_k(theta_k)) = 0`. Those estimating
/// functions are orthogonal at their roots by construction -- and that
/// orthogonality IS what makes the roots consistent -- so no
/// correction built from the fitted scores is a bias estimate for this
/// class of estimator. This accessor therefore reports the uncorrected
/// point estimate rather than a number that merely looks like a
/// correction.
///
/// The pre-v0.91.0 form `coef + mean(psi_b - coef * psi_a)` is
/// algebraically `3 * coef` for a constant-`psi_a` estimator and is
/// not a bias estimate for ANY of them; the v0.91.0 argument applies
/// here unchanged. There is a QTE-specific reason the naive
/// correction is not merely vacuous but actively wrong: the
/// contrast's score `u = psi_1 / deriv_1 - psi_0 / deriv_0` is the
/// difference of two arm scores whose individual means are each
/// near-zero but need not be zero at the reported root, so adding
/// `mean(u)` back to `coefs[j]` shifts a consistent estimate by
/// whatever those two residual means happen to be.
///
/// QTE persists no `fitted : Bool` (its `bootstrap` and
/// `sensitivity_analysis` use the same `coefs.length() > 0` proxy), so
/// this method uses it too.
///
/// Preconditions: `0 <= quantile_index < coefs.length()`.
pub fn DoubleMLQTE::bias_corrected_coef_at(
  self : DoubleMLQTE,
  quantile_index : Int,
) -> Double {
  try {
    require(self.coefs.length() > 0)
    require(quantile_index >= 0)
    require(quantile_index < self.coefs.length())
    self.coefs[quantile_index]
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
