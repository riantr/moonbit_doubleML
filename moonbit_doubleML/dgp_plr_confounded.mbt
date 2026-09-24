// dgp_plr_confounded.mbt
//
// Pure-MoonBit port of upstream
// `doubleml.plm.datasets.dgp_confounded_plr_data.make_confounded_plr_data`.
//
// PLR DGP with a single confounder `c_i` affecting both
// treatment and outcome:
//
//   c_i ~ Bernoulli(0.5)
//   p_score_i = 0.5 * c_i + 0.5 * X_{i,1}
//   d_i ~ Bernoulli(sigmoid(p_score_i))
//   y_i = theta * d_i + 0.5 * X_{i,1} + c_i + v_i,  v ~ N(0, 1)
//   X ~ N(0, Sigma)

///|
struct PlrConfoundedData {
  theta : Double
  x : Matrix
  y : Array[Double]
  d : Array[Double]
  c : Array[Double]
}

///|
pub fn make_confounded_plr_data(
  n_obs : Int,
  dim_x : Int,
  theta : Double,
  seed : Int,
) -> PlrConfoundedData {
  let rng = chacha8_rng(seed)
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
  let c : Array[Double] = Array::make(n_obs, 0.0)
  let d : Array[Double] = Array::make(n_obs, 0.0)
  let y : Array[Double] = Array::make(n_obs, 0.0)
  for i = 0; i < n_obs; i = i + 1 {
    c[i] = if rng.double() < 0.5 { 1.0 } else { 0.0 }
    let x1 = x_flat[i * dim_x + 1]
    let p_score = 0.5 * c[i] + 0.5 * x1
    let p = 1.0 / (1.0 + @math.exp(-p_score))
    d[i] = if rng.double() < p { 1.0 } else { 0.0 }
    y[i] = theta * d[i] + 0.5 * x1 + c[i] + v_flat[i]
  }
  let x_mat = Matrix::from_array(x_flat, n_obs, dim_x)
  { theta, x: x_mat, y, d, c }
}

///|
pub fn PlrConfoundedData::theta_get(self : PlrConfoundedData) -> Double {
  self.theta
}

///|
pub fn PlrConfoundedData::x_get(self : PlrConfoundedData) -> Matrix {
  self.x
}

///|
pub fn PlrConfoundedData::y_get(self : PlrConfoundedData) -> Array[Double] {
  self.y
}

///|
pub fn PlrConfoundedData::d_get(self : PlrConfoundedData) -> Array[Double] {
  self.d
}

///|
pub fn PlrConfoundedData::c_get(self : PlrConfoundedData) -> Array[Double] {
  self.c
}