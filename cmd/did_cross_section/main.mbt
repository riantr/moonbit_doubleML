// Demo: cross-section DID (Sant'Anna & Zhao 2020,
// "repeated cross-sections" variant). 500 units, each
// with one observation, binary treatment d, and
// binary post-period t. True ATT = 1.0 applied to the
// (d=1, t=1) cell.
//
// The cross-section DID estimator fits 4 g-functions
// g(d, t, x) = E[Y | D=d, T=t, X] and 1 propensity
// m(x) = E[D=1 | X], then constructs the ATT score
// function from these nuisance predictions. Expected
// output: ATT_hat ~ 1.0, 95% CI should cover 1.0.

///|
fn main {
  let n = 500
  let p = 3
  let theta0 = 1.0
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let rng = @dml.chacha8_rng(11)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double() * 2.0 - 1.0
    }
    d[i] = if rng.double() < 0.5 { 1.0 } else { 0.0 }
    t_arr[i] = if rng.double() < 0.5 { 1 } else { 0 }
    let mut y_val = 0.0
    for j = 0; j < p; j = j + 1 {
      y_val = y_val + x_flat[i * p + j]
    }
    if d[i] > 0.5 && t_arr[i] == 1 {
      y_val = y_val + theta0
    }
    y_val = y_val + 0.05 * (rng.double() - 0.5)
    y[i] = y_val
  }
  let data = @dml.DoubleMLDIDCrossSectionData::new(
    @dml.Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    name="demo",
  )
  let fitted = @dml.DoubleMLDIDCrossSection::new(
    data,
    n_folds=2,
    n_rep=1,
    seed=3141,
    score="observational",
    in_sample_normalization=false,
  ).fit()
  let att = fitted.coef()
  let se = fitted.se()
  let lo = att - 1.96 * se
  let hi = att + 1.96 * se
  let covered = lo <= theta0 && theta0 <= hi
  println(
    "=== MoonBit DML demo: cross-section DID (Sant'Anna-Zhao 2020, n=\{n}, p=\{p}) ===",
  )
  println("true ATT = \{theta0}")
  println("")
  println("ATT_hat = \{att}, se = \{se}")
  println("95% CI  = [\{lo}, \{hi}] covers=\{covered}")
  // v0.21.0+: multiplier bootstrap and joint CI.
  let booted = fitted.bootstrap(method_name="normal", n_rep_boot=500, seed=2024)
  let (lo_jt, hi_jt) = booted.confint(joint=true)
  let covered_jt = lo_jt <= theta0 && theta0 <= hi_jt
  println("")
  println("--- Multiplier bootstrap (n_rep_boot=500, normal) ---")
  println("joint 95% CI = [\{lo_jt}, \{hi_jt}] covers=\{covered_jt}")
}
