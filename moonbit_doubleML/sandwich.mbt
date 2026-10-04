///|
// v0.79.0+: sandwich (heteroskedasticity-consistent) variance
// estimators + bias-correction helpers for DML estimators.
//
// Scope:
//   - HC0 / HC1 / HC2 / HC3 (Huber-White family, Long & Ervin
//     2000, MacKinnon 2012) for the IID setting.
//   - cluster-robust sandwich (Arellano 1987,
//     Cameron-Gelbach-Miller 2011) for one cluster variable.
//   - `bias_corrected_theta` -- a generic finite-sample bias
//     correction helper.
//
// The four HC estimators share the same skeleton: a squared
// score contribution `psi[i]^2` per observation, optionally
// rescaled by the leverage `(1 - h_ii)` (HC2 / HC3) or by the
// n/(n-k) finite-sample factor (HC1), and finally divided
// by the sample size TWICE (once to turn the sum into the
// `E[psi psi']` estimate, once for the 1/n of a mean-root
// asymptotics). The formulas are scalar (single-theta
// estimator; for multi-theta estimators the helper can be
// called per parameter with the per-parameter `psi_a` slice).
//
// `M_inv` is the inverse Jacobian of the moment condition at
// the population theta, supplied by the caller. For the
// DML scalar case `M_inv = 1 / mean(psi_a)` (a 1x1 matrix),
// which reduces the variance formula to
// `(1 / mean(psi_a)^2) * mean(psi^2) / n` for HC0 (the
// standard DML sandwich). Callers that want a custom
// scaling (for finite-sample corrections, design-matrix
// conditioning, etc.) can pass any positive-definite 1x1
// matrix; the formulas below only inspect `M_inv[0, 0]`
// for the scalar case.
//
// The HC2 / HC3 leverage (v0.88.0):
//   A leverage is a diagonal entry of a hat (projection)
//   matrix -- `h_ii = x_i' (X'X)^{-1} x_i` -- and always
//   satisfies `0 <= h_ii < 1`. The moment inverted here,
//   `E[psi_a * psi(theta)] = 0`, is a single-parameter
//   MEAN moment, so the regression implicit in it is a
//   mean regression: an intercept-only design with equal
//   per-observation weights. Its projection matrix is
//   `(1 / n) * J`, whose diagonal is constant:
//   `h_ii = 1 / n_obs` for every observation. HC2 then
//   divides every term by `(1 - 1/n) = (n-1)/n`, i.e.
//   HC2 == HC1 exactly, and HC3 divides by `((n-1)/n)^2`,
//   i.e. HC3 == HC1^2 / HC0 exactly. Both identities are
//   pinned by `expand_v088_test.mbt`.
//
//   v0.79.0 - v0.87.0 used `h_ii = psi_a[i] * M_inv[0,0]
//   * psi_a[i]` instead. That quantity is not a hat-matrix
//   diagonal in any sense, and with the package convention
//   `M_inv = [[1 / mean(psi_a)]]` and `mean(psi_a) < 0`
//   (the usual case, since `psi_a` is typically a negative
//   score row) it comes out NEGATIVE, so `1 - h_ii > 1`
//   and HC2 / HC3 SHRANK rather than widened -- the
//   opposite of MacKinnon (2012). v0.88.0 replaces it with
//   `1 / n_obs`; HC0 and HC1 are unaffected.
//
// The `psi_a[i]` in the accumulator, and the second 1/n
// (v0.91.0):
//   Through v0.90.0 every function in this file accumulated
//   `sum_i (psi_a[i] * psi[i])^2` and returned
//   `M_inv^2 * acc / n`. Two independent errors:
//
//   1. The `psi_a[i]` factor is not part of the moment.
//      `var_est.mbt` defines the package's estimating function
//      as `f(theta) = E[theta * psi_a + psi_b]`, a MEAN
//      moment -- its implicit regressor is the constant 1, so
//      the per-observation quadratic form is `psi[i]^2`, with
//      no `psi_a` weight. For an estimator with a constant
//      `psi_a = c` the shipped form gave
//      `(1/c^2) * c^2 * sum psi^2 / n = sum psi^2 / n`, i.e.
//      the `c^2` cancelled and the `psi_a` factor was a
//      no-op for every constant-`psi_a` estimator (IRM / APO
//      / SSM / CVAR / DID ATT) while re-weighting the
//      non-constant ones (PLR / PLPR / IIVM / PLIV) by the
//      data-dependent ratio
//      `sum (psi_a psi)^2 / sum psi^2` (0.229 on the
//      v0.90.0 PLR DGP -- a SHRINK there; the sign of this
//      factor is data, not formula, which is the whole
//      problem with having it in a variance at all).
//
//   2. `M_inv^2 * acc / n` is the variance of
//      `sqrt(n) * (theta_hat - theta)`, not of
//      `(theta_hat - theta)`. `var_est` returns the latter:
//      `sigma2 = mean(psi^2) / (J^2 * n) = M_inv^2 *
//      sum psi^2 / n^2`. The shipped form was missing the
//      outer `1 / n`, so it was `n` times too large in the
//      variance (`sqrt(n)` times too large in the SE) for
//      EVERY estimator, constant-`psi_a` or not.
//
//   v0.91.0 fixes both: the accumulator is `sum_i psi[i]^2`
//   and the return is `M_inv^2 * acc / n / n`. The payoff is
//   the invariant `se() == sandwich_se(HC0)` to floating-point
//   tolerance for EVERY estimator -- `se()` (i.e. `var_est`)
//   was always the reference and is unchanged by this change.
//   Because the cluster estimator carries the same missing
//   `1 / n` in its meat, it moves by the same factor, so
//   "all-singleton clusters == IID HC0 == se()" still holds
//   exactly. All the v0.88.0 leverage identities
//   (`HC1 == HC0 * n/(n-1)`, `HC2 == HC1`,
//   `HC3 == HC1^2 / HC0`) are scale-invariant and are
//   unaffected.
//
// All helpers in this file raise on malformed inputs via the
// shared `check(...)` precondition (the same convention as
// every other free function in this package). HC2 / HC3
// keep the `1.0e-10` divisor clip as a finiteness
// safeguard; with `h_ii = 1 / n_obs` it can only engage at
// `n_obs <= 1` (the typical `statsmodels` / `car`
// degenerate-input guard).

