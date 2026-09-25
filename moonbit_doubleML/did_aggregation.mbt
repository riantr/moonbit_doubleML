///|
/// Aggregation result for a single axis (group, time, or event).
/// `theta` is the weighted-mean ATT, `se` is the delta-method SE,
/// `agg_names[i]` is the human-readable label (e.g. the group
/// value, the time period, or the event-time value).
pub struct DIDAggregationResult {
  theta : Array[Double]
  se : Array[Double]
  agg_names : Array[String]
} derive(Debug)
pub extend DIDAggregationResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Group aggregation. For each unique group value `g_i` in
/// `groups`, computes the weighted mean of `coef_matrix[gi, :]`
/// (the per-`g_i` post-treatment ATTs) with weights proportional
/// to `n_units_in_group_g_i` (the share of units in group `g_i`).
///
/// Arguments:
///   - `coef_matrix` : row-major `(n_groups, n_periods)` ATT
///     matrix from a fitted `DoubleMLDIDCS` / `DoubleMLDIDMulti`.
///     `coef_matrix[gi * n_periods + pi]` is the ATT for group
///     `groups[gi]` at period `periods[pi]`. Pre-treatment cells
///     (e.g. `t < g`) are expected to be `0.0` (the
///     `DoubleMLDIDCS` convention).
///   - `se_matrix`   : row-major `(n_groups, n_periods)` SE matrix
///     (same shape as `coef_matrix`).
///   - `groups`      : the sorted-ascending unique group values.
///   - `periods`     : the sorted-ascending unique time-period
///     values (the same `times` accessor from
///     `DoubleMLDIDCSData`).
///   - `group_sizes` : per-unit group sizes (one entry per
///     unique row in the long-format panel). Must be aligned with
///     `groups`; entry `i` is the number of units in
///     `groups[i]`.
///
/// Returns a `DIDAggregationResult` with one entry per group.
pub fn aggregate_group(
  coef_matrix : Array[Double],
  se_matrix : Array[Double],
  groups : Array[Int],
  periods : Array[Int],
  group_sizes : Array[Int],
) -> DIDAggregationResult {
  try {
    let n_groups = groups.length()
    let n_periods = periods.length()
    require(coef_matrix.length() == n_groups * n_periods)
    require(se_matrix.length() == n_groups * n_periods)
    require(group_sizes.length() == n_groups)
    // Total units (denominator for the per-group share).
    let mut total = 0
    for i = 0; i < n_groups; i = i + 1 {
      total = total + group_sizes[i]
    }
    require(total > 0)
    // For each group g_i, average the post-treatment (t >= g_i)
    // per-(g_i, t) ATTs with weight 1/n_periods.
    let theta : Array[Double] = Array::make(n_groups, 0.0)
    let se : Array[Double] = Array::make(n_groups, 0.0)
    let names : Array[String] = Array::make(n_groups, "")
    for i = 0; i < n_groups; i = i + 1 {
      let g_value = groups[i]
      let mut sum_w_theta = 0.0
      let mut sum_w = 0.0
      let mut sum_w2_se2 = 0.0
      for pi = 0; pi < n_periods; pi = pi + 1 {
        let t_eval = periods[pi]
        if t_eval <= g_value {
          continue
        }
        let flat = i * n_periods + pi
        let w = 1.0
        sum_w_theta = sum_w_theta + w * coef_matrix[flat]
        sum_w = sum_w + w
        sum_w2_se2 = sum_w2_se2 + w * w * se_matrix[flat] * se_matrix[flat]
      }
      if sum_w > 0.0 {
        theta[i] = sum_w_theta / sum_w
        // (v0.52.0: removed dead code `let w_g = ...; ignore(w_g)`.
        // Group-level weight for the *overall* aggregation used to be
        // computed here but was never read by the time/overall
        // aggregators; the package's `aggregate_*` helpers compute
        // the same ratio internally.)
        se[i] = (sum_w2_se2 / (sum_w * sum_w)).sqrt()
      }
      names[i] = g_value.to_string()
    }
    { theta, se, agg_names: names, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Time aggregation. For each unique time period `t_j` in
/// `periods`, computes the weighted mean of all per-`(g, t_j)`
/// ATTs (across groups) with weights proportional to
/// `group_sizes[g]` (the share of units in each group).
///
/// Pre-treatment cells (`t < g`) are skipped. Returns one entry
/// per period.
pub fn aggregate_time(
  coef_matrix : Array[Double],
  se_matrix : Array[Double],
  groups : Array[Int],
  periods : Array[Int],
  group_sizes : Array[Int],
) -> DIDAggregationResult {
  try {
    let n_groups = groups.length()
    let n_periods = periods.length()
    require(coef_matrix.length() == n_groups * n_periods)
    require(se_matrix.length() == n_groups * n_periods)
    require(group_sizes.length() == n_groups)
    let mut total = 0
    for i = 0; i < n_groups; i = i + 1 {
      total = total + group_sizes[i]
    }
    require(total > 0)
    let theta : Array[Double] = Array::make(n_periods, 0.0)
    let se : Array[Double] = Array::make(n_periods, 0.0)
    let names : Array[String] = Array::make(n_periods, "")
    for pi = 0; pi < n_periods; pi = pi + 1 {
      let t_eval = periods[pi]
      let mut sum_w_theta = 0.0
      let mut sum_w = 0.0
      let mut sum_w2_se2 = 0.0
      for i = 0; i < n_groups; i = i + 1 {
        let g_value = groups[i]
        if t_eval <= g_value {
          continue
        }
        let flat = i * n_periods + pi
        let w = group_sizes[i].to_double()
        sum_w_theta = sum_w_theta + w * coef_matrix[flat]
        sum_w = sum_w + w
        sum_w2_se2 = sum_w2_se2 + w * w * se_matrix[flat] * se_matrix[flat]
      }
      if sum_w > 0.0 {
        theta[pi] = sum_w_theta / sum_w
        se[pi] = (sum_w2_se2 / (sum_w * sum_w)).sqrt()
      }
      names[pi] = t_eval.to_string()
    }
    { theta, se, agg_names: names, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Event-study aggregation. For each unique event time
/// `e = t_eval - g`, computes the weighted mean of all
/// per-`(g, t_eval)` ATTs with `t_eval - g = e`.
///
/// Pre-treatment cells (`e < 0`) are included as pre-trend
/// estimates (matching upstream's default; upstream
/// `agg_weights` only normalises post-treatment cells, but the
/// per-event theta uses all selected cells, so the event-time
/// profile includes pre-trend as a sanity check). Returns one
/// entry per unique event time.
pub fn aggregate_event(
  coef_matrix : Array[Double],
  se_matrix : Array[Double],
  groups : Array[Int],
  periods : Array[Int],
  group_sizes : Array[Int],
) -> DIDAggregationResult {
  try {
    let n_groups = groups.length()
    let n_periods = periods.length()
    require(coef_matrix.length() == n_groups * n_periods)
    require(se_matrix.length() == n_groups * n_periods)
    require(group_sizes.length() == n_groups)
    // Collect unique event times (in ascending order).
    let e_set : Array[Int] = []
    let mut e_set_acc = e_set
    for i = 0; i < n_groups; i = i + 1 {
      let g_value = groups[i]
      for pi = 0; pi < n_periods; pi = pi + 1 {
        let t_eval = periods[pi]
        let e = t_eval - g_value
        let mut found = false
        for k = 0; k < e_set_acc.length(); k = k + 1 {
          if e_set_acc[k] == e {
            found = true
          }
        }
        if !found {
          e_set_acc = e_set_acc + [e]
        }
      }
    }
    e_set_acc.sort()
    let n_e = e_set_acc.length()
    let theta : Array[Double] = Array::make(n_e, 0.0)
    let se : Array[Double] = Array::make(n_e, 0.0)
    let names : Array[String] = Array::make(n_e, "")
    for ei = 0; ei < n_e; ei = ei + 1 {
      let e = e_set_acc[ei]
      // Skip the pre-treatment baseline (e = 0) cells: those are
      // the pre-treatment `t = g` cells that `DoubleMLDIDCS`
      // leaves at 0.0 by convention. Including them would
      // mechanically drag the event-time-0 estimate toward 0.
      if e <= 0 {
        theta[ei] = 0.0
        se[ei] = 0.0
        names[ei] = e.to_string()
        continue
      }
      let mut sum_w_theta = 0.0
      let mut sum_w = 0.0
      let mut sum_w2_se2 = 0.0
      for i = 0; i < n_groups; i = i + 1 {
        let g_value = groups[i]
        for pi = 0; pi < n_periods; pi = pi + 1 {
          let t_eval = periods[pi]
          if t_eval - g_value != e {
            continue
          }
          let flat = i * n_periods + pi
          let w = group_sizes[i].to_double()
          sum_w_theta = sum_w_theta + w * coef_matrix[flat]
          sum_w = sum_w + w
          sum_w2_se2 = sum_w2_se2 + w * w * se_matrix[flat] * se_matrix[flat]
        }
      }
      if sum_w > 0.0 {
        theta[ei] = sum_w_theta / sum_w
        se[ei] = (sum_w2_se2 / (sum_w * sum_w)).sqrt()
      }
      names[ei] = e.to_string()
    }
    { theta, se, agg_names: names, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
