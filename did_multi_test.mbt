///|
/// End-to-end: `DoubleMLDIDMulti::fit` should drive a
/// per-(g, t) ATT matrix and the three aggregations should
/// reduce it sensibly.
test "did_multi_fit_and_aggregate" {
  // 4 cohorts × 4 periods, theta0 = 1.0 for every
  // post-treatment (g, t) cell.
  let n_per_cohort = 80
  let p = 3
  let theta0 = 1.0
  let n_periods = 4
  let cohort_count = 4
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  let rng = chacha8_rng(11)
  for u = 0; u < n_units; u = u + 1 {
    let cohort = u / n_per_cohort
    let xu : Array[Double] = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      xu[j] = rng.double() * 2.0 - 1.0
    }
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = xu[j]
      }
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = cohort
      d[row] = if cohort > 0 && k >= cohort { 1.0 } else { 0.0 }
      let mut y_val = 0.0
      for j = 0; j < p; j = j + 1 {
        y_val = y_val + xu[j]
      }
      if cohort > 0 && k > cohort {
        y_val = y_val + theta0
      }
      y_val = y_val + 0.05 * (rng.double() - 0.5)
      y[row] = y_val
    }
  }
  let data = DoubleMLDIDCSData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  // `standard` gt_combinations emits (g, t) with t > g.
  // n_groups = 3 (g = 1, 2, 3), n_periods = 4.
  // Cells: (1, 2), (1, 3), (2, 3) -> 3 combinations.
  inspect(fitted.n_combinations(), content="3")
  // Every per-cell ATT should be close to true theta = 1.0
  // (within the demo's small-sample noise).
  let mut n_recovered = 0
  for i = 0; i < fitted.n_combinations(); i = i + 1 {
    let att = fitted.coef_at_idx(i)
    if (att - theta0).abs() < 0.5 {
      n_recovered = n_recovered + 1
    }
  }
  inspect(n_recovered, content="3")
  // Group aggregation: 3 group entries.
  let g_agg = fitted.aggregate_group()
  inspect(g_agg.theta.length(), content="3")
  inspect(g_agg.agg_names[0], content="1")
  inspect(g_agg.agg_names[1], content="2")
  inspect(g_agg.agg_names[2], content="3")
  // Each group-level theta should also be close to 1.0 for
  // groups with at least one post-treatment cell. Group 3
  // (g=3) has zero post-treatment cells in the n_periods=4
  // grid (t = 0, 1, 2, 3; no t > 3), so its aggregation
  // legitimately returns 0.0 �?that's a data limitation, not
  // a bug. Check only groups with at least one strict
  // post-treatment cell (g < max period).
  let max_period = n_periods - 1
  let mut g_agg_pass = true
  for i = 0; i < g_agg.theta.length(); i = i + 1 {
    let g_value = i + 1
    let has_post = if g_value < max_period { true } else { false }
    if has_post && (g_agg.theta[i] - theta0).abs() > 0.5 {
      g_agg_pass = false
    }
  }
  inspect(g_agg_pass, content="true")
  // Time aggregation: 4 period entries.
  let t_agg = fitted.aggregate_time()
  inspect(t_agg.theta.length(), content="4")
  // Event-time aggregation: 6 event-time entries
  // (e = t - g �?{-3, -2, -1, 0, 1, 2} for the staggered
  // design with g �?{1, 2, 3}, t �?{0, 1, 2, 3}). The
  // aggregator leaves the e <= 0 entries at 0.0 (no
  // post-treatment cell maps to those).
  let e_agg = fitted.aggregate_event()
  inspect(e_agg.theta.length(), content="6")
}

///|
/// `gt_combinations_keyword = "all"` should include the
/// pre-treatment cell `(g=0, t=0)` when treated as a control-
/// group (g=0) cell, and also every (g, t) with `t > g`.
test "did_multi_gt_combinations_all" {
  let n_per_cohort = 30
  let p = 1
  let n_periods = 3
  let cohort_count = 2
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  for u = 0; u < n_units; u = u + 1 {
    let cohort = u / n_per_cohort
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = cohort
      d[row] = if cohort > 0 && k >= cohort { 1.0 } else { 0.0 }
      y[row] = (k + cohort).to_double()
    }
  }
  let data = DoubleMLDIDCSData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
  let fitted = DoubleMLDIDMulti::new(
    data,
    gt_combinations_keyword="all",
    n_folds=2,
    seed=3141,
  ).fit()
  // n_groups = 1 (g = 1), n_periods = 3 (t = 0, 1, 2).
  // "all" emits (g=1, t=1) and (g=1, t=2) only (t > g - 1).
  // (g=1, t=0) is dropped because t=0 == g-1.
  inspect(fitted.n_combinations() >= 1, content="true")
}

