// dgp_irm.mbt
//
// Pure-MoonBit port of upstream
// `doubleml.irm.datasets.dgp_irm_data.make_irm_data`.
//
// IRM (Interactive Regression Model) data generating process from
// Chernozhukov et al. (2018) "Double/debiased machine learning for
// treatment and structural parameters", Econometrics Journal 21:
// C1-C68, Section 4.2. Same partially-linear structure as the PLR
// DGP, but with binary treatment `d` drawn from a logistic
// propensity:
//
//   p_i = sigmoid(0.5 * x_{i,1} + 0.5 * x_{i,2}),
//   d_i ~ Bernoulli(p_i),
//
//   y_i = theta * d_i + 0.5 * sigmoid(x_{i,1})
//         + 0.5 * sigmoid(x_{i,2}) + v_i,
//   v_i ~ N(0, 1),
//
//   X ~ N(0, Sigma),  Sigma_{kj} = 0.7^|j-k|.
//
// The true causal parameter is theta (default 0.5). The MoonBit
// port omits the upstream `return_type` parameter
// (DataFrame/DoubleMLData/tuple).

///|
/// Result of the IRM DGP.
struct IrmData {
  /// Causal parameter used in `y = theta * d + g(X) + noise`.
  theta : Double
  /// `Matrix` of shape `(n_obs, dim_x)`.
  x : Matrix
  /// Outcome vector of length `n_obs`.
  y : Array[Double]
  /// Binary treatment vector of length `n_obs` (0.0 or 1.0).
  d : Array[Double]
}

///|
/// Generate the IRM DGP from Chernozhukov et al. (2018) Section 4.2.
pub fn make_irm_data(
  n_obs : Int,
  dim_x : Int,
  theta : Double,
  seed : Int,
) -> IrmData {
  let rng = chacha8_rng(seed)
  // 1. Pre-draw n_obs * dim_x standard normals via Box-Muller.
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
  // 3. Pre-draw v ~ N(0, 1) (for the outcome noise).
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
  // 4. Build d (binary) and y per the IRM DGP formula.
  let d : Array[Double] = Array::make(n_obs, 0.0)
  let y : Array[Double] = Array::make(n_obs, 0.0)
  for i = 0; i < n_obs; i = i + 1 {
    let x1 = x_flat[i * dim_x + 1]
    let x2 = x_flat[i * dim_x + 2]
    let p_score = 0.5 * x1 + 0.5 * x2
    let p = 1.0 / (1.0 + @math.exp(-p_score))
    d[i] = if rng.double() < p { 1.0 } else { 0.0 }
    let sig1 = 1.0 / (1.0 + @math.exp(-x1))
    let sig2 = 1.0 / (1.0 + @math.exp(-x2))
    y[i] = theta * d[i] + 0.5 * sig1 + 0.5 * sig2 + v_flat[i]
  }
  let x_mat = Matrix::from_array(x_flat, n_obs, dim_x)
  { theta, x: x_mat, y, d, }
}

///|
/// Get the causal parameter (theta).
pub fn IrmData::theta_get(self : IrmData) -> Double {
  self.theta
}

///|
/// Get the design matrix.
pub fn IrmData::x_get(self : IrmData) -> Matrix {
  self.x
}

///|
/// Get the outcome vector.
pub fn IrmData::y_get(self : IrmData) -> Array[Double] {
  self.y
}

///|
/// Get the binary treatment vector.
pub fn IrmData::d_get(self : IrmData) -> Array[Double] {
  self.d
}
