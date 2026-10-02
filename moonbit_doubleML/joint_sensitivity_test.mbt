///|
// v0.77.0+: white-box tests for `joint_sensitivity` (the
// cross-estimator joint-coverage + joint-RV helper added in
// sensitivity.mbt). Each test builds a small
// `Array[JointSensitivityInput]` of synthetic summaries via the
// `JointSensitivityInput::new(...)` constructor and asserts on
// the per-estimator Bonferroni-corrected CI, the per-estimator
// RV / RV_q, and the cross-estimator joint fields
// (`joint_lower` / `joint_upper` / `joint_rv` / `joint_rv_q` /
// `bonferroni_alpha` / `num_estimators`).
//
// Three scenarios:
//   1. K = 2 (the typical multi-estimator case): the Bonferroni
//      correction should widen the per-estimator CI relative to
//      the un-corrected 1.96 * se Wald bound; the joint CI should
//      bracket both estimators' true coefs; the joint RV should
//      be `min(per_estimator_rv)`.
//   2. K = 1 (single-estimator control): no Bonferroni
//      correction (`bonferroni_alpha == alpha`); the joint CI
//      should collapse to the single estimator's CI.
//   3. K = 0 (empty input): zero-valued result with
//      `num_estimators == 0`, `bonferroni_alpha == alpha`, and
//      empty per-estimator arrays.

///|
/// `joint_sensitivity` with K = 2 takes a Bonferroni-corrected
/// alpha = `alpha / 2 = 0.025`. The two-sided critical value
/// becomes `z_{1 - 0.0125} = z_{0.9875} ~ 2.2414`, which is
/// strictly wider than the un-corrected 1.96 * se Wald bound.
/// For each estimator i, `per_estimator_lower[i] = coef_i - z *
/// se_i` and `per_estimator_upper[i] = coef_i + z * se_i`. The
/// joint CI is the union
/// `[min(per_estimator_lower), max(per_estimator_upper)]`, which
/// should bracket both `coef_1 = 0.5` and `coef_2 = 0.7`. The
/// joint RV / RV_q should equal `min(per_estimator_rv)` /
/// `min(per_estimator_rv_q)` respectively.
test "joint_sensitivity / 2-estimators / Bonferroni widens CI" {
  let i1 = JointSensitivityInput::new("irm", 0.5, 0.1, 1.0, 0.5, 0.05, 0.05)
  let i2 = JointSensitivityInput::new("plr", 0.7, 0.15, 1.5, 0.7, 0.05, 0.05)
  let r = joint_sensitivity([i1, i2], 0.05)
  // K and Bonferroni alpha.
  inspect(r.num_estimators, content="2")
  inspect((r.bonferroni_alpha - 0.025).abs() < 1.0e-12, content="true")
  // Joint CI brackets both coefs.
  inspect(r.joint_lower <= 0.5, content="true")
  inspect(r.joint_upper >= 0.7, content="true")
  // Per-estimator lower should be wider (smaller) than the
  // un-corrected Wald lower for estimator 1:
  // `0.5 - 1.96 * 0.1 = 0.304`. The Bonferroni-corrected lower
  // is `0.5 - 2.2414 * 0.1 = 0.2759`, which is < 0.39.
  inspect(r.per_estimator_lower[0] < 0.39, content="true")
  // Per-estimator upper for estimator 2 should be wider
  // (larger) than `0.7 + 1.96 * 0.15 = 0.994`.
  inspect(r.per_estimator_upper[1] > 0.994, content="true")
  // Joint RV = min(per_estimator_rv).
  let rv_min = if r.per_estimator_rv[0] < r.per_estimator_rv[1] {
    r.per_estimator_rv[0]
  } else {
    r.per_estimator_rv[1]
  }
  inspect((r.joint_rv - rv_min).abs() < 1.0e-12, content="true")
  // Joint RV_q = min(per_estimator_rv_q).
  let rvq_min = if r.per_estimator_rv_q[0] < r.per_estimator_rv_q[1] {
    r.per_estimator_rv_q[0]
  } else {
    r.per_estimator_rv_q[1]
  }
  inspect((r.joint_rv_q - rvq_min).abs() < 1.0e-12, content="true")
  // RV per estimator 1 is finite (sigma_sq * rho = 0.5 > 0).
  let rv1 = r.per_estimator_rv[0]
  inspect(rv1.is_nan() == false && rv1.is_inf() == false, content="true")
  // RV_q per estimator 1 is finite (|coef_1| = 0.5 > 0.224).
  let rvq1 = r.per_estimator_rv_q[0]
  inspect(rvq1.is_nan() == false && rvq1.is_inf() == false, content="true")
}

