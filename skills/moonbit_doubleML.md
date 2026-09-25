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

- access fitted estimates via the named accessor methods (`coef()`,
  `se()`, `confint()`) — not via struct field reads. Cross-struct
  field access needs `pub` getters, but MoonBit's `pub` rule and
  the canonical method form together mean: just call the method.

# Dependency rule (repo-wide)

- Only official (`moonbitlang/*`) packages are allowed.
- Non-official packages may only be `riantr/*` (this repo itself).
- For official packages, pin to the latest published version on the
  registry (e.g. `moonbitlang/async@0.20.3`) and upgrade when
  bumping is intentional.
- Notable consequence: HTTP-service code (e.g.
  `examples/api_server/`) builds directly on `moonbitlang/async`'s
  raw `Server` / `ServerConnection` API rather than adopting a
  third-party web framework (no `bobzhang/crescent`,
  `moonbit-community/rabbita`, etc.).

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

- the library lives at `moonbit_doubleML/` (workspace member). All
  production `.mbt` files are at the package root (flat layout).

- The 17 estimators (`DoubleMLPLR`, `DoubleMLIRM`, `DoubleMLPLIV`,
  `DoubleMLIIVM`, `DoubleMLDID`, `DoubleMLDIDBinary`, `DoubleMLDIDCS`,
  `DoubleMLDIDMulti`, `DoubleMLDIDCrossSection`, `DoubleMLSSM`,
  `DoubleMLAPO`, `DoubleMLAPOS`, `DoubleMLPQ`, `DoubleMLQTE`,
  `DoubleMLLPQ`, `DoubleMLCVAR`, `DoubleMLRDD`, `DoubleMLBLP`,
  `DoubleMLPolicyTree`) are each their own `<name>.mbt` file
  with a sibling `<name>_test.mbt`.

- 35 DGP modules live at root as `dgp_*.mbt` with sibling
  `dgp_*_test.mbt`. The shared Box-Muller helper is in `seed.mbt`.

- 13 command drivers live under `examples/<bin>/main.mbt`. Of these:
  - 12 (`apos`, `consumer_demo`, `cvar`, `datasets`, `did_binary`,
    `did_cross_section`, `did_cs`, `did_cs_binary`, `did_multi`,
    `fuzz`, `lplr`, `main`, `plpr`) are CLI-style numeric demos
    that print true-vs-estimated θ and a 95% CI.
  - `examples/api_server/` is the HTTP service: it declares
    `"riantr/moonbit_doubleML@0.52.0"` in `moon.mod` and consumes
    the library through its public API.

- Python cross-validators live at root as `validate_*.py`. They
  re-derive the hand-rolled reference for one model and compare
  against the MoonBit output. Keep the script name aligned with
  the estimator it validates.

# Anti-patterns

- do NOT introduce a `Map[K, V]` **for estimator / DGP kernel
  code**. MoonBit 0.10.11 deprecated the built-in Map; use
  `Array[(K, V)]` and linear scan, or use a per-key fixed-size
  array when the key range is small. The HTTP plumbing in
  `examples/api_server/main.mbt` is exempt from this rule — it
  uses `Map::of([])` for response headers, where the deprecation
  caveat does not apply.

- do NOT name a field `train` or `test`. Both are reserved in
  current MoonBit; use `train_idx` / `test_idx`.

- do NOT use `ref`, `dyn`, `with`, `assert`, `var`, `method`,
  `test`, or `train` as identifiers — all are reserved keywords.
  In particular, `method` shows up often in HTTP handlers; use
  `method_` (or another non-reserved name) instead.

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

- do NOT use non-official third-party HTTP frameworks. Per the
  repo dependency rule, `examples/api_server/` uses
  `moonbitlang/async`'s raw `Server` directly. Resist the urge
  to add `bobzhang/crescent`, `moonbit-community/rabbita`, or
  similar even if they're well-known.

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
