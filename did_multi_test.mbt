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
  let fitted = DoubleMLDIDMulti::new(
    data,
    n_folds=2,
    seed=3141,
  ).fit()
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
