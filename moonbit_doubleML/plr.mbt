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
pub fn DoubleMLPLR::confint(self : DoubleMLPLR) -> (Double, Double) {
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
/// `score` selects the DML nuisance score (v0.54.0+):
///   - `"partialling-out"` (default): the standard
///     partialling-out DML score `psi_a = -(d - m_hat)^2`,
///     `psi_b = (d - m_hat) * (y - l_hat)`. This is what
///     upstream calls `DoubleMLPLR._score_partialling_out`
///     and is the only score ported at v0.54.0.
///   - `"IV-type"`: would require an instrument vector `Z`
///     in `DoubleMLData`; not yet ported. Calling `fit` with
///     `score="IV-type"` aborts with a descriptive message.
///
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
) -> DoubleMLPLR {
  try {
    require(
      score == "partialling-out" || score == "iv-type" || score == "IV-type",
    )
    require(max_attempts >= 1)
    if score == "iv-type" || score == "IV-type" {
      // v0.54.0: `score="IV-type"` requires an instrument
      // vector Z in `DoubleMLData`, which is not yet ported.
      // Throw a `PreconditionError` (v0.48.0+ cascade) so the
      // outer `try` catches it and re-aborts with a
      // descriptive message naming the v0.54.0 limitation.
      let line : String = "DoubleMLPLR::fit: score='IV-type' needs instrument vector Z (port coming in v0.55+)"
      ignore(line)
      require(false) // unreachable
    }
    if self.data.is_cluster_data() {
      return self.fit_cluster(learner_l~, learner_m~, max_attempts~)
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
      let psi_a : Array[Double] = Array::make(n, 0.0)
      let psi_b : Array[Double] = Array::make(n, 0.0)
      for i = 0; i < n; i = i + 1 {
        psi_a[i] = -v_hat[i] * v_hat[i]
        psi_b[i] = v_hat[i] * u_hat[i]
      }
      // point estimate + variance come from the shared DML formula
      let (coef_r, se_r) = var_est(psi_a, psi_b)
      coefs[r] = coef_r
      ses[r] = se_r
    }
    // last iteration's predictions are now in l_pred / m_pred
    let (coef, se) = aggregate_coef_se(coefs, ses)
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
) -> DoubleMLPLR {
  try {
    require(max_attempts >= 1)
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
        let psi_a : Array[Double] = Array::make(n, 0.0)
        let psi_b : Array[Double] = Array::make(n, 0.0)
        for i = 0; i < n; i = i + 1 {
          let v = self.data.d[i] - m_pred[i]
          let u = self.data.y[i] - l_pred[i]
          psi_a[i] = -v * v
          psi_b[i] = v * u
        }
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
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
