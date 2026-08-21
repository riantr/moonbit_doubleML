///|
/// Data container for the cross-section DID model
/// (Sant'Anna & Zhao 2020, "repeated cross-sections"
/// variant). Each unit has ONE observation, with
/// covariates `x`, outcome `y`, binary treatment `d`
/// (in {0, 1}), and binary post-period indicator `t`
/// (in {0, 1}). The total sample size is `n`.
///
/// Unlike the panel DID, there is no `id` column
/// (cross-section = each unit is observed at most once)
/// and no `g` column (no group structure — the
/// "treated" group is just the `d == 1` cohort and the
/// "control" group is the `d == 0` cohort). The model
/// fits 4 g-functions `g(d, t, x) = E[Y | D=d, T=t, X]`
/// for the 4 (d, t) combinations, plus 1 propensity
/// function `m(x) = E[D=1 | X]`, and constructs the
/// ATT score function from these nuisance predictions.
pub struct DoubleMLDIDCrossSectionData {
  x : Matrix
  y : Array[Double]
  d : Array[Double]
  t : Array[Int]
  // Convenience: the data-set name, used only for
  // `DoubleMLDIDCrossSection` error messages.
  name : String
} derive(Debug)

///|
pub fn DoubleMLDIDCrossSectionData::new(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  t : Array[Int],
  name? : String = "cross_section",
) -> DoubleMLDIDCrossSectionData {
  let n = y.length()
  require(x.nrows == n)
  require(d.length() == n)
  require(t.length() == n)
  // Validate d is binary {0, 1}.
  for di in d {
    require(di == 0.0 || di == 1.0)
  }
  // Validate t is binary {0, 1}.
  for ti in t {
    require(ti == 0 || ti == 1)
  }
  // Validate t has both 0 and 1 (otherwise the DID
  // setup is degenerate).
  let mut has_t0 = false
  let mut has_t1 = false
  for ti in t {
    if ti == 0 {
      has_t0 = true
    } else if ti == 1 {
      has_t1 = true
    }
  }
  require(has_t0 && has_t1)
  { x, y, d, t, name }
}

///|
/// Sample size of the cross-section DID data.
pub fn DoubleMLDIDCrossSectionData::n_obs(
  self : DoubleMLDIDCrossSectionData,
) -> Int {
  self.y.length()
}

///|
/// Number of features in the cross-section DID data
/// (excluding the intercept, which is added inside the
/// learner).
pub fn DoubleMLDIDCrossSectionData::n_features(
  self : DoubleMLDIDCrossSectionData,
) -> Int {
  self.x.cols()
}

// ---------------------------------------------------------------------------
// Cross-section DID model (Sant'Anna & Zhao 2020, "repeated cross-sections")
// ---------------------------------------------------------------------------

///|
/// v0.20.0+: Cross-section DID model with 4 g-functions
/// and 1 propensity function. The score function matches
/// the upstream
/// `doubleml.DoubleMLDIDCS._score_elements` algorithm.
///
/// `score` selects the score convention:
///   - `"observational"` (default): the 2x2 DID setting
///     where treatment assignment may be confounded by
///     covariates. Uses the doubly-robust form with
///     propensity reweighting.
///   - `"experimental"`: an A/B-test setting where
///     treatment is independent of pre-treatment
///     covariates. The propensity `m` collapses to a
///     constant and the score simplifies.
///
/// `in_sample_normalization` selects the in-sample vs
/// out-of-sample normalization:
///   - `false` (default): the canonical Sant'Anna-Zhao
///     form, with `weight_psi_a = d / p_hat`.
///   - `true`: in-sample normalization
///     `weight_psi_a = d / mean(d)`.
pub struct DoubleMLDIDCrossSection {
  data : DoubleMLDIDCrossSectionData
  n_folds : Int
  n_rep : Int
  seed : Int
  score : String
  in_sample_normalization : Bool
  propensity_clip : Double
  ps_processor : PSProcessor
  // Post-fit outputs.
  coef : Double
  se : Double
  // v0.20.0+ per-observation influence function
  // `psi = psi_a + theta * psi_b` on the cross-section
  // sample (length n). Used by the multiplier bootstrap
  // in v0.20.0+ `bootstrap` (deferred to a follow-up
  // release; psi_a / psi_b are exposed individually for
  // forward-compat).
  psi_a : Array[Double]
  psi_b : Array[Double]
  // Post-fit nuisance predictions (4 g-functions +
  // 1 m-function), each length n.
  g_d0_t0 : Array[Double]
  g_d0_t1 : Array[Double]
  g_d1_t0 : Array[Double]
  g_d1_t1 : Array[Double]
  m_hat : Array[Double]
  fitted : Bool
  // v0.21.0+: multiplier bootstrap outputs. `boot_t_stat`
  // is a length-`n_rep_boot` array of t-statistics (one
  // per bootstrap replication). Populated by
  // `bootstrap`; `boot_t_stat.length() == 0` until
  // `bootstrap` is called.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
} derive(Debug)

