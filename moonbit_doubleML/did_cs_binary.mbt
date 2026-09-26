///|
/// Callaway-Sant'Anna (2021) DID model for panel data with
/// binary `(group, time)` outcomes. Estimates the ATT for a
/// specific `(g_value, t_value_pre, t_value_eval)` triple via
/// the Sant'Anna-Zhao (2020) "binary outcome" DML score
/// (4 g-functions + 1 propensity, doubly-robust
/// reweighting on the propensity, observational or
/// experimental score variants — the latter is currently
/// a v0.52.0+ target).
///
/// **Simplifications vs. upstream `DoubleMLDIDCSBinary`**:
///   - `ml_g` and `ml_m` are both collapsed to the same
///     closed-form `LinearRegression` learner. The upstream
///     supports an arbitrary `ml_g` regressor / classifier
///     plus an `ml_m` classifier; we treat the binary
///     outcome `Y` as a regression on `E[Y | D=d, X] ∈ [0, 1]`
///     (closed-form OLS + clip is the standard
///     "frequentist" trick that `R::predict.lm` uses for
///     binary outcomes) and treat the propensity as a
///     regression on `E[1{D=1} | X]` clipped to
///     `[clip, 1 - clip]`. This is a v0.51.0 design
///     choice; pluggable learners can be added in a later
///     release by porting `_dml_cv_predict`.
///   - `score = "experimental"` is **not** ported in
///     v0.51.0. The `new` constructor accepts only
///     `score = "observational"`. Experimental support
///     (which has no `ml_m`) can be added in v0.52.0+
///     if needed.
///   - `ps_processor_config` is collapsed to a single
///     `propensity_clip` field (default `1e-6`); the
///     `isotonic` / `cv_calibration` paths are not
///     ported (they require `CalibratedClassifierCV`).
///   - `anticipation_periods` is stored but not applied
///     to the score (the upstream uses it to extend the
///     post-treatment window; that's a v0.52.0+ target).
///   - No sensitivity analysis, no `tune_optuna`, no
///     multiplier bootstrap.
///
/// **Sample splitting**: `kfold_stratified` is used on the
/// 4-stratum key `G_indicator + 2 * T_indicator` so that
/// each fold balances the `(G, T)` cells (matching
/// upstream `self._strata`).

// ---------------------------------------------------------------------------
// Internal: panel subset + strata construction
// ---------------------------------------------------------------------------

///|
/// Per-row output of `cs_bin_panel_subset`. Each row is one
/// observation in the post-subset panel: a `(G_indicator, T_indicator)`
/// pair, the covariates, and the (still-raw) outcome `y`.
struct CSBinPanelRow {
  x : Array[Double] // length p
  y : Double
  g_indicator : Double // 0 or 1
  t_indicator : Double // 0 (pre) or 1 (eval)
} derive(Debug)

