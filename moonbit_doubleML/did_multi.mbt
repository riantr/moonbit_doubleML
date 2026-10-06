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
  // v0.60.0+: injected nuisance learners (forwarded to the
  // inner `DoubleMLDIDCS` -> `DoubleMLDIDBinary` -> `DoubleMLDID`
  // chain via `inner.fit(ml_g, ml_m)`).
  ml_g : LearnerDispatch
  ml_m : LearnerDispatch
  // Per-unit group sizes for aggregation weights. Filled in
  // `fit` from the data.
  group_sizes : Array[Int]
  // The inner per-(g, t) estimator.
  inner : DoubleMLDIDCS
  // v0.15.0+: bootstrap state. `boot_t_stat` is a
  // `n_rep_boot * n_thetas` row-major array of t-statistics
  // computed from the multiplier bootstrap. `boot_method` is
  // the multiplier distribution ("Bayes" / "normal" / "wild").
  // `n_rep_boot` is the bootstrap replication count. Empty
  // until `bootstrap()` is called.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  // v0.15.0+: bootstrap RNG seed. `bootstrap` accepts an
  // optional `seed` argument; the default is `2024`.
  boot_seed : Int
  fitted : Bool
  // v0.82.0+: memoization flag. The wrapper's `fit()` forwards
  // this flag to the inner `DoubleMLDIDCS` so the aggregated
  // cross-fits honour `.enable_memoize()` uniformly.
  memoize_enabled : Bool
} derive(Debug)