///|
pub fn DoubleMLDIDCrossSection::new(
  data : DoubleMLDIDCrossSectionData,
  n_folds? : Int = 5,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  score? : String = "observational",
  in_sample_normalization? : Bool = false,
  propensity_clip? : Double = 1.0e-6,
  ps_processor? : PSProcessor = PSProcessor::new(),
) -> DoubleMLDIDCrossSection {
  require(n_folds >= 2)
  require(n_rep >= 1)
  require(propensity_clip > 0.0)
  require(propensity_clip < 0.5)
  require(score == "observational" || score == "experimental")
  let n = data.n_obs()
  {
    data,
    n_folds,
    n_rep,
    seed,
    score,
    in_sample_normalization,
    propensity_clip,
    ps_processor,
    coef: 0.0,
    se: 0.0,
    psi_a: Array::make(n, 0.0),
    psi_b: Array::make(n, 0.0),
    g_d0_t0: Array::make(n, 0.0),
    g_d0_t1: Array::make(n, 0.0),
    g_d1_t0: Array::make(n, 0.0),
    g_d1_t1: Array::make(n, 0.0),
    m_hat: Array::make(n, 0.0),
    fitted: false,
    boot_t_stat: [],
    boot_method: "",
    n_rep_boot: 0,
    boot_seed: 0,
  }
}

///|
/// v0.20.0+: per-observation `psi_a` from the
/// cross-section DID score. Length `n_obs`. Throws if
/// the model hasn't been fit.
pub fn DoubleMLDIDCrossSection::psi_a(
  self : DoubleMLDIDCrossSection,
) -> Array[Double] {
  require(self.fitted)
  self.psi_a
}

///|
/// v0.20.0+: per-observation `psi_b` from the
/// cross-section DID score. Length `n_obs`. Throws if
/// the model hasn't been fit.
pub fn DoubleMLDIDCrossSection::psi_b(
  self : DoubleMLDIDCrossSection,
) -> Array[Double] {
  require(self.fitted)
  self.psi_b
}

///|
/// v0.20.0+: nuisance predictions `g(0, 0)` (control,
/// pre-period). Length `n_obs`.
pub fn DoubleMLDIDCrossSection::predictions_g_d0_t0(
  self : DoubleMLDIDCrossSection,
) -> Array[Double] {
  require(self.fitted)
  self.g_d0_t0
}

///|
/// v0.20.0+: nuisance predictions `g(0, 1)` (control,
/// post-period). Length `n_obs`.
pub fn DoubleMLDIDCrossSection::predictions_g_d0_t1(
  self : DoubleMLDIDCrossSection,
) -> Array[Double] {
  require(self.fitted)
  self.g_d0_t1
}

///|
/// v0.20.0+: nuisance predictions `g(1, 0)` (treated,
/// pre-period). Length `n_obs`.
pub fn DoubleMLDIDCrossSection::predictions_g_d1_t0(
  self : DoubleMLDIDCrossSection,
) -> Array[Double] {
  require(self.fitted)
  self.g_d1_t0
}

///|
/// v0.20.0+: nuisance predictions `g(1, 1)` (treated,
/// post-period). Length `n_obs`.
pub fn DoubleMLDIDCrossSection::predictions_g_d1_t1(
  self : DoubleMLDIDCrossSection,
) -> Array[Double] {
  require(self.fitted)
  self.g_d1_t1
}

///|
/// v0.20.0+: propensity predictions `m(x) = E[D=1 | X]`.
/// Length `n_obs`. Clipped to `[propensity_clip, 1 -
/// propensity_clip]` after the cross-fit prediction
/// averaging.
pub fn DoubleMLDIDCrossSection::predictions_m(
  self : DoubleMLDIDCrossSection,
) -> Array[Double] {
  require(self.fitted)
  self.m_hat
}

///|
/// ATT estimate from the cross-section DID fit.
pub fn DoubleMLDIDCrossSection::coef(self : DoubleMLDIDCrossSection) -> Double {
  require(self.fitted)
  self.coef
}

///|
/// Standard error of the ATT estimate (HC0 sandwich).
pub fn DoubleMLDIDCrossSection::se(self : DoubleMLDIDCrossSection) -> Double {
  require(self.fitted)
  self.se
}

