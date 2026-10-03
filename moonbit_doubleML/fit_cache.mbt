///|
// Memoization layer for the cross-fitting step of DML estimators
// (v0.80.0). When `DoubleMLIRM` is created with `enable_memoize()`,
// repeated `fit()` calls with the same data fingerprint, fold
// split, and nuisance-learner configuration can reuse the cached
// per-observation nuisance predictions instead of re-fitting the
// outcome / propensity learners on every call.
//
// The cache is invalidated when any of the following change:
//   - the data (`hash_data(X, y, d, z, cluster_vars)`)
//   - the fold split (`fold_split_seed`, `n_folds`, `n_rep`)
//   - the observation count (`n_obs`)
//   - the nuisance-learner configuration
//     (`hash_hyperparams(estimator_kind, ml_g, ml_m)`)
//   - the estimator family (`estimator_kind` string)
//
// Scope: only the nuisance-prediction step is memoized. The
// coefficient / SE aggregation from the cached nuisances still
// runs on every `fit()` call (the cached `psi_a` / `psi_b` and
// the post-aggregation `(coef, se)` are recomputed, so changing
// the score / aggregator configuration always takes effect).
//
// Vectorization of the per-fold nuisance fit/predict is deferred
// to v0.81 -- this release only adds the caching layer.

///|
/// Memoization container for a single DML `fit()` call.
///
/// Stored on the estimator struct (e.g. `DoubleMLIRM::fit_cache`).
/// `predictions` is a list of per-observation nuisance prediction
/// arrays whose meaning depends on the estimator kind:
///
///   - `"irm"`: `[g0_hat, g1_hat, m_hat, m_raw]`
///   - `"plr"`: `[g_hat, m_hat]`
///   - `"iivm"`: `[g0_hat, g1_hat, m_hat, r0_hat, r1_hat]`
///   - `"pliv"`: `[g_hat, m_hat]`
///   - `"did"` / `"did_cs"`: `[g_pre, g_post, m_pre, m_post]`
///   - `"lpq"` / `"cvar"` / `"ssm"`: per-estimator nuisance arrays
///
/// `fold_ids[i]` is the test-fold index of observation `i` in
/// the LAST repetition (the one whose nuisances are stored).
///
/// `cluster_ids_hash` (v0.82.0+) is the hash of the
/// `cluster_vars` vector (or 0 for the IID path). The
/// `is_valid(...)` check requires the stored hash to match the
/// caller's hash, so a switch from IID to clustered (or a
/// different cluster partition) invalidates the cache.
pub struct FitCache {
  fold_ids : Array[Int]
  predictions : Array[Array[Double]]
  fold_split_seed : Int
  n_folds : Int
  n_rep : Int
  n_obs : Int
  data_hash : UInt64
  hyperparams_hash : UInt64
  cluster_ids_hash : UInt64
  estimator_kind : String
} derive(Debug)

///|
pub extend FitCache with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Empty cache sentinel. `fold_ids.length() == 0` is the "no
/// cache" marker; `is_valid(...)` returns `false` against this
/// empty cache because the per-call `n_obs` / `n_folds` /
/// hashes can never simultaneously match `0`.
pub fn FitCache::empty() -> FitCache {
  {
    fold_ids: [],
    predictions: [],
    fold_split_seed: 0,
    n_folds: 0,
    n_rep: 0,
    n_obs: 0,
    data_hash: 0UL,
    hyperparams_hash: 0UL,
    cluster_ids_hash: 0UL,
    estimator_kind: "",
  }
}

///|
/// `true` iff the cache holds no observations and was never
/// populated. The opposite of `is_valid(...)` against the
/// expected inputs.
pub fn FitCache::is_empty(self : FitCache) -> Bool {
  self.fold_ids.length() == 0
}