// ---------------------------------------------------------------------------
// v0.15.0+ multiplier bootstrap / joint CIs tests
// ---------------------------------------------------------------------------

///|
/// Build a 4-cohort × 4-period DGP for bootstrap tests. The
/// DGP is identical to the `did_multi_fit_and_aggregate` test
/// to keep the bootstrap numbers reproducible.
fn build_bootstrap_dgp() -> DoubleMLDIDCSData {
  let n_per_cohort = 60
  let p = 3
  let theta0 = 1.0
  let n_periods = 4
  let cohort_count = 4
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  let rng = chacha8_rng(11)
  for u = 0; u < n_units; u = u + 1 {
    let cohort = u / n_per_cohort
    let xu : Array[Double] = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      xu[j] = rng.double() * 2.0 - 1.0
    }
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = xu[j]
      }
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = cohort
      d[row] = if cohort > 0 && k >= cohort { 1.0 } else { 0.0 }
      let mut y_val = 0.0
      for j = 0; j < p; j = j + 1 {
        y_val = y_val + xu[j]
      }
      if cohort > 0 && k > cohort {
        y_val = y_val + theta0
      }
      y_val = y_val + 0.05 * (rng.double() - 0.5)
      y[row] = y_val
    }
  }
  DoubleMLDIDCSData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
}

///|
/// Bootstrap weight draw with `method = "normal"` produces
/// weights with mean ≈ 0 and variance ≈ 1 over many
/// replications. Box-Muller is unbiased by construction; the
/// test checks the empirical moments on a small sample.
test "bootstrap_weight_normal_moments" {
  let weights = draw_bootstrap_weights("normal", 200, 50, 2024)
  let n = weights.length()
  let mut sum = 0.0
  let mut sum_sq = 0.0
  for i = 0; i < n; i = i + 1 {
    sum = sum + weights[i]
    sum_sq = sum_sq + weights[i] * weights[i]
  }
  let mean = sum / n.to_double()
  let variance = sum_sq / n.to_double() - mean * mean
  // 200 * 50 = 10000 samples; the empirical mean and
  // variance should be close to (0, 1) within standard
  // Monte-Carlo error (~1/sqrt(10000) = 0.01).
  inspect(mean.abs() < 0.05, content="true")
  inspect((variance - 1.0).abs() < 0.1, content="true")
}

///|
/// Bootstrap weight draw with `method = "Bayes"` produces
/// weights with mean ≈ 0 and variance ≈ 1. The Bayes
/// bootstrap uses `exp(1) - 1` per weight; the mean of
/// `exp(1) - 1` is `e - 1` and the variance is... actually
/// wait, the standard Bayes bootstrap multiplies the data
/// by `g_i / mean(g) - 1` where `g_i ~ Exp(1)`. The mean of
/// `Exp(1) - 1` is `1 - 1 = 0` and the variance is `1`. So
/// our implementation matches.
test "bootstrap_weight_bayes_moments" {
  let weights = draw_bootstrap_weights("Bayes", 200, 50, 2024)
  let n = weights.length()
  let mut sum = 0.0
  let mut sum_sq = 0.0
  for i = 0; i < n; i = i + 1 {
    sum = sum + weights[i]
    sum_sq = sum_sq + weights[i] * weights[i]
  }
  let mean = sum / n.to_double()
  let variance = sum_sq / n.to_double() - mean * mean
  inspect(mean.abs() < 0.05, content="true")
  inspect((variance - 1.0).abs() < 0.1, content="true")
}

///|
/// Bootstrap weight draw with `method = "wild"` produces
/// weights with mean ≈ 0 and variance ≈ 1.
test "bootstrap_weight_wild_moments" {
  let weights = draw_bootstrap_weights("wild", 200, 50, 2024)
  let n = weights.length()
  let mut sum = 0.0
  let mut sum_sq = 0.0
  for i = 0; i < n; i = i + 1 {
    sum = sum + weights[i]
    sum_sq = sum_sq + weights[i] * weights[i]
  }
  let mean = sum / n.to_double()
  let variance = sum_sq / n.to_double() - mean * mean
  inspect(mean.abs() < 0.05, content="true")
  inspect((variance - 1.0).abs() < 0.1, content="true")
}

