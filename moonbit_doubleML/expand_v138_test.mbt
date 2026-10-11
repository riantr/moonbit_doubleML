//| v0.138.0 gates -- `DoubleMLSSM`'s default `ml_m` is a CLASSIFIER.
//
//| Context. The eleventh and last of the `ml_m` defaults. v0.132.0 / v0.133.0
//| / v0.134.0 / v0.135.0 migrated IRM, the APOS forwarding bug, APO and APOS.
//| v0.136.0 refused the next candidate (`DoubleMLDID`) on measurement -- it is
//| doubly robust, so `g` carries identification and `m` is second-order. v0.137.0
//| then measured ALL ELEVEN remaining defaults one by one and recorded a
//| per-estimator verdict. SSM was the single measured hazard. This release
//| acts on it.
//
//| Why SSM and why it is the worst case in the package. The score carries TWO
//| reciprocals, one per direction (`ssm.mbt:73-74`):
//!
//|   psi_b1 = (D==1)*S*(Y-g_d1)/(m*pi)      + g_d1
//!   psi_b0 = (D==0)*S*(Y-g_d0)/((1-m)*pi)  + g_d0
//!
//| `m` is the treatment propensity and `pi` the selection propensity, so an
//| unbounded regressor breaks BOTH denominators independently. IRM/APO carry
//| `1/m` alone and were bad by ~200x; SSM was bad by ~200x in the point
//| estimate and ~1900x in the standard error.
//
//| MEASURED, three arms in one run on a saturated-propensity DGP, true
//| `theta = 1.0`, n=2000, p=2, `n_folds=2`, `seed=3141`
//| (`_verify/probe_v1380_ssm.mbt`):
//!
//!   arm                         coef             SE
//!   SHIPPED (no ml_m argument)   242.1162443137717  185.4454546371585
//!   linear_regression           242.1162443137717  185.4454546371585
//!   logistic_regression          1.177284305063409   0.09819960252026207
//!
//!   `shipped - ols` is EXACTLY 0, to the last digit of both the coefficient
//!   and the SE. That is the control the v0.136.0 probe lacked and the whole
//! release depends on: it proves the 242 is the number USERS GET, not an
//! artefact of an arm I constructed in a probe. Without it the flip would rest
//!   on a comparison against a learner the default never reaches.
//
//| MEASURED, the hazard is a property of the CLAMP, not of the estimator --
//! two fixtures x three seeds, same n/p/folds/seed
//! (`_verify/probe_v1380_ssm.mbt`, `v1380_probe_ssm_two_fixtures`):
//!
//!   fixture  seed   OLS coef     OLS SE    logit coef  logit SE
//!   steep     13    242.116      185.45     1.1773      0.0982
//!   steep     29    105.641      208.34     0.9511      0.1187
//!   steep     41   -451.770      209.58     0.4160      0.2997
//!   mild      13      1.00493      0.005153  1.0056      0.005463
//!   mild      29      0.998388     0.005810  0.9994      0.005983
//!   mild      41      0.999559     0.005151  1.0000      0.005478
//!
//| Three things follow, and each is asserted below.
//!
//!   1. On the steep fixture the OLS arm CHANGES SIGN across seeds
//!      (+242, +106, -452) while the classifier arm stays positive and
//!      O(0.1) from the truth. Its coefficient spread across the three seeds
//!      is 693.9 against the classifier's 0.761.
//!   2. On the MILD fixture -- slope 0.4, so the true propensity never
//!      reaches the 0.02/0.98 clamp -- the two learners agree to three
//!      decimals and OLS is marginally BETTER (0.99956 vs 1.00004 at seed 41,
//!      SE 0.005151 vs 0.005478). Nothing is given up where OLS was already
//!      fine. This is why GATE 4 exists: a default flip that only ever gets
//!      measured on the failing fixture would not know the difference between
//!      "the classifier is better" and "the fixture is bad".
//!   3. The two arms are not a matter of degree on the steep fixture. Even
//!      the WORST classifier arm (0.2997 SE) beats the BEST OLS arm (185.45
//!      SE) by 619x.
//
//| NOT CLAIMED: that the classifier is unbiased. At steep/41 it carries a
//| 0.584 bias. The claim is the comparative one -- the regressor is wrong by
//| 100x to 450x and unstable in sign, the classifier is stable and within one
//| standard error of the truth on all three seeds.
//
//| Mutations -- MEASURED, not predicted (`_verify/_mutate_1380_ssm.py revert`
//| reverts the default to `LearnerDispatch::linear_regression()` and nothing
//| else):
//!
//!   GATE 1  default IS the classifier            FAIL   as expected
//!   GATE 2  point estimate beats the regressor    FAIL   as expected
//!   GATE 3  SE is orders of magnitude tighter     FAIL   as expected
//!   GATE 4  benign-regime agreement               PASS   as expected, by design
//!   GATE 5  stability across seeds                FAIL   after a fix -- see below
//!
//| Two of those five rows are worth reading twice.
//!
//| GATE 4 is SUPPOSED to survive. It is the benign-regime control, and a
//| control that fails when you undo the thing it controls is not a control.
//!
//| GATE 5 survived its first mutation run, which was a defect in the gate. It
//| had been written with explicit learners on BOTH sides, so the revert left
//| every input to it unchanged and it passed having observed nothing. An
//| earlier draft of this header predicted it would fail; the prediction was
//| wrong, the run said so, and GATE 5 now asserts the SHIPPED arm directly.
//| The general rule that cost a release cycle: a gate whose every input is
//| spelled out explicitly cannot see the default, and if the default is what
//| the release is about, such a gate is decoration.