///|
/// Check whether the stored cache matches the requested
/// configuration. Returns `true` only if every dimension of the
/// fingerprint matches the current call -- otherwise the caller
/// must fall back to the standard (non-cached) cross-fit.
///
/// `cluster_ids_hash` (v0.82.0+) is the hash of the
/// `cluster_vars` vector (or 0 for the IID path). Pass the same
/// hash you used when the cache was populated; the caller's
/// hash is compared to the stored one to detect a switch from
/// IID to clustered (or a different cluster partition).
pub fn FitCache::is_valid(
  self : FitCache,
  fold_split_seed : Int,
  n_folds : Int,
  n_rep : Int,
  n_obs : Int,
  data_hash : UInt64,
  hyperparams_hash : UInt64,
  cluster_ids_hash : UInt64,
  estimator_kind : String,
) -> Bool {
  self.fold_ids.length() == n_obs &&
  self.fold_split_seed == fold_split_seed &&
  self.n_folds == n_folds &&
  self.n_rep == n_rep &&
  self.n_obs == n_obs &&
  self.data_hash == data_hash &&
  self.hyperparams_hash == hyperparams_hash &&
  self.cluster_ids_hash == cluster_ids_hash &&
  self.estimator_kind == estimator_kind
}

///|
/// FoldMix64 step: `(h ^ v) * FNV_PRIME_64`. The FNV-1a style
/// multiplication keeps the avalanche fast and the resulting
/// hash well-distributed. `FNV_PRIME_64` is the canonical 64-bit
/// FNV prime (1099511628211).
fn fold_mix(h : UInt64, v : UInt64) -> UInt64 {
  let prime : UInt64 = 0x00000100000001B3UL
  (h ^ v) * prime
}

///|
/// Mix a Double into the hash. MoonBit's `Double::to_uint64`
/// and `to_int64` truncate the value (not a bit-cast), so
/// using them directly would collide e.g. `0.999` with `0.0`.
/// We use `Double::to_string()` instead: the MoonBit runtime
/// emits a canonical scientific-notation string for each IEEE
/// bit pattern, so two different Doubles produce two different
/// strings and therefore two different hashes. The string is
/// slow to produce (relative to a bit cast), but the cost is
/// amortized across a single `fit()` call (the hash is
/// computed once per fit, not per access), so this stays
/// acceptable for memoization.
fn fold_mix_double(h : UInt64, v : Double) -> UInt64 {
  let s = v.to_string()
  let mut acc = h
  for c in s {
    acc = fold_mix_int(acc, c.to_int())
  }
  acc
}

///|
/// Mix an Int into the hash. Two's complement bit pattern gives
/// a stable mapping for all integer values (including negatives).
fn fold_mix_int(h : UInt64, v : Int) -> UInt64 {
  fold_mix(h, v.to_uint64())
}

///|
/// 64-bit content hash of the data passed to a DML estimator.
/// Combines the data dimensions, a sampled slice of `X` (first
/// 10 + last 10 rows, first column), and the full content of
/// `y`, `d`, `z`, and `cluster_vars`.
///
/// The hash is NOT cryptographic -- it is designed to detect
/// accidental input mutations (row reordering, scaling, value
/// edits, dimension changes) at O(n) cost. A malicious caller
/// could craft two different datasets that share the same hash;
/// that is acceptable for a memoization invalidation key.
pub fn hash_data(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  z? : Array[Double] = [],
  cluster_vars? : Array[Int] = [],
) -> UInt64 {
  let mut h : UInt64 = 0xcbf29ce484222325UL // FNV-1a 64-bit offset basis
  // Dimensions + vector lengths first so a dimension change
  // invalidates the cache even before sampling any values.
  h = fold_mix_int(h, x.rows())
  h = fold_mix_int(h, x.cols())
  h = fold_mix_int(h, y.length())
  h = fold_mix_int(h, d.length())
  h = fold_mix_int(h, z.length())
  h = fold_mix_int(h, cluster_vars.length())
  // X sample: first 10 + last 10 rows, column 0 only. Cheap
  // (2*10 = 20 cell accesses) and catches the common cases of
  // row scaling / column edits / append-prepend mutations.
  let n_rows = x.rows()
  let n_cols = x.cols()
  if n_rows > 0 && n_cols > 0 {
    let first_n = if n_rows < 10 { n_rows } else { 10 }
    for i = 0; i < first_n; i = i + 1 {
      h = fold_mix_double(h, x.get(i, 0))
    }
    if n_rows > 10 {
      let last_start = n_rows - 10
      for i = 0; i < 10; i = i + 1 {
        h = fold_mix_double(h, x.get(last_start + i, 0))
      }
    }
  }
  // Full content of the per-observation vectors.
  for v in y {
    h = fold_mix_double(h, v)
  }
  for v in d {
    h = fold_mix_double(h, v)
  }
  for v in z {
    h = fold_mix_double(h, v)
  }
  for v in cluster_vars {
    h = fold_mix_int(h, v)
  }
  h
}