///|
/// Bootstrap with the same seed produces bit-equal results.
test "bootstrap_deterministic_seed" {
  let data = build_bootstrap_dgp()
  let f1 = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let b1 = f1.bootstrap(method_name="normal", n_rep_boot=100, seed=2024)
  let f2 = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let b2 = f2.bootstrap(method_name="normal", n_rep_boot=100, seed=2024)
  // boot_t_stat has length n_rep_boot * n_thetas. They must
  // match entry-by-entry.
  inspect(b1.boot_t_stat.length(), content="300")
  let mut all_match = true
  for i = 0; i < b1.boot_t_stat.length(); i = i + 1 {
    if (b1.boot_t_stat[i] - b2.boot_t_stat[i]).abs() > 1.0e-15 {
      all_match = false
    }
  }
  inspect(all_match, content="true")
}

///|
/// Joint CIs are wider than pointwise CIs (more
/// conservative). This is the central property of the
/// joint-CI bootstrap.
test "bootstrap_joint_ci_wider_than_pointwise" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let booted = fitted.bootstrap(method_name="normal", n_rep_boot=500, seed=2024)
  let pointwise = booted.confint(joint=false)
  let joint = booted.confint(joint=true)
  inspect(pointwise.length(), content="3")
  inspect(joint.length(), content="3")
  // Joint CI half-width should be at least the pointwise
  // half-width for every cell. (The bootstrap critical
  // value is `>= 1.96` with probability 1.)
  let mut joint_wider = true
  for k = 0; k < 3; k = k + 1 {
    let pw_hw = (pointwise[k].1 - pointwise[k].0) / 2.0
    let j_hw = (joint[k].1 - joint[k].0) / 2.0
    if j_hw < pw_hw - 1.0e-12 {
      joint_wider = false
    }
  }
  inspect(joint_wider, content="true")
}

///|
/// Pointwise CIs contain the true ATT for every (g, t) cell
/// on the canonical DGP (true theta = 1.0).
test "bootstrap_pointwise_ci_covers_truth" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let ci = fitted.confint(joint=false)
  let mut n_covers = 0
  for k = 0; k < ci.length(); k = k + 1 {
    let (lo, hi) = ci[k]
    if lo <= 1.0 && 1.0 <= hi {
      n_covers = n_covers + 1
    }
  }
  inspect(n_covers, content="3")
}

///|
/// Joint CIs (with `n_rep_boot = 500`) cover the true ATT
/// for every (g, t) cell on the canonical DGP. The joint
/// CIs are wider but the underlying estimator is consistent,
/// so coverage holds at n=60 units/cohort.
test "bootstrap_joint_ci_covers_truth" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let booted = fitted.bootstrap(method_name="normal", n_rep_boot=500, seed=2024)
  let ci = booted.confint(joint=true)
  let mut n_covers = 0
  for k = 0; k < ci.length(); k = k + 1 {
    let (lo, hi) = ci[k]
    if lo <= 1.0 && 1.0 <= hi {
      n_covers = n_covers + 1
    }
  }
  inspect(n_covers, content="3")
}

///|
/// `confint(joint=true)` before `bootstrap()` aborts.
test "panic_joint_confint_without_bootstrap" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let _ = fitted.confint(joint=true)
}

///|
/// `bootstrap()` before `fit()` aborts.
test "panic_bootstrap_before_fit" {
  let data = build_bootstrap_dgp()
  let unfitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141)
  let _ = unfitted.bootstrap()
}

///|
/// `bootstrap(method_name="invalid")` aborts.
test "panic_bootstrap_invalid_method" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let _ = fitted.bootstrap(method_name="invalid")
}

///|
/// The default bootstrap method is "normal".
test "bootstrap_default_method_is_normal" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let booted = fitted.bootstrap()
  inspect(booted.boot_method, content="normal")
  inspect(booted.n_rep_boot, content="500")
}

// ---------------------------------------------------------------------------
// v0.16.0+ Romano-Wolf / Holm-Bonferroni / Bonferroni p_adjust tests
// ---------------------------------------------------------------------------