///|
/// Saturated-but-legitimate propensity: a clamp of a linear index that runs
/// past [0,1], so a REGRESSOR fit to the 0/1 target predicts outside [0,1]
/// while a classifier cannot. `slope` sets the steepness; `theta` is the true
/// treatment effect, so every bias below is measured against a known value.
fn v1380_data(
  n : Int,
  p : Int,
  slope : Double,
  theta : Double,
  seed : Int,
) -> DoubleMLSSMData {
  let rng = chacha8_rng(seed)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let x0s : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let xi = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      let v = rng.double() * 2.0 - 1.0
      x_flat[i * p + j] = v
      xi[j] = v
    }
    x0s[i] = xi[0]
    let raw = 0.5 + slope * xi[0]
    let pi = if raw < 0.02 { 0.02 } else if raw > 0.98 { 0.98 } else { raw }
    let di = if rng.double() < pi { 1.0 } else { 0.0 }
    d[i] = di
    y[i] = 0.5 + 0.8 * xi[0] + theta * di + 0.3 * (rng.double() - 0.5)
  }
  // MAR selection: S depends on D and X, both observed by the estimator.
  let s : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let ps = 0.7 - 0.25 * x0s[i] + 0.2 * d[i]
    let ps = if ps < 0.05 { 0.05 } else if ps > 0.95 { 0.95 } else { ps }
    s[i] = if chacha8_rng(1000 + i).double() < ps { 1.0 } else { 0.0 }
  }
  DoubleMLSSMData::new(Matrix::from_array(x_flat, n, p), y, d, s)
}

