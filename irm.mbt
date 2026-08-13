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
  g0_hat : Array[Double]
  g1_hat : Array[Double]
  m_hat : Array[Double]
  coef : Double
  se : Double
  fitted : Bool
} derive(Debug)

///|
pub fn DoubleMLIRM::new(
  data : DoubleMLData,
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
) -> DoubleMLIRM {
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
    coef: 0.0,
    se: 0.0,
    fitted: false,
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
  require(self.fitted)
  self.coef
}

///|
pub fn DoubleMLIRM::se(self : DoubleMLIRM) -> Double {
  require(self.fitted)
  self.se
}

///|
pub fn DoubleMLIRM::confint(self : DoubleMLIRM) -> (Double, Double) {
  require(self.fitted)
  let lo = self.coef - 1.96 * self.se
  let hi = self.coef + 1.96 * self.se
  (lo, hi)
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
  ml_g : LinearRegression,
  ml_m : LinearRegression,
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  folds : Array[Fold],
  propensity_clip : Double,
) -> (Array[Double], Array[Double], Array[Double]) {
  let n_obs = x.rows()
  let g0 = Array::make(n_obs, 0.0)
  let g1 = Array::make(n_obs, 0.0)
  let m = Array::make(n_obs, 0.0)
  for fold in folds {
    let train_idx = fold.train_indices()
    let test_idx = fold.test_indices()
    // g0: train on D == 0
    let train_d0 : Array[Int] = []
    for i in train_idx {
      if d[i] == 0.0 {
        train_d0.push(i)
      }
    }
    require(train_d0.length() > 0)
    let xt0 = slice_matrix_rows(x, train_d0)
    let yt0 = slice_vector(y, train_d0)
    let fitted0 = ml_g.fit(xt0, yt0)
    let p = fitted0.predict(slice_matrix_rows(x, test_idx))
    for k = 0; k < test_idx.length(); k = k + 1 {
      g0[test_idx[k]] = p[k]
    }
    // g1: train on D == 1
    let train_d1_only : Array[Int] = []
    for i in train_idx {
      if d[i] == 1.0 {
        train_d1_only.push(i)
      }
    }
    require(train_d1_only.length() > 0)
    let xt1 = slice_matrix_rows(x, train_d1_only)
    let yt1 = slice_vector(y, train_d1_only)
    let fitted1 = ml_g.fit(xt1, yt1)
    let p = fitted1.predict(slice_matrix_rows(x, test_idx))
    for k = 0; k < test_idx.length(); k = k + 1 {
      g1[test_idx[k]] = p[k]
    }
    // m: train on all
    let fitted_m = ml_m.fit(
      slice_matrix_rows(x, train_idx),
      slice_vector(d, train_idx),
    )
    let p = fitted_m.predict(slice_matrix_rows(x, test_idx))
    for k = 0; k < test_idx.length(); k = k + 1 {
      m[test_idx[k]] = p[k]
    }
  }
  // m must be clipped
  let m_clipped = clip_vec(m, propensity_clip, 1.0 - propensity_clip)
  (g0, g1, m_clipped)
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
pub fn DoubleMLIRM::fit(
  self : DoubleMLIRM,
  ml_g? : LinearRegression = LinearRegression::new(),
  ml_m? : LinearRegression = LinearRegression::new(),
) -> DoubleMLIRM {
  ignore(ml_g)
  ignore(ml_m)
  let n = self.n_obs()
  let nrep = self.n_rep
  let coefs : Array[Double] = Array::make(nrep, 0.0)
  let ses : Array[Double] = Array::make(nrep, 0.0)
  // hold the last rep's predictions; final values land in g0_hat / g1_hat / m_hat
  let mut g0 : Array[Double] = Array::make(n, 0.0)
  let mut g1 : Array[Double] = Array::make(n, 0.0)
  let mut m : Array[Double] = Array::make(n, 0.0)
  for r = 0; r < nrep; r = r + 1 {
    let folds = kfold(n, self.n_folds, self.seed + r)
    let (g0_r, g1_r, m_r) = cross_fit_irm(
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
  {
    data: self.data,
    n_folds: self.n_folds,
    n_rep: self.n_rep,
    seed: self.seed,
    propensity_clip: self.propensity_clip,
    g0_hat: g0,
    g1_hat: g1,
    m_hat: m,
    coef,
    se,
    fitted: true,
  }
}
