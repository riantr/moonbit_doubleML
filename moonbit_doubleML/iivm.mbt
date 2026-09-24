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
  g0_hat : Array[Double]
  g1_hat : Array[Double]
  m_hat : Array[Double]
  r0_hat : Array[Double]
  r1_hat : Array[Double]
  coef : Double
  se : Double
  fitted : Bool
} derive(Debug)

///|
pub fn DoubleMLIIVM::new(
  data : DoubleMLIIVMData,
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
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
      g0_hat: Array::make(data.n_obs(), 0.0),
      g1_hat: Array::make(data.n_obs(), 0.0),
      m_hat: Array::make(data.n_obs(), 0.0),
      r0_hat: Array::make(data.n_obs(), 0.0),
      r1_hat: Array::make(data.n_obs(), 0.0),
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
pub fn DoubleMLIIVM::confint(self : DoubleMLIIVM) -> (Double, Double) {
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
  ml_g : LinearRegression,
  ml_m : LinearRegression,
  ml_r : LinearRegression,
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
      // g0
      let xt = slice_matrix_rows(x, train_z0)
      let yt = slice_vector(y, train_z0)
      let p = ml_g.fit(xt, yt).predict(slice_matrix_rows(x, test_idx))
      for k = 0; k < test_idx.length(); k = k + 1 {
        g0[test_idx[k]] = p[k]
      }
      // g1
      let xt = slice_matrix_rows(x, train_z1)
      let yt = slice_vector(y, train_z1)
      let p = ml_g.fit(xt, yt).predict(slice_matrix_rows(x, test_idx))
      for k = 0; k < test_idx.length(); k = k + 1 {
        g1[test_idx[k]] = p[k]
      }
      // m (trained on all)
      let p = ml_m
        .fit(slice_matrix_rows(x, train_idx), slice_vector(z, train_idx))
        .predict(slice_matrix_rows(x, test_idx))
      for k = 0; k < test_idx.length(); k = k + 1 {
        m[test_idx[k]] = p[k]
      }
      // r0
      let xt = slice_matrix_rows(x, train_z0)
      let dt = slice_vector(d, train_z0)
      let p = ml_r.fit(xt, dt).predict(slice_matrix_rows(x, test_idx))
      for k = 0; k < test_idx.length(); k = k + 1 {
        r0[test_idx[k]] = p[k]
      }
      // r1
      let xt = slice_matrix_rows(x, train_z1)
      let dt = slice_vector(d, train_z1)
      let p = ml_r.fit(xt, dt).predict(slice_matrix_rows(x, test_idx))
      for k = 0; k < test_idx.length(); k = k + 1 {
        r1[test_idx[k]] = p[k]
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
  ml_g? : LinearRegression = LinearRegression::new(),
  ml_m? : LinearRegression = LinearRegression::new(),
  ml_r? : LinearRegression = LinearRegression::new(),
  max_attempts? : Int = 1,
) -> DoubleMLIIVM {
  try {
    require(max_attempts >= 1)
    if self.data.is_cluster_data() {
      return self.fit_cluster(ml_g, ml_m, ml_r, max_attempts~)
    }
    ignore(ml_g)
    ignore(ml_m)
    ignore(ml_r)
    let n = self.n_obs()
    let nrep = self.n_rep
    let coefs : Array[Double] = Array::make(nrep, 0.0)
    let ses : Array[Double] = Array::make(nrep, 0.0)
    // hold the last rep's predictions; final values land in *_hat fields
    let mut g0 : Array[Double] = Array::make(n, 0.0)
    let mut g1 : Array[Double] = Array::make(n, 0.0)
    let mut m : Array[Double] = Array::make(n, 0.0)
    let mut r0 : Array[Double] = Array::make(n, 0.0)
    let mut r1 : Array[Double] = Array::make(n, 0.0)
    for r = 0; r < nrep; r = r + 1 {
      let folds = kfold(n, self.n_folds, self.seed + r)
      let (g0_r, g1_r, m_r, r0_r, r1_r) = cross_fit_iivm(
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
      g0 = g0_r
      g1 = g1_r
      m = m_r
      r0 = r0_r
      r1 = r1_r
      // LATE score for THIS rep's nuisances only
      let y = self.data.y
      let d = self.data.d
      let z = self.data.z
      let psi_a : Array[Double] = Array::make(n, 0.0)
      let psi_b : Array[Double] = Array::make(n, 0.0)
      for i = 0; i < n; i = i + 1 {
        let u0 = y[i] - g0[i]
        let u1 = y[i] - g1[i]
        let w0 = d[i] - r0[i]
        let w1 = d[i] - r1[i]
        let m_i = m[i]
        let one_minus_m = 1.0 - m_i
        psi_b[i] = g1[i] -
          g0[i] +
          z[i] * u1 / m_i -
          (1.0 - z[i]) * u0 / one_minus_m
        psi_a[i] = -(r1[i] - r0[i]) -
          z[i] * w1 / m_i +
          (1.0 - z[i]) * w0 / one_minus_m
      }
      let (coef_r, se_r) = var_est(psi_a, psi_b)
      coefs[r] = coef_r
      ses[r] = se_r
    }
    // last iteration's predictions are now in g0 / g1 / m / r0 / r1
    let (coef, se) = aggregate_coef_se(coefs, ses)
    {
      data: self.data,
      n_folds: self.n_folds,
      n_rep: self.n_rep,
      seed: self.seed,
      propensity_clip: self.propensity_clip,
      g0_hat: g0,
      g1_hat: g1,
      m_hat: m,
      r0_hat: r0,
      r1_hat: r1,
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
  ml_g : LinearRegression,
  ml_m : LinearRegression,
  ml_r : LinearRegression,
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
        let psi_a : Array[Double] = Array::make(n, 0.0)
        let psi_b : Array[Double] = Array::make(n, 0.0)
        for i = 0; i < n; i = i + 1 {
          let u0 = y[i] - g0[i]
          let u1 = y[i] - g1[i]
          let w0 = d[i] - r0[i]
          let w1 = d[i] - r1[i]
          let m_i = m[i]
          let one_minus_m = 1.0 - m_i
          psi_b[i] = g1[i] -
            g0[i] +
            z[i] * u1 / m_i -
            (1.0 - z[i]) * u0 / one_minus_m
          psi_a[i] = -(r1[i] - r0[i]) -
            z[i] * w1 / m_i +
            (1.0 - z[i]) * w0 / one_minus_m
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
    {
      data: self.data,
      n_folds: self.n_folds,
      n_rep: self.n_rep,
      seed: self.seed,
      propensity_clip: self.propensity_clip,
      g0_hat: g0,
      g1_hat: g1,
      m_hat: m,
      r0_hat: r0,
      r1_hat: r1,
      coef,
      se,
      fitted: true,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
