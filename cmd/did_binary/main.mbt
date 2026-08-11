// Demo: synthetic panel DID DGP running DoubleMLDIDBinary.
// 200 units × 2 periods (pre, post); half are treated (g=1), half
// never-treated (g=0). True ATT = 1.0.

///|
fn main {
  let n_units = 400
  let p = 3
  let theta0 = 1.0
  let n = n_units * 2
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  let bytes = @dml.seed_to_bytes(7)
  let rng = @random.Rand::chacha8(seed=Bytes::from_array(bytes))
  for u = 0; u < n_units; u = u + 1 {
    let xu : Array[Double] = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      xu[j] = rng.double() * 2.0 - 1.0
    }
    let is_treated = if u % 2 == 0 { 1 } else { 0 }
    for k = 0; k < 2; k = k + 1 {
      let row = 2 * u + k
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = xu[j]
      }
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = is_treated
      d[row] = if is_treated == 1 && k == 1 { 1.0 } else { 0.0 }
      let mut y_val = 0.0
      for j = 0; j < p; j = j + 1 {
        y_val = y_val + xu[j]
      }
      if k == 1 && is_treated == 1 {
        y_val = y_val + theta0
      }
      y_val = y_val + 0.05 * (rng.double() - 0.5)
      y[row] = y_val
    }
  }
  let data = @dml.DoubleMLDIDBinaryData::new(
    @dml.Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    g_arr,
    id_arr,
  )
  let fitted = @dml.DoubleMLDIDBinary::new(
    data,
    1,
    0,
    1,
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let (lo, hi) = fitted.confint()
  println("=== MoonBit DML demo: DID Binary (panel, n_units=\{n_units}, p=\{p}) ===")
  println("true ATT = \{theta0}")
  println("")
  println("--- DoubleMLDIDBinary (observational, never_treated control) ---")
  println("n_obs_subset = \{fitted.n_obs_subset()}")
  println("ATT_hat     = \{fitted.coef()}")
  println("se          = \{fitted.se()}")
  println("95% CI      = [\{lo}, \{hi}]")
}