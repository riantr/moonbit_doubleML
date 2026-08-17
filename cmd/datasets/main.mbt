// Demo entry point: synthetic 401(k)-style DGP for the DML PLR and
// IRM estimators. Reproduces the spirit of the upstream
// `doubleml.datasets.fetch_401K` example (Chernozhukov et al. 2018,
// Table 1) without depending on the upstream `.dta` file. The DGP
// below captures the qualitative features of the 401(k) study —
// binary `e401` (eligible for 401(k)), continuous `net_tfa` (net
// total financial assets), and 9 controls (`age`, `inc`, `educ`,
// `fsize`, `marr`, `twoearn`, `db`, `pira`, `hown`) — but the
// coefficients and noise distribution are synthetic. Use this as
// a smoke test for the productionised estimator: it should land
// within a few SE of the true effect `theta_0 = 1.5` and the
// `n_rep = 5` aggregation should tighten the SE further.

///|
fn box_muller_pair(rng : @random.Rand) -> (Double, Double) {
  let u1 = rng.double()
  let u2 = rng.double()
  let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
  let r = (-2.0 * @math.ln(safe)).sqrt()
  let theta = 2.0 * 3.141592653589793 * u2
  (r * @math.cos(theta), r * @math.sin(theta))
}

///|
fn main {
  let n = 4000
  let p = 9
  let theta0 = 1.5
  let seed = 1111
  let rng = @dml.chacha8_rng(seed)
  // Draw 9 features x n + residuals: 9 * n normals from Box-Muller.
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  for i = 0; i < (n * p + 2 * n) / 2; i = i + 1 {
    let (z1, z2) = box_muller_pair(rng)
    let idx_a = 2 * i
    let idx_b = 2 * i + 1
    if idx_a < n * p {
      x_flat[idx_a] = z1
    }
    if idx_b < n * p {
      x_flat[idx_b] = z2
    }
  }
  // Logistic propensity for `e401`: linear in (age, inc, educ).
  let p_score : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    p_score[i] = -1.5 +
      0.05 * x_flat[i * p] +
      0.02 * x_flat[i * p + 1] +
      0.1 * x_flat[i * p + 2]
  }
  // Outcome: y = theta * e401 + x @ 1 + noise.
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let noise_pool : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < (n + 1) / 2; i = i + 1 {
    let (z1, z2) = box_muller_pair(rng)
    let idx_a = 2 * i
    let idx_b = 2 * i + 1
    if idx_a < n {
      noise_pool[idx_a] = z1
    }
    if idx_b < n {
      noise_pool[idx_b] = z2
    }
  }
  for i = 0; i < n; i = i + 1 {
    // Sigmoid via the tanh form to avoid `@math.exp` here.
    let p_clip = if p_score[i] < -20.0 {
      -20.0
    } else if p_score[i] > 20.0 {
      20.0
    } else {
      p_score[i]
    }
    d[i] = if rng.double() < 1.0 / (1.0 + @math.exp(-p_clip)) {
      1.0
    } else {
      0.0
    }
    let mut s = noise_pool[i]
    for j = 0; j < p; j = j + 1 {
      s = s + x_flat[i * p + j]
    }
    y[i] = theta0 * d[i] + s
  }
  let x_mat = @dml.Matrix::from_array(x_flat, n, p)
  let data = @dml.DoubleMLData::new(x_mat, y, d)
  println(
    "=== MoonBit DML demo: synthetic 401(k)-style DGP (n=\{n}, p=\{p}) ===",
  )
  println("true theta_0      = \{theta0}")
  let plr = @dml.DoubleMLPLR::new(data, n_folds=2, n_rep=1, seed=3141)
  let plr_fit = plr.fit()
  let (lo, hi) = plr_fit.confint()
  println("")
  println("--- DoubleMLPLR (partialling out, n_rep=1) ---")
  println("theta_hat = \{plr_fit.coef()}")
  println("se        = \{plr_fit.se()}")
  println("95% CI    = [\{lo}, \{hi}]")
  let plr5 = @dml.DoubleMLPLR::new(data, n_folds=2, n_rep=5, seed=3141)
  let plr5_fit = plr5.fit()
  println("--- DoubleMLPLR (n_rep=5) ---")
  println("theta_hat = \{plr5_fit.coef()}")
  println("se        = \{plr5_fit.se()}")
  let irm = @dml.DoubleMLIRM::new(data, n_folds=2, n_rep=1, seed=3141)
  let irm_fit = irm.fit()
  let (ilo, ihi) = irm_fit.confint()
  println("")
  println("--- DoubleMLIRM (ATE, n_rep=1) ---")
  println("theta_hat = \{irm_fit.coef()}")
  println("se        = \{irm_fit.se()}")
  println("95% CI    = [\{ilo}, \{ihi}]")
  let irm5 = @dml.DoubleMLIRM::new(data, n_folds=2, n_rep=5, seed=3141)
  let irm5_fit = irm5.fit()
  println("--- DoubleMLIRM (n_rep=5) ---")
  println("theta_hat = \{irm5_fit.coef()}")
  println("se        = \{irm5_fit.se()}")
}
