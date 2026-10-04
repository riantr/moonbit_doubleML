///|
/// Double / debiased machine learning estimator for the partially
/// linear regression model
///
///     Y = D * theta_0 + g_0(X) + zeta,    E[zeta | D, X] = 0
///     D = m_0(X) + V,                      E[V | X] = 0
///
/// with the *partialling out* score
///
///     psi_a(theta) = -(D - m_hat)^2,
///     psi_b(theta) =  (D - m_hat) * (Y - l_hat),
///     psi(theta)   =  theta * psi_a + psi_b
///
/// where `l_hat = E_hat[Y | X]` and `m_hat = E_hat[D | X]` are obtained
/// from a `LinearRegression` learner (or any other `Learner`) trained
/// out-of-fold via K-fold cross-fitting.
///
/// The point estimate is
///
///     theta_hat = -mean(psi_b) / mean(psi_a)
///               = mean((D - m_hat)(Y - l_hat)) / mean((D - m_hat)^2).
///
/// The variance is estimated following `doubleml.utils._estimation._var_est`
/// (non-cluster case):
///
///     J  = mean(psi_a)              # expected derivative of psi w.r.t. theta
///     gamma = mean(psi(theta_hat)^2)
///     sigma2 = gamma / (J^2 * n)
///     se = sqrt(sigma2).
///
/// The implementation supports only the `partialling out` score and a
/// single treatment. It is intentionally minimal — see the README for
/// the matrix of features covered relative to the upstream package.
pub struct DoubleMLPLR {
  data : DoubleMLData
  // injected learner types (v0.54.0+): separate per-nuisance so
  // l-step and m-step can use different model families
  // (e.g. OLS for l, random forest for m). Both default to a
  // fresh `LinearRegression`; can be overridden per-fit via
  // `DoubleMLPLR::fit`'s labeled params.
  learner_l : LearnerDispatch
  learner_m : LearnerDispatch
  n_folds : Int
  n_rep : Int
  seed : Int
  // cross-fitted nuisance predictions
  l_hat : Array[Double]
  m_hat : Array[Double]
  // point estimate, standard error
  coef : Double
  se : Double
  fitted : Bool
  // v0.61.0+: per-observation influence function components
  // `theta * psi_a[i] + psi_b[i]` for the multiplier bootstrap.
  // Populated by `fit(...)` (and re-cleared on re-fit). Length `n_obs`.
  psi_a : Array[Double]
  psi_b : Array[Double]
  // v0.61.0+: multiplier bootstrap state. `boot_t_stat` is a
  // length-`n_rep_boot` array of t-statistics for `coef`.
  // Populated by `bootstrap(...)`; empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
  // v0.58.0+: populated by `DoubleMLPLR::tune(...)` with the
  // chosen candidate and per-candidate scores. `None` for models
  // built via `DoubleMLPLR::new(...)` or re-fit via
  // `DoubleMLPLR::fit(...)` (a re-fit discards the prior tune
  // history because the nuisance learners may have changed).
  tune_result : TuneResult?
  // v0.80.0+: memoization state. v0.82.0+ extends to PLR.
  // `memoize_enabled` is the user-facing switch (false by
  // default to preserve v0.79.0 behavior bit-for-bit). When
  // true, `fit()` caches the last repetition's nuisance
  // predictions in `fit_cache` and reuses them on the next
  // call when the data fingerprint, fold split, and learner
  // configuration are unchanged. Mirrors the IRM plumbing.
  memoize_enabled : Bool
  fit_cache : FitCache
} derive(Debug)

