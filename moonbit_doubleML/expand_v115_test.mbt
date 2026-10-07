// v0.115.0 -- the CCT second bandwidth `b` and bias-corrected inference.
//
// # What was missing
//
// v0.110.0 gave RDD an MSE-optimal bandwidth for the POINT estimate.
// What it did not have was `rdrobust`'s second bandwidth `b` -- and `b`
// is not a refinement of the first, it is the other half of the CCT
// procedure. `bwselect = "CCT"` (rdrobust's DEFAULT) computes BOTH `h`
// and `b`; `rdrobust` then subtracts the estimated bias from the point
// estimate and inflates the standard error to pay for having done so.
// The package had the estimation bandwidth only, which the v0.113.0
// CHANGELOG already called the largest remaining gap. It was correct, and
// it was a whole missing STAGE rather than a missing monomial.
//
// # The reason the two bandwidths differ at all
//
// A local polynomial of degree `j` has leading bias `O(h^(j+1))`, so the
// `j`-order MSE criterion has a `b^(2(j+1))` variance term. `rdrobust`
// estimates the point with `p = 1` (local linear) and the bias with
// `q = 2` (local quadratic), so the two criteria being minimised are
// genuinely different functions and `b` is not a rescaling of `h`.
//
// # The identity this release is built on
//
//     tau_bc = tau_cl - bias
//            = [xi_p(h)_r - xi_p(h)_l] - [(xi_p(h)_r - xi_q(b)_r)
//                                         - (xi_p(h)_l - xi_q(b)_l)]
//            = xi_q(b)_r - xi_q(b)_l
//
// The whole apparatus telescopes to one q-order fit per side. That is
// not a shortcut -- it is why no joint covariance across the two
// bandwidths is needed, and it is directly checkable from outside
// because `tau_bc_collapsed` computes the right-hand side.
//
// # What these gates do NOT claim
//
// The point estimate is implemented. The variance is NOT: `rdrobust`'s
// procedure (iii) is "bias-corrected with ROBUST standard errors" and its
// default robust estimator is `vce = "nn"`, nearest-neighbour matched
// residuals. This port implements that matching for the CRITERION
// (`bandwidth_sigma4`) but not for the VARIANCE. `tau_bc_se`
// returns the homoskedastic / `HC0` variance the package already had,
// applied to the q-order fits. It is a standard error for the
// bias-corrected estimator, not `rdrobust`'s robust one -- shipping it as
// procedure (iii) would be the v0.113 mistake again.
//
// # Every number asserted here was MEASURED first
//
// `_verify/probe_v115.mbt` printed the quantities before any of these
// assertions were written. Two claims made in the design were falsified
// by that probe and corrected in the source docs rather than in the
// assertions: the bias is NOT zero when `b == h` (it is a linear-vs-
// quadratic difference), and the long-way / collapsed routes differ by
// EXACTLY zero, not by 1e-12.

// ---------------------------------------------------------------------------
// DGP -- private to this file (MoonBit `fn` is file-scoped)
//
// A sharp RDD with a jump of `theta` plus a DELIBERATELY NONLINEAR
// `0.4 * u^2` term, matching `expand_v110_test.mbt`'s fixture. The
// nonlinearity is not decoration: the bias-correction stage exists
// precisely because a local-LINEAR fit is biased when the truth curves,
// so under a linear DGP the whole stage would be measuring zero and the
// gates below would be vacuous.
// ---------------------------------------------------------------------------

///|
fn v115_rdd_data(n : Int, theta : Double) -> DoubleMLRDDData {
  let x = Matrix::zeros(n, 1)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let score = Array::make(n, 0.0)
  let rng = chacha8_rng(31)
  let noise : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    noise[i] = rng.double()
  }
  for i = 0; i < n; i = i + 1 {
    let u = (i.to_double() + 0.5) / (n.to_double() / 2.0) - 1.0
    score[i] = u
    d[i] = if u >= 0.0 { 1.0 } else { 0.0 }
    y[i] = theta +
      0.7 * u +
      0.4 * u * u +
      theta * d[i] +
      0.1 * (noise[i] - 0.5) * 2.0
  }
  DoubleMLRDDData::new(x, y, d, score)
}