// ---------------------------------------------------------------------------
// SandwichKind enum
// ---------------------------------------------------------------------------

///|
/// Choice of sandwich estimator. The four cases correspond
/// to the Huber-White heteroskedasticity-consistent (HC)
/// family; the IID / cluster-robust choice is selected at
/// the function call site rather than via this enum because
/// the cluster variant has a different signature
/// (per-cluster sums + jackknife correction).
pub enum SandwichKind {
  /// Classical sandwich (Huber 1967, White 1980). No
  /// finite-sample correction.
  HC0
  /// HC0 * n / (n - k). The standard Stata
  /// `, robust` correction; matches `statsmodels.OLS`
  /// `cov_type='HC1'`.
  HC1
  /// Divide by `(1 - h_ii)` per observation, with
  /// `h_ii = 1 / n_obs` the mean-regression leverage.
  /// Reduces bias of the squared-residual HC0 estimator on
  /// high-leverage rows (MacKinnon 2012 sec 5.4). Equals
  /// HC1 for this mean-moment family.
  HC2
  /// Divide by `(1 - h_ii)^2` per observation (same
  /// `h_ii = 1 / n_obs`). The "jackknife" variant
  /// (MacKinnon 2012 sec 5.4); widens the confidence
  /// interval most aggressively.
  HC3
} derive(Debug)

///|
pub extend SandwichKind with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn SandwichKind::to_string(self : SandwichKind) -> String {
  match self {
    HC0 => "HC0"
    HC1 => "HC1"
    HC2 => "HC2"
    HC3 => "HC3"
  }
}

