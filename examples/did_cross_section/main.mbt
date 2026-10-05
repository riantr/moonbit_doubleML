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
  let (x, y, d, t_arr) = build_dgp(n, p, theta0, 11, 0.05)
  let data = @moonbit_doubleML.DoubleMLDIDCrossSectionData::new(
    @moonbit_doubleML.Matrix::from_array(x, n, p),
    y,
    d,
    t_arr,
    name="demo",
  )
  let fitted = @moonbit_doubleML.DoubleMLDIDCrossSection::new(
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
  // v0.103.0+: the same DGP at 4x the sample size.
  //
  // A consistent estimator's SE must fall like 1 / sqrt(n),
  // so the n=2000 SE should be close to HALF the n=500 one.
  // This is the check that catches a variance formula whose
  // 1 / n has been algebraically cancelled away: such a
  // formula reports a flat SE across n (the v0.102.0
  // predecessor read 0.3654 / 0.3708 / 0.3613 at
  // n = 300 / 600 / 2400). Unlike a coefficient
  // comparison, this does not depend on the two sides
  // sharing an RNG stream, so it survives the
  // MoonBit chacha8 / numpy PCG64 split.
  let n2 = 2000
  let (x2, y2, d2, t2) = build_dgp(n2, p, theta0, 11, 0.05)
  let fitted2 = @moonbit_doubleML.DoubleMLDIDCrossSection::new(
    @moonbit_doubleML.DoubleMLDIDCrossSectionData::new(
      @moonbit_doubleML.Matrix::from_array(x2, n2, p),
      y2,
      d2,
      t2,
      name="demo-scale",
    ),
    n_folds=2,
    n_rep=1,
    seed=3141,
    score="observational",
    in_sample_normalization=false,
  ).fit()
  let att2 = fitted2.coef()
  let se2 = fitted2.se()
  println("")
  println("--- Scale check: same DGP, 4x the sample size ---")
  println("scale n=\{n2} ATT_hat = \{att2}, se = \{se2}")
  println("se_ratio = \{(se2 / se).to_string()}")
  // v0.103.0+: the same DGP with 10x the noise.
  //
  // The base DGP's noise term is 0.05 * U(-1, 0.5), i.e. a
  // standard deviation near 0.02 against regressors with a
  // standard deviation near 1.0. On data that close to
  // deterministic, several wrong point estimators coincide
  // with the right one: the pre-v0.102.0 argmin fit read
  // ATT_hat = 1.0024 here versus 0.9961 for the correct
  // moment root. So the near-noise-free section above
  // exercises the 1/sqrt(n) check but CANNOT exercise a
  // coefficient check. At noise amplitude 0.5 the same
  // comparison separates them by ~0.15.
  let (x3, y3, d3, t3) = build_dgp(n, p, theta0, 11, 0.5)
  let fitted3 = @moonbit_doubleML.DoubleMLDIDCrossSection::new(
    @moonbit_doubleML.DoubleMLDIDCrossSectionData::new(
      @moonbit_doubleML.Matrix::from_array(x3, n, p),
      y3,
      d3,
      t3,
      name="demo-noisy",
    ),
    n_folds=2,
    n_rep=1,
    seed=3141,
    score="observational",
    in_sample_normalization=false,
  ).fit()
  let att3 = fitted3.coef()
  let se3 = fitted3.se()
  println("")
  println("--- Noisy variant: same DGP, 10x the noise amplitude ---")
  println("noisy ATT_hat = \{att3}, se = \{se3}")
}

///|
/// The example DGP: `y = sum_j x_j + theta0 * 1[d=1 & t=1] + noise`,
/// `d` / `t` Bernoulli(1/2), `x` U(-1, 1),
/// `noise = noise_amp * (U(-1, 1) - 0.5)`.
/// Factored out in v0.103.0 so the scale and noise checks reuse
/// it verbatim rather than restating it.
fn build_dgp(
  n : Int,
  p : Int,
  theta0 : Double,
  seed : Int,
  noise_amp : Double,
) -> (Array[Double], Array[Double], Array[Double], Array[Int]) {
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let rng = @moonbit_doubleML.chacha8_rng(seed)
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
    y_val = y_val + noise_amp * (rng.double() - 0.5)
    y[i] = y_val
  }
  (x_flat, y, d, t_arr)
}
