///|
/// v0.105.0: LPLR's two scores were an inert parameter.
///
/// `DoubleMLLPLR::new` accepted `score="instrument"` and `require`d
/// that it be one of the two upstream names. The field was then
/// stored on the struct, copied into the fitted result, hashed into
/// nothing, and -- critically -- never read. `fit` unconditionally
/// ran the nuisance_space path. `examples/lplr` printed both scores
/// and they agreed to the last bit, which looks like an algebraic
/// identity and is actually an unimplemented branch.
///
/// Upstream `DoubleMLLPLR` branches in four places
/// (`plm/lplr.py`):
///
///   - `_fit_nuisance`      :244-252  `ml_m`'s TRAINING SET differs
///                                        (`Y == 0` subsample vs full)
///   - `_compute_score`     :521-530  entirely different formula
///   - `_compute_score_deriv` :532-540 entirely different formula
///   - `_nuisance_tuning`   :450-455  tuning subset differs
///
/// The tests below pin the two load-bearing pieces -- the score
/// formulas -- against literal vectors. That is the sharp shape
/// available here: these are pure functions of hand-fed inputs, so
/// the expected values are arithmetic, not statistics. There is no
/// Monte-Carlo error to tune a tolerance around, and the tolerance
/// only has to absorb the last-ulp difference between MoonBit's
/// `@math.exp`/`expit` and CPython's `math.exp`.
///
/// The same input vectors, and the Python that produced them, live
/// in `_verify/zz_probe_lplr_exact.py` -- it was a probe and is
/// deleted; the literals below are the durable artefact.

///|
/// One shared input vector for both branches.
///
/// `m_pred` is deliberately NOT equal to `a_pred` (0.28/0.66/0.24/
/// 0.51 vs 0.30/0.70/0.20/0.55). Before v0.105.0 `fit` wrote
/// `m_pred = a_pred`, so pinning them apart here is what makes the
/// alias a test failure rather than an invisible convenience.
///
/// `d = 0` on rows 0 and 3, which pins the `d`-factor out of both
/// score derivatives (they must be exactly zero there).
fn v105_lplr_inputs() -> (
  Double,
  Array[Double],
  Array[Double],
  Array[Double],
  Array[Double],
  Array[Double],
  Double,
) {
  let d = [0.0, 1.0, 1.0, 0.0]
  let y = [0.0, 1.0, 0.0, 1.0]
  let t_pred = [0.4, -0.2, 1.1, -0.9]
  let a_pred = [0.3, 0.7, 0.2, 0.55]
  let m_pred = [0.28, 0.66, 0.24, 0.51]
  (0.75, d, y, t_pred, a_pred, m_pred, 0.45)
}

///|
/// `nuisance_space` score, upstream `lplr.py:522-524`:
///
///   score_1 = y * exp(-theta*d) * d_tilde
///   score   = psi_hat * (score_1 - score_const)
///
/// with `psi_hat = expit(-r_hat)` and
/// `score_const = d_tilde * (1-y) * exp(r_hat)`.
test "v105_lplr_nuisance_space_score_literals" {
  let (theta, d, y, t_pred, a_pred, m_pred, beta_start) = v105_lplr_inputs()
  let sc = lplr_score_at(
    theta,
    d,
    y,
    t_pred,
    a_pred,
    m_pred,
    beta_start,
    lplr_score_kind("nuisance_space"),
  )
  let expect_psi = [
    0.15844220081073487, 0.10053494094024137, -0.5570953134215317, -0.3871175326205075,
  ]
  let expect_deriv = [0.0, -0.10053494094024137, -0.0, 0.0]
  assert_eq(sc.psi.length(), 4)
  assert_eq(sc.psi_deriv.length(), 4)
  for i = 0; i < 4; i = i + 1 {
    assert_true((sc.psi[i] - expect_psi[i]).abs() < 1.0e-15)
    assert_true((sc.psi_deriv[i] - expect_deriv[i]).abs() < 1.0e-15)
  }
}

///|
/// `instrument` score, upstream `lplr.py:525-528`:
///
///   score = (y - expit(theta*d + r_hat)) * d_tilde
///
/// and the derivative `lplr.py:536-538`:
///
///   deriv = -d * expit(theta*d + r_hat) * (1 - expit(...)) * d_tilde
///
/// Note this branch reads neither `psi_hat` nor `score_const`.
test "v105_lplr_instrument_score_literals" {
  let (theta, d, y, t_pred, a_pred, m_pred, beta_start) = v105_lplr_inputs()
  let sc = lplr_score_at(
    theta,
    d,
    y,
    t_pred,
    a_pred,
    m_pred,
    beta_start,
    lplr_score_kind("instrument"),
  )
  let expect_psi = [
    0.1584422008107349, 0.15011642177102513, -0.6484393417509494, -0.3871175326205076,
  ]
  let expect_deriv = [0.0, -0.08383718622591833, -0.09518463131620655, 0.0]
  assert_eq(sc.psi.length(), 4)
  assert_eq(sc.psi_deriv.length(), 4)
  for i = 0; i < 4; i = i + 1 {
    assert_true((sc.psi[i] - expect_psi[i]).abs() < 1.0e-15)
    assert_true((sc.psi_deriv[i] - expect_deriv[i]).abs() < 1.0e-15)
  }
}

