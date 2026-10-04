///|
/// Data container for `DoubleMLIIVM`. Same shape as `DoubleMLData`
/// but adds a single instrumental variable `z`. The treatment `d`
/// and the instrument `z` are both binary.
pub struct DoubleMLIIVMData {
  x : Matrix
  y : Array[Double]
  d : Array[Double]
  z : Array[Double]
  cluster_vars : Array[Int]
} derive(Debug)

///|
pub extend DoubleMLIIVMData with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLIIVMData::new(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  z : Array[Double],
  cluster_vars? : Array[Int] = [],
) -> DoubleMLIIVMData {
  try {
    require(x.nrows == y.length())
    require(x.nrows == d.length())
    require(x.nrows == z.length())
    if cluster_vars.length() > 0 {
      require(cluster_vars.length() == x.nrows)
    }
    { x, y, d, z, cluster_vars, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLIIVMData::n_obs(self : DoubleMLIIVMData) -> Int {
  self.x.rows()
}

///|
pub fn DoubleMLIIVMData::n_features(self : DoubleMLIIVMData) -> Int {
  self.x.cols()
}

///|
/// True iff the data is set up for clustered inference (a
/// non-empty `cluster_vars` vector was passed to `new`).
pub fn DoubleMLIIVMData::is_cluster_data(self : DoubleMLIIVMData) -> Bool {
  self.cluster_vars.length() > 0
}

///|
/// Length of the cluster_vars vector (0 when not clustered).
pub fn DoubleMLIIVMData::n_cluster_vars(self : DoubleMLIIVMData) -> Int {
  self.cluster_vars.length()
}

///|
/// Double / debiased machine learning estimator for the *interactive
/// IV regression model* (IIVM) of Chernozhukov et al. (2018) with the
/// *LATE* score, identifying the Local Average Treatment Effect on
/// the "compliers":
///
///     Y = theta * D + g_0(D, X) + U,    E[U | D, X] = 0
///     D = m_0(X, Z) + V,               E[V | X, Z] = 0
///
/// where the binary instrument `Z` satisfies the relevance and
/// exclusion restrictions. Five cross-fitted nuisance functions are
/// needed (each estimated out-of-fold via K-fold):
///
///     g0(X) = E[Y | Z = 0, X]      (trained only on Z = 0)
///     g1(X) = E[Y | Z = 1, X]      (trained only on Z = 1)
///     m(X)  = E[Z | X]             (trained on all obs, then
///                                   clipped to [eps, 1 - eps])
///     r0(X) = E[D | Z = 0, X]      (trained only on Z = 0)
///     r1(X) = E[D | Z = 1, X]      (trained only on Z = 1)
///
/// Residuals:
///
///     u_hat0 = Y - g0,  u_hat1 = Y - g1
///     w_hat0 = D - r0,  w_hat1 = D - r1
///
/// *LATE* score:
///
///     psi_b =  (g1 - g0) + Z u_hat1 / m - (1 - Z) u_hat0 / (1 - m)
///     psi_a = -(r1 - r0) - Z w_hat1 / m + (1 - Z) w_hat0 / (1 - m)
///     psi(theta) = theta * psi_a + psi_b
///
/// Point estimate and variance (same `_var_est` formula as the
/// other DML models):
///
///     theta_hat = -mean(psi_b) / mean(psi_a)
///     J         = mean(psi_a)
///     gamma     = mean(psi(theta_hat)^2)
///     sigma2    = gamma / (J^2 * n)
///     se        = sqrt(sigma2).
pub struct DoubleMLIIVM {
  data : DoubleMLIIVMData
  n_folds : Int
  n_rep : Int
  seed : Int
  propensity_clip : Double
  // v0.59.0+: injected nuisance learners (replaces the v0.57.0
  // hardcoded `LinearRegression`). Defaults to OLS so v0.57.0
  // callers see byte-identical results.
  ml_g : LearnerDispatch
  ml_m : LearnerDispatch
  ml_r : LearnerDispatch
  g0_hat : Array[Double]
  g1_hat : Array[Double]
  m_hat : Array[Double]
  r0_hat : Array[Double]
  r1_hat : Array[Double]
  coef : Double
  se : Double
  fitted : Bool
  // v0.61.0+: per-observation influence function components
  // for the multiplier bootstrap. IIVM LATE score:
  //   psi_a[i] = -(r1 - r0)[i] - Z[i]*w1[i]/m[i]
  //              + (1-Z[i])*w0[i]/(1-m[i])
  //   psi_b[i] = (g1 - g0)[i] + Z[i]*u1[i]/m[i]
  //              - (1-Z[i])*u0[i]/(1-m[i])
  // where `w0/1 = D - r0/1`, `u0/1 = Y - g0/1`, `m = clip(m_hat)`.
  // Length `n_obs`. Populated by `fit(...)` from the last
  // rep's nuisances.
  psi_a : Array[Double]
  psi_b : Array[Double]
  // v0.61.0+: multiplier bootstrap state. `boot_t_stat` is a
  // length-`n_rep_boot` array of t-statistics for `coef`.
  // Populated by `bootstrap(...)`; empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
  // v0.82.0+: memoization state. `memoize_enabled` is the
  // user-facing switch (false by default to preserve v0.81.0
  // behavior bit-for-bit). When true, `fit()` caches the last
  // repetition's nuisance predictions in `fit_cache` and
  // reuses them on the next call when the data fingerprint,
  // fold split, and learner configuration are unchanged.
  // Mirrors the IRM plumbing.
  memoize_enabled : Bool
  fit_cache : FitCache
} derive(Debug)

///|
pub extend DoubleMLIIVM with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLIIVM::new(
  data : DoubleMLIIVMData,
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
  ml_g? : LearnerDispatch = LearnerDispatch::linear_regression(),
  ml_m? : LearnerDispatch = LearnerDispatch::linear_regression(),
  ml_r? : LearnerDispatch = LearnerDispatch::linear_regression(),
) -> DoubleMLIIVM {
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
      ml_r,
      g0_hat: Array::make(data.n_obs(), 0.0),
      g1_hat: Array::make(data.n_obs(), 0.0),
      m_hat: Array::make(data.n_obs(), 0.0),
      r0_hat: Array::make(data.n_obs(), 0.0),
      r1_hat: Array::make(data.n_obs(), 0.0),
      coef: 0.0,
      se: 0.0,
      fitted: false,
      psi_a: Array::make(data.n_obs(), 0.0),
      psi_b: Array::make(data.n_obs(), 0.0),
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      // v0.82.0+: default memoize off so v0.81.0 callers see
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
pub fn DoubleMLIIVM::n_obs(self : DoubleMLIIVM) -> Int {
  self.data.n_obs()
}

///|
pub fn DoubleMLIIVM::coef(self : DoubleMLIIVM) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLIIVM::se(self : DoubleMLIIVM) -> Double {
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
pub fn DoubleMLIIVM::confint(
  self : DoubleMLIIVM,
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
pub fn DoubleMLIIVM::predictions_g0(self : DoubleMLIIVM) -> Array[Double] {
  self.g0_hat
}

///|
pub fn DoubleMLIIVM::predictions_g1(self : DoubleMLIIVM) -> Array[Double] {
  self.g1_hat
}

///|
pub fn DoubleMLIIVM::predictions_m(self : DoubleMLIIVM) -> Array[Double] {
  self.m_hat
}

///|
pub fn DoubleMLIIVM::predictions_r0(self : DoubleMLIIVM) -> Array[Double] {
  self.r0_hat
}

///|
pub fn DoubleMLIIVM::predictions_r1(self : DoubleMLIIVM) -> Array[Double] {
  self.r1_hat
}

///|
/// v0.82.0+: turn on memoization for subsequent `fit()` calls.
/// When enabled, `fit()` will cache the per-observation
/// nuisance predictions (`g0_hat`, `g1_hat`, `m_hat`, `r0_hat`,
/// `r1_hat`) and the fold partition and skip the cross-fit on
/// a repeat call whose data + learner fingerprint is unchanged.
/// Returns a new `DoubleMLIIVM` with the flag set (the struct
/// is immutable; the cache itself is populated by the next
/// `fit()` call).
pub fn DoubleMLIIVM::enable_memoize(self : DoubleMLIIVM) -> DoubleMLIIVM {
  { ..self, memoize_enabled: true, }
}

///|
/// v0.82.0+: turn off memoization. Same immutability contract
/// as `enable_memoize()`. After this, `fit()` will not read or
/// write the cache; the existing `fit_cache` is preserved on
/// the returned struct (call `clear_cache()` to drop it).
pub fn DoubleMLIIVM::disable_memoize(self : DoubleMLIIVM) -> DoubleMLIIVM {
  { ..self, memoize_enabled: false, }
}

///|
/// v0.82.0+: drop any cached nuisance predictions and fold
/// assignment.
pub fn DoubleMLIIVM::clear_cache(self : DoubleMLIIVM) -> DoubleMLIIVM {
  { ..self, fit_cache: FitCache::empty(), }
}

///|
/// v0.82.0+: `true` iff `fit_cache` holds at least one cached
/// observation.
pub fn DoubleMLIIVM::has_cache(self : DoubleMLIIVM) -> Bool {
  !self.fit_cache.is_empty()
}

///|
/// Filter `idx` to keep only entries `i` for which `cond[i]` matches
/// the desired value `target`. Used to build the conditional sample
/// splits for `g0/g1/r0/r1`.
pub fn filter_by_value(
  idx : Array[Int],
  cond : Array[Double],
  target : Double,
) -> Array[Int] {
  let out : Array[Int] = []
  for i in idx {
    if cond[i] == target {
      out.push(i)
    }
  }
  out
}

///|
/// Cross-fit the five nuisance functions of the IIVM model. For each
/// fold we train:
///
///   - `ml_g` on `(x[train_z0], y[train_z0])` -> `g0`, predict on
///     `x[test]`
///   - `ml_g` on `(x[train_z1], y[train_z1])` -> `g1`, predict on
///     `x[test]`
///   - `ml_m` on `(x[train], z[train])` -> `m`, predict on `x[test]`,
///     clipped to `[eps, 1 - eps]`
///   - `ml_r` on `(x[train_z0], d[train_z0])` -> `r0`, predict on
///     `x[test]`
///   - `ml_r` on `(x[train_z1], d[train_z1])` -> `r1`, predict on
///     `x[test]`
///
/// Returns `(g0, g1, m, r0, r1)`, each of length `n_obs`. If a
/// conditional training subset is empty (extreme Z imbalance falls
/// into one half of a 2-fold split), the call aborts via
/// `require(...)` rather than silently writing zero predictions —
/// silently-zero nuisance predictions would corrupt the LATE score.
fn cross_fit_iivm(
  ml_g : LearnerDispatch,
  ml_m : LearnerDispatch,
  ml_r : LearnerDispatch,
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  z : Array[Double],
  folds : Array[Fold],
  propensity_clip : Double,
) -> (Array[Double], Array[Double], Array[Double], Array[Double], Array[Double]) {
  try {
    let n_obs = x.rows()
    let g0 = Array::make(n_obs, 0.0)
    let g1 = Array::make(n_obs, 0.0)
    let m = Array::make(n_obs, 0.0)
    let r0 = Array::make(n_obs, 0.0)
    let r1 = Array::make(n_obs, 0.0)
    for fold in folds {
      let train_idx = fold.train_indices()
      let test_idx = fold.test_indices()
      let train_z0 = filter_by_value(train_idx, z, 0.0)
      let train_z1 = filter_by_value(train_idx, z, 1.0)
      require(train_z0.length() > 0)
      require(train_z1.length() > 0)
      // g0: train on z == 0 subset
      let p0 = cross_fit_predict_dispatch(ml_g, x, y, [
        Fold::new(train_z0, test_idx),
      ])
      for k = 0; k < test_idx.length(); k = k + 1 {
        let row = test_idx[k]
        g0[row] = p0[row]
      }
      // g1: train on z == 1 subset
      let p1 = cross_fit_predict_dispatch(ml_g, x, y, [
        Fold::new(train_z1, test_idx),
      ])
      for k = 0; k < test_idx.length(); k = k + 1 {
        let row = test_idx[k]
        g1[row] = p1[row]
      }
      // m: train on all rows (instrument as y)
      let pm = cross_fit_predict_dispatch(ml_m, x, z, [
        Fold::new(train_idx, test_idx),
      ])
      for k = 0; k < test_idx.length(); k = k + 1 {
        let row = test_idx[k]
        m[row] = pm[row]
      }
      // r0: train on z == 0 subset (treatment as y)
      let pr0 = cross_fit_predict_dispatch(ml_r, x, d, [
        Fold::new(train_z0, test_idx),
      ])
      for k = 0; k < test_idx.length(); k = k + 1 {
        let row = test_idx[k]
        r0[row] = pr0[row]
      }
      // r1: train on z == 1 subset (treatment as y)
      let pr1 = cross_fit_predict_dispatch(ml_r, x, d, [
        Fold::new(train_z1, test_idx),
      ])
      for k = 0; k < test_idx.length(); k = k + 1 {
        let row = test_idx[k]
        r1[row] = pr1[row]
      }
    }
    let m_clipped = clip_vec(m, propensity_clip, 1.0 - propensity_clip)
    (g0, g1, m_clipped, r0, r1)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Run the IIVM estimation.
///
/// Per-repetition behaviour: each repetition `r` cross-fits the
/// `g0 / g1 / m / r0 / r1` nuisances from its own folds (seed
/// `self.seed + r`), computes its own `(theta_r, se_r)` from the
/// LATE score, and the two arrays are then aggregated by
/// `aggregate_coef_se` (median of thetas, then SE from the median of
/// `(theta_r + 1.96 * se_r)`). For `n_rep == 1` the aggregator
/// returns the single `(theta_1, se_1)` exactly, so the byte-equality
/// with the previous "average then estimate" implementation is
/// preserved. The `predictions_g0 / g1 / m / r0 / r1` accessors
/// return the nuisances from the *last* repetition (the conventional
/// choice in upstream `doubleml`), not a cross-rep average.
pub fn DoubleMLIIVM::fit(
  self : DoubleMLIIVM,
  ml_g? : LearnerDispatch = self.ml_g,
  ml_m? : LearnerDispatch = self.ml_m,
  ml_r? : LearnerDispatch = self.ml_r,
  max_attempts? : Int = 1,
) -> DoubleMLIIVM {
  try {
    require(max_attempts >= 1)
    if self.data.is_cluster_data() {
      return self.fit_cluster(ml_g~, ml_m~, ml_r~, max_attempts~)
    }
    ignore(ml_g)
    ignore(ml_m)
    ignore(ml_r)
    let n = self.n_obs()
    let nrep = self.n_rep
    // v0.82.0+: memoize check. Mirrors the IRM plumbing.
    let memoize = self.memoize_enabled && nrep == 1
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
      hash_hyperparams("iivm", ml_g, ml_m, self.propensity_clip)
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
        nrep,
        n,
        data_hash,
        hparams_hash,
        cluster_hash,
        "iivm",
      )
    let coefs : Array[Double] = Array::make(nrep, 0.0)
    let ses : Array[Double] = Array::make(nrep, 0.0)
    // hold the last rep's predictions; final values land in *_hat fields
    let mut g0 : Array[Double] = Array::make(n, 0.0)
    let mut g1 : Array[Double] = Array::make(n, 0.0)
    let mut m : Array[Double] = Array::make(n, 0.0)
    let mut r0 : Array[Double] = Array::make(n, 0.0)
    let mut r1 : Array[Double] = Array::make(n, 0.0)
    let mut fold_ids : Array[Int] = []
    for r = 0; r < nrep; r = r + 1 {
      let (g0_r, g1_r, m_r, r0_r, r1_r) = if cache_hit && r == nrep - 1 {
        // Reuse the cached LAST-rep predictions.
        let preds = self.fit_cache.predictions
        fold_ids = self.fit_cache.fold_ids
        (preds[0], preds[1], preds[2], preds[3], preds[4])
      } else {
        let folds = kfold(n, self.n_folds, self.seed + r)
        let cross = cross_fit_iivm(
          ml_g,
          ml_m,
          ml_r,
          self.data.x,
          self.data.y,
          self.data.d,
          self.data.z,
          folds,
          self.propensity_clip,
        )
        if r == nrep - 1 {
          // Build the row -> fold_id map for the cache write below.
          let fid : Array[Int] = Array::make(n, 0)
          for f = 0; f < folds.length(); f = f + 1 {
            for i in folds[f].test_indices() {
              fid[i] = f
            }
          }
          fold_ids = fid
        }
        cross
      }
      g0 = g0_r
      g1 = g1_r
      m = m_r
      r0 = r0_r
      r1 = r1_r
      // LATE score for THIS rep's nuisances only.
      // v0.82.0+: per-observation residuals extracted via
      // `vector_subtract` (the IIVM LATE score needs
      // `u0 = y - g0`, `u1 = y - g1`, `w0 = d - r0`, `w1 = d - r1`,
      // all pure element-wise subtracts, the textbook case for
      // the named building block).
      let y = self.data.y
      let d = self.data.d
      let z = self.data.z
      let u0 = vector_subtract(y, g0)
      let u1 = vector_subtract(y, g1)
      let w0 = vector_subtract(d, r0)
      let w1 = vector_subtract(d, r1)
      let psi_a : Array[Double] = Array::make(n, 0.0)
      let psi_b : Array[Double] = Array::make(n, 0.0)
      for i = 0; i < n; i = i + 1 {
        let m_i = m[i]
        let one_minus_m = 1.0 - m_i
        psi_b[i] = g1[i] -
          g0[i] +
          z[i] * u1[i] / m_i -
          (1.0 - z[i]) * u0[i] / one_minus_m
        psi_a[i] = -(r1[i] - r0[i]) -
          z[i] * w1[i] / m_i +
          (1.0 - z[i]) * w0[i] / one_minus_m
      }
      let (coef_r, se_r) = var_est(psi_a, psi_b)
      coefs[r] = coef_r
      ses[r] = se_r
    }
    // last iteration's predictions are now in g0 / g1 / m / r0 / r1
    let (coef, se) = aggregate_coef_se(coefs, ses)
    // v0.61.0: per-observation influence function for the
    // multiplier bootstrap. Recompute `psi_a / psi_b` (LATE
    // score) from the last rep's nuisances so the stored
    // arrays align with `g0_hat` / `g1_hat` / `m_hat` /
    // `r0_hat` / `r1_hat` and `coef` (matches the v0.20.0+
    // DID convention). v0.82.0+: residuals via
    // `vector_subtract` (same vectorised pattern as the
    // per-rep score loop above).
    let psi_a : Array[Double] = Array::make(n, 0.0)
    let psi_b : Array[Double] = Array::make(n, 0.0)
    let y_last = self.data.y
    let d_last = self.data.d
    let z_last = self.data.z
    let u0 = vector_subtract(y_last, g0)
    let u1 = vector_subtract(y_last, g1)
    let w0 = vector_subtract(d_last, r0)
    let w1 = vector_subtract(d_last, r1)
    for i = 0; i < n; i = i + 1 {
      let m_i = m[i]
      let one_minus_m = 1.0 - m_i
      psi_b[i] = g1[i] -
        g0[i] +
        z_last[i] * u1[i] / m_i -
        (1.0 - z_last[i]) * u0[i] / one_minus_m
      psi_a[i] = -(r1[i] - r0[i]) -
        z_last[i] * w1[i] / m_i +
        (1.0 - z_last[i]) * w0[i] / one_minus_m
    }
    // v0.82.0+: write to cache when memoize is on and the
    // cache missed. Predictions are stored as
    // `[g0, g1, m, r0, r1]` (5 arrays).
    let next_cache = if memoize && !cache_hit && nrep == 1 {
      FitCache::from_fit(
        fold_ids,
        [g0, g1, m, r0, r1],
        self.seed,
        self.n_folds,
        nrep,
        n,
        data_hash,
        hparams_hash,
        cluster_hash,
        "iivm",
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
      ml_g,
      ml_m,
      ml_r,
      g0_hat: g0,
      g1_hat: g1,
      m_hat: m,
      r0_hat: r0,
      r1_hat: r1,
      coef,
      se,
      fitted: true,
      psi_a,
      psi_b,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      // v0.82.0+: persist the memoize flag and (possibly
      // updated) cache.
      memoize_enabled: self.memoize_enabled,
      fit_cache: next_cache,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Clustered-DML path for `DoubleMLIIVM`. Same shape as the
/// other `fit_cluster` helpers: folds are drawn over the
/// unique unit ids, expanded to row folds via
/// `expand_unit_folds_to_rows`; all five nuisances
/// (`g0`, `g1`, `m`, `r0`, `r1`) are cross-fitted with
/// cluster-respecting folds; the LATE coefficient is the
/// fold-weighted ratio of cluster score sums
/// (`est_coef_cluster`); the SE is unit-level cluster-robust
/// (`var_est_cluster`). The per-row score elements are the
/// same as the row-level path
/// (`psi_a = -(r1 - r0) - z w1/m + (1 - z) w0/(1 - m)`,
/// `psi_b = g1 - g0 + z u1/m - (1 - z) u0/(1 - m)`).
fn DoubleMLIIVM::fit_cluster(
  self : DoubleMLIIVM,
  ml_g~ : LearnerDispatch,
  ml_m~ : LearnerDispatch,
  ml_r~ : LearnerDispatch,
  max_attempts? : Int = 1,
) -> DoubleMLIIVM {
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
    let mut r0 : Array[Double] = Array::make(n, 0.0)
    let mut r1 : Array[Double] = Array::make(n, 0.0)
    for r = 0; r < nrep; r = r + 1 {
      // v0.40.0: retry loop on J-floor (see plr.mbt::fit_cluster).
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
        let (g0_r, g1_r, m_r, r0_r, r1_r) = cross_fit_iivm(
          ml_g,
          ml_m,
          ml_r,
          self.data.x,
          self.data.y,
          self.data.d,
          self.data.z,
          folds_row,
          self.propensity_clip,
        )
        g0 = g0_r
        g1 = g1_r
        m = m_r
        r0 = r0_r
        r1 = r1_r
        let y = self.data.y
        let d = self.data.d
        let z = self.data.z
        // v0.82.0+: residuals extracted via `vector_subtract`
        // (same vectorised pattern as the IID IIVM `fit()`
        // body above).
        let u0 = vector_subtract(y, g0)
        let u1 = vector_subtract(y, g1)
        let w0 = vector_subtract(d, r0)
        let w1 = vector_subtract(d, r1)
        let psi_a : Array[Double] = Array::make(n, 0.0)
        let psi_b : Array[Double] = Array::make(n, 0.0)
        for i = 0; i < n; i = i + 1 {
          let m_i = m[i]
          let one_minus_m = 1.0 - m_i
          psi_b[i] = g1[i] -
            g0[i] +
            z[i] * u1[i] / m_i -
            (1.0 - z[i]) * u0[i] / one_minus_m
          psi_a[i] = -(r1[i] - r0[i]) -
            z[i] * w1[i] / m_i +
            (1.0 - z[i]) * w0[i] / one_minus_m
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
    // recompute from the last rep's nuisances so the stored
    // arrays align with `g0_hat` / `g1_hat` / `m_hat` /
    // `r0_hat` / `r1_hat` and `coef`. v0.82.0+: residuals
    // via `vector_subtract` (matches the IID `fit()` body).
    let psi_a : Array[Double] = Array::make(n, 0.0)
    let psi_b : Array[Double] = Array::make(n, 0.0)
    let u0 = vector_subtract(self.data.y, g0)
    let u1 = vector_subtract(self.data.y, g1)
    let w0 = vector_subtract(self.data.d, r0)
    let w1 = vector_subtract(self.data.d, r1)
    for i = 0; i < n; i = i + 1 {
      let m_i = m[i]
      let one_minus_m = 1.0 - m_i
      psi_b[i] = g1[i] -
        g0[i] +
        self.data.z[i] * u1[i] / m_i -
        (1.0 - self.data.z[i]) * u0[i] / one_minus_m
      psi_a[i] = -(r1[i] - r0[i]) -
        self.data.z[i] * w1[i] / m_i +
        (1.0 - self.data.z[i]) * w0[i] / one_minus_m
    }
    {
      data: self.data,
      n_folds: self.n_folds,
      n_rep: self.n_rep,
      seed: self.seed,
      propensity_clip: self.propensity_clip,
      ml_g,
      ml_m,
      ml_r,
      g0_hat: g0,
      g1_hat: g1,
      m_hat: m,
      r0_hat: r0,
      r1_hat: r1,
      coef,
      se,
      fitted: true,
      psi_a,
      psi_b,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      // v0.82.0+: cluster path does not currently consume
      // the memoization cache (the J-floor retry loop can
      // rewrite the fold assignment on a per-attempt basis).
      // Persist the flags so a subsequent non-cluster
      // `fit()` still honors memoize.
      memoize_enabled: self.memoize_enabled,
      fit_cache: self.fit_cache,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.61.0+: multiplier bootstrap for `DoubleMLIIVM`. The
/// per-observation influence function is
///
///   psi[i] = theta * psi_a[i] + psi_b[i]
///
/// where `psi_a` and `psi_b` are the LATE score elements
/// (defined in the module doc) computed at the fitted `coef`
/// from the last rep's cross-fitted nuisances `g0_hat` /
/// `g1_hat` / `m_hat` / `r0_hat` / `r1_hat`. Draws
/// `n_rep_boot` weight vectors of length `n_obs` from the
/// chosen multiplier distribution, and returns a fitted model
/// with `boot_t_stat[b] = sum_i w[b, i] * psi[i] /
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
/// `DoubleMLDIDCrossSection::bootstrap`); IIVM is the
/// `n_thetas=1` case.
pub fn DoubleMLIIVM::bootstrap(
  self : DoubleMLIIVM,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLIIVM {
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
          "draw_bootstrap_weights: unknown method (set in DoubleMLIIVM::bootstrap): " +
          m,
        )
    }
    // Compute psi = psi_at(coef, psi_a, psi_b) and
    // ss_psi = sum(psi[i]^2) once. Both `psi_a` and `psi_b`
    // were populated by `fit(...)` from the last rep's
    // nuisances.
    let psi = psi_at(self.coef, self.psi_a, self.psi_b)
    let mut ss_psi = 0.0
    for i = 0; i < n; i = i + 1 {
      let psi_i = psi[i]
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
/// MSE-on-l_hat scoring convention). `ml_r` (the instrument
/// propensity) is held fixed at `self.ml_r` for both the tune
/// stage and the re-fit. The chosen `(learner_g, learner_m)`
/// is then re-fit on the FINAL-FIT fold partition
/// (`self.n_folds`) under `DoubleMLIIVM::fit`. Cluster-DML
/// is not supported in tune.
///
/// `param_set` is an `Array[TuneParam]`; each entry is a
/// `(learner_g, learner_m)` pair. `scoring_method` is
/// `"MSE"` (default), `"RMSE"`, or `"NegMSE"`. Returns a
/// re-fitted `DoubleMLIIVM` with the chosen pair applied.
pub fn DoubleMLIIVM::tune(
  self : DoubleMLIIVM,
  param_set~ : Array[TuneParam],
  scoring_method? : String = "MSE",
  n_folds_tune? : Int = 5,
  seed? : Int = 3141,
) -> DoubleMLIIVM {
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
    self.fit(
      ml_g=best_param.learner_l,
      ml_m=best_param.learner_m,
      ml_r=self.ml_r,
    )
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.66.0+: Cinelli & Hazlett (2020) omitted-variable bias
/// analysis. Outcome residual is
/// `y - g0_hat - (g1_hat - g0_hat) * d`; the
/// Riesz-representer variance is `mean(psi_a^2)` where
/// `psi_a = -(r1 - r0) - Z * w1/m + (1-Z) * w0/(1-m)` for
/// the LATE score. Routes through the shared
/// `irm_style_sensitivity` helper.
pub fn DoubleMLIIVM::sensitivity_analysis(
  self : DoubleMLIIVM,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let g0 = self.predictions_g0()
  let g1 = self.predictions_g1()
  let d = self.data.d
  let n = g0.length()
  let residuals : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    residuals[i] = self.data.y[i] - g0[i] - (g1[i] - g0[i]) * d[i]
  }
  irm_style_sensitivity(self.coef, residuals, self.psi_a, cf_y, cf_d)
}

///|
/// v0.72.0+: cluster-robust analogue of
/// `DoubleMLIIVM::sensitivity_analysis`. Same DID-style
/// residual form (`y - g0 - (g1 - g0) * d`) and the same
/// `psi_a = -(r1 - r0) - Z * w1/m + (1 - Z) * w0/(1 - m)`
/// (LATE score) as the IID path; only the variance / bias
/// computation is cluster-aware. `cluster_ids` defaults to
/// `DoubleMLIIVMData::cluster_vars`.
pub fn DoubleMLIIVM::sensitivity_analysis_cluster(
  self : DoubleMLIIVM,
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
  let residuals : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    residuals[i] = self.data.y[i] - g0[i] - (g1[i] - g0[i]) * d[i]
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
/// v0.86.0+: Huber-White sandwich standard error for the
/// fitted IIVM. Returns `sqrt(var)` where `var` comes from
/// the shared `sandwich_variance(kind, ...)` dispatch in
/// `sandwich.mbt` (HC0 / HC1 / HC2 / HC3).
///
/// The three inputs are the ones `fit(...)` already persists
/// for the multiplier bootstrap (see the `psi_a` / `psi_b`
/// field docs on `DoubleMLIIVM`):
///   - `psi_a`  = `self.psi_a` -- the IIVM LATE
///     residualized-treatment score
///     (`-(r1 - r0) - Z * w1 / m + (1 - Z) * w0 / (1 - m)`).
///   - `psi`    = `psi_at(self.coef, self.psi_a, self.psi_b)`
///     -- the per-observation influence function evaluated at
///     the fitted `coef`, where `psi_b` is the
///     residualized-outcome score
///     (`(g1 - g0) + Z * u1 / m - (1 - Z) * u0 / (1 - m)`).
///     Same `psi_at` score order as IRM / PLR.
///   - `M_inv`  = `[[1 / mean(psi_a)]]` (1x1). Only
///     `M_inv[0, 0]^2` enters the variance, so the sign of
///     the (up-to-sign) Jacobian inverse is irrelevant.
///
/// Preconditions: `self.fitted`, `mean(psi_a) != 0`.
pub fn DoubleMLIIVM::sandwich_se(
  self : DoubleMLIIVM,
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
/// fitted IIVM. Routes through `cluster_sandwich_variance`
/// with the same `psi_a` / `psi` / `M_inv` inputs as the IID
/// `sandwich_se` path.
///
/// Preconditions: `self.fitted`,
/// `cluster_ids.length() == n_obs`.
pub fn DoubleMLIIVM::cluster_sandwich_se(
  self : DoubleMLIIVM,
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
/// v0.91.0+: returns `coef` UNCHANGED -- a documented
/// no-op, not a bias correction.
///
/// `coef` is the root of the DML moment
/// `f(theta) = E[theta * psi_a + psi_b]` (see
/// `var_est.mbt`), so `mean(f(coef))` is identically
/// zero: the estimating function is orthogonal by
/// construction, and that orthogonality IS what makes
/// the estimator consistent. Nothing computable from
/// the fitted scores is a bias estimate for this class
/// of estimator, so this accessor reports the
/// uncorrected point estimate rather than a number
/// that merely looks like a correction.
///
///
/// v0.79.0 - v0.90.0 returned
/// `coef + mean(psi_b - coef * psi_a)`. That
/// vector is the score at `-coef`, NOT at `coef`;
/// since `coef = -mean_b / mean_a` its mean is
/// `mean_b - coef * mean_a = -2 * coef * mean_a`,
/// so the accessor returned
/// `coef * (1 - 2 * mean(psi_a))` (exactly `3 * coef`
/// when `mean(psi_a) = -1`). That is not a bias
/// estimate. See `bias_corrected_theta` in
/// `sandwich.mbt` for the algebra. The method is kept
/// so the API surface stays stable; removing it
/// outright is the obvious follow-up.
///
/// Preconditions: `self.fitted`.
pub fn DoubleMLIIVM::bias_corrected_coef(self : DoubleMLIIVM) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