///|
/// The two data-driven bandwidths, plus the fitted point estimator at
/// `h`. Returned as a tuple because `DoubleMLRDD`'s fields are private
/// outside `rdd.mbt` -- the data has to be threaded through rather than
/// read back off a fitted model.
fn v115_stage(
  n : Int,
  theta : Double,
) -> (DoubleMLRDDData, Double, Double, DoubleMLRDD) {
  let data = v115_rdd_data(n, theta)
  let boot = DoubleMLRDD::new(data, bandwidth=1.0)
  let h = boot.optimal_bandwidth()
  let b = boot.optimal_bias_bandwidth()
  let est = DoubleMLRDD::new(data, bandwidth=h).fit()
  (data, h, b, est)
}

///|
/// The headline gate, and the one that would fail first if `order` were
/// not really reaching the criterion.
///
/// An ORDER-1 bias bandwidth minimises the order-1 MSE criterion -- which
/// is exactly the criterion `optimal_bandwidth` minimises. The two are
/// separate implementations (different functions, different loop bodies,
/// different call sites), so `==` here is a genuine cross-check between
/// two independent searches rather than a restatement.
///
/// Measured: 0.11249418871408631 for both, to the last bit.
test "v115_bias_bandwidth_order1_equals_the_point_bandwidth" {
  let data = v115_rdd_data(2000, 0.5)
  let boot = DoubleMLRDD::new(data, bandwidth=1.0)
  let h = boot.optimal_bandwidth()
  let b_order1 = boot.optimal_bias_bandwidth(q=1)
  assert_true(h == b_order1)
}

///|
/// The precondition that makes every other bias gate non-vacuous.
///
/// With the default `q = 2` the second bandwidth must NOT come back equal
/// to the point bandwidth, or the order-2 criterion was never actually
/// minimised and the bias-correction stage would be running at whatever
/// `h` happened to be. Measured ratio b/h is 0.907, so the gap is 9.3% --
/// comfortably outside any floating-point noise, and asserted as a
/// relative gap rather than `!=` so it cannot pass on a rounding
/// artefact.
///
/// This is the v0.113 lesson applied forward: `b := h` inside
/// `optimal_bias_bandwidth` would be an equivalent mutation that no
/// downstream assertion could see, so the suite pins the SEARCH.
test "v115_bias_bandwidth_differs_from_the_point_bandwidth" {
  let (_, h, b, _) = v115_stage(2000, 0.5)
  let rel = (b - h).abs() / h
  assert_true(rel > 0.05)
}

///|
/// `b` must actually MINIMISE the order-2 criterion, and `h` must
/// minimise the order-1 one -- i.e. each bandwidth is the minimiser of
/// ITS OWN criterion, not just "some grid point".
///
/// This is the property that makes the order argument mean anything. A
/// mutation that hardcodes `order = 1` inside `optimal_bias_bandwidth`
/// would return `h`, which the previous gate already rejects; a mutation
/// that evaluated the order-2 criterion but searched for a MAXIMUM would
/// return an endpoint, which this gate catches.
test "v115_each_bandwidth_minimises_its_own_order_criterion" {
  let data = v115_rdd_data(2000, 0.5)
  let boot = DoubleMLRDD::new(data, bandwidth=1.0)
  let h = boot.optimal_bandwidth()
  let b = boot.optimal_bias_bandwidth()
  // h is the order-1 minimiser
  assert_true(boot.bandwidth_mse(h, order=1) <= boot.bandwidth_mse(b, order=1))
  // b is the order-2 minimiser
  assert_true(boot.bandwidth_mse(b, order=2) <= boot.bandwidth_mse(h, order=2))
  // and the two criteria genuinely disagree about which is better, so
  // neither gate is a restatement of the other
  assert_true(boot.bandwidth_mse(b, order=2) < boot.bandwidth_mse(h, order=2))
}

