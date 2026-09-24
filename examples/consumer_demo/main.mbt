///|
// consumer_demo: minimal end-to-end PLR usage.
//
// This file is what a downstream library user would write after
// `moon add riantr/moonbit_doubleML`. It demonstrates the full
// workflow: build design matrix + treatment + outcome, wrap in
// DoubleMLData, construct an estimator, fit, and read back results.
//
// The first run is bit-exactly reproducible given the same seed
// across all 4 supported backends (native, wasm, wasm-gc, js).

///|
fn main {
  let n = 100
  let p = 5

  // 1. Build a (n, p) design matrix filled with structured data.
  //    First column carries treatment signal, the rest are controls.
  let x_data : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let v = i.to_double()
    x_data[i * p + 0] = v
    x_data[i * p + 1] = (i % 2).to_double()
    x_data[i * p + 2] = ((i + 1) % 3).to_double()
    x_data[i * p + 3] = ((i + 2) % 5).to_double()
    x_data[i * p + 4] = ((i + 3) % 7).to_double()
    d[i] = v * 0.5
    y[i] = v * 1.0 + (i % 2).to_double()
  }
  let x : @moonbit_doubleML.Matrix = @moonbit_doubleML.Matrix::from_array(
    x_data, n, p,
  )

  // 2. Wrap into the data container.
  let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)

  // 3. Construct + fit a PLR estimator (default n_folds=2, seed=3141).
  let fitted = @moonbit_doubleML.DoubleMLPLR::new(data).fit()

  // 4. Read off the estimated coefficient + 95% CI.
  let theta = fitted.coef()
  let se = fitted.se()
  let (lo, hi) = fitted.confint()

  // 5. Print. (True θ = 1.0 by construction.)
  println("=== consumer_demo: minimal PLR ===")
  println("estimated theta = \{theta}")
  println("standard error   = \{se}")
  println("95% CI           = (\{lo}, \{hi})")
  println("contains 1.0?    = \{lo <= 1.0 && 1.0 <= hi}")
}