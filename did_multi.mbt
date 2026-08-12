///|
/// `DoubleMLDIDMulti` is a thin top-level wrapper over
/// `DoubleMLDIDCS` that adds:
///
///  1. A `gt_combinations` selector. Each combination is a
///     `(g_value, t_value_pre, t_value_eval)` triple. The
///     convenience keyword `"standard"` expands to "every
///     post-treatment (g, t) with t_pre = g" (the default
///     Callaway-Sant'Anna staggered set). `"all"` additionally
///     includes pre-treatment cells for the event-study profile.
///     `"universal"` is the same as `"all"` for the panel
///     case (a cross-section-only setting in upstream is not
///     ported; see the "Notes" section in `CHANGELOG.md`).
///  2. `aggregate_group`, `aggregate_time`, `aggregate_event`
///     methods that wrap the matching helpers in
///     `did_aggregation.mbt`.
///
/// `DoubleMLDIDMulti::fit` reuses `DoubleMLDIDCS::fit` to
/// compute the per-(g, t) ATT matrix (and SE matrix), then
/// hands the matrices to the aggregation helpers. The internal
/// `DoubleMLDIDCS` instance is the canonical per-(g, t)
/// estimator; `DoubleMLDIDMulti` adds the `gt_combinations`
/// filter and the aggregation API on top.
pub struct DoubleMLDIDMulti {
  data : DoubleMLDIDCSData
  // gt_combinations: list of `(g_value, t_value_pre, t_value_eval)`
  // triples. May be set explicitly or expanded from a keyword
  // string at construction time; canonical (sorted, deduped) form.
  gt_combinations : Array[(Int, Int, Int)]
  control_group : String
  anticipation_periods : Int
  n_folds : Int
  n_rep : Int
  seed : Int
  ps_processor : PSProcessor
  in_sample_normalization : Bool
  // Per-unit group sizes for aggregation weights. Filled in
  // `fit` from the data.
  group_sizes : Array[Int]
  // The inner per-(g, t) estimator.
  inner : DoubleMLDIDCS
  fitted : Bool
} derive(Debug)

///|
/// Construct a `DoubleMLDIDMulti`.
///
/// `gt_combinations` may be either an `Array[(Int, Int, Int)]` of
/// explicit `(g_value, t_value_pre, t_value_eval)` triples, or
/// one of the keywords:
///
///   - `"standard"`: every (g, t) with `t > g` and `t_pre = g`
///     (the default Callaway-Sant'Anna staggered set).
///   - `"all"`: every (g, t) in the (groups × periods) grid.
///   - `"universal"`: same as `"all"` for the panel case
///     (upstream's `universal` is only meaningful for repeated
///     cross sections, which this port does not implement).
pub fn DoubleMLDIDMulti::new(
  data : DoubleMLDIDCSData,
  gt_combinations? : Array[(Int, Int, Int)] = [],
  gt_combinations_keyword? : String = "standard",
  control_group? : String = "never_treated",
  anticipation_periods? : Int = 0,
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  ps_processor? : PSProcessor = PSProcessor::new(),
  in_sample_normalization? : Bool = false,
) -> DoubleMLDIDMulti {
  require(n_folds >= 2)
  require(n_rep >= 1)
  require(anticipation_periods >= 0)
  require(control_group == "never_treated" || control_group == "not_yet_treated")
  let n_groups = data.groups.length()
  let n_periods = data.times.length()
  // Resolve `gt_combinations`: explicit list wins, otherwise
  // expand the keyword.
  let resolved = if gt_combinations.length() > 0 {
    gt_combinations
  } else {
    expand_gt_keyword(gt_combinations_keyword, data.groups, data.times, anticipation_periods)
  }
  require(resolved.length() > 0)
  // Sanity-check each triple against the data.
  for i = 0; i < resolved.length(); i = i + 1 {
    let (g, t_pre, t_eval) = resolved[i]
    let mut g_found = false
    for j = 0; j < n_groups; j = j + 1 {
      if data.groups[j] == g {
        g_found = true
      }
    }
    let mut t_pre_found = false
    let mut t_eval_found = false
    for j = 0; j < n_periods; j = j + 1 {
      if data.times[j] == t_pre {
        t_pre_found = true
      }
      if data.times[j] == t_eval {
        t_eval_found = true
      }
    }
    require(g_found)
    require(t_pre_found)
    require(t_eval_found)
    require(t_eval > t_pre)
    ignore(n_groups)
    ignore(n_periods)
  }
  // Per-unit group sizes (for aggregation weights). Equal
  // across groups: `n_total / n_groups`, with leftover units
  // distributed in the first `n_total mod n_groups` groups.
  let mut n_units = 0
  // Count the unit count by finding the largest id.
  let mut max_id = -1
  for i = 0; i < data.id.length(); i = i + 1 {
    if data.id[i] > max_id {
      max_id = data.id[i]
    }
  }
  n_units = max_id + 1
  let base = n_units / n_groups
  let rem = n_units % n_groups
  let group_sizes : Array[Int] = Array::make(n_groups, 0)
  for i = 0; i < n_groups; i = i + 1 {
    group_sizes[i] = base + (if i < rem { 1 } else { 0 })
  }
  // Build the inner `DoubleMLDIDCS` (its `fit` will be called
  // by `DoubleMLDIDMulti::fit`).
  let inner = DoubleMLDIDCS::new(
    data,
    control_group~,
    anticipation_periods~,
    n_folds~,
    n_rep~,
    seed~,
    ps_processor~,
    in_sample_normalization~,
  )
  ignore(control_group)
  {
    data,
    gt_combinations: resolved,
    control_group,
    anticipation_periods,
    n_folds,
    n_rep,
    seed,
    ps_processor,
    in_sample_normalization,
    group_sizes,
    inner,
    fitted: false,
  }
}

