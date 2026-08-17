///|
/// Data container for the Callaway-Sant'Anna (CS) DID model with
/// multi-period panel data and binary treatment. The treatment
/// `d` is the *change* in treatment status (binary `{0, 1}` under
/// the simplified CS-DID port; the upstream package also supports
/// `{-1, 0, 1}` for "switchers" via the `control_group` parameter,
/// which is out of scope here). `t` is the time index (length
/// `n_periods`); each unit is observed in every period (`n_obs =
/// n_units * n_periods` rows).
///
/// The `fit` step iterates over the distinct treatment groups `g`
/// and the evaluation periods `t`, runs a `DoubleMLDIDBinary`
/// for each `(g, t_pre, t_eval)` triple on the long-format panel,
/// and returns the per-`(g, t)` ATT estimates as a flat array
/// (row-major, length `n_groups * n_periods`).
pub struct DoubleMLDIDCSData {
  x : Matrix
  y : Array[Double]
  d : Array[Double]
  t : Array[Int]
  id : Array[Int]
  g : Array[Int]
  // Sorted unique treatment-group values (excluding the
  // never-treated sentinel which is the minimum of `g`). This is
  // set by `fit` from the data.
  groups : Array[Int]
  // Sorted unique time-period values, including the smallest as the
  // `never_treated_time` sentinel.
  times : Array[Int]
} derive(Debug)

///|
pub fn DoubleMLDIDCSData::new(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  t : Array[Int],
  id : Array[Int],
  g : Array[Int],
) -> DoubleMLDIDCSData {
  let n = y.length()
  require(x.nrows == n)
  require(d.length() == n)
  require(t.length() == n)
  require(id.length() == n)
  require(g.length() == n)
  // Validate d is binary {0, 1}.
  for di in d {
    require(di == 0.0 || di == 1.0)
  }
  // Deep-copy `g` and `t` so the caller's arrays are not mutated
  // by the in-place sort inside `discover_groups_times` (and any
  // future in-place ops in `fit`).
  let g_owned : Array[Int] = []
  for v in g {
    g_owned.push(v)
  }
  let t_owned : Array[Int] = []
  for v in t {
    t_owned.push(v)
  }
  // Discover the unique groups and times.
  let (groups, times) = discover_groups_times(g_owned, t_owned)
  { x, y, d, t: t_owned, id, g: g_owned, groups, times }
}

///|
/// Internal: discover the distinct group and time values. The
/// `groups` array is the sorted list of unique `g` values excluding
/// the never-treated sentinel (the minimum of `g`). The `times`
/// array is the sorted list of unique time indices.
///
/// We use a linear pass to collect uniques (no hash map) — fine
/// for the panel sizes typical of CS-DID (n_groups ≤ 10,
/// n_periods ≤ 20).
fn discover_groups_times(
  g : Array[Int],
  t : Array[Int],
) -> (Array[Int], Array[Int]) {
  let n = g.length()
  // never_treated_value = min(g).
  let mut never_treated_value = g[0]
  for i = 1; i < n; i = i + 1 {
    if g[i] < never_treated_value {
      never_treated_value = g[i]
    }
  }
  // Build sorted unique groups and times via a flat Array. We
  // deep-copy first because `Array::sort` is in-place and
  // `Array::copy` is shallow: sorting `g_sorted` would also
  // mutate the caller's `g` array.
  let g_sorted : Array[Int] = []
  for v in g {
    g_sorted.push(v)
  }
  g_sorted.sort()
  let t_sorted : Array[Int] = []
  for v in t {
    t_sorted.push(v)
  }
  t_sorted.sort()
  let g_unique : Array[Int] = []
  let mut g_unique_acc = g_unique
  let t_unique : Array[Int] = []
  let mut t_unique_acc = t_unique
  for i = 0; i < n; i = i + 1 {
    let gv = g_sorted[i]
    if g_unique_acc.length() == 0 ||
      g_unique_acc[g_unique_acc.length() - 1] != gv {
      if gv != never_treated_value {
        g_unique_acc = g_unique_acc + [gv]
      }
    }
    let tv = t_sorted[i]
    if t_unique_acc.length() == 0 ||
      t_unique_acc[t_unique_acc.length() - 1] != tv {
      t_unique_acc = t_unique_acc + [tv]
    }
  }
  (g_unique_acc, t_unique_acc)
}

