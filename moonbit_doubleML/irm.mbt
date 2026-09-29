///|
/// Double / debiased machine learning estimator for the *interactive
/// regression model* (IRM) of Chernozhukov et al. (2018) with the
/// Average Treatment Effect (ATE) score:
///
///     Y = g_0(D, X) + U,    E[U | D, X] = 0
///     D = m_0(X) + V,        E[V | X] = 0
///
/// and the *ATE* orthogonal signal
///
///     g0(X) = E[Y | D=0, X]
///     g1(X) = E[Y | D=1, X]
///     m(X)  = P(D=1 | X)             (the propensity score)
///     u0    = Y - g0(X)
///     u1    = Y - g1(X)
///
///     psi_b = (g1 - g0) + (D u1 / m - (1 - D) u0 / (1 - m))
///     psi_a = -1
///     psi(theta) = theta * psi_a + psi_b
///
/// with point estimate
///
///     theta_hat = -mean(psi_b) / mean(psi_a) = mean(psi_b)
///
/// and variance (same `_var_est` formula as `DoubleMLPLR`):
///
///     J       = mean(psi_a) = -1
///     gamma   = mean(psi(theta_hat)^2)
///     sigma2  = gamma / (J^2 * n)
///     se      = sqrt(sigma2)
///
/// The cross-fitting scheme trains `g0` only on observations with
/// `D = 0` and `g1` only on observations with `D = 1` (the test
/// folds still cover the full observation set), matching
/// `doubleml.utils._estimation._get_cond_smpls` in the upstream
/// package. The propensity score is clipped to
/// `[propensity_clip, 1 - propensity_clip]` before being used in the
/// score, guarding against near-zero or near-one values.
pub struct DoubleMLIRM {
  data : DoubleMLData
  n_folds : Int
  n_rep : Int
  seed : Int
  propensity_clip : Double
  // v0.59.0+: injected nuisance learners (replaces the
  // v0.57.0 hardcoded `LinearRegression`). Defaults to a
  // fresh `LinearRegression` so v0.57.0 callers see
  // byte-identical results. Both fields are package-private
  // to enforce that nuisance changes go through `fit(...)` /
  // `fit_cluster(...)` overrides.
  ml_g : LearnerDispatch
  ml_m : LearnerDispatch
  g0_hat : Array[Double]
  g1_hat : Array[Double]
  m_hat : Array[Double]
  // Raw (pre-clipping) propensity scores. v0.53.0-dev Task 4:
  // mirrors upstream feat "retain raw IRM propensity scores"
  // so callers can inspect the un-clipped predictions without
  // re-fitting.
  m_raw : Array[Double]
  coef : Double
  se : Double
  fitted : Bool
  // v0.61.0+: per-observation influence function components
  // for the multiplier bootstrap. For the ATE score
  // `psi_b = (g1-g0) + (D*u1/m - (1-D)*u0/(1-m))` and
  // `psi_a = -1` (constant), so `psi[i] = -1 + theta *
  // psi_b[i]`. Populated by `fit(...)` from the last rep's
  // nuisances; `psi_a` is `length n_obs` of `-1.0`.
  psi_a : Array[Double]
  psi_b : Array[Double]
  // v0.61.0+: multiplier bootstrap state. `boot_t_stat` is a
  // length-`n_rep_boot` array of t-statistics for `coef`.
  // Populated by `bootstrap(...)`; empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
} derive(Debug)

