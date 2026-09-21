// dgp_plr_CCDDHNR.mbt
//
// Pure-MoonBit port of upstream
// `doubleml.plm.datasets.dgp_plr_CCDDHNR2018.make_plr_CCDDHNR2018`.
//
// DGP from Chernozhukov, Chetverikov, Demirer, Duflo, Hansen,
// Newey, Robins (2018) "Double/debiased machine learning for
// treatment and structural parameters", Econometrics Journal 21:
// C1-C68, doi:10.1111/ecoj.12097, Figure 1 (a partially linear
// regression model with confounded continuous `d` and `y`).
//
// The data generating process (DGP) is
//
//   d_i = a_0 * x_{i,1} + a_1 * sigmoid(x_{i,3})
//         + s_1 * v_i, & v_i ~ N(0, 1),
//
//   y_i = theta * d_i + b_0 * sigmoid(x_{i,1})
//         + b_1 * x_{i,3} + s_2 * zeta_i,
//         & zeta_i ~ N(0, 1),
//
//   with covariates x_i ~ N(0, Sigma),
//   where Sigma_{kj} = 0.7^|j-k|.
//
// Defaults: a_0=1.0, a_1=0.25, b_0=1.0, b_1=0.25, s_1=1.0, s_2=1.0.
//
// The MoonBit port omits the upstream `return_type` parameter
// (`DataFrame` / `DoubleMLData` / tuple); callers wrap the result in
// `DoubleMLData::new(...)` as needed.

///|
/// Result of the PLR CCDDHNR 2018 DGP.
struct PlrCcddhnr2018 {
  /// Causal parameter used in `y = theta * d + g(X) + noise`.
  theta : Double
  /// `Matrix` of shape `(n_obs, dim_x)`.
  x : Matrix
  /// Outcome vector of length `n_obs`.
  y : Array[Double]
  /// Treatment vector of length `n_obs`.
  d : Array[Double]
}

///|
/// Generate the PLR DGP from Chernozhukov et al. (2018) Figure 1.
pub fn make_plr_CCDDHNR2018(
  n_obs : Int,
  dim_x : Int,
  theta : Double,
  seed : Int,
) -> PlrCcddhnr2018 {
  let a_0 = 1.0
  let a_1 = 0.25
  let b_0 = 1.0
  let b_1 = 0.25
  let s_1 = 1.0
  let s_2 = 1.0
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
  // 2. Build X ~ N(0, Sigma) with Sigma_{kj} = 0.7^|j-k| via
  //    the closed-form lower-triangular L (L_{kj} = 0.7^(k-j)
  //    for k >= j). Store X in row-major order.
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
  // 3. Pre-draw v, zeta ~ N(0, 1) independently via Box-Muller.
  let v_flat : Array[Double] = Array::make(n_obs, 0.0)
  let zeta_flat : Array[Double] = Array::make(n_obs, 0.0)
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
  for i = 0; i < half_n; i = i + 1 {
    let (z1, z2) = box_muller_pair(rng)
    let idx_a = 2 * i
    let idx_b = 2 * i + 1
    if idx_a < n_obs {
      zeta_flat[idx_a] = z1
    }
    if idx_b < n_obs {
      zeta_flat[idx_b] = z2
    }
  }
  // 4. Build d and y per the DGP formula.
  let d : Array[Double] = Array::make(n_obs, 0.0)
  let y : Array[Double] = Array::make(n_obs, 0.0)
  for i = 0; i < n_obs; i = i + 1 {
    let x1 = x_flat[i * dim_x + 1]
    let x3 = x_flat[i * dim_x + 3]
    let sig3 = 1.0 / (1.0 + @math.exp(-x3))
    let sig1 = 1.0 / (1.0 + @math.exp(-x1))
    d[i] = a_0 * x1 + a_1 * sig3 + s_1 * v_flat[i]
    y[i] = theta * d[i] + b_0 * sig1 + b_1 * x3 + s_2 * zeta_flat[i]
  }
  let x_mat = Matrix::from_array(x_flat, n_obs, dim_x)
  { theta, x: x_mat, y, d }
}

///|
/// Get the causal parameter (theta).
pub fn PlrCcddhnr2018::theta_get(self : PlrCcddhnr2018) -> Double {
  self.theta
}

///|
/// Get the design matrix.
pub fn PlrCcddhnr2018::x_get(self : PlrCcddhnr2018) -> Matrix {
  self.x
}

///|
/// Get the outcome vector.
pub fn PlrCcddhnr2018::y_get(self : PlrCcddhnr2018) -> Array[Double] {
  self.y
}

///|
/// Get the treatment vector.
pub fn PlrCcddhnr2018::d_get(self : PlrCcddhnr2018) -> Array[Double] {
  self.d
}

///|
/// Box-Muller pair (mu=0, sigma=1). Mirrors the helper in
/// `cmd/datasets/main.mbt`.
fn box_muller_pair(rng : @random.Rand) -> (Double, Double) {
  let u1 = rng.double()
  let u2 = rng.double()
  let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
  let r = (-2.0 * @math.ln(safe)).sqrt()
  let theta = 2.0 * 3.141592653589793 * u2
  (r * @math.cos(theta), r * @math.sin(theta))
}