///|
/// Callaway-Sant'Anna (2021) staggered DID model. Iterates over
/// every `(g, t_pre, t_eval)` triple where `g` is a treatment
/// group and `t_eval` is strictly after `g`, runs a
/// `DoubleMLDIDBinary` on the long-format panel restricted to the
/// never-treated control cohort, and stores the per-`(g, t)` ATT
/// estimate, SE, and 95% CI.
///
/// **Simplifications vs. upstream**:
///   - Binary treatment `{0, 1}` only (the `{-1, 0, 1}` multi-valued
///     `d` convention is not supported here; use `DoubleMLDIDBinary`
///     with `control_group = "not_yet_treated"` for the staggered
///     case).
///   - Default control group is `"never_treated"`. `"not_yet_treated"`
///     is supported but not-yet-treated units are not "switched in"
///     to be controls in subsequent periods (we always use the
///     never-treated sentinel cohort as the single control).
///   - Score is fixed to `observational`; in-sample normalisation
///     is `false` (matches the `DoubleMLDID` default). Callers can
///     pass `in_sample_normalization = true` to switch to the
///     Sant'Anna & Zhao (2020) eq. 4.3 form.
///   - No sensitivity analysis, no `tune_optuna`, no aggregation
///     beyond the per-`(g, t)` output.
pub struct DoubleMLDIDCS {
  data : DoubleMLDIDCSData
  control_group : String
  anticipation_periods : Int
  n_folds : Int
  n_rep : Int
  seed : Int
  propensity_clip : Double
  // v0.10.0+: propensity-score processor. Propagated through to
  // each per-cell `DoubleMLDIDBinary` fit; controls the
  // `clipping_threshold` applied to the averaged propensity.
  ps_processor : PSProcessor
  in_sample_normalization : Bool
  // Per-(g, t) ATT estimates, indexed row-major as
  // `coef[i * n_periods + t]` for group `i`, time `t`. `length`
  // is `n_groups * n_periods`. The entry is `0.0` if the
  // corresponding estimate is not available (e.g. t_eval ≤ g for
  // the chosen group).
  coef_matrix : Array[Double]
  se_matrix : Array[Double]
  // v0.15.0+: per-(g, t) influence function `psi = psi_a + theta
  // * psi_b`, indexed row-major as
  // `psi_matrix[(i * n_periods + t) * n_obs + i_long]`. Length
  // is `n_groups * n_periods * n_obs`. The entry is `0.0` if
  // the (g, t) cell is not available. Used by the multiplier
  // bootstrap in `DoubleMLDIDMulti::bootstrap`.
  psi_matrix : Array[Double]
  n_groups : Int
  n_periods : Int
  fitted : Bool
} derive(Debug)

///|
pub fn DoubleMLDIDCS::new(
  data : DoubleMLDIDCSData,
  control_group? : String = "never_treated",
  anticipation_periods? : Int = 0,
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
  ps_processor? : PSProcessor = PSProcessor::new(),
  in_sample_normalization? : Bool = false,
) -> DoubleMLDIDCS {
  require(n_folds >= 2)
  require(n_rep >= 1)
  require(propensity_clip > 0.0)
  require(propensity_clip < 0.5)
  require(
    control_group == "never_treated" || control_group == "not_yet_treated",
  )
  require(anticipation_periods >= 0)
  let n_groups = data.groups.length()
  let n_periods = data.times.length()
  {
    data,
    control_group,
    anticipation_periods,
    n_folds,
    n_rep,
    seed,
    propensity_clip,
    ps_processor,
    in_sample_normalization,
    coef_matrix: Array::make(n_groups * n_periods, 0.0),
    se_matrix: Array::make(n_groups * n_periods, 0.0),
    psi_matrix: Array::make(n_groups * n_periods * data.y.length(), 0.0),
    n_groups,
    n_periods,
    fitted: false,
  }
}

///|
/// Per-`(g, t)` ATT estimate (row-major indexing). `0.0` if the
/// (g, t) cell is empty (e.g. `t_eval ≤ g` for the chosen group).
pub fn DoubleMLDIDCS::coef_at(
  self : DoubleMLDIDCS,
  group_idx : Int,
  period_idx : Int,
) -> Double {
  require(self.fitted)
  require(group_idx >= 0 && group_idx < self.n_groups)
  require(period_idx >= 0 && period_idx < self.n_periods)
  self.coef_matrix[group_idx * self.n_periods + period_idx]
}

///|
/// Per-`(g, t)` ATT standard error.
pub fn DoubleMLDIDCS::se_at(
  self : DoubleMLDIDCS,
  group_idx : Int,
  period_idx : Int,
) -> Double {
  require(self.fitted)
  require(group_idx >= 0 && group_idx < self.n_groups)
  require(period_idx >= 0 && period_idx < self.n_periods)
  self.se_matrix[group_idx * self.n_periods + period_idx]
}

///|
/// Number of groups (excluding the never-treated sentinel).
pub fn DoubleMLDIDCS::n_groups(self : DoubleMLDIDCS) -> Int {
  self.n_groups
}

