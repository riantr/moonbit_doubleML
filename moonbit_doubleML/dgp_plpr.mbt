// dgp_plpr.mbt
//
// Pure-MoonBit port of upstream
// `doubleml.plm.datasets.dgp_plpr_CP2025.make_plpr_CP2025`.
//
// PLPR (Panel PLR) DGP from Chernozhukov & Pokatilov (2025): a
// panel-data extension of the PLR model with unit fixed effects
// (alpha_i) and time fixed effects (beta_t).
//
// Panel layout:
//   - n_units units, n_periods periods.
//   - alpha_i ~ N(0, 1)  // unit FE
//   - beta_t ~ N(0, 1)  // time FE
//   - X_{i,t} ~ N(0, Sigma)  // dim_x covariates per unit-period
//   - D_{i,t} = alpha_i + 0.5 * X_{i,t,1} + 0.5 * X_{i,t,2}
//              + 1.0 * z_{i,t} + eta_i + eta_t
//     (continuous, with auto-correlation in eta)
//   - z_{i,t} ~ Bernoulli(0.5)  // instrument
//   - Y_{i,t} = theta * D_{i,t} + alpha_i + beta_t
//              + 0.5 * X_{i,t,1} + 0.5 * X_{i,t,2} + eps_{i,t}

///|
/// Result of the PLPR DGP.
struct PlprData {
  /// True causal parameter (theta in upstream DGP).
  theta : Double
  /// Number of panel units.
  n_units : Int
  /// Number of time periods.
  n_periods : Int
  /// Outcome vector (length n_units * n_periods).
  y : Array[Double]
  /// Treatment vector (continuous).
  d : Array[Double]
  /// Covariate matrix (n_obs x dim_x).
  x : Matrix
}

///|
/// Generate the PLPR DGP. `n_obs` is the *target* total sample
/// size; the actual n is `n_units * n_periods`.
pub fn make_plpr_CP2025(
  n_obs : Int,
  dim_x : Int,
  theta : Double,
  seed : Int,
) -> PlprData {
  let rng = chacha8_rng(seed)
  let n_periods = 4
  let n_units = n_obs / n_periods
  let true_n = n_units * n_periods
  // 1. Pre-draw X-draw normals.
  let n_normals_x = true_n * dim_x
  let z_flat : Array[Double] = Array::make(n_normals_x, 0.0)
  let half_z = (n_normals_x + 1) / 2
  for i = 0; i < half_z; i = i + 1 {
    let (z1, z2) = box_muller_pair(rng)
    let idx_a = 2 * i
    let idx_b = 2 * i + 1
    if idx_a < n_normals_x {
      z_flat[idx_a] = z1
    }
    if idx_b < n_normals_x {
      z_flat[idx_b] = z2
    }
  }
  let x_flat : Array[Double] = Array::make(n_normals_x, 0.0)
  for i = 0; i < true_n; i = i + 1 {
    for k = 0; k < dim_x; k = k + 1 {
      let mut s = 0.0
      let mut acc = 1.0
      let mut j = k
      while j >= 0 {
        s = s + acc * z_flat[i * dim_x + j]
        acc = acc * 0.7
        if j == 0 {
          break
        }
        j = j - 1
      }
      x_flat[i * dim_x + k] = s
    }
  }
  // 2. Pre-draw unit FE, time FE, eps.
  let alpha : Array[Double] = Array::make(n_units, 0.0)
  let beta_t : Array[Double] = Array::make(n_periods, 0.0)
  let eps : Array[Double] = Array::make(true_n, 0.0)
  let half_a = (n_units + 1) / 2
  for i = 0; i < half_a; i = i + 1 {
    let (z1, _) = box_muller_pair(rng)
    if i < n_units {
      alpha[i] = z1
    }
  }
  let half_b = (n_periods + 1) / 2
  for i = 0; i < half_b; i = i + 1 {
    let (z1, _) = box_muller_pair(rng)
    if i < n_periods {
      beta_t[i] = z1
    }
  }
  let half_n = (true_n + 1) / 2
  for i = 0; i < half_n; i = i + 1 {
    let (z1, z2) = box_muller_pair(rng)
    let idx_a = 2 * i
    let idx_b = 2 * i + 1
    if idx_a < true_n {
      eps[idx_a] = z1
    }
    if idx_b < true_n {
      eps[idx_b] = z2
    }
  }
  // 3. Build panel: layout outer = unit, inner = period.
  let y : Array[Double] = Array::make(true_n, 0.0)
  let d : Array[Double] = Array::make(true_n, 0.0)
  for u = 0; u < n_units; u = u + 1 {
    for p = 0; p < n_periods; p = p + 1 {
      let idx = u * n_periods + p
      let x1 = x_flat[idx * dim_x + 1]
      let x2 = x_flat[idx * dim_x + 2]
      // Continuous D with unit FE and time-invariant component.
      let z_it = if rng.double() < 0.5 { 1.0 } else { 0.0 }
      d[idx] = alpha[u] +
        0.5 * x1 +
        0.5 * x2 +
        1.0 * z_it +
        0.5 * alpha[u] +
        0.3 * beta_t[p]
      let _ = z_it
      y[idx] = theta * d[idx] +
        alpha[u] +
        beta_t[p] +
        0.5 * x1 +
        0.5 * x2 +
        eps[idx]
    }
  }
  let x_mat = Matrix::from_array(x_flat, true_n, dim_x)
  { theta, n_units, n_periods, y, d, x: x_mat, }
}

///|
pub fn PlprData::theta_get(self : PlprData) -> Double {
  self.theta
}

///|
pub fn PlprData::y_get(self : PlprData) -> Array[Double] {
  self.y
}

///|
pub fn PlprData::d_get(self : PlprData) -> Array[Double] {
  self.d
}

///|
pub fn PlprData::x_get(self : PlprData) -> Matrix {
  self.x
}

///|
pub fn PlprData::n_units_get(self : PlprData) -> Int {
  self.n_units
}

///|
pub fn PlprData::n_periods_get(self : PlprData) -> Int {
  self.n_periods
}
