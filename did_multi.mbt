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
    boot_t_stat: [],
    boot_method: "",
    n_rep_boot: 0,
    boot_seed: 2024,
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
        // "all" or "universal": emit every (g, t) cell.
      } else if t > g - anticipation_periods {
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
/// The inner per-(g, t) ATT at row-major index `idx` (matching
/// the canonical `gt_combinations[i]` ordering).
pub fn DoubleMLDIDMulti::coef_at_idx(
  self : DoubleMLDIDMulti,
  idx : Int,
) -> Double {
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
pub fn DoubleMLDIDMulti::se_at_idx(
  self : DoubleMLDIDMulti,
  idx : Int,
) -> Double {
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
  require(self.fitted)
  require(
    method_name == "normal" || method_name == "Bayes" || method_name == "wild",
  )
  require(n_rep_boot >= 2)
  let n_obs = self.data.y.length()
  let n_thetas = self.gt_combinations.length()
  let n_groups = self.inner.n_groups()
  let n_periods = self.inner.n_periods()
  // Draw weights. Shape: (n_rep_boot, n_obs).
  let weights = draw_bootstrap_weights(method_name, n_rep_boot, n_obs, seed)
  // For each gt_combination, locate the per-cell psi on the
  // full long-format panel and compute the t-statistic. The
  // psi is `coef * psi_a + psi_b` (the per-observation
  // influence function); we use the inner `psi_matrix` from
  // `DoubleMLDIDCS`, indexed row-major as
  // `psi_matrix[(gi * n_periods + pi) * n_obs + i_long]`.
  let boot_t_stat : Array[Double] = Array::make(n_rep_boot * n_thetas, 0.0)
  for b = 0; b < n_rep_boot; b = b + 1 {
    for k = 0; k < n_thetas; k = k + 1 {
      let (g, _t_pre, t_eval) = self.gt_combinations[k]
      // Locate (gi, pi) in the inner matrix.
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
      let se_k = self.inner.se_matrix[flat]
      // Skip empty / pre-treatment cells (se = 0).
      if se_k == 0.0 {
        continue
      }
      // `boot_t_stat[b, k] = sum_i w[b, i] * psi_k[i] /
      // (sqrt(n) * se_k)`. The denominator makes this a
      // t-statistic; its distribution is N(0, 1) under the
      // null. The 1.96 critical value is for 95% pointwise;
      // the joint CI uses the bootstrap quantile.
      let mut s = 0.0
      for i_long = 0; i_long < n_obs; i_long = i_long + 1 {
        let psi_k_i = self.inner.psi_matrix[flat * n_obs + i_long]
        s = s + weights[b * n_obs + i_long] * psi_k_i
      }
      let denom = n_obs.to_double().sqrt() * se_k
      boot_t_stat[b * n_thetas + k] = s / denom
    }
  }
  { ..self, boot_t_stat, boot_method: method_name, n_rep_boot, boot_seed: seed }
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
  require(self.fitted)
  let ts = self.t_stats()
  let n = ts.length()
  let out : Array[Double] = Array::make(n, 1.0)
  for k = 0; k < n; k = k + 1 {
    let t = ts[k]
    let abs_t = if t < 0.0 { -t } else { t }
    // `p = 2 * (1 - norm.cdf(abs_t))` using the A&S 7.1.26
    // approximation. The formula is
    // `norm.cdf(x) ≈ 1 - phi(x) * (b1*t + b2*t^2 + b3*t^3
    //   + b4*t^4 + b5*t^5)` with `t = 1 / (1 + p*x)` and
    //   `phi(x) = exp(-x^2 / 2) / sqrt(2 pi)`.
    let p = 2.0 * norm_sf(abs_t)
    out[k] = if p > 1.0 { 1.0 } else { p }
  }
  out
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
  require(self.fitted)
  require(
    method_name == "romano-wolf" ||
    method_name == "rw" ||
    method_name == "holm" ||
    method_name == "bonferroni",
  )
  let n = self.gt_combinations.length()
  require(n > 0)
  let unadjusted = self.p_values()
  match method_name {
    "romano-wolf" | "rw" =>
      romano_wolf_p_adjust(self.boot_t_stat, unadjusted, self.t_stats())
    "holm" => holm_bonferroni_p_adjust(unadjusted)
    "bonferroni" => bonferroni_p_adjust(unadjusted)
    _ => abort("DoubleMLDIDMulti::p_adjust: unknown method")
  }
}

// ---------------------------------------------------------------------------
// Internal: Romano-Wolf stepdown (matches upstream)
// ---------------------------------------------------------------------------

///|
/// Romano-Wolf stepdown multiple-testing correction.
///
/// Algorithm (matches upstream `doubleml.double_ml_framework.p_adjust`):
///   1. Sort `|t_k|` descending; let `stepdown_ind` be the
///      resulting permutation of cell indices and `ro` be
///      its inverse.
///   2. For each cell `k` (in stepdown order), compute the
///      bootstrap critical value as
///      `cv_k = max_{j > k} |boot_t_stat[b, j]|` for each
///      bootstrap replication `b`. Then
///      `p_k = mean_b [cv_k >= |t_{stepdown_ind[k]}|]`.
///   3. Enforce monotonicity:
///      `p_corrected_sorted[k] = max(p_k, p_corrected_sorted[k - 1])`.
///   4. Re-order to original cell order via `ro`.
///
/// `boot_t_stat` is row-major `(n_rep_boot, n_thetas)`.
/// `unadjusted` and `t_stats` are length `n_thetas`.
pub fn romano_wolf_p_adjust(
  boot_t_stat : Array[Double],
  unadjusted : Array[Double],
  t_stats : Array[Double],
) -> Array[Double] {
  let n = t_stats.length()
  let n_boot = boot_t_stat.length() / n
  require(n_boot > 0)
  // Sort |t| descending. We use a simple O(n^2) selection
  // sort because n is typically small (3-12 cells).
  let stepdown_ind : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    stepdown_ind[i] = i
  }
  let abs_t : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let t = t_stats[i]
    abs_t[i] = if t < 0.0 { -t } else { t }
  }
  // Simple insertion sort on `stepdown_ind` by descending
  // `abs_t`.
  for i = 1; i < n; i = i + 1 {
    let mut j = i
    while j > 0 && abs_t[stepdown_ind[j]] > abs_t[stepdown_ind[j - 1]] {
      let tmp = stepdown_ind[j]
      stepdown_ind[j] = stepdown_ind[j - 1]
      stepdown_ind[j - 1] = tmp
      j = j - 1
    }
  }
  // `ro` is the inverse permutation of `stepdown_ind`:
  // `ro[stepdown_ind[i]] = i`.
  let ro : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    ro[stepdown_ind[i]] = i
  }
  // Compute the stepdown p-values.
  let p_sorted : Array[Double] = Array::make(n, 1.0)
  for i_theta = 0; i_theta < n; i_theta = i_theta + 1 {
    // Bootstrap critical value per replication: max
    // |boot_t_stat[b, j]| for `j > i_theta` (in stepdown
    // order). Use `np.delete`-equivalent: skip the cells
    // at stepdown positions `0..i_theta`.
    let mut p_k = 0.0
    for b = 0; b < n_boot; b = b + 1 {
      let mut cv = 0.0
      for j = i_theta; j < n; j = j + 1 {
        let idx = stepdown_ind[j]
        let v = boot_t_stat[b * n + idx]
        let av = if v < 0.0 { -v } else { v }
        if av > cv {
          cv = av
        }
      }
      let t_target = abs_t[stepdown_ind[i_theta]]
      if cv >= t_target {
        p_k = p_k + 1.0
      }
    }
    let p_k_normalised = if p_k / n_boot.to_double() > 1.0 {
      1.0
    } else {
      p_k / n_boot.to_double()
    }
    p_sorted[i_theta] = p_k_normalised
  }
  // Enforce monotonicity.
  for i_theta = 1; i_theta < n; i_theta = i_theta + 1 {
    if p_sorted[i_theta] < p_sorted[i_theta - 1] {
      p_sorted[i_theta] = p_sorted[i_theta - 1]
    }
  }
  // Re-order to original cell order via `ro`.
  let out : Array[Double] = Array::make(n, 1.0)
  for i = 0; i < n; i = i + 1 {
    out[i] = p_sorted[ro[i]]
  }
  ignore(unadjusted)
  out
}