///|
pub extend DoubleMLIRM with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLIRM::new(
  data : DoubleMLData,
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
  ml_g? : LearnerDispatch = LearnerDispatch::linear_regression(),
  ml_m? : LearnerDispatch = LearnerDispatch::linear_regression(),
) -> DoubleMLIRM {
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
      g0_hat: Array::make(data.n_obs(), 0.0),
      g1_hat: Array::make(data.n_obs(), 0.0),
      m_hat: Array::make(data.n_obs(), 0.0),
      m_raw: Array::make(data.n_obs(), 0.0),
      coef: 0.0,
      se: 0.0,
      fitted: false,
      psi_a: Array::make(data.n_obs(), -1.0),
      psi_b: Array::make(data.n_obs(), 0.0),
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLIRM::n_obs(self : DoubleMLIRM) -> Int {
  self.data.n_obs()
}

///|
/// Number of features (covariate columns).
pub fn DoubleMLIRM::n_features(self : DoubleMLIRM) -> Int {
  self.data.n_features()
}

///|
pub fn DoubleMLIRM::coef(self : DoubleMLIRM) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLIRM::se(self : DoubleMLIRM) -> Double {
  try {
    require(self.fitted)
    self.se
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLIRM::confint(self : DoubleMLIRM) -> (Double, Double) {
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
pub fn DoubleMLIRM::predictions_g0(self : DoubleMLIRM) -> Array[Double] {
  self.g0_hat
}

///|
pub fn DoubleMLIRM::predictions_g1(self : DoubleMLIRM) -> Array[Double] {
  self.g1_hat
}

///|
pub fn DoubleMLIRM::predictions_m(self : DoubleMLIRM) -> Array[Double] {
  self.m_hat
}

///|
/// Raw (pre-clipping) propensity scores, length `n_obs`.
/// v0.53.0-dev Task 4: mirrors upstream feat "retain raw IRM
/// propensity scores" so callers can inspect the un-clipped
/// predictions without re-fitting.
pub fn DoubleMLIRM::propensity_score_raw(self : DoubleMLIRM) -> Array[Double] {
  self.m_raw
}

///|
/// Accessor for the outcome-nuisance learner used by the most
/// recent `fit(...)` / `fit_cluster(...)` call. v0.59.0+.
pub fn DoubleMLIRM::learner_g(self : DoubleMLIRM) -> LearnerDispatch {
  self.ml_g
}

///|
/// Accessor for the propensity-score learner used by the most
/// recent `fit(...)` / `fit_cluster(...)` call. v0.59.0+.
pub fn DoubleMLIRM::learner_m(self : DoubleMLIRM) -> LearnerDispatch {
  self.ml_m
}

///|
/// Filter `idx` to keep only entries `i` for which `mask[i]` is true.
pub fn filter_indices(idx : Array[Int], mask : Array[Double]) -> Array[Int] {
  let out : Array[Int] = []
  for i in idx {
    if mask[i] == 1.0 {
      out.push(i)
    }
  }
  out
}

///|
/// Clip every element of `v` to `[lo, hi]` in place (returns a new
/// array; does not mutate the input).
pub fn clip_vec(v : Array[Double], lo : Double, hi : Double) -> Array[Double] {
  let n = v.length()
  let out = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let x = v[i]
    out[i] = if x < lo { lo } else if x > hi { hi } else { x }
  }
  out
}

///|
/// Cross-fitted nuisance predictions for an IRM model. For each fold
/// we train three learners:
///   - `ml_g` on `(x[train_d0], y[train_d0])` for the `D = 0` group,
///     then predict on `x[test]`,
///   - `ml_g` on `(x[train_d1], y[train_d1])` for the `D = 1` group,
///     then predict on `x[test]`,
///   - `ml_m` on `(x[train], d[train])`, then predict on `x[test]`,
///     clipped to `[eps, 1 - eps]`.
///
/// Returns `(g0_hat, g1_hat, m_hat)` each of length `n_obs`. If a
/// conditional training subset is empty (e.g. an extreme D imbalance
/// falls into one half of a 2-fold split), the call aborts via
/// `require(...)` rather than silently writing zero predictions —
/// silently-zero nuisance predictions would corrupt the ATE score.
fn cross_fit_irm(
  ml_g : LearnerDispatch,
  ml_m : LearnerDispatch,
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  folds : Array[Fold],
  propensity_clip : Double,
) -> (Array[Double], Array[Double], Array[Double], Array[Double]) {
  try {
    let n_obs = x.rows()
    let g0 = Array::make(n_obs, 0.0)
    let g1 = Array::make(n_obs, 0.0)
    let m = Array::make(n_obs, 0.0)
    for fold in folds {
      let train_idx = fold.train_indices()
      let test_idx = fold.test_indices()
      // g0: train on D == 0 — build a single Fold covering
      // (train_d0, test_idx) and call `cross_fit_predict_dispatch`
      // with [single_fold]. The standard cross_fit helper handles
      // the LearnerDispatch enum dispatch (5 arms) for us.
      let train_d0 : Array[Int] = []
      for i in train_idx {
        if d[i] == 0.0 {
          train_d0.push(i)
        }
      }
      require(train_d0.length() > 0)
      let p0 = cross_fit_predict_dispatch(ml_g, x, y, [
        Fold::new(train_d0, test_idx),
      ])
      for k = 0; k < test_idx.length(); k = k + 1 {
        let row = test_idx[k]
        g0[row] = p0[row]
      }
      // g1: train on D == 1 — same single-fold dispatch pattern.
      let train_d1_only : Array[Int] = []
      for i in train_idx {
        if d[i] == 1.0 {
          train_d1_only.push(i)
        }
      }
      require(train_d1_only.length() > 0)
      let p1 = cross_fit_predict_dispatch(ml_g, x, y, [
        Fold::new(train_d1_only, test_idx),
      ])
      for k = 0; k < test_idx.length(); k = k + 1 {
        let row = test_idx[k]
        g1[row] = p1[row]
      }
      // m: train on all rows of train_idx — single fold covering
      // (train_idx, test_idx). Uses `ml_m` (the propensity learner).
      let pm = cross_fit_predict_dispatch(ml_m, x, d, [
        Fold::new(train_idx, test_idx),
      ])
      for k = 0; k < test_idx.length(); k = k + 1 {
        let row = test_idx[k]
        m[row] = pm[row]
      }
    }
    // m must be clipped
    let m_clipped = clip_vec(m, propensity_clip, 1.0 - propensity_clip)
    (g0, g1, m_clipped, m)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Run the IRM estimation. The default learners are closed-form
/// `LinearRegression` instances for both the outcome nuisance (`ml_g`)
/// and the propensity score (`ml_m`).
///
/// Per-repetition behaviour: each repetition `r` cross-fits the
/// `g0 / g1 / m` nuisances from its own folds (seed `self.seed + r`),
/// computes its own `(theta_r, se_r)` from the ATE score, and the two
/// arrays are then aggregated by `aggregate_coef_se` (median of
/// thetas, then SE from the median of `(theta_r + 1.96 * se_r)`). For
/// `n_rep == 1` the aggregator returns the single `(theta_1, se_1)`
/// exactly, so the byte-equality with the previous "average then
/// estimate" implementation is preserved. The
/// `predictions_g0 / g1 / m` accessors return the nuisances from the
/// *last* repetition (the conventional choice in upstream `doubleml`),
/// not a cross-rep average.
///
/// When `self.data` carries a non-empty `cluster_vars` vector, the
/// estimator routes through the clustered DML path: folds partition
/// whole units (rows of one cluster id stay on the same side of
/// every split), the ATE is the fold-weighted ratio of cluster
/// score sums, and the SE is unit-level cluster-robust.
pub fn DoubleMLIRM::fit(
  self : DoubleMLIRM,
  ml_g? : LearnerDispatch = self.ml_g,
  ml_m? : LearnerDispatch = self.ml_m,
  max_attempts? : Int = 1,
) -> DoubleMLIRM {
  try {
    require(max_attempts >= 1)
    if self.data.is_cluster_data() {
      return self.fit_cluster(ml_g~, ml_m~, max_attempts~)
    }
    let n = self.n_obs()
    let nrep = self.n_rep
    let coefs : Array[Double] = Array::make(nrep, 0.0)
    let ses : Array[Double] = Array::make(nrep, 0.0)
    // hold the last rep's predictions; final values land in g0_hat / g1_hat / m_hat
    let mut g0 : Array[Double] = Array::make(n, 0.0)
    let mut g1 : Array[Double] = Array::make(n, 0.0)
    let mut m : Array[Double] = Array::make(n, 0.0)
    let mut m_raw : Array[Double] = Array::make(n, 0.0)
    for r = 0; r < nrep; r = r + 1 {
      let folds = kfold(n, self.n_folds, self.seed + r)
      let (g0_r, g1_r, m_r, m_raw_r) = cross_fit_irm(
        ml_g,
        ml_m,
        self.data.x,
        self.data.y,
        self.data.d,
        folds,
        self.propensity_clip,
      )
      g0 = g0_r
      g1 = g1_r
      m = m_r
      m_raw = m_raw_r
      // Score (ATE, weights=1, weights_bar=1) — uses THIS rep's nuisances only
      let y = self.data.y
      let d = self.data.d
      let psi_a : Array[Double] = Array::make(n, 0.0)
      let psi_b : Array[Double] = Array::make(n, 0.0)
      for i = 0; i < n; i = i + 1 {
        let u0 = y[i] - g0[i]
        let u1 = y[i] - g1[i]
        let m_i = m[i]
        let one_minus_m = 1.0 - m_i
        let d_over_m = d[i] * u1 / m_i
        let one_minus_d_over_one_minus_m = (1.0 - d[i]) * u0 / one_minus_m
        psi_b[i] = g1[i] - g0[i] + (d_over_m - one_minus_d_over_one_minus_m)
        psi_a[i] = -1.0
      }
      let (coef_r, se_r) = var_est(psi_a, psi_b)
      coefs[r] = coef_r
      ses[r] = se_r
    }
    // last iteration's predictions are now in g0 / g1 / m
    let (coef, se) = aggregate_coef_se(coefs, ses)
    // v0.61.0: per-observation influence function for the
    // multiplier bootstrap. Recompute `psi_a / psi_b` from
    // the last rep's cross-fitted nuisances so the stored
    // arrays align with `g0_hat` / `g1_hat` / `m_hat` and
    // `coef` (matches the v0.20.0+ DID convention).
    let psi_a : Array[Double] = Array::make(n, 0.0)
    let psi_b : Array[Double] = Array::make(n, 0.0)
    let y_last = self.data.y
    let d_last = self.data.d
    for i = 0; i < n; i = i + 1 {
      let u0 = y_last[i] - g0[i]
      let u1 = y_last[i] - g1[i]
      let m_i = m[i]
      let one_minus_m = 1.0 - m_i
      let d_over_m = d_last[i] * u1 / m_i
      let one_minus_d_over_one_minus_m = (1.0 - d_last[i]) * u0 / one_minus_m
      psi_b[i] = g1[i] - g0[i] + (d_over_m - one_minus_d_over_one_minus_m)
      psi_a[i] = -1.0
    }
    {
      data: self.data,
      n_folds: self.n_folds,
      n_rep: self.n_rep,
      seed: self.seed,
      propensity_clip: self.propensity_clip,
      // v0.59.0+: persist the per-fit learner overrides onto
      // the returned struct. Defaults preserve v0.57.0 surface
      // when callers don't override.
      ml_g,
      ml_m,
      g0_hat: g0,
      g1_hat: g1,
      m_hat: m,
      m_raw,
      coef,
      se,
      fitted: true,
      psi_a,
      psi_b,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Clustered-DML path for `DoubleMLIRM`. Same shape as
/// `DoubleMLPLR::fit_cluster`: folds are drawn over the unique
/// cluster ids, expanded to row folds; `g0`, `g1`, `m` are
/// cross-fitted with cluster-respecting folds; the ATE
/// coefficient is the fold-weighted ratio of cluster score sums
/// (the IRM `psi_a = -1.0` is constant so the weighted sum
/// collapses to `n_units`-normalised mean), and the SE is the
/// unit-level cluster-robust `var_est_cluster`.
fn DoubleMLIRM::fit_cluster(
  self : DoubleMLIRM,
  ml_g~ : LearnerDispatch,
  ml_m~ : LearnerDispatch,
  max_attempts? : Int = 1,
) -> DoubleMLIRM {
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
    let mut m_raw : Array[Double] = Array::make(n, 0.0)
    for r = 0; r < nrep; r = r + 1 {
      // v0.40.0: retry loop on J-floor. Each retry uses a different
      // fold split (seed = self.seed + r + attempt*nrep) so the
      // fold-mean J is different.
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
        let (g0_r, g1_r, m_r, m_raw_r) = cross_fit_irm(
          ml_g,
          ml_m,
          self.data.x,
          self.data.y,
          self.data.d,
          folds_row,
          self.propensity_clip,
        )
        g0 = g0_r
        g1 = g1_r
        m = m_r
        m_raw = m_raw_r
        let psi_a : Array[Double] = Array::make(n, 0.0)
        let psi_b : Array[Double] = Array::make(n, 0.0)
        for i = 0; i < n; i = i + 1 {
          let u0 = self.data.y[i] - g0[i]
          let u1 = self.data.y[i] - g1[i]
          let m_i = m[i]
          let one_minus_m = 1.0 - m_i
          let d_over_m = self.data.d[i] * u1 / m_i
          let one_minus_d_over_one_minus_m = (1.0 - self.data.d[i]) *
            u0 /
            one_minus_m
          psi_b[i] = g1[i] - g0[i] + (d_over_m - one_minus_d_over_one_minus_m)
          psi_a[i] = -1.0
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
    // the stored arrays align with `g0_hat` / `g1_hat` /
    // `m_hat` and `coef`.
    let psi_a : Array[Double] = Array::make(n, 0.0)
    let psi_b : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      let u0 = self.data.y[i] - g0[i]
      let u1 = self.data.y[i] - g1[i]
      let m_i = m[i]
      let one_minus_m = 1.0 - m_i
      let d_over_m = self.data.d[i] * u1 / m_i
      let one_minus_d_over_one_minus_m = (1.0 - self.data.d[i]) *
        u0 /
        one_minus_m
      psi_b[i] = g1[i] - g0[i] + (d_over_m - one_minus_d_over_one_minus_m)
      psi_a[i] = -1.0
    }
    {
      data: self.data,
      n_folds: self.n_folds,
      n_rep: self.n_rep,
      seed: self.seed,
      propensity_clip: self.propensity_clip,
      // v0.59.0+: persist per-fit learner overrides on the
      // cluster-path return struct too. Defaults preserve
      // v0.57.0 surface for plain `fit_cluster` callers.
      ml_g,
      ml_m,
      g0_hat: g0,
      g1_hat: g1,
      m_hat: m,
      m_raw,
      coef,
      se,
      fitted: true,
      psi_a,
      psi_b,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.61.0+: multiplier bootstrap for `DoubleMLIRM`. The
/// per-observation influence function is
///
///   psi[i] = psi_a[i] + theta * psi_b[i]
///          = -1 + theta * psi_b[i]
///
/// where `psi_b[i] = (g1-g0)[i] + (D*u1/m - (1-D)*u0/(1-m))[i]`
/// is computed at the fitted `coef` from the last rep's
/// cross-fitted nuisances `g0_hat` / `g1_hat` / `m_hat`.
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
/// `DoubleMLDIDCrossSection::bootstrap`); IRM is the
/// `n_thetas=1` case.
pub fn DoubleMLIRM::bootstrap(
  self : DoubleMLIRM,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLIRM {
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
          "draw_bootstrap_weights: unknown method (set in DoubleMLIRM::bootstrap): " +
          m,
        )
    }
    // Compute psi[i] = psi_a[i] + coef * psi_b[i] and
    // ss_psi = sum(psi[i]^2) once. `psi_a[i] = -1` and
    // `psi_b` is the per-observation ATE score, both
    // populated by `fit(...)` from the last rep's nuisances.
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