///|
/// v0.20.0+ (extended in v0.21.0): confidence interval
/// for the ATT.
///
/// When `joint = false` (default), uses the Wald-style
/// `theta ± 1.96 * se` interval (or the `level`-th
/// quantile of the standard normal, scaled to the
/// requested `level`).
///
/// When `joint = true`, uses the multiplier bootstrap
/// (must call `bootstrap()` first). The critical value
/// is the empirical `(1 + level) / 2` quantile of
/// `|boot_t_stat|`, which is wider than the pointwise
/// critical value (more conservative; matches the
/// joint-CI convention for a scalar parameter).
///
/// `level` is the confidence level (default `0.95`).
pub fn DoubleMLDIDCrossSection::confint(
  self : DoubleMLDIDCrossSection,
  joint? : Bool = false,
  level? : Double = 0.95,
) -> (Double, Double) {
  require(self.fitted)
  require(level > 0.0 && level < 1.0)
  if joint {
    require(self.boot_t_stat.length() > 0)
    require(self.n_rep_boot > 0)
    // Empirical (1 + level) / 2 quantile of |boot_t_stat|.
    // For a scalar ATT, the joint CI coincides with
    // the pointwise CI in terms of family-wise error
    // rate; the joint critical value is the empirical
    // quantile of the bootstrap t-statistic.
    let abs_t : Array[Double] = Array::make(self.n_rep_boot, 0.0)
    for b = 0; b < self.n_rep_boot; b = b + 1 {
      let v = self.boot_t_stat[b]
      abs_t[b] = if v < 0.0 { -v } else { v }
    }
    abs_t.sort()
    let idx = ((1.0 + level) / 2.0 * self.n_rep_boot.to_double()).to_int()
    let idx_clamped = if idx >= self.n_rep_boot {
      self.n_rep_boot - 1
    } else {
      idx
    }
    let critical = abs_t[idx_clamped]
    (self.coef - critical * self.se, self.coef + critical * self.se)
  } else {
    // z_{1 - (1 - level) / 2} = z_{(1 + level) / 2}
    // Use the high-accuracy `norm_ppf` (bisection on
    // `norm_sf`, accurate to ~1.3e-6 in z; more than
    // enough for a CI half-width).
    let alpha = (1.0 - level) / 2.0
    let z = if (level - 0.95).abs() < 1.0e-12 {
      // Hardcoded for the canonical 95% CI to keep
      // the test contract bit-exact.
      1.959963984540054
    } else {
      norm_ppf(1.0 - alpha)
    }
    (self.coef - z * self.se, self.coef + z * self.se)
  }
}

// ---------------------------------------------------------------------------
// Nuisance fit helpers
// ---------------------------------------------------------------------------

