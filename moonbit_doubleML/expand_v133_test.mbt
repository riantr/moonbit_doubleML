//| v0.133.0 gates -- `DoubleMLAPOS::fit` forwards `ml_g` / `ml_m` to its
//| child `DoubleMLAPO`s.
//
//| Context. `DoubleMLAPOS::new` accepts `ml_g` / `ml_m` and stores them, and
//| THREE of its four child-construction sites already forwarded them
//| (`bootstrap` apo.mbt:2017, both sensitivity paths :2239 and :2288). The
//| fourth -- the `fit` path, apo.mbt:1489 -- did not, so the child fell back
//| to `DoubleMLAPO`'s own defaults. The parent's `ml_m` therefore reached the
//| bootstrap and the sensitivity analyses but NOT the coefficient.
//|
//| Measured before the fix (n=400, p=2, true ATE = 1.2, `ml_m`
//| = LogisticRegression), all three in one run:
//!
//|   A = APOS(coefs)[0] with ml_m = LogisticRegression  = -201.3232415863109
//!   B = APO.coef()  with ml_m = LogisticRegression     =   1.6791519869991263
//!   C = APO.coef()  with the DEFAULT ml_m (OLS)        = -201.3232415863109
//!
//| |A - C| = 0 EXACTLY. A is bit-identical to ignoring the argument, and it
//| is 203 points away from the same learner applied directly. Nothing raised:
//! an OLS propensity entered the score as `1 / m_hat` and `propensity_clip`
//! kept it finite, exactly the failure mode documented for the OLS `ml_m`
//| default in v0.131.9 / v0.132.0.
//
//| Why it survived: of 19 `DoubleMLAPOS::new` call sites in the package, ZERO
//| pass `ml_m`. The argument was reachable, documented, and never used, so no
//| existing test could observe it -- which is why these gates exist rather
//| than a tweak to an existing one.
//|
//| Design note. Asserting only `APOS == APO-with-the-same-ml_m` would be
//| VACUOUS: if the learner were ignored on BOTH sides the assertion would
//| still hold. So GATE 1 also asserts the two are NOT equal -- the learner
//| must demonstrably change the answer, or the equality proves nothing.

///|
fn v1330_data(n : Int, p : Int, seed : Int) -> DoubleMLData {
  let rng = chacha8_rng(seed)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let xi = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      let v = rng.double() * 2.0 - 1.0
      x_flat[i * p + j] = v
      xi[j] = v
    }
    let raw = 0.5 + 1.1 * xi[0] - 0.5 * xi[1]
    let pi = if raw < 0.05 { 0.05 } else if raw > 0.95 { 0.95 } else { raw }
    let di = if rng.double() < pi { 1.0 } else { 0.0 }
    d[i] = di
    y[i] = 0.5 +
      0.7 * xi[0] -
      0.3 * xi[1] +
      1.2 * di +
      0.3 * (rng.double() - 0.5)
  }
  DoubleMLData::new(Matrix::from_array(x_flat, n, p), y, d)
}

///|
/// GATE 1 -- the configured `ml_m` reaches the child, and demonstrably so.
///
/// The two halves are both load-bearing:
///   `apos == apo_logit`  the argument is forwarded (this is the fix)
///   `apos != apo_default` the learner actually changes the estimate (so the
///                         first assertion is not a tautology)
///
/// Mutation: deleting `ml_m=self.ml_m` from the child constructor at
/// apo.mbt:1489 fails BOTH -- the first by 203.0, the second by 0.0.
/// Measured against the pre-fix values: A was -201.3232415863109.
test "v1330_apos_fit_forwards_ml_m_to_the_child_apo" {
  let data = v1330_data(400, 2, 3141)
  let logit = LearnerDispatch::logistic_regression(LogisticRegression::new())
  let apos = DoubleMLAPOS::new(data, [1.0], n_folds=2, seed=3141, ml_m=logit).fit()
  let apo_logit = DoubleMLAPO::new(
    data,
    treatment_level=1.0,
    n_folds=2,
    seed=3141,
    ml_m=logit,
  ).fit()
  let apo_default = DoubleMLAPO::new(
    data,
    treatment_level=1.0,
    n_folds=2,
    seed=3141,
  ).fit()
  let a = apos.coefs()[0]
  assert_true((a - apo_logit.coef()).abs() < 1.0e-12)
  assert_true((a - apo_default.coef()).abs() > 1.0)
}

///|
/// GATE 2 -- same, across MULTIPLE treatment levels, which is what APOS
/// actually exists for (one child per level).
///
/// GATE 1 uses a single level, where a hypothetical bug that leaked the
/// right learner to exactly one level would pass. APOS's whole contract is
/// the per-level loop, so the loop is what gets pinned.
///
/// Mutation: dropping the forwarding fails this at the first level, same as
/// GATE 1; forwarding only level 0 passes GATE 1 and fails here.
test "v1330_apos_forwards_ml_m_at_every_treatment_level" {
  let data = v1330_data(400, 2, 3141)
  let logit = LearnerDispatch::logistic_regression(LogisticRegression::new())
  let levels = [0.0, 1.0]
  let apos = DoubleMLAPOS::new(data, levels, n_folds=2, seed=3141, ml_m=logit).fit()
  let apos_def = DoubleMLAPOS::new(data, levels, n_folds=2, seed=3141).fit()
  for j in 0..<2 {
    let child = DoubleMLAPO::new(
      data,
      treatment_level=levels[j],
      n_folds=2,
      seed=3141,
      ml_m=logit,
    ).fit()
    // forwarded: matches the same learner applied directly at this level
    assert_true((apos.coefs()[j] - child.coef()).abs() < 1.0e-12)
    // and not vacuous: differs from the default-learner APOS
    assert_true((apos.coefs()[j] - apos_def.coefs()[j]).abs() > 1.0e-9)
  }
}