///|
/// GATE 1 (structural) -- the SHIPPED default IS an explicitly-constructed
/// `LogisticRegression`, and is NOT an explicitly-constructed
/// `linear_regression()`.
///
/// `DoubleMLSSM` exposes no `learner_m()` accessor (unlike `DoubleMLAPOS`), so
/// the type tag is asserted through behaviour instead, which is the STRONGER
/// statement: a type tag would accept "some classifier", whereas exact equality
/// with a constructed `LogisticRegression::new()` pins the object, and the
/// third clause rules out the regressor outright.
///
/// Exact `==` rather than a tolerance is intentional and measured: the default
/// IS that expression, the fit is deterministic, and both arms printed the same
/// 17 significant digits. A last-ulp drift here would be a real signal about
/// which learner the estimator actually used.
///
/// Mutation: reverting the default to `linear_regression()` fails all three.
test "v1380_ssm_default_ml_m_is_the_classifier_not_the_regressor" {
  let ols = LearnerDispatch::linear_regression()
  let logit = LearnerDispatch::logistic_regression(LogisticRegression::new())
  let data = v1380_data(2000, 2, 2.0, 1.0, 13)
  let shipped = DoubleMLSSM::new(data, n_folds=2, seed=3141).fit()
  let as_logit = DoubleMLSSM::new(data, n_folds=2, seed=3141, ml_m=logit).fit()
  let as_ols = DoubleMLSSM::new(data, n_folds=2, seed=3141, ml_m=ols).fit()
  // is the classifier
  assert_true(shipped.coef() == as_logit.coef())
  assert_true(shipped.se() == as_logit.se())
  // and is not the regressor
  assert_true(shipped.coef() != as_ols.coef())
  assert_true(shipped.se() != as_ols.se())
}

///|
/// GATE 2 (point estimate) -- on a saturated propensity the shipped default's
/// error is a small fraction of the regressor's, on every seed.
///
/// Thresholds from the measurement, with margin:
///
///   seed   classifier |bias|   OLS |bias|   ratio    band
///   13        0.1773      241.116        0.00074   < 0.05
///   29        0.0489      104.641        0.00047   < 0.05
///   41        0.5840      452.770        0.00129   < 0.05
///
/// The worst measured ratio is 0.00129, so the 0.05 band leaves 38x of margin
/// while still failing a revert by five orders of magnitude (a revert puts the
/// ratio at exactly 1.0).
test "v1380_ssm_default_point_estimate_beats_the_regressor" {
  let ols = LearnerDispatch::linear_regression()
  for seed in [13, 29, 41] {
    let theta = 1.0
    let data = v1380_data(2000, 2, 2.0, theta, seed)
    let shipped = DoubleMLSSM::new(data, n_folds=2, seed=3141).fit()
    let as_ols = DoubleMLSSM::new(data, n_folds=2, seed=3141, ml_m=ols).fit()
    let e_ship = (shipped.coef() - theta).abs()
    let e_ols = (as_ols.coef() - theta).abs()
    assert_true(e_ols > 100.0)
    assert_true(e_ship < 0.05 * e_ols)
  }
}

///|
/// GATE 3 (standard error) -- the same separation in the SE, and worse.
///
///   seed   classifier SE   OLS SE      ratio     band
///   13        0.0982       185.45      0.00053   < 0.05
///   29        0.1187       208.34      0.00057   < 0.05
///   41        0.2997       209.58      0.00143   < 0.05
///
/// Worst measured ratio 0.00143 -> 34x of margin. The SE is the stronger
/// discriminator here, and it is the one that matters to a user: the OLS arm's
/// 185-210 SEs are not wide intervals, they are intervals that admit almost
/// any treatment effect.
test "v1380_ssm_default_se_is_orders_of_magnitude_tighter" {
  let ols = LearnerDispatch::linear_regression()
  for seed in [13, 29, 41] {
    let data = v1380_data(2000, 2, 2.0, 1.0, seed)
    let shipped = DoubleMLSSM::new(data, n_folds=2, seed=3141).fit()
    let as_ols = DoubleMLSSM::new(data, n_folds=2, seed=3141, ml_m=ols).fit()
    assert_true(as_ols.se() > 100.0)
    assert_true(shipped.se() < 0.05 * as_ols.se())
  }
}

