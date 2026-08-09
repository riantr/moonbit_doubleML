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
pub fn DoubleMLPLR::fit(
  self : DoubleMLPLR,
  learner? : LinearRegression = LinearRegression::new(),
) -> DoubleMLPLR {
  ignore(learner)
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
