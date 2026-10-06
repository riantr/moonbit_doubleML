///|
/// Average potential outcomes for an arbitrary treatment level.
pub struct DoubleMLAPO {
  data : DoubleMLData
  treatment_level : Double
  n_folds : Int
  n_rep : Int
  seed : Int
  propensity_clip : Double
  // v0.60.0+: injected nuisance learners. Defaults to
  // `LearnerDispatch::linear_regression()` so v0.59.0 callers
  // see byte-identical results. v0.61.0+ will plumb these
  // through `cross_fit_predict` for `g_hat` and `m_hat`; for
  // v0.60.0 they're stored on the struct and returned via the
  // accessors but not yet consumed internally.
  ml_g : LearnerDispatch
  ml_m : LearnerDispatch
  g_hat : Array[Double]
  m_hat : Array[Double]
  coef : Double
  se : Double
  fitted : Bool
  // v0.61.0+: per-observation influence function components
  // for the multiplier bootstrap. APO policy score:
  //   psi_a[i] = -1                              (constant)
  //   psi_b[i] = g[i] + treated[i] * (y[i] - g[i]) / m[i]
  // where `treated[i] = 1{d[i] == treatment_level}`,
  // `g = E[Y | X]`, `m = P(D = treatment_level | X)` (clipped).
  // Length `n_obs`. Populated by `fit(...)`.
  psi_a : Array[Double]
  psi_b : Array[Double]
  // v0.61.0+: multiplier bootstrap state. `boot_t_stat` is a
  // length-`n_rep_boot` array of t-statistics for `coef`.
  // Populated by `bootstrap(...)`; empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
  // v0.84.0+: memoization state. `memoize_enabled` is the
  // user-facing opt-in (set via `DoubleMLAPO::enable_memoize()`);
  // when true and `n_rep == 1`, `fit()` caches the LAST rep's
  // `(g_hat, m_hat, psi_a, psi_b)` plus row-to-fold mapping in
  // `fit_cache` and reuses them on the next `fit()` call (the
  // `var_est(psi_a, psi_b)` -> `(coef, se)` pipeline still runs
  // fresh from the cached values, so changing the score path or
  // any post-aggregation configuration always takes effect).
  memoize_enabled : Bool
  fit_cache : FitCache
} derive(Debug)