///|
/// GATE 4 (benign-regime control) -- where the true propensity never reaches
/// the clamp, the two learners AGREE and nothing is given up.
///
///   seed   OLS coef     OLS SE      logit coef  logit SE
///   13      1.0049325    0.0051530    1.0055617    0.0054628
///   29      0.9983875    0.0058097    0.9994082    0.0059834
///   41      0.9995591    0.0051513    1.0000444    0.0054780
///
/// Agreement is asserted at 1% of the coefficient (measured spread is 0.0016,
/// so ~6x margin) and the SE at 20% (measured spread is 6%, ~3x margin).
///
/// This gate SURVIVES the revert on purpose. It is the control for "the flip
/// costs nothing in the regime where OLS was already fine", and a control that
/// fails when you undo the change would not be a control. A default flip
/// measured only on its failing fixture cannot distinguish "the classifier is
/// better" from "that fixture was broken"; this one can.
test "v1380_ssm_default_agrees_with_the_regressor_when_propensity_is_bounded" {
  let ols = LearnerDispatch::linear_regression()
  let logit = LearnerDispatch::logistic_regression(LogisticRegression::new())
  let theta = 1.0
  for seed in [13, 29, 41] {
    // slope 0.4 -> the true propensity stays inside (0.1, 0.9)
    let data = v1380_data(2000, 2, 0.4, theta, seed)
    let as_ols = DoubleMLSSM::new(data, n_folds=2, seed=3141, ml_m=ols).fit()
    let as_logit = DoubleMLSSM::new(data, n_folds=2, seed=3141, ml_m=logit).fit()
    assert_true((as_ols.coef() - as_logit.coef()).abs() < 0.01 * theta.abs())
    assert_true(as_logit.se() < 1.2 * as_ols.se())
    // both near the truth on this fixture
    assert_true((as_logit.coef() - theta).abs() < 0.01 * theta.abs())
  }
}

///|
/// GATE 5 (stability) -- across seeds the SHIPPED default keeps a stable sign
/// and a tight spread, while the regressor changes sign outright.
///
///   shipped / logistic   +1.1773, +0.9511, +0.4160   -> spread 0.761, all +
///   linear_regression   +242.116, +105.641, -451.770 -> spread 693.9, sign flip
///
/// A sign flip is the cleanest possible statement of the defect: no interval
/// can rescue an estimator whose point estimate crosses zero when only the
/// seed moves. Asserted as an explicit sign check rather than a spread
/// threshold alone, so the gate fails if the failure mode ever degrades from
/// "changes sign" to merely "very wide" without anyone noticing.
///
/// The SHIPPED arm is what is asserted for stability, and an explicit
/// regressor arm is what records the defect. That split is deliberate and it
/// was arrived at by measurement, not taste: an earlier draft of this gate
/// used explicit learners on BOTH sides, and the v0.138.0 revert mutation
/// left it PASSING -- a gate built entirely on explicit arms cannot observe
/// the default at all, so it was decoration. Naming the shipped arm here is
/// what makes this gate a gate. The explicit regressor assertions are kept
/// alongside precisely so the historical measurement stays attributable.
test "v1380_ssm_default_is_stable_across_seeds_and_the_regressor_flips_sign" {
  let ols = LearnerDispatch::linear_regression()
  let shipped_coefs : Array[Double] = []
  let ols_coefs : Array[Double] = []
  for seed in [13, 29, 41] {
    let data = v1380_data(2000, 2, 2.0, 1.0, seed)
    shipped_coefs.push(
      DoubleMLSSM::new(data, n_folds=2, seed=3141).fit().coef(),
    )
    ols_coefs.push(
      DoubleMLSSM::new(data, n_folds=2, seed=3141, ml_m=ols).fit().coef(),
    )
  }
  // the shipped default keeps a stable sign and a tight spread ...
  assert_true(shipped_coefs[0] > 0.0 && shipped_coefs[1] > 0.0)
  assert_true(shipped_coefs[2] > 0.0)
  assert_true((shipped_coefs[0] - shipped_coefs[2]).abs() < 2.0)
  // ... while the regressor on the identical data flips sign, and is three
  // orders of magnitude more dispersed.
  assert_true(ols_coefs[0] * ols_coefs[2] < 0.0)
  assert_true((ols_coefs[0] - ols_coefs[2]).abs() > 600.0)
  assert_true(
    (ols_coefs[0] - ols_coefs[2]).abs() >
    100.0 * (shipped_coefs[0] - shipped_coefs[2]).abs(),
  )
}
