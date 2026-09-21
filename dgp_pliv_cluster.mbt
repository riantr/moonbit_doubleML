// dgp_pliv_cluster.mbt
//
// Pure-MoonBit port of upstream
// `doubleml.plm.datasets.dgp_pliv_multiway_cluster_CKMS2021.make_pliv_multiway_cluster_CKMS2021`.
//
// PLIV DGP with multiway (two-dimensional) cluster structure
// from Cameron, Kelchtermans, Miller, Schmeiser (2021).
// Cluster ids are integers; observations are nested in
// `(cluster_a, cluster_b)` pairs.
//
//   cluster_a_i ~ Uniform{1, ..., n_clusters_a}
//   cluster_b_i ~ Uniform{1, ..., n_clusters_b}
//   X_i ~ N(0, Sigma)  // dim_x covariates
//   z_i ~ Bernoulli(0.5)  // instrument
//   p_score_i = sigmoid(0.5 * X_{i,1} + 0.5 * X_{i,2} + 1.0 * z_i
//                       + cluster_a_effect_a + cluster_b_effect_b)
//   d_i ~ Bernoulli(p_score_i)
//   y_i = theta * d_i + 0.5 * X_{i,1} + 0.5 * X_{i,2} + v_i, v ~ N(0, 1)
//
//   cluster_a_effect_a ~ N(0, 0.5^2)  // random cluster effect (A)
//   cluster_b_effect_b ~ N(0, 0.5^2)  // random cluster effect (B)

///|
struct PlivClusterData {
  theta : Double
  x : Matrix
  y : Array[Double]
  d : Array[Double]
  z : Array[Double]
  cluster_a : Array[Int]
  cluster_b : Array[Int]
}

///|
pub fn make_pliv_multiway_cluster(
  n_obs : Int,
  dim_x : Int,
  theta : Double,
  seed : Int,
) -> PlivClusterData {
  let rng = chacha8_rng(seed)
  let n_clusters_a = 50
  let n_clusters_b = 50
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
  // Cluster effects.
  let ca_effects : Array[Double] = Array::make(n_clusters_a, 0.0)
  let cb_effects : Array[Double] = Array::make(n_clusters_b, 0.0)
  let max_ca = (n_clusters_a + 1) / 2
  for i = 0; i < max_ca; i = i + 1 {
    let (z1, _) = box_muller_pair(rng)
    if i < n_clusters_a {
      ca_effects[i] = 0.5 * z1
    }
  }
  let max_cb = (n_clusters_b + 1) / 2
  for i = 0; i < max_cb; i = i + 1 {
    let (z1, _) = box_muller_pair(rng)
    if i < n_clusters_b {
      cb_effects[i] = 0.5 * z1
    }
  }
  // Build cluster ids + z, d, y.
  let cluster_a : Array[Int] = Array::make(n_obs, 0)
  let cluster_b : Array[Int] = Array::make(n_obs, 0)
  let z : Array[Double] = Array::make(n_obs, 0.0)
  let d : Array[Double] = Array::make(n_obs, 0.0)
  let y : Array[Double] = Array::make(n_obs, 0.0)
  for i = 0; i < n_obs; i = i + 1 {
    cluster_a[i] = (rng.int(limit=n_clusters_a) + 1) % n_clusters_a
    cluster_b[i] = (rng.int(limit=n_clusters_b) + 1) % n_clusters_b
    z[i] = if rng.double() < 0.5 { 1.0 } else { 0.0 }
    let x1 = x_flat[i * dim_x + 1]
    let x2 = x_flat[i * dim_x + 2]
    let p_score = 0.5 * x1 + 0.5 * x2 + 1.0 * z[i] +
      ca_effects[cluster_a[i]] + cb_effects[cluster_b[i]]
    let p = 1.0 / (1.0 + @math.exp(-p_score))
    d[i] = if rng.double() < p { 1.0 } else { 0.0 }
    y[i] = theta * d[i] + 0.5 * x1 + 0.5 * x2 + v_flat[i]
  }
  let x_mat = Matrix::from_array(x_flat, n_obs, dim_x)
  { theta, x: x_mat, y, d, z, cluster_a, cluster_b }
}

///|
pub fn PlivClusterData::theta_get(self : PlivClusterData) -> Double {
  self.theta
}

///|
pub fn PlivClusterData::x_get(self : PlivClusterData) -> Matrix { self.x }

///|
pub fn PlivClusterData::y_get(self : PlivClusterData) -> Array[Double] {
  self.y
}

///|
pub fn PlivClusterData::d_get(self : PlivClusterData) -> Array[Double] {
  self.d
}

///|
pub fn PlivClusterData::z_get(self : PlivClusterData) -> Array[Double] {
  self.z
}

///|
pub fn PlivClusterData::cluster_a_get(
  self : PlivClusterData,
) -> Array[Int] {
  self.cluster_a
}

///|
pub fn PlivClusterData::cluster_b_get(
  self : PlivClusterData,
) -> Array[Int] {
  self.cluster_b
}