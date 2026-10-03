///|
/// Double / debiased machine learning estimator for the *interactive
/// regression model* (IRM) of Chernozhukov et al. (2018) with the
/// Average Treatment Effect (ATE) score:
///
///     Y = g_0(D, X) + U,    E[U | D, X] = 0
///     D = m_0(X) + V,        E[V | X] = 0
///
/// and the *ATE* orthogonal signal
///
///     g0(X) = E[Y | D=0, X]
///     g1(X) = E[Y | D=1, X]
///     m(X)  = P(D=1 | X)             (the propensity score)
///     u0    = Y - g0(X)
///     u1    = Y - g1(X)
///
///     psi_b = (g1 - g0) + (D u1 / m - (1 - D) u0 / (1 - m))
///     psi_a = -1
///     psi(theta) = theta * psi_a + psi_b
///
/// with point estimate
///
///     theta_hat = -mean(psi_b) / mean(psi_a) = mean(psi_b)
///
/// and variance (same `_var_est` formula as `DoubleMLPLR`):
///
///     J       = mean(psi_a) = -1
///     gamma   = mean(psi(theta_hat)^2)
///     sigma2  = gamma / (J^2 * n)
///     se      = sqrt(sigma2)
///
/// The cross-fitting scheme trains `g0` only on observations with
/// `D = 0` and `g1` only on observations with `D = 1` (the test
/// folds still cover the full observation set), matching
/// `doubleml.utils._estimation._get_cond_smpls` in the upstream
/// package. The propensity score is clipped to
/// `[propensity_clip, 1 - propensity_clip]` before being used in the
/// score, guarding against near-zero or near-one values.
pub struct DoubleMLIRM {
  data : DoubleMLData
  n_folds : Int
  n_rep : Int
  seed : Int
  propensity_clip : Double
  // v0.59.0+: injected nuisance learners (replaces the
  // v0.57.0 hardcoded `LinearRegression`). Defaults to a
  // fresh `LinearRegression` so v0.57.0 callers see
  // byte-identical results. Both fields are package-private
  // to enforce that nuisance changes go through `fit(...)` /
  // `fit_cluster(...)` overrides.
  ml_g : LearnerDispatch
  ml_m : LearnerDispatch
  g0_hat : Array[Double]
  g1_hat : Array[Double]
  m_hat : Array[Double]
  // Raw (pre-clipping) propensity scores. v0.53.0-dev Task 4:
  // mirrors upstream feat "retain raw IRM propensity scores"
  // so callers can inspect the un-clipped predictions without
  // re-fitting.
  m_raw : Array[Double]
  coef : Double
  se : Double
  fitted : Bool
  // v0.61.0+: per-observation influence function components
  // for the multiplier bootstrap. For the ATE score
  // `psi_b = (g1-g0) + (D*u1/m - (1-D)*u0/(1-m))` and
  // `psi_a = -1` (constant), so `psi[i] = -1 + theta *
  // psi_b[i]`. Populated by `fit(...)` from the last rep's
  // nuisances; `psi_a` is `length n_obs` of `-1.0`.
  psi_a : Array[Double]
  psi_b : Array[Double]
  // v0.61.0+: multiplier bootstrap state. `boot_t_stat` is a
  // length-`n_rep_boot` array of t-statistics for `coef`.
  // Populated by `bootstrap(...)`; empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
  // v0.80.0+: memoization state. `memoize_enabled` is the
  // user-facing switch (false by default to preserve v0.79.0
  // behavior bit-for-bit). When true, `fit()` caches the last
  // repetition's nuisance predictions in `fit_cache` and
  // reuses them on the next call when the data fingerprint,
  // fold split, and learner configuration are unchanged.
  memoize_enabled : Bool
  fit_cache : FitCache
} derive(Debug)