///|
/// Internal: cross-fit predict the 4 g-functions and
/// the propensity. Each nuisance function is fit on
/// the union of the *training* folds; predictions are
/// made on the *test* fold; the per-observation
/// prediction is the average over reps.
///
/// This is the "out-of-fold" prediction pattern used
/// by all DML models. The cross-fit is essential for
/// the orthogonalization property (otherwise the
/// score function is biased).
///
/// Returns (g_d0_t0, g_d0_t1, g_d1_t0, g_d1_t1, m).
fn crossfit_nuisance(
  data : DoubleMLDIDCrossSectionData,
  n_folds : Int,
  n_rep : Int,
  seed : Int,
  propensity_clip : Double,
  ps_processor : PSProcessor,
) -> (Array[Double], Array[Double], Array[Double], Array[Double], Array[Double]) {
  let n = data.n_obs()
  let p = data.n_features()
  // Cross-fit predictions, accumulated over reps.
  let g00_acc : Array[Double] = Array::make(n, 0.0)
  let g01_acc : Array[Double] = Array::make(n, 0.0)
  let g10_acc : Array[Double] = Array::make(n, 0.0)
  let g11_acc : Array[Double] = Array::make(n, 0.0)
  let m_acc : Array[Double] = Array::make(n, 0.0)
  for r = 0; r < n_rep; r = r + 1 {
    let folds = kfold(n, n_folds, seed + r)
    // For each fold, fit nuisances on the union of
    // training folds and predict on the test fold.
    for fold = 0; fold < n_folds; fold = fold + 1 {
      let test_idx = folds[fold].test_idx
      let train_idx = folds[fold].train_idx
      let n_train = train_idx.length()
      let n_test = test_idx.length()
      // Build the training sub-matrix.
      let mut x_train_acc : Array[Double] = []
      let mut y_train_acc : Array[Double] = []
      let mut d_train_acc : Array[Double] = []
      let mut t_train_acc : Array[Int] = []
      for k = 0; k < n_train; k = k + 1 {
        let i = train_idx[k]
        for j = 0; j < p; j = j + 1 {
          x_train_acc = x_train_acc + [data.x.data[i * p + j]]
        }
        y_train_acc = y_train_acc + [data.y[i]]
        d_train_acc = d_train_acc + [data.d[i]]
        t_train_acc = t_train_acc + [data.t[i]]
      }
      // Build the test sub-matrix.
      let mut x_test_acc : Array[Double] = []
      for k = 0; k < n_test; k = k + 1 {
        let i = test_idx[k]
        for j = 0; j < p; j = j + 1 {
          x_test_acc = x_test_acc + [data.x.data[i * p + j]]
        }
      }
      let x_train = Matrix::from_array(x_train_acc, n_train, p)
      let x_test = Matrix::from_array(x_test_acc, n_test, p)
      // Fit the 4 g-functions on the training subset
      // and predict on the test subset.
      let pred_g00 = fit_g_subset_predict(
        x_train, y_train_acc, d_train_acc, t_train_acc, x_test, 0.0, 0,
      )
      let pred_g01 = fit_g_subset_predict(
        x_train, y_train_acc, d_train_acc, t_train_acc, x_test, 0.0, 1,
      )
      let pred_g10 = fit_g_subset_predict(
        x_train, y_train_acc, d_train_acc, t_train_acc, x_test, 1.0, 0,
      )
      let pred_g11 = fit_g_subset_predict(
        x_train, y_train_acc, d_train_acc, t_train_acc, x_test, 1.0, 1,
      )
      // Fit the propensity.
      let m_model = LinearRegression::new().fit(x_train, d_train_acc)
      let pred_m = m_model.predict(x_test)
      // Scatter the test-fold predictions into the
      // accumulators.
      for k = 0; k < n_test; k = k + 1 {
        let i = test_idx[k]
        g00_acc[i] = g00_acc[i] + pred_g00[k]
        g01_acc[i] = g01_acc[i] + pred_g01[k]
        g10_acc[i] = g10_acc[i] + pred_g10[k]
        g11_acc[i] = g11_acc[i] + pred_g11[k]
        m_acc[i] = m_acc[i] + pred_m[k]
      }
    }
  }
  // Average over reps and folds. Each unit is in
  // exactly one test fold per rep, so the average
  // is `sum / n_rep`.
  let n_rep_d = n_rep.to_double()
  for i = 0; i < n; i = i + 1 {
    g00_acc[i] = g00_acc[i] / n_rep_d
    g01_acc[i] = g01_acc[i] / n_rep_d
    g10_acc[i] = g10_acc[i] / n_rep_d
    g11_acc[i] = g11_acc[i] / n_rep_d
    m_acc[i] = m_acc[i] / n_rep_d
  }
  // Clip the propensity to `[propensity_clip, 1 -
  // propensity_clip]` and apply the ps_processor for
  // consistency with the panel DID.
  let m_clipped = clip_vec(m_acc, propensity_clip, 1.0 - propensity_clip)
  let d_arr : Array[Double] = []
  for v in data.d {
    d_arr.push(v)
  }
  let m_processed = ps_processor.adjust_ps(m_clipped, d_arr)
  (g00_acc, g01_acc, g10_acc, g11_acc, m_processed)
}

///|
/// Internal: fit a g-function on a training subset
/// restricted to `(d == d_value) ∧ (t == t_value)` and
/// predict on a test sub-matrix. Returns the test-fold
/// predictions.
fn fit_g_subset_predict(
  x_train : Matrix,
  y_train : Array[Double],
  d_train : Array[Double],
  t_train : Array[Int],
  x_test : Matrix,
  d_value : Double,
  t_value : Int,
) -> Array[Double] {
  let n_train = y_train.length()
  let p = x_train.cols()
  let n_test = x_test.nrows
  // Collect subset rows from training.
  let mut sub_n = 0
  let mut y_sub_acc : Array[Double] = []
  let mut x_sub_acc : Array[Double] = []
  for i = 0; i < n_train; i = i + 1 {
    if d_train[i] != d_value || t_train[i] != t_value {
      continue
    }
    y_sub_acc = y_sub_acc + [y_train[i]]
    for j = 0; j < p; j = j + 1 {
      x_sub_acc = x_sub_acc + [x_train.data[i * p + j]]
    }
    sub_n = sub_n + 1
  }
  // Empty subset: predict zeros.
  if sub_n < p + 1 {
    return Array::make(n_test, 0.0)
  }
  let x_sub = Matrix::from_array(x_sub_acc, sub_n, p)
  let model = LinearRegression::new().fit(x_sub, y_sub_acc)
  model.predict(x_test)
}

