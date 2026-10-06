///|
/// Data container for `DoubleMLPLIV`. In addition to the covariates
/// `x`, the outcome `y` and the treatment `d`, PLIV needs an
/// instrumental variable `z`. The port supports a *single*
/// instrument (1-D array) — the multi-instrument case is not
/// implemented.
pub struct DoubleMLPLIVData {
  x : Matrix
  y : Array[Double]
  d : Array[Double]
  z : Array[Double]
  cluster_vars : Array[Int]
} derive(Debug)

///|
pub extend DoubleMLPLIVData with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Build a `DoubleMLPLIVData` from an `n x p` feature matrix, an
/// outcome vector of length `n`, a treatment vector of length `n`
/// and an instrument vector of length `n`.
pub fn DoubleMLPLIVData::new(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  z : Array[Double],
  cluster_vars? : Array[Int] = [],
) -> DoubleMLPLIVData {
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
/// Number of observations.
pub fn DoubleMLPLIVData::n_obs(self : DoubleMLPLIVData) -> Int {
  self.x.rows()
}

///|
/// Number of features.
pub fn DoubleMLPLIVData::n_features(self : DoubleMLPLIVData) -> Int {
  self.x.cols()
}

///|
/// True iff the data is set up for clustered inference (a
/// non-empty cluster_vars vector was passed to DoubleMLPLIVData::new).
pub fn DoubleMLPLIVData::is_cluster_data(self : DoubleMLPLIVData) -> Bool {
  self.cluster_vars.length() > 0
}

///|
/// Length of the cluster_vars vector (0 when not clustered).
pub fn DoubleMLPLIVData::n_cluster_vars(self : DoubleMLPLIVData) -> Int {
  self.cluster_vars.length()
}

///|
/// Double / debiased machine learning estimator for the *partially
/// linear IV regression model* (PLIV) of Chernozhukov et al. (2018) with
/// the *partialling out* score:
///
///     Y = D * theta_0 + g_0(X) + zeta,    E[zeta | D, X] = 0
///     D = m_0(X) + V,                     E[V | X] = 0
///     Z = ell_0(X) + xi,                  E[xi | X] = 0,
///                                       Cov(Z, V) != 0  (relevance)
///
/// with the *partialling out* (single-instrument) score
///
///     l_hat = E_hat[Y | X]
///     r_hat = E_hat[D | X]
///     m_hat = E_hat[Z | X]
///     u_hat = Y - l_hat
///     w_hat = D - r_hat
///     v_hat = Z - m_hat
///     psi_a = -w_hat * v_hat
///     psi_b =  v_hat * u_hat
///     psi(theta) = theta * psi_a + psi_b
///
/// with point estimate and variance
///
///     theta_hat = -mean(psi_b) / mean(psi_a)
///               = mean(v_hat * u_hat) / mean(w_hat * v_hat)
///     J         = mean(psi_a)
///     gamma     = mean(psi(theta_hat)^2)
///     sigma2    = gamma / (J^2 * n)
///     se        = sqrt(sigma2).
///
/// The port supports only a *single* instrument and the *partialling
/// out* score (the `IV-type` score, which would need an additional
/// `ml_g` learner, is not implemented). All three nuisance functions
/// are estimated with the same closed-form `LinearRegression` learner.
pub struct DoubleMLPLIV {
  data : DoubleMLPLIVData
  n_folds : Int
  n_rep : Int
  seed : Int
  // v0.109.0+: caller-supplied sample splitting; `[]` means "draw my
  // own". When non-empty, `fit` uses `smpls[r]` for repetition `r`
  // INSTEAD of calling `kfold`, and the repetition count comes from
  // the supplied partition's length rather than from the configured
  // `n_rep`. Set it through `DoubleMLPLIV::set_sample_splitting`,
  // which validates the partition and derives both counts -- do not
  // build it by hand.
  smpls : Array[Array[Fold]]
  // v0.59.0+: injected nuisance learner (replaces the v0.57.0
  // hardcoded `LinearRegression`). Defaults to OLS so v0.57.0
  // callers see byte-identical results.
  learner : LearnerDispatch
  l_hat : Array[Double]
  r_hat : Array[Double]
  m_hat : Array[Double]
  coef : Double
  se : Double
  fitted : Bool
  // v0.61.0+: per-observation influence function components
  // for the multiplier bootstrap. PLIV partialling-out score:
  //   psi_a[i] = -w_hat[i] * v_hat[i]
  //   psi_b[i] =  v_hat[i] * u_hat[i]
  // where `w_hat = d - r_hat`, `v_hat = z - m_hat`,
  // `u_hat = y - l_hat`. Length `n_obs`. Populated by
  // `fit(...)` from the last rep's nuisances.
  psi_a : Array[Double]
  psi_b : Array[Double]
  // v0.61.0+: multiplier bootstrap state. `boot_t_stat` is a
  // length-`n_rep_boot` array of t-statistics for `coef`.
  // Populated by `bootstrap(...)`; empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
  // v0.82.0+: memoization state. Mirrors the IRM / PLR / IIVM
  // plumbing. `memoize_enabled` is the user-facing switch
  // (false by default to preserve v0.81.0 behavior bit-for-bit).
  memoize_enabled : Bool
  fit_cache : FitCache
} derive(Debug)

///|
pub extend DoubleMLPLIV with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLPLIV::new(
  data : DoubleMLPLIVData,
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  learner? : LearnerDispatch = LearnerDispatch::linear_regression(),
) -> DoubleMLPLIV {
  try {
    require(n_folds >= 2)
    require(n_folds <= data.n_obs())
    require(n_rep >= 1)
    {
      data,
      n_folds,
      n_rep,
      seed,
      // v0.109.0: no external splitting unless
      // `set_sample_splitting` is called, so every pre-existing caller
      // keeps the drawn path.
      smpls: [],
      learner,
      l_hat: Array::make(data.n_obs(), 0.0),
      r_hat: Array::make(data.n_obs(), 0.0),
      m_hat: Array::make(data.n_obs(), 0.0),
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
pub fn DoubleMLPLIV::n_obs(self : DoubleMLPLIV) -> Int {
  self.data.n_obs()
}

///|
pub fn DoubleMLPLIV::coef(self : DoubleMLPLIV) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLPLIV::se(self : DoubleMLPLIV) -> Double {
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
pub fn DoubleMLPLIV::confint(
  self : DoubleMLPLIV,
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
pub fn DoubleMLPLIV::predictions_l(self : DoubleMLPLIV) -> Array[Double] {
  self.l_hat
}

///|
/// v0.82.0+: turn on memoization for subsequent `fit()` calls.
/// Returns a new `DoubleMLPLIV` with the flag set (the struct
/// is immutable; the cache itself is populated by the next
/// `fit()` call).
pub fn DoubleMLPLIV::enable_memoize(self : DoubleMLPLIV) -> DoubleMLPLIV {
  { ..self, memoize_enabled: true, }
}

///|
/// v0.82.0+: turn off memoization.
pub fn DoubleMLPLIV::disable_memoize(self : DoubleMLPLIV) -> DoubleMLPLIV {
  { ..self, memoize_enabled: false, }
}

///|
/// v0.82.0+: drop any cached nuisance predictions and fold
/// assignment.
pub fn DoubleMLPLIV::clear_cache(self : DoubleMLPLIV) -> DoubleMLPLIV {
  { ..self, fit_cache: FitCache::empty(), }
}

///|
/// v0.82.0+: `true` iff `fit_cache` holds at least one cached
/// observation.
pub fn DoubleMLPLIV::has_cache(self : DoubleMLPLIV) -> Bool {
  !self.fit_cache.is_empty()
}

///|
pub fn DoubleMLPLIV::predictions_r(self : DoubleMLPLIV) -> Array[Double] {
  self.r_hat
}

///|
pub fn DoubleMLPLIV::predictions_m(self : DoubleMLPLIV) -> Array[Double] {
  self.m_hat
}

///|
/// Run the PLIV estimation. The default learner is a closed-form
/// `LinearRegression`; a different `Learner` can be supplied for
/// experiments. The result is stored on the object and the object is
/// returned for chaining.
///
/// Per-repetition behaviour: each repetition `r` cross-fits the
/// `l / r / m` nuisances from its own folds (seed `self.seed + r`),
/// computes its own `(theta_r, se_r)` from the partialling-out
/// single-instrument score, and the two arrays are then aggregated
/// by `aggregate_coef_se` (median of thetas, then SE from the median
/// of `(theta_r + 1.96 * se_r)`). For `n_rep == 1` the aggregator
/// returns the single `(theta_1, se_1)` exactly, so the byte-equality
/// with the previous "average then estimate" implementation is
/// preserved. The `predictions_l / r / m` accessors return the
/// nuisances from the *last* repetition (the conventional choice in
/// upstream `doubleml`), not a cross-rep average.
pub fn DoubleMLPLIV::fit(
  self : DoubleMLPLIV,
  learner? : LearnerDispatch = LearnerDispatch::linear_regression(),
  max_attempts? : Int = 1,
) -> DoubleMLPLIV {
  try {
    require(max_attempts >= 1)
    if self.data.is_cluster_data() {
      return self.fit_cluster(learner~, max_attempts~)
    }
    let n = self.n_obs()
    // v0.109.0: true when the caller supplied the split through
    // `set_sample_splitting`. It gates the two places where behaviour
    // genuinely differs -- the memoize decision and the fold draw --
    // but NOT the repetition count, which the derivation already wrote
    // into `self.n_rep`.
    let external = self.smpls.length() > 0
    // v0.109.0: `set_sample_splitting` writes the DERIVED counts into
    // `self.n_folds` / `self.n_rep`, so reading `self.n_rep` here is
    // already reading the derived value and needs no `if external`
    // override. An `if external` override here was measured to be an
    // EQUIVALENT mutant and deleted on the PLR side; defensive code
    // that no mutation can fail is a ratchet, not a safeguard.
    let nrep = self.n_rep
    // v0.82.0+: memoize check. Mirrors the IRM / PLR / IIVM
    // plumbing.
    //
    // v0.109.0: external splits are EXCLUDED from the cache. The key
    // is built from data + learner + cluster hashes and has no term
    // for the fold assignment, so two different supplied partitions
    // would collide and the second fit would silently return the
    // first one's predictions. Rather than extend the key (a change to
    // FitCache that every memoizing estimator would have to adopt at
    // once), the external path turns memoize off. That can only cost
    // time; reusing a stale split cannot be made safe by ignoring it.
    let memoize = self.memoize_enabled && nrep == 1 && !external
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
      hash_hyperparams("pliv", learner, learner, 0.0)
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
        "pliv",
      )
    let coefs : Array[Double] = Array::make(nrep, 0.0)
    let ses : Array[Double] = Array::make(nrep, 0.0)
    // hold the last rep's predictions; final values land in l_hat / r_hat / m_hat
    let mut l_pred : Array[Double] = Array::make(n, 0.0)
    let mut r_pred : Array[Double] = Array::make(n, 0.0)
    let mut m_pred : Array[Double] = Array::make(n, 0.0)
    let mut fold_ids : Array[Int] = []
    for r = 0; r < nrep; r = r + 1 {
      let (l_pred_r, r_pred_r, m_pred_r) = if cache_hit && r == nrep - 1 {
        // Reuse the cached LAST-rep predictions.
        let preds = self.fit_cache.predictions
        fold_ids = self.fit_cache.fold_ids
        (preds[0], preds[1], preds[2])
      } else {
        // v0.109.0: the external splitting wins over the drawn one.
        // `check_sample_splitting` already proved `self.smpls[r]` is a
        // partition of `[0, n)`, so no re-validation here.
        let folds = if external {
          self.smpls[r]
        } else {
          kfold(n, self.n_folds, self.seed + r)
        }
        let l_p = cross_fit_predict_dispatch(
          learner,
          self.data.x,
          self.data.y,
          folds,
        )
        let r_p = cross_fit_predict_dispatch(
          learner,
          self.data.x,
          self.data.d,
          folds,
        )
        let m_p = cross_fit_predict_dispatch(
          learner,
          self.data.x,
          self.data.z,
          folds,
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
        (l_p, r_p, m_p)
      }
      l_pred = l_pred_r
      r_pred = r_pred_r
      m_pred = m_pred_r
      // Score (partialling out, single instrument) for THIS rep's
      // nuisances only. v0.82.0+: per-observation residuals
      // extracted via `vector_subtract` (u = y - l_pred, w = d -
      // r_pred, v = z - m_pred -- all pure element-wise subtracts,
      // the textbook case for the named building block).
      let y = self.data.y
      let d = self.data.d
      let z = self.data.z
      let u = vector_subtract(y, l_pred)
      let w = vector_subtract(d, r_pred)
      let v = vector_subtract(z, m_pred)
      let psi_a : Array[Double] = Array::make(n, 0.0)
      let psi_b : Array[Double] = Array::make(n, 0.0)
      for i = 0; i < n; i = i + 1 {
        psi_a[i] = -w[i] * v[i]
        psi_b[i] = v[i] * u[i]
      }
      let (coef_r, se_r) = var_est(psi_a, psi_b)
      coefs[r] = coef_r
      ses[r] = se_r
    }
    // last iteration's predictions are now in l_pred / r_pred / m_pred
    let (coef, se) = aggregate_coef_se(coefs, ses)
    // v0.61.0: per-observation influence function for the
    // multiplier bootstrap. Recompute `psi_a / psi_b` from the
    // last rep's nuisances so the stored arrays align with
    // `l_hat` / `r_hat` / `m_hat` and `coef` (matches the
    // v0.20.0+ DID convention). v0.82.0+: residuals via
    // `vector_subtract`.
    let psi_a : Array[Double] = Array::make(n, 0.0)
    let psi_b : Array[Double] = Array::make(n, 0.0)
    let u = vector_subtract(self.data.y, l_pred)
    let w = vector_subtract(self.data.d, r_pred)
    let v = vector_subtract(self.data.z, m_pred)
    for i = 0; i < n; i = i + 1 {
      psi_a[i] = -w[i] * v[i]
      psi_b[i] = v[i] * u[i]
    }
    // v0.82.0+: write to cache when memoize is on and the
    // cache missed. Predictions are stored as
    // `[l_pred, r_pred, m_pred]` (3 arrays).
    let next_cache = if memoize && !cache_hit && nrep == 1 {
      FitCache::from_fit(
        fold_ids,
        [l_pred, r_pred, m_pred],
        self.seed,
        self.n_folds,
        nrep,
        n,
        data_hash,
        hparams_hash,
        cluster_hash,
        "pliv",
      )
    } else {
      self.fit_cache
    }
    {
      data: self.data,
      n_folds: self.n_folds,
      n_rep: self.n_rep,
      seed: self.seed,
      // v0.109.0: carry the external splitting onto the returned model
      // (both `fit` and `fit_cluster` build one) so a re-fit over a
      // model that was given explicit splits keeps using them. Dropping
      // it here would make the NEXT fit silently revert to drawing its
      // own folds -- and the estimate would still look plausible, which
      // is exactly what makes a surprise fold change easy to miss.
      smpls: self.smpls,
      // v0.59.0+: persist per-fit learner override on the struct
      learner,
      l_hat: l_pred,
      r_hat: r_pred,
      m_hat: m_pred,
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
/// Clustered-DML path for `DoubleMLPLIV`. Same shape as
/// `DoubleMLPLR::fit_cluster`: folds are drawn over the
/// unique unit ids, expanded to row folds via
/// `expand_unit_folds_to_rows`; coefficient is the
/// fold-weighted ratio of cluster score sums
/// (`est_coef_cluster`); variance is unit-level
/// cluster-robust (`var_est_cluster`). All three nuisances
/// (`l = E[Y|X]`, `r = E[D|X]`, `m = E[Z|X]`) are
/// cross-fitted with cluster-respecting folds; the per-row
/// score elements are the same as the row-level path
/// (`psi_a = -w_hat * v_hat`, `psi_b = v_hat * u_hat`).
fn DoubleMLPLIV::fit_cluster(
  self : DoubleMLPLIV,
  learner~ : LearnerDispatch,
  max_attempts? : Int = 1,
) -> DoubleMLPLIV {
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
    let mut l_pred : Array[Double] = Array::make(n, 0.0)
    let mut r_pred : Array[Double] = Array::make(n, 0.0)
    let mut m_pred : Array[Double] = Array::make(n, 0.0)
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
        l_pred = cross_fit_predict_dispatch(
          learner,
          self.data.x,
          self.data.y,
          folds_row,
        )
        r_pred = cross_fit_predict_dispatch(
          learner,
          self.data.x,
          self.data.d,
          folds_row,
        )
        m_pred = cross_fit_predict_dispatch(
          learner,
          self.data.x,
          self.data.z,
          folds_row,
        )
        let y = self.data.y
        let d = self.data.d
        let z = self.data.z
        // v0.82.0+: residuals via `vector_subtract` (same
        // vectorised pattern as the IID `fit()` body above).
        let u = vector_subtract(y, l_pred)
        let w = vector_subtract(d, r_pred)
        let v = vector_subtract(z, m_pred)
        let psi_a : Array[Double] = Array::make(n, 0.0)
        let psi_b : Array[Double] = Array::make(n, 0.0)
        for i = 0; i < n; i = i + 1 {
          psi_a[i] = -w[i] * v[i]
          psi_b[i] = v[i] * u[i]
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
    // the stored arrays align with `l_hat` / `r_hat` /
    // `m_hat` and `coef`.
    let psi_a : Array[Double] = Array::make(n, 0.0)
    let psi_b : Array[Double] = Array::make(n, 0.0)
    // v0.82.0+: residuals via `vector_subtract` (matches the
    // IID `fit()` body).
    let u = vector_subtract(self.data.y, l_pred)
    let w = vector_subtract(self.data.d, r_pred)
    let v = vector_subtract(self.data.z, m_pred)
    for i = 0; i < n; i = i + 1 {
      psi_a[i] = -w[i] * v[i]
      psi_b[i] = v[i] * u[i]
    }
    {
      data: self.data,
      n_folds: self.n_folds,
      n_rep: self.n_rep,
      seed: self.seed,
      // v0.109.0: carry the external splitting onto the cluster-path
      // return struct too, so a later non-cluster `fit` still uses the
      // supplied folds. The cluster path itself ignores them (see
      // `set_sample_splitting`); dropping the field here would make
      // the NEXT fit silently revert to drawing its own folds.
      smpls: self.smpls,
      // v0.59.0+: persist per-fit learner override on the
      // cluster-path return struct.
      learner,
      l_hat: l_pred,
      r_hat: r_pred,
      m_hat: m_pred,
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
      // the memoization cache. Persist the flags so a
      // subsequent non-cluster `fit()` still honors
      // memoize.
      memoize_enabled: self.memoize_enabled,
      fit_cache: self.fit_cache,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.61.0+: multiplier bootstrap for `DoubleMLPLIV`. The
/// per-observation influence function is
///
///   psi[i] = theta * psi_a[i] + psi_b[i]
///          = -w*v + theta * v*u
///
/// where `w = d - r_hat`, `v = z - m_hat`, `u = y - l_hat`
/// are computed at the fitted `coef` from the last rep's
/// cross-fitted nuisances `l_hat` / `r_hat` / `m_hat`.
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
/// `DoubleMLDIDCrossSection::bootstrap`); PLIV is the
/// `n_thetas=1` case.
pub fn DoubleMLPLIV::bootstrap(
  self : DoubleMLPLIV,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLPLIV {
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
          "draw_bootstrap_weights: unknown method (set in DoubleMLPLIV::bootstrap): " +
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
/// v0.65.0+: tune the single nuisance `learner` (used for all
/// three nuisances `l` / `r` / `m`) via MSE-on-l_hat
/// cross-fitting (matches `DoubleMLPLR::tune`'s
/// MSE-on-l_hat scoring convention; see tune.mbt §4.1). The
/// chosen `learner` is then re-fit on the FINAL-FIT fold
/// partition (`self.n_folds`) under `DoubleMLPLIV::fit`.
/// Cluster-DML is not supported in tune (mirrors the PLR
/// behaviour — `tune` requires `!self.data.is_cluster_data()`).
///
/// `param_set` is an `Array[LearnerDispatch]` (each entry is a
/// candidate nuisance learner; PLIV has only one nuisance slot
/// so the TuneParam wrapper is unnecessary). Returns a
/// re-fitted `DoubleMLPLIV` with the chosen learner applied
/// via the `learner` field. `scoring_method` is `"MSE"`
/// (default), `"RMSE"`, or `"NegMSE"`.
pub fn DoubleMLPLIV::tune(
  self : DoubleMLPLIV,
  param_set~ : Array[LearnerDispatch],
  scoring_method? : String = "MSE",
  n_folds_tune? : Int = 5,
  seed? : Int = 3141,
) -> DoubleMLPLIV {
  try {
    require(param_set.length() > 0)
    require(n_folds_tune >= 2)
    require(!self.data.is_cluster_data())
    let scoring = TuneScoring::parse(scoring_method)
    // v0.108.0: scoring loop + fold draw + argmin moved into
    // `tune_score_grid`. PLIV keeps its own `Array[LearnerDispatch]`
    // grid shape (it has a single nuisance slot, so a two-learner
    // `TuneParam` would be a wrapper around one value) and passes it
    // straight through - the core is keyed on the learner array, not
    // on `TuneParam`, precisely so both shapes share it.
    let grid = tune_score_grid(
      self.data.x,
      self.data.y,
      param_set,
      n_folds_tune,
      seed,
      scoring,
    )
    self.fit(learner=param_set[grid.best_index])
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.66.0+: Cinelli & Hazlett (2020) omitted-variable bias
/// analysis. Outcome residual is `y - l_hat`; the
/// Riesz-representer variance is `mean(psi_a^2)` where
/// `psi_a = -w * v` for the partialling-out IV score
/// (`w = d - r_hat`, `v = z - m_hat`). Routes through the
/// shared `irm_style_sensitivity` helper.
pub fn DoubleMLPLIV::sensitivity_analysis(
  self : DoubleMLPLIV,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let l_hat = self.predictions_l()
  let n = l_hat.length()
  let residuals : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    residuals[i] = self.data.y[i] - l_hat[i]
  }
  irm_style_sensitivity(self.coef, residuals, self.psi_a, cf_y, cf_d)
}

///|
/// v0.72.0+: cluster-robust analogue of
/// `DoubleMLPLIV::sensitivity_analysis`. Same residual
/// formula (`y - l_hat`) and the same `psi_a = -w * v`
/// (partialling-out IV score) as the IID path; only the
/// variance / bias computation is cluster-aware.
/// `cluster_ids` defaults to `DoubleMLData::cluster_vars`.
pub fn DoubleMLPLIV::sensitivity_analysis_cluster(
  self : DoubleMLPLIV,
  cluster_ids? : Array[Int] = self.data.cluster_vars,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let l_hat = self.predictions_l()
  let n = l_hat.length()
  require(cluster_ids.length() == n)
  let residuals : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    residuals[i] = self.data.y[i] - l_hat[i]
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
/// fitted PLIV. Returns `sqrt(var)` where `var` comes from
/// the shared `sandwich_variance(kind, ...)` dispatch in
/// `sandwich.mbt` (HC0 / HC1 / HC2 / HC3).
///
/// The three inputs are the ones `fit(...)` already persists
/// for the multiplier bootstrap (see the `psi_a` / `psi_b`
/// field docs on `DoubleMLPLIV`):
///   - `psi_a`  = `self.psi_a` -- the partialling-out
///     treatment score `-w_hat * v_hat` with
///     `w_hat = d - r_hat`, `v_hat = z - m_hat`.
///   - `psi`    = `psi_at(self.coef, self.psi_a, self.psi_b)`
///     -- the per-observation influence function evaluated at
///     the fitted `coef`, where `psi_b = v_hat * u_hat` is the
///     partialling-out outcome score with `u_hat = y - l_hat`.
///     Same `psi_at` score order as IRM / PLR.
///   - `M_inv`  = `[[1 / mean(psi_a)]]` (1x1). Only
///     `M_inv[0, 0]^2` enters the variance, so the sign of
///     the (up-to-sign) Jacobian inverse is irrelevant.
///
/// Preconditions: `self.fitted`, `mean(psi_a) != 0`.
pub fn DoubleMLPLIV::sandwich_se(
  self : DoubleMLPLIV,
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
/// fitted PLIV. Routes through `cluster_sandwich_variance`
/// with the same `psi_a` / `psi` / `M_inv` inputs as the IID
/// `sandwich_se` path.
///
/// Preconditions: `self.fitted`,
/// `cluster_ids.length() == n_obs`.
pub fn DoubleMLPLIV::cluster_sandwich_se(
  self : DoubleMLPLIV,
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
pub fn DoubleMLPLIV::bias_corrected_coef(self : DoubleMLPLIV) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Record a caller-supplied sample splitting and DERIVE the fold and
/// repetition counts from it. Returns a new `DoubleMLPLIV`; the
/// receiver is unchanged, as everywhere in this package.
///
/// `smpls` is one entry per repetition, each entry one `Fold` per fold
/// -- the nested form is the only form, so a single repetition is
/// `[f0, f1, f2]` wrapped once, i.e. `[[f0, f1, f2]]`.
///
/// The derivation is upstream's, and it is the part that surprises
/// people: `set_sample_splitting`
/// (`doubleml/double_ml_sampling_mixins.py:76`) sets `n_folds` and
/// `n_rep` FROM the supplied partition, so handing a two-fold split to
/// a model built with `n_folds=5` yields a two-fold model. On the
/// returned model `n_folds` / `n_rep` are updated to match, and `fit`
/// uses the supplied folds instead of drawing them.
///
/// Validation, via `check_sample_splitting`: every repetition carries
/// the same number of folds, and within each repetition the test index
/// sets are disjoint and cover exactly `[0, n_obs)`. A supplied
/// partition that is not a partition aborts rather than quietly
/// producing a cross-fit that leaks across folds.
///
/// Memoization: `fit` will not read or write the fit cache once an
/// external splitting is recorded. The cache key is built from the data,
/// learner and cluster hashes and has no term for the fold assignment,
/// so two different supplied partitions would collide and the second fit
/// would silently return the first one's predictions. The
/// `memoize_enabled` flag is carried through unchanged; it is the
/// `!external` term in `fit` that refuses the cache. The cache is also
/// CLEARED here, so a re-fit under a new splitting cannot resurrect an
/// entry written under the old one.
///
/// Cluster path: an externally supplied splitting applies to the
/// ROW-level path only. `fit_cluster` draws UNIT-level folds over the
/// unique cluster ids and expands them to rows, so a supplied row-level
/// partition is not consulted there and a clustered fit keeps drawing
/// its own unit-level folds. Making the cluster path honour external
/// splits is a separate decision and out of scope here; the field is
/// carried across so the row-level path resumes the supplied splitting
/// on a later non-cluster fit.
///
/// The one-fold "no sample splitting" case needs no special handling: a
/// single `Fold` whose train and test both cover everything is a valid
/// partition with `folds = 1`, which is what upstream detects and
/// reports.
pub fn DoubleMLPLIV::set_sample_splitting(
  self : DoubleMLPLIV,
  smpls : Array[Array[Fold]],
) -> DoubleMLPLIV {
  try {
    let checked = check_sample_splitting(smpls, self.n_obs())
    {
      ..self,
      n_folds: checked.folds,
      n_rep: checked.reps,
      smpls: checked.smpls,
      // A re-fit under a new splitting must not reuse a cache entry
      // written under the old one.
      fit_cache: FitCache::empty(),
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// The sample splitting recorded by `set_sample_splitting`, or `None`
/// when none was supplied and `fit` draws its own. `Some` carries the
/// DERIVED counts next to the folds, so a caller can read back what the
/// estimator actually used rather than inferring it from the constructor
/// arguments it no longer has any say over.
pub fn DoubleMLPLIV::sample_splitting(self : DoubleMLPLIV) -> SampleSplitting? {
  if self.smpls.length() == 0 {
    None
  } else {
    Some({ smpls: self.smpls, folds: self.n_folds, reps: self.n_rep, })
  }
}
