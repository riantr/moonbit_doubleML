// dgp_irm_discrete.mbt
//
// Pure-MoonBit port of upstream
// `doubleml.irm.datasets.dgp_irm_data_discrete_treatments.make_dgp_irm_data_discrete_treatments`.
//
// IRM DGP with discrete treatment in {0, 1, 2, 3} (a 4-level
// multivalued treatment) and a propensity score per level:
//
//   p_0_i = 0.1,  p_1_i = 0.2,  p_2_i = 0.3,  p_3_i = 0.4
//   d_i ~ Categorical(p_0, p_1, p_2, p_3)  // max-pool draw
//   y_i = theta * d_i + 0.5 * X_{i,1} + 0.5 * X_{i,2} + v_i,
//         v ~ N(0, 1)
//   X ~ N(0, Sigma), Sigma_{kj} = 0.7^|j-k|

///|
struct IrmDiscreteData {
  theta : Double
  x : Matrix
  y : Array[Double]
  d : Array[Double]
}

///|
pub fn make_irm_discrete_treatments(
  n_obs : Int,
  dim_x : Int,
  theta : Double,
  seed : Int,
) -> IrmDiscreteData {
  let rng = chacha8_rng(seed)
  // Pre-draw X-draw normals.
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
        acc = acc * 0.7
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
  let p = [0.1, 0.2, 0.3, 0.4]
  let cum = [0.1, 0.3, 0.6, 1.0]
  for i = 0; i < n_obs; i = i + 1 {
    let u = rng.double()
    let mut d_i = 0.0
    if u < cum[0] {
      d_i = 0.0
    } else if u < cum[1] {
      d_i = 1.0
    } else if u < cum[2] {
      d_i = 2.0
    } else {
      d_i = 3.0
    }
    let _ = p
    d[i] = d_i
    let x1 = x_flat[i * dim_x + 1]
    let x2 = x_flat[i * dim_x + 2]
    y[i] = theta * d_i + 0.5 * x1 + 0.5 * x2 + v_flat[i]
  }
  let x_mat = Matrix::from_array(x_flat, n_obs, dim_x)
  { theta, x: x_mat, y, d }
}

///|
pub fn IrmDiscreteData::theta_get(self : IrmDiscreteData) -> Double {
  self.theta
}

///|
pub fn IrmDiscreteData::x_get(self : IrmDiscreteData) -> Matrix { self.x }

///|
pub fn IrmDiscreteData::y_get(self : IrmDiscreteData) -> Array[Double] {
  self.y
}

///|
pub fn IrmDiscreteData::d_get(self : IrmDiscreteData) -> Array[Double] {
  self.d
}