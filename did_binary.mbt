///|
/// Panel data container for the binary DID model. Stores long-format
/// panel observations: each row is `(unit, time, y, d, x_1, ...,
/// x_p)`. `t_col` and `id_col` identify the time and unit indices.
/// `g_col` is the unit's treatment-group index (the period of
/// first treatment; equal to `never_treated_value` for never-treated
/// units). All arrays are length `n_obs_total = n_units * n_periods`.
///
/// The `fit` step reshapes this long-format data into a wide-format
/// DID dataset: for each unit observed in both `t_value_pre` and
/// `t_value_eval`, we construct `y_diff = y_post - y_pre`, the
/// `G_indicator = (g == g_value)`, the `C_indicator` (never-treated
/// or not-yet-treated per `control_group`), and the covariates from
/// the earlier period. The wide-format dataset is then passed to
/// `DoubleMLDID` for the standard DML cross-fit.
pub struct DoubleMLDIDBinaryData {
  x : Matrix
  y : Array[Double]
  d : Array[Double]
  t : Array[Int]
  g : Array[Int]
  id : Array[Int]
} derive(Debug)

///|
pub fn DoubleMLDIDBinaryData::new(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  t : Array[Int],
  g : Array[Int],
  id : Array[Int],
) -> DoubleMLDIDBinaryData {
  let n = y.length()
  require(x.nrows == n)
  require(d.length() == n)
  require(t.length() == n)
  require(g.length() == n)
  require(id.length() == n)
  { x, y, d, t, g, id }
}

///|
pub fn DoubleMLDIDBinaryData::n_obs(self : DoubleMLDIDBinaryData) -> Int {
  self.y.length()
}

///|
pub fn DoubleMLDIDBinaryData::n_features(self : DoubleMLDIDBinaryData) -> Int {
  self.x.cols()
}

///|
/// The wide-format DID subset returned by `preprocess_did_binary`.
/// Carries the covariate matrix, the first-differenced outcome, and
/// the binary G_indicator (`d`).
struct WideDIDSubset {
  x : Matrix
  y : Array[Double]
  d : Array[Double]
} derive(Debug)