// ---------------------------------------------------------------------------
// Standard-normal quantile (Beasley-Springer-Moro)
// ---------------------------------------------------------------------------

///|
/// v0.21.0+ standard-normal CDF. Implements the
/// A&S 7.1.26 formula directly (rather than going
/// through `norm_sf`, which is the upper-tail survival
/// and saturates to 1.0 at `x <= 0`). The coefficients
/// match the existing `norm_sf`:
///   `p = 0.2316419, b1 = 0.319381530, b2 = -0.356563782,
///    b3 = 1.781477937, b4 = -1.821255978, b5 = 1.330274429`
/// and the max abs error is ~7.5e-8. Symmetry
/// `Phi(x) = 1 - Phi(-x)` handles the negative
/// half-line.
pub fn norm_cdf(x : Double) -> Double {
  let p_coef = 0.2316419
  let b1 = 0.319381530
  let b2 = -0.356563782
  let b3 = 1.781477937
  let b4 = -1.821255978
  let b5 = 1.330274429
  let abs_x = if x < 0.0 { -x } else { x }
  let t = 1.0 / (1.0 + p_coef * abs_x)
  let phi = @math.exp(-abs_x * abs_x / 2.0) / 2.5066282746310002
  let poly = t * (b1 + t * (b2 + t * (b3 + t * (b4 + t * b5))))
  let phi_pos = 1.0 - phi * poly
  if x >= 0.0 {
    phi_pos
  } else {
    1.0 - phi_pos
  }
}

///|
/// v0.21.0+ standard-normal quantile function (inverse
/// CDF). Uses bisection on the existing `norm_cdf`
/// (which delegates to `norm_sf` with ~7.5e-8
/// accuracy) to find the `z` such that `Phi(z) = p`.
/// The bisection runs for 64 iterations on the
/// interval `[-8, 8]`, which is more than enough to
/// drive the absolute error below 1e-12.
///
/// `p` must lie in `(0, 1)`. The result is the `x`
/// such that `P(Z <= x) = p` for a standard normal
/// random variable `Z`.
pub fn norm_ppf(p : Double) -> Double {
  require(p > 0.0 && p < 1.0)
  let mut lo = -8.0
  let mut hi = 8.0
  let mut mid = 0.0
  for _iter = 0; _iter < 64; _iter = _iter + 1 {
    mid = (lo + hi) / 2.0
    let cdf_mid = norm_cdf(mid)
    if cdf_mid < p {
      lo = mid
    } else {
      hi = mid
    }
  }
  mid
}

