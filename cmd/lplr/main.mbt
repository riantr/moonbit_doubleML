// Demo: DoubleMLLPLR (partially logistic regression, LZZ2020).
// 500 observations, 6 covariates, binary D and Y, alpha = 0.5
// (true causal effect on the logit scale). The estimator runs a
// double cross-fit (outer folds for ml_M, ml_m, ml_t; inner
// folds for the preliminary per-fold beta) and solves the
// nonlinear LPLR score via a damped Newton iteration.

///|
fn build_dgp(
  rng : @random.Rand,
  n : Int,
  alpha : Double,
) -> @dml.DoubleMLBinaryData {
  let p = 6
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  // Box-Muller pool.
  let pool : Array[Double] = Array::new()
  while pool.length() < n * p + n {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let theta = 2.0 * 3.141592653589793 * u2
    pool.push(r * @math.cos(theta))
    pool.push(r * @math.sin(theta))
  }
  for i = 0; i < n * p; i = i + 1 {
    x_flat[i] = pool[i]
  }
  for i = 0; i < n; i = i + 1 {
    let x1 = x_flat[i * p]
    let x2 = x_flat[i * p + 1]
    let a = 0.5 * @math.sin(x1) + 0.5 * @math.cos(x2) + 0.5 * pool[n * p + i]
    let p_t = @dml.expit(a)
    let u = rng.double()
    d[i] = if u < p_t { 1.0 } else { 0.0 }
  }
  for i = 0; i < n; i = i + 1 {
    let x1 = x_flat[i * p]
    let x2 = x_flat[i * p + 1]
    let x3 = x_flat[i * p + 2]
    let x4 = x_flat[i * p + 3]
    let x5 = x_flat[i * p + 4]
    let x6 = x_flat[i * p + 5]
    let r = 0.25 * x1 * x2 +
      0.25 * x3 * x3 +
      0.25 * @math.cos(x4) -
      0.5 * @math.sin(x5) +
      (if x6 > 0.0 { 1.0 } else { 0.0 }) -
      0.5
    let prob = @dml.expit(alpha * d[i] + r)
    let u = rng.double()
    y[i] = if u < prob { 1.0 } else { 0.0 }
  }
  @dml.DoubleMLBinaryData::new(@dml.Matrix::from_array(x_flat, n, p), y, d)
}

///|
fn main {
  let data = build_dgp(@dml.chacha8_rng(3141), 500, 0.5)
  println("=== MoonBit DML demo: Partially Logistic Regression (LZZ2020) ===")
  println("true alpha = 0.5 (logit-scale causal effect)")
  println("")
  // Both score paths.
  let names = [
    ("nuisance_space", "nuisance space score (default)"),
    ("instrument", "instrument score (sample-weighted)"),
  ]
  for i = 0; i < names.length(); i = i + 1 {
    let sc_name = names[i].0
    let sc_desc = names[i].1
    let fitted = @dml.DoubleMLLPLR::new(
      data,
      score=sc_name,
      n_folds=2,
      n_folds_inner=2,
      seed=3141,
    ).fit()
    let (lo, hi) = fitted.confint()
    println("--- \{sc_name} (\{sc_desc}) ---")
    println("theta_hat = \{fitted.coef()}")
    println("se        = \{fitted.se()}")
    println("95% CI    = [\{lo}, \{hi}]")
    println("")
  }
}