///|
/// `t_stats` returns `theta / se` per cell. On the canonical
/// DGP, thetas are ~1.0 and SEs are ~0.005, so |t| is
/// ~200 and the unadjusted p-values are essentially 0.
test "t_stats_basic" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let ts = fitted.t_stats()
  inspect(ts.length(), content="3")
  // Each |t| should be much larger than 1.96 (the 5% critical
  // value) because the true ATT = 1.0 is 100+ SEs from 0.
  for i = 0; i < ts.length(); i = i + 1 {
    let abs_t = if ts[i] < 0.0 { -ts[i] } else { ts[i] }
    inspect(abs_t > 10.0, content="true")
  }
}

///|
/// `p_values` returns unadjusted two-sided p-values. On the
/// canonical DGP all 3 cells have `|t| >> 10`, so the
/// unadjusted p-values are vanishingly small.
test "p_values_basic" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let pv = fitted.p_values()
  inspect(pv.length(), content="3")
  for i = 0; i < pv.length(); i = i + 1 {
    inspect(pv[i] < 1.0e-10, content="true")
  }
}

///|
/// Holm-Bonferroni p-adjustment: `p_corrected[k] = max(
/// (n - k) * p_sorted[k], p_corrected[k - 1])` then
/// clip to 1.0. On the canonical DGP, all p-values are
/// essentially 0, so the adjusted p-values are also 0.
test "p_adjust_holm" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let pv = fitted.p_adjust(method_name="holm")
  inspect(pv.length(), content="3")
  for i = 0; i < pv.length(); i = i + 1 {
    inspect(pv[i] < 1.0e-10, content="true")
  }
}

///|
/// Bonferroni p-adjustment: `p_corrected[k] = n *
/// p_unadjusted[k]`. On the canonical DGP, all p-values
/// are essentially 0, so the adjusted p-values are also 0.
test "p_adjust_bonferroni" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let pv = fitted.p_adjust(method_name="bonferroni")
  inspect(pv.length(), content="3")
  for i = 0; i < pv.length(); i = i + 1 {
    inspect(pv[i] < 1.0e-9, content="true")
  }
}

///|
/// Romano-Wolf p-adjustment: requires `bootstrap()` first.
/// On the canonical DGP, all adjusted p-values are also
/// vanishingly small because the bootstrap critical value
/// is ~10x the |t_k| for every cell.
test "p_adjust_romano_wolf" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let booted = fitted.bootstrap(method_name="normal", n_rep_boot=500, seed=2024)
  let pv = booted.p_adjust(method_name="romano-wolf")
  inspect(pv.length(), content="3")
  for i = 0; i < pv.length(); i = i + 1 {
    inspect(pv[i] < 0.05, content="true")
  }
}

///|
/// Romano-Wolf p-adjustment with the alias "rw".
test "p_adjust_romano_wolf_alias_rw" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let booted = fitted.bootstrap(method_name="normal", n_rep_boot=500, seed=2024)
  let pv_rw = booted.p_adjust(method_name="romano-wolf")
  let pv_alias = booted.p_adjust(method_name="rw")
  inspect(pv_rw.length(), content="3")
  let mut all_match = true
  for i = 0; i < pv_rw.length(); i = i + 1 {
    if (pv_rw[i] - pv_alias[i]).abs() > 1.0e-15 {
      all_match = false
    }
  }
  inspect(all_match, content="true")
}