///|
pub extend DoubleMLIRM with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLIRM::new(
  data : DoubleMLData,
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
  ml_g? : LearnerDispatch = LearnerDispatch::linear_regression(),
  ml_m? : LearnerDispatch = LearnerDispatch::linear_regression(),
) -> DoubleMLIRM {
  try {
    require(n_folds >= 2)
    require(n_folds <= data.n_obs())
    require(n_rep >= 1)
    require(propensity_clip > 0.0)
    require(propensity_clip < 0.5)
    {
      data,
      n_folds,
      n_rep,
      seed,
      propensity_clip,
      ml_g,
      ml_m,
      g0_hat: Array::make(data.n_obs(), 0.0),
      g1_hat: Array::make(data.n_obs(), 0.0),
      m_hat: Array::make(data.n_obs(), 0.0),
      m_raw: Array::make(data.n_obs(), 0.0),
      coef: 0.0,
      se: 0.0,
      fitted: false,
      psi_a: Array::make(data.n_obs(), -1.0),
      psi_b: Array::make(data.n_obs(), 0.0),
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      // v0.80.0+: default memoize off so v0.79.0 callers see
      // byte-identical fit() output. Enable explicitly via
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
pub fn DoubleMLIRM::n_obs(self : DoubleMLIRM) -> Int {
  self.data.n_obs()
}

///|
/// Number of features (covariate columns).
pub fn DoubleMLIRM::n_features(self : DoubleMLIRM) -> Int {
  self.data.n_features()
}

///|
pub fn DoubleMLIRM::coef(self : DoubleMLIRM) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLIRM::se(self : DoubleMLIRM) -> Double {
  try {
    require(self.fitted)
    self.se
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.67.0+: `joint` is a no-op for single-theta estimators
/// (the joint CI equals the Wald CI); accepted for API
/// parity with the multi-theta estimators.
pub fn DoubleMLIRM::confint(
  self : DoubleMLIRM,
  joint? : Bool = false,
  level? : Double = 0.95,
) -> (Double, Double) {
  try {
    require(self.fitted)
    require(level > 0.0 && level < 1.0)
    let z = norm_ppf(1.0 - (1.0 - level) / 2.0)
    let lo = self.coef - z * self.se
    let hi = self.coef + z * self.se
    ignore(joint)
    (lo, hi)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLIRM::predictions_g0(self : DoubleMLIRM) -> Array[Double] {
  self.g0_hat
}

///|
pub fn DoubleMLIRM::predictions_g1(self : DoubleMLIRM) -> Array[Double] {
  self.g1_hat
}

///|
pub fn DoubleMLIRM::predictions_m(self : DoubleMLIRM) -> Array[Double] {
  self.m_hat
}

///|
/// Raw (pre-clipping) propensity scores, length `n_obs`.
/// v0.53.0-dev Task 4: mirrors upstream feat "retain raw IRM
/// propensity scores" so callers can inspect the un-clipped
/// predictions without re-fitting.
pub fn DoubleMLIRM::propensity_score_raw(self : DoubleMLIRM) -> Array[Double] {
  self.m_raw
}

///|
/// Accessor for the outcome-nuisance learner used by the most
/// recent `fit(...)` / `fit_cluster(...)` call. v0.59.0+.
pub fn DoubleMLIRM::learner_g(self : DoubleMLIRM) -> LearnerDispatch {
  self.ml_g
}

///|
/// Accessor for the propensity-score learner used by the most
/// recent `fit(...)` / `fit_cluster(...)` call. v0.59.0+.
pub fn DoubleMLIRM::learner_m(self : DoubleMLIRM) -> LearnerDispatch {
  self.ml_m
}

///|
/// v0.80.0+: turn on memoization for subsequent `fit()` calls.
/// When enabled, `fit()` will cache the per-observation nuisance
/// predictions and the fold partition and skip the
/// `cross_fit_irm(...)` step on a repeat call whose data +
/// learner fingerprint is unchanged. Returns a new
/// `DoubleMLIRM` with the flag set (the struct is immutable;
/// the cache itself is populated by the next `fit()` call).
///
/// Default is OFF. When OFF, every `fit()` call runs the full
/// cross-fit and the cache is neither read nor written, so
/// v0.79.0 callers see byte-identical output.
pub fn DoubleMLIRM::enable_memoize(self : DoubleMLIRM) -> DoubleMLIRM {
  { ..self, memoize_enabled: true, }
}

///|
/// v0.80.0+: turn off memoization. Same immutability contract
/// as `enable_memoize()`. After this, `fit()` will not read or
/// write the cache; the existing `fit_cache` is preserved on
/// the returned struct (call `clear_cache()` to drop it).
pub fn DoubleMLIRM::disable_memoize(self : DoubleMLIRM) -> DoubleMLIRM {
  { ..self, memoize_enabled: false, }
}

///|
/// v0.80.0+: drop any cached nuisance predictions and fold
/// assignment. Useful when the caller wants to free memory or
/// force the next `fit()` to recompute from scratch (e.g.
/// after mutating a learner in place that the cache key does
/// not detect).
pub fn DoubleMLIRM::clear_cache(self : DoubleMLIRM) -> DoubleMLIRM {
  { ..self, fit_cache: FitCache::empty(), }
}

///|
/// v0.80.0+: `true` iff `fit_cache` holds at least one cached
/// observation (i.e. at least one prior `fit()` call with
/// `memoize_enabled = true` has populated the cache). Note
/// that the cache may still be stale relative to the current
/// data + learner configuration -- check `memoize_enabled`
/// before assuming a cache hit.
pub fn DoubleMLIRM::has_cache(self : DoubleMLIRM) -> Bool {
  !self.fit_cache.is_empty()
}

///|
/// Filter `idx` to keep only entries `i` for which `mask[i]` is true.
pub fn filter_indices(idx : Array[Int], mask : Array[Double]) -> Array[Int] {
  let out : Array[Int] = []
  for i in idx {
    if mask[i] == 1.0 {
      out.push(i)
    }
  }
  out
}

///|
/// Clip every element of `v` to `[lo, hi]` in place (returns a new
/// array; does not mutate the input).
pub fn clip_vec(v : Array[Double], lo : Double, hi : Double) -> Array[Double] {
  let n = v.length()
  let out = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let x = v[i]
    out[i] = if x < lo { lo } else if x > hi { hi } else { x }
  }
  out
}

///|
/// Cross-fitted nuisance predictions for an IRM model. For each fold
/// we train three learners:
///   - `ml_g` on `(x[train_d0], y[train_d0])` for the `D = 0` group,
///     then predict on `x[test]`,
///   - `ml_g` on `(x[train_d1], y[train_d1])` for the `D = 1` group,
///     then predict on `x[test]`,
///   - `ml_m` on `(x[train], d[train])`, then predict on `x[test]`,
///     clipped to `[eps, 1 - eps]`.
///
/// Returns `(g0_hat, g1_hat, m_hat)` each of length `n_obs`. If a
/// conditional training subset is empty (e.g. an extreme D imbalance
/// falls into one half of a 2-fold split), the call aborts via
/// `require(...)` rather than silently writing zero predictions —
/// silently-zero nuisance predictions would corrupt the ATE score.
fn cross_fit_irm(
  ml_g : LearnerDispatch,
  ml_m : LearnerDispatch,
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  folds : Array[Fold],
  propensity_clip : Double,
) -> (Array[Double], Array[Double], Array[Double], Array[Double]) {
  try {
    let n_obs = x.rows()
    let g0 = Array::make(n_obs, 0.0)
    let g1 = Array::make(n_obs, 0.0)
    let m = Array::make(n_obs, 0.0)
    for fold in folds {
      let train_idx = fold.train_indices()
      let test_idx = fold.test_indices()
      // g0: train on D == 0 — build a single Fold covering
      // (train_d0, test_idx) and call `cross_fit_predict_dispatch`
      // with [single_fold]. The standard cross_fit helper handles
      // the LearnerDispatch enum dispatch (5 arms) for us.
      let train_d0 : Array[Int] = []
      for i in train_idx {
        if d[i] == 0.0 {
          train_d0.push(i)
        }
      }
      require(train_d0.length() > 0)
      let p0 = cross_fit_predict_dispatch(ml_g, x, y, [
        Fold::new(train_d0, test_idx),
      ])
      for k = 0; k < test_idx.length(); k = k + 1 {
        let row = test_idx[k]
        g0[row] = p0[row]
      }
      // g1: train on D == 1 — same single-fold dispatch pattern.
      let train_d1_only : Array[Int] = []
      for i in train_idx {
        if d[i] == 1.0 {
          train_d1_only.push(i)
        }
      }
      require(train_d1_only.length() > 0)
      let p1 = cross_fit_predict_dispatch(ml_g, x, y, [
        Fold::new(train_d1_only, test_idx),
      ])
      for k = 0; k < test_idx.length(); k = k + 1 {
        let row = test_idx[k]
        g1[row] = p1[row]
      }
      // m: train on all rows of train_idx — single fold covering
      // (train_idx, test_idx). Uses `ml_m` (the propensity learner).
      let pm = cross_fit_predict_dispatch(ml_m, x, d, [
        Fold::new(train_idx, test_idx),
      ])
      for k = 0; k < test_idx.length(); k = k + 1 {
        let row = test_idx[k]
        m[row] = pm[row]
      }
    }
    // m must be clipped
    let m_clipped = clip_vec(m, propensity_clip, 1.0 - propensity_clip)
    (g0, g1, m_clipped, m)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Run the IRM estimation. The default learners are closed-form
/// `LinearRegression` instances for both the outcome nuisance (`ml_g`)
/// and the propensity score (`ml_m`).
///
/// Per-repetition behaviour: each repetition `r` cross-fits the
/// `g0 / g1 / m` nuisances from its own folds (seed `self.seed + r`),
/// computes its own `(theta_r, se_r)` from the ATE score, and the two
/// arrays are then aggregated by `aggregate_coef_se` (median of
/// thetas, then SE from the median of `(theta_r + 1.96 * se_r)`). For
/// `n_rep == 1` the aggregator returns the single `(theta_1, se_1)`
/// exactly, so the byte-equality with the previous "average then
/// estimate" implementation is preserved. The
/// `predictions_g0 / g1 / m` accessors return the nuisances from the
/// *last* repetition (the conventional choice in upstream `doubleml`),
/// not a cross-rep average.
///
/// When `self.data` carries a non-empty `cluster_vars` vector, the
/// estimator routes through the clustered DML path: folds partition
/// whole units (rows of one cluster id stay on the same side of
/// every split), the ATE is the fold-weighted ratio of cluster
/// score sums, and the SE is unit-level cluster-robust.
pub fn DoubleMLIRM::fit(
  self : DoubleMLIRM,
  ml_g? : LearnerDispatch = self.ml_g,
  ml_m? : LearnerDispatch = self.ml_m,
  max_attempts? : Int = 1,
) -> DoubleMLIRM {
  try {
    require(max_attempts >= 1)
    if self.data.is_cluster_data() {
      return self.fit_cluster(ml_g~, ml_m~, max_attempts~)
    }
    let n = self.n_obs()
    let nrep = self.n_rep
    // v0.80.0+: memoize check. The cache stores the LAST rep's
    // fold assignment and nuisance predictions. We honor the
    // cache only when:
    //   (a) the user opted in (`self.memoize_enabled`),
    //   (b) n_rep == 1 (multi-rep aggregations must run every
    //       rep fresh -- we cannot cache individual rep scores),
    //   (c) `is_valid(...)` matches every dimension of the
    //       data + learner fingerprint.
    // When memoize_enabled is false (the default), the entire
    // cache code path is skipped so v0.79.0 callers see a
    // byte-identical fit() output.
    let memoize = self.memoize_enabled && nrep == 1
    let data_hash : UInt64 = if memoize {
      hash_data(
        self.data.x,
        self.data.y,
        self.data.d,
        z=[],
        cluster_vars=self.data.cluster_vars,
      )
    } else {
      0UL
    }
    let hparams_hash : UInt64 = if memoize {
      hash_hyperparams("irm", ml_g, ml_m, self.propensity_clip)
    } else {
      0UL
    }
    // v0.82.0+: cache invalidation now also considers the
    // `cluster_ids_hash`. An IID fit (empty cluster_vars) and
    // a clustered fit (non-empty cluster_vars) of the same data
    // produce different nuisances, so we must compare the
    // stored hash to the caller's hash.
    let cluster_hash : UInt64 = if memoize {
      hash_cluster_ids(self.data.cluster_vars)
    } else {
      0UL
    }
    let cache_hit = memoize &&
      self.fit_cache.is_valid(
        self.seed,
        self.n_folds,
        nrep,
        n,
        data_hash,
        hparams_hash,
        cluster_hash,
        "irm",
      )
    let coefs : Array[Double] = Array::make(nrep, 0.0)
    let ses : Array[Double] = Array::make(nrep, 0.0)
    // hold the last rep's predictions; final values land in g0_hat / g1_hat / m_hat
    let mut g0 : Array[Double] = Array::make(n, 0.0)
    let mut g1 : Array[Double] = Array::make(n, 0.0)
    let mut m : Array[Double] = Array::make(n, 0.0)
    let mut m_raw : Array[Double] = Array::make(n, 0.0)
    // Track the LAST rep's fold_ids (for cache write below).
    let mut fold_ids : Array[Int] = []
    for r = 0; r < nrep; r = r + 1 {
      let rep_seed = self.seed + r
      let (g0_r, g1_r, m_r, m_raw_r) = if cache_hit && r == nrep - 1 {
        // Reuse the cached LAST-rep predictions. The cache
        // stores exactly one fold partition + one set of
        // nuisance arrays; when `cache_hit` is true the cache
        // is guaranteed to be in sync with the current call's
        // (seed, n_folds, n_rep) so this is correct.
        let preds = self.fit_cache.predictions
        fold_ids = self.fit_cache.fold_ids
        (preds[0], preds[1], preds[2], preds[3])
      } else {
        let folds = kfold(n, self.n_folds, rep_seed)
        // Build the row -> fold_id map for the cache write below.
        let fid : Array[Int] = Array::make(n, 0)
        for f = 0; f < folds.length(); f = f + 1 {
          for i in folds[f].test_indices() {
            fid[i] = f
          }
        }
        fold_ids = fid
        cross_fit_irm(
          ml_g,
          ml_m,
          self.data.x,
          self.data.y,
          self.data.d,
          folds,
          self.propensity_clip,
        )
      }
      g0 = g0_r
      g1 = g1_r
      m = m_r
      m_raw = m_raw_r
      // Score (ATE, weights=1, weights_bar=1) -- uses THIS rep's nuisances only.
      // v0.81.0+: the per-observation residuals `u0 = y - g0` and
      // `u1 = y - g1` are extracted via `vector_subtract` so the
      // element-wise subtract is a single named building block rather
      // than an inlined per-iteration load/subtract. The remaining
      // `psi_b` expression still uses a per-observation loop because
      // it combines `vector_subtract` results with scalar arithmetic
      // (`d * u1 / m`, `(1 - d) * u0 / (1 - m)`) that we have not
      // yet generalised to a vector helper.
      let y = self.data.y
      let d = self.data.d
      let u0 = vector_subtract(y, g0)
      let u1 = vector_subtract(y, g1)
      let psi_a : Array[Double] = Array::make(n, -1.0)
      let psi_b : Array[Double] = Array::make(n, 0.0)
      for i = 0; i < n; i = i + 1 {
        let m_i = m[i]
        let one_minus_m = 1.0 - m_i
        let d_over_m = d[i] * u1[i] / m_i
        let one_minus_d_over_one_minus_m = (1.0 - d[i]) * u0[i] / one_minus_m
        psi_b[i] = g1[i] - g0[i] + (d_over_m - one_minus_d_over_one_minus_m)
      }
      let (coef_r, se_r) = var_est(psi_a, psi_b)
      coefs[r] = coef_r
      ses[r] = se_r
    }
    // last iteration's predictions are now in g0 / g1 / m
    let (coef, se) = aggregate_coef_se(coefs, ses)
    // v0.61.0: per-observation influence function for the
    // multiplier bootstrap. Recompute `psi_a / psi_b` from
    // the last rep's cross-fitted nuisances so the stored
    // arrays align with `g0_hat` / `g1_hat` / `m_hat` and
    // `coef` (matches the v0.20.0+ DID convention).
    // v0.81.0+: the `u0 = y - g0` and `u1 = y - g1` extractions
    // route through `vector_subtract` (same vectorisation as
    // the per-rep score loop above).
    let psi_a : Array[Double] = Array::make(n, -1.0)
    let psi_b : Array[Double] = Array::make(n, 0.0)
    let y_last = self.data.y
    let d_last = self.data.d
    let u0_last = vector_subtract(y_last, g0)
    let u1_last = vector_subtract(y_last, g1)
    for i = 0; i < n; i = i + 1 {
      let m_i = m[i]
      let one_minus_m = 1.0 - m_i
      let d_over_m = d_last[i] * u1_last[i] / m_i
      let one_minus_d_over_one_minus_m = (1.0 - d_last[i]) *
        u0_last[i] /
        one_minus_m
      psi_b[i] = g1[i] - g0[i] + (d_over_m - one_minus_d_over_one_minus_m)
    }
    // v0.80.0+: when memoize is on and the cache missed, write
    // the freshly-computed fold_ids + nuisances to the cache so
    // the next `fit()` call can short-circuit. Skip the write
    // when the cache was already hit (no new info) and when
    // nrep > 1 (cache only stores the LAST rep).
    let next_cache = if memoize && !cache_hit && nrep == 1 {
      FitCache::from_fit(
        fold_ids,
        [g0, g1, m, m_raw],
        self.seed,
        self.n_folds,
        nrep,
        n,
        data_hash,
        hparams_hash,
        cluster_hash,
        "irm",
      )
    } else {
      self.fit_cache
    }
    {
      data: self.data,
      n_folds: self.n_folds,
      n_rep: self.n_rep,
      seed: self.seed,
      propensity_clip: self.propensity_clip,
      // v0.59.0+: persist the per-fit learner overrides onto
      // the returned struct. Defaults preserve v0.57.0 surface
      // when callers don't override.
      ml_g,
      ml_m,
      g0_hat: g0,
      g1_hat: g1,
      m_hat: m,
      m_raw,
      coef,
      se,
      fitted: true,
      psi_a,
      psi_b,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      // v0.80.0+: persist the per-fit memoize flag and the
      // (possibly updated) cache. When `memoize_enabled` is
      // false, `fit_cache` is unchanged; when true and the
      // data fingerprint matches, `fit_cache` already holds
      // the LAST rep's nuisances (no rewrite needed).
      memoize_enabled: self.memoize_enabled,
      fit_cache: next_cache,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Clustered-DML path for `DoubleMLIRM`. Same shape as
/// `DoubleMLPLR::fit_cluster`: folds are drawn over the unique
/// cluster ids, expanded to row folds; `g0`, `g1`, `m` are
/// cross-fitted with cluster-respecting folds; the ATE
/// coefficient is the fold-weighted ratio of cluster score sums
/// (the IRM `psi_a = -1.0` is constant so the weighted sum
/// collapses to `n_units`-normalised mean), and the SE is the
/// unit-level cluster-robust `var_est_cluster`.
fn DoubleMLIRM::fit_cluster(
  self : DoubleMLIRM,
  ml_g~ : LearnerDispatch,
  ml_m~ : LearnerDispatch,
  max_attempts? : Int = 1,
) -> DoubleMLIRM {
  try {
    require(max_attempts >= 1)
    let cluster = self.data.cluster_vars
    let n = self.n_obs()
    let nrep = self.n_rep
    let uniq = unique_units(cluster)
    let n_units = uniq.length()
    require(self.n_folds <= n_units)
    // v0.36.0: build_row_unit_map raises ClusterDataError on
    // malformed cluster vector; catch and re-abort to preserve
    // pre-v0.36.0 behavior.
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
    let coefs : Array[Double] = Array::make(nrep, 0.0)
    let ses : Array[Double] = Array::make(nrep, 0.0)
    let mut g0 : Array[Double] = Array::make(n, 0.0)
    let mut g1 : Array[Double] = Array::make(n, 0.0)
    let mut m : Array[Double] = Array::make(n, 0.0)
    let mut m_raw : Array[Double] = Array::make(n, 0.0)
    for r = 0; r < nrep; r = r + 1 {
      // v0.40.0: retry loop on J-floor. Each retry uses a different
      // fold split (seed = self.seed + r + attempt*nrep) so the
      // fold-mean J is different.
      let mut theta_r = 0.0
      let mut se_r = 0.0
      let mut attempt = 0
      let mut succeeded = false
      while attempt < max_attempts && !succeeded {
        let rep_seed = self.seed + r + attempt * nrep
        let folds_u = kfold(n_units, self.n_folds, rep_seed)
        let (folds_row, unit_fold, fold_n_units) = expand_unit_folds_to_rows(
          cluster, folds_u, row_unit,
        )
        let (g0_r, g1_r, m_r, m_raw_r) = cross_fit_irm(
          ml_g,
          ml_m,
          self.data.x,
          self.data.y,
          self.data.d,
          folds_row,
          self.propensity_clip,
        )
        g0 = g0_r
        g1 = g1_r
        m = m_r
        m_raw = m_raw_r
        // v0.81.0+: per-observation residuals extracted via `vector_subtract`
        // (matches the IID fit() vectorisation above). `psi_a` is
        // constant `-1` for the IRM ATE score, so it is allocated
        // directly to that value rather than filled in a loop.
        let u0 = vector_subtract(self.data.y, g0)
        let u1 = vector_subtract(self.data.y, g1)
        let psi_a : Array[Double] = Array::make(n, -1.0)
        let psi_b : Array[Double] = Array::make(n, 0.0)
        for i = 0; i < n; i = i + 1 {
          let m_i = m[i]
          let one_minus_m = 1.0 - m_i
          let d_over_m = self.data.d[i] * u1[i] / m_i
          let one_minus_d_over_one_minus_m = (1.0 - self.data.d[i]) *
            u0[i] /
            one_minus_m
          psi_b[i] = g1[i] - g0[i] + (d_over_m - one_minus_d_over_one_minus_m)
        }
        let (t, s) = cluster_causal_param_and_se(
          psi_a,
          psi_b,
          folds_row,
          fold_n_units,
          unit_rows,
          unit_fold,
          folds_u.length(),
          self.n_folds,
        ) catch {
          _ => {
            attempt = attempt + 1
            (0.0, 0.0)
          }
        }
        theta_r = t
        se_r = s
        succeeded = true
      }
      if !succeeded {
        abort(
          "var_est_cluster: J-floor fired " +
          max_attempts.to_string() +
          " times for rep=" +
          r.to_string() +
          " (cluster SE numerically unstable across multiple fold splits, try a different seed or larger n_units)",
        )
      }
      coefs[r] = theta_r
      ses[r] = se_r
    }
    let (coef, se) = aggregate_coef_se(coefs, ses)
    // v0.61.0: per-observation influence function for the
    // multiplier bootstrap. Same convention as `fit()`:
    // recompute from the last rep's cross-fitted nuisances so
    // the stored arrays align with `g0_hat` / `g1_hat` /
    // `m_hat` and `coef`. v0.81.0+: residuals via
    // `vector_subtract` (matches the IID fit() vectorisation).
    let psi_a : Array[Double] = Array::make(n, -1.0)
    let psi_b : Array[Double] = Array::make(n, 0.0)
    let u0 = vector_subtract(self.data.y, g0)
    let u1 = vector_subtract(self.data.y, g1)
    for i = 0; i < n; i = i + 1 {
      let m_i = m[i]
      let one_minus_m = 1.0 - m_i
      let d_over_m = self.data.d[i] * u1[i] / m_i
      let one_minus_d_over_one_minus_m = (1.0 - self.data.d[i]) *
        u0[i] /
        one_minus_m
      psi_b[i] = g1[i] - g0[i] + (d_over_m - one_minus_d_over_one_minus_m)
    }
    {
      data: self.data,
      n_folds: self.n_folds,
      n_rep: self.n_rep,
      seed: self.seed,
      propensity_clip: self.propensity_clip,
      // v0.59.0+: persist per-fit learner overrides on the
      // cluster-path return struct too. Defaults preserve
      // v0.57.0 surface for plain `fit_cluster` callers.
      ml_g,
      ml_m,
      g0_hat: g0,
      g1_hat: g1,
      m_hat: m,
      m_raw,
      coef,
      se,
      fitted: true,
      psi_a,
      psi_b,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      // v0.80.0+: cluster path does not currently consume the
      // memoization cache (the J-floor retry loop can rewrite
      // the fold assignment on a per-attempt basis, which
      // complicates the cache key). Persist the flags so the
      // next non-cluster `fit()` call still honors memoize.
      memoize_enabled: self.memoize_enabled,
      fit_cache: self.fit_cache,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.61.0+: multiplier bootstrap for `DoubleMLIRM`. The
/// per-observation influence function is
///
///   psi[i] = psi_a[i] + theta * psi_b[i]
///          = -1 + theta * psi_b[i]
///
/// where `psi_b[i] = (g1-g0)[i] + (D*u1/m - (1-D)*u0/(1-m))[i]`
/// is computed at the fitted `coef` from the last rep's
/// cross-fitted nuisances `g0_hat` / `g1_hat` / `m_hat`.
/// Draws `n_rep_boot` weight vectors of length `n_obs` from
/// the chosen multiplier distribution, and returns a fitted
/// model with `boot_t_stat[b] = sum_i w[b, i] * psi[i] /
/// (sqrt(n) * se_psi)` populated where
/// `se_psi = sqrt(mean(psi^2))`.
///
/// `method_name` selects the multiplier distribution:
///   - `"normal"` (default): `w[i] ~ N(0, 1)`.
///   - `"Bayes"`: `w[i] = exp(1) - 1` (mean 0, var 1).
///   - `"wild"`: `w[i] = x[i] / sqrt(2) + (y[i]^2 - 1) / 2`
///     with `x, y ~ N(0, 1)`.
///
/// Calling `bootstrap` requires the model to be fitted; calling
/// on an un-fit model aborts with `PreconditionError`. The
/// helper is `did_bootstrap_t_stat` (v0.55.0 extracted from
/// `DoubleMLDIDCrossSection::bootstrap`); IRM is the
/// `n_thetas=1` case.
pub fn DoubleMLIRM::bootstrap(
  self : DoubleMLIRM,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLIRM {
  try {
    require(self.fitted)
    require(
      method_name == "normal" || method_name == "Bayes" || method_name == "wild",
    )
    require(n_rep_boot >= 2)
    let n = self.n_obs()
    // Draw weights. Shape: (n_rep_boot, n_obs).
    let weights = draw_bootstrap_weights(method_name, n_rep_boot, n, seed) catch {
      BootstrapMethodError::UnknownMethod(m) =>
        abort(
          "draw_bootstrap_weights: unknown method (set in DoubleMLIRM::bootstrap): " +
          m,
        )
    }
    // Compute psi[i] = psi_a[i] + coef * psi_b[i] and
    // ss_psi = sum(psi[i]^2) once. `psi_a[i] = -1` and
    // `psi_b` is the per-observation ATE score, both
    // populated by `fit(...)` from the last rep's nuisances.
    let psi : Array[Double] = Array::make(n, 0.0)
    let mut ss_psi = 0.0
    for i = 0; i < n; i = i + 1 {
      let psi_i = self.psi_a[i] + self.coef * self.psi_b[i]
      psi[i] = psi_i
      ss_psi = ss_psi + psi_i * psi_i
    }
    let n_d = n.to_double()
    let se_psi = (ss_psi / n_d).sqrt()
    if se_psi <= 0.0 {
      // Degenerate: psi sums to 0. Cannot divide.
      let boot_t_stat_zero : Array[Double] = Array::make(n_rep_boot, 0.0)
      return {
        ..self,
        boot_t_stat: boot_t_stat_zero,
        boot_method: method_name,
        n_rep_boot,
        boot_seed: seed,
      }
    }
    // n_thetas=1 case.
    let se_flat : Array[Double] = [se_psi]
    let boot_t_stat = did_bootstrap_t_stat(
      weights, psi, se_flat, n_rep_boot, n, 1,
    )
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
/// v0.65.0+: tune the (ml_g, ml_m) nuisance-learner pair via
/// MSE-on-g_hat cross-fitting (matches `DoubleMLPLR::tune`'s
/// MSE-on-l_hat scoring convention; see tune.mbt §4.1). The
/// chosen `(learner_g, learner_m)` is then re-fit on the
/// FINAL-FIT fold partition (`self.n_folds`) under
/// `DoubleMLIRM::fit`. Cluster-DML is not supported in
/// tune (mirrors the PLR behaviour — `tune` requires
/// `!self.data.is_cluster_data()`).
///
/// `param_set` is an `Array[TuneParam]`; each entry is a
/// `(learner_g, learner_m)` pair. `scoring_method` is
/// `"MSE"` (default), `"RMSE"`, or `"NegMSE"`. Returns a
/// re-fitted `DoubleMLIRM` with the chosen learners applied.
/// The chosen pair is visible via `ml_g` / `ml_m` on the
/// returned model (no `tune_result` field is persisted —
/// that audit field is reserved for PLR-style estimators).
pub fn DoubleMLIRM::tune(
  self : DoubleMLIRM,
  param_set~ : Array[TuneParam],
  scoring_method? : String = "MSE",
  n_folds_tune? : Int = 5,
  seed? : Int = 3141,
) -> DoubleMLIRM {
  try {
    require(param_set.length() > 0)
    require(n_folds_tune >= 2)
    require(!self.data.is_cluster_data())
    let scoring = TuneScoring::parse(scoring_method)
    let folds_tune = kfold(self.n_obs(), n_folds_tune, seed)
    let n = self.n_obs()
    let scores : Array[Double] = Array::make(param_set.length(), 0.0)
    for i = 0; i < param_set.length(); i = i + 1 {
      let c = param_set[i]
      let g_hat_c = cross_fit_predict_dispatch(
        c.learner_l,
        self.data.x,
        self.data.y,
        folds_tune,
      )
      scores[i] = if g_hat_c.length() == n {
        tune_score_outcome(self.data.y, g_hat_c, scoring)
      } else {
        TUNE_SCORE_FAIL_SENTINEL
      }
    }
    // argmin rule (NegMSE = argmax).
    let best_idx = if scoring is NegMSE {
      let mut bi = 0
      let mut bv = scores[0]
      for i = 1; i < scores.length(); i = i + 1 {
        if scores[i] > bv {
          bv = scores[i]
          bi = i
        }
      }
      bi
    } else {
      let mut bi = 0
      let mut bv = scores[0]
      for i = 1; i < scores.length(); i = i + 1 {
        if scores[i] < bv {
          bv = scores[i]
          bi = i
        }
      }
      bi
    }
    let best_param = param_set[best_idx]
    self.fit(ml_g=best_param.learner_l, ml_m=best_param.learner_m)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.66.0+: Cinelli & Hazlett (2020) omitted-variable bias
/// analysis. Outcome residual is
/// `y - g0_hat - (g1_hat - g0_hat) * d` (the doubly-robust
/// outcome regression evaluated at the observed treatment);
/// the Riesz-representer variance is `mean(psi_a^2) = 1`
/// for the IRM ATE score (`psi_a = -1` constant — the
/// helper short-circuits when `nu2 == 1`). Routes through
/// the shared `irm_style_sensitivity` helper (see
/// sensitivity.mbt).
pub fn DoubleMLIRM::sensitivity_analysis(
  self : DoubleMLIRM,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let g0 = self.predictions_g0()
  let g1 = self.predictions_g1()
  let d = self.data.d
  let n = g0.length()
  // v0.81.0+: residual extraction via `vector_subtract` for the
  // outcome `y - g0` component. The `(g1[i] - g0[i]) * d[i]`
  // correction is per-observation scalar arithmetic and stays
  // in a loop (no vector helper for that combination yet).
  let y_minus_g0 = vector_subtract(self.data.y, g0)
  let g1_minus_g0 = vector_subtract(g1, g0)
  let residuals : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    residuals[i] = y_minus_g0[i] - g1_minus_g0[i] * d[i]
  }
  irm_style_sensitivity(self.coef, residuals, self.psi_a, cf_y, cf_d)
}

///|
/// v0.72.0+: cluster-robust analogue of
/// `DoubleMLIRM::sensitivity_analysis`. Same DID-style
/// residual form (`y - g0 - (g1 - g0) * d`) and the same
/// `psi_a = -1` (constant) as the IID path; only the
/// variance / bias computation is cluster-aware.
/// `cluster_ids` defaults to `DoubleMLData::cluster_vars`.
pub fn DoubleMLIRM::sensitivity_analysis_cluster(
  self : DoubleMLIRM,
  cluster_ids? : Array[Int] = self.data.cluster_vars,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let g0 = self.predictions_g0()
  let g1 = self.predictions_g1()
  let d = self.data.d
  let n = g0.length()
  require(cluster_ids.length() == n)
  // v0.81.0+: residual extraction via `vector_subtract` (same
  // pattern as the IID `sensitivity_analysis` path above).
  let y_minus_g0 = vector_subtract(self.data.y, g0)
  let g1_minus_g0 = vector_subtract(g1, g0)
  let residuals : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    residuals[i] = y_minus_g0[i] - g1_minus_g0[i] * d[i]
  }
  irm_style_sensitivity_cluster(
    self.coef,
    residuals,
    self.psi_a,
    cluster_ids,
    cf_y,
    cf_d,
  )
}

///|
/// v0.79.0+: Huber-White sandwich standard error for the
/// fitted IRM. Returns `sqrt(var_xx)` where `var_xx` is
/// computed by the `sandwich_variance_xx` free function
/// in `sandwich.mbt` (HC0 / HC1 / HC2 / HC3). The Jacobian
/// inverse `M_inv = [[1 / mean(psi_a)]]` is built from the
/// stored `psi_a` (which is `[-1, -1, ..., -1]` for the
/// IRM ATE score, so `M_inv = [[-1.0]]` always — the
/// `mean(psi_a)` is `-1` by construction).
///
/// Preconditions: `self.fitted`.
pub fn DoubleMLIRM::sandwich_se(
  self : DoubleMLIRM,
  kind : SandwichKind,
) -> Double {
  try {
    require(self.fitted)
    let n = self.n_obs()
    // psi = psi_a + coef * psi_b (the per-observation IF
    // evaluated at the fitted coef).
    let psi : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      psi[i] = self.psi_a[i] + self.coef * self.psi_b[i]
    }
    // M_inv = [[1 / mean(psi_a)]]. For the IRM ATE score
    // `psi_a = -1` so `mean(psi_a) = -1` and `M_inv = -1`;
    // we use the explicit mean (rather than hard-coding -1)
    // so the formula generalises to the PLR / future
    // multi-theta estimators.
    let mean_a = mean(self.psi_a)
    require(mean_a.abs() > 0.0)
    let m_inv = Matrix::from_array([1.0 / mean_a], 1, 1)
    let variance_val = match kind {
      HC0 => sandwich_variance_hc0(self.psi_a, psi, m_inv, n, 1)
      HC1 => sandwich_variance_hc1(self.psi_a, psi, m_inv, n, 1)
      HC2 => sandwich_variance_hc2(self.psi_a, psi, m_inv, n, 1)
      HC3 => sandwich_variance_hc3(self.psi_a, psi, m_inv, n, 1)
    }
    require(variance_val >= 0.0)
    variance_val.sqrt()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.79.0+: cluster-robust sandwich standard error for
/// the fitted IRM. Routes through
/// `cluster_sandwich_variance` in `sandwich.mbt` with
/// `M_inv = [[1 / mean(psi_a)]]` (matching the IID path's
/// Jacobian inverse).
///
/// Preconditions: `self.fitted`,
/// `cluster_ids.length() == n_obs`.
pub fn DoubleMLIRM::cluster_sandwich_se(
  self : DoubleMLIRM,
  cluster_ids : Array[Int],
) -> Double {
  try {
    require(self.fitted)
    let n = self.n_obs()
    require(cluster_ids.length() == n)
    let psi : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      psi[i] = self.psi_a[i] + self.coef * self.psi_b[i]
    }
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
/// v0.79.0+: finite-sample bias-corrected coefficient.
/// Uses the simple `psi_b - coef * psi_a` per-observation
/// bias form (the score evaluated at the fitted theta):
///
///     bias_per_obs[i] = psi_b[i] - coef * psi_a[i]
///     theta_corrected = coef + mean(bias_per_obs)
///
/// `psi_a = -1` for IRM ATE, so
/// `bias_per_obs[i] = psi_b[i] + coef` and the corrected
/// theta reduces to `2 * coef + mean(psi_b)` for the IRM
/// case. Callers wanting a different bias form should call
/// `bias_corrected_theta(...)` directly with their own
/// `bias_per_obs` vector.
///
/// Preconditions: `self.fitted`.
pub fn DoubleMLIRM::bias_corrected_coef(self : DoubleMLIRM) -> Double {
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
