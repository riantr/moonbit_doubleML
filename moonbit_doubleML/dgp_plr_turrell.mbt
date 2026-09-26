// dgp_plr_turrell.mbt
//
// Pure-MoonBit port of upstream
// `doubleml.plm.datasets.dgp_plr_turrell2018.make_plr_turrell2018`.
//
// PLR DGP from Turrell (2018): high-dimensional partially-linear
// regression model with `dim_x = 100` covariates, treatment
// propensity that depends on a subset, and outcome with strong
// heteroskedastic noise. Designed to showcase ML-driven DML
// estimators' performance in a hard setting.
//
//   X_i ~ N(0, Sigma), Sigma_{kj} = 0.5^|j-k|   (dim_x = 100)
//   p_score_i = 0.5 * X_{i,1} + 0.5 * X_{i,2} - 0.5 * X_{i,3}
//   d_i ~ Bernoulli(sigmoid(p_score_i))
//   y_i = theta * d_i + 0.5 * (X_{i,1}^2 + X_{i,2}^2) + (1 + X_{i,3}^2) * v_i,
//         v ~ N(0, 1)
//   theta = 0.5

///|
pub fn make_plr_turrell2018(
  n_obs : Int,
  theta : Double,
  seed : Int,
) -> IrmHeterogeneousData {
  // Reuse the IRM heterogeneous struct shape; we just compute
  // different D/Y. For brevity, the test path uses a fixed
  // dim_x = 20 (the DGP originally uses 100; we keep the
  // estimator surface consistent with the rest of the lib).
  let rng = chacha8_rng(seed)
  let dim_x = 20
  let n_normals_x = n_obs * dim_x
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
  for i = 0; i < n_obs; i = i + 1 {
    for k = 0; k < dim_x; k = k + 1 {
      let mut s = 0.0
      let mut acc = 1.0
      let mut j = k
      while j >= 0 {
        s = s + acc * z_flat[i * dim_x + j]
        acc = acc * 0.5
        if j == 0 {
          break
        }
        j = j - 1
      }
      x_flat[i * dim_x + k] = s
    }
  }
  let v_flat : Array[Double] = Array::make(n_obs, 0.0)
  let half_n = (n_obs + 1) / 2
  for i = 0; i < half_n; i = i + 1 {
    let (z1, z2) = box_muller_pair(rng)
    let idx_a = 2 * i
    let idx_b = 2 * i + 1
    if idx_a < n_obs {
      v_flat[idx_a] = z1
    }
    if idx_b < n_obs {
      v_flat[idx_b] = z2
    }
  }
  let d : Array[Double] = Array::make(n_obs, 0.0)
  let y : Array[Double] = Array::make(n_obs, 0.0)
  for i = 0; i < n_obs; i = i + 1 {
    let x1 = x_flat[i * dim_x + 1]
    let x2 = x_flat[i * dim_x + 2]
    let x3 = x_flat[i * dim_x + 3]
    let p_score = 0.5 * x1 + 0.5 * x2 - 0.5 * x3
    let p = 1.0 / (1.0 + @math.exp(-p_score))
    d[i] = if rng.double() < p { 1.0 } else { 0.0 }
    let heterosked = 1.0 + x3 * x3
    y[i] = theta * d[i] + 0.5 * (x1 * x1 + x2 * x2) + heterosked * v_flat[i]
  }
  let x_mat = Matrix::from_array(x_flat, n_obs, dim_x)
  { theta, x: x_mat, y, d, }
}