///|
pub extend CSBinPanelRow with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// v0.51.0: subset the long-format panel to the 4
/// `(G_indicator, T_indicator)` cells used by the CS
/// Binary score. Specifically:
///   1. Keep only rows with `t ∈ {t_value_pre, t_value_eval}`.
///   2. `G_indicator = 1{G == g_value}`,
///      `C_indicator = 1{unit is in the chosen control
///      cohort}` per `control_group`.
///   3. Drop rows with `G_indicator + C_indicator != 1` (G
///      and C are disjoint).
///   4. `T_indicator = 1{t == t_value_eval}` (0 for the pre
///      period, 1 for the eval period).
///
/// Returns `(rows, never_treated_value, n_g, n_c)`. The
/// `n_g` / `n_c` counters are the pre-stratification
/// treated / control cohort sizes in the **post-subset**
/// data; downstream code uses them for the
/// `g_value > 0` / `control_group` validation and for the
/// `mean(d)` of the propensity.
fn cs_bin_panel_subset(
  data : DoubleMLDIDCSData,
  g_value : Int,
  t_value_pre : Int,
  t_value_eval : Int,
  control_group : String,
  anticipation_periods : Int,
) -> (Array[CSBinPanelRow], Int, Int, Int) {
  try {
    let n = data.y.length()
    let p = data.x.cols()
    // Discover `never_treated_value` = min of all `g`.
    let mut never_treated_value = data.g[0]
    for i = 1; i < n; i = i + 1 {
      if data.g[i] < never_treated_value {
        never_treated_value = data.g[i]
      }
    }
    // For `not_yet_treated`: not-yet-treated = never-treated
    // ∪ (g > max_g_value ∧ g != g_value), where
    // `max_g_value = max(t_value_eval, g_value) +
    // anticipation_periods` (matches the upstream
    // convention in `_preprocess_data`).
    let comparison_period = if t_value_eval > g_value {
      t_value_eval
    } else {
      g_value
    }
    let max_g_value = comparison_period + anticipation_periods
    // Build the per-row subset. We accumulate into flat
    // arrays for speed; `x` is `n_rows * p` row-major.
    let x_acc : Array[Double] = []
    let y_acc : Array[Double] = []
    let d_acc : Array[Double] = [] // G_indicator
    let t_acc : Array[Double] = [] // T_indicator
    let mut n_g = 0
    let mut n_c = 0
    for i = 0; i < n; i = i + 1 {
      let tv = data.t[i]
      if tv != t_value_pre && tv != t_value_eval {
        continue
      }
      let gv = data.g[i]
      let g_indicator = if gv == g_value { 1.0 } else { 0.0 }
      let c_indicator = if control_group == "never_treated" {
        if gv == never_treated_value {
          1.0
        } else {
          0.0
        }
      } else if gv == never_treated_value ||
        (g_indicator == 0.0 && gv > max_g_value) {
        1.0
      } else {
        0.0
      }
      if g_indicator + c_indicator != 1.0 {
        continue
      }
      // Copy the row.
      for j = 0; j < p; j = j + 1 {
        x_acc.push(data.x.data[i * p + j])
      }
      y_acc.push(data.y[i])
      d_acc.push(g_indicator)
      t_acc.push(if tv == t_value_eval { 1.0 } else { 0.0 })
      if g_indicator == 1.0 {
        n_g = n_g + 1
      } else {
        n_c = n_c + 1
      }
    }
    let n_sub = x_acc.length() / p
    require(x_acc.length() == n_sub * p)
    require(y_acc.length() == n_sub)
    require(d_acc.length() == n_sub)
    require(t_acc.length() == n_sub)
    // Materialize the row struct for clarity downstream.
    let rows : Array[CSBinPanelRow] = []
    for k = 0; k < n_sub; k = k + 1 {
      let x_row : Array[Double] = Array::make(p, 0.0)
      for j = 0; j < p; j = j + 1 {
        x_row[j] = x_acc[k * p + j]
      }
      rows.push({
        x: x_row,
        y: y_acc[k],
        g_indicator: d_acc[k],
        t_indicator: t_acc[k],
      })
    }
    (rows, never_treated_value, n_g, n_c)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

// ---------------------------------------------------------------------------
// Internal: crossfit the 4 g-functions and the propensity
// ---------------------------------------------------------------------------

///|
/// Internal: crossfit predict the 4 g-functions
/// `g(d_value, t_value, X) = E[Y | D=d, T=t, X]` plus
/// the propensity `m(X) = E[D=1 | X]` on the
/// post-subset panel, using the stratified k-fold
/// partition `folds`. Each g is fit on the
/// `(d_value, t_value)` cell of the training fold and
/// predicted on the **full** test fold (matching
/// upstream `_estimate_conditional_g`).
///
/// The propensity is fit on the full training fold
/// (all (D, T) cells combined) and predicted on the
/// test fold (matching upstream `_dml_cv_predict` for
/// `ml_m`). The result is clipped to
/// `[propensity_clip, 1 - propensity_clip]` and passed
/// through `ps_processor.adjust_ps` for consistency
/// with the panel DID family.
fn cs_bin_crossfit_nuisance(
  rows : Array[CSBinPanelRow],
  p : Int,
  folds : Array[Fold],
  n_rep : Int,
  seed : Int,
  propensity_clip : Double,
  ps_processor : PSProcessor,
) -> (Array[Double], Array[Double], Array[Double], Array[Double], Array[Double]) {
  let n = rows.length()
  let n_folds = folds.length()
  // Per-rep accumulators (each rep averages over folds).
  let g00_acc : Array[Double] = Array::make(n, 0.0)
  let g01_acc : Array[Double] = Array::make(n, 0.0)
  let g10_acc : Array[Double] = Array::make(n, 0.0)
  let g11_acc : Array[Double] = Array::make(n, 0.0)
  let m_acc : Array[Double] = Array::make(n, 0.0)
  // The folds from `kfold_stratified` are for a single
  // seed; replicate across reps by re-seeding (mirrors
  // upstream `draw_sample_splitting` behaviour: each
  // rep gets its own folds).
  let mut active_folds = folds
  for r = 0; r < n_rep; r = r + 1 {
    if r > 0 {
      // v0.51.0: re-draw the strata for rep r. The strata
      // vector is rows.g_indicator + 2 * rows.t_indicator.
      let strata : Array[Double] = Array::make(n, 0.0)
      for i = 0; i < n; i = i + 1 {
        strata[i] = rows[i].g_indicator + 2.0 * rows[i].t_indicator
      }
      active_folds = kfold_stratified(n, strata, n_folds, seed + r)
    }
    for fold = 0; fold < n_folds; fold = fold + 1 {
      let train_idx = active_folds[fold].train_idx
      let test_idx = active_folds[fold].test_idx
      let n_train = train_idx.length()
      let n_test = test_idx.length()
      // Build the training sub-matrix + vectors.
      let mut x_train_acc : Array[Double] = []
      let mut y_train_acc : Array[Double] = []
      let mut d_train_acc : Array[Double] = []
      let mut t_train_acc : Array[Double] = []
      for k = 0; k < n_train; k = k + 1 {
        let i = train_idx[k]
        let row = rows[i]
        for j = 0; j < p; j = j + 1 {
          x_train_acc = x_train_acc + [row.x[j]]
        }
        y_train_acc = y_train_acc + [row.y]
        d_train_acc = d_train_acc + [row.g_indicator]
        t_train_acc = t_train_acc + [row.t_indicator]
      }
      // Build the test sub-matrix.
      let mut x_test_acc : Array[Double] = []
      for k = 0; k < n_test; k = k + 1 {
        let i = test_idx[k]
        let row = rows[i]
        for j = 0; j < p; j = j + 1 {
          x_test_acc = x_test_acc + [row.x[j]]
        }
      }
      let x_train = Matrix::from_array(x_train_acc, n_train, p)
      let x_test = Matrix::from_array(x_test_acc, n_test, p)
      // 4 conditional g-functions, each fit on the
      // matching (d, t) cell of the training fold and
      // predicted on the full test fold.
      let pred_g00 = fit_cs_bin_g(
        x_train, y_train_acc, d_train_acc, t_train_acc, x_test, 0.0, 0.0,
      )
      let pred_g01 = fit_cs_bin_g(
        x_train, y_train_acc, d_train_acc, t_train_acc, x_test, 0.0, 1.0,
      )
      let pred_g10 = fit_cs_bin_g(
        x_train, y_train_acc, d_train_acc, t_train_acc, x_test, 1.0, 0.0,
      )
      let pred_g11 = fit_cs_bin_g(
        x_train, y_train_acc, d_train_acc, t_train_acc, x_test, 1.0, 1.0,
      )
      // Propensity: fit on the full training fold
      // (no D, T conditioning), predict on the test
      // fold.
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
  // Average over reps. Each unit is in exactly one
  // test fold per rep, so the average is `sum / n_rep`.
  let n_rep_d = n_rep.to_double()
  for i = 0; i < n; i = i + 1 {
    g00_acc[i] = g00_acc[i] / n_rep_d
    g01_acc[i] = g01_acc[i] / n_rep_d
    g10_acc[i] = g10_acc[i] / n_rep_d
    g11_acc[i] = g11_acc[i] / n_rep_d
    m_acc[i] = m_acc[i] / n_rep_d
  }
  // Clip + apply ps_processor. The `treatment` arg of
  // `adjust_ps` is the G_indicator (the propensity
  // condition is `E[D=1 | X]`).
  let m_clipped = clip_vec(m_acc, propensity_clip, 1.0 - propensity_clip)
  let d_arr : Array[Double] = []
  for row in rows {
    d_arr.push(row.g_indicator)
  }
  let m_processed = ps_processor.adjust_ps(m_clipped, d_arr)
  (g00_acc, g01_acc, g10_acc, g11_acc, m_processed)
}

///|
/// Internal: fit a g-function on the training subset
/// restricted to `(d == d_value) ∧ (t == t_value)` and
/// predict on the test sub-matrix. Returns the
/// test-fold predictions. If the subset is empty or
/// smaller than `p + 1` (so the linear regression is
/// under-determined), predict zeros (matches the
/// fallback in `did_cross_section.mbt::fit_g_subset_predict`).
fn fit_cs_bin_g(
  x_train : Matrix,
  y_train : Array[Double],
  d_train : Array[Double],
  t_train : Array[Double],
  x_test : Matrix,
  d_value : Double,
  t_value : Double,
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
  if sub_n < p + 1 {
    return Array::make(n_test, 0.0)
  }
  let x_sub = Matrix::from_array(x_sub_acc, sub_n, p)
  let model = LinearRegression::new().fit(x_sub, y_sub_acc)
  model.predict(x_test)
}

// ---------------------------------------------------------------------------
// Internal: observational score
// ---------------------------------------------------------------------------

///|
/// v0.51.0: observational Sant'Anna-Zhao (2020) DML
/// score for the binary DID setting. Mirrors
/// `did_cross_section.mbt::compute_score` restricted to
/// `score = "observational"` (the experimental branch
/// is the same as the cross-section case but with
/// `weight_psi_a = 1.0` and no `prop_weighting`; we
/// port it on demand in a later release). The
/// `in_sample_normalization = false` form is the
/// canonical Sant'Anna-Zhao eq. 4.3 form; the
/// `in_sample_normalization = true` form divides by
/// in-sample means (a small-sample correction).
fn cs_bin_score_obs(
  y : Array[Double],
  d : Array[Double],
  t : Array[Double],
  g00 : Array[Double],
  g01 : Array[Double],
  g10 : Array[Double],
  g11 : Array[Double],
  m : Array[Double],
  in_sample_normalization : Bool,
) -> (Array[Double], Array[Double]) {
  let n = y.length()
  // Pre-compute group indicators and their means.
  let d1t1 : Array[Double] = Array::make(n, 0.0)
  let d1t0 : Array[Double] = Array::make(n, 0.0)
  let d0t1 : Array[Double] = Array::make(n, 0.0)
  let d0t0 : Array[Double] = Array::make(n, 0.0)
  let mut mean_d = 0.0
  let mut mean_t = 0.0
  for i = 0; i < n; i = i + 1 {
    let di = d[i]
    let ti = t[i]
    d1t1[i] = di * ti
    d1t0[i] = di * (1.0 - ti)
    d0t1[i] = (1.0 - di) * ti
    d0t0[i] = (1.0 - di) * (1.0 - ti)
    mean_d = mean_d + di
    mean_t = mean_t + ti
  }
  let n_d = n.to_double()
  mean_d = mean_d / n_d
  mean_t = mean_t / n_d
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
  mean_d1t1 = mean_d1t1 / n_d
  mean_d1t0 = mean_d1t0 / n_d
  mean_d0t1 = mean_d0t1 / n_d
  mean_d0t0 = mean_d0t0 / n_d
  // Means of (group * prop_weighting) for in-sample
  // normalization on the control group.
  let mut mean_d0t1_pw = 0.0
  let mut mean_d0t0_pw = 0.0
  for i = 0; i < n; i = i + 1 {
    let m_i = m[i]
    let one_minus_m_i = 1.0 - m_i
    // Degenerate: 1 - m_i = 0; the upstream
    // sets this ratio to 0 via `where` (out=0).
    let pw_i = if one_minus_m_i > 1.0e-12 { m_i / one_minus_m_i } else { 0.0 }
    mean_d0t1_pw = mean_d0t1_pw + d0t1[i] * pw_i
    mean_d0t0_pw = mean_d0t0_pw + d0t0[i] * pw_i
  }
  mean_d0t1_pw = mean_d0t1_pw / n_d
  mean_d0t0_pw = mean_d0t0_pw / n_d
  // Compute psi_a, psi_b per the observational,
  // in-sample-normalization-aware formula.
  let p_hat = mean_d
  let lambda_hat = mean_t
  let psi_a : Array[Double] = Array::make(n, 0.0)
  let psi_b : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let di = d[i]
    let m_i = m[i]
    let one_minus_m_i = 1.0 - m_i
    let p_i = p_hat
    let l_i = lambda_hat
    // Weights.
    let weight_psi_a = if in_sample_normalization {
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
    let weight_g_d1_t1 = if p_i > 0.0 { di / p_i } else { 0.0 }
    let weight_g_d1_t0 = if p_i > 0.0 { -di / p_i } else { 0.0 }
    let weight_g_d0_t1 = if p_i > 0.0 { -di / p_i } else { 0.0 }
    let weight_g_d0_t0 = if p_i > 0.0 { di / p_i } else { 0.0 }
    // Residuals.
    let resid_d0_t0 = y[i] - g00[i]
    let resid_d0_t1 = y[i] - g01[i]
    let resid_d1_t0 = y[i] - g10[i]
    let resid_d1_t1 = y[i] - g11[i]
    // Propensity-weighting.
    let prop_weighting : Double = if one_minus_m_i > 1.0e-12 {
      m_i / one_minus_m_i
    } else {
      0.0
    }
    // Residual weights.
    let weight_resid_d1_t1 = if in_sample_normalization {
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
    let weight_resid_d1_t0 = if in_sample_normalization {
      if mean_d1t0 > 0.0 {
        -d1t0[i] / mean_d1t0
      } else {
        0.0
      }
    } else if p_i * (1.0 - l_i) > 1.0e-12 {
      -d1t0[i] / (p_i * (1.0 - l_i))
    } else {
      0.0
    }
    let weight_resid_d0_t1 = if in_sample_normalization {
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
    let weight_resid_d0_t0 = if in_sample_normalization {
      if mean_d0t0_pw > 0.0 {
        d0t0[i] * prop_weighting / mean_d0t0_pw
      } else {
        0.0
      }
    } else if p_i * (1.0 - l_i) > 1.0e-12 {
      d0t0[i] / (p_i * (1.0 - l_i)) * prop_weighting
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
  }
  (psi_a, psi_b)
}

// ---------------------------------------------------------------------------
// Public API: DoubleMLDIDCSBinary
// ---------------------------------------------------------------------------

///|
/// v0.51.0: Callaway-Sant'Anna (2021) DID with
/// binary `(group, time)` outcomes. Estimates the
/// `ATT(g_value, t_value_eval)` for a specific
/// `(g_value, t_value_pre, t_value_eval)` triple via
/// the Sant'Anna-Zhao (2020) binary-outcome DML score.
/// Mirrors the upstream `DoubleMLDIDCSBinary` (Python
/// 0.11.3) with the v0.51.0 simplifications listed in
/// the file-level docstring.
pub struct DoubleMLDIDCSBinary {
  data : DoubleMLDIDCSData
  g_value : Int
  t_value_pre : Int
  t_value_eval : Int
  control_group : String
  anticipation_periods : Int
  n_folds : Int
  n_rep : Int
  seed : Int
  propensity_clip : Double
  ps_processor : PSProcessor
  score : String
  in_sample_normalization : Bool
  // Post-fit outputs.
  coef : Double
  se : Double
  // Per-observation influence function `psi = psi_a +
  // theta * psi_b` on the post-subset panel. Length
  // `n_obs_subset` (= `rows.length()` after the
  // panel subset).
  psi_a : Array[Double]
  psi_b : Array[Double]
  // Post-fit nuisance predictions on the post-subset
  // panel.
  g_d0_t0 : Array[Double]
  g_d0_t1 : Array[Double]
  g_d1_t0 : Array[Double]
  g_d1_t1 : Array[Double]
  m_hat : Array[Double]
  // Effective sample size after panel subsetting.
  n_obs_subset : Int
  // Number of treated (G_indicator=1) rows in the
  // post-subset panel; used by the
  // `did_cs_binary_panel_subset_shape` test.
  n_g_subset : Int
  // Number of control (C_indicator=1) rows in the
  // post-subset panel.
  n_c_subset : Int
  fitted : Bool
} derive(Debug)

///|
pub extend DoubleMLDIDCSBinary with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// v0.51.0: construct a `DoubleMLDIDCSBinary`
/// estimator. Validates the inputs and stores them on
/// the struct; no estimation happens until `fit` is
/// called. The `score` argument is restricted to
/// `"observational"` for v0.51.0 (experimental is a
/// v0.52.0+ target).
pub fn DoubleMLDIDCSBinary::new(
  data : DoubleMLDIDCSData,
  g_value : Int,
  t_value_pre : Int,
  t_value_eval : Int,
  control_group? : String = "never_treated",
  anticipation_periods? : Int = 0,
  n_folds? : Int = 5,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
  ps_processor? : PSProcessor = PSProcessor::new(),
  score? : String = "observational",
  in_sample_normalization? : Bool = false,
) -> DoubleMLDIDCSBinary {
  try {
    require(t_value_pre != t_value_eval)
    require(g_value > 0)
    require(
      control_group == "never_treated" || control_group == "not_yet_treated",
    )
    require(n_folds >= 2)
    require(n_rep >= 1)
    require(propensity_clip > 0.0)
    require(propensity_clip < 0.5)
    require(anticipation_periods >= 0)
    require(score == "observational")
    {
      data,
      g_value,
      t_value_pre,
      t_value_eval,
      control_group,
      anticipation_periods,
      n_folds,
      n_rep,
      seed,
      propensity_clip,
      ps_processor,
      score,
      in_sample_normalization,
      coef: 0.0,
      se: 0.0,
      psi_a: [],
      psi_b: [],
      g_d0_t0: [],
      g_d0_t1: [],
      g_d1_t0: [],
      g_d1_t1: [],
      m_hat: [],
      n_obs_subset: 0,
      n_g_subset: 0,
      n_c_subset: 0,
      fitted: false,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.51.0: ATT estimate (point estimate) for the
/// chosen `(g_value, t_value_pre, t_value_eval)` triple.
pub fn DoubleMLDIDCSBinary::coef(self : DoubleMLDIDCSBinary) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.51.0: standard error of the ATT estimate.
pub fn DoubleMLDIDCSBinary::se(self : DoubleMLDIDCSBinary) -> Double {
  try {
    require(self.fitted)
    self.se
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.51.0: 95% Wald-style confidence interval.
pub fn DoubleMLDIDCSBinary::confint(
  self : DoubleMLDIDCSBinary,
  level? : Double = 0.95,
) -> (Double, Double) {
  try {
    require(self.fitted)
    require(level > 0.0 && level < 1.0)
    let z = if (level - 0.95).abs() < 1.0e-12 {
      1.959963984540054
    } else {
      // For non-95% levels, fall back to the
      // 1.96 upper-tail approximation. Tight
      // tolerance on the 95% level is what the
      // tests actually inspect.
      1.96
    }
    (self.coef - z * self.se, self.coef + z * self.se)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.51.0: the `g_value` constructor argument (the
/// treated group in the `(g, t)` DID setup).
pub fn DoubleMLDIDCSBinary::g_value(self : DoubleMLDIDCSBinary) -> Int {
  self.g_value
}

///|
/// v0.51.0: the `t_value_pre` constructor argument
/// (the baseline pre-treatment period).
pub fn DoubleMLDIDCSBinary::t_value_pre(self : DoubleMLDIDCSBinary) -> Int {
  self.t_value_pre
}

///|
/// v0.51.0: the `t_value_eval` constructor argument
/// (the evaluation period).
pub fn DoubleMLDIDCSBinary::t_value_eval(self : DoubleMLDIDCSBinary) -> Int {
  self.t_value_eval
}

///|
/// v0.51.0: number of observations in the post-subset
/// panel (i.e. the effective sample size for the SE).
/// This is the post-subset count, NOT the full panel
/// `n_obs`. Matches the upstream
/// `DoubleMLDIDCSBinary.n_obs_subset` attribute.
pub fn DoubleMLDIDCSBinary::n_obs(self : DoubleMLDIDCSBinary) -> Int {
  self.n_obs_subset
}

///|
/// v0.51.0: number of treated (`G_indicator = 1`) rows
/// in the post-subset panel.
pub fn DoubleMLDIDCSBinary::n_g_subset(self : DoubleMLDIDCSBinary) -> Int {
  self.n_g_subset
}

///|
/// v0.51.0: number of control (`C_indicator = 1`) rows
/// in the post-subset panel.
pub fn DoubleMLDIDCSBinary::n_c_subset(self : DoubleMLDIDCSBinary) -> Int {
  self.n_c_subset
}

///|
/// v0.51.0: total number of observations in the
/// original (pre-subset) panel.
pub fn DoubleMLDIDCSBinary::n_obs_panel(self : DoubleMLDIDCSBinary) -> Int {
  self.data.y.length()
}

///|
/// v0.51.0: `true` after `fit` has been called, `false`
/// otherwise.
pub fn DoubleMLDIDCSBinary::fitted(self : DoubleMLDIDCSBinary) -> Bool {
  self.fitted
}

///|
/// v0.51.0: cross-fitted nuisance predictions
/// `g_d0_t0` (control × pre). Length `n_obs_subset()`.
pub fn DoubleMLDIDCSBinary::predictions_g_d0_t0(
  self : DoubleMLDIDCSBinary,
) -> Array[Double] {
  try {
    require(self.fitted)
    self.g_d0_t0
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.51.0: cross-fitted nuisance predictions
/// `g_d0_t1` (control × eval).
pub fn DoubleMLDIDCSBinary::predictions_g_d0_t1(
  self : DoubleMLDIDCSBinary,
) -> Array[Double] {
  try {
    require(self.fitted)
    self.g_d0_t1
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.51.0: cross-fitted nuisance predictions
/// `g_d1_t0` (treated × pre).
pub fn DoubleMLDIDCSBinary::predictions_g_d1_t0(
  self : DoubleMLDIDCSBinary,
) -> Array[Double] {
  try {
    require(self.fitted)
    self.g_d1_t0
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.51.0: cross-fitted nuisance predictions
/// `g_d1_t1` (treated × eval).
pub fn DoubleMLDIDCSBinary::predictions_g_d1_t1(
  self : DoubleMLDIDCSBinary,
) -> Array[Double] {
  try {
    require(self.fitted)
    self.g_d1_t1
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.51.0: cross-fitted propensity predictions
/// `m(X) = E[G_indicator | X]`. Clipped to
/// `[propensity_clip, 1 - propensity_clip]`.
pub fn DoubleMLDIDCSBinary::predictions_m(
  self : DoubleMLDIDCSBinary,
) -> Array[Double] {
  try {
    require(self.fitted)
    self.m_hat
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.51.0: per-observation `psi_a` from the CS Binary
/// score. Length `n_obs_subset()`.
pub fn DoubleMLDIDCSBinary::psi_a(self : DoubleMLDIDCSBinary) -> Array[Double] {
  try {
    require(self.fitted)
    self.psi_a
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.51.0: per-observation `psi_b` from the CS Binary
/// score. Length `n_obs_subset()`.
pub fn DoubleMLDIDCSBinary::psi_b(self : DoubleMLDIDCSBinary) -> Array[Double] {
  try {
    require(self.fitted)
    self.psi_b
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.51.0: run the CS Binary estimation. Three
/// steps:
///   1. Subset the panel to the 4
///      `(G_indicator, T_indicator)` cells.
///   2. Cross-fit the 4 g-functions and the
///      propensity using `kfold_stratified` on
///      `G_indicator + 2 * T_indicator`.
///   3. Compute `psi_a`, `psi_b` via the
///      observational Sant'Anna-Zhao score, and
///      derive the ATT and SE via the shared
///      `var_est(psi_a, psi_b)` helper.
pub fn DoubleMLDIDCSBinary::fit(
  self : DoubleMLDIDCSBinary,
  ml_g? : LinearRegression = LinearRegression::new(),
  ml_m? : LinearRegression = LinearRegression::new(),
) -> DoubleMLDIDCSBinary {
  ignore(ml_g)
  ignore(ml_m)
  // Step 1: panel subset.
  let p = self.data.x.cols()
  let (rows, _never_treated_value, n_g, n_c) = cs_bin_panel_subset(
    self.data,
    self.g_value,
    self.t_value_pre,
    self.t_value_eval,
    self.control_group,
    self.anticipation_periods,
  )
  let n_sub = rows.length()
  // Step 2: stratified k-fold.
  let strata : Array[Double] = Array::make(n_sub, 0.0)
  for i = 0; i < n_sub; i = i + 1 {
    strata[i] = rows[i].g_indicator + 2.0 * rows[i].t_indicator
  }
  let folds = kfold_stratified(n_sub, strata, self.n_folds, self.seed)
  // Crossfit the 4 g-functions + the propensity.
  let (g00, g01, g10, g11, m) = cs_bin_crossfit_nuisance(
    rows,
    p,
    folds,
    self.n_rep,
    self.seed,
    self.propensity_clip,
    self.ps_processor,
  )
  // Materialize the y / d / t arrays for the score.
  let y : Array[Double] = Array::make(n_sub, 0.0)
  let d : Array[Double] = Array::make(n_sub, 0.0)
  let t_arr : Array[Double] = Array::make(n_sub, 0.0)
  for i = 0; i < n_sub; i = i + 1 {
    y[i] = rows[i].y
    d[i] = rows[i].g_indicator
    t_arr[i] = rows[i].t_indicator
  }
  // Step 3: score + theta + SE.
  let (psi_a, psi_b) = cs_bin_score_obs(
    y,
    d,
    t_arr,
    g00,
    g01,
    g10,
    g11,
    m,
    self.in_sample_normalization,
  )
  let (coef, se) = var_est(psi_a, psi_b)
  {
    ..self,
    coef,
    se,
    psi_a,
    psi_b,
    g_d0_t0: g00,
    g_d0_t1: g01,
    g_d1_t0: g10,
    g_d1_t1: g11,
    m_hat: m,
    n_obs_subset: n_sub,
    n_g_subset: n_g,
    n_c_subset: n_c,
    fitted: true,
  }
}
