// Demo entry point: the canonical DoubleMLAPOS example. Two-level
// discrete-treatment IRM DGP with theta_0 = 1.0 per level; the
// `DoubleMLAPOS` estimator should land at (1.0, 1.0) for both
// treatment levels (the symmetric case). v0.49.0 also exercises
// `causal_contrast` between the two levels, which should be 0.0.

///|
fn main {
  let n = 500
  let p = 3
  let theta0 = 1.0
  let seed = 1111
  let rng = @dml.chacha8_rng(seed)

  // ---- Build X (n, p) via CLT on chacha8 uniforms ----
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  for k = 0; k < n * p; k = k + 1 {
    let mut acc = 0.0
    for _j = 0; _j < 12; _j = _j + 1 {
      acc = acc + rng.double()
    }
    x_flat[k] = acc - 6.0
  }
  let x = @dml.Matrix::from_array(x_flat, n, p)

  // ---- Build treatment assignment d in {1, 2} ----
  // Two-level treatment with probability depending on X[:, 0].
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let x0 = x_flat[i * p]
    let p1 = 0.5 + 0.2 * @math.tanh(x0)
    let u = rng.double()
    if u <= p1 {
      d[i] = 1.0
    } else {
      d[i] = 2.0
    }
  }

  // ---- Build outcome Y = theta0 * 1{d == 1} + theta0 * 1{d == 2} + 0.5 * X@1 + N(0, 1) ----
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let mut xsum = 0.0
    for k = 0; k < p; k = k + 1 {
      xsum = xsum + x_flat[i * p + k]
    }
    let mut acc = 0.0
    for _j = 0; _j < 12; _j = _j + 1 {
      acc = acc + rng.double()
    }
    let eps = acc - 6.0
    y[i] = theta0 * (if d[i] == 1.0 { 1.0 } else { 0.0 }) +
      theta0 * (if d[i] == 2.0 { 1.0 } else { 0.0 }) +
      0.5 * xsum +
      eps
  }

  // ---- Estimate ----
  let data = @dml.DoubleMLData::new(x, y, d)
  let fitted = @dml.DoubleMLAPOS::new(
    data,
    [1.0, 2.0],
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()

  println("=== MoonBit DML APOS (2-level discrete treatment) ===")
  println("true theta_0      = " + theta0.to_string() + " (per level)")
  let coefs = fitted.coefs()
  let ses = fitted.ses()
  println(
    "level 1.0: coef=" + coefs[0].to_string() + ", se=" + ses[0].to_string(),
  )
  println(
    "level 2.0: coef=" + coefs[1].to_string() + ", se=" + ses[1].to_string(),
  )

  // Causal contrast: 1.0 - 2.0 should be ~0 (symmetric DGP).
  let contrasts = fitted.causal_contrast([1.0])
  let delta_2_vs_1 = contrasts[0][1]
  let se_2_vs_1 = contrasts[0][2]
  println(
    "contrast (level 2 - level 1): delta=" +
    delta_2_vs_1.to_string() +
    ", se=" +
    se_2_vs_1.to_string(),
  )
}