///|
/// Internal: preprocess long-format panel data into the wide-format
/// DID dataset. Returns `(x, y, d)` where `y = y_post - y_pre`,
/// `d = G_indicator`, and `x` is the earlier-period covariate
/// matrix.
///
/// Algorithm (O(n log n) panel-wide):
///   1. Build `(id, t, y, d, g, row_idx)` tuples and sort by
///      `(id, t)` so all rows for the same unit are contiguous and
///      ordered by time.
///   2. Walk the sorted array: a unit with both `t_value_pre` and
///      `t_value_eval` emits a wide-format row. Otherwise the unit
///      is skipped.
///   3. Construct `y_diff = y_eval - y_pre`,
///      `G_indicator = (g == g_value)`, and
///      `C_indicator` per `control_group`. The unit's wide row is
///      emitted only if it's in exactly one of the two groups
///      (asserted by `_check_disjoint`).
///   4. Use the **earlier period's** covariates as the regressors
///      (matching upstream's `_dml_data.x_cols` extraction).
///
/// `control_group = "never_treated"` keeps units whose `g` equals
/// `never_treated_value`. `"not_yet_treated"` additionally keeps
/// units whose `g > max_g_value` where
/// `max_g_value` is the largest time period at most
/// `max(t_value_eval, g_value) + anticipation_periods`.
fn preprocess_did_binary(
  data : DoubleMLDIDBinaryData,
  g_value : Int,
  t_value_pre : Int,
  t_value_eval : Int,
  control_group : String,
  anticipation_periods : Int,
) -> WideDIDSubset {
  let n = data.n_obs()
  let p = data.n_features()
  // Discover `never_treated_value` = min of all `g`. This matches
  // the upstream convention "the smallest `g` value marks the
  // never-treated cohort".
  let mut never_treated_value = data.g[0]
  for i = 1; i < n; i = i + 1 {
    if data.g[i] < never_treated_value {
      never_treated_value = data.g[i]
    }
  }
  // Compute `max_g_value` for the `not_yet_treated` case: the
  // largest time period at most `max(t_value_eval, g_value) +
  // anticipation_periods`. Since panel data doesn't carry a full
  // time-period index in the data struct, we take
  // `max_g_value = max(t_value_eval, g_value) + anticipation_periods`.
  let comparison_period = if t_value_eval > g_value {
    t_value_eval
  } else {
    g_value
  }
  let max_g_value = comparison_period + anticipation_periods
  // Build `(id, t, y, d, g, row_idx)` tuples and sort by (id, t).
  let keys : Array[(Int, Int, Int)] = Array::makei(n, fn(i) {
    (data.id[i], data.t[i], i)
  })
  keys.sort_by(fn(a, b) {
    let c = a.0.compare(b.0)
    if c != 0 {
      c
    } else {
      a.1.compare(b.1)
    }
  })
  // Walk: emit a wide-format row for every unit that has both
  // `t_value_pre` and `t_value_eval`.
  let x_out : Array[Double] = []
  let y_out : Array[Double] = []
  let d_out : Array[Double] = []
  let mut x_acc = x_out
  let mut y_acc = y_out
  let mut d_acc = d_out
  let mut i = 0
  while i < n {
    let id_cur = keys[i].0
    // Find the contiguous range of rows for this id.
    let mut j = i + 1
    while j < n && keys[j].0 == id_cur {
      j = j + 1
    }
    // Within [i, j), find the (at most one) row at `t_value_pre`
    // and the (at most one) row at `t_value_eval`.
    let mut pre_idx = -1
    let mut eval_idx = -1
    for k = i; k < j; k = k + 1 {
      if keys[k].1 == t_value_pre {
        pre_idx = keys[k].2
      } else if keys[k].1 == t_value_eval {
        eval_idx = keys[k].2
      }
    }
    if pre_idx >= 0 && eval_idx >= 0 {
      let g_unit = data.g[pre_idx]
      // If pre and eval rows disagree on g (e.g. a never-treated
      // unit accidentally mis-coded), we still allow the wide row
      // but use the pre-period `g`.
      let g_indicator = if g_unit == g_value { 1.0 } else { 0.0 }
      let c_indicator = if control_group == "never_treated" {
        if g_unit == never_treated_value {
          1.0
        } else {
          0.0
        }
      } else {
        // "not_yet_treated": keep never-treated OR (G_indicator=0
        // AND g_unit > max_g_value). The never-treated condition is
        // the same as above; the latter is the not-yet-treated
        // cohort.
        if g_unit == never_treated_value || (g_indicator == 0.0 && g_unit > max_g_value) {
          1.0
        } else {
          0.0
        }
      }
      // Wide row is emitted iff G_indicator == 1 OR
      // C_indicator == 1 (and exactly one, asserted by require).
      if g_indicator + c_indicator == 1.0 {
        let y_diff = data.y[eval_idx] - data.y[pre_idx]
        // Covariates come from the **pre** period (matching
        // upstream's wide-from-long conversion).
        let mut x_row_acc : Array[Double] = []
        for col = 0; col < p; col = col + 1 {
          x_row_acc = x_row_acc + [data.x.data[pre_idx * p + col]]
        }
        x_acc = x_acc + x_row_acc
        y_acc = y_acc + [y_diff]
        d_acc = d_acc + [g_indicator]
      }
    }
    i = j
  }
  // Build the output matrix.
  let n_sub = x_acc.length() / p
  require(n_sub * p == x_acc.length())
  require(y_acc.length() == n_sub)
  require(d_acc.length() == n_sub)
  let x_mat = Matrix::from_array(x_acc, n_sub, p)
  // Validate that the post-preprocess `d` is binary {0, 1} (the
  // upstream `DoubleMLDIDData` requires this).
  for di in d_acc {
    require(di == 0.0 || di == 1.0)
  }
  { x: x_mat, y: y_acc, d: d_acc }
}

///|
/// Binary DID model (Sant'Anna & Zhao 2020, §4.3) for panel data
/// with binary treatment in terms of the `(group, time)`
/// combination. Supports the two score variants
/// `"observational"` (default, IPW-style) and `"experimental"`
/// (A/B-test-style, requires independent treatment assignment),
/// and the two weighting conventions
/// `"in_sample_normalization = true"` (divide by sample mean) and
/// `false` (divide by `p_hat = mean(d)`). The default
/// `(observational, false)` matches the byte-equality of the
/// pre-0.8.0 `DoubleMLDID` port on the canonical DGP.
///
/// The model is a thin wrapper around `DoubleMLDID`: it
/// preprocesses the long-format panel into the wide-format DID
/// dataset, then dispatches to `DoubleMLDID::fit`. The DML point
/// estimate is the ATT (average treatment effect on the treated)
/// for the chosen `(g_value, t_value_pre, t_value_eval)` triple.
pub struct DoubleMLDIDBinary {
  data : DoubleMLDIDBinaryData
  g_value : Int
  t_value_pre : Int
  t_value_eval : Int
  control_group : String
  anticipation_periods : Int
  n_folds : Int
  n_rep : Int
  seed : Int
  propensity_clip : Double
  score : String
  in_sample_normalization : Bool
  // Output of the inner `DoubleMLDID::fit`. Empty until `fit` is
  // called; `coef`/`se`/`confint` accessors guard on `fitted`.
  inner : DoubleMLDID
  fitted : Bool
} derive(Debug)

