// dgp_did_SZ2020.mbt
//
// Pure-MoonBit port of upstream
// `doubleml.did.datasets.dgp_did_SZ2020.make_did_SZ2020`.
//
// DID DGP from Sant'Anna & Zhao (2020): a 2x2 staggered DID DGP
// with a single treated cohort and a never-treated control.
//
//   - 2 cohorts: cohort 0 = never-treated, cohort 1 = treated at t=1.
//   - 2 periods: t = 0 (pre), t = 1 (post).
//   - Per-unit FE alpha_i ~ N(0, 1).
//   - Per-period FE beta_t ~ N(0, 1).
//   - X ~ N(0, Sigma), dim_x covariates.
//   - Y_{i,t} = alpha_i + beta_t + theta * D_{i,t}
//              + 0.5 * X_{i,1} + 0.5 * X_{i,2} + eps_{i,t}.
//   - D_{i,t} = 1{cohort == 1 AND t >= 1}.

///|
pub fn make_did_SZ2020(
  n_obs : Int,
  dim_x : Int,
  theta : Double,
  seed : Int,
) -> DidCsData {
  // Reuse DidCsData struct shape (y, d, t, g, id, x, theta,
  // n_groups, n_periods). This DGP is the 2-cohort 2-period
  // variant of Callaway-Sant'Anna.
  let rng = chacha8_rng(seed)
  let n_periods = 2
  let n_groups = 2
  let n_per_cohort = n_obs / n_groups / n_periods
  let true_n = n_per_cohort * n_groups * n_periods
  // Pre-draw X-draw normals.
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
  // Unit FE, time FE, eps.
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
  let y : Array[Double] = Array::make(true_n, 0.0)
  let d : Array[Double] = Array::make(true_n, 0.0)
  let t : Array[Int] = Array::make(true_n, 0)
  let g : Array[Int] = Array::make(true_n, 0)
  let id : Array[Int] = Array::make(true_n, 0)
  for u = 0; u < n_units; u = u + 1 {
    let cohort = u / n_per_cohort
    let unit_in_cohort = u % n_per_cohort
    let is_treated = cohort > 0
    let tau_g = if is_treated { 1 } else { -1 }
    for period = 0; period < n_periods; period = period + 1 {
      let idx = u * n_periods + period
      d[idx] = if is_treated && period >= tau_g { 1.0 } else { 0.0 }
      let mut x_dot_gamma = 0.0
      for k = 0; k < dim_x; k = k + 1 {
        x_dot_gamma = x_dot_gamma + 0.5 * x_unit[u * dim_x + k]
      }
      y[idx] = alpha[u] +
        beta_t[period] +
        theta * d[idx] +
        x_dot_gamma +
        eps[idx]
      t[idx] = period
      g[idx] = cohort
      id[idx] = unit_in_cohort
    }
  }
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
  { theta, n_groups, n_periods, y, d, t, g, id, x: x_panel, }
}
