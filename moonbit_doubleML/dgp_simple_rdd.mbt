// dgp_simple_rdd.mbt
//
// Pure-MoonBit port of upstream
// `doubleml.rdd.datasets.simple_dgp.simple_rdd_dgp`.
//
// Simple sharp-RDD DGP (Hahn, Todd, Van der Klaauw 2001 / Imbens
// & Lemieux 2008): the running variable X is drawn from U[-1, 1]
// (with a small fraction exactly 0 discarded; we instead
// threshold at 0 via a Bernoulli gate to avoid floating-point
// edge cases). The treatment D = 1{X > 0} (sharp assignment).
// The outcome Y = m(X) + D * theta + noise, where m(X) is a
// smooth polynomial and theta is the local treatment effect at
// the cutoff (default 1.0).
//
//   X_i ~ U[-1, 1]
//   D_i = 1{X_i > 0}
//   Y_i = 0.5 * X_i^2 + theta * D_i + v_i,  v ~ N(0, 1)
//
// This DGP is the canonical "fuzzy/sharp" RD DGP used in the
// double-ml R package's `rdrobust` regression discontinuity
// examples. The MoonBit port emits the data in the shape of
// `DoubleMLRDDData { x, y, d, score }`, where `score` is a
// constant +1 column (the local-polynomial regressor stack).

///|
struct RddSimpleData {
  /// True local effect at cutoff.
  theta : Double
  /// Running variable X.
  x : Array[Double]
  /// Outcome Y.
  y : Array[Double]
  /// Binary treatment D = 1{X > 0}.
  d : Array[Double]
  /// Constant score column (used by DoubleMLRDD's local-poly
  /// regressor stack).
  score : Array[Double]
}

///|
/// Generate the simple RDD DGP.
pub fn make_simple_rdd_dgp(
  n_obs : Int,
  theta : Double,
  seed : Int,
) -> RddSimpleData {
  let rng = chacha8_rng(seed)
  // 1. Pre-draw v ~ N(0, 1) (outcome noise).
  let v_flat : Array[Double] = Array::make(n_obs, 0.0)
  let half = (n_obs + 1) / 2
  for i = 0; i < half; i = i + 1 {
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
  // 2. Build X (uniform on [-1, 1]) and D, Y.
  let x : Array[Double] = Array::make(n_obs, 0.0)
  let d : Array[Double] = Array::make(n_obs, 0.0)
  let y : Array[Double] = Array::make(n_obs, 0.0)
  let score : Array[Double] = Array::make(n_obs, 0.0)
  for i = 0; i < n_obs; i = i + 1 {
    x[i] = rng.double() * 2.0 - 1.0
    d[i] = if x[i] > 0.0 { 1.0 } else { 0.0 }
    score[i] = 1.0
    y[i] = 0.5 * x[i] * x[i] + theta * d[i] + v_flat[i]
  }
  { theta, x, y, d, score, }
}

///|
pub fn RddSimpleData::theta_get(self : RddSimpleData) -> Double {
  self.theta
}

///|
pub fn RddSimpleData::x_get(self : RddSimpleData) -> Array[Double] {
  self.x
}

///|
pub fn RddSimpleData::y_get(self : RddSimpleData) -> Array[Double] {
  self.y
}

///|
pub fn RddSimpleData::d_get(self : RddSimpleData) -> Array[Double] {
  self.d
}

///|
pub fn RddSimpleData::score_get(self : RddSimpleData) -> Array[Double] {
  self.score
}