///|
pub extend DoubleMLAPO with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLAPO::new(
  data : DoubleMLData,
  treatment_level? : Double = 1.0,
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
  ml_g? : LearnerDispatch = LearnerDispatch::linear_regression(),
  ml_m? : LearnerDispatch = LearnerDispatch::linear_regression(),
) -> DoubleMLAPO {
  try {
    require(n_folds >= 2)
    require(n_folds <= data.n_obs())
    require(n_rep >= 1)
    require(propensity_clip > 0.0)
    require(propensity_clip < 0.5)
    {
      data,
      treatment_level,
      n_folds,
      n_rep,
      seed,
      propensity_clip,
      ml_g,
      ml_m,
      g_hat: Array::make(data.n_obs(), 0.0),
      m_hat: Array::make(data.n_obs(), 0.0),
      coef: 0.0,
      se: 0.0,
      fitted: false,
      psi_a: Array::make(data.n_obs(), -1.0),
      psi_b: Array::make(data.n_obs(), 0.0),
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
pub fn DoubleMLAPO::n_obs(self : DoubleMLAPO) -> Int {
  self.data.n_obs()
}

///|
/// Number of features (covariate columns).
pub fn DoubleMLAPO::n_features(self : DoubleMLAPO) -> Int {
  self.data.n_features()
}

///|
/// Accessor for the outcome-nuisance learner used by the most
/// recent `fit(...)` call. v0.60.0+.
pub fn DoubleMLAPO::learner_g(self : DoubleMLAPO) -> LearnerDispatch {
  self.ml_g
}

///|
/// Accessor for the propensity-score learner used by the most
/// recent `fit(...)` call. v0.60.0+.
pub fn DoubleMLAPO::learner_m(self : DoubleMLAPO) -> LearnerDispatch {
  self.ml_m
}

///|
pub fn DoubleMLAPO::coef(self : DoubleMLAPO) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLAPO::se(self : DoubleMLAPO) -> Double {
  try {
    require(self.fitted)
    self.se
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLAPO::confint(self : DoubleMLAPO) -> (Double, Double) {
  try {
    require(self.fitted)
    (self.coef - 1.96 * self.se, self.coef + 1.96 * self.se)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLAPO::predictions_g(self : DoubleMLAPO) -> Array[Double] {
  try {
    require(self.fitted)
    self.g_hat
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLAPO::predictions_m(self : DoubleMLAPO) -> Array[Double] {
  try {
    require(self.fitted)
    self.m_hat
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
fn indicator_level(d : Array[Double], level : Double) -> Array[Double] {
  let out = Array::make(d.length(), 0.0)
  for i = 0; i < d.length(); i = i + 1 {
    out[i] = if d[i] == level { 1.0 } else { 0.0 }
  }
  out
}

///|
/// Cross-fit the APO nuisances. The order is asymmetric: the
/// conditional outcome `g` is fit only on the treated subset (the
/// same as the upstream `DoubleMLAPO`), while the propensity `m`
/// is fit on the *full* training fold (including controls). The
/// effect is that rows with `treated = 0` receive their `g` value
/// from the previous fold's treated-only fit (or stay at the
/// default 0.0 if no fold has yet seen them); rows with `treated = 1`
/// receive both a `g` (on the treated subset) and a propensity
/// update. Matches the upstream `DoubleMLAPO` convention.
///
/// v0.63.0+: routes `ml_g` (for the conditional outcome on the
/// treated subset) and `ml_m` (for the propensity on the full
/// fold) through `LearnerDispatch`. Defaults preserve v0.62.2
/// byte-equality (default `LearnerDispatch::linear_regression()`
/// gives the v0.62.2 OLS path).
fn cross_fit_apo(
  ml_g : LearnerDispatch,
  ml_m : LearnerDispatch,
  x : Matrix,
  y : Array[Double],
  treated : Array[Double],
  folds : Array[Fold],
  clip : Double,
) -> (Array[Double], Array[Double]) {
  let n = x.rows()
  let g = Array::make(n, 0.0)
  let m = Array::make(n, 0.0)
  for fold in folds {
    let tr = fold.train_indices()
    let te = fold.test_indices()
    let tg = filter_indices(tr, treated)
    if tg.length() > 0 {
      let p = fit_predict_one_dispatch(
        ml_g,
        slice_matrix_rows(x, tg),
        slice_vector(y, tg),
        slice_matrix_rows(x, te),
      )
      for k = 0; k < te.length(); k = k + 1 {
        g[te[k]] = p[k]
      }
    }
    let p = fit_predict_one_dispatch(
      ml_m,
      slice_matrix_rows(x, tr),
      slice_vector(treated, tr),
      slice_matrix_rows(x, te),
    )
    for k = 0; k < te.length(); k = k + 1 {
      m[te[k]] = p[k]
    }
  }
  (g, clip_vec(m, clip, 1.0 - clip))
}

///|
pub fn DoubleMLAPO::fit(
  self : DoubleMLAPO,
  ml_g? : LearnerDispatch = self.ml_g,
  ml_m? : LearnerDispatch = self.ml_m,
) -> DoubleMLAPO {
  // v0.65.0+: cluster-data dispatch — when `cluster_vars` is
  // non-empty, route through `fit_cluster` (cluster-aware
  // folds, unit-level cluster-robust SE).
  if self.data.is_cluster_data() {
    return self.fit_cluster(ml_g~, ml_m~)
  }
  let n = self.n_obs()
  let treated = indicator_level(self.data.d, self.treatment_level)
  // v0.84.0+: memoize check (mirrors the PLR / IRM / CVAR /
  // SSM / PLPR / LPLR pattern). The cache stores the LAST
  // rep's `(g_hat, m_hat, psi_a, psi_b)` plus row-to-fold
  // mapping. Honored only when `n_rep == 1` (multi-rep
  // aggregations must run every rep fresh -- we cannot
  // cache individual rep nuisances).
  // When memoize_enabled is false (the default), the entire
  // cache code path is skipped so v0.83.0 callers see
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
    hash_hyperparams("apo", ml_g, ml_m, self.propensity_clip)
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
      "apo",
    )
  // Accumulate `g` and `m` directly in the storage arrays; divide
  // by `n_rep` after the loop.
  let g = Array::make(n, 0.0)
  let m = Array::make(n, 0.0)
  // v0.84.0+: track the LAST rep's row-to-fold mapping for the
  // cache writeback.
  let fold_ids : Array[Int] = Array::make(n, 0)
  for r = 0; r < self.n_rep; r = r + 1 {
    let (gr, mr) = if cache_hit && r == self.n_rep - 1 {
      // Reuse the cached LAST-rep nuisances. The
      // `pa` / `pb` / `var_est` -> (coef, se) pipeline
      // below runs fresh from the cached values.
      let preds = self.fit_cache.predictions
      let cached_fold_ids = self.fit_cache.fold_ids
      for i = 0; i < n; i = i + 1 {
        fold_ids[i] = cached_fold_ids[i]
      }
      (preds[0], preds[1])
    } else {
      let folds = kfold(n, self.n_folds, self.seed + r)
      // Build row->fold_id map for the LAST rep (used by the
      // cache writeback below).
      if r == self.n_rep - 1 {
        for f = 0; f < folds.length(); f = f + 1 {
          for i in folds[f].test_indices() {
            fold_ids[i] = f
          }
        }
      }
      let (gr, mr) = cross_fit_apo(
        ml_g,
        ml_m,
        self.data.x,
        self.data.y,
        treated,
        folds,
        self.propensity_clip,
      )
      (gr, mr)
    }
    for i = 0; i < n; i = i + 1 {
      g[i] = g[i] + gr[i]
      m[i] = m[i] + mr[i]
    }
  }
  let inv = 1.0 / self.n_rep.to_double()
  // v0.84.0+: vectorise the per-element `g *= inv` /
  // `m *= inv` post-aggregation pass via
  // `vector_scale`. Byte-identical to the scalar loop
  // because `vector_scale` is a flat element-wise multiply.
  let g_scaled = vector_scale(g, inv)
  let m_scaled = vector_scale(m, inv)
  // `pa` is the APO score's `psi_a` component, which is structurally
  // `-1` for every observation (the potential-outcome score has no
  // treatment-side variation). `pb` is the `psi_b` component with
  // the IPW-style centring `g + treated * (y - g) / m`. v0.84.0+:
  // the `pb` residual loop is rewritten in terms of
  // `vector_subtract`, `vector_multiply`, `vector_divide`,
  // `vector_add` (matches the v0.81.0 helpers used by the
  // other DML estimators).
  let pa = Array::make(n, -1.0)
  let y_minus_g = vector_subtract(self.data.y, g_scaled)
  let treat_y_diff = vector_multiply(treated, y_minus_g)
  let ratio = vector_divide(treat_y_diff, m_scaled, eps=1.0e-12)
  let pb = vector_add(g_scaled, ratio)
  // Score + variance via the shared `var_est` helper.
  let (theta, se) = var_est(pa, pb)
  // v0.84.0+: when memoize is on and the cache missed, write
  // the freshly-computed nuisances + IF components + row-to-fold
  // mapping to the cache.
  let next_cache = if memoize && !cache_hit && self.n_rep == 1 {
    FitCache::from_fit(
      fold_ids,
      [g_scaled, m_scaled, pa, pb],
      self.seed,
      self.n_folds,
      self.n_rep,
      n,
      data_hash,
      hparams_hash,
      cluster_hash,
      "apo",
    )
  } else {
    self.fit_cache
  }
  {
    data: self.data,
    treatment_level: self.treatment_level,
    n_folds: self.n_folds,
    n_rep: self.n_rep,
    seed: self.seed,
    propensity_clip: self.propensity_clip,
    ml_g,
    ml_m,
    g_hat: g_scaled,
    m_hat: m_scaled,
    coef: theta,
    se,
    fitted: true,
    // v0.61.0: persist `pa` / `pb` as `psi_a` / `psi_b` for
    // the multiplier bootstrap (`pa` is constant -1, `pb` is
    // the IPW-centred potential-outcome score).
    psi_a: pa,
    psi_b: pb,
    boot_t_stat: [],
    boot_method: "",
    n_rep_boot: 0,
    boot_seed: 0,
    memoize_enabled: self.memoize_enabled,
    fit_cache: next_cache,
  }
}

///|
/// v0.65.0+: clustered-DML path for `DoubleMLAPO`. Folds
/// partition whole units (`kfold` on unique cluster ids,
/// expanded to row folds); nuisances are cross-fitted under
/// cluster folds; `psi_a = -1` (constant), `psi_b = g +
/// treated * (y - g) / m` is computed from the cluster
/// nuisances; coefficient is the fold-weighted ratio of
/// cluster score sums and SE is unit-level cluster-robust
/// (`cluster_causal_param_and_se`). The cluster path
/// differs from the row-level path only in the fold partition
/// and the two aggregation steps; the per-row score elements
/// are identical, so a single nuisances cross-fit (with
/// cluster-respecting folds) feeds both paths.
fn DoubleMLAPO::fit_cluster(
  self : DoubleMLAPO,
  ml_g~ : LearnerDispatch,
  ml_m~ : LearnerDispatch,
  max_attempts? : Int = 1,
) -> DoubleMLAPO {
  try {
    require(max_attempts >= 1)
    let cluster = self.data.cluster_vars
    let n = self.n_obs()
    let nrep = self.n_rep
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
    let treated = indicator_level(self.data.d, self.treatment_level)
    let coefs : Array[Double] = Array::make(nrep, 0.0)
    let ses : Array[Double] = Array::make(nrep, 0.0)
    let mut g : Array[Double] = Array::make(n, 0.0)
    let mut m : Array[Double] = Array::make(n, 0.0)
    for r = 0; r < nrep; r = r + 1 {
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
        let (g_r, m_r) = cross_fit_apo(
          ml_g,
          ml_m,
          self.data.x,
          self.data.y,
          treated,
          folds_row,
          self.propensity_clip,
        )
        g = g_r
        m = m_r
        let pa : Array[Double] = Array::make(n, 0.0)
        let pb : Array[Double] = Array::make(n, 0.0)
        for i = 0; i < n; i = i + 1 {
          pa[i] = -1.0
          pb[i] = g[i] + treated[i] * (self.data.y[i] - g[i]) / m[i]
        }
        let (t, s) = cluster_causal_param_and_se(
          pa,
          pb,
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
    // v0.65.0+: per-observation IF (constant -1 + IPW score)
    // persisted for the multiplier bootstrap; recomputed from
    // the last rep's cluster-aware nuisances so the stored
    // arrays align with `g_hat` / `m_hat` and `coef`.
    let pa : Array[Double] = Array::make(n, 0.0)
    let pb : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      pa[i] = -1.0
      pb[i] = g[i] + treated[i] * (self.data.y[i] - g[i]) / m[i]
    }
    {
      data: self.data,
      treatment_level: self.treatment_level,
      n_folds: self.n_folds,
      n_rep: self.n_rep,
      seed: self.seed,
      propensity_clip: self.propensity_clip,
      ml_g,
      ml_m,
      g_hat: g,
      m_hat: m,
      coef,
      se,
      fitted: true,
      psi_a: pa,
      psi_b: pb,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      // v0.84.0+: memoize state carried through the cluster
      // path; the cluster folds are deterministic for fixed
      // (seed, n_folds, n_rep, cluster_vars) so the same
      // hash pipeline as the IID path applies.
      memoize_enabled: self.memoize_enabled,
      fit_cache: self.fit_cache,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.84.0+: turn on memoization. When enabled (and `n_rep == 1`),
/// the next `fit()` caches the LAST rep's `(g_hat, m_hat,
/// psi_a, psi_b)` plus row-to-fold mapping; subsequent `fit()`
/// calls with the same data fingerprint, fold split, learner
/// configuration, propensity clip, and cluster partition reuse
/// the cached nuisances. The `var_est(psi_a, psi_b) -> (coef,
/// se)` pipeline still runs fresh on every `fit()`, so any
/// post-aggregation configuration change always takes effect.
pub fn DoubleMLAPO::enable_memoize(self : DoubleMLAPO) -> DoubleMLAPO {
  { ..self, memoize_enabled: true, }
}

///|
/// v0.84.0+: turn off memoization. After this, `fit()` will not
/// read or write the cache; the existing `fit_cache` is preserved
/// on the returned struct (call `clear_cache()` to drop it).
pub fn DoubleMLAPO::disable_memoize(self : DoubleMLAPO) -> DoubleMLAPO {
  { ..self, memoize_enabled: false, }
}

///|
/// v0.84.0+: drop the cached nuisances. After this, the next
/// `fit()` will run the full cross-fit (and repopulate the cache
/// if memoize is still enabled).
pub fn DoubleMLAPO::clear_cache(self : DoubleMLAPO) -> DoubleMLAPO {
  { ..self, fit_cache: FitCache::empty(), }
}

///|
/// v0.84.0+: `true` iff `fit_cache` holds at least one cached
/// nuisance prediction (i.e. a previous `fit()` with
/// `memoize_enabled = true` has populated the cache). Note that
/// `has_cache()` does NOT verify the cache key matches the
/// current data + learner configuration -- check `memoize_enabled`
/// if you also need to know whether the next `fit()` will hit.
pub fn DoubleMLAPO::has_cache(self : DoubleMLAPO) -> Bool {
  !self.fit_cache.is_empty()
}

///|
/// v0.89.0+: Huber-White sandwich standard error for the fitted
/// APO (average potential outcome at `treatment_level`).
/// Returns `sqrt(var)` where `var` comes from the shared
/// `sandwich_variance(kind, ...)` dispatch in `sandwich.mbt`
/// (HC0 / HC1 / HC2 / HC3).
///
/// The three inputs are the ones `fit(...)` already persists for
/// the multiplier bootstrap (see the `psi_a` / `psi_b` field docs
/// on `DoubleMLAPO`):
///   - `psi_a` = `self.psi_a` -- the potential-outcome score's
///     treatment term, structurally the constant `-1` (the
///     potential-outcome score has no treatment-side variation),
///     so `mean(psi_a) == -1` and `M_inv = [[-1.0]]`.
///   - `psi`   = `psi_at(self.coef, self.psi_a, self.psi_b)` --
///     the per-observation influence function at the fitted
///     `coef`, with `psi_b` the IPW-centred score
///     `g[i] + treated[i] * (y[i] - g[i]) / m[i]`. Matches the
///     `psi(theta) = theta * psi_a + psi_b` form documented on
///     `DoubleMLAPO::bootstrap`.
///   - `M_inv` = `[[1 / mean(psi_a)]]` (1x1). Only
///     `M_inv[0, 0]^2` enters the variance, so the sign of the
///     (up-to-sign) Jacobian inverse is irrelevant.
///
/// APO has no transformed / subset domain: both the IID path and
/// the v0.65.0 cluster path (`fit_cluster`) persist length-`n_obs`
/// IF components, so the variance's `n_obs` is
/// `self.psi_a.length() == self.n_obs()`.
///
/// Preconditions: `self.fitted`, `mean(psi_a) != 0`.
pub fn DoubleMLAPO::sandwich_se(
  self : DoubleMLAPO,
  kind : SandwichKind,
) -> Double {
  try {
    require(self.fitted)
    let n = self.psi_a.length()
    require(n == self.psi_b.length())
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
/// v0.89.0+: cluster-robust sandwich standard error for the
/// fitted APO. Routes through `cluster_sandwich_variance` with
/// the same `psi_a` / `psi` / `M_inv` inputs as the IID
/// `sandwich_se` path. `cluster_ids[i]` is the cluster of
/// observation `i` on the full-sample (not transformed) domain.
/// When the model was fitted on cluster data
/// (`data.cluster_vars` non-empty) the natural `cluster_ids` are
/// those very unit ids; otherwise the caller supplies them.
///
/// Preconditions: `self.fitted`,
/// `cluster_ids.length() == psi_a.length()`.
pub fn DoubleMLAPO::cluster_sandwich_se(
  self : DoubleMLAPO,
  cluster_ids : Array[Int],
) -> Double {
  try {
    require(self.fitted)
    let n = self.psi_a.length()
    require(n == self.psi_b.length())
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
/// (APO's `psi_a` is the constant `-1`.)
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
pub fn DoubleMLAPO::bias_corrected_coef(self : DoubleMLAPO) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.61.0+: multiplier bootstrap for `DoubleMLAPO`. The
/// per-observation influence function is
///
///   psi[i] = theta * psi_a[i] + psi_b[i]
///          = -1 + theta * pb[i]
///
/// where `pb[i] = g[i] + treated[i] * (y[i] - g[i]) / m[i]`
/// is the IPW-centred potential-outcome score, computed at
/// the fitted `coef` from the stored `g_hat` / `m_hat`.
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
/// `DoubleMLDIDCrossSection::bootstrap`); APO is the
/// `n_thetas=1` case.
pub fn DoubleMLAPO::bootstrap(
  self : DoubleMLAPO,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLAPO {
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
          "draw_bootstrap_weights: unknown method (set in DoubleMLAPO::bootstrap): " +
          m,
        )
    }
    // Compute psi = psi_at(coef, psi_a, psi_b) and
    // ss_psi = sum(psi[i]^2) once. `psi_a[i] = -1` and
    // `psi_b` is the IPW-centred potential-outcome score,
    // both populated by `fit(...)`.
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
/// MSE-on-g_hat cross-fitting. The chosen `(learner_g,
/// learner_m)` is then re-fit on the FINAL-FIT fold partition
/// (`self.n_folds`) under `DoubleMLAPO::fit`. `treatment_level`
/// is held fixed at `self.treatment_level`.
///
/// `param_set` is an `Array[TuneParam]`; each entry is a
/// `(learner_g, learner_m)` pair. `scoring_method` is
/// `"MSE"` (default), `"RMSE"`, or `"NegMSE"`. Returns a
/// re-fitted `DoubleMLAPO` with the chosen pair applied.
pub fn DoubleMLAPO::tune(
  self : DoubleMLAPO,
  param_set~ : Array[TuneParam],
  scoring_method? : String = "MSE",
  n_folds_tune? : Int = 5,
  seed? : Int = 3141,
) -> DoubleMLAPO {
  try {
    require(param_set.length() > 0)
    require(n_folds_tune >= 2)
    // v0.108.0: this guard was MISSING here. `PLR` / `PLIV` / `IRM` /
    // `IIVM` all carried `require(!self.data.is_cluster_data())`; APO
    // did not, so `DoubleMLAPO::tune` silently ran on cluster data
    // where its four siblings aborted. The asymmetry was invisible:
    // cluster-DML tune folds must be drawn over unique units, not
    // rows, and a row-wise fold schedule on clustered data produces
    // a plausible-looking score for a wrong cross-fit. Same for APOS,
    // which now inherits the guard.
    require(!self.data.is_cluster_data())
    let scoring = TuneScoring::parse(scoring_method)
    // v0.108.0: the scoring loop, the fold draw and the argmin/argmax
    // selection moved into `tune_score_grid`. APO carried a
    // byte-identical copy of all three; so did the other four, and
    // that duplication is what let the selection rule be inverted
    // with the entire suite green.
    let grid = tune_score_grid(
      self.data.x,
      self.data.y,
      param_set.map(fn(p : TuneParam) { p.learner_l }),
      n_folds_tune,
      seed,
      scoring,
    )
    let best_param = param_set[grid.best_index]
    self.fit(ml_g=best_param.learner_l, ml_m=best_param.learner_m)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// `DoubleMLAPOS::tune` - score a grid of `(learner_g, learner_m)`
/// pairs and re-fit with the winner. APOS is the multi-treatment
/// sibling of `DoubleMLAPO` and tunes the same two slots, so it routes
/// through the same `tune_score_grid` core.
///
/// v0.108.0: new. `APOS` had no `tune` at all, so it was one of the
/// fourteen estimators that carried a coverage gap against upstream
/// (where `tune` reaches every estimator through the `BaseDML` mixin).
///
/// The cluster guard is inherited from `APO`, which itself only got
/// one in v0.108.0 - cluster-DML tune folds must be drawn over unique
/// units rather than rows, and a row-wise schedule on clustered data
/// produces a plausible-looking score for a wrong cross-fit instead of
/// an error.
pub fn DoubleMLAPOS::tune(
  self : DoubleMLAPOS,
  param_set~ : Array[TuneParam],
  scoring_method? : String = "MSE",
  n_folds_tune? : Int = 5,
  seed? : Int = 3141,
) -> DoubleMLAPOS {
  try {
    require(param_set.length() > 0)
    require(n_folds_tune >= 2)
    require(!self.data.is_cluster_data())
    let scoring = TuneScoring::parse(scoring_method)
    let grid = tune_score_grid(
      self.data.x,
      self.data.y,
      param_set.map(fn(p : TuneParam) { p.learner_l }),
      n_folds_tune,
      seed,
      scoring,
    )
    let best_param = param_set[grid.best_index]
    self.fit(ml_g=best_param.learner_l, ml_m=best_param.learner_m)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.66.0+: Cinelli & Hazlett (2020) omitted-variable bias
/// analysis. Outcome residual is `y - g_hat` (the APO is
/// conditioned on `treated=1`); the Riesz-representer
/// variance is `mean(psi_a^2) = 1` for the APO score
/// (`psi_a = -1` constant). Routes through the shared
/// `irm_style_sensitivity` helper.
pub fn DoubleMLAPO::sensitivity_analysis(
  self : DoubleMLAPO,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let g_hat = self.predictions_g()
  let n = g_hat.length()
  let residuals : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    residuals[i] = self.data.y[i] - g_hat[i]
  }
  irm_style_sensitivity(self.coef, residuals, self.psi_a, cf_y, cf_d)
}

///|
/// v0.72.0+: cluster-robust analogue of
/// `DoubleMLAPO::sensitivity_analysis`. Same residual
/// formula (`y - g_hat`) and the same `psi_a = -1`
/// (constant) as the IID path; only the variance / bias
/// computation is cluster-aware. `cluster_ids` defaults to
/// `DoubleMLData::cluster_vars`.
pub fn DoubleMLAPO::sensitivity_analysis_cluster(
  self : DoubleMLAPO,
  cluster_ids? : Array[Int] = self.data.cluster_vars,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let g_hat = self.predictions_g()
  let n = g_hat.length()
  require(cluster_ids.length() == n)
  let residuals : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    residuals[i] = self.data.y[i] - g_hat[i]
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
/// Average potential outcomes *symmetric* across multiple treatment
/// levels. v0.49.0: full upstream parity — `treatment_levels`
/// validation in `new` (rejects duplicates and levels not in
/// `data.d`), the `causal_contrast` method (level-by-level delta
/// and SE vs a reference level), and the
/// `treatment_levels()` / `n_treatment_levels()` / `fitted()`
/// accessors.
///
/// Each treatment level is fit with the same fold partition
/// (the parent does not currently route a shared partition to the
/// child `DoubleMLAPO`; each child draws its own folds via
/// `kfold`. v0.50.0+ plans to wire the parent through a
/// `fit_with_splits` helper to share one stratified partition,
/// but the v0.49.0 implementation is the v0.50.0 PR target) and
/// the same closed-form `LinearRegression` learner. The
/// `causal_contrast(reference_levels)` method then returns the
/// level-by-level difference `coefs[i] - coefs[ref]` for one or
/// more reference levels, matching the upstream
/// `DoubleMLAPOS.causal_contrast` semantics.
pub struct DoubleMLAPOS {
  data : DoubleMLData
  treatment_levels : Array[Double]
  n_folds : Int
  n_rep : Int
  seed : Int
  propensity_clip : Double
  // v0.60.0+: injected nuisance learners (forwarded to
  // each child `DoubleMLAPO` on fit). Same forward-compat
  // story as the rest of the v0.60.0 estimator set.
  ml_g : LearnerDispatch
  ml_m : LearnerDispatch
  coefs : Array[Double]
  ses : Array[Double]
  fitted : Bool
  // v0.63.0+: multiplier-bootstrap state. `boot_t_stat[j]` is
  // the length-`n_rep_boot` t-stat array for `coefs[j]`
  // (the APO coefficient at treatment level `j`).
  // Populated by `bootstrap(...)`; empty until then.
  boot_t_stat : Array[Array[Double]]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
  // v0.84.0+: memoization state. `memoize_enabled` is the
  // user-facing opt-in (set via
  // `DoubleMLAPOS::enable_memoize()`); when true, each
  // child `DoubleMLAPO` gets `enable_memoize()` forwarded
  // on `fit()` so the per-level cache is honored.
  // `fit_cache` here additionally caches the parent-level
  // `(coefs, ses)` arrays so a second `fit()` call with
  // identical inputs skips the entire per-level loop.
  memoize_enabled : Bool
  fit_cache : FitCache
  // v0.100.0+: per-level `psi_b`, flattened row-major as
  // `psi_b_flat[treatment_index * n_obs + i]`. This is the EXACT
  // array the child `DoubleMLAPO` already persisted as its own
  // `psi_b` (see the `psi_b: pb` writes in `DoubleMLAPO::fit` /
  // `DoubleMLAPO::fit_cluster`); the per-level loop used to read
  // only `z.coef()` / `z.se()` and drop it on the floor, which is
  // what left `DoubleMLAPOS` out of the 17-estimator sandwich
  // family. Empty until `fit` runs.
  //
  // The sibling `psi_a` is deliberately NOT stored: APO's `psi_a`
  // is the CONSTANT `-1` for every observation (the
  // potential-outcome score has no treatment-side variation), so
  // `Array::make(n_obs, -1.0)` reproduces the child's `pa` bit for
  // bit at zero memory cost. `m_inv_1x1_at` reads it back and
  // requires `mean(psi_a) != 0`, the same guard
  // `DoubleMLAPO::sandwich_se` uses.
  //
  // Carried through the memoize path as
  // `fit_cache.predictions[2]`, so a cache hit restores the IF
  // components WITHOUT re-fitting the children (re-fitting would
  // defeat the cache, which is the whole point of the layer).
  psi_b_flat : Array[Double]
} derive(Debug)

///|
pub extend DoubleMLAPOS with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLAPOS::new(
  data : DoubleMLData,
  treatment_levels : Array[Double],
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
  ml_g? : LearnerDispatch = LearnerDispatch::linear_regression(),
  ml_m? : LearnerDispatch = LearnerDispatch::linear_regression(),
) -> DoubleMLAPOS {
  try {
    require(treatment_levels.length() >= 1)
    require(n_folds >= 2)
    require(n_folds <= data.n_obs())
    require(n_rep >= 1)
    require(propensity_clip > 0.0)
    require(propensity_clip < 0.5)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
  // v0.49.0: every requested treatment level must be present in
  // the data's treatment assignment (`np.unique(data.d)` in
  // upstream). Catch duplicates within the request itself too.
  for i = 0; i < treatment_levels.length(); i = i + 1 {
    let lvl = treatment_levels[i]
    let mut dup = false
    for j = 0; j < i; j = j + 1 {
      if treatment_levels[j] == lvl {
        dup = true
        break
      }
    }
    if dup {
      abort(
        "DoubleMLAPOS: treatment_levels contains a duplicate entry: " +
        lvl.to_string(),
      )
    }
    let mut in_data = false
    for k = 0; k < data.d.length(); k = k + 1 {
      if data.d[k] == lvl {
        in_data = true
        break
      }
    }
    if !in_data {
      abort(
        "DoubleMLAPOS: treatment_level " +
        lvl.to_string() +
        " is not present in data.d",
      )
    }
  }
  {
    data,
    treatment_levels,
    n_folds,
    n_rep,
    seed,
    propensity_clip,
    ml_g,
    ml_m,
    coefs: Array::make(treatment_levels.length(), 0.0),
    ses: Array::make(treatment_levels.length(), 0.0),
    fitted: false,
    boot_t_stat: [],
    boot_method: "",
    n_rep_boot: 0,
    boot_seed: 0,
    // v0.84.0+: memoize starts disabled; opt in via
    // `.enable_memoize()` for caching.
    memoize_enabled: false,
    fit_cache: FitCache::empty(),
    // v0.100.0+: per-level IF components; populated by `fit`.
    psi_b_flat: [],
  }
}

///|
pub fn DoubleMLAPOS::fit(
  self : DoubleMLAPOS,
  ml_g? : LearnerDispatch = self.ml_g,
  ml_m? : LearnerDispatch = self.ml_m,
) -> DoubleMLAPOS {
  try {
    ignore(ml_g)
    ignore(ml_m)
    require(self.treatment_levels.length() >= 1)
    let n_obs = self.data.n_obs()
    let n_levels = self.treatment_levels.length()
    // v0.84.0+: memoize check (mirrors the per-estimator
    // pattern). The parent cache stores the LAST rep's
    // `(coefs, ses)` arrays (the only values the parent owns)
    // plus a sentinel `fold_ids` row (the parent's cache hit
    // path doesn't need row-to-fold routing -- the children
    // own their own cross-fit partitions). When memoize is on
    // and the cache is valid, we skip the entire per-level
    // child-fit loop and just hand back the cached `coefs` /
    // `ses`. When memoize is on and the cache missed, we run
    // the standard per-level loop and write back the resulting
    // `coefs` / `ses` for the next call.
    //
    // Hyperparameter hashing folds the `treatment_levels`
    // vector into the hparams key by reusing the cluster-ids
    // hash slot (the APOS parent has no `cluster_vars` of its
    // own; the child DoubleMLAPO's cluster partition is the
    // parent's `cluster_vars` already, hashed by the child's
    // own cache write). For the parent key we mix in a hash
    // of the treatment-levels vector so a reconfigure
    // invalidates correctly.
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
      hash_hyperparams("apos", ml_g, ml_m, self.propensity_clip)
    } else {
      0UL
    }
    let cluster_hash : UInt64 = if memoize {
      // Fold the treatment-levels vector + seed + n_folds
      // into a per-call fingerprint. The standard
      // `hash_cluster_ids` over an empty vector is 0; for
      // APOS we want a non-trivial fingerprint, so we
      // override here: mix the level vector length, then
      // each level, then `n_folds`.
      let mut h : UInt64 = 0xcbf29ce484222325UL
      h = (h ^ n_levels.to_uint64()) * 0x00000100000001B3UL
      for lvl in self.treatment_levels {
        // level as integer (we store Double; bit-cast via
        // to_uint64) is not stable across refactors -- use
        // string instead, matching `fold_mix_double`.
        h = fold_mix_double(h, lvl)
      }
      h = fold_mix_int(h, self.n_folds)
      h
    } else {
      0UL
    }
    let cache_hit = memoize &&
      self.fit_cache.is_valid(
        self.seed,
        self.n_folds,
        self.n_rep,
        n_obs,
        data_hash,
        hparams_hash,
        cluster_hash,
        "apos",
      )
    let (c, s, pb_flat) = if cache_hit {
      // Cache hit: pull `(coefs, ses, psi_b_flat)` straight from the
      // stored predictions. The sentinel `fold_ids` length
      // (1 in the empty-cache / 1 + n_obs in the cached
      // variant) does not gate the parent's hit path -- the
      // parent's prediction layout is `[coefs, ses, psi_b_flat]`.
      //
      // v0.100.0: `psi_b_flat` is the THIRD slot. It has to be,
      // because a hit skips the child loop entirely -- there is no
      // live child left to read `psi_b` from, so without the third
      // slot every `sandwich_se_at` call on a memoized APOS would
      // see `psi_b_flat == []` and abort on the length guard. The
      // `require`s here ABORT rather than degrade to a re-fit: a
      // cache that cannot serve the IF components is not a cache,
      // and silently re-fitting is the behaviour the layer exists
      // to avoid.
      let preds = self.fit_cache.predictions
      require(preds.length() == 3)
      require(preds[2].length() == n_levels * n_obs)
      (preds[0], preds[1], preds[2])
    } else {
      let c = Array::make(n_levels, 0.0)
      let s = Array::make(n_levels, 0.0)
      // v0.100.0: per-level `psi_b` rows, row-major. The child
      // already computed and persisted this array for its own
      // multiplier bootstrap (`DoubleMLAPO::bootstrap` reads
      // `self.psi_b`), so keeping it costs a copy and NO extra
      // cross-fit, no re-training and no recomputation.
      let pb_flat = Array::make(n_levels * n_obs, 0.0)
      for j = 0; j < n_levels; j = j + 1 {
        // v0.49.0: the parent APOS fits each child `DoubleMLAPO` with
        // `n_rep = self.n_rep` so the child draws its own fold
        // partition (`n_rep` total fold draws per treatment level).
        // The parent does not currently route a shared stratified
        // partition to the child — that's a v0.50.0+ target. The
        // resulting fold-draw count is `n_rep * n_treatment_levels`,
        // matching the upstream `DoubleMLAPOS.fit` total.
        //
        // v0.84.0+: when `memoize_enabled` is on, route
        // `.enable_memoize()` through to the child so the
        // child's own cache is honored on subsequent fits.
        let child = DoubleMLAPO::new(
          self.data,
          treatment_level=self.treatment_levels[j],
          n_folds=self.n_folds,
          n_rep=self.n_rep,
          seed=self.seed,
          propensity_clip=self.propensity_clip,
        )
        let child_memo = if self.memoize_enabled {
          child.enable_memoize()
        } else {
          child
        }
        let z = child_memo.fit()
        c[j] = z.coef()
        s[j] = z.se()
        // v0.100.0: keep the child's `psi_b` row. `z.psi_a` is the
        // constant `-1` (same value at every index) and is NOT
        // copied -- `Array::make(n_obs, -1.0)` regenerates it
        // exactly. Length is checked rather than assumed so a
        // future child that changes its IF layout fails here,
        // loudly, instead of silently mis-slicing the row.
        require(z.psi_b.length() == n_obs)
        let offset = j * n_obs
        for i = 0; i < n_obs; i = i + 1 {
          pb_flat[offset + i] = z.psi_b[i]
        }
      }
      (c, s, pb_flat)
    }
    // v0.84.0+: writeback when memoize is on and the cache
    // missed. The parent-side sentinel is a length-`n_obs`
    // array of zeros (the parent doesn't need a per-row
    // fold-id routing -- children own their own folds; the
    // FitCache contract just requires `fold_ids.length()
    // == n_obs` for `is_valid` to fire).
    let next_cache = if memoize && !cache_hit {
      FitCache::from_fit(
        Array::make(n_obs, 0),
        [c, s, pb_flat],
        self.seed,
        self.n_folds,
        self.n_rep,
        n_obs,
        data_hash,
        hparams_hash,
        cluster_hash,
        "apos",
      )
    } else {
      self.fit_cache
    }
    {
      data: self.data,
      treatment_levels: self.treatment_levels,
      n_folds: self.n_folds,
      n_rep: self.n_rep,
      seed: self.seed,
      propensity_clip: self.propensity_clip,
      ml_g,
      ml_m,
      coefs: c,
      ses: s,
      fitted: true,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      memoize_enabled: self.memoize_enabled,
      fit_cache: next_cache,
      // v0.100.0: per-level IF components, bound from EITHER the
      // per-level loop (miss) or the third cache slot (hit), so
      // there is exactly one binding and no second restore path
      // that can drift.
      psi_b_flat: pb_flat,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.84.0+: turn on memoization. Forwards `.enable_memoize()`
/// to each child `DoubleMLAPO` on the next call, and caches
/// the resulting `(coefs, ses)` arrays at the parent level so
/// a repeated `fit()` call with identical inputs skips the
/// per-level loop entirely.
pub fn DoubleMLAPOS::enable_memoize(self : DoubleMLAPOS) -> DoubleMLAPOS {
  { ..self, memoize_enabled: true, }
}

///|
/// v0.84.0+: turn off memoization. After this, `fit()` will not
/// read or write the cache; the existing `fit_cache` is preserved
/// on the returned struct (call `clear_cache()` to drop it).
pub fn DoubleMLAPOS::disable_memoize(self : DoubleMLAPOS) -> DoubleMLAPOS {
  { ..self, memoize_enabled: false, }
}

///|
/// v0.84.0+: drop the cached `(coefs, ses)` arrays. After this,
/// the next `fit()` will run the per-level loop fresh (and
/// repopulate the cache if memoize is still enabled).
pub fn DoubleMLAPOS::clear_cache(self : DoubleMLAPOS) -> DoubleMLAPOS {
  { ..self, fit_cache: FitCache::empty(), }
}

///|
/// v0.84.0+: `true` iff `fit_cache` holds at least one cached
/// `(coefs, ses)` pair (i.e. a previous `fit()` with
/// `memoize_enabled = true` has populated the cache). Note that
/// `has_cache()` does NOT verify the cache key matches the
/// current data + learner configuration -- check `memoize_enabled`
/// if you also need to know whether the next `fit()` will hit.
pub fn DoubleMLAPOS::has_cache(self : DoubleMLAPOS) -> Bool {
  !self.fit_cache.is_empty()
}

///|
/// Accessor for the outcome-nuisance learner used by the most
/// recent `fit(...)` call. v0.60.0+.
pub fn DoubleMLAPOS::learner_g(self : DoubleMLAPOS) -> LearnerDispatch {
  self.ml_g
}

///|
/// Accessor for the propensity-score learner used by the most
/// recent `fit(...)` call. v0.60.0+.
pub fn DoubleMLAPOS::learner_m(self : DoubleMLAPOS) -> LearnerDispatch {
  self.ml_m
}

///|
pub fn DoubleMLAPOS::coefs(self : DoubleMLAPOS) -> Array[Double] {
  try {
    require(self.fitted)
    self.coefs
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLAPOS::ses(self : DoubleMLAPOS) -> Array[Double] {
  try {
    require(self.fitted)
    self.ses
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.49.0: the requested treatment levels, in user-supplied order.
pub fn DoubleMLAPOS::treatment_levels(self : DoubleMLAPOS) -> Array[Double] {
  self.treatment_levels
}

///|
/// v0.49.0: number of requested treatment levels.
pub fn DoubleMLAPOS::n_treatment_levels(self : DoubleMLAPOS) -> Int {
  self.treatment_levels.length()
}

// ---------------------------------------------------------------------------
// v0.100.0: per-level sandwich API (the `sandwich_se_at` triple)
// ---------------------------------------------------------------------------
//
// WHY APOS IS PER LEVEL, AND WHY IT IS NOT LIKE THE DID FAMILY
// =============================================================
// `DoubleMLAPOS` fits one independent child `DoubleMLAPO` per
// requested treatment level and keeps `coefs[j]` / `ses[j]`. Each
// child is a separate scalar Z-estimator with its own cross-fit,
// its own score and its own root, so each level is a 1x1 sandwich
// problem and the methods are PER LEVEL, following
// `DoubleMLQTE::sandwich_se_at` (v0.95.0) rather than the joint
// `sandwich_se` of the DID family (which has a multi-column IF
// matrix and a real `M_inv` to invert).
//
// What APOS does NOT do, unlike the DID family, is re-derive the
// score: the child already persists `psi_a` / `psi_b` for its own
// multiplier bootstrap, and `DoubleMLAPO::sandwich_se` (v0.89.0)
// already routes those exact arrays through the shared
// `sandwich_variance` dispatch. This file is the per-level
// transcription of that, over the child's own arrays.
//
// THE STRUCTURAL FACT: `M_inv` IS -1 HERE
// --------------------------------------
// APO's score has no treatment-side variation, so the child's
// `psi_a[i]` is the CONSTANT `-1` at every observation
// (`pa = Array::make(n, -1.0)` in `DoubleMLAPO::fit`), giving
//
//     mean(psi_a) = -1   and   M_inv = [[1 / mean(psi_a)]] = [[-1.0]]
//
// Only `M_inv[0,0]^2` enters the variance, so the sign is
// irrelevant and `M_inv[0,0]^2 == 1` exactly. This is why
// APOS -- unlike PQ or QTE, whose Jacobians are data-dependent --
// needs no `m_inv` guard beyond `mean(psi_a) != 0`: there is no
// fitted derivative that can be zero or sub-normal.
//
// THE PAYOFF INVARIANT
// --------------------
//
//     sandwich_se_at(j, HC0) == ses[j]
//
// and it is BIT-IDENTICAL, not merely equal to a tolerance.
// `var_est` (var_est.mbt) computes
//
//     psi[i]  = coef * psi_a[i] + psi_b[i]     (same order as `psi_at`)
//     gamma   = Kahan sum of psi[i]^2
//     sigma2  = (gamma / n) / (mean(psi_a)^2 * n)
//
// while `sandwich_variance_hc0` computes
//
//     acc     = Kahan sum of psi[i]^2
//     var     = M_inv[0,0]^2 * acc / n / n
//
// Same Kahan loop, same index order, same products; `coef` is the
// same number (it IS the child's stored `coef`, and
// `sandwich_se_at` reads `coefs[j]`); and `mean(psi_a)^2 == 1.0`
// exactly, so the multiply by `1.0` is the IEEE identity and the
// two sides run the identical sequence of operations.
// `expand_v100_apos_test.mbt` pins exact equality (`==`).
//
// The invariant holds for any `n_rep` on the IID path: the child
// averages its per-rep nuisances and then calls `var_est` ONCE on
// the averaged `pa` / `pb`, so the persisted `psi_b` and the
// shipped `se` always describe the same score.
//
// IT DOES NOT HOLD ON A CLUSTERED FIT. With non-empty
// `data.cluster_vars` the child routes to
// `DoubleMLAPO::fit_cluster`, where `se` is the unit-level
// cluster-robust `sqrt(var_unit / n_units)` from
// `cluster_causal_param_and_se` and `coef` is the fold-weighted
// cluster score ratio -- a different quantity from the row-level
// IID variance, and with a `n_units` (not `n_obs`) denominator.
// Use `cluster_sandwich_se_at(j, self.data.cluster_vars)` there;
// it agrees with the shipped cluster SE only up to that
// denominator and the jackknife correction.

///|
/// Treatment level `treatment_index`'s per-observation `psi_b`,
/// extracted as the slice
/// `psi_b_flat[treatment_index * n_obs .. (treatment_index + 1) * n_obs]`
/// of a fresh array. The `.. self`-style struct-literal methods
/// (`bootstrap`, `enable_memoize`, ...) carry the field for free.
fn DoubleMLAPOS::psi_b_row_at(
  self : DoubleMLAPOS,
  treatment_index : Int,
) -> Array[Double] {
  try {
    let n_levels = self.treatment_levels.length()
    require(n_levels >= 1)
    require(treatment_index >= 0)
    require(treatment_index < n_levels)
    require(self.coefs.length() == n_levels)
    require(self.ses.length() == n_levels)
    let n_obs = self.data.n_obs()
    require(n_obs >= 1)
    require(self.psi_b_flat.length() == n_levels * n_obs)
    let row : Array[Double] = Array::make(n_obs, 0.0)
    let offset = treatment_index * n_obs
    for i = 0; i < n_obs; i = i + 1 {
      row[i] = self.psi_b_flat[offset + i]
    }
    row
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Treatment level `treatment_index`'s `psi_a` (the constant `-1`
/// row) -- see the section comment above for why it is regenerated
/// rather than persisted.
fn DoubleMLAPOS::psi_a_row_at(
  self : DoubleMLAPOS,
  treatment_index : Int,
) -> Array[Double] {
  try {
    let n_levels = self.treatment_levels.length()
    require(n_levels >= 1)
    require(treatment_index >= 0)
    require(treatment_index < n_levels)
    let n_obs = self.data.n_obs()
    require(n_obs >= 1)
    require(self.psi_b_flat.length() == n_levels * n_obs)
    Array::make(n_obs, -1.0)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// The Jacobian inverse `M_inv` (1x1) for treatment level
/// `treatment_index`: `[[1 / mean(psi_a)]]`, which for APO is
/// `[[-1.0]]` because `psi_a` is the constant `-1` -- see the
/// section comment above.
///
/// The `mean(psi_a) != 0` guard is kept (it is the one
/// `DoubleMLAPO::sandwich_se` uses) rather than dropped as
/// vacuously true: it is the assertion that this level's IF
/// components are present and well-formed, and it is the same
/// shape a reader of the fifteen other estimators expects.
fn DoubleMLAPOS::m_inv_1x1_at(
  self : DoubleMLAPOS,
  treatment_index : Int,
) -> Matrix {
  try {
    let psi_a = self.psi_a_row_at(treatment_index)
    let mean_a = mean(psi_a)
    require(mean_a.abs() > 0.0)
    Matrix::from_array([1.0 / mean_a], 1, 1)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.100.0+: heteroskedasticity-consistent (Huber-White) sandwich
/// standard error for treatment level `treatment_index` of a
/// fitted APOS. Routes through the shared `sandwich_variance`
/// dispatch, so the HC0 / HC1 / HC2 / HC3 relationships are the
/// package-wide ones (see the file header in `sandwich.mbt` and
/// the identities pinned in `expand_v088_test.mbt`).
///
/// The three inputs are the ones the child `DoubleMLAPO` already
/// computed and persisted for its own multiplier bootstrap:
///   - `psi_a` = the regenerated constant `-1` row;
///   - `psi`   = `psi_at(coefs[treatment_index], psi_a, psi_b)` --
///     the per-observation influence function at the fitted
///     coefficient, with `psi_b` the IPW-centred potential-outcome
///     score `g[i] + treated[i] * (y[i] - g[i]) / m[i]`. Uses the
///     package-wide `psi(theta) = theta * psi_a + psi_b` order
///     (`sandwich.mbt` is the authority, not the
///     `psi_a + theta * psi_b` phrasing some DID-family comments
///     use);
///   - `M_inv` = `[[1 / mean(psi_a)]]` = `[[-1.0]]`; only
///     `M_inv[0, 0]^2` enters the variance.
///
/// `n_obs` is the full sample -- the same `n_obs` the child divides
/// by in `var_est` -- and `n_params` is 1: ONE scalar estimand per
/// treatment level, NOT `treatment_levels.length()`. The plausible
/// misreading `k = n_levels` would give `sqrt(n / (n - k))` for
/// HC1 and is ruled out in the test.
///
/// On the IID path `sandwich_se_at(j, HC0) == ses[j]` EXACTLY (see
/// the section comment); on a CLUSTERED fit `ses[j]` is the
/// unit-level cluster-robust SE and the invariant does not hold --
/// use `cluster_sandwich_se_at(j, self.data.cluster_vars)`.
///
/// Preconditions: `self.fitted`,
/// `0 <= treatment_index < treatment_levels.length()`,
/// `mean(psi_a) != 0`.
pub fn DoubleMLAPOS::sandwich_se_at(
  self : DoubleMLAPOS,
  treatment_index : Int,
  kind : SandwichKind,
) -> Double {
  try {
    require(self.fitted)
    let m_inv = self.m_inv_1x1_at(treatment_index)
    let n_obs = self.data.n_obs()
    let psi_b = self.psi_b_row_at(treatment_index)
    let psi_a = self.psi_a_row_at(treatment_index)
    let psi = psi_at(self.coefs[treatment_index], psi_a, psi_b)
    let variance_val = sandwich_variance(kind, psi_a, psi, m_inv, n_obs, 1)
    require(variance_val >= 0.0)
    variance_val.sqrt()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.100.0+: cluster-robust sandwich standard error for treatment
/// level `treatment_index` of a fitted APOS (Arellano 1987,
/// Cameron-Gelbach-Miller 2011). Routes through
/// `cluster_sandwich_variance` with the SAME `psi_a` / `psi` /
/// `M_inv` inputs as the IID `sandwich_se_at` path.
///
/// `DoubleMLData` carries `cluster_vars`, so a clustered fit can
/// pass `self.data.cluster_vars` directly; on the IID constructor
/// path (`cluster_vars = []`) the caller must supply the grouping
/// variable explicitly -- any clustering the application has:
/// region, site, panel unit. With all-singleton clusters the meat
/// degenerates to `sum_i psi[i]^2` and the formula collapses to
/// `sandwich_se_at(j, HC0)`, hence to `ses[j]` on an IID fit.
///
/// NOT equal to the IID HC0 with real clusters, on two counts:
/// the within-cluster cross terms enter the meat, and the
/// denominator is `n_obs` (observations) here while a clustered
/// FIT's `ses[j]` is divided by `n_units`. This is the same
/// row-level-vs-unit-level distinction QTE documents.
///
/// Preconditions: `self.fitted`,
/// `0 <= treatment_index < treatment_levels.length()`,
/// `mean(psi_a) != 0`,
/// `cluster_ids.length() == n_obs`.
pub fn DoubleMLAPOS::cluster_sandwich_se_at(
  self : DoubleMLAPOS,
  treatment_index : Int,
  cluster_ids : Array[Int],
) -> Double {
  try {
    require(self.fitted)
    let m_inv = self.m_inv_1x1_at(treatment_index)
    let n_obs = self.data.n_obs()
    require(cluster_ids.length() == n_obs)
    let psi_b = self.psi_b_row_at(treatment_index)
    let psi_a = self.psi_a_row_at(treatment_index)
    let psi = psi_at(self.coefs[treatment_index], psi_a, psi_b)
    let variance_val = cluster_sandwich_variance(
      psi_a, psi, m_inv, cluster_ids, 1,
    )
    require(variance_val >= 0.0)
    variance_val.sqrt()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.100.0+: returns `coefs[treatment_index]` UNCHANGED -- a
/// documented no-op, not a bias correction. Identical in reasoning
/// to `DoubleMLAPO::bias_corrected_coef` (v0.91.0, the sibling
/// estimator) and to `DoubleMLQTE::bias_corrected_coef_at`;
/// see `DoubleMLPQ::bias_corrected_coef` and
/// `bias_corrected_theta` in `sandwich.mbt` for the full argument.
///
/// `coefs[j]` is the root of the DML moment
/// `f(theta) = E[theta * psi_a + psi_b]` (`var_est.mbt`), so
/// `mean(f(coefs[j]))` is identically zero: the estimating function
/// is orthogonal by construction, and that orthogonality IS what
/// makes the estimator consistent. Nothing computable from the
/// fitted scores is a bias estimate for this class of estimator, so
/// this accessor reports the uncorrected point estimate rather than
/// a number that merely looks like a correction.
///
/// The pre-v0.91.0 form `coef + mean(psi_b - coef * psi_a)` is
/// that vector at `-coef`, NOT at `coef`; since
/// `coef = -mean_b / mean_a` its mean is
/// `mean_b - coef * mean_a = -2 * coef * mean_a`, so the accessor
/// returned `coef * (1 - 2 * mean(psi_a))` -- exactly `3 * coef`
/// when `mean(psi_a) = -1` (APO's case). That is not a bias
/// estimate.
///
/// The method is per level, matching the rest of the v0.100.0
/// APOS API.
///
/// Preconditions: `self.fitted`,
/// `0 <= treatment_index < coefs.length()`.
pub fn DoubleMLAPOS::bias_corrected_coef_at(
  self : DoubleMLAPOS,
  treatment_index : Int,
) -> Double {
  try {
    require(self.fitted)
    require(self.coefs.length() > 0)
    require(treatment_index >= 0)
    require(treatment_index < self.coefs.length())
    self.coefs[treatment_index]
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Per-level multiplier bootstrap for `DoubleMLAPOS`. Each
/// treatment level's child `DoubleMLAPO` is re-fit (deterministic
/// given `seed`) and its `bootstrap(...)` invoked; the per-level
/// `boot_t_stat` arrays are concatenated into a length-`n_levels`
/// `Array[Array[Double]]` and also written to `self.boot_t_stat`.
///
/// `method_name` selects the multiplier distribution: `"normal"`
/// (default), `"Bayes"`, `"wild"` — see `DoubleMLAPO::bootstrap`.
/// `n_rep_boot` defaults to 500; `seed` defaults to 2024.
pub fn DoubleMLAPOS::bootstrap(
  self : DoubleMLAPOS,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLAPOS {
  try {
    require(self.fitted)
    require(
      method_name == "normal" || method_name == "Bayes" || method_name == "wild",
    )
    require(n_rep_boot >= 2)
    let n_levels = self.treatment_levels.length()
    let per_level : Array[Array[Double]] = Array::make(n_levels, [])
    for j = 0; j < n_levels; j = j + 1 {
      let child = DoubleMLAPO::new(
        self.data,
        treatment_level=self.treatment_levels[j],
        n_folds=self.n_folds,
        n_rep=self.n_rep,
        seed=self.seed,
        propensity_clip=self.propensity_clip,
        ml_g=self.ml_g,
        ml_m=self.ml_m,
      )
      let fitted_child = child.fit()
      let booted = fitted_child.bootstrap(method_name~, n_rep_boot~, seed~)
      per_level[j] = booted.boot_t_stat
    }
    {
      ..self,
      boot_t_stat: per_level,
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
/// Per-level Wald confidence intervals `(coef - z * se, coef + z * se)`
/// for `DoubleMLAPOS`. Returns one `(lo, hi)` tuple per treatment
/// level, in user-supplied order. `level` defaults to 0.95 (z =
/// 1.959963984540054 for the standard normal).
pub fn DoubleMLAPOS::confint(
  self : DoubleMLAPOS,
  level? : Double = 0.95,
  joint? : Bool = false,
) -> Array[(Double, Double)] {
  try {
    require(self.fitted)
    require(level > 0.0 && level < 1.0)
    if joint {
      require(self.boot_t_stat.length() > 0)
    }
    let alpha = 1.0 - level
    let mut z = norm_ppf(1.0 - alpha / 2.0)
    let n_levels = self.treatment_levels.length()
    let out : Array[(Double, Double)] = Array::make(n_levels, (0.0, 0.0))
    if joint {
      // Joint critical value: (1 - alpha) quantile of max |t|
      // over the n_levels t-statistics per bootstrap rep.
      // `boot_t_stat : Array[Array[Double]]` of length
      // `n_levels`; each per-level array is length
      // `n_rep_boot`.
      let n_boot = self.n_rep_boot
      let max_t_arr : Array[Double] = Array::make(n_boot, 0.0)
      for b = 0; b < n_boot; b = b + 1 {
        let mut mx = 0.0
        for j = 0; j < n_levels; j = j + 1 {
          let per_level = self.boot_t_stat[j]
          let t : Double = per_level[b]
          let abs_t : Double = if t < 0.0 { -t } else { t }
          if abs_t > mx {
            mx = abs_t
          }
        }
        max_t_arr[b] = mx
      }
      // Inline empirical_quantile (insertion sort, no helper).
      max_t_arr.sort()
      let idx = ((n_boot - 1).to_double() * (1.0 - alpha)).to_int()
      z = max_t_arr[idx]
    }
    for j = 0; j < n_levels; j = j + 1 {
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
/// Per-level `boot_t_stat` accessors (v0.63.0+).
pub fn DoubleMLAPOS::boot_t_stats(self : DoubleMLAPOS) -> Array[Array[Double]] {
  try {
    require(self.fitted)
    self.boot_t_stat
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLAPOS::boot_method(self : DoubleMLAPOS) -> String {
  self.boot_method
}

///|
pub fn DoubleMLAPOS::n_rep_boot(self : DoubleMLAPOS) -> Int {
  self.n_rep_boot
}

///|
pub fn DoubleMLAPOS::boot_seed(self : DoubleMLAPOS) -> Int {
  self.boot_seed
}

///|
/// v0.49.0: whether `fit` has been called.
pub fn DoubleMLAPOS::fitted(self : DoubleMLAPOS) -> Bool {
  self.fitted
}

///|
/// v0.49.0: causal contrasts between the requested treatment levels
/// and the supplied reference level(s). Returns one
/// `Array[Double]` of length `2 * treatment_levels.length() - 1`
/// per reference level: the ref-level slot is a single `0.0` (its
/// contrast is trivially zero), and every other slot is a
/// `(delta, se)` pair where `delta = coefs[i] - coefs[ref_idx]`
/// and `se = sqrt(se[i]^2 + se[ref_idx]^2)`. `ref_idx` is the
/// position of the reference level in `treatment_levels`. The
/// layout is interleaved (`[0.0, delta_0, se_0, delta_1, se_1, ...]`
/// for a 2-level input) rather than a `[(level, coef, se), ...]`
/// table — see `apo_test.mbt::apos_causal_contrast_with_reference`
/// for the actual indices.
///
/// The SE of each contrast is computed via the standard
/// `var(psi_a) + var(psi_b) - 2*cov(psi_a, psi_b)` style
/// approximation; for v0.49.0 we take the conservative
/// `sqrt(se_a^2 + se_b^2)` route (same as the upstream
/// `causal_contrast` summary table), which is exact when the
/// per-level psi_a and psi_b are independent across levels
/// (true under stratified kfold with disjoint train indices).
pub fn DoubleMLAPOS::causal_contrast(
  self : DoubleMLAPOS,
  reference_levels : Array[Double],
) -> Array[Array[Double]] {
  // v0.49.0: pre-condition check is local; ref_indices is built
  // up in the same scope that consumes it. `abort` (not raise) is
  // used so the function signature stays clean.
  if !self.fitted {
    abort("precondition failed at DoubleMLAPOS::causal_contrast: not fitted")
  }
  if reference_levels.length() < 1 {
    abort(
      "precondition failed at DoubleMLAPOS::causal_contrast: reference_levels is empty",
    )
  }
  let ref_indices : Array[Int] = []
  for r = 0; r < reference_levels.length(); r = r + 1 {
    let ref_lvl = reference_levels[r]
    let mut found = false
    for i = 0; i < self.treatment_levels.length(); i = i + 1 {
      if self.treatment_levels[i] == ref_lvl {
        ignore(ref_indices.push(i))
        found = true
        break
      }
    }
    if !found {
      abort(
        "DoubleMLAPOS::causal_contrast: reference_level " +
        ref_lvl.to_string() +
        " is not in treatment_levels",
      )
    }
  }
  let results : Array[Array[Double]] = []
  for r = 0; r < ref_indices.length(); r = r + 1 {
    let ref_idx = ref_indices[r]
    let row : Array[Double] = []
    for i = 0; i < self.treatment_levels.length(); i = i + 1 {
      if i == ref_idx {
        ignore(row.push(0.0))
      } else {
        // delta = coef_i - coef_ref, se = sqrt(se_i^2 + se_ref^2)
        let delta = self.coefs[i] - self.coefs[ref_idx]
        let se = (self.ses[i] * self.ses[i] +
        self.ses[ref_idx] * self.ses[ref_idx]).sqrt()
        ignore(row.push(delta))
        ignore(row.push(se))
      }
    }
    results.push(row)
  }
  results
}

///|
/// v0.68.0+: per-level Cinelli & Hazlett (2020)
/// omitted-variable bias analysis for `DoubleMLAPOS`.
/// Re-fits a child `DoubleMLAPO` at each treatment level
/// and delegates to its `sensitivity_analysis(...)`. The
/// per-level `SensitivityResult` is returned in
/// user-supplied order; cross-level aggregation (e.g. for
/// a joint sensitivity bound) is the caller's
/// responsibility. Mirrors the `DoubleMLAPOS::bootstrap`
/// pattern (re-fit each child, capture per-level
/// results).
pub fn DoubleMLAPOS::sensitivity_analysis(
  self : DoubleMLAPOS,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> Array[SensitivityResult] raise {
  require(self.fitted)
  let n_levels = self.treatment_levels.length()
  let out : Array[SensitivityResult] = Array::make(n_levels, {
    rv: 0.0,
    sigma2: 0.0,
    nu2: 0.0,
    cf_y: 0.0,
    cf_d: 0.0,
    max_bias: 0.0,
  })
  for j = 0; j < n_levels; j = j + 1 {
    let child = DoubleMLAPO::new(
      self.data,
      treatment_level=self.treatment_levels[j],
      n_folds=self.n_folds,
      n_rep=self.n_rep,
      seed=self.seed,
      propensity_clip=self.propensity_clip,
      ml_g=self.ml_g,
      ml_m=self.ml_m,
    )
    out[j] = child.fit().sensitivity_analysis(cf_y~, cf_d~)
  }
  out
}

///|
/// v0.74.0+: cluster-robust analogue of
/// `DoubleMLAPOS::sensitivity_analysis`. Re-fits a child
/// `DoubleMLAPO` at each treatment level and delegates to
/// its `sensitivity_analysis_cluster(...)` so the
/// per-cluster `sigma2_cluster` / `nu2_cluster` are
/// computed against the cluster-summed residuals /
/// `psi_a`. The per-level `SensitivityResult` is returned in
/// user-supplied order; cross-level aggregation (e.g. for a
/// joint cluster-robust sensitivity bound) is the caller's
/// responsibility. Mirrors the IID path
/// (`sensitivity_analysis`) and the cluster-aware
/// `sensitivity_analysis_cluster` on `DoubleMLAPO`.
///
/// `cluster_ids` defaults to `DoubleMLData::cluster_vars`.
pub fn DoubleMLAPOS::sensitivity_analysis_cluster(
  self : DoubleMLAPOS,
  cluster_ids? : Array[Int] = self.data.cluster_vars,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> Array[SensitivityResult] raise {
  require(self.fitted)
  let n_levels = self.treatment_levels.length()
  let out : Array[SensitivityResult] = Array::make(n_levels, {
    rv: 0.0,
    sigma2: 0.0,
    nu2: 0.0,
    cf_y: 0.0,
    cf_d: 0.0,
    max_bias: 0.0,
  })
  for j = 0; j < n_levels; j = j + 1 {
    let child = DoubleMLAPO::new(
      self.data,
      treatment_level=self.treatment_levels[j],
      n_folds=self.n_folds,
      n_rep=self.n_rep,
      seed=self.seed,
      propensity_clip=self.propensity_clip,
      ml_g=self.ml_g,
      ml_m=self.ml_m,
    )
    out[j] = child
      .fit()
      .sensitivity_analysis_cluster(cluster_ids~, cf_y~, cf_d~)
  }
  out
}
