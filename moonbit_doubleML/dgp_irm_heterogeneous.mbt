// dgp_irm_heterogeneous.mbt
//
// Pure-MoonBit port of upstream
// `doubleml.irm.datasets.dgp_heterogeneous_data.make_heterogeneous_data`.
//
// IRM DGP with heterogeneous treatment effects (the parameter
// theta_i varies across observations by a function of X):
//
//   p_score_i = 0.5 * X_{i,1} + 0.5 * X_{i,2}
//   d_i ~ Bernoulli(sigmoid(p_score_i))
//   theta_i = 0.5 + 0.25 * X_{i,1}  // heterogeneous causal effect
//   y_i = theta_i * d_i + 0.5 * sigmoid(X_{i,1}) + 0.5 * sigmoid(X_{i,2})
//         + v_i,  v ~ N(0, 1)
//   X ~ N(0, Sigma),  Sigma_{kj} = 0.7^|j-k|
//
// The ATE (average of theta_i over the population) is still 0.5
// when X_{i,1} has mean 0 (which it does under N(0, Sigma)), but
// the conditional effect varies. Tests check that the recovered
// estimator theta_hat lands near the population ATE.

///|
struct IrmHeterogeneousData {
  /// Average causal parameter (ATE of theta_i over the sample).
  theta : Double
  x : Matrix
  y : Array[Double]
  d : Array[Double]
}

///|
pub fn make_irm_heterogeneous_data(
  n_obs : Int,
  dim_x : Int,
  seed : Int,
) -> IrmHeterogeneousData {
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
  // 2. Build X.
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
  // 4. Build d and y; track per-unit theta_i for the population ATE.
  let d : Array[Double] = Array::make(n_obs, 0.0)
  let y : Array[Double] = Array::make(n_obs, 0.0)
  let mut theta_sum = 0.0
  for i = 0; i < n_obs; i = i + 1 {
    let x1 = x_flat[i * dim_x + 1]
    let x2 = x_flat[i * dim_x + 2]
    let p_score = 0.5 * x1 + 0.5 * x2
    let p = 1.0 / (1.0 + @math.exp(-p_score))
    d[i] = if rng.double() < p { 1.0 } else { 0.0 }
    let theta_i = 0.5 + 0.25 * x1
    theta_sum = theta_sum + theta_i
    let sig1 = 1.0 / (1.0 + @math.exp(-x1))
    let sig2 = 1.0 / (1.0 + @math.exp(-x2))
    y[i] = theta_i * d[i] + 0.5 * sig1 + 0.5 * sig2 + v_flat[i]
  }
  let theta = theta_sum / n_obs.to_double()
  let x_mat = Matrix::from_array(x_flat, n_obs, dim_x)
  { theta, x: x_mat, y, d }
}

///|
pub fn IrmHeterogeneousData::theta_get(self : IrmHeterogeneousData) -> Double {
  self.theta
}

///|
pub fn IrmHeterogeneousData::x_get(self : IrmHeterogeneousData) -> Matrix {
  self.x
}

///|
pub fn IrmHeterogeneousData::y_get(
  self : IrmHeterogeneousData,
) -> Array[Double] {
  self.y
}

///|
pub fn IrmHeterogeneousData::d_get(
  self : IrmHeterogeneousData,
) -> Array[Double] {
  self.d
}