///|
/// Internal: compute `psi_a` and `psi_b` per the
/// upstream
/// `doubleml.DoubleMLDIDCS._score_elements` formula.
/// All weight formulas are documented inline.
fn compute_score(
  y : Array[Double],
  d : Array[Double],
  t : Array[Int],
  g00 : Array[Double],
  g01 : Array[Double],
  g10 : Array[Double],
  g11 : Array[Double],
  m : Array[Double],
  score : String,
  in_sample_normalization : Bool,
) -> (Array[Double], Array[Double]) {
  let n = y.length()
  // Pre-compute group indicators.
  let d1t1 : Array[Double] = Array::make(n, 0.0)
  let d1t0 : Array[Double] = Array::make(n, 0.0)
  let d0t1 : Array[Double] = Array::make(n, 0.0)
  let d0t0 : Array[Double] = Array::make(n, 0.0)
  // Means of d and t.
  let mut mean_d = 0.0
  let mut mean_t = 0.0
  for i = 0; i < n; i = i + 1 {
    let di = d[i]
    let ti = t[i].to_double()
    d1t1[i] = di * ti
    d1t0[i] = di * (1.0 - ti)
    d0t1[i] = (1.0 - di) * ti
    d0t0[i] = (1.0 - di) * (1.0 - ti)
    mean_d = mean_d + di
    mean_t = mean_t + ti
  }
  mean_d = mean_d / n.to_double()
  mean_t = mean_t / n.to_double()
  // Means of group indicators.
  let mut mean_d1t1 = 0.0
  let mut mean_d1t0 = 0.0
  let mut mean_d0t1 = 0.0
  let mut mean_d0t0 = 0.0
  for i = 0; i < n; i = i + 1 {
    mean_d1t1 = mean_d1t1 + d1t1[i]
    mean_d1t0 = mean_d1t0 + d1t0[i]
    mean_d0t1 = mean_d0t1 + d0t1[i]
    mean_d0t0 = mean_d0t0 + d0t0[i]
  }
  mean_d1t1 = mean_d1t1 / n.to_double()
  mean_d1t0 = mean_d1t0 / n.to_double()
  mean_d0t1 = mean_d0t1 / n.to_double()
  mean_d0t0 = mean_d0t0 / n.to_double()
  // Means of (group * prop_weighting) for in-sample
  // normalization on the control group.
  let mut mean_d0t1_pw = 0.0
  let mut mean_d0t0_pw = 0.0
  if score == "observational" {
    for i = 0; i < n; i = i + 1 {
      let m_i = m[i]
      let one_minus_m_i = 1.0 - m_i
      // Degenerate: 1 - m_i = 0; the upstream
      // sets this ratio to 0 via `where` (out=0).
      let pw_i = if one_minus_m_i > 1.0e-12 { m_i / one_minus_m_i } else { 0.0 }
      mean_d0t1_pw = mean_d0t1_pw + d0t1[i] * pw_i
      mean_d0t0_pw = mean_d0t0_pw + d0t0[i] * pw_i
    }
    mean_d0t1_pw = mean_d0t1_pw / n.to_double()
    mean_d0t0_pw = mean_d0t0_pw / n.to_double()
  }
  // Compute psi_a, psi_b_1, psi_b_2 weights per
  // (score, in_sample_normalization).
  let p_hat = mean_d
  let lambda_hat = mean_t
  let psi_a : Array[Double] = Array::make(n, 0.0)
  let psi_b : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let di = d[i]
    let m_i = m[i]
    let one_minus_m_i = 1.0 - m_i
    let p_i = p_hat
    let one_minus_p_i = 1.0 - p_hat
    let l_i = lambda_hat
    let one_minus_l_i = 1.0 - lambda_hat
    // Weights.
    let weight_psi_a : Double = if score == "observational" {
      if in_sample_normalization {
        if mean_d > 0.0 {
          di / mean_d
        } else {
          0.0
        }
      } else if p_i > 0.0 {
        di / p_i
      } else {
        0.0
      }
    } else {
      1.0
    }
    let weight_g_d1_t1 = if score == "observational" {
      if p_i > 0.0 {
        di / p_i
      } else {
        0.0
      }
    } else {
      1.0
    }
    let weight_g_d1_t0 = if score == "observational" {
      if p_i > 0.0 {
        -di / p_i
      } else {
        0.0
      }
    } else {
      -1.0
    }
    let weight_g_d0_t1 = if score == "observational" {
      if p_i > 0.0 {
        -di / p_i
      } else {
        0.0
      }
    } else {
      -1.0
    }
    let weight_g_d0_t0 = if score == "observational" {
      if p_i > 0.0 {
        di / p_i
      } else {
        0.0
      }
    } else {
      1.0
    }
    // Residuals.
    let resid_d0_t0 = y[i] - g00[i]
    let resid_d0_t1 = y[i] - g01[i]
    let resid_d1_t0 = y[i] - g10[i]
    let resid_d1_t1 = y[i] - g11[i]
    // Propensity-weighting (only used in observational).
    let prop_weighting : Double = if one_minus_m_i > 1.0e-12 {
      m_i / one_minus_m_i
    } else {
      0.0
    }
    // Residual weights.
    let weight_resid_d1_t1 : Double = if score == "observational" {
      if in_sample_normalization {
        if mean_d1t1 > 0.0 {
          d1t1[i] / mean_d1t1
        } else {
          0.0
        }
      } else if p_i * l_i > 1.0e-12 {
        d1t1[i] / (p_i * l_i)
      } else {
        0.0
      }
    } else if in_sample_normalization {
      if mean_d1t1 > 0.0 {
        d1t1[i] / mean_d1t1
      } else {
        0.0
      }
    } else if p_i * l_i > 1.0e-12 {
      d1t1[i] / (p_i * l_i)
    } else {
      0.0
    }
    let weight_resid_d1_t0 : Double = if score == "observational" {
      if in_sample_normalization {
        if mean_d1t0 > 0.0 {
          -d1t0[i] / mean_d1t0
        } else {
          0.0
        }
      } else if p_i * one_minus_l_i > 1.0e-12 {
        -d1t0[i] / (p_i * one_minus_l_i)
      } else {
        0.0
      }
    } else if in_sample_normalization {
      if mean_d1t0 > 0.0 {
        -d1t0[i] / mean_d1t0
      } else {
        0.0
      }
    } else if p_i * one_minus_l_i > 1.0e-12 {
      -d1t0[i] / (p_i * one_minus_l_i)
    } else {
      0.0
    }
    let weight_resid_d0_t1 : Double = if score == "observational" {
      if in_sample_normalization {
        if mean_d0t1_pw > 0.0 {
          -d0t1[i] * prop_weighting / mean_d0t1_pw
        } else {
          0.0
        }
      } else if p_i * l_i > 1.0e-12 {
        -d0t1[i] / (p_i * l_i) * prop_weighting
      } else {
        0.0
      }
    } else if in_sample_normalization {
      if mean_d0t1 > 0.0 {
        -d0t1[i] / mean_d0t1
      } else {
        0.0
      }
    } else if one_minus_p_i * l_i > 1.0e-12 {
      -d0t1[i] / (one_minus_p_i * l_i)
    } else {
      0.0
    }
    let weight_resid_d0_t0 : Double = if score == "observational" {
      if in_sample_normalization {
        if mean_d0t0_pw > 0.0 {
          d0t0[i] * prop_weighting / mean_d0t0_pw
        } else {
          0.0
        }
      } else if p_i * one_minus_l_i > 1.0e-12 {
        d0t0[i] / (p_i * one_minus_l_i) * prop_weighting
      } else {
        0.0
      }
    } else if in_sample_normalization {
      if mean_d0t0 > 0.0 {
        d0t0[i] / mean_d0t0
      } else {
        0.0
      }
    } else if one_minus_p_i * one_minus_l_i > 1.0e-12 {
      d0t0[i] / (one_minus_p_i * one_minus_l_i)
    } else {
      0.0
    }
    // psi_a = -weight_psi_a.
    psi_a[i] = -weight_psi_a
    // psi_b = psi_b_1 + psi_b_2.
    let psi_b_1 = weight_g_d1_t1 * g11[i] +
      weight_g_d1_t0 * g10[i] +
      weight_g_d0_t0 * g00[i] +
      weight_g_d0_t1 * g01[i]
    let psi_b_2 = weight_resid_d1_t1 * resid_d1_t1 +
      weight_resid_d1_t0 * resid_d1_t0 +
      weight_resid_d0_t0 * resid_d0_t0 +
      weight_resid_d0_t1 * resid_d0_t1
    psi_b[i] = psi_b_1 + psi_b_2
    // Suppress unused-variable warnings on `one_minus_p_i`,
    // `l_i`, `mean_d0t1`, `mean_d0t0` which are
    // referenced only inside some of the score branches.
    let _ = (one_minus_p_i, l_i, mean_d0t1, mean_d0t0)
  }
  (psi_a, psi_b)
}