///|
/// THE identity. The long way (`tau_bc`) and the collapsed
/// way (`tau_bc_collapsed`) must agree, because the algebra
/// says they are the same number.
///
/// Asserted with `==`, NOT a tolerance. That was measured, not assumed:
/// the gap is exactly 0 on this fixture (0.506690940304431 both ways).
/// It is a property of these magnitudes, not a theorem -- `a - (a - b)`
/// is not exactly `b` in general -- so if a future fixture breaks this,
/// relax THIS assertion and leave the algebra alone.
test "v115_bias_corrected_is_the_q_order_estimate" {
  let (_, _, b, est) = v115_stage(2000, 0.5)
  assert_true(est.tau_bc(b~) == est.tau_bc_collapsed(b~))
}

///|
/// The bias must be non-zero and must DIFFER between the two sides.
///
/// A single pooled bias number would satisfy "bias is non-zero" while
/// hiding the fact that `rdrobust` reports it per side (`bias` in the
/// return value is "estimated bias ... below and above the cutoff").
///
/// Measured: bias_l = -0.00745, bias_r = -0.01999 -- same sign, clearly
/// different magnitudes, which is what a jump plus curvature produces.
test "v115_bias_is_nonzero_and_side_asymmetric" {
  let (_, _, b, est) = v115_stage(2000, 0.5)
  let (bias_l, bias_r) = est.bias(b~)
  assert_true(bias_l != 0.0)
  assert_true(bias_r != 0.0)
  assert_true((bias_l - bias_r).abs() / (bias_l.abs() + bias_r.abs()) > 0.1)
}

///|
/// The bias-correction stage must actually MOVE the estimate. If
/// `tau_bc` returned the conventional estimate, every other
/// gate here would still pass -- the bias is non-zero, the identity
/// holds, `b != h` -- while the feature did nothing.
///
/// Measured: tau_cl = 0.49415, tau_bc = 0.50669. The shift is 1.3% of the
/// conventional estimate, far outside noise.
test "v115_bias_correction_moves_the_estimate" {
  let (_, _, b, est) = v115_stage(2000, 0.5)
  let tau_cl = est.coef()
  let corrected = est.tau_bc(b~)
  assert_true((corrected - tau_cl).abs() / tau_cl.abs() > 0.005)
}

///|
/// `rho` must actually rescale: `b = h / rho`. Pinned at `rho = 1`, `b`
/// and `h` are the same number; at `rho = 2` the bias bandwidth is half
/// of `h`. Without this, `rho` is a parameter nothing reads.
test "v115_rho_rescales_the_bias_bandwidth" {
  let (_, _, _, est) = v115_stage(2000, 0.5)
  let h = est.bandwidth
  let at_rho1 = est.tau_bc(b=0.0, rho=1.0)
  let at_rho2 = est.tau_bc(b=0.0, rho=2.0)
  let at_half = est.tau_bc_collapsed(b=h / 2.0)
  // rho is read: changing it changes the answer
  assert_true(at_rho1 != at_rho2)
  // and the two routes agree at rho = 2 as well, so the rescaling is not
  // a separate code path with its own arithmetic
  assert_true(at_rho2 == at_half)
}

///|
/// The empirical signature of CCT: correcting the bias COSTS variance.
///
/// Measured: se_conv = 0.0013022, bc_se = 0.0020109 -- a 54% inflation.
/// This is the whole point of procedure (iii) existing: the bias-
/// corrected estimator is more honest about the point AND less precise,
/// and a bias correction that did not inflate the standard error would
/// be a strictly free lunch, which is the signature of a mistake rather
/// than a result.
///
/// Direction only, no magnitude: this asserts the SIGN of the effect,
/// which is what the mathematics guarantees. Pinning the ratio to a
/// narrow band would be a bet on this fixture's noise draw.
test "v115_tau_bc_se_is_larger_than_the_conventional_se" {
  let (_, _, b, est) = v115_stage(2000, 0.5)
  assert_true(est.tau_bc_se(b~) > est.se())
}

///|
/// Pinning that the block is not accidental: three independent draws of
/// the nonlinear fixture must each produce a non-zero, side-asymmetric
/// bias and a positive `b`. A stage that only worked on one noise draw
/// would be a fixture-specific accident.
test "v115_bias_stage_holds_across_draws" {
  for k = 0; k < 3; k = k + 1 {
    let (_, h, b, est) = v115_stage(1500 + 250 * k, 0.3 + 0.2 * k.to_double())
    let (bias_l, bias_r) = est.bias(b~)
    assert_true(bias_l != 0.0)
    assert_true(bias_r != 0.0)
    assert_true((bias_l - bias_r).abs() / (bias_l.abs() + bias_r.abs()) > 0.05)
    assert_true(b > 0.0)
    assert_true(b != h)
    assert_true(est.tau_bc_se(b~) > 0.0)
  }
}

