///|
/// Happy-path smoke test: with `psi_a = ones` and `psi_b` drawn from a
/// (roughly) standard normal, `var_est` should return a point estimate
/// `coef` close to 0 (since `mean(psi_b) ≈ 0` and `mean(psi_a) = 1`)
/// and a small positive `se`. The tolerances here are intentionally
/// loose — this test is only here to make sure `var_est` does not
/// return a non-finite or wildly wrong number, not to pin down the
/// exact DML variance.
test "var_est_happy_path" {
  let n = 500
  let psi_a : Array[Double] = Array::make(n, 1.0)
  let psi_b : Array[Double] = Array::make(n, 0.0)
  // generate psi_b from a standard normal via Box-Muller
  let rng = @random.Rand::chacha8(seed=Bytes::from_array(seed_to_bytes(2024)))
  let mut i = 0
  while i < n {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let theta_ = 2.0 * 3.141592653589793 * u2
    psi_b[i] = r * @math.cos(theta_)
    if i + 1 < n {
      psi_b[i + 1] = r * @math.sin(theta_)
    }
    i = i + 2
  }
  let (coef, se) = @dml.var_est(psi_a, psi_b)
  // sanity: with psi_a=ones and mean(psi_b) ≈ 0, coef ≈ 0 within 1.0
  inspect((coef - 0.0).abs() < 1.0, content="true")
  // se must be positive and below 1.0 for n = 500 with unit psi_a
  inspect(se > 0.0, content="true")
  inspect(se < 1.0, content="true")
}

///|
/// `var_est` must abort when the two input arrays have different
/// lengths. The panic path goes through
/// `require(psi_a.length() == psi_b.length())` inside `var_est.mbt`,
/// which is the same `check.mbt:require` surface every other public
/// API uses.
test "panic_var_est_length_mismatch" {
  let _ = @dml.var_est([1.0, 2.0], [1.0])
}

///|
/// `var_est` must abort when both input arrays are empty. The panic
/// path goes through `require(psi_a.length() >= 1)` inside
/// `var_est.mbt` (the `n >= 1` precondition that guards against the
/// zero-length mean / division-by-zero that would otherwise follow).
test "panic_var_est_n_zero" {
  let _ = @dml.var_est([], [])
}