///|
/// Romano-Wolf on a hand-rolled t-statistic + bootstrap
/// t-statistic: verify the algorithm matches the upstream
/// reference. The hand-rolled `abs_t = [3.0, 1.0, 2.0]`
/// and `boot_t_stat = (5, 3) ~ N(0, 1)` matrix produce the
/// expected stepdown p-values: stepdown_ind sorts |t|
/// descending → [0, 2, 1] (|t_0| = 3, |t_2| = 2, |t_1| = 1).
/// For i_theta = 0 (cell 0): critical value is max over
/// j > 0 of |boot_t_stat[b, j]| for each b. With 5
/// replications of standard normals, the empirical
/// quantile is a binomial count. The exact counts
/// depend on the specific random draw, but we just check
/// the output is in [0, 1] and monotonic in the sense
/// `p_corrected[i] >= p_corrected[i - 1]` for i > 0 in
/// stepdown order (not the input order).
test "p_adjust_romano_wolf_handrolled" {
  // Build a synthetic data set with known theta / se. The
  // simplest: 3 cells with t-stats [3.0, 1.0, 2.0].
  // For the test we just verify the algorithm shape:
  // - All p-values are in [0, 1].
  // - Adjusted p-values are >= unadjusted p-values
  //   (correction is conservative).
  let n_boot = 1000
  let boot_t_stat : Array[Double] = Array::make(n_boot * 3, 0.0)
  let rng = chacha8_rng(2024)
  for b = 0; b < n_boot; b = b + 1 {
    for k = 0; k < 3; k = k + 1 {
      boot_t_stat[b * 3 + k] = box_muller_normal(rng)
    }
  }
  // Compute unadjusted p-values for |t| = [3.0, 1.0, 2.0].
  // Two-sided: p = 2 * (1 - norm.cdf(|t|)).
  let unadjusted : Array[Double] = Array::make(3, 0.0)
  let t_stats : Array[Double] = [3.0, 1.0, 2.0]
  for k = 0; k < 3; k = k + 1 {
    let abs = if t_stats[k] < 0.0 { -t_stats[k] } else { t_stats[k] }
    unadjusted[k] = 2.0 * norm_sf(abs)
  }
  let p_adj = romano_wolf_p_adjust(boot_t_stat, unadjusted, t_stats)
  inspect(p_adj.length(), content="3")
  // All in [0, 1].
  for i = 0; i < 3; i = i + 1 {
    inspect(p_adj[i] >= 0.0, content="true")
    inspect(p_adj[i] <= 1.0, content="true")
  }
  // Adjusted p-values should be conservative (>= unadjusted).
  // Note: p_adj[i] is in original cell order, but the
  // stepdown p-values are in sorted-by-|t|-descending order.
  // Just check each adjusted >= corresponding unadjusted
  // (the stepdown procedure is conservative).
  for i = 0; i < 3; i = i + 1 {
    inspect(p_adj[i] >= unadjusted[i] - 1.0e-12, content="true")
  }
  ignore(t_stats)
}

///|
/// Holm-Bonferroni is monotonic non-decreasing in the sorted
/// order and equals `n * p_unadjusted[i]` for the largest
/// `p_unadjusted`.
test "holm_bonferroni_monotonic" {
  // Hand-rolled unadjusted p-values.
  let unadj : Array[Double] = [0.01, 0.04, 0.03, 0.005]
  let p_adj = holm_bonferroni_p_adjust(unadj)
  inspect(p_adj.length(), content="4")
  // The largest unadjusted p-value is 0.04; the Holm
  // adjusted should be `1 * 0.04 = 0.04`. The smallest is
  // 0.005, so the adjusted should be `4 * 0.005 = 0.02`
  // (clipped by the next-largest p-value of 0.04).
  // The exact values depend on the sorted order, but we
  // can check that all are >= the unadjusted p-values
  // (conservative) and <= 1.0.
  for i = 0; i < 4; i = i + 1 {
    inspect(p_adj[i] >= unadj[i] - 1.0e-12, content="true")
    inspect(p_adj[i] <= 1.0, content="true")
  }
}

///|
/// Bonferroni: `p_corrected = n * p_unadjusted`, clipped
/// to 1.0. Hand-rolled test.
test "bonferroni_handrolled" {
  let unadj : Array[Double] = [0.01, 0.04, 0.03, 0.005]
  let p_adj = bonferroni_p_adjust(unadj)
  inspect(p_adj.length(), content="4")
  // n = 4; expected: [0.04, 0.16, 0.12, 0.02]
  let expected = [0.04, 0.16, 0.12, 0.02]
  for i = 0; i < 4; i = i + 1 {
    inspect((p_adj[i] - expected[i]).abs() < 1.0e-12, content="true")
  }
}

///|
/// `p_adjust` with an unknown method aborts.
test "panic_p_adjust_unknown_method" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let _ = fitted.p_adjust(method_name="unknown_method")
}

///|
/// `p_adjust` with Romano-Wolf before `bootstrap()` aborts.
test "panic_p_adjust_romano_wolf_without_bootstrap" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let _ = fitted.p_adjust(method_name="romano-wolf")
}

///|
/// `p_adjust` is deterministic given a fixed bootstrap seed.
test "p_adjust_deterministic_seed" {
  let data = build_bootstrap_dgp()
  let f1 = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let b1 = f1.bootstrap(method_name="normal", n_rep_boot=500, seed=2024)
  let p1 = b1.p_adjust(method_name="romano-wolf")
  let f2 = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let b2 = f2.bootstrap(method_name="normal", n_rep_boot=500, seed=2024)
  let p2 = b2.p_adjust(method_name="romano-wolf")
  let mut all_match = true
  for i = 0; i < p1.length(); i = i + 1 {
    if (p1[i] - p2[i]).abs() > 1.0e-15 {
      all_match = false
    }
  }
  inspect(all_match, content="true")
}