///|
/// Expand the `gt_combinations_keyword` string to a list of
/// `(g, t_pre, t_eval)` triples over the `groups × times` grid.
fn expand_gt_keyword(
  keyword : String,
  groups : Array[Int],
  times : Array[Int],
  anticipation_periods : Int,
) -> Array[(Int, Int, Int)] {
  let n_groups = groups.length()
  let n_periods = times.length()
  let out : Array[(Int, Int, Int)] = []
  let mut out_acc = out
  for i = 0; i < n_groups; i = i + 1 {
    let g = groups[i]
    for j = 0; j < n_periods; j = j + 1 {
      let t = times[j]
      // Skip pre-treatment cells relative to g, with
      // anticipation_periods leeway. For "standard", only emit
      // post-treatment cells (t > g - anticipation_periods) and
      // also require t_pre = g (the canonical Callaway-Sant'Anna
      // pre-treatment baseline). For "all" / "universal", emit
      // every (g, t) cell, including pre-treatment. The strict
      // `t > g - anticipation_periods` ensures t_eval > t_pre
      // (i.e. the cell is a real post-treatment period).
      if keyword == "standard" {
        if t > g - anticipation_periods {
          out_acc = out_acc + [(g, g, t)]
        }
      } else {
        // "all" or "universal": emit every (g, t) cell.
        if t > g - anticipation_periods {
          out_acc = out_acc + [(g, g, t)]
        }
      }
    }
  }
  // Deduplicate (the same triple may appear in the inner loop
  // for different groups only if `g` and `t_pre` both vary; in
  // practice `t_pre = g` so the dedupe is a no-op, but keep it
  // for safety).
  let seen : Array[(Int, Int, Int)] = []
  let mut seen_acc = seen
  let dedup : Array[(Int, Int, Int)] = []
  let mut dedup_acc = dedup
  for i = 0; i < out_acc.length(); i = i + 1 {
    let triple = out_acc[i]
    let mut found = false
    for j = 0; j < seen_acc.length(); j = j + 1 {
      let (ga, tpa, te) = seen_acc[j]
      let (gb, tpb, tf) = triple
      if ga == gb && tpa == tpb && te == tf {
        found = true
      }
    }
    if !found {
      seen_acc = seen_acc + [triple]
      dedup_acc = dedup_acc + [triple]
    }
  }
  dedup_acc
}