///|
pub extend DoubleMLPLR with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLPLR::new(
  data : DoubleMLData,
  learner_l? : LearnerDispatch = LearnerDispatch::linear_regression(),
  learner_m? : LearnerDispatch = LearnerDispatch::linear_regression(),
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
) -> DoubleMLPLR {
  try {
    require(n_folds >= 2)
    require(n_folds <= data.n_obs())
    require(n_rep >= 1)
    {
      data,
      learner_l,
      learner_m,
      n_folds,
      n_rep,
      seed,
      l_hat: Array::make(data.n_obs(), 0.0),
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
      tune_result: None,
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
/// Number of observations.
pub fn DoubleMLPLR::n_obs(self : DoubleMLPLR) -> Int {
  self.data.n_obs()
}

///|
/// Number of features (covariate columns).
pub fn DoubleMLPLR::n_features(self : DoubleMLPLR) -> Int {
  self.data.n_features()
}

///|
/// Fitted causal parameter.
pub fn DoubleMLPLR::coef(self : DoubleMLPLR) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Standard error of the causal parameter, computed via the
/// DML variance formula.
pub fn DoubleMLPLR::se(self : DoubleMLPLR) -> Double {
  try {
    require(self.fitted)
    self.se
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// 95% Wald-style confidence interval `[coef - 1.96*se, coef + 1.96*se]`.
/// v0.67.0+: `joint` is a no-op for single-theta estimators
/// (the joint CI equals the Wald CI for a single parameter);
/// accepted for API parity with the multi-theta estimators
/// (APOS / QTE / DIDCS) and the IRM-style cluster path.
pub fn DoubleMLPLR::confint(
  self : DoubleMLPLR,
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
/// Cross-fitted nuisance predictions for the outcome (length `n`).
pub fn DoubleMLPLR::predictions_l(self : DoubleMLPLR) -> Array[Double] {
  self.l_hat
}

///|
/// Cross-fitted nuisance predictions for the treatment (length `n`).
pub fn DoubleMLPLR::predictions_m(self : DoubleMLPLR) -> Array[Double] {
  self.m_hat
}

///|
/// Accessor for the `tune_result` populated by
/// `DoubleMLPLR::tune(...)` (v0.58.0+). Returns `None` for
/// models built via `DoubleMLPLR::new(...)` or re-fit via
/// `DoubleMLPLR::fit(...)` (a re-fit discards the prior tune
/// history because the nuisance learners may have changed).
///
/// Inspect the returned `TuneResult` to see which `(learner_l,
/// learner_m)` combination won under the chosen scoring rule,
/// what the best score was, and the per-candidate score vector
/// (in `param_set` order).
pub fn DoubleMLPLR::tune_result(self : DoubleMLPLR) -> TuneResult? {
  self.tune_result
}

///|
/// v0.82.0+: turn on memoization for subsequent `fit()` calls.
/// When enabled, `fit()` will cache the per-observation nuisance
/// predictions and the fold partition and skip the
/// cross-fit nuisance fit on a repeat call whose data +
/// learner fingerprint is unchanged. Returns a new
/// `DoubleMLPLR` with the flag set (the struct is immutable;
/// the cache itself is populated by the next `fit()` call).
///
/// Default is OFF. When OFF, every `fit()` call runs the full
/// cross-fit and the cache is neither read nor written, so
/// v0.81.0 callers see byte-identical output.
pub fn DoubleMLPLR::enable_memoize(self : DoubleMLPLR) -> DoubleMLPLR {
  { ..self, memoize_enabled: true, }
}

///|
/// v0.82.0+: turn off memoization. Same immutability contract
/// as `enable_memoize()`. After this, `fit()` will not read or
/// write the cache; the existing `fit_cache` is preserved on
/// the returned struct (call `clear_cache()` to drop it).
pub fn DoubleMLPLR::disable_memoize(self : DoubleMLPLR) -> DoubleMLPLR {
  { ..self, memoize_enabled: false, }
}

///|
/// v0.82.0+: drop any cached nuisance predictions and fold
/// assignment. Useful when the caller wants to free memory or
/// force the next `fit()` to recompute from scratch.
pub fn DoubleMLPLR::clear_cache(self : DoubleMLPLR) -> DoubleMLPLR {
  { ..self, fit_cache: FitCache::empty(), }
}

///|
/// v0.82.0+: `true` iff `fit_cache` holds at least one cached
/// observation (i.e. at least one prior `fit()` call with
/// `memoize_enabled = true` has populated the cache). Note
/// that the cache may still be stale relative to the current
/// data + learner configuration -- check `memoize_enabled`
/// before assuming a cache hit.
pub fn DoubleMLPLR::has_cache(self : DoubleMLPLR) -> Bool {
  !self.fit_cache.is_empty()
}

///|
/// Run the DML estimation. The default learner is a closed-form
/// `LinearRegression`; a different `Learner` can be supplied for
/// experiments. The result is stored on the object and the object is
/// returned for chaining.
///
/// Per-repetition behaviour: each repetition `r` cross-fits the
/// nuisances from its own folds (seed `self.seed + r`), computes its
/// own `(theta_r, se_r)` from the `mean(psi_a) / mean(psi_b)` form,
/// and the two arrays are then aggregated by `aggregate_coef_se`
/// (median of thetas, then SE from the median of
/// `(theta_r + 1.96 * se_r)`). For `n_rep == 1` the aggregator
/// returns the single `(theta_1, se_1)` exactly, so the byte-equality
/// with the previous "average then estimate" implementation is
/// preserved. The `predictions_l/m` accessors return the nuisances
/// from the *last* repetition (the conventional choice in upstream
/// `doubleml`), not a cross-rep average.
///
/// When `self.data` carries a non-empty `cluster_vars` vector, the
/// estimator routes through the *clustered* DML path: folds are
/// drawn over the unique cluster ids, every row of a unit stays
/// on the same side of every split, the causal parameter is the
/// fold-weighted ratio of cluster score sums, and the SE is the
/// unit-level cluster-robust estimator (mirrors upstream's
/// `_var_est` one-cluster-variable branch and
/// `LinearScoreMixin._est_coef` cluster branch).
///
/// `score` selects the DML nuisance score (v0.55.0+):
///   - `"partialling-out"` (default, v0.54.0): the standard
///     partialling-out DML score `psi_a = -(d - m_hat)^2`,
///     `psi_b = (d - m_hat) * (y - l_hat)`. This is what
///     upstream calls `DoubleMLPLR._score_partialling_out`.
///     Works without `DoubleMLData.z` (the v0.54.0 default).
///   - `"IV-type"` / `"iv-type"` (v0.55.0+): the
///     instrument-residual-maker DML score
///     `psi_a = -z * (d - m_hat)`,
///     `psi_b =  z * (y - l_hat)`,
///     where `z = DoubleMLData::new(..., z=...)`. Requires
///     `data.is_instrument_data()` to be true; calling `fit`
///     with this score and no instrument aborts with a
///     descriptive message naming the missing `z=` arg.
///

///|
/// Per-row DML score elements for `DoubleMLPLR`. v0.55.0:
/// factored out of `DoubleMLPLR::fit` / `fit_cluster` so the
/// `"partialling-out"` and `"IV-type"` score branches share
/// one helper.
///
/// `partialling-out` (the v0.54.0 default):
///   psi_a[i] = -v_hat[i] * v_hat[i]
///   psi_b[i] =  v_hat[i] * u_hat[i]
///
/// `IV-type` (v0.55.0+; requires instrument vector Z):
///   psi_a[i] = -z[i] * v_hat[i]
///   psi_b[i] =  z[i] * u_hat[i]
///
/// where `v_hat = d - m_hat`, `u_hat = y - l_hat`. The IV-type
/// score is the standard "instrumental residual-maker" DML
/// score (Chernozhukov et al. 2018): substituting `z` for `d`
/// in the partialling-out formula makes the score exogenous
/// from `X` (via the exclusion restriction), recovering a
/// consistent IV-style theta even when the treatment is
/// endogenous.
///
/// The caller must validate that `z.length() == n` (for IV-type)
/// or that `z.length() == 0` (the v0.54.0 default,
/// partialling-out path) before invoking this helper. No
/// precondition check here — the caller has richer error
/// context (e.g. names the offending `DoubleMLPLR::fit`
/// call site).
fn plr_score_elements(
  n : Int,
  v_hat : Array[Double],
  u_hat : Array[Double],
  z : Array[Double],
  score : String,
) -> (Array[Double], Array[Double]) {
  let psi_a : Array[Double] = Array::make(n, 0.0)
  let psi_b : Array[Double] = Array::make(n, 0.0)
  if score == "iv-type" || score == "IV-type" {
    // IV-type: z[i] is the instrument (length n is caller's
    // responsibility; the array index below would panic if z
    // is shorter). The default `z = []` (length 0) on
    // DoubleMLData never reaches here because the caller
    // pre-validates with `require(z.length() == n)`.
    for i = 0; i < n; i = i + 1 {
      psi_a[i] = -z[i] * v_hat[i]
      psi_b[i] = z[i] * u_hat[i]
    }
  } else {
    // partialling-out (default): v_hat[i] is the treatment residual.
    for i = 0; i < n; i = i + 1 {
      psi_a[i] = -v_hat[i] * v_hat[i]
      psi_b[i] = v_hat[i] * u_hat[i]
    }
  }
  (psi_a, psi_b)
}

///|
/// The `learner_l` / `learner_m` labeled params accept any
/// `LearnerDispatch` (defaults to the constructor-set values,
/// i.e. a fresh `LinearRegression`). Per-fit overrides let
/// callers swap in alternative nuisance estimators
/// (`ConstantLearner`, `NoopLearner`, ...) without rebuilding
/// the `DoubleMLPLR` instance.
pub fn DoubleMLPLR::fit(
  self : DoubleMLPLR,
  learner_l? : LearnerDispatch = self.learner_l,
  learner_m? : LearnerDispatch = self.learner_m,
  max_attempts? : Int = 1,
  score? : String = "partialling-out",
  tune_result? : TuneResult? = None,
) -> DoubleMLPLR {
  try {
    require(
      score == "partialling-out" || score == "iv-type" || score == "IV-type",
    )
    require(max_attempts >= 1)
    // v0.55.0: real IV-type branch. Caller must have built
    // `DoubleMLData` with a non-empty `z` vector of length `n_obs`.
    // The require below is the v0.48.0+ cascade: false here
    // throws `PreconditionError::Violated(loc)` which the outer
    // `try` catches and re-aborts with a descriptive message.
    if score == "iv-type" || score == "IV-type" {
      require(self.data.z.length() == self.n_obs())
    }
    if self.data.is_cluster_data() {
      return self.fit_cluster(
        learner_l~,
        learner_m~,
        max_attempts~,
        score~,
        tune_result~,
      )
    }
    let n = self.n_obs()
    let nrep = self.n_rep
    // v0.82.0+: memoize check. The cache stores the LAST rep's
    // fold assignment and nuisance predictions. We honor the
    // cache only when:
    //   (a) the user opted in (`self.memoize_enabled`),
    //   (b) n_rep == 1 (multi-rep aggregations must run every
    //       rep fresh -- we cannot cache individual rep scores).
    //   (c) `is_valid(...)` matches every dimension of the
    //       data + learner + cluster fingerprint.
    // When memoize_enabled is false (the default), the entire
    // cache code path is skipped so v0.81.0 callers see a
    // byte-identical fit() output.
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
      hash_hyperparams("plr", learner_l, learner_m, 0.0)
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
        "plr",
      )
    let coefs : Array[Double] = Array::make(nrep, 0.0)
    let ses : Array[Double] = Array::make(nrep, 0.0)
    // hold the last rep's predictions; final values land in l_hat / m_hat
    let mut l_pred : Array[Double] = Array::make(n, 0.0)
    let mut m_pred : Array[Double] = Array::make(n, 0.0)
    // Track the LAST rep's fold_ids (for cache write below).
    let mut fold_ids : Array[Int] = []
    for r = 0; r < nrep; r = r + 1 {
      let (l_pred_r, m_pred_r) = if cache_hit && r == nrep - 1 {
        // Reuse the cached LAST-rep predictions.
        let preds = self.fit_cache.predictions
        fold_ids = self.fit_cache.fold_ids
        (preds[0], preds[1])
      } else {
        let folds = kfold(n, self.n_folds, self.seed + r)
        let l_p = cross_fit_predict_dispatch(
          learner_l,
          self.data.x,
          self.data.y,
          folds,
        )
        let m_p = cross_fit_predict_dispatch(
          learner_m,
          self.data.x,
          self.data.d,
          folds,
        )
        // Build the row -> fold_id map for the cache write below.
        let fid : Array[Int] = Array::make(n, 0)
        for f = 0; f < folds.length(); f = f + 1 {
          for i in folds[f].test_indices() {
            fid[i] = f
          }
        }
        if r == nrep - 1 {
          fold_ids = fid
        }
        (l_p, m_p)
      }
      l_pred = l_pred_r
      m_pred = m_pred_r
      // score elements for THIS rep's nuisances only.
      // v0.81.0+: residuals extracted via `vector_subtract` (the
      // partialling-out score `v_hat = d - m_pred` and the outcome
      // residual `u_hat = y - l_pred` are both pure element-wise
      // subtracts, the textbook case for the named building block).
      let v_hat = vector_subtract(self.data.d, m_pred)
      let u_hat = vector_subtract(self.data.y, l_pred)
      let (psi_a, psi_b) = plr_score_elements(
        n,
        v_hat,
        u_hat,
        self.data.z,
        score,
      )
      // point estimate + variance come from the shared DML formula
      let (coef_r, se_r) = var_est(psi_a, psi_b)
      coefs[r] = coef_r
      ses[r] = se_r
    }
    // last iteration's predictions are now in l_pred / m_pred
    let (coef, se) = aggregate_coef_se(coefs, ses)
    // v0.61.0: per-observation influence function for the
    // multiplier bootstrap. Recompute `psi_a / psi_b` from the
    // last rep's cross-fitted nuisances so the stored arrays
    // align with `l_hat` / `m_hat` and `coef` (matches the
    // v0.20.0+ `DoubleMLDIDCrossSection::fit` convention).
    // v0.81.0+: residuals via `vector_subtract` (same vectorised
    // pattern as the per-rep score loop above).
    let v_hat_last = vector_subtract(self.data.d, m_pred)
    let u_hat_last = vector_subtract(self.data.y, l_pred)
    let (psi_a, psi_b) = plr_score_elements(
      n,
      v_hat_last,
      u_hat_last,
      self.data.z,
      score,
    )
    // v0.82.0+: when memoize is on and the cache missed, write
    // the freshly-computed fold_ids + nuisances to the cache.
    let next_cache = if memoize && !cache_hit && nrep == 1 {
      FitCache::from_fit(
        fold_ids,
        [l_pred, m_pred],
        self.seed,
        self.n_folds,
        nrep,
        n,
        data_hash,
        hparams_hash,
        cluster_hash,
        "plr",
      )
    } else {
      self.fit_cache
    }
    {
      data: self.data,
      learner_l,
      learner_m,
      n_folds: self.n_folds,
      n_rep: self.n_rep,
      seed: self.seed,
      l_hat: l_pred,
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
      // honor the caller's tune_result override (set by
      // `DoubleMLPLR::tune`); default `None` preserves v0.57.0
      // behavior for plain `fit(...)` callers.
      tune_result,
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
/// Clustered-DML path for `DoubleMLPLR`. Folds partition whole
/// units (`kfold` on unique cluster ids, expanded to row folds);
/// coefficient is the fold-weighted ratio of cluster score sums
/// (`est_coef_cluster`); variance is unit-level cluster-robust
/// (`var_est_cluster`). `psi_a = -(d - m_hat)^2` and
/// `psi_b = (d - m_hat) * (y - l_hat)` are the per-row score
/// elements — the same ones the row-level path uses. The cluster
/// path differs from the row-level path only in the fold
/// partition and the two aggregation steps; the per-row score
/// elements are identical, so a single nuisances cross-fit
/// (with cluster-respecting folds) feeds both paths.
fn DoubleMLPLR::fit_cluster(
  self : DoubleMLPLR,
  learner_l~ : LearnerDispatch,
  learner_m~ : LearnerDispatch,
  max_attempts? : Int = 1,
  score? : String = "partialling-out",
  tune_result? : TuneResult? = None,
) -> DoubleMLPLR {
  try {
    require(max_attempts >= 1)
    // v0.55.0: real IV-type branch. Caller must have built
    // `DoubleMLData` with a non-empty `z` vector. Same
    // require-cascade as `fit()` for the v0.48.0+
    // `PreconditionError::Violated(loc)` -> `abort(...)` flow.
    if score == "iv-type" || score == "IV-type" {
      require(self.data.z.length() == self.n_obs())
    }
    let cluster = self.data.cluster_vars
    let n = self.n_obs()
    let nrep = self.n_rep
    let uniq = unique_units(cluster)
    let n_units = uniq.length()
    require(self.n_folds <= n_units)
    // row → unit-position map (linear scan, panels are small in
    // tests and demos). v0.36.0: build_row_unit_map raises
    // ClusterDataError::MissingUnit on a malformed cluster vector;
    // we catch and re-abort to preserve pre-v0.36.0 behavior.
    let row_unit = build_row_unit_map(cluster, uniq) catch {
      ClusterDataError::MissingUnit(g) =>
        abort(
          "expand_unit_folds_to_rows: row without a unit id (unit_id=" +
          g.to_string() +
          ")",
        )
    }
    // ascending row indices per unit
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
    let mut m_pred : Array[Double] = Array::make(n, 0.0)
    for r = 0; r < nrep; r = r + 1 {
      // v0.40.0: retry loop on J-floor. Each retry uses a different
      // fold split (seed = self.seed + r + attempt*nrep) so the
      // fold-mean J is different. If all max_attempts attempts hit
      // the J-floor for this rep, we record the failure and the
      // post-loop re-aborts (preserves pre-v0.40.0 behavior when
      // max_attempts=1).
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
          learner_l,
          self.data.x,
          self.data.y,
          folds_row,
        )
        m_pred = cross_fit_predict_dispatch(
          learner_m,
          self.data.x,
          self.data.d,
          folds_row,
        )
        // v0.81.0+: residuals extracted via `vector_subtract` (matches
        // the IID `fit()` vectorisation above; the cluster retry
        // loop can re-enter this body so keeping the body
        // branchless -- i.e. no per-iteration scalar arithmetic --
        // avoids cross-attempt numerical drift).
        let v_hat = vector_subtract(self.data.d, m_pred)
        let u_hat = vector_subtract(self.data.y, l_pred)
        // v0.55.0: route through the shared score helper so the
        // IV-type branch (cluster-aware variant) uses the same
        // psi_a / psi_b formula as `DoubleMLPLR::fit`.
        let (psi_a, psi_b) = plr_score_elements(
          n,
          v_hat,
          u_hat,
          self.data.z,
          score,
        )
        // The cluster helper can raise VarEstClusterError::JTooSmall
        // on a fold split where mean(psi_deriv) lands below 1e-6.
        // The catch arm below records the failure and tries again
        // with the next attempt's seed; we don't re-abort here
        // because v0.40.0 adds max_attempts retries.
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
            // Sentinel (0.0, 0.0): the catch arm's return value is
            // never observed because we re-enter the while loop
            // (succeeded stays false) until attempt == max_attempts.
            // The post-loop check `if !succeeded` then re-aborts.
            (0.0, 0.0)
          }
        }
        // If we got here without the catch arm running, the try
        // expression returned (t, s) and we succeeded. The catch
        // arm's (0.0, 0.0) is never observed because succeeded
        // is still false in that branch (we set attempt += 1 but
        // didn't reach this code).
        theta_r = t
        se_r = s
        succeeded = true
      }
      if !succeeded {
        // All max_attempts attempts hit the J-floor; give up and
        // re-abort (preserves pre-v0.40.0 behavior when
        // max_attempts=1).
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
    // arrays align with `l_hat` / `m_hat` and `coef`.
    // v0.81.0+: residuals via `vector_subtract` (matches the IID
    // `fit()` vectorisation).
    let v_hat_last = vector_subtract(self.data.d, m_pred)
    let u_hat_last = vector_subtract(self.data.y, l_pred)
    let (psi_a, psi_b) = plr_score_elements(
      n,
      v_hat_last,
      u_hat_last,
      self.data.z,
      score,
    )
    {
      data: self.data,
      learner_l,
      learner_m,
      n_folds: self.n_folds,
      n_rep: self.n_rep,
      seed: self.seed,
      l_hat: l_pred,
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
      // cluster path: honor caller's tune_result override
      // (set by `DoubleMLPLR::tune`); default `None` preserves
      // v0.57.0 behavior for plain `fit(...)` callers.
      tune_result,
      // v0.82.0+: cluster path does not currently consume the
      // memoization cache (the J-floor retry loop can rewrite
      // the fold assignment on a per-attempt basis). Persist
      // the flags so a subsequent non-cluster `fit()` still
      // honors memoize.
      memoize_enabled: self.memoize_enabled,
      fit_cache: self.fit_cache,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.61.0+: multiplier bootstrap for `DoubleMLPLR`. The
/// per-observation influence function is
///
///   psi[i] = theta * psi_a[i] + psi_b[i]
///
/// (computed at the fitted `coef` from the last rep's
/// cross-fitted nuisances `l_hat` / `m_hat`). Draws
/// `n_rep_boot` weight vectors of length `n_obs` from the
/// chosen multiplier distribution, and returns a fitted model
/// with `boot_t_stat[b] = sum_i w[b, i] * psi[i] /
/// (sqrt(n) * se_psi)` populated where
/// `se_psi = sqrt(mean(psi^2))`.
///
/// `method_name` selects the multiplier distribution:
///   - `"normal"` (default): `w[i] ~ N(0, 1)`. Matches the
///     upstream `bootstrap(method="normal")` default.
///   - `"Bayes"`: `w[i] = exp(1) - 1` (mean 0, var 1).
///   - `"wild"`: `w[i] = x[i] / sqrt(2) + (y[i]^2 - 1) / 2`
///     with `x, y ~ N(0, 1)`. Robust to heteroskedasticity.
///
/// Calling `bootstrap` requires the model to be fitted; calling
/// on an un-fit model aborts with `PreconditionError`. The
/// helper is `did_bootstrap_t_stat` (v0.55.0 extracted from
/// `DoubleMLDIDCrossSection::bootstrap`); PLR is the
/// `n_thetas=1` case with `psi[i] = psi_at(coef, psi_a, psi_b)[i]`.
pub fn DoubleMLPLR::bootstrap(
  self : DoubleMLPLR,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLPLR {
  try {
    require(self.fitted)
    require(
      method_name == "normal" || method_name == "Bayes" || method_name == "wild",
    )
    require(n_rep_boot >= 2)
    let n = self.n_obs()
    // Draw weights. Shape: (n_rep_boot, n_obs).
    // v0.37.0+: draw_bootstrap_weights raises
    // BootstrapMethodError on an unknown method; catch and
    // re-abort to preserve pre-v0.37.0 process-death behavior.
    let weights = draw_bootstrap_weights(method_name, n_rep_boot, n, seed) catch {
      BootstrapMethodError::UnknownMethod(m) =>
        abort(
          "draw_bootstrap_weights: unknown method (set in DoubleMLPLR::bootstrap): " +
          m,
        )
    }
    // Compute psi = psi_at(coef, psi_a, psi_b) and
    // ss_psi = sum(psi[i]^2) once. `psi_a` / `psi_b` were
    // populated by `fit(...)` from the last rep's nuisances
    // (matching `l_hat` / `m_hat`); the bootstrap is run at the
    // already-fitted `coef`, no re-estimation.
    let psi = psi_at(self.coef, self.psi_a, self.psi_b)
    let mut ss_psi = 0.0
    for i = 0; i < n; i = i + 1 {
      let psi_i = psi[i]
      ss_psi = ss_psi + psi_i * psi_i
    }
    let n_d = n.to_double()
    let se_psi = (ss_psi / n_d).sqrt()
    if se_psi <= 0.0 {
      // Degenerate: psi sums to 0 (constant IF). Cannot divide.
      // Return zeros (matches the DIDCrossSection convention).
      let boot_t_stat_zero : Array[Double] = Array::make(n_rep_boot, 0.0)
      return {
        ..self,
        boot_t_stat: boot_t_stat_zero,
        boot_method: method_name,
        n_rep_boot,
        boot_seed: seed,
      }
    }
    // v0.55.0 extracted helper. PLR is `n_thetas=1`:
    // `psi_flat = [psi]`, `se_flat = [se_psi]`.
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
/// v0.66.0+: Cinelli & Hazlett (2020) omitted-variable bias
/// analysis. Outcome residual is `y - l_hat`; the
/// Riesz-representer variance is `mean(psi_a^2)` where
/// `psi_a = -v^2` for the partialling-out score
/// (`v = d - m_hat`). Routes through the shared
/// `irm_style_sensitivity` helper (see sensitivity.mbt).
///
/// `cf_y` / `cf_d` are the confounding-strength upper bounds
/// (defaults 0.05) and are passed through to the result for
/// upstream parity.
pub fn DoubleMLPLR::sensitivity_analysis(
  self : DoubleMLPLR,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let l_hat = self.predictions_l()
  // v0.81.0+: residual extraction via `vector_subtract` (the
  // PLR sensitivity residual `y - l_hat` is a single pure
  // subtract, the textbook case for the named building block).
  let residuals = vector_subtract(self.data.y, l_hat)
  irm_style_sensitivity(self.coef, residuals, self.psi_a, cf_y, cf_d)
}

///|
/// v0.72.0+: cluster-robust analogue of
/// `DoubleMLPLR::sensitivity_analysis`. Same residual
/// formula (`y - l_hat`) and the same `psi_a` as the IID
/// path; only the variance / bias computation is
/// cluster-aware (see `irm_style_sensitivity_cluster`).
/// `cluster_ids` defaults to `DoubleMLData::cluster_vars`
/// (the optional 5th constructor arg added in v0.55.0); pass
/// an explicit `cluster_ids` to override.
pub fn DoubleMLPLR::sensitivity_analysis_cluster(
  self : DoubleMLPLR,
  cluster_ids? : Array[Int] = self.data.cluster_vars,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let l_hat = self.predictions_l()
  let n = l_hat.length()
  require(cluster_ids.length() == n)
  // v0.81.0+: residual extraction via `vector_subtract` (same
  // pattern as the IID `sensitivity_analysis` path above).
  let residuals = vector_subtract(self.data.y, l_hat)
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
/// fitted PLR. Same shape as `DoubleMLIRM::sandwich_se`
/// but operating on the PLR partialling-out score
/// `psi_a[i] = -v_hat[i]^2`, `psi_b[i] = v_hat[i] *
/// u_hat[i]`. `M_inv = [[1 / mean(psi_a)]]`. The
/// `sandwich_variance_xx` free function in `sandwich.mbt`
/// does the per-observation squared-score accumulation.
///
/// Preconditions: `self.fitted`.
pub fn DoubleMLPLR::sandwich_se(
  self : DoubleMLPLR,
  kind : SandwichKind,
) -> Double {
  try {
    require(self.fitted)
    let n = self.n_obs()
    let psi = psi_at(self.coef, self.psi_a, self.psi_b)
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
/// the fitted PLR. Same shape as
/// `DoubleMLIRM::cluster_sandwich_se`; routes through
/// `cluster_sandwich_variance` with the per-observation
/// PLR `psi_a` (`-v_hat^2`) and the per-observation IF
/// `psi[i] = psi_at(coef, psi_a, psi_b)[i]`.
///
/// Preconditions: `self.fitted`,
/// `cluster_ids.length() == n_obs`.
pub fn DoubleMLPLR::cluster_sandwich_se(
  self : DoubleMLPLR,
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
pub fn DoubleMLPLR::bias_corrected_coef(self : DoubleMLPLR) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
