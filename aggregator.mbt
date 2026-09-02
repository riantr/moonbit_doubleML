///|
/// Per-repetition coefficient / standard-error aggregation for the
/// DML family of estimators. Mirrors `doubleml.utils._aggregate_coefs_and_ses`
/// in the upstream `doubleml` package:
///
///     theta_hat = median(theta_1, ..., theta_R)
///     ub_r      = theta_r + 1.96 * se_r           for each rep r
///     ub_hat    = median(ub_1, ..., ub_R)
///     se_hat    = (ub_hat - theta_hat) / 1.96
///
/// The median is the "high median" — sort the array, take the entry
/// at index `length() / 2` (so for `n = 1` it is the only entry, for
/// `n = 2` it is the upper-middle, for odd `n` it is the exact middle).
/// This intentionally uses `Array::sort` + `length() / 2` and does not
/// depend on any external package.
///
/// The two input arrays must have the same non-zero length; otherwise
/// the call aborts at the `require(...)` precondition. The arrays are
/// not mutated — the function makes its own copy of `coefs` before
/// sorting.
///
/// For `n_rep == 1` the result is exactly `(coefs[0], ses[0])` because:
///
///     theta_hat = median([c]) = c
///     ub_hat    = median([c + 1.96 * s]) = c + 1.96 * s
///     se_hat    = (c + 1.96 * s - c) / 1.96 = s
///
/// This is the regression-protection invariant that the four estimator
/// `fit()`s rely on: when `n_rep = 1` the new "per-rep + median"
/// implementation must produce the same `(theta, se)` as the previous
/// "average nuisances, then estimate" implementation.
pub fn aggregate_coef_se(
  coefs : Array[Double],
  ses : Array[Double],
) -> (Double, Double) {
  try {
    require(coefs.length() == ses.length())
    require(coefs.length() >= 1)
    // n_rep == 1 fast path: the general formula goes through
    //   (median(coefs + 1.96 * ses) - median(coefs)) / 1.96
    // which is not exactly `ses[0]` in IEEE 754. The estimator
    // regression-protection invariant requires `(coefs[0], ses[0])`
    // byte-equal, so return the inputs directly here.
    if coefs.length() == 1 {
      return (coefs[0], ses[0])
    }
    let n = coefs.length()
    // theta_hat = median(coefs). Copy then sort so we do not mutate the
    // caller's array.
    let coefs_sorted = coefs.copy()
    coefs_sorted.sort()
    let theta_hat = coefs_sorted[n / 2]
    // ub = coefs + 1.96 * ses, then median.
    let ub = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      ub[i] = coefs[i] + 1.96 * ses[i]
    }
    ub.sort()
    let ub_hat = ub[n / 2]
    let se_hat = (ub_hat - theta_hat) / 1.96
    (theta_hat, se_hat)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