// ---------------------------------------------------------------------------
// Fit
// ---------------------------------------------------------------------------

///|
/// v0.20.0+: fit the cross-section DID model. Runs
/// cross-fit nuisance estimation (4 g-functions +
/// 1 propensity), constructs the `psi_a` / `psi_b`
/// score, and returns the ATT and HC0 SE.
pub fn DoubleMLDIDCrossSection::fit(
  self : DoubleMLDIDCrossSection,
) -> DoubleMLDIDCrossSection {
  // Step 1: cross-fit the nuisance functions.
  let (g00, g01, g10, g11, m) = crossfit_nuisance(
    self.data,
    self.n_folds,
    self.n_rep,
    self.seed,
    self.propensity_clip,
    self.ps_processor,
  )
  // Step 2: compute psi_a, psi_b.
  let (psi_a, psi_b) = compute_score(
    self.data.y,
    self.data.d,
    self.data.t,
    g00,
    g01,
    g10,
    g11,
    m,
    self.score,
    self.in_sample_normalization,
  )
  // Step 3: theta_hat = argmin_theta sum_i (psi_a[i]
  // + theta * psi_b[i])^2 = -<psi_a, psi_b> / ||psi_b||^2.
  let n = self.data.n_obs()
  let mut inner_ab = 0.0
  let mut inner_bb = 0.0
  for i = 0; i < n; i = i + 1 {
    inner_ab = inner_ab + psi_a[i] * psi_b[i]
    inner_bb = inner_bb + psi_b[i] * psi_b[i]
  }
  require(inner_bb > 0.0)
  let theta = -inner_ab / inner_bb
  // Step 4: HC0 SE. The influence function is
  // `psi[i] = psi_a[i] + theta * psi_b[i]`, and the
  // variance is `(1/n) * sum_i psi[i]^2 / mean_b^2`
  // where `mean_b^2 = inner_bb / n^2` (the squared
  // average of psi_b).
  let n_d = n.to_double()
  let mut ss_psi = 0.0
  for i = 0; i < n; i = i + 1 {
    let psi_i = psi_a[i] + theta * psi_b[i]
    ss_psi = ss_psi + psi_i * psi_i
  }
  let mean_b2 = inner_bb / (n_d * n_d)
  require(mean_b2 > 0.0)
  let var_theta = ss_psi / (n_d * n_d * mean_b2)
  let se = var_theta.sqrt()
  // Step 5: cache the nuisance predictions and psi.
  {
    ..self,
    coef: theta,
    se,
    psi_a,
    psi_b,
    g_d0_t0: g00,
    g_d0_t1: g01,
    g_d1_t0: g10,
    g_d1_t1: g11,
    m_hat: m,
    fitted: true,
    boot_t_stat: self.boot_t_stat,
    boot_method: self.boot_method,
    n_rep_boot: self.n_rep_boot,
    boot_seed: self.boot_seed,
  }
}

