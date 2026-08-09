///|
/// Data container for `DoubleMLDID`. Uses *panel* data with two
/// time periods. The treatment `d` is the *change* in treatment
/// status between the post-period and the pre-period (so
/// `d ∈ {-1, 0, 1}` for never-treated/always-treated/switchers
/// under the Sant'Anna & Zhao (2020) convention). The default port
/// supports binary `d ∈ {0, 1}` (only the switchers).
pub struct DoubleMLDIDData {
  x : Matrix
  y : Array[Double]
  d : Array[Double]
} derive(Debug)

///|
pub fn DoubleMLDIDData::new(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
) -> DoubleMLDIDData {
  require(x.nrows == y.length())
  require(x.nrows == d.length())
  // Validate that `d` is binary `{0, 1}` (the default port supports
  // only switchers; the multi-valued `{-1, 0, 1}` Sant'Anna & Zhao
  // convention is not implemented).
  for i = 0; i < d.length(); i = i + 1 {
    if d[i] != 0.0 && d[i] != 1.0 {
      abort("DoubleMLDIDData.d must be binary {0, 1}")
    }
  }
  { x, y, d }
}

///|
pub fn DoubleMLDIDData::n_obs(self : DoubleMLDIDData) -> Int {
  self.x.rows()
}

///|
pub fn DoubleMLDIDData::n_features(self : DoubleMLDIDData) -> Int {
  self.x.cols()
}

