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
  // `psi_a[i] + theta * psi_b[i]` for the multiplier bootstrap.
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
    let coefs : Array[Double] = Array::make(nrep, 0.0)
    let ses : Array[Double] = Array::make(nrep, 0.0)
    // hold the last rep's predictions; final values land in l_hat / m_hat
    let mut l_pred : Array[Double] = Array::make(n, 0.0)
    let mut m_pred : Array[Double] = Array::make(n, 0.0)
    for r = 0; r < nrep; r = r + 1 {
      let folds = kfold(n, self.n_folds, self.seed + r)
      l_pred = cross_fit_predict_dispatch(
        learner_l,
        self.data.x,
        self.data.y,
        folds,
      )
      m_pred = cross_fit_predict_dispatch(
        learner_m,
        self.data.x,
        self.data.d,
        folds,
      )
      // score elements for THIS rep's nuisances only
      let v_hat : Array[Double] = Array::make(n, 0.0)
      let u_hat : Array[Double] = Array::make(n, 0.0)
      for i = 0; i < n; i = i + 1 {
        v_hat[i] = self.data.d[i] - m_pred[i]
        u_hat[i] = self.data.y[i] - l_pred[i]
      }
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
    let v_hat_last : Array[Double] = Array::make(n, 0.0)
    let u_hat_last : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      v_hat_last[i] = self.data.d[i] - m_pred[i]
      u_hat_last[i] = self.data.y[i] - l_pred[i]
    }
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
      // honor the caller's tune_result override (set by
      // `DoubleMLPLR::tune`); default `None` preserves v0.57.0
      // behavior for plain `fit(...)` callers.
      tune_result,
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
        let v_hat : Array[Double] = Array::make(n, 0.0)
        let u_hat : Array[Double] = Array::make(n, 0.0)
        for i = 0; i < n; i = i + 1 {
          v_hat[i] = self.data.d[i] - m_pred[i]
          u_hat[i] = self.data.y[i] - l_pred[i]
        }
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
    let v_hat_last : Array[Double] = Array::make(n, 0.0)
    let u_hat_last : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      v_hat_last[i] = self.data.d[i] - m_pred[i]
      u_hat_last[i] = self.data.y[i] - l_pred[i]
    }
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
///   psi[i] = psi_a[i] + theta * psi_b[i]
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
/// `n_thetas=1` case with `psi[i] = psi_a[i] + coef * psi_b[i]`.
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
    // Compute psi[i] = psi_a[i] + coef * psi_b[i] and
    // ss_psi = sum(psi[i]^2) once. `psi_a` / `psi_b` were
    // populated by `fit(...)` from the last rep's nuisances
    // (matching `l_hat` / `m_hat`); the bootstrap is run at the
    // already-fitted `coef`, no re-estimation.
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
  let n = l_hat.length()
  let residuals : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    residuals[i] = self.data.y[i] - l_hat[i]
  }
  irm_style_sensitivity(self.coef, residuals, self.psi_a, cf_y, cf_d)
}
