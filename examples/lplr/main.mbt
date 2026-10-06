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
) -> @moonbit_doubleML.DoubleMLBinaryData {
  let p = 6
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  // Box-Muller pool.
  let pool : Array[Double] = []
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
    let p_t = @moonbit_doubleML.expit(a)
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
    let prob = @moonbit_doubleML.expit(alpha * d[i] + r)
    let u = rng.double()
    y[i] = if u < prob { 1.0 } else { 0.0 }
  }
  @moonbit_doubleML.DoubleMLBinaryData::new(
    @moonbit_doubleML.Matrix::from_array(x_flat, n, p),
    y,
    d,
  )
}

///|
fn main {
  let data = build_dgp(@moonbit_doubleML.chacha8_rng(3141), 500, 0.5)
  println("=== MoonBit DML demo: Partially Logistic Regression (LZZ2020) ===")
  println("true alpha = 0.5 (logit-scale causal effect)")
  println("")
  // Both score paths. The two are DIFFERENT formulas upstream
  // (`DoubleMLLPLR._compute_score`, plm/lplr.py:521-530); through
  // v0.104.0 this port validated the `score` string and then never
  // read it, so both rows printed identical numbers.
  let names = [
    ("nuisance_space", "nuisance space score (default)"),
    ("instrument", "instrument score (upstream form, unweighted ml_m)"),
  ]
  let mut th_ns = 0.0
  let mut th_in = 0.0
  let mut se_ns = 0.0
  let mut se_in = 0.0
  for i = 0; i < names.length(); i = i + 1 {
    let sc_name = names[i].0
    let sc_desc = names[i].1
    let fitted = @moonbit_doubleML.DoubleMLLPLR::new(
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
    if sc_name == "instrument" {
      th_in = fitted.coef()
      se_in = fitted.se()
    } else {
      th_ns = fitted.coef()
      se_ns = fitted.se()
    }
  }
  println(
    "score gap: |theta_instrument - theta_nuisance_space| = \{(th_in - th_ns).abs()}",
  )
  println(
    "          |se_instrument    - se_nuisance_space|    = \{(se_in - se_ns).abs()}",
  )
  println("")
  // v0.105.0: the same DGP at 4x the sample size.
  //
  // The coefficient is not the useful check here. This DGP gives
  // se ~ 0.27 at n = 500, so two independent draws of the same
  // estimator differ by ~sqrt(2) * 0.27 in expectation -- any
  // Monte-Carlo-tolerant band wide enough for that is far too wide
  // to notice a wrong standard error. The SE's own 1/sqrt(n)
  // scaling is the sharp quantity, and it does not depend on the
  // two sides sharing an RNG stream: MoonBit draws from
  // `chacha8_rng` and the Python reference from `default_rng`,
  // and those cannot be aligned.
  //
  // A wrong `M_inv` is what this catches. LPLR's `M_inv` is
  // `1 / mean(psi_deriv)`, and v0.87.0 had it as
  // `1 / mean(psi_a)` -- a catastrophic-cancellation residual
  // rather than the Jacobian. v0.92.0 corrected it. Nothing has
  // held the line since.
  let data_big = build_dgp(@moonbit_doubleML.chacha8_rng(3141), 2000, 0.5)
  let fitted_big = @moonbit_doubleML.DoubleMLLPLR::new(
    data_big,
    score="nuisance_space",
    n_folds=2,
    n_folds_inner=2,
    seed=3141,
  ).fit()
  println("--- scale (same DGP, 4x the sample size, nuisance_space) ---")
  println("scale n=2000 theta_hat = \{fitted_big.coef()}")
  println("scale n=2000 se        = \{fitted_big.se()}")
  println("LPLR example done")
}
