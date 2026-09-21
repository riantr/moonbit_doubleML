// dgp_lplr.mbt
//
// Pure-MoonBit port of upstream
// `doubleml.plm.datasets.dgp_lplr_LZZ2020.make_lplr_LZZ2020`.
//
// LPLR (Logistic PLR) DGP from Liu, Zhang, Zhou (2021) — a
// partially-logistic-regression model with binary treatment and
// binary outcome:
//
//   r_0(x) = 0.25 * x_1 * x_2 + 0.25 * x_3^2 + 0.25 * cos(x_4)
//            - 0.5 * sin(x_5) + 1[x_6 > 0] - 0.5
//   a_0(x) = 0.5 * sin(x_1) + 0.5 * cos(x_2)
//   a_i = a_0(x_i) + 0.5 * noise_i
//   d_i ~ Bernoulli(sigmoid(a_i))
//   p_i = sigmoid(alpha * d_i + r_0(x_i))
//   y_i ~ Bernoulli(p_i)
//
// `alpha = 0.5` is the true causal parameter. The covariate
// design is rich enough that the closed-form logistic/linear
// learners estimate nuisances well at n = 500.
//
// This is the same DGP that was previously inlined as
// `build_lzz2020_dgp` in `lplr_test.mbt`; we promote it to a
// top-level module so callers outside `lplr_test` can use it.

///|
/// Result of the LPLR LZZ2020 DGP.
struct LplrData {
  /// True causal parameter (alpha in the upstream DGP).
  theta : Double
  /// `DoubleMLBinaryData` (x, y, d) ready for `DoubleMLLPLR::new`.
  data : DoubleMLBinaryData
}

///|
/// Generate the LPLR LZZ2020 DGP.
pub fn make_lplr_LZZ2020(
  n : Int,
  alpha : Double,
  seed : Int,
) -> LplrData {
  let p = 6
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let rng = chacha8_rng(seed)
  // Box-Muller pool: enough normals for x (n*p) + noise (n).
  let need = n * p + n
  let pool : Array[Double] = Array::make(need, 0.0)
  let half = (need + 1) / 2
  for i = 0; i < half; i = i + 1 {
    let (z1, z2) = box_muller_pair(rng)
    let idx_a = 2 * i
    let idx_b = 2 * i + 1
    if idx_a < need {
      pool[idx_a] = z1
    }
    if idx_b < need {
      pool[idx_b] = z2
    }
  }
  for i = 0; i < n * p; i = i + 1 {
    x_flat[i] = pool[i]
  }
  // Treatment: a_0(x) + 0.5 * noise, then Bernoulli via sigmoid.
  for i = 0; i < n; i = i + 1 {
    let x1 = x_flat[i * p]
    let x2 = x_flat[i * p + 1]
    let a = 0.5 * @math.sin(x1) + 0.5 * @math.cos(x2) + 0.5 * pool[n * p + i]
    let p_t = 1.0 / (1.0 + @math.exp(-a))
    let u = rng.double()
    d[i] = if u < p_t { 1.0 } else { 0.0 }
  }
  // Outcome.
  for i = 0; i < n; i = i + 1 {
    let x1 = x_flat[i * p]
    let x2 = x_flat[i * p + 1]
    let x3 = x_flat[i * p + 2]
    let x4 = x_flat[i * p + 3]
    let x5 = x_flat[i * p + 4]
    let x6 = x_flat[i * p + 5]
    let r = 0.25 * x1 * x2 +
      0.25 * x3 * x3 +
      0.25 * @math.cos(x4) -
      0.5 * @math.sin(x5) +
      (if x6 > 0.0 { 1.0 } else { 0.0 }) -
      0.5
    let prob = 1.0 / (1.0 + @math.exp(-(alpha * d[i] + r)))
    let u = rng.double()
    y[i] = if u < prob { 1.0 } else { 0.0 }
  }
  let data = DoubleMLBinaryData::new(
    Matrix::from_array(x_flat, n, p), y, d,
  )
  { theta: alpha, data }
}

///|
/// Get the true causal parameter.
pub fn LplrData::theta_get(self : LplrData) -> Double { self.theta }

///|
/// Get the underlying `DoubleMLBinaryData`.
pub fn LplrData::data_get(self : LplrData) -> DoubleMLBinaryData {
  self.data
}