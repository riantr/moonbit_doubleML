///|
/// `n_rep == 1` is the regression-protection invariant. The aggregator
/// must return `(coefs[0], ses[0])` exactly (bit-for-bit) so the four
/// estimator `fit()`s behave identically to the previous "average then
/// estimate" implementation when called with `n_rep = 1`.
test "aggregate_n_rep_one_passthrough" {
  let coefs : Array[Double] = [0.5]
  let ses : Array[Double] = [0.1]
  let (theta, se) = aggregate_coef_se(coefs, ses)
  inspect(theta, content="0.5")
  inspect(se, content="0.1")
}

///|
/// Three reps, coefs = [0, 1, 2] -> median = 1; ses = [1, 1, 1] ->
/// ub = [0+1.96, 1+1.96, 2+1.96] -> median = 1 + 1.96 -> SE = 1.
test "aggregate_n_rep_three_uses_median" {
  let coefs : Array[Double] = [0.0, 1.0, 2.0]
  let ses : Array[Double] = [1.0, 1.0, 1.0]
  let (theta, se) = aggregate_coef_se(coefs, ses)
  inspect(theta == 1.0, content="true")
  // se == (median(ub) - median(coefs)) / 1.96 == 1.0
  inspect((se - 1.0).abs() < 1.0e-12, content="true")
}

///|
/// Mismatched lengths must `require` (abort) instead of silently
/// producing a partial aggregation. The `panic_` prefix on the test
/// name lets the framework report the abort as expected.
test "panic_aggregate_rejects_mismatched_lengths" {
  let coefs : Array[Double] = [0.5, 0.6]
  let ses : Array[Double] = [0.1]
  let _ = aggregate_coef_se(coefs, ses)
}