///|
/// `joint_sensitivity` with K = 1 takes Bonferroni alpha =
/// `alpha / 1 = alpha` (no correction). The two-sided critical
/// value stays at `z_{1 - alpha/2} = 1.96` for `alpha = 0.05`,
/// and the joint CI / RV collapse to the single estimator's
/// values.
test "joint_sensitivity / single estimator / no Bonferroni correction" {
  let i1 = JointSensitivityInput::new("irm", 0.5, 0.1, 1.0, 0.5, 0.05, 0.05)
  let r = joint_sensitivity([i1], 0.05)
  inspect(r.num_estimators, content="1")
  // No Bonferroni correction: bonferroni_alpha == alpha.
  inspect((r.bonferroni_alpha - 0.05).abs() < 1.0e-12, content="true")
  // Joint lower / upper collapse to the Wald 1.96 * se CI.
  // Tolerance is 1e-6 (not 1e-12): `norm_ppf` is bounded by
  // `norm_cdf`'s ~7.5e-8 absolute error, which propagates
  // through 64 bisection iterations to ~1e-6 in z-space
  // around the peak of the standard normal.
  let z_975 = 1.959963984540054
  let expected_lower = 0.5 - z_975 * 0.1
  let expected_upper = 0.5 + z_975 * 0.1
  inspect((r.joint_lower - expected_lower).abs() < 1.0e-6, content="true")
  inspect((r.joint_upper - expected_upper).abs() < 1.0e-6, content="true")
  inspect(
    (r.per_estimator_lower[0] - expected_lower).abs() < 1.0e-6,
    content="true",
  )
  inspect(
    (r.per_estimator_upper[0] - expected_upper).abs() < 1.0e-6,
    content="true",
  )
  // Joint RV == per_estimator RV (min over a single element).
  inspect((r.joint_rv - r.per_estimator_rv[0]).abs() < 1.0e-12, content="true")
  // RV_q matches the same collapse.
  inspect(
    (r.joint_rv_q - r.per_estimator_rv_q[0]).abs() < 1.0e-12,
    content="true",
  )
}

///|
/// `joint_sensitivity` with K = 0 returns a zero-valued result
/// with `num_estimators == 0`, `bonferroni_alpha == alpha` (no
/// division — `alpha / 0` is undefined; we fall back to alpha),
/// and empty per-estimator arrays. The joint bounds stay at
/// 0.0 (the default) and the joint RV / RV_q stay at the
/// `1.0e300` sentinel.
test "joint_sensitivity / empty results / zero-valued result" {
  let r = joint_sensitivity([], 0.05)
  inspect(r.num_estimators, content="0")
  inspect(r.joint_lower == 0.0, content="true")
  inspect(r.joint_upper == 0.0, content="true")
  inspect(r.per_estimator_lower.length(), content="0")
  inspect(r.per_estimator_upper.length(), content="0")
  inspect(r.per_estimator_rv.length(), content="0")
  inspect(r.per_estimator_rv_q.length(), content="0")
  // bonferroni_alpha stays at alpha when K = 0.
  inspect((r.bonferroni_alpha - 0.05).abs() < 1.0e-12, content="true")
  // RV / RV_q sentinels.
  inspect(r.joint_rv > 1.0e100, content="true")
  inspect(r.joint_rv_q > 1.0e100, content="true")
}
