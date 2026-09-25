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
  pi_hat : Array[Double]
  m_hat : Array[Double]
  g_d1 : Array[Double]
  g_d0 : Array[Double]
  coef : Double
  se : Double
  fitted : Bool
} derive(Debug)
pub extend DoubleMLSSM with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLSSM::new(
  data : DoubleMLSSMData,
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
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
      pi_hat: Array::make(data.n_obs(), 0.0),
      m_hat: Array::make(data.n_obs(), 0.0),
      g_d1: Array::make(data.n_obs(), 0.0),
      g_d0: Array::make(data.n_obs(), 0.0),
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
  ml_g : LinearRegression,
  ml_m : LinearRegression,
  ml_pi : LinearRegression,
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
    let m_pred = ml_m
      .fit(slice_matrix_rows(x, train_idx), slice_vector(d, train_idx))
      .predict(slice_matrix_rows(x, test_idx))
    for k = 0; k < test_idx.length(); k = k + 1 {
      m[test_idx[k]] = m_pred[k]
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
    let pi_pred = ml_pi
      .fit(xd_train, slice_vector(s, train_idx))
      .predict(xd_test)
    for k = 0; k < test_idx.length(); k = k + 1 {
      pi[test_idx[k]] = pi_pred[k]
    }
    // g_d1: train on {D=1, S=1}, features = X only. (Bug #1: do NOT
    // append `pi` — the upstream MAR fit uses X alone.)
    let train_d1_s1 = filter_two_values(train_idx, d, 1.0, s, 1.0)
    if train_d1_s1.length() > 0 {
      let x_train = slice_matrix_rows(x, train_d1_s1)
      let x_test = slice_matrix_rows(x, test_idx)
      let yt = slice_vector(y, train_d1_s1)
      let p = ml_g.fit(x_train, yt).predict(x_test)
      for k = 0; k < test_idx.length(); k = k + 1 {
        gd1[test_idx[k]] = p[k]
      }
    }
    // g_d0: train on {D=0, S=1}, features = X only.
    let train_d0_s1 = filter_two_values(train_idx, d, 0.0, s, 1.0)
    if train_d0_s1.length() > 0 {
      let x_train = slice_matrix_rows(x, train_d0_s1)
      let x_test = slice_matrix_rows(x, test_idx)
      let yt = slice_vector(y, train_d0_s1)
      let p = ml_g.fit(x_train, yt).predict(x_test)
      for k = 0; k < test_idx.length(); k = k + 1 {
        gd0[test_idx[k]] = p[k]
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
  ml_g? : LinearRegression = LinearRegression::new(),
  ml_m? : LinearRegression = LinearRegression::new(),
  ml_pi? : LinearRegression = LinearRegression::new(),
) -> DoubleMLSSM {
  ignore(ml_g)
  ignore(ml_m)
  ignore(ml_pi)
  try {
    require(self.n_obs() >= self.n_folds) // kfold precondition
    let n = self.n_obs()
    let nrep = self.n_rep
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
  }
  let inv = 1.0 / nrep.to_double()
  let pi_hat : Array[Double] = Array::make(n, 0.0)
  let m_hat : Array[Double] = Array::make(n, 0.0)
  let g_d1 : Array[Double] = Array::make(n, 0.0)
  let g_d0 : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    pi_hat[i] = pi_acc[i] * inv
    m_hat[i] = m_acc[i] * inv
    g_d1[i] = g_d1_acc[i] * inv
    g_d0[i] = g_d0_acc[i] * inv
  }
  // MAR score (un-normalized IPW)
  let y = self.data.y
  let d = self.data.d
  let s = self.data.s
  let psi_a : Array[Double] = Array::make(n, 0.0)
  let psi_b : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let m_i = m_hat[i]
    let pi_i = pi_hat[i]
    let one_minus_m = 1.0 - m_i
    psi_a[i] = -1.0
    psi_b[i] = d[i] * s[i] * (y[i] - g_d1[i]) / (m_i * pi_i) +
      g_d1[i] -
      ((1.0 - d[i]) * s[i] * (y[i] - g_d0[i]) / (one_minus_m * pi_i) + g_d0[i])
  }
  let (coef, se) = var_est(psi_a, psi_b)
  {
    data: self.data,
    n_folds: self.n_folds,
    n_rep: self.n_rep,
    seed: self.seed,
    propensity_clip: self.propensity_clip,
    pi_hat,
    m_hat,
    g_d1,
    g_d0,
    coef,
    se,
    fitted: true,
  }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
