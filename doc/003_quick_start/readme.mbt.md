# Quick Start

A minimal end-to-end example: partially linear regression (PLR) on
synthetic data with θ = 1.

```moonbit nocheck
// 1. Build a (n=100, p=5) design matrix and a treatment + outcome.
let n = 100
let p = 5
let x : @moonbit_doubleML.Matrix = @moonbit_doubleML.Matrix::from_array(
  Array::make(n * p, 0.0),
)
let y : Array[Double] = Array::make(n, 0.0)
let d : Array[Double] = Array::make(n, 0.0)

// ... fill x with N(0, 1) draws, set d = x_1 + ε_d, y = θ · d + x_2 + ε_y
// ... (see examples/datasets for the full RNG-driven construction)

// 2. Wrap into the data container.
let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)

// 3. Construct + fit a PLR estimator.
let fitted = @moonbit_doubleML.DoubleMLPLR::new(
  data,
  n_folds=2,
  n_rep=1,
  seed=3141,
).fit()

// 4. Read off the estimated coefficient, standard error, and CI.
let theta = fitted.coef_get()       // ≈ 1.0
let se = fitted.se_get()           // ≈ 0.1
let (lo, hi) = fitted.confint()    // ≈ (0.8, 1.2) at 95%
```

The `DoubleMLPLR::new(...).fit()` is the canonical entry point.
The same shape applies to all 17 estimators — see
`004_estimators` for the catalogue.

## Cross-platform

The same `DoubleMLPLR::new(...).fit()` call runs on all 4 supported
backends (`native`, `wasm`, `wasm-gc`, `js`). The only backend
divergence is in the floating-point semantics for `next_f64`
chacha8 draws; bit-exact determinism is preserved within each
backend given the same `seed` and `n_rep`.

## Next

- See `004_estimators` for the full estimator catalogue and the
  estimator-specific constructor signatures.
- See `005_dgps` for the 35 DGP factories you can use to test.
- See `006_python_check` for the cross-validation workflow.