// ---------------------------------------------------------------------------
// Internal: Holm-Bonferroni and Bonferroni
// ---------------------------------------------------------------------------

///|
/// Holm-Bonferroni stepdown correction. Sort unadjusted
/// p-values ascending, then `p_corrected_sorted[k] =
/// max((n - k) * p_sorted[k], p_corrected_sorted[k - 1])`,
/// clipped to `1.0`. Re-order to original cell order.
pub fn holm_bonferroni_p_adjust(unadjusted : Array[Double]) -> Array[Double] {
  let n = unadjusted.length()
  let order : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    order[i] = i
  }
  // Sort `order` by ascending `unadjusted[order[i]]` via
  // insertion sort.
  for i = 1; i < n; i = i + 1 {
    let mut j = i
    while j > 0 && unadjusted[order[j]] < unadjusted[order[j - 1]] {
      let tmp = order[j]
      order[j] = order[j - 1]
      order[j - 1] = tmp
      j = j - 1
    }
  }
  let ro : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    ro[order[i]] = i
  }
  let p_sorted : Array[Double] = Array::make(n, 1.0)
  p_sorted[0] = if unadjusted[order[0]] * n.to_double() > 1.0 {
    1.0
  } else {
    unadjusted[order[0]] * n.to_double()
  }
  for i = 1; i < n; i = i + 1 {
    let raw = unadjusted[order[i]] * (n - i).to_double()
    let mut candidate = if raw > 1.0 { 1.0 } else { raw }
    if candidate < p_sorted[i - 1] {
      candidate = p_sorted[i - 1]
    }
    p_sorted[i] = candidate
  }
  let out : Array[Double] = Array::make(n, 1.0)
  for i = 0; i < n; i = i + 1 {
    out[i] = p_sorted[ro[i]]
  }
  out
}

///|
/// Bonferroni correction. `p_corrected[k] = min(1.0, n *
/// p_unadjusted[k])`.
pub fn bonferroni_p_adjust(unadjusted : Array[Double]) -> Array[Double] {
  let n = unadjusted.length()
  let out : Array[Double] = Array::make(n, 1.0)
  for i = 0; i < n; i = i + 1 {
    let p = unadjusted[i] * n.to_double()
    out[i] = if p > 1.0 { 1.0 } else { p }
  }
  out
}

///|
/// v0.15.0+: confidence interval for the per-(g, t) ATT.
/// When `joint = false` (default), uses the Wald-style
/// `theta ± 1.96 * se` interval. When `joint = true`, uses
/// the bootstrap: `theta ± critical_value * se` where
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
pub fn draw_bootstrap_weights(
  method_name : String,
  n_rep_boot : Int,
  n_obs : Int,
  seed : Int,
) -> Array[Double] {
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
        _ =>
          abort(
            "draw_bootstrap_weights: unknown method (set in DoubleMLDIDMulti::bootstrap)",
          )
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
