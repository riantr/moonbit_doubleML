// dgp_ssm.mbt
//
// Pure-MoonBit port of upstream
// `doubleml.irm.datasets.dgp_ssm_data.make_ssm_data`.
//
// SSM (Sample Selection Model) DGP from Heckman-style selection
// framework. Treatment `d` is binary, selection indicator `s` is
// binary, and outcome `y` is observed only when `s == 1` (and
// NaN otherwise, but the upstream DGP returns the latent outcome
// without selection for parity with the rest of the DGPs). The
// parameter of interest is `theta` in the outcome equation.
//
//   propensity_d = sigmoid(0.5 * X_{i,1} + 0.5 * X_{i,2})
//   propensity_s = sigmoid(0.5 * X_{i,1} - 0.5 * X_{i,2})
//   d_i ~ Bernoulli(propensity_d)
//   s_i ~ Bernoulli(propensity_s)
//   y_i = theta * d_i + 0.5 * X_{i,1} + 0.5 * X_{i,2} + v_i,
//         v ~ N(0, 1).
//   X ~ N(0, Sigma), Sigma_{kj} = 0.7^|j-k|.

///|
/// Result of the SSM DGP.
struct SsmData {
  /// Causal parameter.
  theta : Double
  /// Covariate matrix.
  x : Matrix
  /// Outcome (latent; not selection-filtered in this port).
  y : Array[Double]
  /// Binary treatment.
  d : Array[Double]
  /// Binary selection indicator.
  s : Array[Double]
}

///|
/// Generate the SSM DGP.
pub fn make_ssm_data(
  n_obs : Int,
  dim_x : Int,
  theta : Double,
  seed : Int,
) -> SsmData {
  let rng = chacha8_rng(seed)
  // 1. Pre-draw X-draw normals.
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
  // 2. Build X via lower-triangular L.
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
  // 3. Pre-draw v ~ N(0, 1).
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
  // 4. Build d, s, y.
  let d : Array[Double] = Array::make(n_obs, 0.0)
  let s : Array[Double] = Array::make(n_obs, 0.0)
  let y : Array[Double] = Array::make(n_obs, 0.0)
  for i = 0; i < n_obs; i = i + 1 {
    let x1 = x_flat[i * dim_x + 1]
    let x2 = x_flat[i * dim_x + 2]
    let p_d_score = 0.5 * x1 + 0.5 * x2
    let p_s_score = 0.5 * x1 - 0.5 * x2
    let p_d = 1.0 / (1.0 + @math.exp(-p_d_score))
    let p_s = 1.0 / (1.0 + @math.exp(-p_s_score))
    d[i] = if rng.double() < p_d { 1.0 } else { 0.0 }
    s[i] = if rng.double() < p_s { 1.0 } else { 0.0 }
    y[i] = theta * d[i] + 0.5 * x1 + 0.5 * x2 + v_flat[i]
  }
  let x_mat = Matrix::from_array(x_flat, n_obs, dim_x)
  { theta, x: x_mat, y, d, s, }
}

///|
pub fn SsmData::theta_get(self : SsmData) -> Double {
  self.theta
}

///|
pub fn SsmData::x_get(self : SsmData) -> Matrix {
  self.x
}

///|
pub fn SsmData::y_get(self : SsmData) -> Array[Double] {
  self.y
}

///|
pub fn SsmData::d_get(self : SsmData) -> Array[Double] {
  self.d
}

///|
pub fn SsmData::s_get(self : SsmData) -> Array[Double] {
  self.s
}
