// dgp_did_cs_CS2021.mbt
//
// Pure-MoonBit port of upstream
// `doubleml.did.datasets.dgp_did_cs_CS2021.make_did_cs_CS2021`.
//
// Callaway & Sant'Anna (2021) staggered-adoption DID DGP for the
// "2x2" group-time average treatment effect on the treated
// (ATT(g, t)). Adapted to the MoonBit lib's `DoubleMLDIDCSData`
// surface (continuous treatment `d`, time, group, id vectors; X is
// a covariate matrix).
//
// Setup:
//   - n_groups groups, n_periods periods.
//   - Each group g in {0, 1, ..., n_groups-1} has treatment timing
//     tau_g = ceil(g / n_periods_indicator); here we use the
//     upstream "single treated cohort" pattern (one group treated
//     at tau_g = 1, never-treated cohort g = 0).
//   - Outcome Y is generated per the partially-linear DGP
//     with covariates X drawn from N(0, Sigma).
//   - DGP (CS2021 Eq. 1.1, simplified to 2-period 2-group):
//       Y_{i,t} = alpha_i + beta_t + theta * D_{i,t}
//                  + X_i @ gamma + epsilon_{i,t},
//     where D_{i,t} = 1{g_i <= t} * 1{group i is treated}.
//
// We replicate the canonical 2-cohort 2-period case: one treated
// cohort with g=1 (treated at t=1) and one never-treated cohort
// (g=0). Y is generated with the true ATT equal to `theta`.

///|
/// Result of the DID CS2021 DGP.
struct DidCsData {
  /// True ATT parameter.
  theta : Double
  /// Number of cohorts (groups) in the panel.
  n_groups : Int
  /// Number of time periods.
  n_periods : Int
  /// Outcome vector (length n_obs = n_groups * cohort_size * n_periods).
  y : Array[Double]
  /// Treatment indicator (length n_obs; binary).
  d : Array[Double]
  /// Time index (length n_obs; integer 0..n_periods-1).
  t : Array[Int]
  /// Group/treatment-cohort index (length n_obs; integer 0..n_groups-1).
  g : Array[Int]
  /// Unit id within cohort (length n_obs; integer 0..cohort_size-1).
  id : Array[Int]
  /// Covariate matrix (n_obs x dim_x).
  x : Matrix
}

///|
/// Generate the DID CS2021 DGP. Default: 2 cohorts, 2 periods,
/// `theta = 1.0`, balanced cohort sizes, `n_per_cohort = 200`,
/// `dim_x = 3`.
pub fn make_did_cs_CS2021(
  n_obs : Int,
  dim_x : Int,
  theta : Double,
  seed : Int,
) -> DidCsData {
  let rng = chacha8_rng(seed)
  // 2 cohorts, 2 periods, equal cohort sizes; cohort 0 = never-treated,
  // cohort 1 = treated at t=1.
  let n_periods = 2
  let n_groups = 2
  let n_per_cohort = n_obs / n_groups / n_periods
  let true_n = n_per_cohort * n_groups * n_periods
  // 1. Pre-draw X-draw normals (n_units * dim_x).
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
  // 2. Build unit-level X (n_units x dim_x) via lower-triangular L.
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
  // 3. Pre-draw time-varying noise (n_units * n_periods).
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
  // 4. Build panel y, d, t, g, id. Layout: outer = unit, inner = period.
  let y : Array[Double] = Array::make(true_n, 0.0)
  let d : Array[Double] = Array::make(true_n, 0.0)
  let t : Array[Int] = Array::make(true_n, 0)
  let g : Array[Int] = Array::make(true_n, 0)
  let id : Array[Int] = Array::make(true_n, 0)
  for u = 0; u < n_units; u = u + 1 {
    let cohort = u / n_per_cohort
    let unit_in_cohort = u % n_per_cohort
    let is_treated = cohort > 0
    let tau_g = if is_treated { 1 } else { -1 } // never-treated sentinel
    for period = 0; period < n_periods; period = period + 1 {
      let idx = u * n_periods + period
      // Treatment indicator: post-treatment for treated cohort.
      d[idx] = if is_treated && period >= tau_g { 1.0 } else { 0.0 }
      // Outcome: alpha_i + beta_t + theta * D + X_i @ gamma + eps
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
  // Expand X to panel (each unit's X is repeated n_periods times).
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
/// Get the true ATT parameter.
pub fn DidCsData::theta_get(self : DidCsData) -> Double {
  self.theta
}

///|
/// Get the outcome vector.
pub fn DidCsData::y_get(self : DidCsData) -> Array[Double] {
  self.y
}

///|
/// Get the treatment vector.
pub fn DidCsData::d_get(self : DidCsData) -> Array[Double] {
  self.d
}

///|
/// Get the time-period index.
pub fn DidCsData::t_get(self : DidCsData) -> Array[Int] {
  self.t
}

///|
/// Get the group (cohort) index.
pub fn DidCsData::g_get(self : DidCsData) -> Array[Int] {
  self.g
}

///|
/// Get the unit id (within cohort).
pub fn DidCsData::id_get(self : DidCsData) -> Array[Int] {
  self.id
}

///|
/// Get the covariate matrix (panel-level, n_obs x dim_x).
pub fn DidCsData::x_get(self : DidCsData) -> Matrix {
  self.x
}

///|
/// Get the number of cohorts.
pub fn DidCsData::n_groups_get(self : DidCsData) -> Int {
  self.n_groups
}

///|
/// Get the number of periods.
pub fn DidCsData::n_periods_get(self : DidCsData) -> Int {
  self.n_periods
}