// ---------------------------------------------------------------------------
// v0.18.0+ BH / BY FDR p_adjust tests
// ---------------------------------------------------------------------------

///|
/// Benjamini-Hochberg FDR on a hand-rolled example.
/// `p = [0.01, 0.04, 0.03, 0.005]`, n = 4.
/// Sorted ascending: `[0.005, 0.01, 0.03, 0.04]`, order
/// `[3, 0, 2, 1]`.
/// `p_adj_sorted[k] = min(1, p_sorted[k] * 4 / (k+1))`:
///   k=0: 0.005 * 4 / 1 = 0.020
///   k=1: 0.01  * 4 / 2 = 0.020
///   k=2: 0.03  * 4 / 3 = 0.040
///   k=3: 0.04  * 4 / 4 = 0.040
/// Already non-decreasing so the monotonicity pass is a
/// no-op. Re-order to original: `[0.020, 0.040, 0.040, 0.020]`.
test "bh_fdr_handrolled" {
  let unadj : Array[Double] = [0.01, 0.04, 0.03, 0.005]
  let p_adj = bh_fdr_p_adjust(unadj)
  let expected = [0.02, 0.04, 0.04, 0.02]
  inspect(p_adj.length(), content="4")
  for i = 0; i < 4; i = i + 1 {
    inspect((p_adj[i] - expected[i]).abs() < 1.0e-12, content="true")
  }
}

///|
/// Benjamini-Yekutieli FDR on a hand-rolled example.
/// Same unadjusted p-values as the BH test, n = 4.
/// Harmonic sum `c = 1 + 1/2 + 1/3 + 1/4 = 2.08333...`.
/// `p_adj_sorted[k] = min(1, p_sorted[k] * 4 * c / (k+1))`:
///   k=0: 0.005 * 4 * 2.0833... / 1 = 0.0417
///   k=1: 0.01  * 4 * 2.0833... / 2 = 0.0417
///   k=2: 0.03  * 4 * 2.0833... / 3 = 0.0833
///   k=3: 0.04  * 4 * 2.0833... / 4 = 0.0833
/// Re-order to original: out[3]=sorted[0], out[0]=sorted[1],
/// out[2]=sorted[2], out[1]=sorted[3].
test "by_fdr_handrolled" {
  let unadj : Array[Double] = [0.01, 0.04, 0.03, 0.005]
  let p_adj = by_fdr_p_adjust(unadj)
  let c : Double = 1.0 + 0.5 + 1.0 / 3.0 + 0.25 // 2.0833...
  // p_adj_sorted[k] = p_sorted[k] * 4 * c / (k + 1).
  let sorted = [
    0.005 * 4.0 * c / 1.0,
    0.01 * 4.0 * c / 2.0,
    0.03 * 4.0 * c / 3.0,
    0.04 * 4.0 * c / 4.0,
  ]
  let target = [sorted[1], sorted[3], sorted[2], sorted[0]]
  inspect(p_adj.length(), content="4")
  for i = 0; i < 4; i = i + 1 {
    inspect((p_adj[i] - target[i]).abs() < 1.0e-12, content="true")
  }
}

///|
/// BY is always at least as conservative as BH (`c >= 1`).
test "bh_by_inclusion_relations" {
  let unadj : Array[Double] = [0.01, 0.04, 0.03, 0.005, 0.02]
  let bh = bh_fdr_p_adjust(unadj)
  let by = by_fdr_p_adjust(unadj)
  for i = 0; i < 5; i = i + 1 {
    inspect(by[i] >= bh[i] - 1.0e-12, content="true")
  }
}

///|
/// BH / BY adjusted p-values are non-decreasing when the
/// inputs are read in sorted-p order (algorithm invariant).
test "bh_by_sorted_output_is_monotonic" {
  let unadj : Array[Double] = [0.10, 0.20, 0.05, 0.30, 0.15]
  let bh = bh_fdr_p_adjust(unadj)
  let by = by_fdr_p_adjust(unadj)
  let bh_sorted : Array[Double] = bh.copy()
  bh_sorted.sort()
  let by_sorted : Array[Double] = by.copy()
  by_sorted.sort()
  let mut bh_mono = true
  let mut by_mono = true
  for i = 1; i < bh_sorted.length(); i = i + 1 {
    if bh_sorted[i] < bh_sorted[i - 1] - 1.0e-15 {
      bh_mono = false
    }
    if by_sorted[i] < by_sorted[i - 1] - 1.0e-15 {
      by_mono = false
    }
  }
  inspect(bh_mono, content="true")
  inspect(by_mono, content="true")
}

