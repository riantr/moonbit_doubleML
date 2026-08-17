///|
/// `aggregate_group` should average the post-treatment ATTs
/// within each group with equal weight. Pre-treatment AND
/// baseline (`t == g`) cells are skipped (the baseline cell
/// is left at 0.0 by `DoubleMLDIDCS` convention).
test "aggregate_group_simple" {
  // 2 groups × 3 periods, all strictly post-treatment.
  let coef = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
  let se = [0.1, 0.1, 0.1, 0.2, 0.2, 0.2]
  let groups = [1, 2]
  let periods = [3, 4, 5] // all t > g (1, 2) -> strict post
  let sizes = [50, 50]
  let r = aggregate_group(coef, se, groups, periods, sizes)
  // Group 1: mean(1, 2, 3) = 2.0, Group 2: mean(4, 5, 6) = 5.0
  inspect(r.theta.length(), content="2")
  inspect((r.theta[0] - 2.0).abs() < 1.0e-12, content="true")
  inspect((r.theta[1] - 5.0).abs() < 1.0e-12, content="true")
  // SE: sqrt(0.03 / 9) for group 1, sqrt(0.12 / 9) for group 2.
  let se1 = (0.03 / 9.0).sqrt()
  let se2 = (0.12 / 9.0).sqrt()
  inspect((r.se[0] - se1).abs() < 1.0e-12, content="true")
  inspect((r.se[1] - se2).abs() < 1.0e-12, content="true")
  inspect(r.agg_names[0], content="1")
  inspect(r.agg_names[1], content="2")
}

///|
/// Pre-treatment cells (`t <= g`) should be skipped (including
/// the `t == g` baseline cell).
test "aggregate_group_skips_pre_treatment" {
  // 1 group (g=2), 3 periods (t=1, 2, 3). Only t=3 is strict
  // post-treatment.
  let coef = [99.0, 99.0, 2.0] // t=1: 99, t=2: 99 (baseline), t=3: 2
  let se = [99.0, 99.0, 0.1]
  let groups = [2]
  let periods = [1, 2, 3]
  let sizes = [10]
  let r = aggregate_group(coef, se, groups, periods, sizes)
  // Mean of [2.0] = 2.0; SE = 0.1.
  inspect((r.theta[0] - 2.0).abs() < 1.0e-12, content="true")
  inspect((r.se[0] - 0.1).abs() < 1.0e-12, content="true")
}

///|
/// `aggregate_time` should average across groups with weights
/// proportional to group sizes. Baseline `t == g` cells are
/// skipped.
test "aggregate_time_weighted" {
  // 2 groups × 2 periods, all strict post-treatment.
  let coef = [1.0, 2.0, 4.0, 5.0]
  let se = [0.1, 0.1, 0.1, 0.1]
  let groups = [1, 2]
  let periods = [2, 3]
  // 75% in group 1, 25% in group 2.
  let sizes = [75, 25]
  let r = aggregate_time(coef, se, groups, periods, sizes)
  // Period 2 (t=2): g=1 post, g=2 baseline (skipped).
  //   weighted mean = (75*1) / 75 = 1.0
  // Period 3 (t=3): both post. weighted mean = (75*2 + 25*5) / 100 = 2.75
  inspect((r.theta[0] - 1.0).abs() < 1.0e-12, content="true")
  inspect((r.theta[1] - 2.75).abs() < 1.0e-12, content="true")
}

///|
/// `aggregate_event` should bucket by `e = t - g` and return
/// one entry per unique event time. Pre-treatment / baseline
/// cells (`e <= 0`) are skipped.
test "aggregate_event_basic" {
  // 2 groups × 3 periods. Strict post-treatment cells:
  //   g=1: e ∈ {1, 2} (t=2, 3)
  //   g=2: e ∈ {1}    (t=3)
  let coef = [
    0.0, 0.0, 11.0, 12.0, // g=1: t=0, 1, 2, 3
     0.0, 0.0, 0.0, 22.0, // g=2: t=0, 1, 2, 3
  ]
  let se = [0.0, 0.0, 0.1, 0.1, 0.0, 0.0, 0.0, 0.1]
  let groups = [1, 2]
  let periods = [0, 1, 2, 3]
  let sizes = [10, 10]
  let r = aggregate_event(coef, se, groups, periods, sizes)
  // e values present: -2, -1, 0, 1, 2 (5 unique). The
  // aggregator leaves the e <= 0 entries at 0.0.
  inspect(r.theta.length(), content="5")
  // e = 1: g=1 (t=2) coef=11, g=2 (t=3) coef=22, equal weights
  //        -> mean(11, 22) = 16.5
  let mut e1_idx = -1
  for i = 0; i < r.agg_names.length(); i = i + 1 {
    if r.agg_names[i] == "1" {
      e1_idx = i
    }
  }
  inspect(e1_idx >= 0, content="true")
  inspect((r.theta[e1_idx] - 16.5).abs() < 1.0e-12, content="true")
}