///|
/// `HC0` constructor (factory wrapper). Returns the
/// `SandwichKind::HC0` variant so callers don't need to
/// reach into the enum's private constructors.
pub fn SandwichKind::hc0() -> SandwichKind {
  HC0
}

///|
/// `HC1` constructor (factory wrapper).
pub fn SandwichKind::hc1() -> SandwichKind {
  HC1
}

///|
/// `HC2` constructor (factory wrapper).
pub fn SandwichKind::hc2() -> SandwichKind {
  HC2
}

///|
/// `HC3` constructor (factory wrapper).
pub fn SandwichKind::hc3() -> SandwichKind {
  HC3
}

// ---------------------------------------------------------------------------
// Per-observation score evaluation (single source of truth)
// ---------------------------------------------------------------------------

///|
/// Evaluate the per-observation estimating-function score at
/// `coef`, for the package convention documented in `var_est.mbt`:
///
///     psi[i] = coef * psi_a[i] + psi_b[i]
///
/// i.e. the score of `f(theta) = E[theta * psi_a + psi_b]`, whose
/// root is `theta_hat = -mean(psi_b) / mean(psi_a)` and whose
/// Jacobian is `J = d f / d theta = mean(psi_a)`. `M_inv = 1 / J`
/// (the `[[1 / mean(psi_a)]]` every sandwich method builds) is
/// consistent with exactly this convention.
///
/// Added in v0.90.0. v0.64.0 - v0.89.0 built the score inline in 13
/// places as `psi_a[i] + coef * psi_b[i]` -- the roles of `psi_a`
/// (the Jacobian / coefficient row) and `psi_b` (the offset) were
/// swapped, so the sandwich and multiplier-bootstrap families
/// evaluated `g(theta) = E[psi_a + theta * psi_b]`, a DIFFERENT
/// function whose root `-E[psi_a] / E[psi_b]` is not `theta_hat`.
/// On a fixed DGP the resulting `sandwich_se(HC0)` differed from
/// the analytic `se()` by three orders of magnitude. Thirteen inline
/// copies of one algebraic expression will drift, so the expression
/// now lives here and every caller routes through it.
///
/// `psi_a` and `psi_b` must share the same non-zero length; the call
/// aborts via `require(...)` otherwise. Returns a fresh
/// `Array[Double]` of that length.
pub fn psi_at(
  coef : Double,
  psi_a : Array[Double],
  psi_b : Array[Double],
) -> Array[Double] {
  try {
    require(psi_a.length() == psi_b.length())
    require(psi_a.length() >= 1)
    let n = psi_a.length()
    let psi : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      psi[i] = coef * psi_a[i] + psi_b[i]
    }
    psi
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

// ---------------------------------------------------------------------------
// Scalar sandwich variances
// ---------------------------------------------------------------------------

///|
/// HC0 (classical Huber-White) sandwich variance for a
/// scalar DML estimator:
///
///     var = M_inv[0,0]^2 * sum_i psi[i]^2 / n^2
///         = M_inv[0,0]^2 * mean_i psi[i]^2 / n
///
/// `psi[i]` is the per-observation influence-function
/// residual at the fitted `theta` (`psi_at(coef, psi_a,
/// psi_b)`), `M_inv` is the inverse Jacobian (a 1x1 matrix
/// for the scalar case; the function only inspects
/// `M_inv[0, 0]`), and `n_obs` is the sample size.
///
/// The formula is `var_est`'s `sigma2` (see `var_est.mbt`):
/// the DML moment is a MEAN moment, so its meat is
/// `E[psi psi']`, and the root has `var = E[psi psi'] / (J^2
/// * n)`. There is deliberately NO `psi_a[i]` factor: the
/// moment `E[theta * psi_a + psi_b]` is inverted as a
/// regression on the constant 1, not on `psi_a`. v0.90.0 and
/// earlier accumulated `sum_i (psi_a[i] * psi[i])^2 / n`,
/// which is the variance of `sqrt(n) * (theta_hat - theta)`
/// with a spurious regressor weight; `se()` is unchanged and
/// is the reference for every number here.
///
/// Preconditions:
///   - `psi_a.length() == psi.length() == n_obs`.
///   - `M_inv.rows() == 1` and `M_inv.cols() == 1`
///     (scalar Jacobian inverse).
///   - `n_obs >= 1`.
///   - `n_params >= 1` (the n-k finite-sample correction
///     in HC1 / HC2 / HC3 needs a positive `n - k`).
///
/// On success returns the scalar variance. Aborts via
/// `PreconditionError` on malformed input.
pub fn sandwich_variance_hc0(
  psi_a : Array[Double],
  psi : Array[Double],
  m_inv : Matrix,
  n_obs : Int,
  n_params : Int,
) -> Double {
  try {
    require(psi_a.length() == psi.length())
    require(psi_a.length() == n_obs)
    require(m_inv.rows() == 1 && m_inv.cols() == 1)
    require(n_obs >= 1)
    require(n_params >= 1)
    let m = m_inv.get(0, 0)
    let mut acc = 0.0
    let mut acc_c = 0.0
    let n_d = n_obs.to_double()
    for i = 0; i < n_obs; i = i + 1 {
      let v = psi[i]
      // Kahan-compensated sum of psi^2 (the meat of the
      // mean moment; v0.91.0 dropped the `psi_a[i]` factor).
      let y = v * v - acc_c
      let t = acc + y
      acc_c = t - acc - y
      acc = t
    }
    let m2 = m * m
    m2 * acc / n_d / n_d
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// HC1 sandwich variance: HC0 * n / (n - k) where `k =
/// n_params`. The classic finite-sample correction (the
/// Stata `, robust` default; matches `statsmodels.OLS`
/// `cov_type='HC1'`).
///
/// Preconditions match `sandwich_variance_hc0` plus
/// `n_obs > n_params` (the `(n - k)` divisor must be
/// positive). Aborts on `n_obs <= n_params` because the
/// finite-sample correction becomes undefined there.
pub fn sandwich_variance_hc1(
  psi_a : Array[Double],
  psi : Array[Double],
  m_inv : Matrix,
  n_obs : Int,
  n_params : Int,
) -> Double {
  try {
    require(psi_a.length() == psi.length())
    require(psi_a.length() == n_obs)
    require(m_inv.rows() == 1 && m_inv.cols() == 1)
    require(n_obs >= 1)
    require(n_params >= 1)
    require(n_obs > n_params)
    let v0 = sandwich_variance_hc0(psi_a, psi, m_inv, n_obs, n_params)
    let n_d = n_obs.to_double()
    let k_d = n_params.to_double()
    let scale = n_d / (n_d - k_d)
    v0 * scale
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// HC2 sandwich variance: per-observation leverage
/// correction `(1 - h_ii)` on the squared score
/// (MacKinnon 2012 sec 5.4):
///
///     var = M_inv[0,0]^2 * sum_i (psi[i]^2 / (1 - h_ii)) / n^2
///
/// where `h_ii` is the diagonal of the projection matrix of
/// the mean regression implicit in the moment
/// `E[theta * psi_a + psi_b] = 0`. That design is
/// intercept-only with equal weights, so its projection is
/// `(1 / n) * J` and `h_ii = 1 / n_obs` on every row.
/// Consequently `var(HC2) == var(HC0) * n / (n - 1)`, i.e. HC2
/// is exactly HC1 for this family.
///
/// v0.79.0 - v0.87.0 used `h_ii = psi_a[i] * M_inv[0,0] *
/// psi_a[i]`, which is not a projection-matrix diagonal and
/// goes negative under `M_inv = [[1 / mean(psi_a)]]` with
/// `mean(psi_a) < 0`, shrinking the variance instead of
/// widening it. The divisor is still clipped to `1.0e-10` so
/// HC2 stays finite on the degenerate `n_obs == 1` input.
///
/// Preconditions match `sandwich_variance_hc0`. Aborts on
/// malformed input.
pub fn sandwich_variance_hc2(
  psi_a : Array[Double],
  psi : Array[Double],
  m_inv : Matrix,
  n_obs : Int,
  n_params : Int,
) -> Double {
  try {
    require(psi_a.length() == psi.length())
    require(psi_a.length() == n_obs)
    require(m_inv.rows() == 1 && m_inv.cols() == 1)
    require(n_obs >= 1)
    require(n_params >= 1)
    let m = m_inv.get(0, 0)
    let eps : Double = 1.0e-10
    let n_d = n_obs.to_double()
    // v0.88.0: constant mean-regression leverage (see the file
    // header). Replaces the old signed `psi_a[i]^2 * M_inv`
    // "leverage", which is not a hat-matrix diagonal.
    let h_ii = 1.0 / n_d
    let denom = if 1.0 - h_ii < eps { eps } else { 1.0 - h_ii }
    let mut acc = 0.0
    let mut acc_c = 0.0
    for i = 0; i < n_obs; i = i + 1 {
      let v = psi[i]
      let term = v * v / denom
      let y = term - acc_c
      let t = acc + y
      acc_c = t - acc - y
      acc = t
    }
    let m2 = m * m
    m2 * acc / n_d / n_d
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// HC3 sandwich variance: the jackknife-style HC3
/// correction that divides by `(1 - h_ii)^2` per
/// observation. Otherwise identical to HC2 (same leverage
/// computation, same precondition set, same degenerate-input
/// safeguard). Under `h_ii = 1 / n_obs` this means
/// `var(HC3) == var(HC0) * (n / (n - 1))^2`, i.e. exactly
/// `HC1^2 / HC0`.
///
/// Preconditions match `sandwich_variance_hc0`. Aborts on
/// malformed input.
pub fn sandwich_variance_hc3(
  psi_a : Array[Double],
  psi : Array[Double],
  m_inv : Matrix,
  n_obs : Int,
  n_params : Int,
) -> Double {
  try {
    require(psi_a.length() == psi.length())
    require(psi_a.length() == n_obs)
    require(m_inv.rows() == 1 && m_inv.cols() == 1)
    require(n_obs >= 1)
    require(n_params >= 1)
    let m = m_inv.get(0, 0)
    let eps : Double = 1.0e-10
    let n_d = n_obs.to_double()
    let h_ii = 1.0 / n_d
    let one_minus_h = if 1.0 - h_ii < eps { eps } else { 1.0 - h_ii }
    let denom = one_minus_h * one_minus_h
    let mut acc = 0.0
    let mut acc_c = 0.0
    for i = 0; i < n_obs; i = i + 1 {
      let v = psi[i]
      let term = v * v / denom
      let y = term - acc_c
      let t = acc + y
      acc_c = t - acc - y
      acc = t
    }
    let m2 = m * m
    m2 * acc / n_d / n_d
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

// ---------------------------------------------------------------------------
// Shared SandwichKind dispatch
// ---------------------------------------------------------------------------

///|
/// Shared `SandwichKind` dispatch: routes to the matching
/// `sandwich_variance_hc*` free function above and returns
/// the corresponding variance.
///
/// Added in v0.86.0 so the per-estimator `sandwich_se(kind)`
/// methods (`DoubleMLIIVM`, `DoubleMLPLIV`, `DoubleMLDID`,
/// `DoubleMLCVAR`, ...) share ONE dispatch rather than each
/// inlining the same four-arm `match`. The arithmetic is
/// identical to calling the matching `sandwich_variance_hc*`
/// function directly, so results are byte-identical to the
/// per-estimator inline dispatch.
///
/// Preconditions match the individual `sandwich_variance_hc*`
/// functions (notably `n_obs > n_params` for HC1). Aborts via
/// `PreconditionError` on malformed input.
pub fn sandwich_variance(
  kind : SandwichKind,
  psi_a : Array[Double],
  psi : Array[Double],
  m_inv : Matrix,
  n_obs : Int,
  n_params : Int,
) -> Double {
  match kind {
    HC0 => sandwich_variance_hc0(psi_a, psi, m_inv, n_obs, n_params)
    HC1 => sandwich_variance_hc1(psi_a, psi, m_inv, n_obs, n_params)
    HC2 => sandwich_variance_hc2(psi_a, psi, m_inv, n_obs, n_params)
    HC3 => sandwich_variance_hc3(psi_a, psi, m_inv, n_obs, n_params)
  }
}

// ---------------------------------------------------------------------------
// Cluster-robust sandwich
// ---------------------------------------------------------------------------

///|
/// Cluster-robust sandwich variance for a scalar DML
/// estimator (Arellano 1987, Cameron-Gelbach-Miller 2011):
///
///     S_c        = (sum_{i in c} psi[i])^2
///     var        = M_inv[0,0]^2 *
///                  (sum_c S_c * n_c / (n_c - 1)) / n^2
///
/// `cluster_ids[i]` is the 0-based cluster id of
/// observation `i`. All observations in the same cluster
/// share an id; `cluster_ids.length()` must equal
/// `psi_a.length()`. The number of clusters is
/// `1 + max(cluster_ids)`.
///
/// The `(n_c - 1)` jackknife correction (small-cluster
/// bias adjustment) is applied per cluster. When a cluster
/// has a single observation (`n_c == 1`) the corresponding
/// `(n_c - 1) == 0` divisor would blow up; we clip the
/// per-cluster correction to `n_c / max(n_c - 1, 1) == 1`
/// in that case so single-observation clusters contribute
/// their raw `S_c` without finite-sample correction (the
/// `statsmodels.cov_type='cluster'` convention).
///
/// The meat is `E[sum_c (sum_{i in c} psi[i])^2]`, estimated
/// as `sum_c S_c / n`, and the estimator is `sqrt(n) *
/// (theta_hat - theta) -> N(0, M_inv B M_inv')`, so the
/// returned VARIANCE of `theta_hat` carries the outer `1 / n`
/// as well -- hence the `n^2` divisor. With all-singleton
/// clusters `sum_c S_c == sum_i psi[i]^2` and the formula
/// collapses to `sandwich_variance_hc0` exactly, i.e. to
/// `se()`. (v0.90.0 and earlier divided by `n` once and
/// summed `psi_a[i] * psi[i]` within the cluster; both are
/// corrected here -- see the file header.)
///
/// Preconditions:
///   - `psi_a.length() == psi.length() == cluster_ids.length()`.
///   - `M_inv.rows() == 1` and `M_inv.cols() == 1`.
///   - `cluster_ids[i] >= 0` for all `i`.
///
/// Returns the scalar cluster-robust variance. Aborts on
/// malformed input.
pub fn cluster_sandwich_variance(
  psi_a : Array[Double],
  psi : Array[Double],
  m_inv : Matrix,
  cluster_ids : Array[Int],
  n_params : Int,
) -> Double {
  try {
    require(psi_a.length() == psi.length())
    require(psi_a.length() == cluster_ids.length())
    require(m_inv.rows() == 1 && m_inv.cols() == 1)
    require(n_params >= 1)
    let n = psi_a.length()
    require(n >= 1)
    let mut max_cid = -1
    for i = 0; i < n; i = i + 1 {
      let c = cluster_ids[i]
      require(c >= 0)
      if c > max_cid {
        max_cid = c
      }
    }
    require(max_cid >= 0)
    let n_clusters = max_cid + 1
    // Per-cluster sums of psi[i] and per-cluster sizes.
    let cluster_sum : Array[Double] = Array::make(n_clusters, 0.0)
    let cluster_size : Array[Int] = Array::make(n_clusters, 0)
    for i = 0; i < n; i = i + 1 {
      let c = cluster_ids[i]
      cluster_sum[c] = cluster_sum[c] + psi[i]
      cluster_size[c] = cluster_size[c] + 1
    }
    let mut acc = 0.0
    let mut acc_c = 0.0
    for c = 0; c < n_clusters; c = c + 1 {
      let nc = cluster_size[c]
      // Empty cluster: skip (no contribution to var).
      if nc == 0 {
        continue
      }
      // Single-observation cluster: jackknife correction would
      // divide by zero; clip to 1 (no finite-sample correction)
      // so the cluster's S_c is added raw.
      let scale = if nc <= 1 {
        1.0
      } else {
        nc.to_double() / (nc.to_double() - 1.0)
      }
      let sc = cluster_sum[c]
      let term = sc * sc * scale
      let y = term - acc_c
      let t = acc + y
      acc_c = t - acc - y
      acc = t
    }
    let m = m_inv.get(0, 0)
    let m2 = m * m
    let n_d = n.to_double()
    m2 * acc / n_d / n_d
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

// ---------------------------------------------------------------------------
// Bias-correction helper
// ---------------------------------------------------------------------------

///|
/// Generic scalar add-a-bias helper:
///
///     theta_corrected = theta_hat + mean(bias_per_obs)
///
/// where `bias_per_obs[i]` is a per-observation bias term
/// supplied by the caller.
///
/// THIS IS NOT A BIAS CORRECTION FOR A DML ESTIMATE, and
/// nothing in this package calls it that way any more
/// (v0.91.0). Two facts make score-based bias correction
/// vacuous for these estimators:
///
///   1. Under `var_est.mbt`'s convention the estimating
///      function is `f(theta) = E[theta * psi_a + psi_b]`
///      and `theta_hat` is its root, so
///      `mean(f(theta_hat)) = mean(coef * psi_a + psi_b) = 0`
///      IDENTICALLY -- the estimating function is orthogonal
///      by construction, and any "correction" built from the
///      score at the estimate has mean exactly zero.
///   2. Through v0.90.0 every `bias_corrected_coef` passed
///      `bias_per_obs[i] = psi_b[i] - coef * psi_a[i]`,
///      which is the score at `-coef`, not at `coef`. Its
///      mean is `mean_b + coef * mean_a = -2 * coef * mean_a`,
///      i.e. twice the estimate, so the accessor returned
///      `3 * coef` (algebraically, for every estimator). That
///      is not a bias estimate; it is a guaranteed-wrong
///      number. All twelve `bias_corrected_coef` methods are
///      now documented no-ops that return `coef` unchanged
///      (see e.g. `DoubleMLIRM::bias_corrected_coef`).
///
/// The helper is retained ONLY for a caller who has a
/// genuinely exogenous bias vector from outside the DML
/// machinery (an analytic finite-sample correction, say).
/// Passing the DML score here cannot correct anything, and
/// v0.90.0 - v0.91.0 shipped documentation that claimed the
/// opposite; do not repeat it.
///
/// Preconditions:
///   - `bias_per_obs.length() >= 1`.
///
/// Returns the corrected scalar theta. Aborts on empty
/// `bias_per_obs`.
pub fn bias_corrected_theta(
  theta_hat : Double,
  bias_per_obs : Array[Double],
) -> Double {
  try {
    require(bias_per_obs.length() >= 1)
    let n_d = bias_per_obs.length().to_double()
    let mut acc = 0.0
    let mut acc_c = 0.0
    for i = 0; i < bias_per_obs.length(); i = i + 1 {
      let v = bias_per_obs[i]
      let y = v - acc_c
      let t = acc + y
      acc_c = t - acc - y
      acc = t
    }
    theta_hat + acc / n_d
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