///|
/// Double / debiased machine learning estimator for the *difference
/// in differences* (DID) model with *panel* data and *binary*
/// treatment `d ∈ {0, 1}`, following Sant'Anna and Zhao (2020).
///
/// The reduced-form outcome equation is
///
///     Y_post = g_0(0, X) + D * theta + U_post,    E[U | D, X] = 0
///     Y_pre  = g_0(0, X) + U_pre,                  E[U_pre | X] = 0
///
/// or, in first differences,
///
///     dY = Y_post - Y_pre = g_1(1, X) - g_0(0, X) + D * theta + (U_post - U_pre)
///
/// We form cross-fitted nuisance predictions
///
///     g0(X) = E[Y | D = 0, X]      (trained on D = 0)
///     g1(X) = E[Y | D = 1, X]      (trained on D = 1)
///     m(X)  = P(D = 1 | X)         (trained on all obs; observational
///                                   only, clipped to [eps, 1 - eps])
///
/// and use the *observational* DID score (the most general one):
///
///     resid_d0 = Y - g0
///     p_hat = mean(D)
///     weight_psi_a   = D / p_hat
///     weight_resid   = (D - m) / (p_hat * (1 - m))
///     psi_b = (D - m)/(p_hat (1 - m)) * (Y - g0)        [the g1 term cancels in ATT]
///     psi_a = -D / p_hat
///     psi(theta) = theta * psi_a + psi_b
///
/// Note: in the upstream code, when `D = 1` is the only informative
/// group, the ATT-style psi_b simplifies to
///     psi_b = weight_resid_d0 * resid_d0
/// because `psi_b_1` (the g1-based term) is zero under the ATT
/// weighting. The port follows that simplification.
///
/// Point estimate and variance
///
///     theta_hat = -mean(psi_b) / mean(psi_a)
///     J         = mean(psi_a)
///     gamma     = mean(psi(theta_hat)^2)
///     sigma2    = gamma / (J^2 * n)
///     se        = sqrt(sigma2).
///
/// The *experimental* score (`score = "experimental"`) and the
/// staggered-DID variant (`DoubleMLDIDCS`) are not implemented in
/// this port.
pub struct DoubleMLDID {
  data : DoubleMLDIDData
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
pub fn DoubleMLDID::new(
  data : DoubleMLDIDData,
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
) -> DoubleMLDID {
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
pub fn DoubleMLDID::n_obs(self : DoubleMLDID) -> Int {
  self.data.n_obs()
}

///|
pub fn DoubleMLDID::coef(self : DoubleMLDID) -> Double {
  require(self.fitted)
  self.coef
}

///|
pub fn DoubleMLDID::se(self : DoubleMLDID) -> Double {
  require(self.fitted)
  self.se
}

///|
pub fn DoubleMLDID::confint(self : DoubleMLDID) -> (Double, Double) {
  require(self.fitted)
  let lo = self.coef - 1.96 * self.se
  let hi = self.coef + 1.96 * self.se
  (lo, hi)
}

///|
pub fn DoubleMLDID::predictions_g0(self : DoubleMLDID) -> Array[Double] {
  self.g0_hat
}

///|
pub fn DoubleMLDID::predictions_g1(self : DoubleMLDID) -> Array[Double] {
  self.g1_hat
}

///|
pub fn DoubleMLDID::predictions_m(self : DoubleMLDID) -> Array[Double] {
  self.m_hat
}

///|
/// Cross-fit the three DID nuisance functions: `g0` (D = 0 only),
/// `g1` (D = 1 only), `m` (all observations). Each returns length-`n_obs`
/// vectors. The test folds cover the full observation set.
fn cross_fit_did(
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
    let train_d0 = filter_by_value(train_idx, d, 0.0)
    let train_d1 = filter_by_value(train_idx, d, 1.0)
    if train_d0.length() > 0 {
      let xt = slice_matrix_rows(x, train_d0)
      let yt = slice_vector(y, train_d0)
      let p = ml_g.fit(xt, yt).predict(slice_matrix_rows(x, test_idx))
      for k = 0; k < test_idx.length(); k = k + 1 {
        g0[test_idx[k]] = p[k]
      }
    }
    if train_d1.length() > 0 {
      let xt = slice_matrix_rows(x, train_d1)
      let yt = slice_vector(y, train_d1)
      let p = ml_g.fit(xt, yt).predict(slice_matrix_rows(x, test_idx))
      for k = 0; k < test_idx.length(); k = k + 1 {
        g1[test_idx[k]] = p[k]
      }
    }
    let p = ml_m
      .fit(slice_matrix_rows(x, train_idx), slice_vector(d, train_idx))
      .predict(slice_matrix_rows(x, test_idx))
    for k = 0; k < test_idx.length(); k = k + 1 {
      m[test_idx[k]] = p[k]
    }
  }
  let m_clipped = clip_vec(m, propensity_clip, 1.0 - propensity_clip)
  (g0, g1, m_clipped)
}

///|
/// Run the DID estimation.
pub fn DoubleMLDID::fit(
  self : DoubleMLDID,
  ml_g? : LinearRegression = LinearRegression::new(),
  ml_m? : LinearRegression = LinearRegression::new(),
) -> DoubleMLDID {
  ignore(ml_g)
  ignore(ml_m)
  let n = self.n_obs()
  let nrep = self.n_rep
  let g0_acc : Array[Double] = Array::make(n, 0.0)
  let g1_acc : Array[Double] = Array::make(n, 0.0)
  let m_acc : Array[Double] = Array::make(n, 0.0)
  for r = 0; r < nrep; r = r + 1 {
    let folds = kfold(n, self.n_folds, self.seed + r)
    let (g0, g1, m) = cross_fit_did(
      ml_g,
      ml_m,
      self.data.x,
      self.data.y,
      self.data.d,
      folds,
      self.propensity_clip,
    )
    for i = 0; i < n; i = i + 1 {
      g0_acc[i] = g0_acc[i] + g0[i]
      g1_acc[i] = g1_acc[i] + g1[i]
      m_acc[i] = m_acc[i] + m[i]
    }
  }
  let inv = 1.0 / nrep.to_double()
  let g0_hat : Array[Double] = Array::make(n, 0.0)
  let g1_hat : Array[Double] = Array::make(n, 0.0)
  let m_hat : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    g0_hat[i] = g0_acc[i] * inv
    g1_hat[i] = g1_acc[i] * inv
    m_hat[i] = m_acc[i] * inv
  }
  // observational DID score (ATT-style), following Sant'Anna & Zhao (2020)
  let y = self.data.y
  let d = self.data.d
  let p_hat = mean(d)
  let psi_a : Array[Double] = Array::make(n, 0.0)
  let psi_b : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let resid_d0 = y[i] - g0_hat[i]
    let m_i = m_hat[i]
    let one_minus_m = 1.0 - m_i
    let denom = p_hat * one_minus_m
    psi_a[i] = -d[i] / p_hat
    psi_b[i] = (d[i] - m_i) / denom * resid_d0
  }
  let (coef, se) = var_est(psi_a, psi_b)
  {
    data: self.data,
    n_folds: self.n_folds,
    n_rep: self.n_rep,
    seed: self.seed,
    propensity_clip: self.propensity_clip,
    g0_hat,
    g1_hat,
    m_hat,
    coef,
    se,
    fitted: true,
  }
}
