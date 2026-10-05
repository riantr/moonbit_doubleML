///|
/// v0.104.0: the weighted path of `pava`.
///
/// `pava` maintained each block's mean as `sum_y / sum_w` but
/// seeded `sum_y` with the RAW `y[i]` instead of `w[i] * y[i]`,
/// so every pooled block reported `(sum of y) / (sum of w)`.
/// With unit weights the two agree and the unweighted cases pass;
/// with any non-uniform weight the fitted block value is wrong.
///
/// The case below is the one that separates them. y is already
/// sorted by x; positions 1 and 2 violate monotonicity (0.5 then
/// 0.1) and pool, and the weights differ (1.0 vs 0.25):
///
///   correct  (1*0.5 + 0.25*0.1) / (1 + 0.25) = 0.525 / 1.25 = 0.42
///   buggy    (0.5 + 0.1) / 1.25                = 0.6   / 1.25 = 0.48
///
/// 0.42 is what `sklearn.isotonic.isotonic_regression` returns
/// for the same (y, sample_weight); see
/// `validate_pava_with_python.py` and `examples/pava`.
test "v104_pava_weighted_block_mean" {
  let y = [0.2, 0.5, 0.1, 0.8]
  let w = [1.0, 1.0, 0.25, 1.0]
  let fitted = pava(y, weights=w)
  assert_eq(fitted.length(), 4)
  let expect = [0.2, 0.42, 0.42, 0.8]
  for i = 0; i < 4; i = i + 1 {
    assert_true((fitted[i] - expect[i]).abs() < 1.0e-12)
  }
}

///|
/// A single element with a non-unit weight must come back
/// unchanged -- the simplest form of the same property, and one
/// that isolates the seeding line from the pooling loop.
test "v104_pava_single_weighted_element" {
  let y = [0.37]
  let fitted = pava(y, weights=[3.0])
  assert_eq(fitted.length(), 1)
  assert_true((fitted[0] - 0.37).abs() < 1.0e-12)
}

///|
/// Weighting must be able to change the fit, not merely survive
/// it. A weight of 1000 against a weight of 1 pulls the pooled
/// value almost all the way to 0.9 -- but not all the way, and
/// the exact value is the point:
///
///   (1000*0.9 + 1*0.1) / 1001 = 900.1 / 1001 = 0.8992007992
///
/// which is what `sklearn.isotonic.isotonic_regression` gives.
/// Asserting `0.9` here (a plausible "big weight pins the value"
/// intuition) would have been wrong by 8e-4. Under unit weights
/// the same data pools at the plain mean, so the pair also says
/// the weights are read rather than ignored.
test "v104_pava_weight_actually_moves_the_fit" {
  let y = [0.9, 0.1]
  let heavy = pava(y, weights=[1000.0, 1.0])
  let unit = pava(y)
  assert_true((heavy[0] - 0.8992007992007992).abs() < 1.0e-12)
  assert_true((heavy[1] - 0.8992007992007992).abs() < 1.0e-12)
  // Unit weights: both elements pool at their mean.
  assert_true((unit[0] - 0.5).abs() < 1.0e-12)
  assert_true((unit[1] - 0.5).abs() < 1.0e-12)
}