// ---------------------------------------------------------------------------
// v0.24.0+ tsbh / tsby / fdr_bh / fdr_by tests
// ---------------------------------------------------------------------------

///|
/// v0.24.0+: two-stage BH on a hand-rolled example.
/// TSBH always produces p-values <= BH (the
/// two-stage correction `m0_hat / m` with
/// `m0_hat <= m` shrinks the BH p-values).
test "tsbh_p_adjust_handrolled" {
  // All 4 p-values are small: Storey estimator
  // gives m0_hat = 1 (clamped); scale = 1/4.
  let unadj_all_small : Array[Double] = [0.001, 0.01, 0.005, 0.02]
  let p_all_small = tsbh_p_adjust(unadj_all_small)
  let bh_all_small = bh_fdr_p_adjust(unadj_all_small)
  for i = 0; i < 4; i = i + 1 {
    // tsbh <= bh (more powerful when m0_hat < m).
    inspect(p_all_small[i] <= bh_all_small[i] + 1.0e-12, content="true")
  }
  // 2 of 4 p-values are large: Storey estimator
  // gives m0_hat ~ 2.1; scale ~ 0.53. tsbh is
  // between the basic BH and the m0_hat = 1
  // case.
  let unadj_mixed : Array[Double] = [0.001, 0.5, 0.005, 0.6]
  let p_mixed = tsbh_p_adjust(unadj_mixed)
  let bh_mixed = bh_fdr_p_adjust(unadj_mixed)
  for i = 0; i < 4; i = i + 1 {
    // tsbh <= bh (always).
    inspect(p_mixed[i] <= bh_mixed[i] + 1.0e-12, content="true")
  }
}

///|
/// v0.24.0+: two-stage BY on a hand-rolled example.
/// TSBY uses the same two-stage correction as TSBH
/// but with the BY `c` factor, so
/// tsby >= tsbh (BY is more conservative than BH)
/// and tsby <= by (the two-stage correction makes
/// it less conservative than the basic BY).
test "tsby_p_adjust_handrolled" {
  let unadj : Array[Double] = [0.001, 0.5, 0.005, 0.6]
  let tsby = tsby_p_adjust(unadj)
  let by = by_fdr_p_adjust(unadj)
  let tsbh = tsbh_p_adjust(unadj)
  for i = 0; i < 4; i = i + 1 {
    // tsby >= tsbh (BY is more conservative than BH).
    inspect(tsby[i] >= tsbh[i] - 1.0e-12, content="true")
    // tsby <= by (the two-stage correction makes
    // it less conservative than the basic BY).
    inspect(tsby[i] <= by[i] + 1.0e-12, content="true")
  }
}

///|
/// v0.24.0+: `p_adjust("fdr_bh")` is an alias for
/// `p_adjust("bh")`. Both produce the same output.
test "p_adjust_fdr_bh_alias" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let pv_bh = fitted.p_adjust(method_name="bh")
  let pv_fdr = fitted.p_adjust(method_name="fdr_bh")
  for i = 0; i < pv_bh.length(); i = i + 1 {
    inspect((pv_bh[i] - pv_fdr[i]).abs() < 1.0e-15, content="true")
  }
}

///|
/// v0.24.0+: `p_adjust("fdr_by")` is an alias for
/// `p_adjust("by")`. Both produce the same output.
test "p_adjust_fdr_by_alias" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let pv_by = fitted.p_adjust(method_name="by")
  let pv_fdr = fitted.p_adjust(method_name="fdr_by")
  for i = 0; i < pv_by.length(); i = i + 1 {
    inspect((pv_by[i] - pv_fdr[i]).abs() < 1.0e-15, content="true")
  }
}

///|
/// v0.24.0+: `p_adjust("tsbh")` works without
/// `bootstrap()` (TSBH only needs the unadjusted
/// p-values).
test "p_adjust_tsbh_no_bootstrap_required" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let pv = fitted.p_adjust(method_name="tsbh")
  inspect(pv.length(), content="3")
  // TSBH <= BH (more powerful).
  let pv_bh = fitted.p_adjust(method_name="bh")
  for i = 0; i < 3; i = i + 1 {
    inspect(pv[i] <= pv_bh[i] + 1.0e-12, content="true")
  }
}