///|
/// A NOISELESS DGP whose truth is EXACTLY quadratic on each side, but
/// with DIFFERENT curvature left and right, so the `u^2` column is tested
/// STRUCTURALLY rather than through a downstream number.
///
/// If the outcome is exactly `jump*D + a*u + c(u)*u^2` with `c` constant
/// per side, a local QUADRATIC fit is an exact model on both sides and
/// must recover the jump to near machine precision at any bandwidth wide
/// enough for four parameters. A local LINEAR fit cannot.
///
/// # Why the curvature MUST be asymmetric -- the first version failed
///
/// The first attempt used a single symmetric `0.4*u^2` and the order-1
/// fit recovered the jump to 8e-11, i.e. BETTER than the order-2 fit's
/// 4.1e-10. That is not a bug, it is the algebra: for a local linear fit
/// of `c*s^2` evaluated at the window edge the intercept bias is exactly
/// `-0.1*c*h^2` on BOTH sides, so the two biases CANCEL in the
/// difference `xi_r - xi_l` and the RD estimate comes out nearly
/// unbiased.
///
/// The symmetric fixture therefore could not tell order 1 from order 2 at
/// all -- a comparison blind to the thing it was built to detect. This
/// is the v0.110 lesson ("a comparison that cannot see the change cannot
/// testify about it") arriving one level down, in the design of the
/// FIXTURE rather than the assertion.
///
/// With `c_left = 0.4` and `c_right = 0.9` the two side biases differ, so
/// the linear route is off by `0.1*(c_left - c_right)*h^2` and the
/// quadratic route still contains the truth exactly.
fn v115_exact_quadratic(n : Int, jump : Double) -> DoubleMLRDDData {
  let x = Matrix::zeros(n, 1)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let score = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u = (i.to_double() + 0.5) / (n.to_double() / 2.0) - 1.0
    score[i] = u
    d[i] = if u >= 0.0 { 1.0 } else { 0.0 }
    let c = if u >= 0.0 { 0.9 } else { 0.4 }
    y[i] = jump * d[i] + 0.5 * u + c * u * u
  }
  DoubleMLRDDData::new(x, y, d, score)
}

///|
/// The `u^2` column exists, and the order-2 fit uses it.
///
/// Measured on the asymmetric DGP: the order-2 route recovers the jump to
/// ~4e-10 (pure conditioning error -- the design is a Vandermonde with a
/// rank-deficient zero covariate column, so this is the floor, not the
/// algorithm), while the order-1 route is off by ~7e-4. The two
/// thresholds are separated by three orders of magnitude, so neither can
/// be tripped by the other's error.
///
/// A mutation that dropped `u^2` from the design while still evaluating a
/// quadratic prediction would break the first assertion. A mutation that
/// degraded BOTH routes to linear would break both. A mutation that
/// ignored `q` would make them equal, which the second assertion and
/// `v115_order_two_differs_from_order_one` both catch.
test "v115_quadratic_fit_recovers_an_exactly_quadratic_dgp" {
  let data = v115_exact_quadratic(2000, 0.5)
  let b = 0.12
  let est = DoubleMLRDD::new(data, bandwidth=b).fit()
  let quadratic = est.tau_bc_collapsed(b~)
  let linear = est.tau_bc_collapsed(b~, q=1)
  // exact model class contains the truth: only fp error is left
  assert_true((quadratic - 0.5).abs() < 1.0e-8)
  // and the linear route is measurably worse, so the first assertion is
  // not holding for a reason unrelated to polynomial order
  assert_true((linear - 0.5).abs() > 1.0e-4)
}

