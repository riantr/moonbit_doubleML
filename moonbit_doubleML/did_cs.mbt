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
pub extend DoubleMLDIDCSData with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLDIDCSData::new(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  t : Array[Int],
  id : Array[Int],
  g : Array[Int],
) -> DoubleMLDIDCSData {
  try {
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
    { x, y, d, t: t_owned, id, g: g_owned, groups, times, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
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
  // v0.69.0+: per-(g, t) Riesz-representer `psi_a` component
  // (without the `theta * psi_b` term), same row-major layout
  // as `psi_matrix`. Drives the per-cell
  // `irm_style_sensitivity` decomposition in
  // `DoubleMLDIDCS::sensitivity_analysis`.
  psi_a_matrix : Array[Double]
  // v0.69.0+: per-(g, t) outcome residual
  // `y - g_d0_hat - (g_d1_hat - g_d0_hat) * d`, same
  // row-major layout as `psi_matrix`. Drives the per-cell
  // `irm_style_sensitivity` decomposition (the
  // `residuals` argument to `irm_style_sensitivity`).
  residuals_matrix : Array[Double]
  // v0.100.0+: per-(g, t) WIDE-format influence-function
  // components for the `sandwich_se_at` /
  // `cluster_sandwich_se_at` / `bias_corrected_coef_at` API,
  // indexed row-major by the flat cell index
  // `group_idx * n_periods + period_idx` -- the SAME index
  // `coef_at` / `se_at` use. `length` is
  // `n_groups * n_periods`; an entry is the EMPTY array for a
  // cell that was not estimated.
  //
  // Unlike `psi_matrix` / `psi_a_matrix` above, these are NOT
  // scattered onto the full long-format panel: each entry is the
  // child `DoubleMLDIDBinary`'s OWN `psi_a` / `psi_b` row, i.e.
  // the exact arrays that child's `var_est` call summed. The
  // reversed long-format `psi_matrix` is the wrong score for the
  // sandwich in any case: it is built as `psi_a + theta * psi_b`
  // (see the comment at the long-format mapping below), whereas
  // `var_est.mbt` -- the package authority, and the one
  // `sandwich.mbt::psi_at` implements -- defines
  // `psi(theta) = theta * psi_a + psi_b`. The two differ in which
  // component carries the `theta` weight.
  //
  // WHY THE WIDE ROW SET AND NOT THE LONG PANEL
  // -------------------------------------------
  // `se_matrix[k]` IS `sub_fitted.se()`, and that number is
  // `var_est(psi_a, psi_b)` over the child's WIDE-format data:
  // the units observed in BOTH the pre and the eval period after
  // `preprocess_did_binary`, whose length is
  // `inner_psi_a.length()`. That is NOT the `sub_n` long-format
  // sub-panel rows the cell loop below builds, and not the
  // `n_groups * n_periods * n_obs` long panel. Measured on the
  // 4-cohort / 4-period / 200-unit panel of
  // `expand_v100_didcs_test.mbt`, cell (g = 1, t = 2) has
  // `sub_n = 200`, `n_wide = 100`, `n_panel = 800`, and only 50
  // of the 100 wide rows carry a non-zero `psi_a`. `var_est`
  // divides by `n_wide`, so both `sub_n` and the non-zero count
  // are the wrong denominator; see the section comment above
  // `m_inv_1x1_at` for the full measurement.
  //
  // Keeping the rows wide rather than long is also cheaper than
  // the long-format matrices above: `n_wide <= sub_n < n_obs`.
  //
  // An empty cell (`t_eval <= g`, or no observed pre-period)
  // stores the EMPTY array here. That is what lets the sandwich
  // accessors REFUSE such a cell with a clear message instead of
  // reporting a misleading `0.0` the way `se_at` does.
  cell_psi_a : Array[Array[Double]]
  cell_psi_b : Array[Array[Double]]
  n_groups : Int
  n_periods : Int
  fitted : Bool
  // v0.64.0+: multiplier bootstrap state. `boot_t_stat` is a
  // flat `[n_rep_boot * n_cells]` array of t-statistics in
  // row-major order (rep-major, then cell-major — the same
  // order as `DoubleMLDIDMulti::boot_t_stat`). Populated by
  // `bootstrap(...)`; empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
  // v0.82.0+: memoization flag. The wrapper's `fit()` forwards
  // this flag to every per-cell `DoubleMLDIDBinary.fit()` so the
  // aggregated cross-fits honour `.enable_memoize()` /
  // `.has_cache()` uniformly.
  memoize_enabled : Bool
} derive(Debug)

///|
pub extend DoubleMLDIDCS with @moonbitlang/core/debug.Debug::{to_repr}

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
  try {
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
      psi_a_matrix: Array::make(n_groups * n_periods * data.y.length(), 0.0),
      residuals_matrix: Array::make(n_groups * n_periods * data.y.length(), 0.0),
      // v0.100.0+: per-cell WIDE-format IF rows; populated by
      // `fit`. Empty entries are placeholders that `fit`
      // overwrites (whole-array assignment only, never in-place
      // mutation, so the shared `[]` default is never aliased).
      cell_psi_a: Array::make(n_groups * n_periods, []),
      cell_psi_b: Array::make(n_groups * n_periods, []),
      n_groups,
      n_periods,
      fitted: false,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      // v0.82.0+: default memoize off.
      memoize_enabled: false,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
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
  try {
    require(self.fitted)
    require(group_idx >= 0 && group_idx < self.n_groups)
    require(period_idx >= 0 && period_idx < self.n_periods)
    self.coef_matrix[group_idx * self.n_periods + period_idx]
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.82.0+: turn on memoization for subsequent `fit()` calls.
/// The flag is forwarded to every per-cell
/// `DoubleMLDIDBinary` fit.
pub fn DoubleMLDIDCS::enable_memoize(self : DoubleMLDIDCS) -> DoubleMLDIDCS {
  { ..self, memoize_enabled: true, }
}

///|
/// v0.82.0+: turn off memoization.
pub fn DoubleMLDIDCS::disable_memoize(self : DoubleMLDIDCS) -> DoubleMLDIDCS {
  { ..self, memoize_enabled: false, }
}

///|
/// v0.82.0+: drop any cached nuisance predictions across all
/// per-cell inner models. No-op on an un-fit wrapper.
pub fn DoubleMLDIDCS::clear_cache(self : DoubleMLDIDCS) -> DoubleMLDIDCS {
  self
}

///|
/// v0.82.0+: `true` iff the memoize flag is set.
pub fn DoubleMLDIDCS::has_cache(self : DoubleMLDIDCS) -> Bool {
  self.memoize_enabled
}

///|
/// Per-`(g, t)` ATT standard error.
pub fn DoubleMLDIDCS::se_at(
  self : DoubleMLDIDCS,
  group_idx : Int,
  period_idx : Int,
) -> Double {
  try {
    require(self.fitted)
    require(group_idx >= 0 && group_idx < self.n_groups)
    require(period_idx >= 0 && period_idx < self.n_periods)
    self.se_matrix[group_idx * self.n_periods + period_idx]
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
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
  try {
    require(group_idx >= 0 && group_idx < self.n_groups)
    self.data.groups[group_idx]
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Time value at column index `t` (sorted ascending).
pub fn DoubleMLDIDCS::period_at(self : DoubleMLDIDCS, period_idx : Int) -> Int {
  try {
    require(period_idx >= 0 && period_idx < self.n_periods)
    self.data.times[period_idx]
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

// ---------------------------------------------------------------------------
// v0.100.0: per-cell sandwich API (the `sandwich_se_at` triple)
// ---------------------------------------------------------------------------
//
// WHY DIDCS IS PER CELL, AND WHY IT IS NOT LIKE APOS
// =================================================
// `DoubleMLDIDCS` runs one independent child
// `DoubleMLDIDBinary` per `(g, t)` cell and keeps
// `coef_matrix` / `se_matrix`. Each child is a separate scalar
// Z-estimator with its own cross-fit, its own score and its own
// root, so each cell is a 1x1 sandwich problem and the methods are
// PER CELL, indexed like `coef_at` / `se_at`
// (`group_idx * n_periods + period_idx`) and shaped after
// `DoubleMLAPOS::sandwich_se_at` (v0.100.0) and
// `DoubleMLQTE::sandwich_se_at` (v0.95.0) rather than the joint
// multi-column `sandwich_se` of the DID family.
//
// Nothing has to be re-derived. The child already computed
// `psi_a` / `psi_b` for its own multiplier bootstrap, and
// `DoubleMLDIDBinary::sandwich_se` (v0.89.0) already routes
// those exact arrays through the shared `sandwich_variance`
// dispatch. Before v0.100.0 this file threw them away one level
// up: the cell loop read `inner_psi_a()` / `inner_psi_b()` to
// build the long-format matrices and then dropped the rest.
//
// THE `psi` ORDER IS NOT INTERCHANGEABLE
// --------------------------------------
// The long-format `psi_matrix` this file has persisted since
// v0.15.0 is built as
//
//     psi = psi_a + theta * psi_b
//
// but `var_est.mbt` (the package authority, and what
// `sandwich.mbt::psi_at` implements) defines
//
//     psi(theta) = theta * psi_a + psi_b
//
// The DID ATT score's `psi_a` is the treatment-weight term and
// `psi_b` the outcome score, so the two expressions are
// different functions: under the reversed order the estimating
// equation's derivative `dE[psi] / dtheta` is `E[psi_b]`, not
// `E[psi_a]`, and the root is not `theta_hat`. `psi_matrix` is
// therefore NOT a valid input to the sandwich, which is why the
// new `cell_psi_a` / `cell_psi_b` fields store the child's rows
// separately rather than unpacking `psi_matrix`. `psi_matrix` is
// left exactly as it was -- it feeds the multiplier bootstrap in
// `DoubleMLDIDMulti::bootstrap`, and changing its convention is
// out of scope here.
//
// THE DENOMINATOR, MEASURED
// ------------------------
// `se_matrix[k]` is `sub_fitted.se()` and nothing else, so the
// per-cell sandwich reproduces it iff it uses the row set and
// the `n` that the child's own `var_est` call used:
//
//     se = var_est(psi_a, psi_b)
//        = (Kahan sum of psi[i]^2 / n_wide)
//          / (mean(psi_a)^2 * n_wide)
//
// where `psi[i] = coef * psi_a[i] + psi_b[i]` and `n_wide` is the
// WIDE-format row count -- the `n_wide` units observed in BOTH
// the pre and the eval period after `preprocess_did_binary`, read
// back as `inner_psi_a().length()`.
//
// The three plausible denominators, measured on the
// 4-cohort / 4-period / 200-unit panel of
// `expand_v100_didcs_test.mbt` at cell (g = 1, t = 2):
//
//     n_wide = 100   <- `var_est`'s n. CORRECT.
//     sub_n  = 200   <- the long-format sub-panel the cell loop
//                       builds (50 G + 50 never-treated units, each
//                       observed in both of the two periods).
//     n_panel= 800   <- the full long-format panel.
//     (non-zero `psi_a` rows: 50 -- a fourth candidate, and the
//      one that looks right if you only read the sparse
//      `psi_a_matrix`.)
//
// The analytic identity `var = sum(psi^2) / sum(psi_a)^2` makes
// the variance invariant to which superset of the cell's rows you
// sum over, PROVIDED `mean(psi_a)` and `n` come from the SAME row
// set. Mixing them -- which is what reconstructing from the sparse
// long-format matrices forces, because a written zero and an
// unwritten zero are indistinguishable -- is what breaks it. So
// the fields store whole rows and the helpers take
// `length()` and `mean()` from the same array; no scalar `j` is
// persisted and nothing is inferred from zero patterns.
//
// BIT-IDENTITY, NOT A TOLERANCE
// ----------------------------
// `var_est` ends with `gamma / n` then `/(mean(psi_a)^2 * n)`;
// `sandwich_variance_hc0` computes `M_inv[0,0]^2 * acc / n / n`
// over the same Kahan sum of the same products in the same index
// order. The two op sequences coincide because for this score
// `psi_a[i] = -d[i] / p_hat` with `p_hat = mean(d)`, so
// `mean(psi_a) == -1` exactly and `M_inv[0,0]^2 == 1.0` exactly
// (the `* 1.0` is the IEEE identity). Measured on the cell above,
// `sandwich_se_at(0, 2, HC0) - se_at(0, 2) == 0.0` bit for bit;
// `expand_v100_didcs_test.mbt` asserts `==` and PRINTS the
// discrepancy for every non-degenerate cell so the claim is
// checkable from the test log.
//
// This holds for `n_rep >= 1` because the child calls `var_est`
// ONCE, on the nuisances it persisted, so the stored rows and the
// shipped `se` always describe the same score.
//
// THE MEMOIZE CACHE-HIT PATH
// --------------------------
// Unlike APOS, `DoubleMLDIDCS` has NO `FitCache` of its own: the
// struct has no `fit_cache` field and `fit` has no `cache_hit`
// branch. `memoize_enabled` is forwarded down the chain
// (`DoubleMLDIDCS` -> `DoubleMLDIDBinary` -> `DoubleMLDID`), and
// the cache that actually exists is the inner
// `DoubleMLDID::fit_cache`, which stores the per-rep nuisance
// PREDICTIONS `[g0_hat, g1_hat, m_clipped]` and re-derives
// `psi_a` / `psi_b` from them on a hit. That re-derivation is
// deterministic and does not depend on the cross-fit, so a cache
// hit reproduces the child's `psi_a` / `psi_b` / `coef` / `se`
// BYTE for BYTE -- which is what makes it safe for the cell loop
// to read them unconditionally on every `fit`, hit or miss.
//
// So the analogue of APOS's "restore the third predictions slot"
// is here: there is no separate restore branch to get right,
// because the parent re-enters the child loop on a hit and the
// child fills the same slots either way. What the second `fit()`
// must therefore preserve is the per-cell WIDE rows, and the
// regression this guards against is a `fit` that returned the
// `new()` all-empty `cell_psi_a` / `cell_psi_b` sentinel on the
// hit path -- which would ABORT inside `m_inv_1x1_at` rather
// than quietly return a wrong number. The cache-hit test drives
// the second fit from the FIRST returned value (`f1.fit()`),
// because `fit` takes `self` BY VALUE: `est.fit()` twice re-reads
// `est`'s own cold chain and the test would be vacuous.

///|
/// Flat cell index `group_idx * n_periods + period_idx`, after
/// validating `self.fitted` and both indices against
/// `n_groups` / `n_periods`. Mirrors the guard in `coef_at` /
/// `se_at` so every accessor in the family rejects the same
/// inputs the same way.
fn DoubleMLDIDCS::cell_flat_at(
  self : DoubleMLDIDCS,
  group_idx : Int,
  period_idx : Int,
) -> Int {
  try {
    require(self.fitted)
    require(group_idx >= 0 && group_idx < self.n_groups)
    require(period_idx >= 0 && period_idx < self.n_periods)
    group_idx * self.n_periods + period_idx
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// The `(g, t)` cell's WIDE-format `psi_a` row -- the child's own
/// `inner_psi_a()`, the array its `var_est` call averaged. A fresh
/// array of the row's own length, so the sandwich's accumulator
/// and the caller's `psi_at` result are never aliased with the
/// persisted state.
///
/// Aborts on an unestimated cell: `t_eval <= g`, or no observed
/// pre-treatment period, or an empty sub-panel. `se_at` reports
/// `0.0` for such a cell and a sandwich SE is not defined, so
/// returning a zero here would be a plausible-looking wrong
/// answer rather than an obvious absence.
fn DoubleMLDIDCS::cell_psi_a_row_at(
  self : DoubleMLDIDCS,
  group_idx : Int,
  period_idx : Int,
) -> Array[Double] {
  let flat = self.cell_flat_at(group_idx, period_idx)
  let row = self.cell_psi_a[flat]
  if row.length() == 0 {
    abort(
      "DoubleMLDIDCS: cell (group_idx=" +
      group_idx.to_string() +
      ", period_idx=" +
      period_idx.to_string() +
      ") has no estimate (t_eval <= g, no observed pre-period, or " +
      "an empty sub-panel); se_at() reports 0.0 for it and no " +
      "sandwich SE is defined",
    )
  }
  row
}

///|
/// The `(g, t)` cell's WIDE-format `psi_b` row -- the child's own
/// `inner_psi_b()`. Same guards and same flat index as
/// `cell_psi_a_row_at`; the two are always the same length
/// (`fit` asserts it at the point of capture).
fn DoubleMLDIDCS::cell_psi_b_row_at(
  self : DoubleMLDIDCS,
  group_idx : Int,
  period_idx : Int,
) -> Array[Double] {
  let flat = self.cell_flat_at(group_idx, period_idx)
  let row = self.cell_psi_b[flat]
  if row.length() == 0 {
    abort(
      "DoubleMLDIDCS: cell (group_idx=" +
      group_idx.to_string() +
      ", period_idx=" +
      period_idx.to_string() +
      ") has no estimate (t_eval <= g, no observed pre-period, or " +
      "an empty sub-panel); se_at() reports 0.0 for it and no " +
      "sandwich SE is defined",
    )
  }
  row
}

///|
/// The `(g, t)` cell's Jacobian inverse `M_inv` (1x1):
/// `[[1 / mean(psi_a)]]`, with `mean(psi_a)` taken over the
/// SAME `n_wide` rows the score is accumulated over -- the pairing
/// the whole file comment above insists on.
///
/// For this score `psi_a[i] = -d[i] / p_hat` with
/// `p_hat = mean(d)` (observational) or `p_hat = mean(d)`
/// (in-sample normalization), so `mean(psi_a) == -1` and
/// `M_inv[0,0] == -1.0`, `M_inv[0,0]^2 == 1.0` exactly; only the
/// square enters the variance, so the sign is immaterial. The
/// `mean != 0` guard is kept anyway: it is the assertion that
/// this cell's IF components are present and well-formed, and it
/// is the same shape the fifteen other estimators expose.
fn DoubleMLDIDCS::m_inv_1x1_at(
  self : DoubleMLDIDCS,
  group_idx : Int,
  period_idx : Int,
) -> Matrix {
  let psi_a = self.cell_psi_a_row_at(group_idx, period_idx)
  let mean_a = mean(psi_a)
  if !(mean_a.abs() > 0.0) {
    abort(
      "DoubleMLDIDCS: cell (group_idx=" +
      group_idx.to_string() +
      ", period_idx=" +
      period_idx.to_string() +
      ") has a degenerate Jacobian, mean(psi_a) = 0",
    )
  }
  Matrix::from_array([1.0 / mean_a], 1, 1)
}

///|
/// v0.100.0+: heteroskedasticity-consistent (Huber-White) sandwich
/// standard error for the `(g, t)` cell of a fitted CS-DID.
/// Routes through the shared `sandwich_variance` dispatch, so the
/// HC0 / HC1 / HC2 / HC3 relationships are the package-wide ones
/// (see the file header in `sandwich.mbt` and the identities
/// pinned in `expand_v088_test.mbt` and
/// `expand_v100_didcs_test.mbt`).
///
/// The three inputs are the ones the child `DoubleMLDIDBinary`
/// already computed and persisted for its own multiplier
/// bootstrap:
///   - `psi_a` = the child's wide-format `psi_a` row, i.e. the
///     treatment-weight term `-d / p_hat`;
///   - `psi`   = `psi_at(coef_at(g, t), psi_a, psi_b)` -- the
///     per-observation influence function at the fitted cell
///     coefficient, in the package-wide
///     `psi(theta) = theta * psi_a + psi_b` order. This is the
///     order `var_est` uses, and it is the OPPOSITE of the
///     `psi_a + theta * psi_b` order the long-format
///     `psi_matrix` uses -- see the section comment above;
///   - `M_inv` = `[[1 / mean(psi_a)]]`, which is `[[-1.0]]` here
///     (only `M_inv[0, 0]^2` enters the variance).
///
/// `n_obs` is the cell's `n_wide` -- the child's own wide-format
/// row count, the same `n` its `var_est` divided by -- and
/// `n_params` is 1: ONE scalar estimand (this cell's ATT), NOT
/// `n_groups` and NOT the number of visited cells. The plausible
/// misreading `k = n_groups` would give `sqrt(n / (n - k))` for
/// HC1 and is ruled out in the test.
///
/// `coef_at(g, t)` IS the child's stored `coef`, the same number
/// `var_est` solved for, so on the IID path
///
///     sandwich_se_at(g, t, HC0) == se_at(g, t)
///
/// holds BIT-IDENTICALLY (measured difference `0.0`; see the
/// section comment and `expand_v100_didcs_test.mbt`).
///
/// Preconditions: `self.fitted`,
/// `0 <= group_idx < n_groups`, `0 <= period_idx < n_periods`,
/// the cell was actually estimated, `mean(psi_a) != 0`, and
/// `n_obs > n_params` for HC1 / HC2 / HC3.
pub fn DoubleMLDIDCS::sandwich_se_at(
  self : DoubleMLDIDCS,
  group_idx : Int,
  period_idx : Int,
  kind : SandwichKind,
) -> Double {
  try {
    let m_inv = self.m_inv_1x1_at(group_idx, period_idx)
    let psi_a = self.cell_psi_a_row_at(group_idx, period_idx)
    let psi_b = self.cell_psi_b_row_at(group_idx, period_idx)
    require(psi_a.length() == psi_b.length())
    let coef = self.coef_matrix[self.cell_flat_at(group_idx, period_idx)]
    let psi = psi_at(coef, psi_a, psi_b)
    let n_obs = psi_a.length()
    let variance_val = sandwich_variance(kind, psi_a, psi, m_inv, n_obs, 1)
    require(variance_val >= 0.0)
    variance_val.sqrt()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.100.0+: cluster-robust sandwich standard error for the
/// `(g, t)` cell of a fitted CS-DID (Arellano 1987,
/// Cameron-Gelbach-Miller 2011). Routes through
/// `cluster_sandwich_variance` with the SAME `psi_a` / `psi` /
/// `M_inv` inputs as the IID `sandwich_se_at` path, and the same
/// per-cell `n_wide` row set.
///
/// `DoubleMLDIDCSData` has no `cluster_vars` field (the CS-DID
/// estimator itself fits no cluster path), so the caller must
/// supply `cluster_ids` explicitly. The ids are PER CELL AND PER
/// CELL ROW, not per long-format panel row:
/// `cluster_ids.length()` must equal this cell's
/// `cell_psi_a[g * n_periods + t].length()`, i.e. the child's
/// `n_wide`. For a `(g, t)` cell that is one entry per unit
/// observed in both the pre and the eval period, so the panel
/// `data.id` (length `n_units * n_periods`, long format) is the
/// WRONG array to pass; slice the cell's rows first, or build the
/// ids from the same `(g in {G, C}, t in {pre, eval})` rule the
/// cell loop uses. Cluster indices are 0-based and
/// `1 + max(cluster_ids)` is the number of clusters. For a DID
/// the natural grouping is the panel unit.
///
/// NOT equal to the IID HC0 once clusters hold more than one row,
/// and the reason is the MEAT, not the denominator:
/// `cluster_sandwich_variance` sums `S_c = (sum_{i in c}
/// psi[i])^2` per cluster, so the within-cluster cross terms
/// enter, and each cluster carries a per-cluster jackknife factor
/// `n_c / (n_c - 1)` (clipped to 1 for a singleton cluster). The
/// divisor is the same `n_wide^2` as HC0, and all rows of the
/// cell are the same rows. With ALL-SINGLETON clusters the meat
/// degenerates to `sum_i psi[i]^2`, the jackknife factors are all
/// 1, and the formula collapses to `sandwich_se_at(g, t, HC0)`
/// exactly -- which is the property `expand_v100_didcs_test.mbt`
/// pins.
///
/// This is the ROW-level cluster variance. A clustered FIT's
/// `se_at` in this package is divided by `n_units` (panel units),
/// not by the row count, so `cluster_sandwich_se_at` is not a
/// drop-in for a cluster-robust `se_at`; the DIDCS fit path takes
/// no clustering at all, so there is no clustered `se_at` to
/// disagree with here.
///
/// Preconditions: `self.fitted`, valid indices, the cell was
/// actually estimated, `mean(psi_a) != 0`,
/// `cluster_ids.length() == n_wide`, all `cluster_ids[i] >= 0`.
pub fn DoubleMLDIDCS::cluster_sandwich_se_at(
  self : DoubleMLDIDCS,
  group_idx : Int,
  period_idx : Int,
  cluster_ids : Array[Int],
) -> Double {
  try {
    let m_inv = self.m_inv_1x1_at(group_idx, period_idx)
    let psi_a = self.cell_psi_a_row_at(group_idx, period_idx)
    let psi_b = self.cell_psi_b_row_at(group_idx, period_idx)
    require(psi_a.length() == psi_b.length())
    let n_wide = psi_a.length()
    require(cluster_ids.length() == n_wide)
    let coef = self.coef_matrix[self.cell_flat_at(group_idx, period_idx)]
    let psi = psi_at(coef, psi_a, psi_b)
    let variance_val = cluster_sandwich_variance(
      psi_a, psi, m_inv, cluster_ids, 1,
    )
    require(variance_val >= 0.0)
    variance_val.sqrt()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.100.0+: returns `coef_at(group_idx, period_idx)` UNCHANGED
/// -- a documented no-op, not a bias correction. Identical in
/// reasoning to `DoubleMLAPO::bias_corrected_coef` (v0.91.0),
/// `DoubleMLAPOS::bias_corrected_coef_at` (v0.100.0) and
/// `DoubleMLQTE::bias_corrected_coef_at`; see
/// `DoubleMLPQ::bias_corrected_coef` and `bias_corrected_theta`
/// in `sandwich.mbt` for the full argument.
///
/// `coef_at(g, t)` is the child's root of the DML moment
/// `f(theta) = E[theta * psi_a + psi_b]` (`var_est.mbt`), so
/// `mean(f(coef_at(g, t)))` is identically zero: the estimating
/// function is orthogonal by construction, and that orthogonality
/// IS what makes the estimator consistent. Nothing computable
/// from the fitted scores is a bias estimate for this class of
/// estimator, so this accessor reports the uncorrected point
/// estimate rather than a number that merely looks like a
/// correction.
///
/// The pre-v0.91.0 form `coef + mean(psi_b - coef * psi_a)` is
/// that vector at `-coef`, NOT at `coef`; since
/// `coef = -mean_b / mean_a` its mean is
/// `mean_b - coef * mean_a = -2 * coef * mean_a`, so the
/// accessor returned `coef * (1 - 2 * mean(psi_a))` -- exactly
/// `3 * coef` when `mean(psi_a) = -1`, which is exactly this
/// score's case for every cell. That is not a bias estimate.
///
/// Unlike `sandwich_se_at`, an unestimated cell does NOT abort
/// here: the answer is the identity on `coef_at`, and `coef_at`
/// reports `0.0` for such a cell, so `0.0` is the consistent
/// answer rather than a misleading one.
///
/// The method is per cell, matching the rest of the v0.100.0
/// DIDCS API.
///
/// Preconditions: `self.fitted`,
/// `0 <= group_idx < n_groups`, `0 <= period_idx < n_periods`.
pub fn DoubleMLDIDCS::bias_corrected_coef_at(
  self : DoubleMLDIDCS,
  group_idx : Int,
  period_idx : Int,
) -> Double {
  self.coef_matrix[self.cell_flat_at(group_idx, period_idx)]
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
  ml_g? : LearnerDispatch = LearnerDispatch::linear_regression(),
  ml_m? : LearnerDispatch = LearnerDispatch::linear_regression(),
) -> DoubleMLDIDCS {
  ignore(ml_g)
  ignore(ml_m)
  try {
    require(self.n_groups >= 1 && self.n_periods >= 1)
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
    // v0.69.0+: per-cell Riesz-representer component `psi_a`
    // (no `theta * psi_b` term) on long-format panel,
    // parallel to `psi_values`. Used by the per-cell
    // `irm_style_sensitivity` decomposition in
    // `DoubleMLDIDCS::sensitivity_analysis`.
    let psi_a_values : Array[Array[Double]] = []
    let mut psi_a_values_acc = psi_a_values
    // v0.69.0+: per-cell outcome residuals
    // `y - g_d0_hat - (g_d1_hat - g_d0_hat) * d` on the
    // long-format panel, parallel to `psi_values`. Drives
    // the per-cell IRM-style sensitivity helper.
    let residuals_values : Array[Array[Double]] = []
    let mut residuals_values_acc = residuals_values
    // v0.100.0+: per-cell WIDE-format `psi_a` / `psi_b` -- the
    // child's own rows, i.e. the arrays its `var_est` call
    // summed. Parallel to `psi_values_acc`, and visited in the same
    // order, so the reassembly pass below can index all four
    // accumulators with the single `coef_idx` cursor.
    let cell_psi_a_values : Array[Array[Double]] = []
    let mut cell_psi_a_values_acc = cell_psi_a_values
    let cell_psi_b_values : Array[Array[Double]] = []
    let mut cell_psi_b_values_acc = cell_psi_b_values
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
        let sub_pre = DoubleMLDIDBinary::new(
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
        )
        // v0.82.0+: forward the memoize flag to every per-cell
        // DoubleMLDIDBinary so the aggregated cross-fits
        // honour the cache uniformly.
        let sub_pre_memo = if self.memoize_enabled {
          sub_pre.enable_memoize()
        } else {
          sub_pre
        }
        let sub_fitted = sub_pre_memo.fit(ml_g~, ml_m~)
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
        // v0.69.0+: pull the inner nuisance predictions so the
        // per-cell outcome residual
        // `y - g_d0_hat - (g_d1_hat - g_d0_hat) * d` can be
        // computed and mapped to long-format. The sub-set
        // ordering matches `inner_psi_a` (wide-format via
        // `sub_to_wide`).
        let inner_g0 = sub_fitted.predictions_g0()
        let inner_g1 = sub_fitted.predictions_g1()
        let sub_to_wide = sub_fitted.eval_idx
        let psi_long : Array[Double] = Array::make(n, 0.0)
        // v0.69.0+: per-cell psi_a long-format accumulator.
        let psi_a_long : Array[Double] = Array::make(n, 0.0)
        // v0.69.0+: per-cell residuals long-format accumulator.
        let residuals_long : Array[Double] = Array::make(n, 0.0)
        for k_wide = 0; k_wide < sub_to_wide.length(); k_wide = k_wide + 1 {
          let k_sub = sub_to_wide[k_wide]
          let full_i = full_idx_acc[k_sub]
          psi_long[full_i] = inner_psi_a[k_wide] + theta * inner_psi_b[k_wide]
          psi_a_long[full_i] = inner_psi_a[k_wide]
          // residuals_long[full_i] = y - g0 - (g1 - g0) * d
          // (the ATT-form residual; matches the v0.66.0
          // DIDCSBinary::sensitivity residual convention).
          // `d_sub_acc[k_wide]` is the cell-recomputed d
          // (= 1 iff unit is in G cohort AND in eval period).
          residuals_long[full_i] = y_sub_acc[k_wide] -
            inner_g0[k_wide] -
            (inner_g1[k_wide] - inner_g0[k_wide]) * d_sub_acc[k_wide]
        }
        psi_values_acc = psi_values_acc + [psi_long]
        psi_a_values_acc = psi_a_values_acc + [psi_a_long]
        residuals_values_acc = residuals_values_acc + [residuals_long]
        // v0.100.0+: persist the child's OWN wide-format IF rows
        // for the sandwich API. Copied rather than aliased so the
        // persisted state cannot be mutated through the discarded
        // child, and length-checked here rather than at read time
        // so a future change to the child's IF layout fails at the
        // point of the change instead of silently mis-slicing a
        // sandwich SE much later.
        require(inner_psi_a.length() == inner_psi_b.length())
        require(inner_psi_a.length() >= 1)
        let wide_a : Array[Double] = Array::make(inner_psi_a.length(), 0.0)
        let wide_b : Array[Double] = Array::make(inner_psi_b.length(), 0.0)
        for k_wide2 = 0; k_wide2 < inner_psi_a.length(); k_wide2 = k_wide2 + 1 {
          wide_a[k_wide2] = inner_psi_a[k_wide2]
          wide_b[k_wide2] = inner_psi_b[k_wide2]
        }
        cell_psi_a_values_acc = cell_psi_a_values_acc + [wide_a]
        cell_psi_b_values_acc = cell_psi_b_values_acc + [wide_b]
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
    // v0.69.0+: per-cell Riesz-representer `psi_a` (no
    // `theta * psi_b` term) and per-cell outcome residual
    // (ATT-form `y - g_d0 - (g_d1 - g_d0) * d`) on the
    // long-format panel, parallel to `final_psi`. Empty
    // cells stay at 0.0. Drives the per-cell
    // `irm_style_sensitivity` decomposition in
    // `DoubleMLDIDCS::sensitivity_analysis`.
    let final_psi_a : Array[Double] = Array::make(
      self.n_groups * self.n_periods * n,
      0.0,
    )
    let final_res : Array[Double] = Array::make(
      self.n_groups * self.n_periods * n,
      0.0,
    )
    // v0.100.0+: per-cell WIDE-format `psi_a` / `psi_b` rows for
    // the sandwich API, row-major by flat cell index. Cells that
    // were not visited keep the EMPTY array, which the sandwich
    // accessors treat as "no estimate here" and refuse with a
    // clear message.
    let final_cell_psi_a : Array[Array[Double]] = Array::make(
      self.n_groups * self.n_periods,
      [],
    )
    let final_cell_psi_b : Array[Array[Double]] = Array::make(
      self.n_groups * self.n_periods,
      [],
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
        // v0.69.0+: copy the per-cell psi_a and per-cell
        // residuals into the matching row-major slots
        // (parallel to `final_psi`).
        let psi_a_k = psi_a_values_acc[coef_idx]
        let res_k = residuals_values_acc[coef_idx]
        for k = 0; k < n; k = k + 1 {
          final_psi_a[flat * n + k] = psi_a_k[k]
          final_res[flat * n + k] = res_k[k]
        }
        // v0.100.0+: same placement for the wide-format IF rows.
        // Whole-array assignment: the per-cell rows are shared by
        // reference with `cell_psi_a_values_acc` and are never
        // mutated in place afterwards.
        final_cell_psi_a[flat] = cell_psi_a_values_acc[coef_idx]
        final_cell_psi_b[flat] = cell_psi_b_values_acc[coef_idx]
        coef_idx = coef_idx + 1
      }
    }
    {
      ..self,
      coef_matrix: final_coef,
      se_matrix: final_se,
      psi_matrix: final_psi,
      psi_a_matrix: final_psi_a,
      residuals_matrix: final_res,
      // v0.100.0+: persisted per-cell WIDE-format IF rows. Set
      // here (not left to the `new()` sentinel) on EVERY `fit`,
      // so the state is correct whether or not memoize is on and
      // whether or not this call re-used cached nuisance
      // predictions. See the section comment above
      // `m_inv_1x1_at` for the cache-hit argument.
      cell_psi_a: final_cell_psi_a,
      cell_psi_b: final_cell_psi_b,
      fitted: true,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.64.0+: multiplier bootstrap for `DoubleMLDIDCS`. For
/// each (g, t) cell that has a non-zero SE, materialises the
/// per-cell IF row (`psi_matrix[(gi * n_periods + pi) *
/// n_obs + i_long]`) into a flat `[n_cells, n_obs]` psi
/// matrix and calls the shared `generic_bootstrap_psi_matrix`
/// helper. `boot_t_stat` is a flat `[n_rep_boot * n_cells]`
/// array, row-major by rep, then by cell — the same layout as
/// `DoubleMLDIDMulti::boot_t_stat`. Pre-treatment or empty
/// cells (`se_matrix[k] == 0`) are zeroed out by the helper.
///
/// `method_name` selects the multiplier distribution:
/// `"normal"` (default), `"Bayes"`, `"wild"`. `seed` defaults
/// to `2024`; `n_rep_boot` defaults to `500`.
///
/// Calling on an un-fit model aborts via `PreconditionError`.
pub fn DoubleMLDIDCS::bootstrap(
  self : DoubleMLDIDCS,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLDIDCS {
  try {
    require(self.fitted)
    require(
      method_name == "normal" || method_name == "Bayes" || method_name == "wild",
    )
    require(n_rep_boot >= 2)
    let n_obs = self.data.y.length()
    let n_cells = self.n_groups * self.n_periods
    let psi_flat : Array[Double] = Array::make(n_cells * n_obs, 0.0)
    for k = 0; k < n_cells; k = k + 1 {
      if self.se_matrix[k] <= 0.0 {
        continue
      }
      for i_long = 0; i_long < n_obs; i_long = i_long + 1 {
        psi_flat[k * n_obs + i_long] = self.psi_matrix[k * n_obs + i_long]
      }
    }
    let boot_t_stat = generic_bootstrap_psi_matrix(
      psi_flat,
      self.se_matrix,
      method_name,
      n_rep_boot,
      n_obs,
      n_cells,
      seed,
    ) catch {
      BootstrapMethodError::UnknownMethod(m) =>
        abort(
          "draw_bootstrap_weights: unknown method (set in DoubleMLDIDCS::bootstrap): " +
          m,
        )
    }
    {
      ..self,
      boot_t_stat,
      boot_method: method_name,
      n_rep_boot,
      boot_seed: seed,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.69.0+: per-(g, t) sensitivity analysis for `DoubleMLDIDCS`.
///
/// Each (g, t) cell that has a fitted estimate (`se_matrix[k]
/// > 0`) gets its own `SensitivityResult` via the shared
/// `irm_style_sensitivity` helper, using the per-cell
/// Riesz-representer `psi_a` and per-cell outcome residual
/// (ATT-form `y - g_d0_hat - (g_d1_hat - g_d0_hat) * d`)
/// persisted by `fit` in `psi_a_matrix` and
/// `residuals_matrix` (same row-major layout as
/// `psi_matrix`). The cell-decomposition is identical to
/// the v0.66.0 `DoubleMLDIDCSBinary::sensitivity_analysis`
/// decomposition; the only difference is the per-cell
/// scope (one result per (g, t) cell instead of a single
/// cell-wide result for DIDCSBinary).
///
/// Cells with `se_matrix[k] == 0` (pre-treatment / no
/// observed evaluation period / empty panel subset) return
/// a zeroed `SensitivityResult` (same default as
/// `DoubleMLAPOS::sensitivity` for missing cells).
///
/// `cf_y` and `cf_d` default to `0.05` matching the rest
/// of the v0.66.0-onward sensitivity family.
///
/// Returns an `Array[SensitivityResult]` of length
/// `n_groups * n_periods` in row-major `(gi, pi)` order.
// Indices for unavailable cells stay at the zero

///|
/// default. Calling on an un-fit model aborts via
/// `PreconditionError`.
pub fn DoubleMLDIDCS::sensitivity_analysis(
  self : DoubleMLDIDCS,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> Array[SensitivityResult] raise {
  require(self.fitted)
  let n_obs = self.data.y.length()
  let n_cells = self.n_groups * self.n_periods
  let zero_result : SensitivityResult = {
    rv: 0.0,
    sigma2: 0.0,
    nu2: 0.0,
    cf_y: 0.0,
    cf_d: 0.0,
    max_bias: 0.0,
  }
  let out : Array[SensitivityResult] = Array::make(n_cells, zero_result)
  for k = 0; k < n_cells; k = k + 1 {
    if self.se_matrix[k] <= 0.0 {
      continue
    }
    let psi_a_k : Array[Double] = Array::make(n_obs, 0.0)
    let residuals_k : Array[Double] = Array::make(n_obs, 0.0)
    for i_long = 0; i_long < n_obs; i_long = i_long + 1 {
      psi_a_k[i_long] = self.psi_a_matrix[k * n_obs + i_long]
      residuals_k[i_long] = self.residuals_matrix[k * n_obs + i_long]
    }
    out[k] = irm_style_sensitivity(
      self.coef_matrix[k],
      residuals_k,
      psi_a_k,
      cf_y,
      cf_d,
    )
  }
  out
}

///|
/// When `joint = false` (default), uses the Wald-style
/// `theta ± 1.96 * se` interval. When `joint = true`, uses
/// the bootstrap: `theta ± critical_value * se` where
/// `critical_value` is the (1 - alpha) quantile of
/// `max_k |boot_t_stat[b, k]|` over bootstrap replications
/// `b` (the joint critical value). Requires `bootstrap()`
/// to have been called.
pub fn DoubleMLDIDCS::confint(
  self : DoubleMLDIDCS,
  joint? : Bool = false,
  level? : Double = 0.95,
) -> Array[(Double, Double)] {
  try {
    require(self.fitted)
    require(level > 0.0 && level < 1.0)
    if joint {
      require(self.boot_t_stat.length() > 0)
    }
    let alpha = 1.0 - level
    let mut z = norm_ppf(1.0 - alpha / 2.0)
    let n_cells = self.n_groups * self.n_periods
    let out : Array[(Double, Double)] = Array::make(n_cells, (0.0, 0.0))
    if joint {
      let n_boot = self.n_rep_boot
      let max_t_arr : Array[Double] = Array::make(n_boot, 0.0)
      for b = 0; b < n_boot; b = b + 1 {
        let mut mx = 0.0
        for k = 0; k < n_cells; k = k + 1 {
          let t : Double = self.boot_t_stat[b * n_cells + k]
          let abs_t : Double = if t < 0.0 { -t } else { t }
          if abs_t > mx {
            mx = abs_t
          }
        }
        max_t_arr[b] = mx
      }
      max_t_arr.sort()
      let idx = ((n_boot - 1).to_double() * (1.0 - alpha)).to_int()
      z = max_t_arr[idx]
    }
    for k = 0; k < n_cells; k = k + 1 {
      let coef = self.coef_matrix[k]
      let se = self.se_matrix[k]
      let lo = coef - z * se
      let hi = coef + z * se
      out[k] = (lo, hi)
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.73.0+: cluster-robust analogue of
/// `DoubleMLDIDCS::sensitivity_analysis`. Same per-cell
/// ATT-form residual `y - g_d0_hat - (g_d1_hat - g_d0_hat) *
/// d` and the same per-cell `psi_a` (the Riesz-representer
/// component) as the IID path; only the variance / bias
/// computation is cluster-aware (see
/// `irm_style_sensitivity_cluster_multi` and
/// `irm_style_sensitivity_cluster` in sensitivity.mbt).
///
/// `DoubleMLDIDCSData` has no `cluster_vars` field (the
/// CS-DID estimator itself does not fit a cluster path), so
/// the user must pass `cluster_ids` explicitly.
/// `cluster_ids.length()` must equal `self.data.n_obs()`
/// (the long-format panel length). Cluster indices are
/// 0-based; `1 + max(cluster_ids)` is the number of
/// clusters. All rows in the same cluster share an id.
///
/// Cells with `se_matrix[k] == 0` (pre-treatment / no
/// observed evaluation period / empty panel subset) return
/// a zeroed `SensitivityResult` from the inner
/// `irm_style_sensitivity_cluster` pass.
///
/// Returns an `Array[SensitivityResult]` of length
/// `n_groups * n_periods` in row-major `(gi, pi)` order.
pub fn DoubleMLDIDCS::sensitivity_analysis_cluster(
  self : DoubleMLDIDCS,
  cluster_ids : Array[Int],
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> Array[SensitivityResult] raise {
  require(self.fitted)
  let n_obs = self.data.y.length()
  require(cluster_ids.length() == n_obs)
  let n_cells = self.n_groups * self.n_periods
  let residuals_arr : Array[Array[Double]] = Array::make(n_cells, [])
  let psi_a_arr : Array[Array[Double]] = Array::make(n_cells, [])
  for k = 0; k < n_cells; k = k + 1 {
    let psi_a_k : Array[Double] = Array::make(n_obs, 0.0)
    let residuals_k : Array[Double] = Array::make(n_obs, 0.0)
    for i_long = 0; i_long < n_obs; i_long = i_long + 1 {
      psi_a_k[i_long] = self.psi_a_matrix[k * n_obs + i_long]
      residuals_k[i_long] = self.residuals_matrix[k * n_obs + i_long]
    }
    residuals_arr[k] = residuals_k
    psi_a_arr[k] = psi_a_k
  }
  let zero_result : SensitivityResult = {
    rv: 0.0,
    sigma2: 0.0,
    nu2: 0.0,
    cf_y: 0.0,
    cf_d: 0.0,
    max_bias: 0.0,
  }
  let out_all = irm_style_sensitivity_cluster_multi(
    self.coef_matrix,
    residuals_arr,
    psi_a_arr,
    cluster_ids,
    cf_y,
    cf_d,
  )
  for k = 0; k < n_cells; k = k + 1 {
    if self.se_matrix[k] <= 0.0 {
      out_all[k] = zero_result
    }
  }
  out_all
}