///|
/// Number of distinct time periods.
pub fn DoubleMLDIDCS::n_periods(self : DoubleMLDIDCS) -> Int {
  self.n_periods
}

///|
/// Group value at row index `i` (sorted ascending).
pub fn DoubleMLDIDCS::group_at(self : DoubleMLDIDCS, group_idx : Int) -> Int {
  require(group_idx >= 0 && group_idx < self.n_groups)
  self.data.groups[group_idx]
}

///|
/// Time value at column index `t` (sorted ascending).
pub fn DoubleMLDIDCS::period_at(self : DoubleMLDIDCS, period_idx : Int) -> Int {
  require(period_idx >= 0 && period_idx < self.n_periods)
  self.data.times[period_idx]
}

///|
/// Run the CS-DID estimation: for every `(g, t_eval)` triple with
/// `t_eval > g`, restrict the panel to the never-treated cohort
/// plus the units with `g == g_value`, run a `DoubleMLDIDBinary` on
/// the restricted long-format data with `t_value_pre = g` and
/// `t_value_eval = t_eval`, and store the resulting ATT and SE.
///
/// The (g, t_eval) combinations are visited in row-major order
/// (groups ascending, periods ascending). Cells with `t_eval <= g`
/// are left at the default `0.0` (the CS-DID convention is "no
/// pre-treatment estimate" for such cells; downstream aggregation
/// layers can drop them via the `nan`-aware aggregator).
pub fn DoubleMLDIDCS::fit(
  self : DoubleMLDIDCS,
  ml_g? : LinearRegression = LinearRegression::new(),
  ml_m? : LinearRegression = LinearRegression::new(),
) -> DoubleMLDIDCS {
  ignore(ml_g)
  ignore(ml_m)
  let n = self.data.y.length()
  let p = self.data.x.cols()
  // Precompute the never-treated-value = min of g.
  let mut never_treated_value = self.data.g[0]
  for i = 1; i < n; i = i + 1 {
    if self.data.g[i] < never_treated_value {
      never_treated_value = self.data.g[i]
    }
  }
  let coef_values : Array[Double] = []
  let se_values : Array[Double] = []
  let mut coef_values_acc = coef_values
  let mut se_values_acc = se_values
  // v0.15.0+: per-cell influence function on long-format panel.
  let psi_values : Array[Array[Double]] = []
  let mut psi_values_acc = psi_values
  for gi = 0; gi < self.n_groups; gi = gi + 1 {
    let g_value = self.data.groups[gi]
    // Find the index of the period equal to g_value (the
    // pre-treatment baseline).
    let mut pre_period_idx = -1
    for pi = 0; pi < self.n_periods; pi = pi + 1 {
      if self.data.times[pi] == g_value {
        pre_period_idx = pi
      }
    }
    if pre_period_idx < 0 {
      // The cohort's pre-treatment period isn't observed; skip
      // all (g_value, t_eval) cells for this group.
      continue
    }
    let pre_period = g_value
    for pi = 0; pi < self.n_periods; pi = pi + 1 {
      let eval_period = self.data.times[pi]
      if eval_period <= pre_period {
        continue
      }
      // Restrict the panel to: (g == g_value) ∪ (g == never_treated_value).
      let mut sub_n = 0
      let mut x_sub_acc : Array[Double] = []
      let mut y_sub_acc : Array[Double] = []
      let mut d_sub_acc : Array[Double] = []
      let mut t_sub_acc : Array[Int] = []
      let mut id_sub_acc : Array[Int] = []
      let mut g_sub_acc : Array[Int] = []
      // v0.15.0+: track the full long-format index for each
      // sub row, so we can map wide-format psi back to the
      // full long-format panel for the multiplier bootstrap.
      let mut full_idx_acc : Array[Int] = []
      for i = 0; i < n; i = i + 1 {
        let gv = self.data.g[i]
        let tv = self.data.t[i]
        // Only keep rows in the pre or eval periods, for the G or
        // C cohort.
        if tv != pre_period && tv != eval_period {
          continue
        }
        if gv != g_value && gv != never_treated_value {
          continue
        }
        // Recompute `d` for the sub-DID: 1 iff the unit is
        // in the G cohort AND in the eval period.
        let di = if gv == g_value && tv == eval_period { 1.0 } else { 0.0 }
        // Copy the row.
        for j = 0; j < p; j = j + 1 {
          x_sub_acc = x_sub_acc + [self.data.x.data[i * p + j]]
        }
        y_sub_acc = y_sub_acc + [self.data.y[i]]
        d_sub_acc = d_sub_acc + [di]
        t_sub_acc = t_sub_acc + [tv]
        id_sub_acc = id_sub_acc + [self.data.id[i]]
        g_sub_acc = g_sub_acc + [gv]
        // Record the full long-format index for the bootstrap.
        full_idx_acc = full_idx_acc + [i]
        sub_n = sub_n + 1
      }
      if sub_n == 0 {
        continue
      }
      // Build the panel data and run DoubleMLDIDBinary.
      let sub_data = DoubleMLDIDBinaryData::new(
        Matrix::from_array(x_sub_acc, sub_n, p),
        y_sub_acc,
        d_sub_acc,
        t_sub_acc,
        g_sub_acc,
        id_sub_acc,
      )
      let sub_fitted = DoubleMLDIDBinary::new(
        sub_data,
        g_value,
        pre_period,
        eval_period,
        control_group=self.control_group,
        anticipation_periods=self.anticipation_periods,
        n_folds=self.n_folds,
        n_rep=self.n_rep,
        seed=self.seed,
        propensity_clip=self.propensity_clip,
        ps_processor=self.ps_processor,
        score="observational",
        in_sample_normalization=self.in_sample_normalization,
      ).fit()
      // Append the (g, t) ATT to the running arrays; we will
      // reassemble the per-row-major matrix after the loop (so
      // missing cells — pre / eval combinations with t_eval <= g
      // — stay at 0.0 as the default).
      coef_values_acc = coef_values_acc + [sub_fitted.coef()]
      se_values_acc = se_values_acc + [sub_fitted.se()]
      // v0.15.0+: per-cell influence function
      // `psi = psi_a + theta * psi_b` on the long-format
      // panel. The inner DoubleMLDID's psi is on the
      // wide-format (sub-panel after preprocess_did_binary);
      // we map it back to the full long-format panel via
      // `sub_fitted.eval_idx` (wide -> sub) and
      // `full_idx_acc` (sub -> full). Rows not in the cell
      // stay at 0.0. Used by the multiplier bootstrap in
      // `DoubleMLDIDMulti::bootstrap`.
      let theta = sub_fitted.coef()
      let inner_psi_a = sub_fitted.inner_psi_a()
      let inner_psi_b = sub_fitted.inner_psi_b()
      let sub_to_wide = sub_fitted.eval_idx
      let psi_long : Array[Double] = Array::make(n, 0.0)
      for k_wide = 0; k_wide < sub_to_wide.length(); k_wide = k_wide + 1 {
        let k_sub = sub_to_wide[k_wide]
        let full_i = full_idx_acc[k_sub]
        psi_long[full_i] = inner_psi_a[k_wide] + theta * inner_psi_b[k_wide]
      }
      psi_values_acc = psi_values_acc + [psi_long]
    }
  }
  // Reassemble the row-major matrix. For missing cells (g, t) with
  // `t_eval <= g` or no pre-treatment period observed, the entry
  // stays at 0.0. The accumulated `coef_values_acc` /
  // `se_values_acc` arrays are written into the matching flat
  // index in `final_coef` / `final_se`. A single O(n) pass over
  // (gi, pi) reconstructs the indexing.
  let final_coef : Array[Double] = Array::make(
    self.n_groups * self.n_periods,
    0.0,
  )
  let final_se : Array[Double] = Array::make(
    self.n_groups * self.n_periods,
    0.0,
  )
  // v0.15.0+: per-cell influence function `psi = psi_a + theta *
  // psi_b` on the long-format panel, used by the multiplier
  // bootstrap. Empty cells (no psi) are left at 0.0.
  let final_psi : Array[Double] = Array::make(
    self.n_groups * self.n_periods * n,
    0.0,
  )
  let mut coef_idx = 0
  for gi = 0; gi < self.n_groups; gi = gi + 1 {
    let g_value = self.data.groups[gi]
    // Locate the pre-treatment period (g_value itself) in the
    // time index; if absent, the whole group is skipped.
    let mut has_pre = false
    for pi = 0; pi < self.n_periods; pi = pi + 1 {
      if self.data.times[pi] == g_value {
        has_pre = true
      }
    }
    for pi = 0; pi < self.n_periods; pi = pi + 1 {
      let eval_period = self.data.times[pi]
      let flat = gi * self.n_periods + pi
      if !has_pre || eval_period <= g_value {
        continue
      }
      final_coef[flat] = coef_values_acc[coef_idx]
      final_se[flat] = se_values_acc[coef_idx]
      // Copy the per-cell psi into the row-major slot. The
      // psi is a length-`n` array; we flatten it into
      // `final_psi[flat * n .. (flat + 1) * n]`.
      let psi_k = psi_values_acc[coef_idx]
      for k = 0; k < n; k = k + 1 {
        final_psi[flat * n + k] = psi_k[k]
      }
      coef_idx = coef_idx + 1
    }
  }
  {
    ..self,
    coef_matrix: final_coef,
    se_matrix: final_se,
    psi_matrix: final_psi,
    fitted: true,
  }
}
