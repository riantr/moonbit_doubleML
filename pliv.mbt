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
  require(x.nrows == y.length())
  require(x.nrows == d.length())
  require(x.nrows == z.length())
  if cluster_vars.length() > 0 {
    require(cluster_vars.length() == x.nrows)
  }
  { x, y, d, z, cluster_vars }
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
  l_hat : Array[Double]
  r_hat : Array[Double]
  m_hat : Array[Double]
  coef : Double
  se : Double
  fitted : Bool
} derive(Debug)

///|
pub fn DoubleMLPLIV::new(
  data : DoubleMLPLIVData,
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
) -> DoubleMLPLIV {
  require(n_folds >= 2)
  require(n_folds <= data.n_obs())
  require(n_rep >= 1)
  {
    data,
    n_folds,
    n_rep,
    seed,
    l_hat: Array::make(data.n_obs(), 0.0),
    r_hat: Array::make(data.n_obs(), 0.0),
    m_hat: Array::make(data.n_obs(), 0.0),
    coef: 0.0,
    se: 0.0,
    fitted: false,
  }
}

///|
pub fn DoubleMLPLIV::n_obs(self : DoubleMLPLIV) -> Int {
  self.data.n_obs()
}

///|
pub fn DoubleMLPLIV::coef(self : DoubleMLPLIV) -> Double {
  require(self.fitted)
  self.coef
}

///|
pub fn DoubleMLPLIV::se(self : DoubleMLPLIV) -> Double {
  require(self.fitted)
  self.se
}

///|
pub fn DoubleMLPLIV::confint(self : DoubleMLPLIV) -> (Double, Double) {
  require(self.fitted)
  let lo = self.coef - 1.96 * self.se
  let hi = self.coef + 1.96 * self.se
  (lo, hi)
}

///|
pub fn DoubleMLPLIV::predictions_l(self : DoubleMLPLIV) -> Array[Double] {
  self.l_hat
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
  learner? : LinearRegression = LinearRegression::new(),
) -> DoubleMLPLIV {
  if self.data.is_cluster_data() {
    return self.fit_cluster(learner)
  }
  ignore(learner)
  let n = self.n_obs()
  let nrep = self.n_rep
  let coefs : Array[Double] = Array::make(nrep, 0.0)
  let ses : Array[Double] = Array::make(nrep, 0.0)
  // hold the last rep's predictions; final values land in l_hat / r_hat / m_hat
  let mut l_pred : Array[Double] = Array::make(n, 0.0)
  let mut r_pred : Array[Double] = Array::make(n, 0.0)
  let mut m_pred : Array[Double] = Array::make(n, 0.0)
  for r = 0; r < nrep; r = r + 1 {
    let folds = kfold(n, self.n_folds, self.seed + r)
    l_pred = cross_fit_predict(learner, self.data.x, self.data.y, folds)
    r_pred = cross_fit_predict(learner, self.data.x, self.data.d, folds)
    m_pred = cross_fit_predict(learner, self.data.x, self.data.z, folds)
    // Score (partialling out, single instrument) for THIS rep's nuisances only
    let y = self.data.y
    let d = self.data.d
    let z = self.data.z
    let psi_a : Array[Double] = Array::make(n, 0.0)
    let psi_b : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      let u = y[i] - l_pred[i]
      let w = d[i] - r_pred[i]
      let v = z[i] - m_pred[i]
      psi_a[i] = -w * v
      psi_b[i] = v * u
    }
    let (coef_r, se_r) = var_est(psi_a, psi_b)
    coefs[r] = coef_r
    ses[r] = se_r
  }
  // last iteration's predictions are now in l_pred / r_pred / m_pred
  let (coef, se) = aggregate_coef_se(coefs, ses)
  {
    data: self.data,
    n_folds: self.n_folds,
    n_rep: self.n_rep,
    seed: self.seed,
    l_hat: l_pred,
    r_hat: r_pred,
    m_hat: m_pred,
    coef,
    se,
    fitted: true,
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
  learner : LinearRegression,
) -> DoubleMLPLIV {
  let cluster = self.data.cluster_vars
  let n = self.n_obs()
  let nrep = self.n_rep
  let uniq = unique_units(cluster)
  let n_units = uniq.length()
  require(self.n_folds <= n_units)
  // v0.36.0: build_row_unit_map raises ClusterDataError on
  // malformed cluster vector; catch and re-abort to preserve
  // pre-v0.36.0 behavior.
  let row_unit = try
    build_row_unit_map(cluster, uniq)
  catch {
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
    let folds_u = kfold(n_units, self.n_folds, self.seed + r)
    let (folds_row, unit_fold, fold_n_units) = expand_unit_folds_to_rows(
      cluster, folds_u, row_unit,
    )
    l_pred = cross_fit_predict(learner, self.data.x, self.data.y, folds_row)
    r_pred = cross_fit_predict(learner, self.data.x, self.data.d, folds_row)
    m_pred = cross_fit_predict(learner, self.data.x, self.data.z, folds_row)
    let y = self.data.y
    let d = self.data.d
    let z = self.data.z
    let psi_a : Array[Double] = Array::make(n, 0.0)
    let psi_b : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      let u = y[i] - l_pred[i]
      let w = d[i] - r_pred[i]
      let v = z[i] - m_pred[i]
      psi_a[i] = -w * v
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
    r_hat: r_pred,
    m_hat: m_pred,
    coef,
    se,
    fitted: true,
  }
}
