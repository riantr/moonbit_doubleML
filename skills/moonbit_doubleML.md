# moonbit_doubleML skill

Conventions for AI coding agents working on this codebase. Mirrors
moonbit-community/rabbita's `skills/rabbita.md` layout (one
`skills/<name>.md` per repo documenting the library's preferred API
surface and anti-patterns).

# Basic requirement

- prefer the public `DoubleML*::new(...).fit()` API over hand-rolling
  score / nuisance / influence-function plumbing. The 22 estimators
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
  The accessor set is *not* uniform, though: 16 of the 22 estimators
  expose all four of `coef()` / `se()` / `confint()` / `bootstrap()`,
  and six do not -- `DoubleMLAPOS` and `DoubleMLQTE` use `coefs` /
  `ses`, `DoubleMLDIDCS` uses `coef_at` / `se_at`, `DoubleMLDIDMulti`
  uses `coef_at_idx` / `se_at_idx`, `DoubleMLBLP` uses
  `confint_joint` instead of `confint`, and `DoubleMLPolicyTree` has
  no scalar coefficient at all.

# Dependency rule (repo-wide)

- Only official (`moonbitlang/*`) packages are allowed.
- Non-official packages may only be `riantr/*` (this repo itself).
- For official packages, pin to the latest published version on the
  registry (e.g. `moonbitlang/async@0.22.5`) and upgrade when
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

- whitebox tests (package-internal access) live in `*_wbtest.mbt`
  next to the production file. Use them only for helpers that
  `_test.mbt` cannot reach (private visibility, internal
  contracts). There are **26** `*_wbtest.mbt` files at the package
  root, holding **169** test cases in total; the `*_wbtest.mbt`
  glob is the source of truth for the current set. Two of them
  show the shape:
    - `kfold_wbtest.mbt` (5 tests) — `expand_unit_folds_to_rows`
      invariants (cluster contract: no unit straddles a split)
      and `build_row_unit_map` under non-contiguous unit ids.
    - `matrix_wbtest.mbt` (6 tests) — `Matrix::ones` /
      `Matrix::from_rows` / `Matrix::copy` deep-copy semantics,
      matmul dimension-mismatch precondition (via the
      `panic_*` driver), involutive transpose, and matmul
      associativity within 1e-9 (the v0.34.0+ kahan-compensation
      invariant).

- regression tests for upstream doubleml-for-py v0.11.x go in
  `*_parity_test.mbt` and assert against the hand-rolled reference
  built by `validate_*_with_python.py`.

- DGP recovery tests go in `dgp_recovery_test.mbt` and check that
  the estimator's `coef()` recovers the true `theta`. The band is
  **per test and measured**, not a package constant: the DIDCS tests
  use an SE-relative band (measured across 12 seeds -- max error
  14.41 absolute, 2.41 in SE units) and the PLPR test uses
  `10.0 * se + 0.5`. Do NOT loosen a band without a written reason
  in the commit message.

  The `max(MODEL_TOL, 2.0 * handrolled_se)` tolerance is a
  **different** thing: it lives in the Python validators
  (`validate_*_with_python.py`), and it is not one constant either --
  the IRM script uses `model_tol = 0.1` while the APOS and
  DIDCSBinary scripts use `MODEL_TOL = 0.3`. Neither `MODEL_TOL` nor
  `handrolled_se` appears anywhere in the MoonBit sources.

# Source layout

- the library lives at `moonbit_doubleML/` (workspace member). All
  production `.mbt` files are at the package root (flat layout).

- The 22 estimators (`DoubleMLPLR`, `DoubleMLIRM`, `DoubleMLPLIV`,
  `DoubleMLIIVM`, `DoubleMLDID`, `DoubleMLDIDBinary`, `DoubleMLDIDCS`,
  `DoubleMLDIDCSBinary`, `DoubleMLDIDMulti`, `DoubleMLDIDCrossSection`,
  `DoubleMLSSM`, `DoubleMLAPO`, `DoubleMLAPOS`, `DoubleMLPQ`,
  `DoubleMLQTE`, `DoubleMLLPQ`, `DoubleMLLPLR`, `DoubleMLCVAR`,
  `DoubleMLRDD`, `DoubleMLBLP`, `DoubleMLPLPR`, `DoubleMLPolicyTree`)
  pack into 19 `<name>.mbt` files (some files hold 2 structs:
  `apo.mbt` for APO+APOS, `quantile.mbt` for PQ+QTE,
  `blp_policy.mbt` for BLP+PolicyTree). Each estimator has a
  sibling `<name>_test.mbt`. 19 mirror upstream `doubleml-for-py`
  by name; two are upstream's under another name -- `DoubleMLRDD` is
  upstream's `RDFlex` and `DoubleMLDIDCrossSection` is upstream's
  `DoubleMLDIDCS`; and `DoubleMLDIDCS` is the one with no 1:1 upstream
  class (a port-side variant of upstream's multi-period
  `DoubleMLDIDMulti`). `DoubleMLDIDCSBinary`, `DoubleMLLPLR` and
  `DoubleMLPLPR` all ship upstream too -- an earlier revision of this
  file called them MoonBit extras, which was wrong.

- 17 DGP modules live at root as `dgp_*.mbt` with sibling
  `dgp_*_test.mbt` (35 files in all). The shared Box-Muller helper is in
  `seed.mbt`.