///|
pub fn DoubleMLDIDBinary::new(
  data : DoubleMLDIDBinaryData,
  g_value : Int,
  t_value_pre : Int,
  t_value_eval : Int,
  control_group? : String = "never_treated",
  anticipation_periods? : Int = 0,
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
  score? : String = "observational",
  in_sample_normalization? : Bool = false,
) -> DoubleMLDIDBinary {
  require(n_folds >= 2)
  require(n_rep >= 1)
  require(propensity_clip > 0.0)
  require(propensity_clip < 0.5)
  require(control_group == "never_treated" || control_group == "not_yet_treated")
  require(score == "observational" || score == "experimental")
  require(anticipation_periods >= 0)
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
    score,
    in_sample_normalization,
    // Placeholder: the real `DoubleMLDID` is built in `fit()` once
    // the wide-format preprocessing has produced a non-empty
    // dataset. We pass a 4-row dummy here so the
    // `DoubleMLDID::new` precondition `n_folds <= n_obs` is not
    // tripped at construction time (`n_folds` defaults to 2).
    // The dummy is overwritten by the real inner model on `fit()`.
    inner: DoubleMLDID::new(
      DoubleMLDIDData::new(
        Matrix::zeros(4, data.n_features()),
        [0.0, 0.0, 0.0, 0.0],
        [0.0, 0.0, 0.0, 0.0],
      ),
      n_folds~,
      n_rep~,
      seed~,
      propensity_clip~,
      score~,
      in_sample_normalization~,
    ),
    fitted: false,
  }
}

///|
/// Number of units in the wide-format subset (i.e. observed in both
/// `t_value_pre` and `t_value_eval` and assigned to either G or C).
pub fn DoubleMLDIDBinary::n_obs_subset(self : DoubleMLDIDBinary) -> Int {
  self.inner.data.n_obs()
}

///|
/// Number of features (matches `data.n_features()`).
pub fn DoubleMLDIDBinary::n_features(self : DoubleMLDIDBinary) -> Int {
  self.inner.data.n_features()
}

///|
/// Point estimate (ATT) for the chosen `(g_value, t_value_pre,
/// t_value_eval)` triple.
pub fn DoubleMLDIDBinary::coef(self : DoubleMLDIDBinary) -> Double {
  require(self.fitted)
  self.inner.coef()
}

///|
/// Standard error of the ATT point estimate.
pub fn DoubleMLDIDBinary::se(self : DoubleMLDIDBinary) -> Double {
  require(self.fitted)
  self.inner.se()
}

///|
/// 95% Wald-style confidence interval.
pub fn DoubleMLDIDBinary::confint(
  self : DoubleMLDIDBinary,
) -> (Double, Double) {
  require(self.fitted)
  self.inner.confint()
}

///|
/// Cross-fitted propensity predictions on the wide-format subset.
pub fn DoubleMLDIDBinary::predictions_m(
  self : DoubleMLDIDBinary,
) -> Array[Double] {
  require(self.fitted)
  self.inner.predictions_m()
}

///|
/// Cross-fitted control outcome predictions `g_0(X) = E[Y | D = 0, X]`.
pub fn DoubleMLDIDBinary::predictions_g0(
  self : DoubleMLDIDBinary,
) -> Array[Double] {
  require(self.fitted)
  self.inner.predictions_g0()
}

///|
/// Cross-fitted treated outcome predictions `g_1(X) = E[Y | D = 1, X]`.
pub fn DoubleMLDIDBinary::predictions_g1(
  self : DoubleMLDIDBinary,
) -> Array[Double] {
  require(self.fitted)
  self.inner.predictions_g1()
}

///|
/// Run the binary DID estimation. Three steps:
///   1. Preprocess the long-format panel into the wide-format DID
///      dataset (`preprocess_did_binary`).
///   2. Build a `DoubleMLDIDData` from the wide-format arrays.
///   3. Fit a `DoubleMLDID` on the wide-format data with the chosen
///      `score` and `in_sample_normalization`.
///
/// The preprocessing keeps only units observed in both
/// `t_value_pre` and `t_value_eval`, drops units with neither the
/// `G_indicator = (g == g_value)` nor the `C_indicator` set, and
/// uses the earlier period's covariates as the regressors.
pub fn DoubleMLDIDBinary::fit(
  self : DoubleMLDIDBinary,
  ml_g? : LinearRegression = LinearRegression::new(),
  ml_m? : LinearRegression = LinearRegression::new(),
) -> DoubleMLDIDBinary {
  ignore(ml_g)
  ignore(ml_m)
  let wide = preprocess_did_binary(
    self.data,
    self.g_value,
    self.t_value_pre,
    self.t_value_eval,
    self.control_group,
    self.anticipation_periods,
  )
  let wide_data = DoubleMLDIDData::new(wide.x, wide.y, wide.d)
  let inner = DoubleMLDID::new(
    wide_data,
    n_folds=self.n_folds,
    n_rep=self.n_rep,
    seed=self.seed,
    propensity_clip=self.propensity_clip,
    score=self.score,
    in_sample_normalization=self.in_sample_normalization,
  ).fit()
  { ..self, inner, fitted: true }
}