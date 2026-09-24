# Introduction

`riantr/moonbit_doubleML` is a pure-MoonBit port of the
[`doubleml-for-py`](https://github.com/DoubleML/doubleml-for-py) Python
package, covering all 17 models currently in upstream.

## What is Double / Debiased Machine Learning?

Double Machine Learning (DML) is a framework for estimating causal
parameters in high-dimensional settings. The classical application
is partially linear regression:

  Y = θ · D + g(X, U) + ε

where you want to recover θ but nuisance functions `g` are too
flexible for direct estimation. DML orthogonalises the treatment
D from the controls X, fits a separate model for the residual, and
combines them with cross-fitting so the influence function is
Neyman-orthogonal (insensitive to first-order errors in g).

## Why port to MoonBit?

The pure-MoonBit implementation:

- **No Python FFI, no native add-ons** — the only external deps are
  `moonbitlang/core/random` and `moonbitlang/core/math`.
- **Same numerical semantics as upstream** — verified by
  `validate_*_with_python.py` cross-checkers (24 scripts, all PASS
  at v0.52.0).
- **Cross-platform WASM** — `moon build --target wasm-gc` produces
  a self-contained estimator that runs in browsers and Node.js.
- **Single learner** — the closed-form `LinearRegression`
  (Cholesky + 1e-10 ridge) handles every nuisance function,
  avoiding scikit-learn compatibility.

## Status at v0.52.0

- **17 estimators** — PLR, IRM, PLIV, IIVM, DID (5 variants),
  SSM, APO(S), PQ/QTE, LPQ, CVaR, RDB, BLP, PolicyTree.
- **35 DGPs** — covering all upstream doubleml-for-py
  `make_*_data` factories.
- **415 / 415 tests pass** on native (wasm-gc, wasm, js similar).
- **0 errors** under `moon test --deny-warn`.
- **Published to mooncakes.io** as `riantr/moonbit_doubleML@0.52.0`.

## Next

- See `002_installation` for setup instructions.
- See `003_quick_start` for a 30-line end-to-end example.
- See `004_estimators` for the full estimator catalogue.