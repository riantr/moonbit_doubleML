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
pub fn DoubleMLPLR::new(
  data : DoubleMLData,
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
) -> DoubleMLPLR {
  require(n_folds >= 2)
  require(n_folds <= data.n_obs())
  require(n_rep >= 1)
  {
    data,
    n_folds,
    n_rep,
    seed,
    l_hat: Array::make(data.n_obs(), 0.0),
    m_hat: Array::make(data.n_obs(), 0.0),
    coef: 0.0,
    se: 0.0,
    fitted: false,
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
  require(self.fitted)
  self.coef
}

///|
/// Standard error of the causal parameter, computed via the
/// DML variance formula.
pub fn DoubleMLPLR::se(self : DoubleMLPLR) -> Double {
  require(self.fitted)
  self.se
}

///|
/// 95% Wald-style confidence interval `[coef - 1.96*se, coef + 1.96*se]`.
pub fn DoubleMLPLR::confint(self : DoubleMLPLR) -> (Double, Double) {
  require(self.fitted)
  let lo = self.coef - 1.96 * self.se
  let hi = self.coef + 1.96 * self.se
  (lo, hi)
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
pub fn DoubleMLPLR::fit(
  self : DoubleMLPLR,
  learner? : LinearRegression = LinearRegression::new(),
) -> DoubleMLPLR {
  if self.data.is_cluster_data() {
    return self.fit_cluster(learner)
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
    l_pred = cross_fit_predict(learner, self.data.x, self.data.y, folds)
    m_pred = cross_fit_predict(learner, self.data.x, self.data.d, folds)
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
    n_folds: self.n_folds,
    n_rep: self.n_rep,
    seed: self.seed,
    l_hat: l_pred,
    m_hat: m_pred,
    coef,
    se,
    fitted: true,
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
  learner : LinearRegression,
) -> DoubleMLPLR {
  let cluster = self.data.cluster_vars
  let n = self.n_obs()
  let nrep = self.n_rep
  let uniq = unique_units(cluster)
  let n_units = uniq.length()
  require(self.n_folds <= n_units)
  // row → unit-position map (linear scan, panels are small in
  // tests and demos).
  let row_unit = build_row_unit_map(cluster, uniq)
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
    // unit-level folds expanded to row-level folds (rows of one
    // unit stay on the same side of every split).
    let folds_u = kfold(n_units, self.n_folds, self.seed + r)
    let (folds_row, unit_fold, fold_n_units) = expand_unit_folds_to_rows(
      cluster, folds_u, row_unit,
    )
    l_pred = cross_fit_predict(learner, self.data.x, self.data.y, folds_row)
    m_pred = cross_fit_predict(learner, self.data.x, self.data.d, folds_row)
    let psi_a : Array[Double] = Array::make(n, 0.0)
    let psi_b : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      let v = self.data.d[i] - m_pred[i]
      let u = self.data.y[i] - l_pred[i]
      psi_a[i] = -v * v
      psi_b[i] = v * u
    }
    let (theta_r, se_r) = try
      cluster_causal_param_and_se(
        psi_a,
        psi_b,
        folds_row,
        fold_n_units,
        unit_rows,
        unit_fold,
        folds_u.length(),
        self.n_folds,
      )
    catch {
      e =>
        match e {
          VarEstClusterError::JTooSmall(j, g, n_units) =>
            abort(
              "var_est_cluster: |J|=" +
              j.abs().to_string() +
              " < 1e-6 (J=" +
              j.to_string() +
              ", g=" +
              g.to_string() +
              ", n_units=" +
              n_units.to_string() +
              "); cluster SE is numerically unstable, try a different seed",
            )
        }
    }
    coefs[r] = theta_r
    ses[r] = se_r
  }
  let (coef, se) = aggregate_coef_se(coefs, ses)
  {
    data: self.data,
    n_folds: self.n_folds,
    n_rep: self.n_rep,
    seed: self.seed,
    l_hat: l_pred,
    m_hat: m_pred,
    coef,
    se,
    fitted: true,
  }
}
