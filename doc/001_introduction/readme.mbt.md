# Introduction

`riantr/moonbit_doubleML` is a pure-MoonBit port of the
[`doubleml-for-py`](https://github.com/DoubleML/doubleml-for-py) Python
package. It covers all 21 estimator classes upstream ships in
0.11.4 -- 19 under the same name, `DoubleMLRDD` for upstream's `RDFlex`
and `DoubleMLDIDCrossSection` for upstream's `DoubleMLDIDCS` -- and adds
one port-only estimator (`DoubleMLDIDCS`), for 22 in total.

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

- **No Python FFI, no native add-ons** — the library imports no
  third-party package at all. `moon.mod` does declare two entries,
  `moonbitlang/async@0.22.5` and `moonbit-community/sqlite3@0.2.3`,
  but no `.mbt` in the library imports either one (measured: 0
  references each), so they are dead entries rather than runtime
  dependencies.
- **Same numerical semantics as upstream** — verified by
  `validate_*_with_python.py` cross-checkers (24 scripts, each
  reporting `PASS` on its trailing line).
- **Cross-platform WASM** — `moon build --target wasm-gc` produces
  a self-contained estimator that runs in browsers and Node.js.
- **Pure-MoonBit learners** — no scikit-learn. The port ships 11
  `LearnerDispatch` variants: 8 regressors (`LinearRegression`,
  `Constant`, `Noop`, `RandomForest`, `GradientBoosting`, `Ridge`,
  `Lasso`, `ElasticNet`) and 3 classifiers (`LogisticRegression`,
  `RandomForestClassifier`, `GradientBoostingClassifier`).
  `ml_m` defaults to the logistic classifier wherever the
  propensity enters the score as `1 / m_hat`.

## Status at v0.164.36

- **22 estimators** — PLR, IRM, PLIV, IIVM, DID (6 variants),
  SSM, APO(S), PQ/QTE, LPQ, LPLR, PLPR, CVaR, RDD, BLP, PolicyTree.
- **18 DGP factories** across 17 `dgp_*.mbt` modules (35 files
  counting the `dgp_*_test.mbt` siblings), ported from upstream's
  `make_*_data` factories.
- **1117 / 1117 tests pass** on native.
- **0 errors** under `moon test --deny-warn`.
- **Published to mooncakes.io** as `riantr/moonbit_doubleML@0.164.36`.

## Next

- See `002_installation` for setup instructions.
- See `003_quick_start` for a 35-line end-to-end example.
- See `004_estimators` for the full estimator catalogue.
