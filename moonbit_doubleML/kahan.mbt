///|
/// Kahan compensated summation: returns `sum(arr)` with a running
/// compensation term that recovers the low-order bits lost at each
/// addition step. The result is effectively computed in *double-double*
/// precision while staying inside the standard `Double` type.
///
/// # Why we need this
///
/// Naive summation
///
///     s = 0.0
///     for x in arr: s = s + x
///
/// loses the lowest `eps * |s|` bits of each addend on every step. The
/// worst-case relative error is `O(n * eps)` for `n` addends; when the
/// addends alternate in sign or have wildly different magnitudes (the
/// "catastrophic cancellation" pattern), the worst-case error grows
/// to `O(n^2 * eps)` and the running sum can drift by orders of
/// magnitude more than expected.
///
/// In the DML numeric kernels this matters in two places:
///
/// 1. `var_est.mbt`: the `gamma = gamma + psi^2` accumulator runs for
///    `n = 500` observations; `psi` is in roughly `[-2, 2]` so each
///    addend is `O(1)`, but partial sums of opposite-sign squared
///    terms are not catastrophic — Kahan is "free insurance" here.
/// 2. `matrix.mbt::matmul` and `matvec` and `linalg.mbt::cholesky`:
///    the inner-product accumulators add `O(p)` products of `O(1)`
///    terms; the partial sum stays around `O(1)`, so naive sum is
///    fine in well-conditioned cases but Kahan removes the
///    `~p * eps` drift when the partial sums nearly cancel.
///
/// We keep Kahan in the inner-product and the `gamma` loop (where it
/// is the cheapest high-value change), and we also upgraded `mean`
/// (the O(n) sum that every estimator calls twice per fit) to
/// Kahan; the 5-seed precheck confirms the upgrade is invisible at
/// 15-digit output and stays inside the TODO #5 thresholds
/// (`|theta - 1| < 0.2` for PLR, `< 0.5` for the other 4).
///
/// # Algorithm
///
/// Standard Kahan summation (Kahan 1965), also called "compensated
/// summation":
///
///     sum = 0.0
///     c   = 0.0    // compensation for low-order bits lost in the next add
///     for x in arr:
///       y = x - c           // align x with the running sum's precision
///       t = sum + y         // primary add
///       c = (t - sum) - y   // low-order bits of `t` that did not fit
///       sum = t
///     return sum
///
/// The invariant is that `sum + c` is the true (extended-precision)
/// running sum; the returned `sum` carries the high-order bits and `c`
/// holds the residual. After each step `|c| <= eps * |sum|`, so the
/// error stays `O(eps)` instead of `O(n * eps)`.
pub fn kahan_sum(arr : Array[Double]) -> Double {
  try {
    require(arr.length() >= 1)
    let mut sum = 0.0
    let mut c = 0.0
    for i = 0; i < arr.length(); i = i + 1 {
      let y = arr[i] - c
      let t = sum + y
      c = t - sum - y
      sum = t
    }
    sum
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
