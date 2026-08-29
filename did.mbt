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
/// Returns `DoubleMLDIDData raise DIDDataError`: the v0.43.0
/// conversion replaces the previous `abort()` call with
/// `raise DIDDataError::NonBinaryTreatment(i)` so the
/// non-binary-`d` path becomes directly testable. Callers
/// that want the pre-v0.43.0 process-death behavior should
/// catch the error and re-abort (this is what
/// `DoubleMLDIDBinaryData::new` does); callers that want to
/// surface the error to downstream consumers should propagate
/// via `?`. The `require` checks on `x.nrows` against `y.length`
/// and `d.length` are unchanged and still abort the process
/// (they are central `require` checks; refactoring them is
/// out of scope for this surgical release).
pub fn DoubleMLDIDData::new(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
) -> DoubleMLDIDData raise DIDDataError {
  require(x.nrows == y.length())
  require(x.nrows == d.length())
  // Validate that `d` is binary `{0, 1}` (the default port supports
  // only switchers; the multi-valued `{-1, 0, 1}` Sant'Anna & Zhao
  // convention is not implemented).
  for i = 0; i < d.length(); i = i + 1 {
    if d[i] != 0.0 && d[i] != 1.0 {
      raise DIDDataError::NonBinaryTreatment(i)
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
/// in-sample-normalisation variant
/// (`in_sample_normalization = true`) are supported as of v0.8.0;
/// they are required by `DoubleMLDIDBinary`'s preprocessing wrapper.
/// The staggered-DID variant (`DoubleMLDIDCS`) is still not
/// implemented in this port.
pub struct DoubleMLDID {
  data : DoubleMLDIDData
  n_folds : Int
  n_rep : Int
  seed : Int
  propensity_clip : Double
  // Propensity-score processor. v0.10.0+ replacement for the
  // bare `propensity_clip` scalar: `fit` now applies
  // `ps_processor.adjust_ps(m, d)` to the cross-fitted propensity
  // vector instead of the hard-coded `clip_vec(m, eps, 1-eps)`.
  // The default `PSProcessor::new()` clips to `[1e-2, 1 - 1e-2]`
  // (matches upstream's `clipping_threshold=1e-2`). The legacy
  // `propensity_clip` field is retained for backward compat and
  // is read only by the inner `cross_fit_did`; the public API
  // is `ps_processor` (or `ps_processor_config` in the wrappers).
  ps_processor : PSProcessor
  // Score function. `"observational"` (default) is the ATT-style
  // IPW score used by Sant'Anna & Zhao (2020) §4.1. `"experimental"`
  // uses the A/B-test-style score where treatment is independent of
  // pre-treatment covariates (Sant'Anna & Zhao 2020 §4.2): the
  // propensity `m` collapses to the constant `mean(d)` and the score
  // simplifies to `psi_a = -1`, `psi_b = g_0(d=0) + g_1(d=1) -
  // w_d * (y - g_0)`. Match the upstream `score` constructor
  // argument.
  score : String
  // Whether to normalise the IPW weights by their sample mean
  // (Sant'Anna & Zhao 2020 eq. 4.3) or by `p_hat = mean(d)`. The
  // `in_sample_normalization = true` form uses `d / mean(d)` instead
  // of `d / p_hat` for `psi_a`; equivalent asymptotically but
  // differs in finite samples. Default is `false` to preserve
  // pre-0.8.0 bit-equality with the prior `DoubleMLDID` port.
  in_sample_normalization : Bool
  // Optional per-observation stratum label for stratified K-fold
  // sample splitting. If non-empty, `fit` calls
  // `stratified_kfold` instead of `kfold`; fold `f` of the resulting
  // partition contains the union of fold-`f` test rows across
  // strata. Length must equal `data.n_obs()`; entries can be any
  // integer (the function does not require them to be `0..k-1`).
  // The DID Binary / DID CS wrappers set this to
  // `G_indicator + 2 * t_indicator` to balance treated/control ×
  // pre/post cells across folds (matching upstream's
  // `self._strata`).
  strata : Array[Int]
  g0_hat : Array[Double]
  g1_hat : Array[Double]
  m_hat : Array[Double]
  coef : Double
  se : Double
  // v0.15.0+: per-observation influence function components.
  // `psi_a[i] + theta * psi_b[i]` is the per-observation
  // contribution to the DML theta estimator. Length `n_obs` (the
  // wide-format data). `psi_a` has mean `-1` (by construction
  // for the observational / experimental score); `psi_b` has
  // mean `theta * -mean(psi_a)` in the ATT sense. Used by
  // `DoubleMLDIDMulti::bootstrap` for the multiplier bootstrap.
  psi_a : Array[Double]
  psi_b : Array[Double]
  fitted : Bool
} derive(Debug)

///|
pub fn DoubleMLDID::new(
  data : DoubleMLDIDData,
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
  ps_processor? : PSProcessor = PSProcessor::new(),
  score? : String = "observational",
  in_sample_normalization? : Bool = false,
  strata? : Array[Int] = [],
) -> DoubleMLDID {
  require(n_folds >= 2)
  require(n_folds <= data.n_obs())
  require(n_rep >= 1)
  require(propensity_clip > 0.0)
  require(propensity_clip < 0.5)
  require(score == "observational" || score == "experimental")
  // Either no strata (empty) or strata of exact length n_obs.
  require(strata.length() == 0 || strata.length() == data.n_obs())
  {
    data,
    n_folds,
    n_rep,
    seed,
    propensity_clip,
    ps_processor,
    score,
    in_sample_normalization,
    strata,
    g0_hat: Array::make(data.n_obs(), 0.0),
    g1_hat: Array::make(data.n_obs(), 0.0),
    m_hat: Array::make(data.n_obs(), 0.0),
    coef: 0.0,
    se: 0.0,
    psi_a: Array::make(data.n_obs(), 0.0),
    psi_b: Array::make(data.n_obs(), 0.0),
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
    // Choose the partitioning strategy. With `strata` set (length
    // = n), use `stratified_kfold` so each fold balances the
    // (G, T) cells; otherwise plain `kfold`.
    let folds = if self.strata.length() == n {
      stratified_kfold(self.strata, self.n_folds, self.seed + r)
    } else {
      kfold(n, self.n_folds, self.seed + r)
    }
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
  // v0.10.0+: re-clip the averaged propensity through the
  // `ps_processor` so the public-facing `m_hat` (and downstream
  // score computation) honours the processor's
  // `clipping_threshold` (default 1e-2) rather than the inner
  // `cross_fit_did` 1e-6 clip. The inner `clip_vec` is kept for
  // numerical safety in the per-rep cross-fit.
  let m_clipped = self.ps_processor.adjust_ps(m_hat, self.data.d)
  // DID score (observational or experimental), following
  // Sant'Anna & Zhao (2020) §4. The two scores share the same
  // structure: `psi_a = -weight_psi_a`, `psi_b = psi_b_1 +
  // weight_resid_d0 * (y - g0)`. The differences are in the
  // weighting (observational uses IPW with `p_hat`, experimental
  // uses A/B-test weights that collapse `m` to the constant
  // `mean(d)`) and in the inclusion of the `g1` term in the
  // experimental psi_b_1.
  let y = self.data.y
  let d = self.data.d
  let p_hat = mean(d)
  let mean_d = p_hat
  let psi_a : Array[Double] = Array::make(n, 0.0)
  let psi_b : Array[Double] = Array::make(n, 0.0)
  let one_minus_d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    one_minus_d[i] = 1.0 - d[i]
  }
  let mean_one_minus_d = mean(one_minus_d)
  let psi_b_1 : Array[Double] = Array::make(n, 0.0)
  if self.score == "observational" {
    if self.in_sample_normalization {
      // Sant'Anna & Zhao (2020) eq. 4.3 (in-sample-normalised form):
      //   w_psi_a   = d / mean(d)
      //   w_resid_d0 = d / mean(d) - (1 - d) * m / (1 - m) / mean((1-d) m / (1-m))
      let mut prop_weight_mean = 0.0
      for i = 0; i < n; i = i + 1 {
        prop_weight_mean = prop_weight_mean +
          one_minus_d[i] * m_clipped[i] / (1.0 - m_clipped[i])
      }
      prop_weight_mean = prop_weight_mean / n.to_double()
      for i = 0; i < n; i = i + 1 {
        let resid_d0 = y[i] - g0_hat[i]
        let m_i = m_clipped[i]
        let one_minus_m = 1.0 - m_i
        let prop_weight_i = one_minus_d[i] * m_i / one_minus_m
        psi_a[i] = -d[i] / mean_d
        psi_b[i] = (d[i] / mean_d - prop_weight_i / prop_weight_mean) * resid_d0
      }
    } else {
      // Default form (pre-0.8.0 behaviour, byte-equal to 0.7.0):
      //   w_psi_a   = d / p_hat
      //   w_resid_d0 = (d - m) / (p_hat * (1 - m))
      for i = 0; i < n; i = i + 1 {
        let resid_d0 = y[i] - g0_hat[i]
        let m_i = m_clipped[i]
        let one_minus_m = 1.0 - m_i
        let denom = p_hat * one_minus_m
        psi_a[i] = -d[i] / p_hat
        psi_b[i] = (d[i] - m_i) / denom * resid_d0
      }
    }
    // score == "experimental": A/B-test setting where treatment is
    // independent of pre-treatment covariates. The propensity `m`
    // collapses to `mean(d)` and the psi_a is the constant `-1`.
    // The psi_b_1 = (d / mean(d) - 1) * g0 + (1 - d / mean(d)) * g1
    // term captures the doubly-robust g adjustment.
  } else if self.in_sample_normalization {
    for i = 0; i < n; i = i + 1 {
      let resid_d0 = y[i] - g0_hat[i]
      let d_i = d[i]
      let w_d = d_i / mean_d
      psi_a[i] = -1.0
      psi_b_1[i] = (w_d - 1.0) * g0_hat[i] + (1.0 - w_d) * g1_hat[i]
      psi_b[i] = psi_b_1[i] + (w_d - (1.0 - d_i) / mean_one_minus_d) * resid_d0
    }
  } else {
    for i = 0; i < n; i = i + 1 {
      let resid_d0 = y[i] - g0_hat[i]
      let m_i = m_clipped[i]
      let d_i = d[i]
      let w_d = d_i / m_i
      psi_a[i] = -1.0
      psi_b_1[i] = (w_d - 1.0) * g0_hat[i] + (1.0 - w_d) * g1_hat[i]
      psi_b[i] = psi_b_1[i] + (d_i - m_i) / (m_i * (1.0 - m_i)) * resid_d0
    }
  }
  ignore(psi_b_1)
  let (coef, se) = var_est(psi_a, psi_b)
  {
    data: self.data,
    n_folds: self.n_folds,
    n_rep: self.n_rep,
    seed: self.seed,
    propensity_clip: self.propensity_clip,
    ps_processor: self.ps_processor,
    score: self.score,
    in_sample_normalization: self.in_sample_normalization,
    strata: self.strata,
    g0_hat,
    g1_hat,
    m_hat: m_clipped,
    coef,
    se,
    psi_a,
    psi_b,
    fitted: true,
  }
}