///|
/// The regression itself: on the SAME inputs the two branches must
/// not agree. Rows 1 and 2 are the witnesses (0.10053 vs 0.15012,
/// -0.55710 vs -0.64844).
///
/// This is the assertion that would have caught v0.104.0. Note what
/// it is NOT: it is not `assert(psi_nuisance == psi_instrument)`.
/// That version reads as an elegant invariant and is really a ratchet
/// -- it would cement the inert parameter as a property of the
/// estimator and make the upstream port impossible without rewriting
/// the test.
test "v105_lplr_the_two_scores_are_different_functions" {
  let (theta, d, y, t_pred, a_pred, m_pred, beta_start) = v105_lplr_inputs()
  let ns = lplr_score_at(
    theta,
    d,
    y,
    t_pred,
    a_pred,
    m_pred,
    beta_start,
    lplr_score_kind("nuisance_space"),
  )
  let inst = lplr_score_at(
    theta,
    d,
    y,
    t_pred,
    a_pred,
    m_pred,
    beta_start,
    lplr_score_kind("instrument"),
  )
  let mut max_delta = 0.0
  for i = 0; i < 4; i = i + 1 {
    let dp = (ns.psi[i] - inst.psi[i]).abs()
    let dd = (ns.psi_deriv[i] - inst.psi_deriv[i]).abs()
    if dp > max_delta {
      max_delta = dp
    }
    if dd > max_delta {
      max_delta = dd
    }
  }
  // Observed 0.10053; the threshold is 10 orders of magnitude below
  // the smallest non-trivial separation, so this cannot go flaky on
  // last-ulp libm differences.
  assert_true(max_delta > 1.0e-5)
}

///|
/// `m_pred` must reach `d_tilde = d - m_hat`, for BOTH branches.
///
/// This is the aliasing guard: `fit` used to write `m_pred = a_pred`,
/// so `d_tilde` was `d - a_hat`. Perturbing `m_pred` by +0.1 moves
/// the score by 0.076 / 0.085 (measured), versus 0.0 if the field
/// were ignored.
test "v105_lplr_m_hat_enters_the_score" {
  let (theta, d, y, t_pred, a_pred, m_pred, beta_start) = v105_lplr_inputs()
  let bumped = [0.38, 0.76, 0.34, 0.61]
  for kind in [lplr_score_kind("nuisance_space"), lplr_score_kind("instrument")] {
    let base = lplr_score_at(
      theta, d, y, t_pred, a_pred, m_pred, beta_start, kind,
    )
    let moved = lplr_score_at(
      theta, d, y, t_pred, a_pred, bumped, beta_start, kind,
    )
    let mut max_delta = 0.0
    for i = 0; i < 4; i = i + 1 {
      let dp = (base.psi[i] - moved.psi[i]).abs()
      if dp > max_delta {
        max_delta = dp
      }
    }
    assert_true(max_delta > 1.0e-3)
  }
}

///|
/// End-to-end: `DoubleMLLPLR` fitted with each score must report
/// different coefficients and different standard errors.
///
/// The mechanism-level tests above pin the formulas; this one pins
/// the wiring, i.e. that `fit` resolves `self.score` at all. A future
/// refactor that computes `kind` but stops threading it into
/// `lplr_cross_fit_m` would still pass the formula tests.
test "v105_lplr_fit_end_to_end_scores_differ" {
  let data = build_lzz2020_dgp(300, 0.5, 3141)
  let ns = DoubleMLLPLR::new(
    data,
    score="nuisance_space",
    n_folds=2,
    n_folds_inner=2,
    seed=3141,
  ).fit()
  let inst = DoubleMLLPLR::new(
    data,
    score="instrument",
    n_folds=2,
    n_folds_inner=2,
    seed=3141,
  ).fit()
  assert_true((ns.coef() - inst.coef()).abs() > 1.0e-3)
  assert_true((ns.se() - inst.se()).abs() > 1.0e-6)
  // Both must remain finite and in a sane range for this DGP.
  assert_true(ns.coef().abs() < 10.0)
  assert_true(inst.coef().abs() < 10.0)
  assert_true(ns.se() > 0.0)
  assert_true(inst.se() > 0.0)
}
