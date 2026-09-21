// dgp_did_CS2021.mbt
//
// Pure-MoonBit port of upstream
// `doubleml.did.datasets.dgp_did_CS2021.make_did_CS2021`.
//
// Callaway & Sant'Anna (2021) staggered-adoption DID DGP for the
// multi-cohort "long" panel form (used by `DoubleMLDIDMulti`).
// Multi-period treatment timing: each cohort g in {0, 1, ...,
// n_groups - 1} is treated at tau_g = max(1, g - n_groups_never),
// with cohort 0 being the never-treated sentinel.
//
// Layout: outer = unit, inner = period. Y, D, T, G, ID arrays of
// length n_obs = n_per_cohort * n_groups * n_periods.

///|
/// Result of the DID CS2021 multi-cohort DGP.
struct DidMultiData {
  /// True ATT parameter.
  theta : Double
  /// Number of cohorts (groups).
  n_groups : Int
  /// Number of time periods.
  n_periods : Int
  /// Outcome vector.
  y : Array[Double]
  /// Treatment indicator.
  d : Array[Double]
  /// Time-period index.
  t : Array[Int]
  /// Group/cohort index.
  g : Array[Int]
  /// Unit id within cohort.
  id : Array[Int]
  /// Covariate matrix (panel-level).
  x : Matrix
}

///|
/// Generate the multi-cohort DID DGP. `n_obs` is the *target*
/// total sample size; the actual n is `n_per_cohort * n_groups *
/// n_periods`. The function chooses `n_per_cohort` to match
/// `n_obs`.
pub fn make_did_CS2021(
  n_obs : Int,
  dim_x : Int,
  theta : Double,
  seed : Int,
) -> DidMultiData {
  let rng = chacha8_rng(seed)
  let n_periods = 4
  let n_groups = 4
  let n_per_cohort = n_obs / n_groups / n_periods
  let true_n = n_per_cohort * n_groups * n_periods
  // Pre-draw unit-level X-draw normals.
  let n_units = n_per_cohort * n_groups
  let n_normals_x = n_units * dim_x
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
  // Build unit-level X.
  let x_unit : Array[Double] = Array::make(n_normals_x, 0.0)
  for i = 0; i < n_units; i = i + 1 {
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
      x_unit[i * dim_x + k] = s
    }
  }
  // Pre-draw time-varying noise.
  let eps : Array[Double] = Array::make(true_n, 0.0)
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
  // Build panel. Cohort g=0 is never-treated; cohort g>=1 is
  // treated at tau_g = g - 1 (so cohort 1 treated at t=1, etc.).
  let y : Array[Double] = Array::make(true_n, 0.0)
  let d : Array[Double] = Array::make(true_n, 0.0)
  let t : Array[Int] = Array::make(true_n, 0)
  let g : Array[Int] = Array::make(true_n, 0)
  let id : Array[Int] = Array::make(true_n, 0)
  for u = 0; u < n_units; u = u + 1 {
    let cohort = u / n_per_cohort
    let unit_in_cohort = u % n_per_cohort
    let tau_g = if cohort == 0 { -1 } else { cohort - 1 }
    for period = 0; period < n_periods; period = period + 1 {
      let idx = u * n_periods + period
      d[idx] = if cohort > 0 && period >= tau_g { 1.0 } else { 0.0 }
      let mut x_dot_gamma = 0.0
      for k = 0; k < dim_x; k = k + 1 {
        x_dot_gamma = x_dot_gamma + x_unit[u * dim_x + k]
      }
      let alpha_i = 0.5 * unit_in_cohort.to_double()
      let beta_t = 0.3 * period.to_double()
      y[idx] = alpha_i + beta_t + theta * d[idx] + x_dot_gamma + eps[idx]
      t[idx] = period
      g[idx] = cohort
      id[idx] = unit_in_cohort
    }
  }
  // Expand X to panel.
  let x_panel_flat : Array[Double] = Array::make(true_n * dim_x, 0.0)
  for u = 0; u < n_units; u = u + 1 {
    for p = 0; p < n_periods; p = p + 1 {
      let panel_row = u * n_periods + p
      for k = 0; k < dim_x; k = k + 1 {
        x_panel_flat[panel_row * dim_x + k] = x_unit[u * dim_x + k]
      }
    }
  }
  let x_panel = Matrix::from_array(x_panel_flat, true_n, dim_x)
  { theta, n_groups, n_periods, y, d, t, g, id, x: x_panel }
}

///|
pub fn DidMultiData::theta_get(self : DidMultiData) -> Double {
  self.theta
}

///|
pub fn DidMultiData::y_get(self : DidMultiData) -> Array[Double] {
  self.y
}

///|
pub fn DidMultiData::d_get(self : DidMultiData) -> Array[Double] {
  self.d
}

///|
pub fn DidMultiData::t_get(self : DidMultiData) -> Array[Int] {
  self.t
}

///|
pub fn DidMultiData::g_get(self : DidMultiData) -> Array[Int] {
  self.g
}

///|
pub fn DidMultiData::id_get(self : DidMultiData) -> Array[Int] {
  self.id
}

///|
pub fn DidMultiData::x_get(self : DidMultiData) -> Matrix {
  self.x
}

///|
pub fn DidMultiData::n_groups_get(self : DidMultiData) -> Int {
  self.n_groups
}

///|
pub fn DidMultiData::n_periods_get(self : DidMultiData) -> Int {
  self.n_periods
}