///|
/// The two orders must give materially different answers on the same
/// data and bandwidth. Without this, an implementation that ignored
/// `q` everywhere would still satisfy the exact-recovery gate above
/// (since `q = 2` would just mean "whatever the code always does").
test "v115_order_two_differs_from_order_one" {
  let data = v115_rdd_data(2000, 0.5)
  let b = 0.102
  let est = DoubleMLRDD::new(data, bandwidth=b).fit()
  let q1 = est.tau_bc_collapsed(b~, q=1)
  let q2 = est.tau_bc_collapsed(b~, q=2)
  assert_true((q2 - q1).abs() / (1.0e-12 + q1.abs()) > 0.005)
}

///|
/// Kills mutation M3: the criterion's variance exponent is
/// `2 * (order + 1)`, so DOUBLING the bandwidth must multiply the variance
/// term by `2^4 = 16` at order 1 and `2^6 = 64` at order 2.
///
/// M3 hardcoded the exponent to `b^4` for every order -- the order-1
/// value, which is what the code used before `order` existed. It SURVIVED
/// every other gate in this file: the search still minimises whatever
/// criterion it is handed, the bias is still non-zero, `b` still differs
/// from `h`, and the collapse identity still holds. Nothing could see it
/// because the exponent only enters the criterion's VARIANCE half, and
/// that half was not separately observable from outside.
///
/// Asserted as a ratio, so it pins the EXPONENT rather than the
/// magnitude: `sigma4` and `n` cancel, and no noise draw can move it.
test "v115_variance_term_doubles_by_the_order_exponent" {
  let data = v115_rdd_data(2000, 0.5)
  let boot = DoubleMLRDD::new(data, bandwidth=1.0)
  let h_pilot = boot.pilot_bandwidth()
  let wide = 2.0 * h_pilot
  let r1 = boot.bandwidth_variance_term(wide, order=1) /
    boot.bandwidth_variance_term(h_pilot, order=1)
  let r2 = boot.bandwidth_variance_term(wide, order=2) /
    boot.bandwidth_variance_term(h_pilot, order=2)
  assert_true((r1 - 16.0).abs() < 1.0e-9)
  assert_true((r2 - 64.0).abs() < 1.0e-9)
  // and the two orders scale DIFFERENTLY, which is the whole point of
  // running two bandwidth searches rather than rescaling one
  assert_true((r2 / r1 - 4.0).abs() < 1.0e-9)
}

///|
/// Kills mutation M5: `Sigma^4` must be built from residuals of the
/// polynomial that was actually FIT.
///
/// On `v115_exact_quadratic` the order-2 fit is an exact model, so its
/// residuals are zero and `sigma4` -- a mean of squared residual
/// DIFFERENCES -- is zero too. M5 evaluated a TRUNCATED (linear)
/// prediction while still fitting a quadratic, leaving a residual of
/// order `c*h^2` and a `sigma4` of order 1e-6 instead.
///
/// # The threshold is measured, and the floor is not zero
///
/// Measured on this fixture: `sigma4(order=2) = 3.18e-18`, not 0. The
/// design is a Vandermonde, so the fit is exact only to its conditioning,
/// and the residual differences are ~1e-9 with a square of ~1e-18.
///
/// The first version of this gate asserted `< 1e-20` and FAILED. That was
/// a guessed floor rather than a measured one.
///
/// Worth recording: dropping the rank-deficient all-zero covariate column
/// changes `sigma4(order=2)` by nothing at all (3.1775896103510304e-18
/// either way), so the floor is purely the Vandermonde conditioning and
/// not the zero column. That also means the port's standard
/// `Matrix::zeros(n, 1)` fixtures do not perturb this measurement.
///
/// The two thresholds are separated by 12 orders of magnitude, so this is
/// not a tuning choice. Nothing else in this file sees M5: `sigma4` only
/// feeds the bandwidth search, and the search still returns a valid
/// minimiser of a slightly different criterion.
test "v115_sigma4_is_zero_when_the_fit_is_exact" {
  let data = v115_exact_quadratic(2000, 0.5)
  let boot = DoubleMLRDD::new(data, bandwidth=1.0)
  // order 2 contains the truth exactly, to its conditioning
  assert_true(boot.bandwidth_sigma4(order=2) < 1.0e-14)
  // order 1 does not, because the truth curves: measured 4.37e-7
  assert_true(boot.bandwidth_sigma4(order=1) > 1.0e-10)
}