///|
/// Number of `(g, t_pre, t_eval)` triples.
pub fn DoubleMLDIDMulti::n_combinations(self : DoubleMLDIDMulti) -> Int {
  self.gt_combinations.length()
}

///|
/// The inner per-(g, t) ATT at row-major index `idx` (matching
/// the canonical `gt_combinations[i]` ordering).
pub fn DoubleMLDIDMulti::coef_at_idx(self : DoubleMLDIDMulti, idx : Int) -> Double {
  require(self.fitted)
  require(idx >= 0 && idx < self.gt_combinations.length())
  let (g, t_pre, t_eval) = self.gt_combinations[idx]
  // Locate (gi, pi) in the inner per-(g, t) matrix.
  let mut gi = -1
  let mut pi = -1
  for i = 0; i < self.inner.n_groups(); i = i + 1 {
    if self.inner.group_at(i) == g {
      gi = i
    }
  }
  for i = 0; i < self.inner.n_periods(); i = i + 1 {
    if self.inner.period_at(i) == t_eval {
      pi = i
    }
  }
  require(gi >= 0 && pi >= 0)
  ignore(t_pre)
  self.inner.coef_at(gi, pi)
}

///|
/// The inner per-(g, t) SE at row-major index `idx`.
pub fn DoubleMLDIDMulti::se_at_idx(self : DoubleMLDIDMulti, idx : Int) -> Double {
  require(self.fitted)
  let (g, t_pre, t_eval) = self.gt_combinations[idx]
  let mut gi = -1
  let mut pi = -1
  for i = 0; i < self.inner.n_groups(); i = i + 1 {
    if self.inner.group_at(i) == g {
      gi = i
    }
  }
  for i = 0; i < self.inner.n_periods(); i = i + 1 {
    if self.inner.period_at(i) == t_eval {
      pi = i
    }
  }
  require(gi >= 0 && pi >= 0)
  ignore(t_pre)
  self.inner.se_at(gi, pi)
}

///|
/// Run the per-(g, t) cross-fits and store the per-cell ATT
/// matrix for downstream aggregation. The actual per-cell
/// fitting is delegated to `DoubleMLDIDCS::fit`, which already
/// iterates over every (g, t) cell.
pub fn DoubleMLDIDMulti::fit(self : DoubleMLDIDMulti) -> DoubleMLDIDMulti {
  let inner = self.inner.fit()
  { ..self, inner, fitted: true }
}

///|
/// Aggregate by group. Returns a `DIDAggregationResult` with one
/// entry per group.
pub fn DoubleMLDIDMulti::aggregate_group(
  self : DoubleMLDIDMulti,
) -> DIDAggregationResult {
  require(self.fitted)
  aggregate_group(
    self.inner.coef_matrix,
    self.inner.se_matrix,
    self.data.groups,
    self.data.times,
    self.group_sizes,
  )
}

///|
/// Aggregate by time period. Returns a `DIDAggregationResult`
/// with one entry per period.
pub fn DoubleMLDIDMulti::aggregate_time(
  self : DoubleMLDIDMulti,
) -> DIDAggregationResult {
  require(self.fitted)
  aggregate_time(
    self.inner.coef_matrix,
    self.inner.se_matrix,
    self.data.groups,
    self.data.times,
    self.group_sizes,
  )
}

///|
/// Aggregate by event time `e = t - g`. Returns a
/// `DIDAggregationResult` with one entry per unique event time.
pub fn DoubleMLDIDMulti::aggregate_event(
  self : DoubleMLDIDMulti,
) -> DIDAggregationResult {
  require(self.fitted)
  aggregate_event(
    self.inner.coef_matrix,
    self.inner.se_matrix,
    self.data.groups,
    self.data.times,
    self.group_sizes,
  )
}
