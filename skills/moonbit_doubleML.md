# moonbit_doubleML skill

Conventions for AI coding agents working on this codebase. Mirrors
moonbit-community/rabbita's `skills/rabbita.md` layout (one
`skills/<name>.md` per repo documenting the library's preferred API
surface and anti-patterns).

# Basic requirement

- prefer the public `DoubleML*::new(...).fit()` API over hand-rolling
  score / nuisance / influence-function plumbing. The 17 estimators
  exposed here already implement the upstream doubleml-for-py
  semantics; reuse them.

- reach for `@moonbit_doubleML.*` relative imports rather than fully
  qualified `riantr/moonbit_doubleML.*` paths. The relative alias
  is what the rest of the codebase uses; the fully-qualified form
  is only needed at the `examples/<bin>/moon.pkg` boundary.

- cross-file field reads use the `_get()` suffix (e.g.
  `fitted.coef_get()`, `fitted.se_at(g, t)`). MoonBit requires
  `pub` for cross-struct field access, so the getter is the
  canonical read path. Direct field reads compile inside the same
  file but fail across file boundaries.

# Tests

- keep `*_test.mbt` next to the production file it covers (no
  separate `tests/` directory). The `moon check` build expects
  every test file to start with `test` or `panic_test`.

- regression tests for upstream doubleml-for-py v0.11.x go in
  `*_parity_test.mbt` and assert against the hand-rolled reference
  built by `validate_*_with_python.py`.

- DGP recovery tests go in `dgp_recovery_test.mbt` and check that
  the estimator's `coef()` recovers the true `theta` to within
  `MAX(MODEL_TOL=0.1, 2.0 * handrolled_se)`. Do NOT loosen the
  tolerance without a written reason in the commit message.

# Source layout

- all production `.mbt` files live at the package root (flat
  layout). The 17 estimators (`DoubleMLPLR`, `DoubleMLIRM`,
  `DoubleMLPLIV`, `DoubleMLIIVM`, `DoubleMLDID`,
  `DoubleMLDIDBinary`, `DoubleMLDIDCS`, `DoubleMLDIDMulti`,
  `DoubleMLDIDCrossSection`, `DoubleMLSSM`, `DoubleMLAPO`,
  `DoubleMLAPOS`, `DoubleMLPQ`, `DoubleMLQTE`, `DoubleMLLPQ`,
  `DoubleMLCVAR`, `DoubleMLRDD`, `DoubleMLBLP`,
  `DoubleMLPolicyTree`) are each their own `<name>.mbt` file
  with a sibling `<name>_test.mbt`.

- 35 DGP modules live at root as `dgp_*.mbt` with sibling
  `dgp_*_test.mbt`. The shared Box-Muller helper is in `seed.mbt`.

- 12 command drivers live under `examples/<bin>/main.mbt` and each
  declare `"riantr/moonbit_doubleML"` in their `moon.pkg`. New
  command drivers follow the same pattern.

- Python cross-validators live at root as `validate_*.py`. They
  re-derive the hand-rolled reference for one model and compare
  against the MoonBit output. Keep the script name aligned with
  the estimator it validates.

# Anti-patterns

- do NOT introduce a `Map[K, V]`. MoonBit 0.10.11 deprecated the
  built-in Map; use `Array[(K, V)]` and linear scan, or use a
  per-key fixed-size array when the key range is small.

- do NOT name a field `train` or `test`. Both are reserved in
  current MoonBit; use `train_idx` / `test_idx`.

- do NOT use `ref`, `dyn`, `with`, `assert`, or `var` as
  identifiers — all are reserved keywords.

- do NOT introduce classifier learners (RandomForest, XGBoost,
  etc.). Upstream's scikit-learn interface is intentionally not
  ported; the single closed-form `LinearRegression` learner
  (Cholesky + 1e-10 ridge) is the project's design choice.

- do NOT bypass `--deny-warn`. The CI runs
  `moon test --target {native,wasm-gc,wasm,js} --deny-warn` and
  fails on any warning. Pre-existing warnings block the build
  until cleaned up.

- do NOT relax `MAX(MODEL_TOL=0.1, ...)` in
  `dgp_recovery_test.mbt` without a documented reason. This is
  the contract that the upstream parity tests verify.

# Cross-validators

- each `validate_<estimator>_with_python.py` script must produce
  exactly one trailing line that contains `PASS` (or `passed`).
  The CI loop `for s in validate_*_with_python.py; do python $s
  | tail -1; done` greps for that token.

- new estimators MUST come with a new `validate_<name>_with_python.py`
  script in the same commit. No estimator lands without a Python
  cross-check.

# Determinism

- all randomness goes through the `chacha8_rng(seed)` helper from
  `seed.mbt`. Use `seed=3141` as the default; deviate only with
  a comment explaining why.

- synthetic DGP outputs are byte-identical across runs given the
  same seed. If a test starts to flake, the DGP is leaking
  nondeterminism (likely via `Random::new()` instead of the seeded
  RNG); fix the DGP, not the test.
