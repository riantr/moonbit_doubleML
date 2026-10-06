///|
/// Data container for `DoubleMLSSM`. Adds a binary *selection
/// indicator* `s` on top of the usual `x/y/d`. The outcome `y` is
/// observed only when `s = 1`; for `s = 0` the y entry should be
/// ignored.
pub struct DoubleMLSSMData {
  x : Matrix
  y : Array[Double]
  d : Array[Double]
  s : Array[Double]
} derive(Debug)

///|
pub extend DoubleMLSSMData with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLSSMData::new(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  s : Array[Double],
) -> DoubleMLSSMData {
  try {
    require(x.nrows == y.length())
    require(x.nrows == d.length())
    require(x.nrows == s.length())
    { x, y, d, s, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLSSMData::n_obs(self : DoubleMLSSMData) -> Int {
  self.x.rows()
}

///|
pub fn DoubleMLSSMData::n_features(self : DoubleMLSSMData) -> Int {
  self.x.cols()
}

///|
/// Double / debiased machine learning estimator for the *Sample
/// Selection Model* (SSM) of Bia, Huber and Laffers (2023), under the
/// *Missing At Random* (MAR) score with `normalize_ipw = False`.
///
/// The model is
///
///     Y = theta * D + X @ beta * D + U,           E[U | D, X] = 0
///     S = 1{D + gamma Z + X @ beta + V > 0},     E[V | X, D] = 0
///
/// Y is observed only when S = 1. The four cross-fitted nuisances:
///
///     g_d1(X) = E[Y | D = 1, S = 1, X]      (trained on D=1 ∧ S=1,
///                                            features = X only —
///                                            Bug #1 fix: previously
///                                            `pi_hat` was appended as
///                                            an extra feature, which
///                                            leaked the test-fold pi
///                                            into the training fold)
///     g_d0(X) = E[Y | D = 0, S = 1, X]      (trained on D=0 ∧ S=1,
///                                            features = X only)
///     m(X)    = P(D = 1 | X)                 (trained on all obs,
///                                            clipped to [eps, 1 - eps])
///     pi(X, D) = P(S = 1 | D, X)            (trained on (X, D),
///                                            clipped to [eps, 1 - eps])
///
/// Score (un-normalized IPW):
///
///     psi_a = -1
///     psi_b1 = (D == 1) * S * (Y - g_d1) / (m * pi) + g_d1
///     psi_b0 = (D == 0) * S * (Y - g_d0) / ((1 - m) * pi) + g_d0
///     psi_b  = psi_b1 - psi_b0
///
/// Point estimate and variance
///
///     theta_hat = -mean(psi_b) / mean(psi_a) = mean(psi_b)
///     J         = mean(psi_a) = -1
///     gamma     = mean(psi(theta_hat)^2)
///     sigma2    = gamma / (J^2 * n)
///     se        = sqrt(sigma2).
///
/// Note: only the MAR case is implemented; `normalize_ipw = True`
/// and the nonignorable-nonresponse case are out of scope.
pub struct DoubleMLSSM {
  data : DoubleMLSSMData
  n_folds : Int
  n_rep : Int
  seed : Int
  propensity_clip : Double
  // v0.59.0+: injected nuisance learners (replaces the v0.57.0
  // hardcoded `LinearRegression`). Defaults to OLS so v0.57.0
  // callers see byte-identical results.
  ml_g : LearnerDispatch
  ml_m : LearnerDispatch
  pi_hat : Array[Double]
  m_hat : Array[Double]
  g_d1 : Array[Double]
  g_d0 : Array[Double]
  coef : Double
  se : Double
  fitted : Bool
  // v0.64.0+: per-observation influence-function components
  // for the multiplier bootstrap. SSM score:
  //   psi_a[i] = -1                              (constant)
  //   psi_b[i] = psi_b1[i] - psi_b0[i]            (the per-observation IPW score)
  // Populated by `fit(...)` from the last cross-fit repetition's
  // nuisances (`g_d1` / `g_d0` / `m_hat` / `pi_hat`); length
  // `n_obs`.
  psi_a : Array[Double]
  psi_b : Array[Double]
  // v0.64.0+: multiplier bootstrap state. `boot_t_stat` is a
  // length-`n_rep_boot` array of t-statistics for `coef`.
  // Populated by `bootstrap(...)`; empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
  // v0.83.0+: memoization state. `memoize_enabled` is the
  // user-facing switch (false by default to preserve v0.82.0
  // behavior bit-for-bit). When true and `n_rep == 1`, `fit()`
  // caches the LAST rep's `(pi_hat, m_hat, g_d1, g_d0)` plus
  // fold assignment in `fit_cache` and reuses them on the
  // next call when the data fingerprint, fold split, and
  // learner configuration are unchanged. Mirrors the IRM /
  // PLR / CVAR plumbing.
  memoize_enabled : Bool
  fit_cache : FitCache
} derive(Debug)

///|
pub extend DoubleMLSSM with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLSSM::new(
  data : DoubleMLSSMData,
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
  ml_g? : LearnerDispatch = LearnerDispatch::linear_regression(),
  ml_m? : LearnerDispatch = LearnerDispatch::linear_regression(),
) -> DoubleMLSSM {
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
      pi_hat: Array::make(data.n_obs(), 0.0),
      m_hat: Array::make(data.n_obs(), 0.0),
      g_d1: Array::make(data.n_obs(), 0.0),
      g_d0: Array::make(data.n_obs(), 0.0),
      coef: 0.0,
      se: 0.0,
      fitted: false,
      psi_a: Array::make(data.n_obs(), 0.0),
      psi_b: Array::make(data.n_obs(), 0.0),
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
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.83.0+: turn on memoization for subsequent `fit()` calls.
/// When enabled, `fit()` will cache the LAST rep's per-fold
/// nuisance predictions (`pi_hat`, `m_hat`, `g_d1`, `g_d0`) and
/// the fold assignment; on a repeat call whose data + learner
/// fingerprint + fold split is identical, the entire per-fold
/// crossfit is skipped and the cached values feed the
/// psi_a / psi_b / coef / se pipeline.
///
/// `enable_memoize()` is honored only when `n_rep == 1`; for
/// `n_rep > 1` the per-rep cross-fit must run each time (the
/// cache would otherwise need to thread `n_rep` independent
/// per-rep nuisance arrays, which the `FitCache` layout does
/// not accommodate).
///
/// Default is OFF. When OFF, every `fit()` call runs the full
/// cross-fit and the cache is neither read nor written, so
/// v0.82.0 callers see byte-identical output.
pub fn DoubleMLSSM::enable_memoize(self : DoubleMLSSM) -> DoubleMLSSM {
  { ..self, memoize_enabled: true, }
}

///|
/// v0.83.0+: turn off memoization. Same immutability contract
/// as `enable_memoize()`. After this, `fit()` will not read or
/// write the cache; the existing `fit_cache` is preserved on
/// the returned struct (call `clear_cache()` to drop it).
pub fn DoubleMLSSM::disable_memoize(self : DoubleMLSSM) -> DoubleMLSSM {
  { ..self, memoize_enabled: false, }
}

///|
/// v0.83.0+: drop any cached nuisance predictions and fold
/// assignment. Forces the next `fit()` to recompute from
/// scratch.
pub fn DoubleMLSSM::clear_cache(self : DoubleMLSSM) -> DoubleMLSSM {
  { ..self, fit_cache: FitCache::empty(), }
}

///|
/// v0.83.0+: `true` iff `fit_cache` holds at least one cached
/// observation (i.e. at least one prior `fit()` call with
/// `memoize_enabled = true` has populated the cache). Note
/// that the cache may still be stale relative to the current
/// data + learner configuration -- check `memoize_enabled`
/// before assuming a cache hit.
pub fn DoubleMLSSM::has_cache(self : DoubleMLSSM) -> Bool {
  !self.fit_cache.is_empty()
}

///|
pub fn DoubleMLSSM::n_obs(self : DoubleMLSSM) -> Int {
  self.data.n_obs()
}

///|
pub fn DoubleMLSSM::coef(self : DoubleMLSSM) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLSSM::se(self : DoubleMLSSM) -> Double {
  try {
    require(self.fitted)
    self.se
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLSSM::confint(self : DoubleMLSSM) -> (Double, Double) {
  try {
    require(self.fitted)
    let lo = self.coef - 1.96 * self.se
    let hi = self.coef + 1.96 * self.se
    (lo, hi)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLSSM::predictions_pi(self : DoubleMLSSM) -> Array[Double] {
  self.pi_hat
}

///|
pub fn DoubleMLSSM::predictions_m(self : DoubleMLSSM) -> Array[Double] {
  self.m_hat
}

///|
pub fn DoubleMLSSM::predictions_g_d1(self : DoubleMLSSM) -> Array[Double] {
  self.g_d1
}

///|
pub fn DoubleMLSSM::predictions_g_d0(self : DoubleMLSSM) -> Array[Double] {
  self.g_d0
}

///|
/// v0.64.0+: multiplier bootstrap for `DoubleMLSSM`. The
/// per-observation influence function is
///
///   `psi[i] = theta * psi_a[i] + psi_b[i]`
///
/// where `psi_a[i] = -1` (constant) and `psi_b[i]` is the
/// MAR-score element defined in the file header. Routes through
/// the shared `generic_bootstrap_t_stat` helper (see
/// `bootstrap_helper.mbt`).
///
/// `method_name` selects the multiplier distribution:
/// `"normal"` (default), `"Bayes"`, `"wild"`. `seed` defaults to
/// `2024`; `n_rep_boot` defaults to `500`.
///
/// Calling on an un-fit model aborts via `PreconditionError`.
pub fn DoubleMLSSM::bootstrap(
  self : DoubleMLSSM,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLSSM {
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
          "draw_bootstrap_weights: unknown method (set in DoubleMLSSM::bootstrap): " +
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
/// Tune the `(ml_g, ml_m)` nuisance-learner pair via MSE-on-g_hat
/// cross-fitting. The winning pair is re-fit on the FINAL-FIT fold
/// partition (`self.n_folds`) under `DoubleMLSSM::fit`; the
/// tune-time cross-fit is not reused. `scoring_method` is `"MSE"`
/// (default), `"RMSE"` or `"NegMSE"`; `n_folds_tune` defaults to
/// 5 and `seed` to 3141. Returns a re-fitted `DoubleMLSSM`.
///
/// Slot semantics: SSM is a propensity-first family, so the FIRST
/// `TuneParam` slot is the treatment/propensity learner and the
/// second is the outcome learner. Build the grid with
/// `TuneParam::for_treatment` so the call site carries the role
/// rather than relying on the field name `learner_l`.
///
/// v0.108.0: new. SSM had no `tune` at all, so it was one of the
/// estimators carrying a coverage gap against upstream, where
/// `tune` reaches every estimator through the `BaseDML` mixin.
/// The fold draw, the scoring loop and the argmin/argmax
/// selection route through the shared `tune_score_grid` core, the
/// same core `PLR` / `PLIV` / `IRM` / `IIVM` / `APO` use. No second
/// copy of the selection rule lives here; that duplication is what
/// previously let an inverted argmin ship with the suite green.
///
/// The third `fit` slot, `ml_pi` (the selection propensity
/// `P(S = 1 | D, X)`), is NOT tuned: `TuneParam` carries exactly
/// two learners, so the grid cannot reach it. This differs from
/// `IIVM`, which carries its third slot (`ml_r`) over from the
/// model being tuned. SSM has no `ml_pi` field on the struct at
/// all -- `fit` declares `ml_pi? : LearnerDispatch = self.ml_m`
/// -- so there is no `self.ml_pi` to forward, and this method
/// passes no `ml_pi`, letting `fit` apply its own default.
/// Consequence worth stating plainly: the re-fit uses the
/// PRE-TUNE `self.ml_m` for the selection propensity, not the
/// winning candidate. The grid tunes `(g, m)`; `pi` is whatever
/// the model being tuned already had.
///
/// No cluster guard, and that is not an oversight carried over
/// from `APO` (the pre-v0.108.0 asymmetry). `DoubleMLSSMData`
/// carries no `cluster_vars` field and exposes no
/// `is_cluster_data()`, so there is no clustered path for a
/// row-wise tune schedule to silently mis-handle. The method is
/// not adding one, for the same reason it does not add the guard:
/// the data type has no cluster concept to guard.
pub fn DoubleMLSSM::tune(
  self : DoubleMLSSM,
  param_set~ : Array[TuneParam],
  scoring_method? : String = "MSE",
  n_folds_tune? : Int = 5,
  seed? : Int = 3141,
) -> DoubleMLSSM {
  try {
    require(param_set.length() > 0)
    require(n_folds_tune >= 2)
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
    // `ml_pi` is deliberately absent: see the doc comment. `fit`
    // defaults it to `self.ml_m`, the pre-tune value.
    self.fit(ml_g=best_param.learner_l, ml_m=best_param.learner_m)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.64.0+: per-observation IF accessors.
pub fn DoubleMLSSM::psi_a(self : DoubleMLSSM) -> Array[Double] {
  try {
    require(self.fitted)
    self.psi_a
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLSSM::psi_b(self : DoubleMLSSM) -> Array[Double] {
  try {
    require(self.fitted)
    self.psi_b
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.68.0+: Cinelli & Hazlett (2020) omitted-variable bias
/// analysis for `DoubleMLSSM`. Outcome residual is
/// `y - g_d1_hat` (the selection-on-treated regression at
/// the cross-fitted propensity / outcome nuisances); the
/// Riesz-representer variance is `mean(psi_a^2) = 1` for
/// the SSM MAR IPW score (`psi_a = -1` constant). Routes
/// through the shared `irm_style_sensitivity` helper.
pub fn DoubleMLSSM::sensitivity_analysis(
  self : DoubleMLSSM,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let g_d1 = self.predictions_g_d1()
  let n = g_d1.length()
  let residuals : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    residuals[i] = self.data.y[i] - g_d1[i]
  }
  irm_style_sensitivity(self.coef, residuals, self.psi_a, cf_y, cf_d)
}

///|
/// v0.74.0+: cluster-robust analogue of
/// `DoubleMLSSM::sensitivity_analysis`. Same outcome
/// residual formula (`y - g_d1_hat`) and same `psi_a` as the
/// IID path; only the variance / bias computation is
/// cluster-aware (sigma2_cluster and nu2_cluster are the
/// `G / n_clusters` sums of squared cluster sums).
///
/// `DoubleMLSSMData` has no `cluster_vars` field, so the
/// user must pass `cluster_ids` explicitly.
/// `cluster_ids.length()` must equal `self.data.n_obs()`.
/// Cluster indices are 0-based; `1 + max(cluster_ids)` is the
/// number of clusters.
pub fn DoubleMLSSM::sensitivity_analysis_cluster(
  self : DoubleMLSSM,
  cluster_ids : Array[Int],
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let g_d1 = self.predictions_g_d1()
  let n = g_d1.length()
  require(cluster_ids.length() == n)
  let residuals : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    residuals[i] = self.data.y[i] - g_d1[i]
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
/// Augment a feature matrix with one extra column (used to add `pi_hat`
/// to the design matrix for the conditional-outcome learners).
pub fn augment_one_col(x : Matrix, extra : Array[Double]) -> Matrix {
  let n = x.rows()
  let p = x.cols()
  let out = Matrix::zeros(n, p + 1)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      out.data[i * (p + 1) + j] = x.data[i * p + j]
    }
    out.data[i * (p + 1) + p] = extra[i]
  }
  out
}

///|
/// Filter `idx` to keep only entries `i` where both `mask1[i]` and
/// `mask2[i]` equal the given values. Used to build
/// `train_d{s_value}_s1` for the conditional-outcome learners.
pub fn filter_two_values(
  idx : Array[Int],
  m1 : Array[Double],
  v1 : Double,
  m2 : Array[Double],
  v2 : Double,
) -> Array[Int] {
  let out : Array[Int] = []
  for i in idx {
    if m1[i] == v1 && m2[i] == v2 {
      out.push(i)
    }
  }
  out
}

///|
/// Cross-fit the four SSM nuisances. `pi_hat` is trained on
/// `(X, D) -> S`; `m_hat` is trained on `X -> D`; `g_d1` and `g_d0`
/// are trained on `X -> Y` (features = X only) restricted to the
/// `{D=d, S=1}` subset for d = 1 and d = 0 respectively.
///
/// Bug #1 fix: the previous implementation appended `pi_hat` as an
/// extra feature to the `g_d1` / `g_d0` training design matrix, which
/// caused test-fold `pi` to leak into training-fold predictions
/// (the `pi` array was 0.0 at the start of fold 0 and only
/// partial at fold 1). Upstream `doubleml.irm.ssm` (MAR branch) trains
/// `g_hat_d1` on `X` only and uses the cross-fit-restricted
/// subsample `{D=d, S=1}` for the cross-fit partitions; the
/// `pi_hat` is still used in the score formula.
fn cross_fit_ssm(
  ml_g : LearnerDispatch,
  ml_m : LearnerDispatch,
  ml_pi : LearnerDispatch,
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  s : Array[Double],
  folds : Array[Fold],
  propensity_clip : Double,
) -> (Array[Double], Array[Double], Array[Double], Array[Double]) {
  let n_obs = x.rows()
  let pi = Array::make(n_obs, 0.0)
  let m = Array::make(n_obs, 0.0)
  let gd1 = Array::make(n_obs, 0.0)
  let gd0 = Array::make(n_obs, 0.0)
  for fold in folds {
    let train_idx = fold.train_indices()
    let test_idx = fold.test_indices()
    // m_hat on X -> D (all obs)
    let pm = cross_fit_predict_dispatch(ml_m, x, d, [
      Fold::new(train_idx, test_idx),
    ])
    for k = 0; k < test_idx.length(); k = k + 1 {
      let row = test_idx[k]
      m[row] = pm[row]
    }
    // pi_hat on (X, D) -> S
    let xd_train = augment_one_col(
      slice_matrix_rows(x, train_idx),
      slice_vector(d, train_idx),
    )
    let xd_test = augment_one_col(
      slice_matrix_rows(x, test_idx),
      slice_vector(d, test_idx),
    )
    let pi_pred = fit_predict_one_dispatch(
      ml_pi,
      xd_train,
      slice_vector(s, train_idx),
      xd_test,
    )
    for k = 0; k < test_idx.length(); k = k + 1 {
      let row = test_idx[k]
      pi[row] = pi_pred[k]
    }
    // g_d1: train on {D=1, S=1}, features = X only.
    let train_d1_s1 = filter_two_values(train_idx, d, 1.0, s, 1.0)
    if train_d1_s1.length() > 0 {
      let pg = cross_fit_predict_dispatch(ml_g, x, y, [
        Fold::new(train_d1_s1, test_idx),
      ])
      for k = 0; k < test_idx.length(); k = k + 1 {
        let row = test_idx[k]
        gd1[row] = pg[row]
      }
    }
    // g_d0: train on {D=0, S=1}, features = X only.
    let train_d0_s1 = filter_two_values(train_idx, d, 0.0, s, 1.0)
    if train_d0_s1.length() > 0 {
      let pg0 = cross_fit_predict_dispatch(ml_g, x, y, [
        Fold::new(train_d0_s1, test_idx),
      ])
      for k = 0; k < test_idx.length(); k = k + 1 {
        let row = test_idx[k]
        gd0[row] = pg0[row]
      }
    }
  }
  let m_clipped = clip_vec(m, propensity_clip, 1.0 - propensity_clip)
  let pi_clipped = clip_vec(pi, propensity_clip, 1.0 - propensity_clip)
  (pi_clipped, m_clipped, gd1, gd0)
}

///|
/// Run the SSM estimation.
pub fn DoubleMLSSM::fit(
  self : DoubleMLSSM,
  ml_g? : LearnerDispatch = self.ml_g,
  ml_m? : LearnerDispatch = self.ml_m,
  ml_pi? : LearnerDispatch = self.ml_m,
) -> DoubleMLSSM {
  ignore(ml_g)
  ignore(ml_m)
  ignore(ml_pi)
  try {
    require(self.n_obs() >= self.n_folds) // kfold precondition
    let n = self.n_obs()
    let nrep = self.n_rep
    // v0.83.0+: memoize check (mirrors the PLR / IRM / CVAR
    // pattern). The cache stores the LAST rep's `(pi_hat,
    // m_hat, g_d1, g_d0)` plus the row-to-fold mapping. SSM
    // is an averaged-across-reps estimator, so for `n_rep >
    // 1` the cache cannot host a per-rep aggregate; we honor
    // the cache only when `n_rep == 1`, in which case the
    // stored values ARE the public averaged nuisances (averaging
    // a single rep is the identity).
    let memoize = self.memoize_enabled && nrep == 1
    let data_hash : UInt64 = if memoize {
      hash_data(self.data.x, self.data.y, self.data.d)
    } else {
      0UL
    }
    let hparams_hash : UInt64 = if memoize {
      hash_hyperparams("ssm", ml_g, ml_m, self.propensity_clip)
    } else {
      0UL
    }
    let cluster_hash : UInt64 = if memoize {
      // SSM data has no `cluster_vars`; pass an empty vector
      // so the hash stays 0 across calls (matches the IID
      // sentinel). This keeps the cache-invalidation key
      // stable across calls even though the SSM data type
      // does not carry a `cluster_vars` field.
      hash_cluster_ids([])
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
        "ssm",
      )
    let pi_hat : Array[Double] = Array::make(n, 0.0)
    let m_hat : Array[Double] = Array::make(n, 0.0)
    let g_d1 : Array[Double] = Array::make(n, 0.0)
    let g_d0 : Array[Double] = Array::make(n, 0.0)
    let fold_ids : Array[Int] = Array::make(n, 0)
    if cache_hit {
      // Reuse the cached LAST-rep (= only rep for nrep == 1)
      // nuisances. The per-rep averaging loop is skipped.
      let preds = self.fit_cache.predictions
      for i = 0; i < n; i = i + 1 {
        pi_hat[i] = preds[0][i]
        m_hat[i] = preds[1][i]
        g_d1[i] = preds[2][i]
        g_d0[i] = preds[3][i]
        fold_ids[i] = self.fit_cache.fold_ids[i]
      }
    } else {
      let pi_acc : Array[Double] = Array::make(n, 0.0)
      let m_acc : Array[Double] = Array::make(n, 0.0)
      let g_d1_acc : Array[Double] = Array::make(n, 0.0)
      let g_d0_acc : Array[Double] = Array::make(n, 0.0)
      for r = 0; r < nrep; r = r + 1 {
        let folds = kfold(n, self.n_folds, self.seed + r)
        let (pi, m, gd1, gd0) = cross_fit_ssm(
          ml_g,
          ml_m,
          ml_pi,
          self.data.x,
          self.data.y,
          self.data.d,
          self.data.s,
          folds,
          self.propensity_clip,
        )
        for i = 0; i < n; i = i + 1 {
          pi_acc[i] = pi_acc[i] + pi[i]
          m_acc[i] = m_acc[i] + m[i]
          g_d1_acc[i] = g_d1_acc[i] + gd1[i]
          g_d0_acc[i] = g_d0_acc[i] + gd0[i]
        }
        // Build row->fold_id map for the LAST rep (used by the
        // cache writeback below). For nrep == 1 this is the only
        // rep; for nrep > 1 memoize is effectively disabled
        // (cache cannot host per-rep aggregates) so fold_ids
        // here is unused downstream.
        if memoize && r == nrep - 1 {
          for f = 0; f < folds.length(); f = f + 1 {
            for i in folds[f].test_indices() {
              fold_ids[i] = f
            }
          }
        }
      }
      let inv = 1.0 / nrep.to_double()
      for i = 0; i < n; i = i + 1 {
        pi_hat[i] = pi_acc[i] * inv
        m_hat[i] = m_acc[i] * inv
        g_d1[i] = g_d1_acc[i] * inv
        g_d0[i] = g_d0_acc[i] * inv
      }
    }
    // MAR score (un-normalized IPW). v0.83.0+: psi_a is a
    // constant `-1` (no per-row computation needed) and the
    // psi_b inner loop is rewritten in terms of the
    // `vectorized.mbt` building blocks (`vector_subtract`,
    // `vector_multiply`, `vector_divide`, `vector_add`). The
    // only remaining scalar loops are the `1 - m_i` /
    // `1 - d[i]` sign-flip passes (no
    // `vector_subtract_scalar` helper exists).
    let y = self.data.y
    let d = self.data.d
    let s = self.data.s
    let psi_a : Array[Double] = Array::make(n, -1.0)
    let y_minus_gd1 = vector_subtract(y, g_d1)
    let y_minus_gd0 = vector_subtract(y, g_d0)
    let ds = vector_multiply(d, s)
    let m_pi = vector_multiply(m_hat, pi_hat)
    let one_minus_m : Array[Double] = Array::make(n, 0.0)
    let one_minus_d : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      one_minus_m[i] = 1.0 - m_hat[i]
      one_minus_d[i] = 1.0 - d[i]
    }
    let term1_num = vector_multiply(ds, y_minus_gd1)
    let term1 = vector_divide(term1_num, m_pi, eps=1.0e-12)
    let term1_offset = vector_add(term1, g_d1)
    let one_minus_ds = vector_multiply(one_minus_d, s)
    let term2_num = vector_multiply(one_minus_ds, y_minus_gd0)
    let one_minus_m_pi = vector_multiply(one_minus_m, pi_hat)
    let term2 = vector_divide(term2_num, one_minus_m_pi, eps=1.0e-12)
    let term2_offset = vector_add(term2, g_d0)
    let psi_b = vector_subtract(term1_offset, term2_offset)
    let (coef, se) = var_est(psi_a, psi_b)
    // v0.83.0+: when memoize is on and the cache missed, write
    // the freshly-computed fold_ids + nuisances to the cache.
    let next_cache = if memoize && !cache_hit && nrep == 1 {
      FitCache::from_fit(
        fold_ids,
        [pi_hat, m_hat, g_d1, g_d0],
        self.seed,
        self.n_folds,
        nrep,
        n,
        data_hash,
        hparams_hash,
        cluster_hash,
        "ssm",
      )
    } else {
      self.fit_cache
    }
    // v0.64.0+: persist the last repetition's `psi_a` / `psi_b`
    // for the multiplier bootstrap. SSM's `psi_a = -1` is a
    // constant; the helper `generic_bootstrap_t_stat` accepts
    // both constant and non-constant arrays.
    {
      data: self.data,
      n_folds: self.n_folds,
      n_rep: self.n_rep,
      seed: self.seed,
      propensity_clip: self.propensity_clip,
      ml_g,
      ml_m,
      pi_hat,
      m_hat,
      g_d1,
      g_d0,
      coef,
      se,
      fitted: true,
      psi_a,
      psi_b,
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

// ---------------------------------------------------------------------------
// v0.87.0+: sandwich variance + bias correction
// ---------------------------------------------------------------------------

///|
/// v0.87.0+: Huber-White sandwich standard error for the
/// fitted SSM. Returns `sqrt(var)` where `var` comes from
/// the shared `sandwich_variance(kind, ...)` dispatch in
/// `sandwich.mbt` (HC0 / HC1 / HC2 / HC3), the same dispatch
/// `DoubleMLDID` / `DoubleMLIIVM` / `DoubleMLCVAR` use.
///
/// The three inputs are the ones `fit(...)` already persists
/// for the multiplier bootstrap (see the `psi_a` / `psi_b`
/// field docs on `DoubleMLSSM`):
///   - `psi_a`  = `self.psi_a` -- the constant MAR-score
///     treatment term `-1`, so `mean(psi_a) = -1` by
///     construction and `M_inv = -1`.
///   - `psi`    = `psi_at(self.coef, self.psi_a, self.psi_b)`
///     -- the per-observation influence function at the
///     fitted `coef`, matching the `psi[i] = psi_a[i] +
///     theta * psi_b[i]` form documented on
///     `DoubleMLSSM::bootstrap`.
///   - `M_inv`  = `[[1 / mean(psi_a)]]` (1x1). Only
///     `M_inv[0, 0]^2` enters the variance, so the sign of
///     the (up-to-sign) Jacobian inverse is irrelevant.
///
/// The variance's `n_obs` is `self.psi_a.length()` (the
/// length `fit(...)` persists, equal to `self.n_obs()`).
///
/// Preconditions: `self.fitted`, `mean(psi_a) != 0`.
pub fn DoubleMLSSM::sandwich_se(
  self : DoubleMLSSM,
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
/// v0.87.0+: cluster-robust sandwich standard error for the
/// fitted SSM. Routes through `cluster_sandwich_variance`
/// with the same `psi_a` / `psi` / `M_inv` inputs as the IID
/// `sandwich_se` path. `DoubleMLSSMData` carries no
/// `cluster_vars`, so the caller must supply `cluster_ids`
/// explicitly (typically the survey / site / household id).
///
/// Preconditions: `self.fitted`,
/// `cluster_ids.length() == psi_a.length()`.
pub fn DoubleMLSSM::cluster_sandwich_se(
  self : DoubleMLSSM,
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
/// (SSM's `psi_a` is the constant `-1`.)
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
pub fn DoubleMLSSM::bias_corrected_coef(self : DoubleMLSSM) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