///|
/// Hyperparameter fingerprint. Combines the estimator family
/// name, the two nuisance-learner dispatch tags (`ml_g` / `ml_m`),
/// and the propensity-clip tolerance (only used by IRM but
/// included unconditionally for cache-key uniformity).
///
/// Each `LearnerDispatch` variant is matched on a tag string
/// (`"linear_regression"` / `"logistic_regression"` / `"constant"`
/// / `"noop"` / `"random_forest"` / `"gradient_boosting"`). The
/// variant's tunables (e.g. RF `n_trees` / `max_depth`) are NOT
/// folded into the key in this release -- the same learner tag
/// re-used with different tunables will hit the cache and yield
/// stale predictions. Users who change tunables across calls
/// must call `DoubleMLIRM::clear_cache()` first. This trade-off
/// keeps the key short and matches the conventional "same
/// learner name = same learner" contract used by upstream
/// `doubleml-for-py`.
pub fn hash_hyperparams(
  estimator_kind : String,
  ml_g : LearnerDispatch,
  ml_m : LearnerDispatch,
  propensity_clip : Double,
) -> UInt64 {
  let mut h : UInt64 = 0x84222325cbf29ce4UL
  h = fold_mix_int(h, estimator_kind.length())
  // Fold the bytes of estimator_kind as Int hashes -- this gives
  // a length-aware, content-aware mix without depending on
  // `String` -> `UInt64` direct conversion.
  for c in estimator_kind {
    h = fold_mix_int(h, c.to_int())
  }
  h = fold_mix(h, learner_dispatch_tag(ml_g))
  h = fold_mix(h, learner_dispatch_tag(ml_m))
  h = fold_mix_double(h, propensity_clip)
  h
}

///|
/// Map a `LearnerDispatch` to a stable 64-bit tag. The tag is
/// derived from the variant's name string so two learners of the
/// same kind produce the same tag. Tunables are intentionally
/// NOT folded in -- see `hash_hyperparams` for the rationale.
fn learner_dispatch_tag(l : LearnerDispatch) -> UInt64 {
  let kind : String = match l {
    LinearRegression(_) => "linear_regression"
    LogisticRegression(_) => "logistic_regression"
    Constant(_) => "constant"
    Noop(_) => "noop"
    RandomForest(_) => "random_forest"
    GradientBoosting(_) => "gradient_boosting"
  }
  let mut h : UInt64 = 0x9e3779b97f40b847UL
  for c in kind {
    h = fold_mix_int(h, c.to_int())
  }
  h
}

///|
/// Build a `FitCache` from the LAST repetition's fold assignment
/// and nuisance predictions. `predictions` is interpreted by the
/// estimator (see the `FitCache` docstring for the per-kind
/// layout).
pub fn FitCache::from_fit(
  fold_ids : Array[Int],
  predictions : Array[Array[Double]],
  fold_split_seed : Int,
  n_folds : Int,
  n_rep : Int,
  n_obs : Int,
  data_hash : UInt64,
  hyperparams_hash : UInt64,
  cluster_ids_hash : UInt64,
  estimator_kind : String,
) -> FitCache {
  {
    fold_ids,
    predictions,
    fold_split_seed,
    n_folds,
    n_rep,
    n_obs,
    data_hash,
    hyperparams_hash,
    cluster_ids_hash,
    estimator_kind,
  }
}

///|
/// Compute the cache-key hash of a cluster-ids vector.
/// v0.82.0+: an empty vector hashes to 0 (the IID sentinel);
/// a non-empty vector hashes via FNV-style fold over its
/// entries. Two structurally-different cluster partitions
/// produce different hashes so the cache invalidates on a
/// cluster redefinition (e.g. a switch from individual-level
/// clustering to individual-by-time or a different
/// treatment-period partition).
pub fn hash_cluster_ids(cluster_ids : Array[Int]) -> UInt64 {
  if cluster_ids.length() == 0 {
    return 0UL
  }
  let mut h : UInt64 = 0xcbf29ce484222325UL
  // Length first so a length change invalidates the cache even
  // before sampling any value.
  h = fold_mix_int(h, cluster_ids.length())
  for v in cluster_ids {
    h = fold_mix_int(h, v)
  }
  h
}
