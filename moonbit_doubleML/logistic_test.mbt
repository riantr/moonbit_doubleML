///|
/// Draw a standard normal sample via Box-Muller, padded into `pool`
/// in pairs. Caller is expected to size the pool to a multiple of 2.
fn fill_normal_pool(rng : @random.Rand, pool : Array[Double]) -> Unit {
  let mut i = 0
  while i < pool.length() {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let theta_ = 2.0 * 3.141592653589793 * u2
    pool[i] = r * @math.cos(theta_)
    if i + 1 < pool.length() {
      pool[i + 1] = r * @math.sin(theta_)
    }
    i = i + 2
  }
}

///|
/// Average of the entries of `v` whose indices are in `idx`. Returns
/// 0.0 on an empty index list.
fn mean_at(v : Array[Double], idx : Array[Int]) -> Double {
  if idx.length() == 0 {
    return 0.0
  }
  let mut s = 0.0
  for k = 0; k < idx.length(); k = k + 1 {
    s = s + v[idx[k]]
  }
  s / idx.length().to_double()
}

///|
/// Deterministic Fisher-Yates permutation of `[0, n)` using a
/// chacha8 RNG seeded from an integer seed. Mirrors `kfold`'s
/// permutation primitive so the split does not depend on platform
/// `Random`.
fn permute(n : Int, seed : Int) -> Array[Int] {
  let rng = chacha8_rng(seed)
  let perm : Array[Int] = Array::makei(n, fn(i) { i })
  for i = n - 1; i > 0; i = i - 1 {
    let j = rng.int(limit=i + 1)
    perm.swap(i, j)
  }
  perm
}

///|
/// DGP: `n = 200`, `p = 2`, `x[:, 0] ~ N(0, 1)`, `x[:, 1] ~ N(0, 1)`,
/// `y = 1{x[:, 0] > 0}`. The boundary is the vertical line `x0 = 0`,
/// which is linearly separable in `x` so IRLS converges in 2-3 steps
/// to a step-like sigmoid. A 50/50 train/test split is drawn with a
/// fixed chacha8 seed so the verdict is reproducible. On the
/// *training* half, we check the fitted model's predicted probability
/// is below 0.5 on the D=0 subset and above 0.5 on the D=1 subset —
/// this is the literal "linear separable" recovery signature.
test "logistic_recovers_linear_separable" {
  let n = 200
  let p = 2
  let rng = chacha8_rng(2026)
  // 200 * 2 = 400 normals, padded to an even count (400 already is).
  let pool : Array[Double] = Array::make(n * p, 0.0)
  fill_normal_pool(rng, pool)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  for i = 0; i < n * p; i = i + 1 {
    x_flat[i] = pool[i]
  }
  let x = Matrix::from_array(x_flat, n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    y[i] = if x.get(i, 0) > 0.0 { 1.0 } else { 0.0 }
  }
  // 50/50 split: shuffle indices with a fixed seed, then first half
  // is the training set, second half the test set.
  let perm = permute(n, 17)
  let half = n / 2
  let train_idx : Array[Int] = Array::make(half, 0)
  let test_idx : Array[Int] = Array::make(n - half, 0)
  for k = 0; k < half; k = k + 1 {
    train_idx[k] = perm[k]
  }
  for k = 0; k < n - half; k = k + 1 {
    test_idx[k] = perm[half + k]
  }
  let x_train = slice_matrix_rows(x, train_idx)
  let y_train = slice_vector(y, train_idx)
  let fitted = LogisticRegression::new().fit(x_train, y_train)
  // 1) coef_ must have length p + 1 (intercept + 2 slopes).
  inspect(fitted.coefficients().length(), content="3")
  // 2) On training data, predictions separate the two classes.
  //    Mean predicted P(y=1) for the D=0 training subset must be < 0.5
  //    and for the D=1 training subset must be > 0.5. Indices are
  //    built into the *training subset* (length half), not the full
  //    data, so we can index `p_train` and `y_train` directly.
  let p_train = fitted.predict(x_train)
  let d0_idx : Array[Int] = []
  let d1_idx : Array[Int] = []
  for k = 0; k < train_idx.length(); k = k + 1 {
    if y_train[k] == 0.0 {
      d0_idx.push(k)
    } else {
      d1_idx.push(k)
    }
  }
  let mean_d0 = mean_at(p_train, d0_idx)
  let mean_d1 = mean_at(p_train, d1_idx)
  inspect(mean_d0 < 0.5, content="true")
  inspect(mean_d1 > 0.5, content="true")
  // 3) predict_class on the same training data recovers y_train exactly
  //    for the separable DGP (sigmoid saturates on both sides of the
  //    boundary).
  let pred_train = fitted.predict_class(x_train)
  for k = 0; k < train_idx.length(); k = k + 1 {
    inspect(pred_train[k], content=if y_train[k] == 1.0 { "1" } else { "0" })
  }
}

