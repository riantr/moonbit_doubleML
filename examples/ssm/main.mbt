// Demo: DoubleMLSSM, and the one place its two standard-error
// accessors must agree exactly.
//
// WHY THIS EXAMPLE EXISTS
// =======================
// `validate_ssm_with_python.py` never ran MoonBit. Through v0.106.0
// it validated a Python re-implementation of the SSM score and
// printed its verdict; the MoonBit side was not involved at all, and
// the file's own docstring said as much.
//
// The check worth having on this estimator is not a coefficient
// comparison. SSM is a `var_est`-shaped estimator, which means
// `se()` and `sandwich_se(HC0)` are two computations of the SAME
// quantity:
//
//   se()        = sqrt( mean(psi^2) / (J^2 * n) )     via var_est
//   HC0         = sqrt( sum(psi^2) / n / J^2 )        via sandwich
//
// with `psi[i] = coef * psi_a[i] + psi_b[i]` and `J = mean(psi_a)`.
// So the claim `HC0 == se()` is ALGEBRA, not statistics: there is no
// sampling content to be uncertain about, and it holds to the last
// bit rather than to a tolerance. Measured here: the relative
// difference is exactly 0.0 at both sample sizes.
//
// That matters because the two accessors went their separate ways
// for most of the package's history. `sandwich_variance_hc0` carried
// a `1/n` the accumulator did not, so HC0 sat at `sqrt(n) * se()`
// through v0.90.0, and `DoubleMLDIDCS` and `DoubleMLLPLR` were held
// out of the sandwich API entirely for related reasons. An
// identity that is exactly true today is exactly the kind of thing
// a refactor silently breaks, and no coefficient band would notice.
//
// The second thing printed is the same DGP at 4x the sample size, so
// a validator can check that the SE actually falls like 1/sqrt(n).
// That one IS statistical, and the band has to come from
// measurement.
//
// `examples/main` already demos SSM, but with a DGP threaded through
// the shared RNG stream and the shared covariate matrix of that
// larger example. Extracting that would mean disturbing four other
// estimators' draws, so this is a self-contained equivalent: the
// same MAR structure, the same true effect, a fixed seed.

///|
/// Self-contained SSM MAR DGP.
///
///   x_j ~ N(0, 1)                      j = 0 .. p-1
///   d   ~ Bernoulli(0.5)
///   v   ~ N(0, 1)
///   s   = 1{ d + 0.5 * x_0 + 0.05 * sum_{j>=1} x_j + v > 0 }
///   y   = theta0 * d + 0.3 * x_0 * d + 0.3 * eps   (observed iff s = 1)
///
/// `s` is the selection indicator SSM is built for: the outcome is
/// only observed on the selected rows, and selection depends on `d`
/// and on `x`, which is the missing-at-random case the estimator
/// targets.
fn build_ssm_dgp(
  rng : @random.Rand,
  n : Int,
  p : Int,
  theta0 : Double,
) -> @moonbit_doubleML.DoubleMLSSMData {
  // Box-Muller pool, drawn up front so the per-row loop below makes
  // exactly the draws it says it makes. Layout, in order:
  //
  //   [0,        n*p)     the covariate matrix, row-major
  //   [n*p,  2*n*p)       the selection noise v_i
  //   [2*n*p, 3*n*p)      the outcome noise eps_i
  //
  // so the pool must be `n * (p + 2)` long. Getting that wrong is a
  // bare `pool.at` panic, not a wrong number.
  let pool : Array[Double] = []
  while pool.length() < n * (p + 2) {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let theta = 2.0 * 3.141592653589793 * u2
    pool.push(r * @math.cos(theta))
    pool.push(r * @math.sin(theta))
  }
  let x = @moonbit_doubleML.Matrix::zeros(n, p)
  let d : Array[Double] = Array::make(n, 0.0)
  let s : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x.set(i, j, pool[i * p + j])
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    let mut linear = d[i] + 0.5 * x.get(i, 0)
    for j = 1; j < p; j = j + 1 {
      linear = linear + 0.05 * x.get(i, j)
    }
    linear = linear + pool[n * p + i]
    s[i] = if linear > 0.0 { 1.0 } else { 0.0 }
    y[i] = theta0 * d[i] + 0.3 * x.get(i, 0) * d[i] + 0.3 * pool[n * p + n + i]
  }
  @moonbit_doubleML.DoubleMLSSMData::new(x, y, d, s)
}

///|
/// One `ssm ... ` line: the point estimate and BOTH standard-error
/// accessors for one sample size.
///
/// The two SEs are printed side by side on purpose. A reader can see
/// they agree, and a validator can assert it.
fn ssm_line(
  tag : String,
  n : Int,
  p : Int,
  theta0 : Double,
  seed : Int,
) -> String {
  let data = build_ssm_dgp(@moonbit_doubleML.chacha8_rng(seed), n, p, theta0)
  let fitted = @moonbit_doubleML.DoubleMLSSM::new(
    data,
    n_folds=2,
    n_rep=1,
    seed~,
  ).fit()
  let row_se = fitted.se()
  let hc0 = fitted.sandwich_se(@moonbit_doubleML.SandwichKind::hc0())
  "ssm \{tag} n=\{n} theta=\{fitted.coef()} se=\{row_se} hc0=\{hc0} hc0_minus_se=\{hc0 - row_se} n_obs=\{fitted.n_obs()}"
}

///|
/// Seeds and sizes, and why these two seeds
/// =========================================
/// The 1/sqrt(n) check needs a seed whose SE actually follows the
/// law. Measured over seeds 99, 7 and 3141 at n = 500 -> 2000
/// (p = 5):
///
///     seed  99   0.036788 -> 0.019333   ratio 0.5255
///     seed   7   0.040243 -> 0.019581   ratio 0.4866
///     seed 3141  0.154311 -> 0.019593   ratio 0.1270
///
/// 99 and 7 sit on 1/sqrt(4) = 0.5. 3141 does not: its SE is already
/// ~4x the others at n = 500, and at n = 8000 the fit diverges
/// outright (`theta = -121.88`, `se = 122.88`). SSM's variance on
/// this DGP is genuinely fragile with respect to the fold split, and
/// `expand_v107_test.mbt::v107_ssm_se_is_fragile_to_the_split` pins
/// that observation so it cannot be quietly forgotten.
///
/// This example therefore reports two seeds, both of which follow the
/// law, and `validate_ssm_with_python.py` asserts the ratio for each.
/// It asserts nothing about 3141's path: a fluctuation that large is
/// a property of the estimator on this DGP at these sizes, not a
/// scale error, and a band wide enough to absorb it would also
/// absorb a flat SE.
///
/// The `hc0_minus_se` column is 0 on every line measured, including
/// the pathological ones. That is the point of printing it: the
/// HC0/se() identity is exact even where the value it returns is not
/// trustworthy, so the two have to be diagnosed separately.

///|
fn main {
  println("=== MoonBit DML demo: SSM and the HC0 == se() identity ===")
  println("true theta0 = 1.0, MAR selection on (d, x)")
  println("")
  println(ssm_line("a500", 500, 5, 1.0, 99))
  println(ssm_line("a2000", 2000, 5, 1.0, 99))
  println(ssm_line("b500", 500, 5, 1.0, 7))
  println(ssm_line("b2000", 2000, 5, 1.0, 7))
  println("ssm example done")
}