///|
pub extend DoubleMLDIDMulti with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Construct a `DoubleMLDIDMulti`.
///
/// `gt_combinations` may be either an `Array[(Int, Int, Int)]` of
/// explicit `(g_value, t_value_pre, t_value_eval)` triples, or
/// one of the keywords:
///
///   - `"standard"`: every (g, t) with `t > g` and `t_pre = g`
///     (the default Callaway-Sant'Anna staggered set).
///   - `"all"`: every (g, t) in the (groups x periods) grid.
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
  ml_g? : LearnerDispatch = LearnerDispatch::linear_regression(),
  ml_m? : LearnerDispatch = LearnerDispatch::linear_regression(),
) -> DoubleMLDIDMulti {
  try {
    require(n_folds >= 2)
    require(n_rep >= 1)
    require(anticipation_periods >= 0)
    require(
      control_group == "never_treated" || control_group == "not_yet_treated",
    )
    let n_groups = data.groups.length()
    let n_periods = data.times.length()
    // Resolve `gt_combinations`: explicit list wins, otherwise
    // expand the keyword.
    let resolved = if gt_combinations.length() > 0 {
      gt_combinations
    } else {
      expand_gt_keyword(
        gt_combinations_keyword,
        data.groups,
        data.times,
        anticipation_periods,
      )
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
      // Note: for "standard", `t_eval > t_pre` is
      // enforced by the keyword expansion. For
      // "all" / "universal", `t_eval < t_pre`
      // (pre-treatment placebo) is explicitly
      // allowed.
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
      ml_g,
      ml_m,
      group_sizes,
      inner,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 2024,
      fitted: false,
      // v0.82.0+: default memoize off.
      memoize_enabled: false,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Expand the `gt_combinations_keyword` string to a list of
/// `(g, t_pre, t_eval)` triples over the `groups x times` grid.
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
    // Skip the never-treated group (g == 0) -- these
    // units never receive treatment, so ATT(g, t)
    // is undefined for them. Upstream's
    // `_construct_gt_combinations` filters these
    // out via `_is_never_treated(g_values,
    // never_treated_value=0)`.
    if g == 0 {
      continue
    }
    for j = 0; j < n_periods; j = j + 1 {
      let t = times[j]
      // For "standard", only emit post-treatment
      // cells (t > g - anticipation_periods, with
      // the canonical baseline t_pre = g). For
      // "all" / "universal", emit every (g, t) cell
      // except the baseline t = g (identically zero
      // by construction). The pre-treatment cells
      // t < g are placebos for the parallel trends
      // assumption.
      if keyword == "standard" {
        if t > g - anticipation_periods && t > g {
          out_acc = out_acc + [(g, g, t)]
        }
        // "all" or "universal".
      } else if t != g {
        out_acc = out_acc + [(g, g, t)]
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

///|
/// Accessor for the outcome-nuisance learner forwarded to the
/// inner `DoubleMLDIDCS` on the most recent `fit(...)` call.
/// v0.60.0+.
pub fn DoubleMLDIDMulti::learner_g(self : DoubleMLDIDMulti) -> LearnerDispatch {
  self.ml_g
}

///|
/// Accessor for the propensity-score learner forwarded to the
/// inner `DoubleMLDIDCS` on the most recent `fit(...)` call.
/// v0.60.0+.
pub fn DoubleMLDIDMulti::learner_m(self : DoubleMLDIDMulti) -> LearnerDispatch {
  self.ml_m
}

///|
/// The inner per-(g, t) ATT at row-major index `idx` (matching
/// the canonical `gt_combinations[i]` ordering).
pub fn DoubleMLDIDMulti::coef_at_idx(
  self : DoubleMLDIDMulti,
  idx : Int,
) -> Double {
  try {
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
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// The inner per-(g, t) SE at row-major index `idx`.
pub fn DoubleMLDIDMulti::se_at_idx(
  self : DoubleMLDIDMulti,
  idx : Int,
) -> Double {
  try {
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
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.100.0+: the inner `(group_idx, period_idx)` that
/// `gt_combinations[idx]` selects, by the same linear scan
/// `coef_at_idx` and `se_at_idx` perform: read the triple
/// `(g, t_pre, t_eval)`, scan `inner.group_at(i)` for `gi` and
/// `inner.period_at(i)` for the index of `t_eval`. `t_pre` is
/// ignored here exactly as it is there -- the inner is keyed by
/// `(g, t_eval)` only, and `t_pre` is fixed at `g` by every
/// keyword expansion.
///
/// This is a NEW private helper for the v0.100.0 sandwich
/// accessors. It deliberately does NOT replace the inline scan in
/// `coef_at_idx` / `se_at_idx`: those two are byte-for-byte
/// unchanged, so nothing that already works can regress behind a
/// refactor. The scan is duplicated in three places rather than
/// extracted from two.
fn did_multi_inner_cell_at_idx(est : DoubleMLDIDMulti, idx : Int) -> (Int, Int) {
  try {
    let (g, t_pre, t_eval) = est.gt_combinations[idx]
    let mut gi = -1
    let mut pi = -1
    for i = 0; i < est.inner.n_groups(); i = i + 1 {
      if est.inner.group_at(i) == g {
        gi = i
      }
    }
    for i = 0; i < est.inner.n_periods(); i = i + 1 {
      if est.inner.period_at(i) == t_eval {
        pi = i
      }
    }
    require(gi >= 0 && pi >= 0)
    ignore(t_pre)
    (gi, pi)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.100.0+: heteroskedasticity-consistent (Huber-White) sandwich
/// standard error for the combination at row-major index `idx`
/// (the same `(g, t_pre, t_eval)` triple ordering as `coef_at_idx`
/// and `se_at_idx`). The per-cell analogue of the DID family's
/// joint `sandwich_se`: this wrapper estimates no scalar of its own,
/// so the natural index is the one it already exposes, the
/// combination index.
///
/// `DoubleMLDIDMulti` persists NO per-cell score state -- only
/// `group_sizes` and `boot_t_stat` -- so this method is a pure
/// FORWARD. The triple is mapped to the inner `(gi, pi)` and the
/// answer is `self.inner.sandwich_se_at(gi, pi, kind)` returned
/// unchanged, with no arithmetic in between. Hence
///
///     sandwich_se_at_idx(idx, kind) ==
///       inner.sandwich_se_at(gi, pi, kind)
///
/// bit for bit, and on the IID path
///
///     sandwich_se_at_idx(idx, HC0) == se_at_idx(idx)
///
/// holds for the reason it holds one level down: the inner's HC0 was
/// MEASURED equal to its own `se_at` on every non-degenerate cell
/// (abs_diff exactly `0.0`), because `var_est` and
/// `sandwich_variance_hc0` run the same op sequence over the same
/// Kahan sum of the same products in the same index order and
/// `M_inv[0, 0]^2 == 1.0` exactly (the DID score's
/// `psi_a[i] = -d[i] / p_hat` with `p_hat = mean(d)` gives
/// `mean(psi_a) == -1`). The wrapper adds no `n_params` and no
/// second estimate, so nothing about that identity is disturbed
/// here.
///
/// The one thing the wrapper does add is COVERAGE. `gt_combinations`
/// may name a combination the inner never estimated: `"all"` and
/// `"universal"` emit the pre-treatment placebos
/// `(g, t_pre = g, t_eval < g)`, and the CS-DID fit only estimates
/// `t_eval > g`, so those map to an EMPTY inner cell. There this
/// method ABORTS, by forwarding the inner's refusal: the inner
/// rejects an unestimated cell rather than return a misleading
/// `0.0` off an empty score row. That is not smoothed over. A
/// caller sweeping every index must skip the degenerate
/// combinations itself, exactly as it must for the inner API -- and
/// `se_at_idx` at the same index returns `0.0` rather than
/// aborting, so the two accessors are NOT interchangeable over a
/// full sweep.
///
/// Preconditions: `self.fitted`,
/// `0 <= idx < gt_combinations.length()`, `gt_combinations[idx]`
/// maps to an inner `(gi, pi)`, that cell was actually estimated,
/// `mean(psi_a) != 0`, and `n_obs > n_params` for HC1 / HC2 / HC3.
pub fn DoubleMLDIDMulti::sandwich_se_at_idx(
  self : DoubleMLDIDMulti,
  idx : Int,
  kind : SandwichKind,
) -> Double {
  try {
    require(self.fitted)
    require(idx >= 0 && idx < self.gt_combinations.length())
    let (gi, pi) = did_multi_inner_cell_at_idx(self, idx)
    self.inner.sandwich_se_at(gi, pi, kind)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.100.0+: cluster-robust sandwich standard error (Arellano
/// 1987, Cameron-Gelbach-Miller 2011) for the combination at
/// row-major index `idx`. Same pure forward as
/// `sandwich_se_at_idx`: the inner cell is resolved and
/// `self.inner.cluster_sandwich_se_at(gi, pi, cluster_ids)` is
/// returned unchanged.
///
/// `DoubleMLDIDCSData` has no `cluster_vars` field, so there is
/// still no default cluster and the caller must supply
/// `cluster_ids`. They are PER CELL ROW, not per long-format panel
/// row: `cluster_ids.length()` must equal THAT cell's `n_wide`, i.e.
/// one entry per unit observed in both the pre and the eval period.
/// The long-format panel `id` (length `n_units * n_periods`) is the
/// WRONG array to pass for a cell whose `n_wide` is smaller, and
/// because the mapping is per index, an `idx`-independent array of
/// the wrong length fails at whichever index it is passed to. For a
/// DID the natural grouping is the panel unit.
///
/// Why this is not `se_at_idx` with a different flavour: the
/// difference is the MEAT, not the denominator.
/// `cluster_sandwich_variance` divides by the cell's own `n_wide`
/// -- the same divisor HC0 uses -- but sums `S_c = (sum_{i in c}
/// psi[i])^2` per cluster, so the within-cluster cross terms enter
/// and each cluster carries a jackknife factor `n_c / (n_c - 1)`.
/// With all-singleton clusters the meat collapses to `sum_i
/// psi[i]^2` and the result is exactly
/// `sandwich_se_at_idx(idx, HC0)`; with real clusters it is larger.
/// (It is also not a drop-in for a cluster-robust `se_at`: that is a
/// different, row-level estimator which this DIDCS fit path does not
/// compute.)
///
/// Aborts at a degenerate combination for the same reason
/// `sandwich_se_at_idx` does -- the inner refuses an unestimated
/// cell, and the wrapper forwards that rather than papering over it.
///
/// Preconditions: `self.fitted`,
/// `0 <= idx < gt_combinations.length()`, the combination maps to
/// an estimated inner cell with `mean(psi_a) != 0`,
/// `cluster_ids.length() == n_wide`, all `cluster_ids[i] >= 0`.
pub fn DoubleMLDIDMulti::cluster_sandwich_se_at_idx(
  self : DoubleMLDIDMulti,
  idx : Int,
  cluster_ids : Array[Int],
) -> Double {
  try {
    require(self.fitted)
    require(idx >= 0 && idx < self.gt_combinations.length())
    let (gi, pi) = did_multi_inner_cell_at_idx(self, idx)
    self.inner.cluster_sandwich_se_at(gi, pi, cluster_ids)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.100.0+: `coef_at_idx(idx)` UNCHANGED -- a documented no-op,
/// not a bias correction. Identical in reasoning to
/// `DoubleMLDIDCS::bias_corrected_coef_at` and the rest of the
/// family; see `DoubleMLPQ::bias_corrected_coef` in `sandwich.mbt`
/// for the full argument. The child's ATT is the root of the DML
/// moment `f(theta) = E[theta * psi_a + psi_b]`, so
/// `mean(f(coef_at))` is identically zero: the estimating function is
/// orthogonal by construction, and that orthogonality is exactly
/// what makes the estimator consistent. Nothing computable from the
/// fitted scores is a bias estimate for this class of estimator, so
/// this accessor reports the uncorrected point estimate rather than
/// a number that merely looks like a correction. The pre-v0.91.0
/// form `coef + mean(psi_b - coef * psi_a)` is that vector at
/// `-coef`, NOT at `coef`; with `coef = -mean_b / mean_a` its mean
/// is `-2 * coef * mean(psi_a)`, so it returned
/// `coef * (1 - 2 * mean(psi_a))` -- exactly `3 * coef` when
/// `mean(psi_a) = -1`, which is this score's case for every cell.
///
/// A genuine difference from `sandwich_se_at_idx`: a DEGENERATE
/// combination does NOT abort here. The answer is the identity on
/// `coef_at_idx`, and `coef_at_idx` reports `0.0` for an
/// unestimated cell, so `0.0` is the consistent answer rather than
/// a misleading one. `0.0` is also why this accessor is safe to
/// call across a full sweep while the sandwich pair is not.
///
/// Preconditions: `self.fitted`,
/// `0 <= idx < gt_combinations.length()`, and `gt_combinations[idx]`
/// maps to an inner `(gi, pi)`.
pub fn DoubleMLDIDMulti::bias_corrected_coef_at_idx(
  self : DoubleMLDIDMulti,
  idx : Int,
) -> Double {
  try {
    require(self.fitted)
    require(idx >= 0 && idx < self.gt_combinations.length())
    let (gi, pi) = did_multi_inner_cell_at_idx(self, idx)
    self.inner.bias_corrected_coef_at(gi, pi)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.82.0+: turn on memoization for subsequent `fit()` calls.
/// The flag is forwarded to the inner `DoubleMLDIDCS`.
pub fn DoubleMLDIDMulti::enable_memoize(
  self : DoubleMLDIDMulti,
) -> DoubleMLDIDMulti {
  { ..self, memoize_enabled: true, }
}

///|
/// v0.82.0+: turn off memoization.
pub fn DoubleMLDIDMulti::disable_memoize(
  self : DoubleMLDIDMulti,
) -> DoubleMLDIDMulti {
  { ..self, memoize_enabled: false, }
}

///|
/// v0.82.0+: drop any cached nuisance predictions. No-op on
/// an un-fit wrapper.
pub fn DoubleMLDIDMulti::clear_cache(
  self : DoubleMLDIDMulti,
) -> DoubleMLDIDMulti {
  self
}

///|
/// v0.82.0+: `true` iff the memoize flag is set.
pub fn DoubleMLDIDMulti::has_cache(self : DoubleMLDIDMulti) -> Bool {
  self.memoize_enabled
}

///|
/// Run the per-(g, t) cross-fits and store the per-cell ATT
/// matrix for downstream aggregation. The actual per-cell
/// fitting is delegated to `DoubleMLDIDCS::fit`, which already
/// iterates over every (g, t) cell.
pub fn DoubleMLDIDMulti::fit(
  self : DoubleMLDIDMulti,
  ml_g? : LearnerDispatch = self.ml_g,
  ml_m? : LearnerDispatch = self.ml_m,
) -> DoubleMLDIDMulti {
  let inner_pre = self.inner.fit(ml_g~, ml_m~)
  // v0.82.0+: forward the memoize flag to the inner
  // DoubleMLDIDCS so the wrapper honours the cache uniformly.
  let inner_memo = if self.memoize_enabled {
    inner_pre.enable_memoize()
  } else {
    inner_pre
  }
  let inner = inner_memo.fit(ml_g~, ml_m~)
  { ..self, inner, ml_g, ml_m, fitted: true, }
}

///|
/// `DoubleMLDIDMulti::tune` - score a grid of `(learner_g,
/// learner_m)` pairs and re-fit the per-cell DID model with the
/// winner.
///
/// Slot semantics: propensity-first family, same as
/// `DoubleMLDIDCrossSection::tune` and the other `DID*`
/// estimators. The first `TuneParam` slot is the treatment /
/// propensity learner, the second is the outcome learner, and the
/// first field is still named `learner_l` because the field names
/// are fixed by the partially-linear family. Use
/// `TuneParam::for_treatment(learner_g, learner_m)` so the call
/// site states the slot's role.
///
/// v0.108.0: new. `DIDMulti` had no `tune` at all, so it was one
/// of the estimators carrying a coverage gap against upstream,
/// where `tune` reaches every estimator through the `BaseDML`
/// mixin. It routes through the shared `tune_score_grid` core in
/// `tune.mbt`, same as every other `::tune`.
///
/// What `tune` forwards, and what it does NOT touch:
///
///   - Forwarded: `ml_g` / `ml_m` from the winning
///     `TuneParam`, i.e. the first two arguments of `fit`.
///   - Carried over from `self` implicitly: everything else,
///     because `DoubleMLDIDMulti::fit` takes ONLY `ml_g` and
///     `ml_m` and rebuilds the model with `{ ..self, inner,
///     ml_g, ml_m, fitted: true }`. In particular the per-`(g,
///     t)` cell grid survives untouched: `gt_combinations` (and
///     its `gt_combinations_keyword` spelling) is a
///     `DoubleMLDIDMulti::new` argument, NOT a `fit` argument, so
///     there is no cell list for `tune` to plumb through and no
///     way for it to silently narrow the cell set. The fold
///     schedule, `n_rep` / `seed` and the memoize flag likewise
///     never appear in the `tune` -> `fit` call: the memoize
///     forwarding and the two-stage inner refit (pre- and
///     post-memoize) are `fit`'s own business.
///   - Dropped: nothing. The only state the tune stage produces
///     is the fold draw and the candidate scores, and those are
///     discarded by design - the winner is re-cross-fitted from
///     scratch under the final-fit fold schedule rather than
///     reusing the tune-time predictions.
///
/// Same scoring caveat as the sibling: the score is MSE of the
/// first-slot learner cross-fitted against the outcome `y`, not
/// against `d`, so it is a shortlisting proxy rather than a
/// per-cell nuisance optimum.
///
/// No cluster guard, deliberately: `DoubleMLDIDCSData` has no
/// `cluster_vars` field and no `is_cluster_data()` method, so
/// there is nothing to guard and the call would not compile. The
/// data type's `id` field is a panel unit id used for
/// aggregation, not a cluster-var accessor.
pub fn DoubleMLDIDMulti::tune(
  self : DoubleMLDIDMulti,
  param_set~ : Array[TuneParam],
  scoring_method? : String = "MSE",
  n_folds_tune? : Int = 5,
  seed? : Int = 3141,
) -> DoubleMLDIDMulti {
  try {
    require(param_set.length() > 0)
    require(n_folds_tune >= 2)
    let scoring = TuneScoring::parse(scoring_method)
    let grid = tune_score_grid(
      self.data.x,
      self.data.y,
      param_set.map(fn(p : TuneParam) { p.learner_l }),
      n_folds_tune,
      seed,
      scoring,
    )
    let best_param = param_set[grid.best_index]
    self.fit(ml_g=best_param.learner_l, ml_m=best_param.learner_m)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.15.0+: multiplier bootstrap for joint confidence
/// intervals. Draws `n_rep_boot` weight vectors from the
/// chosen multiplier distribution and computes
/// `boot_t_stat[b, k] = sum_i w[b, i] * psi_k[i] / (sqrt(n) *
/// se_k)` for each bootstrap replication `b` and each
/// `(g, t)` cell `k`. The joint confidence interval uses
/// the empirical 95th percentile of `max_k |boot_t_stat[b, k]|`
/// as the critical value; the per-cell Wald CI uses 1.96.
///
/// `method_name` selects the multiplier distribution:
///   - `"normal"`: `w[i] ~ N(0, 1)` (default; matches the
///     upstream `bootstrap(method="normal")` default).
///   - `"Bayes"`: `w[i] = exp(1) - 1` (mean 0, var 1).
///   - `"wild"`: `w[i] = x[i] / sqrt(2) + (y[i]^2 - 1) / 2`
///     with `x, y ~ N(0, 1)`. Robust to heteroskedasticity.
///
/// `seed` controls the chacha8 RNG used to draw the weights
/// (default `2024`; matches the upstream numpy default of
/// `np.random.seed(2024)` for the first test in
/// `_verify/test_bootstrap_reference.py`).
///
/// The bootstrap populates `self.boot_t_stat` and is required
/// for `confint(joint=true)`.
pub fn DoubleMLDIDMulti::bootstrap(
  self : DoubleMLDIDMulti,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLDIDMulti {
  try {
    require(self.fitted)
    require(
      method_name == "normal" || method_name == "Bayes" || method_name == "wild",
    )
    require(n_rep_boot >= 2)
    let n_obs = self.data.y.length()
    let n_thetas = self.gt_combinations.length()
    let n_groups = self.inner.n_groups()
    let n_periods = self.inner.n_periods()
    // Draw weights. Shape: (n_rep_boot, n_obs). v0.37.0:
    // draw_bootstrap_weights raises BootstrapMethodError on an
    // unknown method; catch and re-abort to preserve pre-v0.37.0
    // process-death behavior. Note: bootstrap() itself also has
    // a require() check that catches invalid methods first; the
    // catch below only fires if a caller invokes bootstrap with a
    // method that passes require() but doesn't reach the match
    // (currently impossible because the require and match sets
    // are aligned; kept as defense-in-depth).
    let weights = draw_bootstrap_weights(method_name, n_rep_boot, n_obs, seed) catch {
      BootstrapMethodError::UnknownMethod(m) =>
        abort(
          "draw_bootstrap_weights: unknown method (set in DoubleMLDIDMulti::bootstrap): " +
          m,
        )
    }
    // v0.55.0: refactored to call `did_bootstrap_t_stat` from
    // `bootstrap.mbt`. The helper takes a flat `[n_thetas,
    // n_obs]` psi matrix; we materialise it here by locating
    // each (gi, pi) in the inner `psi_matrix` (long-format
    // panel indexed as `psi_matrix[(gi * n_periods + pi) *
    // n_obs + i_long]`).
    let psi_flat : Array[Double] = Array::make(n_thetas * n_obs, 0.0)
    let se_flat : Array[Double] = Array::make(n_thetas, 0.0)
    for k = 0; k < n_thetas; k = k + 1 {
      let (g, _t_pre, t_eval) = self.gt_combinations[k]
      let mut gi = -1
      let mut pi = -1
      for i = 0; i < n_groups; i = i + 1 {
        if self.inner.group_at(i) == g {
          gi = i
        }
      }
      for i = 0; i < n_periods; i = i + 1 {
        if self.inner.period_at(i) == t_eval {
          pi = i
        }
      }
      if gi < 0 || pi < 0 {
        continue
      }
      let flat = gi * n_periods + pi
      se_flat[k] = self.inner.se_matrix[flat]
      // Copy row `flat` of `psi_matrix` into row `k` of `psi_flat`.
      // Skip if se = 0 (empty / pre-treatment cell); the helper
      // also skips those and writes 0 into boot_t_stat.
      if se_flat[k] == 0.0 {
        continue
      }
      for i_long = 0; i_long < n_obs; i_long = i_long + 1 {
        psi_flat[k * n_obs + i_long] = self.inner.psi_matrix[flat * n_obs +
          i_long]
      }
    }
    let boot_t_stat = did_bootstrap_t_stat(
      weights, psi_flat, se_flat, n_rep_boot, n_obs, n_thetas,
    )
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
/// v0.16.0+: per-cell t-statistics `theta / se` (length
/// `n_combinations`). The Wald-style t-statistic matches
/// the upstream `all_t_stats[:, i_rep]` (per repetition,
/// but v0.15.0 is `n_rep = 1` only). The Romano-Wolf
/// stepdown p-adjustment in `p_adjust` consumes these
/// t-statistics. Returns `0.0` for cells where `se_k = 0`
/// (pre-treatment / missing cells).
pub fn DoubleMLDIDMulti::t_stats(self : DoubleMLDIDMulti) -> Array[Double] {
  try {
    require(self.fitted)
    let n = self.gt_combinations.length()
    let out : Array[Double] = Array::make(n, 0.0)
    for k = 0; k < n; k = k + 1 {
      let theta = self.coef_at_idx(k)
      let se = self.se_at_idx(k)
      if se > 0.0 {
        out[k] = theta / se
      }
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.16.0+: per-cell unadjusted p-values for `H0:
/// theta = 0` (two-sided, normal approximation). Length
/// `n_combinations`. `pval[k] = 2 * (1 - norm.cdf(|t_k|))`.
/// Uses the standard-normal survival function on the
/// Wald-style t-statistics from `t_stats()`.
///
/// The implementation uses Abramowitz & Stegun (1964)
/// formula 7.1.26 for the normal CDF (max absolute error
/// ~7.5e-8). MoonBit's `@math` does not expose `erfc`, so
/// we approximate `norm.cdf` directly.
pub fn DoubleMLDIDMulti::p_values(self : DoubleMLDIDMulti) -> Array[Double] {
  try {
    require(self.fitted)
    let ts = self.t_stats()
    let n = ts.length()
    let out : Array[Double] = Array::make(n, 1.0)
    for k = 0; k < n; k = k + 1 {
      let t = ts[k]
      let abs_t = if t < 0.0 { -t } else { t }
      // `p = 2 * (1 - norm.cdf(abs_t))` using the A&S 7.1.26
      // approximation. The formula is
      // `norm.cdf(x) ~ 1 - phi(x) * (b1*t + b2*t^2 + b3*t^3
      //   + b4*t^4 + b5*t^5)` with `t = 1 / (1 + p*x)` and
      //   `phi(x) = exp(-x^2 / 2) / sqrt(2 pi)`.
      let p = 2.0 * norm_sf(abs_t)
      out[k] = if p > 1.0 { 1.0 } else { p }
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

// ---------------------------------------------------------------------------
// Internal: standard-normal survival function (A&S 7.1.26)
// ---------------------------------------------------------------------------

///|
/// Standard-normal survival function `P(Z > x)` using the
/// Abramowitz & Stegun (1964) formula 7.1.26 (max absolute
/// error ~7.5e-8 for `x >= 0`):
///
///   `sf(x) = phi(x) * (b1*t + b2*t^2 + b3*t^3
///              + b4*t^4 + b5*t^5)`
///   `phi(x) = exp(-x^2 / 2) / sqrt(2 pi)`
///   `t = 1 / (1 + p * x)`
///   `p = 0.2316419, b1 = 0.319381530, b2 = -0.356563782,
///    b3 = 1.781477937, b4 = -1.821255978, b5 = 1.330274429`
pub fn norm_sf(x : Double) -> Double {
  if x <= 0.0 {
    return 1.0
  }
  let p = 0.2316419
  let b1 = 0.319381530
  let b2 = -0.356563782
  let b3 = 1.781477937
  let b4 = -1.821255978
  let b5 = 1.330274429
  let t = 1.0 / (1.0 + p * x)
  let phi = @math.exp(-x * x / 2.0) / 2.5066282746310002
  let poly = t * (b1 + t * (b2 + t * (b3 + t * (b4 + t * b5))))
  let sf = phi * poly
  if sf > 1.0 {
    1.0
  } else if sf < 0.0 {
    0.0
  } else {
    sf
  }
}

///|
/// v0.16.0+: multiple-testing p-value adjustment for the
/// per-(g, t) ATTs. Returns an `Array[Double]` of adjusted
/// p-values (length `n_combinations`).
///
/// **Methods**:
///   - `"romano-wolf"` (default): the stepdown bootstrap
///     procedure from Romano & Wolf (2005). For each cell
///     `k`, sorted by descending `|t_k|`, compute
///     `p_k = mean_b [max_j > k |boot_t_stat[b, j]| >=
///     |t_k|]`. Then enforce monotonicity:
///     `p_corrected[k] = max(p_k, p_corrected[k - 1])` (in
///     sorted order). Requires `bootstrap()` to have been
///     called first.
///   - `"holm"`: Holm-Bonferroni stepdown (no bootstrap
///     required). Sort unadjusted p-values ascending; for
///     each `k`, `p_corrected[k] = max((n - k) * p_sorted[k],
///     p_corrected[k - 1])`, then re-sort to original order.
///   - `"bonferroni"`: `p_corrected[k] = n * p_k`, clipped
///     to `1.0`. No bootstrap required.
///
/// The p-values are computed from the Wald-style
/// t-statistics (`theta / se` per cell) via the
/// two-sided normal approximation.
pub fn DoubleMLDIDMulti::p_adjust(
  self : DoubleMLDIDMulti,
  method_name? : String = "romano-wolf",
) -> Array[Double] {
  try {
    require(self.fitted)
    require(
      method_name == "romano-wolf" ||
      method_name == "rw" ||
      method_name == "holm" ||
      method_name == "bonferroni" ||
      method_name == "bh" ||
      method_name == "by" ||
      method_name == "fdr_bh" ||
      method_name == "fdr_by" ||
      method_name == "tsbh" ||
      method_name == "tsby" ||
      method_name == "fdr_tsbh" ||
      method_name == "fdr_tsbky",
    )
    let n = self.gt_combinations.length()
    require(n > 0)
    let unadjusted = self.p_values()
    match method_name {
      "romano-wolf" | "rw" =>
        romano_wolf_p_adjust(self.boot_t_stat, unadjusted, self.t_stats())
      "holm" => holm_bonferroni_p_adjust(unadjusted)
      "bonferroni" => bonferroni_p_adjust(unadjusted)
      "bh" | "fdr_bh" => bh_fdr_p_adjust(unadjusted)
      "by" | "fdr_by" => by_fdr_p_adjust(unadjusted)
      "tsbh" | "fdr_tsbh" => tsbh_p_adjust(unadjusted)
      "tsby" | "fdr_tsbky" => tsby_p_adjust(unadjusted)
      _ =>
        // v0.46.0: dead-code abort. The `require` above (lines
        // 548-561) covers all 11 valid method names, and the
        // match covers exactly the same set. The `_ =>` arm
        // here is therefore unreachable through the public
        // API: the `require` aborts first if a caller passes
        // an unknown method. v0.46.0 marks this explicitly
        // and improves the abort message to be more
        // descriptive (mentions `DoubleMLDIDMulti::p_adjust`
        // as the expected configuration site) so the
        // diagnostic is actionable if the abort ever fires.
        //
        // Same dead-code pattern as v0.37.0's
        // `did_multi.mbt:558` (originally skipped with
        // documentation), v0.45.0's `plpr.mbt:447`
        // (`transform_panel` else-branch), and v0.42.0's
        // removed `solve_pq` lower-bracket dead abort.
        abort(
          "DoubleMLDIDMulti::p_adjust: unknown method (set in DoubleMLDIDMulti::p_adjust): " +
          method_name,
        )
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

// ---------------------------------------------------------------------------
// v0.54.0: p_adjust extraction
// ---------------------------------------------------------------------------
// The 7 p-adjust algorithms (romano_wolf / holm / bonferroni /
// bh / by / tsbh / tsby) were extracted from this file into
// `p_adjust.mbt` so they are reusable across all estimators
// (not just DIDMulti). `DoubleMLDIDMulti::p_adjust(method)` is
// still here as a thin wrapper that pre-computes `unadjusted`
// from `p_values()` and the bootstrap t-statistics, then
// delegates to the public dispatcher:
//
//   p_adjust(method, unadjusted, boot_t_stat?, t_stats?)
//
// The local function `argsort_asc` and `storey_m0_hat` were
// also moved. `DoubleMLDIDMulti::p_adjust` now only contains
// the estimator-specific wiring.

///|
/// v0.15.0+: confidence interval for the per-(g, t) ATT.
/// When `joint = false` (default), uses the Wald-style
/// `theta +/- 1.96 * se` interval. When `joint = true`, uses
/// the bootstrap: `theta +/- critical_value * se` where
/// `critical_value` is the 95th percentile of
/// `max_k |boot_t_stat[b, k]|` across bootstrap replications
/// `b`. Joint CIs are wider (more conservative) and require
/// `bootstrap()` to be called first.
///
/// `level` is the confidence level (default `0.95`).
pub fn DoubleMLDIDMulti::confint(
  self : DoubleMLDIDMulti,
  joint? : Bool = false,
  level? : Double = 0.95,
) -> Array[(Double, Double)] {
  try {
    require(self.fitted)
    require(level > 0.0 && level < 1.0)
    let n_thetas = self.gt_combinations.length()
    let z_975 = 1.959963984540054 // `norm.ppf(0.975)`
    let out : Array[(Double, Double)] = []
    let mut out_acc = out
    if joint {
      require(self.boot_t_stat.length() > 0)
      require(self.boot_method != "" && self.n_rep_boot > 0)
      // Compute the empirical quantile of `max_k |boot_t_stat|`.
      let max_abs : Array[Double] = Array::make(self.n_rep_boot, 0.0)
      for b = 0; b < self.n_rep_boot; b = b + 1 {
        let mut m = 0.0
        for k = 0; k < n_thetas; k = k + 1 {
          let v = self.boot_t_stat[b * n_thetas + k]
          let av = if v < 0.0 { -v } else { v }
          if av > m {
            m = av
          }
        }
        max_abs[b] = m
      }
      // `Array::sort` is in-place. `max_abs` is a fresh array, but
      // the values may be tied. `sort` is not stable in this
      // MoonBit build; for the empirical quantile, ties don't
      // matter (we just need the sorted order).
      max_abs.sort()
      let idx = (level * self.n_rep_boot.to_double()).to_int()
      let idx_clamped = if idx >= self.n_rep_boot {
        self.n_rep_boot - 1
      } else {
        idx
      }
      let critical_value = max_abs[idx_clamped]
      for k = 0; k < n_thetas; k = k + 1 {
        let _ = self.gt_combinations[k]
        let theta = self.coef_at_idx(k)
        let se = self.se_at_idx(k)
        let lo = theta - critical_value * se
        let hi = theta + critical_value * se
        out_acc = out_acc + [(lo, hi)]
      }
      ignore(z_975)
    } else {
      for k = 0; k < n_thetas; k = k + 1 {
        let theta = self.coef_at_idx(k)
        let se = self.se_at_idx(k)
        let lo = theta - z_975 * se
        let hi = theta + z_975 * se
        out_acc = out_acc + [(lo, hi)]
      }
    }
    out_acc
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

// ---------------------------------------------------------------------------
// Internal: multiplier bootstrap weight draw (pure MoonBit)
// ---------------------------------------------------------------------------

///|
/// Draw `n_rep_boot` weight vectors of length `n_obs` from
/// the chosen multiplier distribution. The chacha8 RNG is
/// seeded with `seed` for reproducibility.
///
/// Supported methods:
///   - `"normal"`: `w[i] ~ N(0, 1)` per the Box-Muller transform.
///   - `"Bayes"`: `w[i] = exp(1) - 1` (mean 0, var 1; uses the
///     chacha8-driven `rng.double()` for the uniform
///     quantile input to the inverse-CDF).
///   - `"wild"`: `w[i] = x[i] / sqrt(2) + (y[i]^2 - 1) / 2` with
///     `x, y ~ N(0, 1)`. The wild bootstrap is robust to
///     heteroskedasticity in the influence-function residuals.
///
/// Returns a row-major `Array[Double]` of length
/// `n_rep_boot * n_obs`. The first `n_obs` entries are the
/// first bootstrap replication's weights, the next `n_obs`
/// are the second replication, and so on.
///
/// Returns `Array[Double] raise BootstrapMethodError`: the v0.37.0
/// conversion replaces the previous `abort()` call with
/// `raise BootstrapMethodError::UnknownMethod(method_name)` so
/// the unknown-method path becomes directly testable. Callers
/// that want the pre-v0.37.0 process-death behavior should catch
/// the error and re-abort (this is what every prod caller does);
/// callers that want to surface the error to downstream
/// consumers should propagate via `?`. The error type is declared
/// in `kfold.mbt` so the cluster helper stack can share it.
pub fn draw_bootstrap_weights(
  method_name : String,
  n_rep_boot : Int,
  n_obs : Int,
  seed : Int,
) -> Array[Double] raise BootstrapMethodError {
  let out : Array[Double] = Array::make(n_rep_boot * n_obs, 0.0)
  let rng = chacha8_rng(seed)
  for b = 0; b < n_rep_boot; b = b + 1 {
    for i = 0; i < n_obs; i = i + 1 {
      let w = match method_name {
        "normal" => box_muller_normal(rng)
        "Bayes" => {
          // exp(1) - 1 via inverse-CDF on uniform.
          let u = rng.double()
          let safe = if u < 1.0e-12 { 1.0e-12 } else { u }
          -@math.ln(safe) - 1.0
        }
        "wild" => {
          let x = box_muller_normal(rng)
          let y = box_muller_normal(rng)
          x / 1.4142135623730951 + (y * y - 1.0) / 2.0
        }
        _ => raise BootstrapMethodError::UnknownMethod(method_name)
      }
      out[b * n_obs + i] = w
    }
  }
  out
}

///|
/// Standard normal sample via Box-Muller. Pairs `(u1, u2)` in
/// `[0, 1)` to `(z1, z2) ~ N(0, 1)`. The chacha8 RNG is
/// uniform in `[0, 1)` per the upstream `numpy.random`
/// default; we use the cosine for the first draw and the
/// sine for the second to consume two uniforms per pair.
pub fn box_muller_normal(rng : @random.Rand) -> Double {
  let u1 = rng.double()
  let u2 = rng.double()
  let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
  let r = (-2.0 * @math.ln(safe)).sqrt()
  let theta_ = 2.0 * 3.141592653589793 * u2
  r * @math.cos(theta_)
}

///|
/// Aggregate by group. Returns a `DIDAggregationResult` with one
/// entry per group.
pub fn DoubleMLDIDMulti::aggregate_group(
  self : DoubleMLDIDMulti,
) -> DIDAggregationResult {
  try {
    require(self.fitted)
    aggregate_group(
      self.inner.coef_matrix,
      self.inner.se_matrix,
      self.data.groups,
      self.data.times,
      self.group_sizes,
    )
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Aggregate by time period. Returns a `DIDAggregationResult`
/// with one entry per period.
pub fn DoubleMLDIDMulti::aggregate_time(
  self : DoubleMLDIDMulti,
) -> DIDAggregationResult {
  try {
    require(self.fitted)
    aggregate_time(
      self.inner.coef_matrix,
      self.inner.se_matrix,
      self.data.groups,
      self.data.times,
      self.group_sizes,
    )
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Aggregate by event time `e = t - g`. Returns a
/// `DIDAggregationResult` with one entry per unique event time.
pub fn DoubleMLDIDMulti::aggregate_event(
  self : DoubleMLDIDMulti,
) -> DIDAggregationResult {
  try {
    require(self.fitted)
    aggregate_event(
      self.inner.coef_matrix,
      self.inner.se_matrix,
      self.data.groups,
      self.data.times,
      self.group_sizes,
    )
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

// ---------------------------------------------------------------------------
// Sensitivity (v0.70.0+)
// ---------------------------------------------------------------------------

///|
/// v0.70.0+: per-(g, t) Cinelli & Hazlett (2020) omitted-variable
/// bias analysis for `DoubleMLDIDMulti`. Delegates to
/// `DoubleMLDIDCS::sensitivity_analysis` for the full
/// `n_groups * n_periods` per-cell `SensitivityResult` array,
/// then filters down to the cells selected by
/// `gt_combinations` (i.e. the same cells used by
/// `coef_at_idx` / `se_at_idx`).
///
/// Each selected (g, t) cell's result carries the
/// ATT-form residual `y - g_d0_hat - (g_d1_hat - g_d0_hat) *
/// d` on the long-format panel (persisted by
/// `DoubleMLDIDCS::fit` in `psi_a_matrix` /
/// `residuals_matrix`) and the matching per-cell Riesz
/// representer. Routes through the shared
/// `irm_style_sensitivity` helper (see sensitivity.mbt).
///
/// Cells with no fitted estimate (`se_matrix[k] <= 0`) return
/// a zeroed `SensitivityResult` from the inner pass; the
/// filtering preserves that contract.
///
/// Returns an `Array[SensitivityResult]` of length
/// `gt_combinations.length()`. Calling on an un-fit model
/// aborts via `PreconditionError`.
pub fn DoubleMLDIDMulti::sensitivity_analysis(
  self : DoubleMLDIDMulti,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> Array[SensitivityResult] raise {
  require(self.fitted)
  // Materialise the inner per-cell array once (length
  // `n_groups * n_periods`, row-major (gi, pi)) then walk
  // `gt_combinations` and pick the matching entries via
  // the same `(gi, pi)` lookup used by `coef_at_idx`.
  let all = self.inner.sensitivity_analysis(cf_y~, cf_d~)
  let n_groups = self.inner.n_groups()
  let n_periods = self.inner.n_periods()
  let n_combos = self.gt_combinations.length()
  let out : Array[SensitivityResult] = Array::make(n_combos, {
    rv: 0.0,
    sigma2: 0.0,
    nu2: 0.0,
    cf_y: 0.0,
    cf_d: 0.0,
    max_bias: 0.0,
  })
  for k = 0; k < n_combos; k = k + 1 {
    let (g, _t_pre, t_eval) = self.gt_combinations[k]
    let mut gi = -1
    let mut pi = -1
    for i = 0; i < n_groups; i = i + 1 {
      if self.inner.group_at(i) == g {
        gi = i
      }
    }
    for i = 0; i < n_periods; i = i + 1 {
      if self.inner.period_at(i) == t_eval {
        pi = i
      }
    }
    if gi < 0 || pi < 0 {
      continue
    }
    let flat = gi * n_periods + pi
    if flat >= 0 && flat < all.length() {
      out[k] = all[flat]
    }
  }
  out
}

///|
/// v0.73.0+: cluster-robust analogue of
/// `DoubleMLDIDMulti::sensitivity_analysis`. Delegates to
/// the inner `DoubleMLDIDCS::sensitivity_analysis_cluster`
/// (which carries the per-cell ATT-form residual and
/// per-cell `psi_a` from `psi_a_matrix` /
/// `residuals_matrix`) and then filters down to the
/// `gt_combinations` selected cells (same lookup as
/// `coef_at_idx` / `se_at_idx`).
///
/// `DoubleMLDIDMulti`'s data struct
/// (`DoubleMLDIDCSData`) has no `cluster_vars` field, so the
/// user must pass `cluster_ids` explicitly.
/// `cluster_ids.length()` must equal `self.data.n_obs()`
/// (the long-format panel length).
///
/// Cells with no fitted estimate
/// (`inner.se_matrix[k] <= 0`) return a zeroed
/// `SensitivityResult` from the inner pass; the filtering
/// preserves that contract.
///
/// Returns an `Array[SensitivityResult]` of length
/// `gt_combinations.length()`.
pub fn DoubleMLDIDMulti::sensitivity_analysis_cluster(
  self : DoubleMLDIDMulti,
  cluster_ids : Array[Int],
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> Array[SensitivityResult] raise {
  require(self.fitted)
  let all = self.inner.sensitivity_analysis_cluster(cluster_ids, cf_y~, cf_d~)
  let n_groups = self.inner.n_groups()
  let n_periods = self.inner.n_periods()
  let n_combos = self.gt_combinations.length()
  let out : Array[SensitivityResult] = Array::make(n_combos, {
    rv: 0.0,
    sigma2: 0.0,
    nu2: 0.0,
    cf_y: 0.0,
    cf_d: 0.0,
    max_bias: 0.0,
  })
  for k = 0; k < n_combos; k = k + 1 {
    let (g, _t_pre, t_eval) = self.gt_combinations[k]
    let mut gi = -1
    let mut pi = -1
    for i = 0; i < n_groups; i = i + 1 {
      if self.inner.group_at(i) == g {
        gi = i
      }
    }
    for i = 0; i < n_periods; i = i + 1 {
      if self.inner.period_at(i) == t_eval {
        pi = i
      }
    }
    if gi < 0 || pi < 0 {
      continue
    }
    let flat = gi * n_periods + pi
    if flat >= 0 && flat < all.length() {
      out[k] = all[flat]
    }
  }
  out
}
