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
pub extend DoubleMLDIDBinaryData with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLDIDBinaryData::new(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  t : Array[Int],
  g : Array[Int],
  id : Array[Int],
) -> DoubleMLDIDBinaryData {
  try {
    let n = y.length()
    require(x.nrows == n)
    require(d.length() == n)
    require(t.length() == n)
    require(g.length() == n)
    require(id.length() == n)
    { x, y, d, t, g, id, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
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
/// Carries the covariate matrix, the first-differenced outcome, the
/// binary G_indicator (`d`), and the binary t_indicator
/// (`t_indicator`: 0 if the wide row originated from the
/// `t_value_pre` period, 1 if from `t_value_eval`).
struct WideDIDSubset {
  x : Matrix
  y : Array[Double]
  d : Array[Double]
  t_indicator : Array[Double]
  // v0.15.0+: long-format `eval_idx` per wide-format row.
  // Lets us map wide-format psi back to long-format for the
  // multiplier bootstrap. Index into the input
  // `DoubleMLDIDBinaryData` (long-format) array. Length
  // matches `y` / `d`.
  eval_idx : Array[Int]
} derive(Debug)
pub extend WideDIDSubset with @moonbitlang/core/debug.Debug::{to_repr}

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
  try {
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
    let t_out : Array[Double] = []
    // v0.15.0+: long-format `eval_idx` per emitted wide row.
    let eval_idx_out : Array[Int] = []
    let mut x_acc = x_out
    let mut y_acc = y_out
    let mut d_acc = d_out
    let mut t_acc = t_out
    let mut eval_idx_acc = eval_idx_out
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
          // "not_yet_treated": keep never-treated OR (G_indicator=0
          // AND g_unit > max_g_value). The never-treated condition is
          // the same as above; the latter is the not-yet-treated
          // cohort.
        } else if g_unit == never_treated_value ||
          (g_indicator == 0.0 && g_unit > max_g_value) {
          1.0
        } else {
          0.0
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
          // t_indicator is 0 (pre) for the wide row, since the
          // covariates and the `y_diff` reference the pre period.
          // The post-period residual enters the score via `m_hat`
          // and `g0_hat`, not via the wide `y` itself.
          t_acc = t_acc + [0.0]
          // v0.15.0+: record the long-format row index for the
          // eval period. This is the index into the input
          // `DoubleMLDIDBinaryData` (long-format) arrays; it lets
          // the bootstrap map wide-format psi back to long-format.
          eval_idx_acc = eval_idx_acc + [eval_idx]
        }
      }
      i = j
    }
    // Build the output matrix.
    let n_sub = x_acc.length() / p
    require(n_sub * p == x_acc.length())
    require(y_acc.length() == n_sub)
    require(d_acc.length() == n_sub)
    require(t_acc.length() == n_sub)
    require(eval_idx_acc.length() == n_sub)
    let x_mat = Matrix::from_array(x_acc, n_sub, p)
    // Validate that the post-preprocess `d` is binary {0, 1} (the
    // upstream `DoubleMLDIDData` requires this).
    for di in d_acc {
      require(di == 0.0 || di == 1.0)
    }
    {
      x: x_mat,
      y: y_acc,
      d: d_acc,
      t_indicator: t_acc,
      eval_idx: eval_idx_acc,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
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
/// **v0.10.0 additions** (corresponds to upstream
/// `DoubleMLDIDCSBinary`):
///   - `ps_processor` field replaces the bare `propensity_clip`
///     argument. The processor's `clipping_threshold` is used to
///     bound the propensity scores inside the score denominator;
///     the field-level `propensity_clip` is retained for backward
///     compat but `fit` reads the clip threshold from
///     `ps_processor.clipping_threshold` instead.
///   - `fit` builds the wide-format strata
///     `G_indicator + 2 * t_indicator` (matching upstream
///     `self._strata`) and passes it to `DoubleMLDID::new(strata=
///     ...)`, switching the inner sample-splitting to
///     `stratified_kfold`. Each fold then balances the four
///     (G, T) cells.
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
  ps_processor : PSProcessor
  score : String
  in_sample_normalization : Bool
  // v0.15.0+: long-format row indices for each wide-format
  // observation, in the same order as `inner.data`. Empty until
  // `fit` is called. Used by the `psi_*_long` accessors to map
  // the inner wide-format psi back to the long-format panel
  // for the multiplier bootstrap.
  eval_idx : Array[Int]
  // Output of the inner `DoubleMLDID::fit`. Empty until `fit` is
  // called; `coef`/`se`/`confint` accessors guard on `fitted`.
  inner : DoubleMLDID
  fitted : Bool
} derive(Debug)
pub extend DoubleMLDIDBinary with @moonbitlang/core/debug.Debug::{to_repr}

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
  ps_processor? : PSProcessor = PSProcessor::new(),
  score? : String = "observational",
  in_sample_normalization? : Bool = false,
) -> DoubleMLDIDBinary {
  try {
    require(n_folds >= 2)
    require(n_rep >= 1)
    require(propensity_clip > 0.0)
    require(propensity_clip < 0.5)
    require(
      control_group == "never_treated" || control_group == "not_yet_treated",
    )
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
      ps_processor,
      score,
      in_sample_normalization,
      // v0.15.0+: long-format row indices. Populated by `fit`.
      eval_idx: [],
      // Placeholder: the real `DoubleMLDID` is built in `fit()` once
      // the wide-format preprocessing has produced a non-empty
      // dataset. We pass a 4-row dummy here so the
      // `DoubleMLDID::new` precondition `n_folds <= n_obs` is not
      // tripped at construction time (`n_folds` defaults to 2).
      // The dummy is overwritten by the real inner model on `fit()`.
      // v0.43.0: wrap DoubleMLDIDData::new in try/catch/re-abort to
      // preserve pre-v0.43.0 process-death behavior. The dummy
      // data is valid binary d, so the catch arm is unreachable in
      // practice; it exists to satisfy the `raise DIDDataError`
      // signature on DoubleMLDIDData::new.
      inner: DoubleMLDID::new(
        DoubleMLDIDData::new(
          Matrix::zeros(4, data.n_features()),
          [0.0, 0.0, 0.0, 0.0],
          [0.0, 0.0, 0.0, 0.0],
        ) catch {
          DIDDataError::NonBinaryTreatment(i) =>
            abort(
              "DoubleMLDIDData.d must be binary {0, 1} (index " +
              i.to_string() +
              ")",
            )
        },
        n_folds~,
        n_rep~,
        seed~,
        propensity_clip~,
        score~,
        in_sample_normalization~,
      ),
      fitted: false,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
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
  try {
    require(self.fitted)
    self.inner.coef()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Standard error of the ATT point estimate.
pub fn DoubleMLDIDBinary::se(self : DoubleMLDIDBinary) -> Double {
  try {
    require(self.fitted)
    self.inner.se()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// 95% Wald-style confidence interval.
pub fn DoubleMLDIDBinary::confint(self : DoubleMLDIDBinary) -> (Double, Double) {
  try {
    require(self.fitted)
    self.inner.confint()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Cross-fitted propensity predictions on the wide-format subset.
pub fn DoubleMLDIDBinary::predictions_m(
  self : DoubleMLDIDBinary,
) -> Array[Double] {
  try {
    require(self.fitted)
    self.inner.predictions_m()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Cross-fitted control outcome predictions `g_0(X) = E[Y | D = 0, X]`.
pub fn DoubleMLDIDBinary::predictions_g0(
  self : DoubleMLDIDBinary,
) -> Array[Double] {
  try {
    require(self.fitted)
    self.inner.predictions_g0()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Cross-fitted treated outcome predictions `g_1(X) = E[Y | D = 1, X]`.
pub fn DoubleMLDIDBinary::predictions_g1(
  self : DoubleMLDIDBinary,
) -> Array[Double] {
  try {
    require(self.fitted)
    self.inner.predictions_g1()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.15.0+: per-observation influence function component
/// `psi_a` mapped from the cell's wide-format data back to
/// the long-format panel. Length equals `data.n_obs()`
/// (the long-format panel). For long-format rows that are
/// not in the cell's wide-format subset, the value is `0.0`.
/// The influence function `psi = psi_a + theta * psi_b` is
/// used by the multiplier bootstrap in
/// `DoubleMLDIDMulti::bootstrap`.
pub fn DoubleMLDIDBinary::psi_a_long(self : DoubleMLDIDBinary) -> Array[Double] {
  try {
    require(self.fitted)
    let n_long = self.data.n_obs()
    let out : Array[Double] = Array::make(n_long, 0.0)
    let psi_a_wide = self.inner.psi_a
    for k = 0; k < self.eval_idx.length(); k = k + 1 {
      out[self.eval_idx[k]] = psi_a_wide[k]
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.15.0+: per-observation influence function component
/// `psi_b` mapped from the cell's wide-format data back to
/// the long-format panel. See `psi_a_long` for details.
pub fn DoubleMLDIDBinary::psi_b_long(self : DoubleMLDIDBinary) -> Array[Double] {
  try {
    require(self.fitted)
    let n_long = self.data.n_obs()
    let out : Array[Double] = Array::make(n_long, 0.0)
    let psi_b_wide = self.inner.psi_b
    for k = 0; k < self.eval_idx.length(); k = k + 1 {
      out[self.eval_idx[k]] = psi_b_wide[k]
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.15.0+: per-observation `psi_a` on the cell's wide-format
/// data (the inner `DoubleMLDID`'s `psi_a` field). Length
/// equals `n_obs_subset()` (the cell's wide-format panel
/// size). Used by the multiplier bootstrap in
/// `DoubleMLDIDMulti::bootstrap` to map wide-format psi back
/// to the full long-format panel.
pub fn DoubleMLDIDBinary::inner_psi_a(
  self : DoubleMLDIDBinary,
) -> Array[Double] {
  try {
    require(self.fitted)
    self.inner.psi_a
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.15.0+: per-observation `psi_b` on the cell's wide-format
/// data. See `inner_psi_a` for details.
pub fn DoubleMLDIDBinary::inner_psi_b(
  self : DoubleMLDIDBinary,
) -> Array[Double] {
  try {
    require(self.fitted)
    self.inner.psi_b
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
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
  try {
    require(self.t_value_pre != self.t_value_eval)
    let wide = preprocess_did_binary(
      self.data,
      self.g_value,
      self.t_value_pre,
      self.t_value_eval,
      self.control_group,
      self.anticipation_periods,
    )
    // v0.43.0: wrap in try/catch/re-abort to preserve pre-v0.43.0
    // process-death behavior. The `wide.d` output of
    // `preprocess_did_binary` is normally binary (only the
    // switchers); the catch arm is a defense-in-depth measure.
    let wide_data = DoubleMLDIDData::new(wide.x, wide.y, wide.d) catch {
      DIDDataError::NonBinaryTreatment(i) =>
        abort(
          "DoubleMLDIDData.d must be binary {0, 1} (index " + i.to_string() + ")",
        )
    }
  // v0.10.0: build the wide-format strata as
  // `G_indicator + 2 * t_indicator` (matching upstream's
  // `self._strata = ...`), so each fold balances the (G, T) cells.
  // In the y_diff view the wide row is always anchored to the
  // pre period (t_indicator = 0), so the effective strata is
  // `G_indicator` (1-D, G-vs-C balance). We pass both arrays so
  // upstream-equivalent cells (0, 0), (0, 1), (1, 0), (1, 1) are
  // represented if the data layout changes in a future port.
  //
  // Guard: `stratified_kfold` requires `n_folds <= min stratum
  // size`. If any stratum is too small (e.g. a tiny control
  // cohort), fall back to plain `kfold` by passing an empty
  // `strata` array, which `DoubleMLDID::fit` interprets as
  // "no stratification".
  let strata : Array[Int] = []
  let mut strata_acc = strata
  let mut use_strata = true
  for i = 0; i < wide.d.length(); i = i + 1 {
    strata_acc = strata_acc + [(wide.d[i] + 2.0 * wide.t_indicator[i]).to_int()]
  }
  // Per-stratum min-size check.
  let counts : Array[Int] = []
  let mut counts_acc = counts
  let seen : Array[Int] = []
  let mut seen_acc = seen
  for i = 0; i < strata_acc.length(); i = i + 1 {
    let s = strata_acc[i]
    let mut found = false
    let mut found_idx = 0
    for j = 0; j < seen_acc.length(); j = j + 1 {
      if seen_acc[j] == s {
        found = true
        found_idx = j
      }
    }
    if found {
      counts_acc[found_idx] = counts_acc[found_idx] + 1
    } else {
      seen_acc = seen_acc + [s]
      counts_acc = counts_acc + [1]
    }
  }
  for i = 0; i < counts_acc.length(); i = i + 1 {
    if counts_acc[i] < self.n_folds {
      use_strata = false
    }
  }
  if !use_strata {
    strata_acc = []
  }
  let inner = DoubleMLDID::new(
    wide_data,
    n_folds=self.n_folds,
    n_rep=self.n_rep,
    seed=self.seed,
    propensity_clip=self.propensity_clip,
    ps_processor=self.ps_processor,
    score=self.score,
    in_sample_normalization=self.in_sample_normalization,
    strata=strata_acc,
  ).fit()
  // v0.15.0+: record the long-format `eval_idx` from the
  // preprocessing so the bootstrap can map wide-format psi
  // back to long-format.
  { ..self, inner, eval_idx: wide.eval_idx, fitted: true, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
