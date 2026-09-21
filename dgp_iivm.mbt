// dgp_iivm.mbt
//
// Pure-MoonBit port of upstream
// `doubleml.irm.datasets.dgp_iivm_data.make_iivm_data`.
//
// IIVM (Instrumental Variable in the Interactive Regression Model)
// data generating process for the partially-linear IV model from
// Chernozhukov et al. (2018), Section 4.4:
//
//   z_i ~ Bernoulli(0.5),     // instrument
//   d_i = sigmoid(x_i @ beta + gamma * z_i) noise is implicit in
//          the logit draw (Bernoulli(propensity)),
//   y_i = theta * d_i + x_i @ beta_y + noise,
//   v_i ~ N(0, 1) used in both treatment and outcome draws.
//
// We follow the upstream default structure with `dim_x = 20`
// covariates, `theta = 1.0`, `gamma = 0.5` (instrument strength),
// `beta_x = 0.5` (X coefficient in both equations), and
// `beta_z = 1.0` (instrument coefficient on the treatment
// equation only).

///|
/// Result of the IIVM DGP.
struct IivmData {
  /// Causal parameter used in `y = theta * d + g(X) + noise`.
  theta : Double
  /// `Matrix` of shape `(n_obs, dim_x)`.
  x : Matrix
  /// Outcome vector of length `n_obs`.
  y : Array[Double]
  /// Treatment vector of length `n_obs` (binary, drawn from
  /// propensity that includes `z`).
  d : Array[Double]
  /// Instrument vector of length `n_obs` (binary).
  z : Array[Double]
}

///|
/// Generate the IIVM DGP from Chernozhukov et al. (2018) Section 4.4.
pub fn make_iivm_data(
  n_obs : Int,
  dim_x : Int,
  theta : Double,
  seed : Int,
) -> IivmData {
  let rng = chacha8_rng(seed)
  let beta_x = 0.5
  let beta_z = 1.0
  // 1. Pre-draw n_obs * dim_x standard normals.
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
  // 2. Build X ~ N(0, Sigma) via lower-triangular L.
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
  // 3. Pre-draw v ~ N(0, 1) for the outcome noise.
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
  // 4. Build d (binary treatment), z (instrument), and y.
  let d : Array[Double] = Array::make(n_obs, 0.0)
  let z : Array[Double] = Array::make(n_obs, 0.0)
  let y : Array[Double] = Array::make(n_obs, 0.0)
  for i = 0; i < n_obs; i = i + 1 {
    // Instrument: Bernoulli(0.5).
    z[i] = if rng.double() < 0.5 { 1.0 } else { 0.0 }
    // Treatment propensity: dot(X, beta_x) + beta_z * z_i.
    let mut xb = 0.0
    for k = 0; k < dim_x; k = k + 1 {
      xb = xb + beta_x * x_flat[i * dim_x + k]
    }
    let propensity_score = xb + beta_z * z[i]
    let p = 1.0 / (1.0 + @math.exp(-propensity_score))
    d[i] = if rng.double() < p { 1.0 } else { 0.0 }
    // Outcome: theta * d + dot(X, beta_x) + v.
    y[i] = theta * d[i] + xb + v_flat[i]
  }
  let x_mat = Matrix::from_array(x_flat, n_obs, dim_x)
  { theta, x: x_mat, y, d, z }
}

///|
/// Get the causal parameter (theta).
pub fn IivmData::theta_get(self : IivmData) -> Double {
  self.theta
}

///|
/// Get the design matrix.
pub fn IivmData::x_get(self : IivmData) -> Matrix {
  self.x
}

///|
/// Get the outcome vector.
pub fn IivmData::y_get(self : IivmData) -> Array[Double] {
  self.y
}

///|
/// Get the treatment vector.
pub fn IivmData::d_get(self : IivmData) -> Array[Double] {
  self.d
}

///|
/// Get the instrument vector.
pub fn IivmData::z_get(self : IivmData) -> Array[Double] {
  self.z
}