///|
/// On a noiseless DGP `y = 1{x0 + 0.3 x1 > 0}` with `n = 200`,
/// `p = 2`, the IRLS fit should produce coefficients that match the
/// "linear predictor" view of the model: `predict(x)` must equal
/// `sigmoid([1, x0, x1] @ coef_)` to numerical precision. This pins
/// down the contract that `predict` is just `sigmoid(x_aug @ coef_)`
/// and that `predict_class` thresholds it consistently.
test "logistic_predict_matches_sigmoid_of_linear" {
  let n = 200
  let p = 2
  let rng = chacha8_rng(4242)
  let pool : Array[Double] = Array::make(n * p, 0.0)
  fill_normal_pool(rng, pool)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  for i = 0; i < n * p; i = i + 1 {
    x_flat[i] = pool[i]
  }
  let x = Matrix::from_array(x_flat, n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    y[i] = if x.get(i, 0) + 0.3 * x.get(i, 1) > 0.0 { 1.0 } else { 0.0 }
  }
  let fitted = LogisticRegression::new().fit(x, y)
  let coef = fitted.coefficients()
  // 1) Length contract: p + 1.
  inspect(coef.length(), content="3")
  // 2) Recompute sigmoid([1, x0, x1] @ coef_) for a few rows and
  //    compare to fitted.predict(x).
  let p_pred = fitted.predict(x)
  // spot-check rows 0, 7, 13, 41, 199 — diverse enough to hit both
  // classes for any non-trivial split.
  let spot : Array[Int] = [0, 7, 13, 41, 199]
  for k = 0; k < spot.length(); k = k + 1 {
    let i = spot[k]
    let eta = coef[0] + coef[1] * x.get(i, 0) + coef[2] * x.get(i, 1)
    let expected = 1.0 / (1.0 + @math.exp(-eta))
    // predict() clips to (1e-15, 1 - 1e-15) and sigmoid(eta) here is
    // bounded well inside that band for any eta in the range IRLS
    // produces on this DGP, so the absolute tolerance is generous.
    inspect((p_pred[i] - expected).abs() < 1.0e-9, content="true")
  }
  // 3) predict_class(x) at threshold 0.5 must agree with y on a
  //    separable DGP: every y[i] is on the correct side of the
  //    fitted decision boundary (sigmoid saturates past 0.5).
  let pred_class = fitted.predict_class(x)
  let mut correct = 0
  for i = 0; i < n; i = i + 1 {
    if pred_class[i] == y[i] {
      correct = correct + 1
    }
  }
  // every row is correctly classified on a perfectly separable DGP
  inspect(correct, content="200")
}

///|
/// `LogisticRegression::predict` must abort when called before
/// `fit()`. The panic path goes through `require(self.fitted)` inside
/// `logistic.mbt`. Mirrors the `panic_linear_coefficients_before_fit`
/// test in `check_test.mbt`.
test "panic_logistic_predict_before_fit" {
  let m = LogisticRegression::new()
  let x = Matrix::zeros(2, 1)
  let _ = m.predict(x)
}

///|
/// `LogisticRegression::coefficients` must abort when called before
/// `fit()`. The panic path goes through `require(self.fitted)` inside
/// `logistic.mbt`. Mirrors the `panic_linear_coefficients_before_fit`
/// test in `check_test.mbt`.
test "panic_logistic_coefficients_before_fit" {
  let m = LogisticRegression::new()
  let _ = m.coefficients()
}

///|
/// REVIEW L12 fix (0.7.0): `fit` must abort when `y` is not in
/// `{0, 1}`. The pre-fix code silently produced nonsense for
/// out-of-range labels (e.g. `y = 0.5` produced a
/// logistic-probability fit on a 0.5-classification problem,
/// which is meaningless).
test "panic_logistic_fit_rejects_non_binary_y" {
  let x = Matrix::zeros(4, 1)
  let y : Array[Double] = [0.0, 0.5, 1.0, 1.0]
  let _ = LogisticRegression::new().fit(x, y)
}