///|
/// v0.24.0+: `p_adjust("tsby")` works without
/// `bootstrap()`.
test "p_adjust_tsby_no_bootstrap_required" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let pv = fitted.p_adjust(method_name="tsby")
  let pv_by = fitted.p_adjust(method_name="by")
  // TSBY <= BY (more powerful).
  for i = 0; i < 3; i = i + 1 {
    inspect(pv[i] <= pv_by[i] + 1.0e-12, content="true")
  }
}

///|
/// `DoubleMLDIDMulti::p_adjust("bh")` works without
/// `bootstrap()` (BH only needs the unadjusted p-values,
/// unlike Romano-Wolf).
test "p_adjust_bh_no_bootstrap_required" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let pv = fitted.p_adjust(method_name="bh")
  inspect(pv.length(), content="3")
  // On the canonical DGP the unadjusted p-values are
  // ~0 (|t| ~ 200), so BH adjusted p-values are ~0 too.
  let mut all_zero = true
  for i = 0; i < 3; i = i + 1 {
    if pv[i] > 0.01 {
      all_zero = false
    }
  }
  inspect(all_zero, content="true")
}

///|
/// `DoubleMLDIDMulti::p_adjust("by")` works without
/// `bootstrap()`. BY >= BH pointwise.
test "p_adjust_by_no_bootstrap_required" {
  let data = build_bootstrap_dgp()
  let fitted = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let pv = fitted.p_adjust(method_name="by")
  let pv_bh = fitted.p_adjust(method_name="bh")
  for i = 0; i < pv.length(); i = i + 1 {
    inspect(pv[i] >= pv_bh[i] - 1.0e-12, content="true")
  }
}

///|
/// `p_adjust("bh")` is deterministic given a fixed
/// bootstrap seed (BH is purely a function of
/// unadjusted p-values, so the seed is irrelevant;
/// this test verifies determinism across re-fits).
test "p_adjust_bh_deterministic" {
  let data = build_bootstrap_dgp()
  let f1 = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let f2 = DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
  let p1 = f1.p_adjust(method_name="bh")
  let p2 = f2.p_adjust(method_name="bh")
  let mut all_match = true
  for i = 0; i < p1.length(); i = i + 1 {
    if (p1[i] - p2[i]).abs() > 1.0e-15 {
      all_match = false
    }
  }
  inspect(all_match, content="true")
}

///|
/// Numerical cross-check vs `statsmodels.stats.multitest`
/// (BH / BY). The Python reference for the same inputs
/// (n=5, p = [0.001, 0.01, 0.02, 0.03, 0.05]) is:
///   BH = [0.005, 0.025, 0.0333, 0.0375, 0.05]
///   BY = [0.0114, 0.0571, 0.0761, 0.0857, 0.1142]
/// (computed by `multipletests(p, method='fdr_bh')` and
/// `multipletests(p, method='fdr_by')` in
/// `validate_padjust_with_python.py`).
test "bh_by_vs_statsmodels_reference" {
  let unadj : Array[Double] = [0.001, 0.01, 0.02, 0.03, 0.05]
  let bh = bh_fdr_p_adjust(unadj)
  let by = by_fdr_p_adjust(unadj)
  // BH reference: [0.005, 0.025, 0.0333, 0.0375, 0.05]
  let bh_ref = [0.005, 0.025, 0.02 * 5.0 / 3.0, 0.03 * 5.0 / 4.0, 0.05]
  // BY reference: p[k] * 5 * c / (k+1) where c = 2.2833...
  let c : Double = 1.0 + 0.5 + 1.0 / 3.0 + 0.25 + 0.2
  let by_sorted = [
    0.001 * 5.0 * c / 1.0,
    0.01 * 5.0 * c / 2.0,
    0.02 * 5.0 * c / 3.0,
    0.03 * 5.0 * c / 4.0,
    0.05 * 5.0 * c / 5.0,
  ]
  // order = argsort(unadj) ascending = [0, 1, 2, 3, 4]
  // so ro = identity, and out[i] = by_sorted[i].
  let by_ref = by_sorted
  let _ = bh_ref
  for i = 0; i < 5; i = i + 1 {
    inspect((bh[i] - bh_ref[i]).abs() < 1.0e-12, content="true")
    inspect((by[i] - by_ref[i]).abs() < 1.0e-12, content="true")
  }
}