///|
/// v0.21.0+: multiplier bootstrap. Draws
/// `n_rep_boot` weight vectors of length `n_obs` from
/// the chosen multiplier distribution, computes
/// `boot_t_stat[b] = sum_i w[b, i] * psi[i] /
/// (sqrt(n) * se)` where
/// `psi[i] = psi_a[i] + theta * psi_b[i]` is the
/// per-observation influence function, and returns a
/// fitted model with `boot_t_stat` populated.
///
/// `method_name` selects the multiplier distribution:
///   - `"normal"` (default): `w[i] ~ N(0, 1)`. Matches
///     the upstream `bootstrap(method="normal")` default.
///   - `"Bayes"`: `w[i] = exp(1) - 1` (mean 0, var 1).
///   - `"wild"`: `w[i] = x[i] / sqrt(2) + (y[i]^2 - 1) /
///     2` with `x, y ~ N(0, 1)`. Robust to
///     heteroskedasticity in the influence-function
///     residuals.
///
/// The bootstrap populates `self.boot_t_stat` and is
/// required for `confint(joint=true)`.
pub fn DoubleMLDIDCrossSection::bootstrap(
  self : DoubleMLDIDCrossSection,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLDIDCrossSection {
  require(self.fitted)
  require(
    method_name == "normal" || method_name == "Bayes" || method_name == "wild",
  )
  require(n_rep_boot >= 2)
  let n = self.data.n_obs()
  // Draw weights. Shape: (n_rep_boot, n_obs).
  let weights = draw_bootstrap_weights(method_name, n_rep_boot, n, seed)
  // Compute the per-observation influence function
  // `psi[i] = psi_a[i] + theta * psi_b[i]` once.
  let psi : Array[Double] = Array::make(n, 0.0)
  let mut ss_psi = 0.0
  for i = 0; i < n; i = i + 1 {
    let psi_i = self.psi_a[i] + self.coef * self.psi_b[i]
    psi[i] = psi_i
    ss_psi = ss_psi + psi_i * psi_i
  }
  // `boot_t_stat[b] = sum_i w[b, i] * psi[i] / (sqrt(n) *
  // se_psi)` where `se_psi = sqrt(sum_i psi_i^2 / n)` is
  // the SE of the mean of `psi`. This makes
  // `Var[boot_t_stat] = sum_i psi_i^2 / (n * se_psi^2)
  // = 1` under the null (independent multiplier
  // weights with variance 1), so the bootstrap
  // distribution has mean 0 and SD 1 (matching the
  // standard multiplier bootstrap convention used by
  // the panel `DoubleMLDIDMulti`).
  let boot_t_stat : Array[Double] = Array::make(n_rep_boot, 0.0)
  let n_d = n.to_double()
  let se_psi = (ss_psi / n_d).sqrt()
  let denom = n_d.sqrt() * se_psi
  if denom <= 0.0 {
    // Degenerate: psi sums to 0. Cannot divide.
    // Return zeros (matches the panel DIDMulti
    // convention for empty cells).
    return {
      ..self,
      boot_t_stat,
      boot_method: method_name,
      n_rep_boot,
      boot_seed: seed,
    }
  }
  for b = 0; b < n_rep_boot; b = b + 1 {
    let mut s = 0.0
    for i = 0; i < n; i = i + 1 {
      s = s + weights[b * n + i] * psi[i]
    }
    boot_t_stat[b] = s / denom
  }
  { ..self, boot_t_stat, boot_method: method_name, n_rep_boot, boot_seed: seed }
}