- 21 driver binaries live under `examples/<bin>/main.mbt`. Of these:
  - 16 (`apo`, `apos`, `cluster`, `cvar`, `datasets`, `did_binary`,
    `did_cross_section`, `did_cs`, `did_cs_binary`, `did_multi`,
    `lplr`, `main`, `pava`, `plpr`, `splitting`, `ssm`) are CLI-style
    numeric demos. **14** of the 16 print a true value and **11** of the 16
    print a 95% CI: `examples/pava` and `examples/splitting` print neither,
    and `examples/apos`, `examples/cluster` and `examples/ssm` print a true
    value but no CI.
  - `examples/fuzz/` is the property-based fuzz harness (native-only:
    it needs `--target native`), `examples/bitexact/` and
    `examples/parity/` are the fixtures the bit-exact and LPLR parity
    validators drive, and `examples/consumer_demo/` is the
    library-user pattern.
  - `examples/api_server/` is the HTTP service: it declares
    `"riantr/moonbit_doubleML@0.164.41"` in `moon.mod` and consumes
    the library through its public API.

- Python cross-validators live at the **repo root** -- not inside
  `moonbit_doubleML/` -- as `validate_*.py`. 24 of them are named
  `validate_*_with_python.py`, and that glob is what CI runs; three
  more (`validate_plotting_scope.py`, `validate_splitting_contract.py`,
  `validate_suite_meta.py`) are repo-level harnesses the glob does
  not pick up. Fifteen of the 24 re-derive the hand-rolled reference
  for one model and compare against the MoonBit output; the other nine
  import upstream's `doubleml` wheel and take the reference from
  there. Keep the script name aligned with the estimator it validates.

# Anti-patterns

- do NOT introduce a `Map[K, V]` **for estimator / DGP kernel
  code**. The built-in Map is deprecated: on `moon 0.1.20261023`,
  `Map::of(...)` emits `Warning (deprecated): Use Map([(k, v),
  ...]) or Map::from_array instead`. Use `Array[(K, V)]` and a
  linear scan, or a per-key fixed-size array when the key range is
  small. The HTTP plumbing in `examples/api_server/main.mbt` is
  exempt from the *rule* -- it needs a map for response headers --
  but it is not exempt from the deprecation: that file builds its
  header map with `Map::from_array([])`, and CI runs
  `moon build --deny-warn` over every workspace member, so
  `Map::of` there would turn the build red.

- do NOT name a field `train` or `test`. `test` is reserved in
  current MoonBit — a hard parse error, as a local and as a field
  — while `train` was reserved on `moon 0.1.20261016` and is not
  on `moon 0.1.20261023` (measured: it compiles as a local and as
  a field). Either way, use `train_idx` / `test_idx`.

- do NOT use `ref`, `dyn`, `with`, `assert`, `var`, `method`,
  or `test` as identifiers — all are reserved in current
  MoonBit. Measured on `moon 0.1.20261023`: `with`, `var` and `test`
  are hard errors, while `ref`, `dyn`, `assert` and
  `method` emit `Warning (reserved_keyword): The word ... is
  reserved for possible future use` — which still fails the build,
  because CI runs `--deny-warn`. (`train` is deliberately NOT in
  this list: it was a hard error on `moon 0.1.20261016` and is not
  reserved now — the bullet above covers it.)
  In particular, `method` shows up
  often in HTTP handlers; use `method_` (or another non-reserved
  name) instead.

- do NOT introduce a *new learner family* that upstream does not
  have (XGBoost, an SVM wrapper, a neural net). The port ships
  exactly 11 `LearnerDispatch` variants: 8 regressors
  (`LinearRegression`, `Constant`, `Noop`, `RandomForest`,
  `GradientBoosting`, `Ridge`, `Lasso`, `ElasticNet`) and 3
  classifiers (`LogisticRegression`, `RandomForestClassifier`,
  `GradientBoostingClassifier`).

  The classifiers are not optional, so "no classifier learners" is
  the wrong rule: `ml_m` defaults to
  `LearnerDispatch::logistic_regression(LogisticRegression::new())`
  for the six estimators whose propensity enters the score as
  `1 / m_hat` -- `DoubleMLIRM` (v0.132.0), `DoubleMLAPO`
  (v0.134.0), `DoubleMLAPOS` (v0.135.0), `DoubleMLSSM` (v0.138.0)
  and `DoubleMLPQ` / `DoubleMLQTE` (v0.139.0). A seventh,
  `DoubleMLLPLR` (v0.163.3), also defaults `ml_m` to the classifier,
  but its propensity enters the score as `d - m_hat`, not `1 / m_hat`
  -- so do not add it to the six. `ml_g` deliberately stays OLS,
  because it models `E[y | x]`, not `P(y = 1 | x]`.

- do NOT bypass `--deny-warn`. The CI runs
  `moon test --target {native,wasm-gc,wasm,js} --deny-warn` and
  fails on any warning. Pre-existing warnings block the build
  until cleaned up.

- do NOT loosen a DGP-recovery band in `dgp_recovery_test.mbt`
  without a documented reason. Each test's band is a measurement, not
  a shared constant -- see the Tests section above for the bands and
  for the `max(MODEL_TOL, 2.0 * handrolled_se)` tolerance, which
  belongs to the Python validators rather than to this file.

- do NOT use non-official third-party HTTP frameworks. Per the
  repo dependency rule, `examples/api_server/` uses
  `moonbitlang/async`'s raw `Server` directly. Resist the urge
  to add `bobzhang/crescent`, `moonbit-community/rabbita`, or
  similar even if they're well-known.

# Cross-validators

- each `validate_<estimator>_with_python.py` script must produce
  exactly one trailing line that contains the literal, upper-case
  `PASS`. The CI step greps for it with `case "$line" in *PASS*)`,
  which is **case-sensitive** -- a trailing line reading `passed`
  does not satisfy it, and the step also requires a zero exit code.
  (The QA loop's own check is case-insensitive, so a lower-case
  `passed` would pass there and still fail CI.)

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
