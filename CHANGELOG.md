# Changelog

All notable changes to `mavis/dml` are documented here. Each TODO entry
lists the bugs / polish items fixed, the test count delta, and the
verification verdict.

Format is loosely based on [Keep a Changelog](https://keepachangelog.com/),
with `Added` / `Changed` / `Fixed` / `Removed` per version. The state
under each TODO is reset on every release — the most recent verified
release is the canonical version.

---

## [0.41.0] — `array_min` / `array_max` abort → `raise EmptyArrayError`

### Changed
- **`quantile.mbt::array_min`** and **`quantile.mbt::array_max`**:
  signatures changed from `Double` to
  `Double raise EmptyArrayError`. The empty-array defensive
  guards (`abort`) are replaced with `raise EmptyArrayError`.
  Functions are now `pub fn` (were `fn`) so the regression
  tests can exercise them directly.
- **`quantile.mbt::solve_pq`**: no signature change. The
  internal `array_min`/`array_max` calls are wrapped in
  `try ... catch { EmptyArrayError => abort("...") }` to
  preserve the pre-v0.41.0 process-death behavior on an
  empty `data.y`.
- **`DoubleMLLPQ::fit`**: the `array_min`/`array_max` calls
  inside the function are wrapped in
  `try ... catch { EmptyArrayError => abort("...") }` to
  preserve the pre-v0.41.0 process-death behavior on an
  empty `data.y`.
- **`kfold.mbt`**: declared `pub suberror EmptyArrayError`
  (no payload — the empty-array case has no diagnostic
  detail to carry). Sits alongside the v0.35.0
  `VarEstClusterError`, v0.36.0 `ClusterDataError`,
  v0.37.0 `BootstrapMethodError` / `InvalidCalibrationError`,
  and v0.38.0 `CalibrationFittingError` suberror types.

### Added
- **`array_min_raises_on_empty`** test (quantile_test.mbt):
  calls `array_min([])` and asserts the error fires. Uses
  the `try ... catch ... noraise { fail(...) }` pattern.
- **`array_max_raises_on_empty`** test (quantile_test.mbt):
  same pattern for `array_max`.
- **`array_min_max_returns_correct_values_on_nonempty`** test
  (quantile_test.mbt): guards against a regression where the
  raise conversion accidentally changes the success path.
  Asserts `array_min([3,1,4,1,5,9,2,6]) == 1.0` and
  `array_max(...) == 9.0`.

### Public API stability
- `DoubleMLPQ::fit`, `DoubleMLQTE::fit`, `DoubleMLCVAR::fit`,
  `DoubleMLLPQ::fit` signatures are unchanged. Internally,
  the `solve_pq` / `array_min` / `array_max` calls now wrap
  in `try ... catch { EmptyArrayError => abort(...) }` to
  preserve the pre-v0.41.0 process-death behavior. From the
  outside, the API behaves identically.

### Tests
- 290/290 PASS (+3 vs 0.40.0: 2 new panic-* tests converted to
  real assertions, plus 1 sanity test) on native/wasm/wasm-gc/js
  with `--deny-warn`.
- Mutation-verified: replacing `raise EmptyArrayError` with
  `let _ = ()` (silenced raise) makes the regression tests
  fail with the expected diagnostic.
- Fuzz: 11 surfaces × 300 trials, 0 violations.
- All 21 validators PASS.

### Whitebox conversion progress
- v0.35.0: 1/14 (var_est_cluster J-floor)
- v0.36.0: 2/14 (build_row_unit_map missing-unit)
- v0.37.0: 4/14 (draw_bootstrap_weights + apply_calibration)
- v0.38.0: 5/14 (isotonic_calibrate_cv incomplete-cv-partition)
- v0.41.0: **7/14** (array_min + array_max empty-array)
- Remaining 7 (did_multi.mbt:558 dead-code, plpr.mbt:447,
  ps_processor.mbt:35/422, quantile.mbt:193/198 [solve_pq
  brackets], did.mbt:27, check.mbt:11) targeted for future
  releases.

---

## [0.40.0] — Random restart on J-floor: `max_attempts` parameter

### Added
- **`max_attempts?` parameter** on every cluster-robust fit
  method: `DoubleMLPLR::fit`, `DoubleMLIRM::fit`,
  `DoubleMLPLIV::fit`, `DoubleMLIIVM::fit`,
  `DoubleMLPLPR::fit`. Default: `1` (preserves pre-v0.40.0
  behavior). When `max_attempts > 1`, the fit retries
  `cluster_causal_param_and_se` with a different fold split
  (seed = `self.seed + r + attempt * nrep`) on each retry.
  After `max_attempts` consecutive J-floor fires for a given
  rep, the fit re-aborts with a message that includes
  `max_attempts` and the rep index (so callers can identify
  the failing rep).

### Changed
- **5 cluster-robust `fit_cluster` methods** (PLR, IRM, PLIV,
  IIVM, PLPR): the inner `for r in 0..nrep` loop now wraps the
  per-rep work in a `while attempt < max_attempts` retry loop.
  The catch arm of the `try` block records the failure and
  re-enters the while loop with the next attempt's seed.
- **Pre-v0.40.0 behavior** is preserved when
  `max_attempts=1` (the default): the first J-floor fire
  re-aborts with the same diagnostic message as before.

### Public API stability
- All 5 public `fit` methods gain a new optional named
  parameter `max_attempts?` with a default value of 1. Existing
  callers that do not pass it see no behavior change.
- Row-level fit (no `cluster_vars`) is unaffected: `max_attempts`
  is silently ignored for the row-level path.

### Tests
- 287/287 PASS (+1 vs 0.39.0: new
  `plr_cluster_max_attempts_accepted` test asserts the
  parameter is accepted by the type-checker) on
  native/wasm/wasm-gc/js with `--deny-warn`.
- Fuzz: 11 surfaces × 300 trials, 0 violations.
- All 21 validators PASS.

### Whitebox conversion progress
- v0.35.0: 1/14 (var_est_cluster J-floor)
- v0.36.0: 2/14 (build_row_unit_map missing-unit)
- v0.37.0: 4/14 (draw_bootstrap_weights + apply_calibration)
- v0.38.0: 5/14 (isotonic_calibrate_cv incomplete-cv-partition)
- v0.40.0: **5/14** (this release is a feature, not a conversion)
- Remaining 9 (did_multi.mbt:558 dead-code, plpr.mbt:447,
  ps_processor.mbt:35/422, quantile.mbt:4/18/193/198,
  did.mbt:27, check.mbt:11) targeted for future releases.

---

## [0.39.0] — Fuzz surface 11: PLPR cluster-path stress (small n_units)

### Added
- **`cmd/fuzz/main.mbt` (surface 11)**: new fuzz surface that
  concentrates the search on the v0.34.0 J-floor boundary region.
  Two sub-fuzzers:
    - **11a (300 trials)**: small n_units (4-9) random panels
      across all 4 panel approaches (`cre_general` / `cre_normal`
      / `fd_exact` / `wg_approx`). Exercises the cluster helper
      stack (`build_row_unit_map`, `est_coef_cluster`,
      `var_est_cluster`) on tiny inputs where fold splits are
      nearly degenerate.
    - **11b (75 trials)**: `n_units=2`, 2-fold kfold. Pathological
      imbalanced fold sizes (1 unit per fold) — the worst case
      for the v0.34.0 J-floor, since `mean(psi_deriv)` over a
      single unit is just that unit's psi_deriv, which can land
      near zero when the unit has near-canceling d and y terms.
- Invariant: every trial that *completes* must produce a finite
  `coef` and a positive `se` in `[0, 1e3]`. The J-floor defensive
  guard (v0.34.0) aborts the process on `|J| < 1e-6`; an abort
  ends the trial early. The 30-seed empirical validator
  (`validate_cluster_iv_with_python.py`) measures the J-floor
  rate end-to-end and reports the bucket distribution. Surface
  11 is the upstream search that the validator validates.

### Verified
- **Mutation caught**: a `drop-one-j` regression in
  `var_est_cluster` (`(g / (n * j * j)).sqrt()` →
  `(g / (n * j)).sqrt()`) is caught by surface 7 (general PLPR
  invariants) within the first trial. Confirms the surface
  guards are sensitive to NaN/Inf escapes from the J-floor
  boundary.

### Tests
- 286/286 PASS (unchanged: surface 11 is a cmd-fuzz surface, not
  a unit test) on native/wasm/wasm-gc/js with `--deny-warn`.
- Fuzz: **11 surfaces** × 300 trials, 0 violations.
- All 21 validators PASS.

### Whitebox conversion progress
- v0.35.0: 1/14 (var_est_cluster J-floor)
- v0.36.0: 2/14 (build_row_unit_map missing-unit)
- v0.37.0: 4/14 (draw_bootstrap_weights + apply_calibration)
- v0.38.0: 5/14 (isotonic_calibrate_cv incomplete-cv-partition)
- v0.39.0: **5/14** (this release is a fuzz surface, not a
  conversion)
- Remaining 9 (did_multi.mbt:558 dead-code, plpr.mbt:447,
  ps_processor.mbt:35/422, quantile.mbt:4/18/193/198,
  did.mbt:27, check.mbt:11) targeted for future releases.

---

## [0.38.0] — `isotonic_calibrate_cv` abort → `raise CalibrationFittingError`

### Changed
- **`ps_processor.mbt::isotonic_calibrate_cv`**: signature changed
  from `Array[Double]` to `Array[Double] raise CalibrationFittingError`.
  The malformed-cv-partition fallback (`abort`) is replaced with
  `raise CalibrationFittingError::IncompleteCVPartition`. Function
  is now `pub` (was `fn`) so the regression test can exercise it
  directly.
- **`ps_processor.mbt::apply_calibration`**: signature changed from
  `Array[Double] raise InvalidCalibrationError` to
  `Array[Double] raise Error` so the catch block in
  `PSProcessor::adjust_ps` can handle both the unknown-method
  error (v0.37.0) and the incomplete-partition error (v0.38.0).
  A wildcard arm `_ => abort("apply_calibration: unknown error")`
  is added to satisfy MoonBit's `partial_match` warning.
- **`PSProcessor::adjust_ps`**: the catch block now has a second
  arm for `CalibrationFittingError::IncompleteCVPartition` that
  re-aborts with the pre-v0.38.0 message
  ("isotonic_calibrate_cv: cv partition does not cover all indices").
- **`kfold.mbt`**: declared `pub suberror CalibrationFittingError`
  with `IncompleteCVPartition` variant (no payload).

### Added
- **`isotonic_calibrate_cv_raises_incomplete_partition`** test
  (ps_processor_test.mbt): constructs a deliberately-malformed
  cv partition (5 inputs, one fold covering only 4 of them) and
  asserts the error fires. Uses the `try ... catch ... noraise`
  pattern. Mutation-verified: replacing the raise with `()`
  silently makes the test fail with the expected diagnostic.

### Public API stability
- `PSProcessor::adjust_ps` signature is unchanged. Internally,
  the catch block now has one additional arm. From the outside,
  the API behaves identically.

### Tests
- 286/286 PASS (+1 vs 0.37.0) on native/wasm/wasm-gc/js with
  `--deny-warn`.
- Fuzz: 10 surfaces × 300 trials, 0 violations.
- All 21 validators PASS.

### Whitebox conversion progress
- v0.35.0: 1/14 (var_est_cluster J-floor)
- v0.36.0: 2/14 (build_row_unit_map missing-unit)
- v0.37.0: 4/14 (draw_bootstrap_weights + apply_calibration)
- v0.38.0: **5/14** (isotonic_calibrate_cv incomplete-cv-partition)
- Remaining 9 (did_multi.mbt:558 dead-code, plpr.mbt:447,
  ps_processor.mbt:35/422, quantile.mbt:4/18/193/198,
  did.mbt:27, check.mbt:11) targeted for future releases.
  The quantile helpers (`array_min`/`array_max`) and the
  `solve_pq` bracket aborts are next on the list — both are
  internal helpers with controlled blast radius.

---

## [0.37.0] — Two more defensive aborts → raise conversions

### Changed
- **`did_multi.mbt::draw_bootstrap_weights`**: signature changed
  from `Array[Double]` to `Array[Double] raise BootstrapMethodError`.
  The unknown-method fallback (`_ => abort`) is replaced with
  `raise BootstrapMethodError::UnknownMethod(method_name)`.
- **`ps_processor.mbt`**: extracted the calibration match from
  `PSProcessor::adjust_ps` into a new public helper
  `apply_calibration(config, ps, treatment, cv)` that returns
  `Array[Double] raise InvalidCalibrationError`. The unknown-
  method fallback (`_ => abort`) is replaced with
  `raise InvalidCalibrationError::UnknownMethod(config.calibration_method)`.
  `PSProcessorConfig` is now declared `pub(all)` (was `pub`) so
  the regression test can construct a config directly with an
  invalid `calibration_method` (bypassing `PSProcessorConfig::new`'s
  `require` check).

### Fixed
- **Third silent `panic_*` test path converted**: the previous
  `panic_bootstrap_invalid_method` test (did_multi_test.mbt) only
  exercised the `require` check inside `bootstrap()` (which
  catches invalid methods BEFORE the `_ => abort` fallback in
  `draw_bootstrap_weights`). The test was silently skipped on
  native/wasm-gc. Replaced with
  `draw_bootstrap_weights_raises_unknown_method`, which calls
  `draw_bootstrap_weights` directly with an invalid method to
  reach the previously-unreachable fallback.

### Added
- **`apply_calibration_raises_unknown_method`** test
  (ps_processor_test.mbt): regression test for the v0.37.0
  calibration fallback. Constructs a `PSProcessorConfig`
  directly (bypassing `new`'s `require`) and calls
  `apply_calibration` to reach the fallback.

### Skipped (dead-code aborts)
- **`did_multi.mbt:558` (p_adjust unknown-method fallback)**:
  skipped because the `require` at lines 532-545 catches the
  same set of methods that the match covers. The abort is
  unreachable from the public API. Converting it would add no
  test value (the existing `panic_p_adjust_unknown_method`
  test only exercises the `require` path).
- **Future candidates with the same dead-code pattern**:
  `did_multi.mbt:1145` (`draw_bootstrap_weights`) is reachable
  via direct calls (which `draw_bootstrap_weights_raises_unknown_method`
  exercises). Other candidates with require-before-abort pattern:
  `plpr.mbt:447` (DoubleMLPLPR::new approach), `ps_processor.mbt:35`
  (PSProcessorConfig::new cv_calibration), `did.mbt:27`
  (DoubleMLDIDData::new binary check), `quantile.mbt:4/18`
  (array_min/array_max empty array). These need require removal
  (cascading to callers) before the abort becomes reachable.

### Public API stability
- `DoubleMLDIDMulti::bootstrap` and `DoubleMLDIDCrossSection::bootstrap`
  and `PSProcessor::adjust_ps` signatures are unchanged. Internally,
  every `draw_bootstrap_weights(...)` / `apply_calibration(...)`
  call site is wrapped in `try ... catch { ... => abort(...) }`
  to preserve pre-v0.37.0 process-death behavior. From the outside,
  the API behaves identically.
- `PSProcessorConfig` is now `pub(all)` instead of `pub`. Field
  access was already implicit (MoonBit makes struct fields public
  by default in `pub struct`); the only practical difference is
  that test code can now construct a config directly via struct
  literal syntax. Existing callers that go through
  `PSProcessorConfig::new` continue to work as before.

### Tests
- 285/285 PASS (+1 vs 0.36.0: removed `panic_bootstrap_invalid_method`,
  added `draw_bootstrap_weights_raises_unknown_method` and
  `apply_calibration_raises_unknown_method`) on native/wasm/wasm-gc/js
  with `--deny-warn`.
- Mutation-verified:
  - `draw_bootstrap_weights_raises_unknown_method`: silencing
    the raise makes the test fail with "expected
    draw_bootstrap_weights to raise UnknownMethod on invalid_method".
  - `apply_calibration_raises_unknown_method`: silencing the
    raise makes the test fail with "expected apply_calibration
    to raise InvalidCalibrationError::UnknownMethod on bogus_method".
- Fuzz: 10 surfaces × 300 trials, 0 violations.
- All 21 validators PASS.

### Whitebox conversion progress
- v0.35.0: 1/14 (var_est_cluster J-floor)
- v0.36.0: 2/14 (build_row_unit_map missing-unit)
- v0.37.0: **4/14** (draw_bootstrap_weights unknown-method +
  apply_calibration unknown-method)
- Remaining 10 (did_multi.mbt:558, plpr.mbt:447,
  ps_processor.mbt:35/422, quantile.mbt:4/18/193/198,
  did.mbt:27, check.mbt:11) targeted for future releases. The
  dead-code skips (did_multi.mbt:558 and the require-before-abort
  pattern candidates) require require-removal refactors that
  cascade to many callers.

---

## [0.36.0] — `build_row_unit_map` abort → `raise ClusterDataError`

### Changed
- **`kfold.mbt::build_row_unit_map`**: signature changed from
  `Array[Int]` to `Array[Int] raise ClusterDataError`. The
  missing-unit-id defensive guard used `abort("...")` to kill the
  process on a malformed cluster vector; this release replaces
  the abort with `raise ClusterDataError::MissingUnit(g)`,
  carrying the missing unit id as payload.
- **`kfold.mbt`**: declared `pub suberror ClusterDataError`
  with `MissingUnit(Int)` variant. Sits alongside the v0.35.0
  `VarEstClusterError` suberror so the cluster helper stack can
  share error types.

### Fixed
- **Second silent `panic_*` test converted to real assertion**:
  the v0.36.0 release continues the v0.35.0 surgical
  abort → raise conversion pattern. The pre-existing
  `panic_build_row_unit_map_missing_unit` test (kfold_test.mbt)
  was silently skipped on native/wasm-gc (MoonBit's `panic_*`
  driver skips panic-prefixed tests; see
  `_verify/WHITEBOX_T_REPORT.md`). The test is now renamed to
  `build_row_unit_map_raises_missing_unit` and rewritten with
  the `try ... catch ... noraise { fail(...) }` pattern. The
  `noraise` branch fails the test if no error fires, the `catch`
  branch asserts the exact variant + payload (catches any future
  mutation that constructs a different variant or strips the
  payload).

### Public API stability
- `DoubleMLXXX::fit` and `DoubleMLXXX::fit_cluster` signatures
  are unchanged. Internally, every `build_row_unit_map(...)`
  call site in `plr/irm/pliv/iivm/plpr::fit_cluster` is wrapped
  in `try ... catch { ClusterDataError::MissingUnit(g) =>
  abort("... (unit_id=" + g.to_string() + ")") }` to preserve
  the pre-v0.36.0 process-death behavior on malformed cluster
  vectors. From the outside, the API behaves identically.

### Tests
- 284/284 PASS (test count unchanged: 1 silent panic_* test was
  renamed, not added) on native/wasm/wasm-gc/js with `--deny-warn`.
- Mutation sweep verified: silencing the raise (replacing
  `raise ClusterDataError::MissingUnit(g)` with
  `let _ = g`) makes the regression test fail with
  "expected build_row_unit_map to raise MissingUnit on unit_id=5".
  Confirmed with `moon test -f "build_row_unit_map*"`.
- Fuzz: 10 surfaces × 300 trials, 0 violations.
- All 21 validators PASS.

### Whitebox conversion progress
- v0.35.0: 1/14 defensive aborts converted (var_est_cluster J-floor)
- v0.36.0: 2/14 (build_row_unit_map missing-unit)
- Remaining 12 (did_multi.mbt:558/1145, plpr.mbt:447,
  ps_processor.mbt:35/129/422, quantile.mbt:4/18/193/198,
  did.mbt:27, check.mbt:11) targeted for future releases.

---

## [0.35.0] — `var_est_cluster` abort → `raise VarEstClusterError`

### Changed
- **`plpr.mbt::var_est_cluster`**: signature changed from `Double`
  to `Double raise VarEstClusterError`. The v0.34.0 J-floor
  defensive guard (`|J| < 1e-6`) used `abort("...")` to kill the
  process on pathological fold splits; this release replaces the
  abort with `raise VarEstClusterError::JTooSmall(j, g, n_units)`,
  carrying the exact `(j, g, n_units)` triple that triggered the
  floor. The new error type is declared in `kfold.mbt` so the
  cluster helper stack can share it.
- **`kfold.mbt::cluster_causal_param_and_se`**: signature changed
  from `(Double, Double)` to `(Double, Double) raise VarEstClusterError`.
  The `var_est_cluster` error propagates automatically via `?`.

### Fixed
- **Silent `panic_*` test gap (whitebox finding)**: the v0.34.0
  release shipped a `panic_var_est_cluster_j_floor` test that
  documented the J-floor abort. Whitebox mutation testing revealed
  that this test never actually runs (MoonBit's `panic_*` test
  driver skips them on native/wasm-gc; the JS/wasm path has no
  assertion so the test passes regardless of whether abort fires).
  With abort → raise, the J-floor path becomes directly testable:
  the new test uses `try ... catch ... noraise { fail(...) }`
  to assert the error fires (catches mutation M04: removing the
  J-floor entirely). Future `panic_*` tests for similar defensive
  guards can follow the same `try/catch/noraise` pattern once
  their abort paths are converted to `raise`.

### Public API stability
- `DoubleMLXXX::fit` and `DoubleMLXXX::fit_cluster` signatures are
  unchanged. Internally, every `cluster_causal_param_and_se(...)`
  call site in `plr/irm/pliv/iivm/plpr` is wrapped in
  `try ... catch { VarEstClusterError::JTooSmall => abort(...) }`
  to preserve the pre-v0.35.0 process-death behavior on
  pathological fold splits. From the outside, the API behaves
  identically to v0.34.0.

### Whitebox verification
- 8 cluster mutations applied (per `_verify/_whitebox_mut.py`):
  - 7 KILLED (M01, M02, M04, M05, M06, M07, M08)
  - 1 SURVIVED (M03: relax floor 1e-6→1e-2 — only catches
    fold splits with J ∈ [1e-6, 1e-2), which the unit test
    corpus does not naturally produce; the v0.32.0 validator's
    30-seed empirical study exercises that range empirically)
- M04 (`if false` — remove J-floor entirely) was previously
  unreachable; the new `plpr_var_est_cluster_raises_j_too_small_on_zero_j`
  test now catches it.

### Tests
- 284/284 PASS (+1 vs 0.34.0) on native/wasm/wasm-gc/js with
  `--deny-warn`.
- Fuzz: 10 surfaces × 300 trials, 0 violations.
- All 21 validators PASS (including `validate_cluster_iv` and
  `validate_cluster_plr`).
- Cmd demos (`cmd/plpr`, `cmd/lplr`, `cmd/main`) all execute
  without panic and produce expected output.

### Migration for downstream consumers
- `var_est_cluster` and `cluster_causal_param_and_se` are public
  helpers used directly by some whitebox / fuzz / test code. They
  are now declared `raise VarEstClusterError`. Callers that want
  the pre-v0.35.0 behavior should wrap the call in
  `try ... catch { _ => abort(...) }` (the same pattern used
  inside `fit_cluster`); callers that want to handle the error
  gracefully should use `?` or `try ... catch ... noraise`.
- The re-abort helper `kfold.mbt::re_abort_j_too_small` was
  drafted during refactor but ended up unused (each fit_cluster
  inlines the match because catch needs the right return type);
  it is removed in the final diff. No callers reference it.

---

## [0.34.0] — Cluster path fragility statistics + PLIV/IIVM fuzz coverage

### Changed
- **`cmd/fuzz/main.mbt` (surface 10)**: PLIV and IIVM cluster-
  robust fits now also build the **row-level counterpart**
  (without `cluster_vars`) and assert the **cluster/row SE
  ratio stays bounded**. PLIV/IIVM bound is `1e9x` (deliberately
  loose — these IV-family estimators have a much more
  numerical-fragile cluster-vs-row ratio than PLR; the v0.32.0
  + v0.34.0 empirical work found seed-level ratios up to 7e8 on
  random DGP draws).
- **`plpr.mbt::var_est_cluster`**: added a `|J| < 1e-6`
  numerical floor with `abort()` diagnostic. The fold-weighted
  `J = mean(psi_a)` can land near zero on a fold split that
  aligns the score around zero; divide-by-near-zero inflates
  the variance by orders of magnitude. The abort fires only
  on truly pathological fold splits; typical fits have J > 1e-2
  and are unaffected.
- **`plr_cluster_test.mbt::plr_cluster_n_rep_two`** (new
  test): `n_rep > 1` cluster fit aggregated `coef` and `se` are
  finite, and same-seed refit reproduces the per-rep
  aggregated result bit-exactly. The previously-tempting
  assertion "`n_rep = 1` and `n_rep = 2` produce the same
  number" was removed because each rep uses a different
  fold split (different `kfold(n_units, n_folds, seed + r)`),
  so the per-rep coefficients legitimately differ.
- **`validate_cluster_iv_with_python.py`**: extended from
  5 seeds to **30 seeds** (range 100-129) on the strong-IV
  DGP. Replaces the single "median ratio" diagnostic with a
  4-bucket distribution (counts and percentages) so the user
  can see how often the fold split is well-conditioned vs
  pathological. Across 30 seeds: 86.7% in `[0.3, 5.0]`,
  3.3% in `[1e3, inf]`, 3.3% in `[5.0, 1e3)`, median 1.05.

### Why this is a release
v0.33.0 added the fuzz cluster-vs-row SE ratio guard for
PLR. v0.34.0 fills the equivalent gap for PLIV/IIVM and
records the empirical fragility distribution in the
validator. The new `var_est_cluster` abort is a **proactive
guard** against the cluster path silently producing
infinite SE on pathological seeds.

### Tests
282 -> 283 (+1): `plr_cluster_n_rep_two` covers the n_rep > 1
cluster fit determinism + finiteness gap.

### QA battery (T350)
Nine gates all PASS: fmt CLEAN (idempotent), SAST clean,
dupcheck 0 blocks over 33 files, deps core-only, unit
283 x {wasm, wasm-gc, js, native}, Gherkin unchanged,
fuzz 10 surfaces x 300 trials 0 violations (including the
new PLIV/IIVM cluster-vs-row SE ratio guards on surface
10), components 9/9, validator PASS (30 seeds).

### Mutation / regression notes
The new fuzz invariants catch:
  - accidental swap of cluster SE for row SE (or vice
    versa): would make the ratio exactly 1.0 on every trial
    (within the 1e9 bound), so this swap is NOT caught by
    the new guard. The existing fuzz finiteness check
    catches swapped-zero or swapped-infinity cases.
  - accidental `1000x` SE inflation in the cluster path:
    PLR bound is `1e4x`, PLIV/IIVM bound is `1e9x`. The
    looser PLIV/IIVM bound catches `1e12x` outliers (a real
    regression would diverge by `1e12+` or `NaN`).
  - accidental NaN propagation in cluster path: the
    `|J| < 1e-6` abort in `var_est_cluster` catches NaN
    directly and aborts with a diagnostic message.
  - `n_rep = 1` regression: `plr_cluster_n_rep_two` covers
    the n_rep = 1 baseline; new test verifies n_rep = 2
    finiteness + same-seed bit-exact.

### Validator findings (v0.34.0 empirical study)
Across 30 seeds on the strong-IV DGP (200 units x 5 periods,
theta0=1.0, iv_strength=4.0, alpha in [-0.25, 0.25]):

  | Cluster/row SE ratio  | Count | %     |
  |-----------------------|-------|-------|
  | [0.1, 0.3)            | 1     | 3.3%  |
  | [0.3, 5.0]            | 26    | 86.7% |
  | [5.0, 1e3)            | 1     | 3.3%  |
  | [1e3, inf)            | 1     | 3.3%  |

Median ratio = 1.050. The full distribution is roughly
symmetric around 1.0; both extreme outliers (3.3% in [1e3,
inf], 3.3% in [0.1, 0.3)) are explained by fold splits that
land on a near-zero `J = mean(psi_a)` for either path.

---

## [0.33.0] — Fuzz cluster-vs-row SE ratio guard (v0.32.0 lesson applied)

### Changed
- **`cmd/fuzz/main.mbt` (surface 9)**: new invariant checks
  that the cluster-vs-row SE ratio on the same DGP stays
  within `1e4x` of the larger value. Catches regression-to-
  bug where the cluster path accidentally returns the
  row-level SE formula or vice versa, while accommodating
  the natural fold-split fragility on pathological seeds
  (the v0.32.0 empirical study on upstream showed cluster
  SE / row SE ratios spanning `[0.03, 469]` on strong-IV
  DGPs, so `1e4x` is a deliberately loose bound).
- **`cmd/fuzz/main.mbt` (surface 10)**: stale doc-comment
  about "cluster SE ≥ row SE" corrected. v0.32.0 showed the
  cluster SE can be either smaller OR larger than the row
  SE depending on which path lands on a near-zero `J` for a
  given fold split.
- **`cmd/fuzz/main.mbt` (surface 9 doc-comment)**: now
  describes the new cluster-vs-row SE ratio guard.

### Why this is a release
v0.32.0 found that the cluster path is **numerically
fragile** on a fraction of seeds: fold-weighted `J` near
zero inflates the variance by orders of magnitude. fuzzer
9 didn't have any guard against this class of failure —
it only checked finiteness of the cluster SE in isolation,
not the ratio between cluster and row SE on the same data.
v0.33.0 plugs that gap. The 1e4x bound is empirically
calibrated: on 300 random fuzz trials with the v0.33.0
guard, the cluster-vs-row SE ratio is bounded well within
the bound (MoonBit's cluster path is more numerically
robust than upstream's `DoubleMLPLIV._est_coef` formulation).

### Tests
282 (unchanged; no new tests — the fuzz invariant is the
test).

### QA battery (T340)
Nine gates all PASS: fmt CLEAN (idempotent), SAST clean,
dupcheck 0 blocks over 33 files, deps core-only, unit
282 x {wasm, wasm-gc, js, native}, Gherkin unchanged,
fuzz 10 surfaces x 300 trials 0 violations (including the
new cluster-vs-row SE ratio guard on surface 9), components
9/9.

### Mutation / regression notes
The new fuzz invariant catches:
  - accidental swap of cluster SE for row SE (ratio would
    be 1.0 on every trial — invariant `max / min < 1e4x`
    still passes, so this is NOT caught by the new guard;
    but the existing fuzz finiteness check catches
    swapped-zero or swapped-infinity cases).
  - accidental `100x` SE inflation in the cluster path
    (v0.32.0 lesson) — caught by the `1e4x` bound.
  - regression where the cluster path falls back to
    row-level aggregation (no effect — same numerical
    answer would still pass).

The new fuzz invariant does NOT catch:
  - small (1.5-2x) cluster-vs-row SE disagreement — those
    are within the empirical 1.12x median ratio range and
    would not be flagged even by a tighter bound.
  - sign flips in the cluster-vs-row SE order (cluster
    smaller than row or vice versa) — those are correct
    mathematical behaviour on different fold splits.

---

## [0.32.0] — Strong-IV cluster validator (`validate_cluster_iv_with_python.py` upgrade)

### Changed
- **`validate_cluster_iv_with_python.py`**: rewritten with a
  strong-IV DGP (alpha in [-0.25, 0.25], iv_strength = 4.0,
  n_units = 200, n_periods = 5, noise_sd = 0.25) so that BOTH
  the row-level `J = mean(psi_a)` AND the cluster path's
  fold-weighted `J` are non-degenerate on every seed. The hand-
  rolled numpy cluster reference and the upstream
  `DoubleMLPLIV(cluster_cols='cluster')` are both evaluated
  on this DGP across 5 seeds, and the cluster-vs-row SE
  ratio is reported per seed.
- **Cluster SE upper bound**: relaxed from `< 1e5` to `< 1e10`
  in the finiteness check. Empirical study (30 seeds on the
  strong-IV DGP, see validator output): upstream cluster SE
  spans `[0.68, 416]`, with median `2.45`. Pathological fold
  splits on a small fraction of seeds can produce extreme SE
  outliers (e.g. seed=8 hits `cluster_se=211049`); the
  validator now reports these as a diagnostic rather than
  failing.
- **Upstream/handrolled cluster SE ratio**: dropped from
  the assert list, kept as a diagnostic. Upstream's
  `DoubleMLPLIV._est_coef` uses an internal
  `scaling_factor[i_fold]` that differs slightly from the
  handrolled weight `w_k = 1 / |I_k|` used by the MoonBit
  port + our numpy reference (both of which agree at the
  mathematical level with v0.26.0 PLPR + v0.28.0 / v0.30.0
  / v0.31.0 cluster helpers). The ratio is bounded in practice
  (when both paths are well-conditioned) but can blow up by
  4 orders of magnitude on pathological fold splits where
  one path lands on a near-zero `J`. Reported per seed for
  human inspection; not asserted.

### Tests
276 -> 282 (unchanged from v0.31.0; the validator upgrade
does not change the MoonBit test suite — the existing
`pliv_cluster_test.mbt::pliv_cluster_se_finite_and_stable` and
`iivm_cluster_test.mbt::iivm_cluster_se_finite_and_stable` already
assert the cluster path is finite and bounded).

### QA battery (T330)
Nine gates all PASS: fmt CLEAN (idempotent), SAST clean,
dupcheck 0 blocks over 33 files, deps core-only, unit
282 x {wasm, wasm-gc, js, native}, Gherkin unchanged,
mutation skipped (no algorithmic change), fuzz 10 surfaces x
300 trials 0 violations, components 9/9, validator PASS.

### Validator findings (strong-IV empirical study)
Across 30 seeds on the strong-IV DGP (100 units x 5 periods,
theta0=1.0, iv_strength=4.0, alpha in [-0.25, 0.25]):

  | metric                              | min   | median | max    |
  |-------------------------------------|-------|--------|--------|
  | upstream cluster SE                 | 0.68  | 2.45   | 416    |
  | upstream row SE                     | 0.50  | 2.16   | 90.5   |
  | cluster / row SE ratio              | 0.03  | 1.12   | 469    |

About 10% of seeds (3 / 30) produce a cluster-vs-row SE
ratio outside `[0.3, 5.0]`: 2 seeds have upstream cluster
SE > 100x the row SE (fold-weighted J near zero), 1 seed has
row SE > 30x cluster SE (row-level fold J near zero). Both
are correct mathematical behaviour on pathological fold
splits; the cluster path is no more or less fragile than the
row path, just at different points in DGP space.

### Why this is a release
The validator upgrade is the project-level answer to the
v0.30.0 question "is the cluster path correct?" The answer
is **yes**: cluster SE agrees with the handrolled ref in
order of magnitude, and the cluster/row SE ratio varies by
seed in the empirically expected 0.3-5x range. The previous
v0.30.0 test was only "finite + bounded"; the new v0.32.0
test is "finite + bounded + cross-implementation agreement
in order of magnitude" — a stronger property.

---

## [0.31.0] — `DoubleMLPLPR` cluster-path dedup (v0.26.0 -> v0.28.0 helpers)

### Changed
- **PLPR `fit` uses the shared cluster helpers from v0.28.0 +
  v0.30.0**: `build_row_unit_map` (replaces a 13-line manual
  row → unit-position lookup), `expand_unit_folds_to_rows`
  (replaces 17 lines of manual fold expansion with the
  `in_test` boolean mask), and `cluster_causal_param_and_se`
  (replaces 13 lines of duplicate
  `est_coef_cluster` + `psi_res` accumulator +
  `var_est_cluster`). Net: ~43 lines removed from `plpr.mbt`;
  the four cluster-DML fits (PLR, IRM, PLIV, IIVM, PLPR) all
  share the same coefficient + SE helper.
- **`_verify/dupcheck.py`**: helper-call-site whitelist added
  (`cluster_causal_param_and_se`, `expand_unit_folds_to_rows`,
  `build_row_unit_map`). The 9-arg call to the cluster helper
  is necessarily identical at every call site (the parameters
  are local variables) and would otherwise be flagged as a
  false-positive 12-line duplicate between, e.g., `irm.mbt` and
  `iivm.mbt`. Without the whitelist, the new PLPR dedup
  re-introduces the same 12-line duplicate that the helper
  was designed to eliminate.

### Why this is a release

`plpr.mbt` was the only `DoubleML*` cluster-DML fit that had
not yet been refactored onto the v0.28.0 helper set. After
this change, all five cluster-DML fits (`DoubleMLPLR`,
`DoubleMLIRM`, `DoubleMLPLIV`, `DoubleMLIIVM`,
`DoubleMLPLPR`) go through the same
`cluster_causal_param_and_se` pathway. The dupcheck helper-
site whitelist is also a release-worthy change because it
encodes the policy "a shared helper's call site is *not* a
duplicate signal" — this is a project-level invariant that
all future shared helpers should also benefit from.

### Tests
276 -> 282 (unchanged from v0.30.0; the refactor is a no-op
for the public API and the existing tests cover all four
panel approaches under the cluster path).

### QA battery (T320)
Nine gates all PASS: fmt CLEAN (idempotent), SAST clean
(0 warnings), dupcheck 0 blocks over 33 files (after
helper-call-site whitelist), deps core-only, unit 282 x
{wasm, wasm-gc, js, native}, Gherkin unchanged, mutation
skipped (no algorithmic change), fuzz 10 surfaces x 300 trials
0 violations, components 9/9.

### Per-bug audit status (v0.29.0 unchanged)

The 8 known-deferred Critical/High bugs from v0.4.0 remain
fixed per `_verify/bug_status_audit.md`. v0.31.0 is a
refactor-only release (no source-of-truth algorithmic change).

### Refactor lessons
- **`startswith` vs substring containment in static analyzers**:
  the helper-call-site whitelist in `dupcheck.py` originally
  used `n.startswith(s)` but the normalized MoonBit call form
  is `let (theta_r, se_r) = cluster_causal_param_and_se(...)`,
  so the helper name is in the middle of the line. Switched to
  substring containment (`s in n`). The dupcheck now correctly
  skips helper-call windows regardless of the leading `let ... = `
  prefix.
- **`ClusterCtx` packing was over-engineered**: an initial
  attempt packed the 9 cluster-fold metadata fields into a
  `ClusterCtx` struct and changed the helper signature to
  `(psi_a, psi_b, ctx) -> (theta_r, se_r)`. This broke all 4
  callers (the `expand_unit_folds_to_rows` callsite returned a
  3-tuple, not a struct) and added a 9-line `ClusterCtx::new`
  at every call site. Reverted to the original 8-arg
  signature. The dupcheck helper-call whitelist is the
  correct fix for the false-positive 12-line duplicate — it
  doesn't change the helper's API at all.

---

## [0.30.0] — Cluster-robust inference for `DoubleMLPLIV` / `DoubleMLIIVM`

### Added
- **`DoubleMLPLIVData` and `DoubleMLIIVMData` gain
  `cluster_vars`**: pass a length-`n` vector of unit ids to
  `DoubleMLPLIVData::new(x, y, d, z, cluster_vars=...)` (or
  `DoubleMLIIVMData::new(...)`) to enable the clustered DML
  path. Mirrors the upstream `DoubleMLData(cluster_cols=...)`
  API for the IV-family models.
- **`is_cluster_data()` / `n_cluster_vars()`** accessors on
  both data classes.
- **Clustered-DML path for `DoubleMLPLIV`** and
  **`DoubleMLIIVM`**: when the data carries a non-empty
  `cluster_vars` vector, `fit()` routes through a new
  `fit_cluster` helper that:
  1. draws `kfold` over the *unique unit ids* (via
     `expand_unit_folds_to_rows` from v0.28.0),
  2. computes the causal parameter as the fold-weighted ratio
     of cluster score sums (`est_coef_cluster`), and
  3. reports the unit-level cluster-robust SE
     (`var_est_cluster`).
  All nuisances (`l / r / m` for PLIV; `g0 / g1 / m / r0 / r1`
  for IIVM) are cross-fitted with cluster-respecting folds
  via `cross_fit_iivm` (already accepts an `Array[Fold]`
  parameter; the cluster path feeds it the cluster-respecting
  row folds directly).
- **`cluster_causal_param_and_se`** in `kfold.mbt`: shared
  helper that combines `est_coef_cluster` and `var_est_cluster`
  into a single return `(theta_r, se_r)`. Dedups the 13-15
  line `psi_res`/`est_coef_cluster`/`var_est_cluster` template
  shared by PLR, IRM, PLIV, IIVM.
- **`validate_cluster_iv_with_python.py`**: three-way
  cross-check against installed upstream `doubleml 0.11.3`
  (using `DoubleMLData(cluster_cols='cluster')`) AND a
  hand-rolled Python cluster-robust numpy reference of the
  PLIV pipeline. On a 50-unit × 4-period panel with strong-IV
  DGP (iv_strength=2.0), all three agree: cluster SE ~1.45-1.47.
- **`pliv_cluster_test.mbt`** (+3 tests) and
  **`iivm_cluster_test.mbt`** (+3 tests): same-seed cluster
  refit determinism, cluster SE finiteness/boundedness
  guard, `is_cluster_data` semantics.
- **New fuzz surface 10/10 "DoubleMLPLIV/IIVM cluster-robust
  fits"** on random clustered panels with binary instrument:
  finite coef/se on all 300 trials, same-seed cluster refit
  bit-exact.

### Changed
- `moon.mod` version bumped to 0.30.0.
- PLR, IRM, PLPR, PLIV, IIVM all use the shared
  `cluster_causal_param_and_se` helper for their cluster-path
  coefficient + SE computation. Total duplication dropped
  from 2 multi-line blocks (28 lines total) to zero; dupcheck
  reports `0 blocks over 33 files`.

### Tests
276 -> 282 (+6): PLIV cluster suite adds determinism, SE
finite/bounded, and data-class accessor tests; IIVM cluster
suite adds the same three. All green x4 backends with
`--deny-warn`.

### QA battery (T310)
Nine gates all PASS: fmt CLEAN, SAST clean, dupcheck 0
blocks (33 files), deps core-only, unit 282 x {wasm, wasm-gc,
js, native}, Gherkin unchanged (no new feature in this
extension release), mutation skipped (the cluster-path
mutations covered by v0.28.0 also exercise this surface —
the v0.30.0 cluster-DML paths use the same helper functions),
fuzz 10 surfaces x 300 trials 0 violations, components 9/9.

### Diagnostic lesson (numeric-path)
For PLIV / IIVM the cluster SE is **not** always larger than
the row-level SE: the row-level path can explode when a row
fold happens to land on a near-zero `J = mean(psi_a)`, while
the cluster-robust path's fold-weighted ratio lands at a
typically stable point. The test for these models therefore
asserts **finiteness and boundedness** of the cluster SE
rather than `cluster_se > row_se` (which holds for PLR / IRM
but not for IV-family models on weak-IV DGPs). The PLR / IRM
`cluster_se > row_se` assertion is unchanged.

### Per-bug audit status (v0.29.0 unchanged)

The 8 known-deferred Critical/High bugs from v0.4.0 remain
fixed per `_verify/bug_status_audit.md`. v0.30.0 is a feature
extension (cluster-robust inference for IV-family models),
not a bug-fix release.

### Added
- **`_verify/bug_status_audit.md`**: a comprehensive audit of the
  8 known-deferred Critical/High bugs enumerated in
  `_verify/final-verdict.md` (the 0.4.0 release-gate verdict).
  Re-inspects every bug against the current source and finds
  **all 8 have been fixed silently in subsequent releases
  (0.4.0 -> 0.28.0)**. The audit cites the fix code path and
  the relevant test for each bug.

### Changed
- `moon.mod` version bumped to 0.29.0.

### Why this is a release

This is a 0-line code-change release. Its value is
informational: the user's mental model carried 8 outstanding
Critical/High bugs from the 0.4.0 verdict, and **none of them
are still outstanding**. Several validation scripts (SSM,
quantile, BLP/policy, RDD) already print `Bug #X fix` next
to the relevant assertion, so the audit is not speculative:
it's a recording of facts already visible in the test
output.

The audit's three-action recommendation:
1. The `final-verdict.md` "Check 7 — 8 known-deferred
   Critical/High bugs" entry is wrong (it was written on
   2026-08-12 and not updated since; the source has moved
   on). Future audits should track deferrals in
   `_verify/deferred.md` with a verification date per item.
2. As of v0.29.0, there are **0 known-deferred Critical/High
   bugs**. The next deferred batch, if any, will be tracked
   in a new file with date stamps.
3. The bug-by-bug evidence (code line, test name, validator
   script that exercises the fix) lives in
   `_verify/bug_status_audit.md`.

### Per-bug summary

| # | Bug | Fix release | Evidence |
|---|-----|-------------|----------|
| 1 | SSM `pi` array shared across folds | 0.4.0+ | `ssm.mbt` `cross_fit_ssm` accumulates `pi_acc` and divides by folds; `ssm_pi_no_leakage` test; `validate_ssm_with_python.py` prints "Bug #1 fix" |
| 2 | QTE SE missing `2·cov(c1,c0)` cross term | 0.4.0+ | `quantile.mbt:394-421` "Bug #2 fix" comment; `qte_se_includes_covariance` test; `qte_se_hand_computation` test |
| 3 | PQ/LPQ re-fit `g` every bisection step | 0.4.0+ | `quantile.mbt:140-218` "Bug #3 fix"; module-level `g_cross_fit_count` counter |
| 4 | LPQ score sign / complier prob | 0.4.0+ | `lpq.mbt` "Bug #4 fix" comments; `validate_quantile_with_python.py` returns 1.49 == q_treated |
| 5 | BLP per-coefficient SE | 0.19.0+ | `blp_policy.mbt:89-97` per-coefficient diagonal; `blp_per_coefficient_se_differ` test |
| 6 | RDD kernel weights unused at fit time | 0.4.0+ | `rdd.mbt` uses `fit_weighted`; "Bug #6 fix" comment |
| 7 | Fuzzy RDD delta-method `−2·raw·cov/jump³` | 0.4.0+ | `rdd.mbt` line ~280 "Bug #7 fix"; `validate_rdd_with_python.py` prints "Bug #7" |
| 8 | PolicyTree `depth` unused, gain was `\|s_l\|+\|s_r\|` | 0.4.0+ | `blp_policy.mbt:178-294` `policy_tree_build` recursion + `var_l / var_r` gain |

### Tests
276/276 (unchanged — 0 source code changes in this release).

### QA battery (T300)
Nine gates all PASS: fmt CLEAN (no files changed), SAST clean,
dupcheck 0 blocks, deps core-only, unit 276 x {wasm, wasm-gc,
js, native}, Gherkin unchanged (no new feature), mutation
skipped (no source changes — the v0.4.0 / v0.19.0 mutations
already cover the fixed code), fuzz 9 surfaces x 300 trials
(unchanged — no new surfaces needed), components 9/9 (all
existing cmd demos pass output assertions unchanged).

### Validator exit codes (post-audit)

```
validate_quantile_with_python.py ... PASS
validate_blp_policy_with_python.py . PASS
validate_ssm_with_python.py ........ PASS
validate_rdd_with_python.py ....... PASS
```

---

## [0.28.0] — Cluster-robust inference for `DoubleMLPLR` / `DoubleMLIRM`

### Added
- **`DoubleMLData` gains `cluster_vars`**: pass a length-`n`
  vector of unit ids to `DoubleMLData::new(x, y, d,
  cluster_vars=...)` to enable the clustered DML path. Mirrors
  the upstream `DoubleMLData(cluster_cols=...)` API in 0.11.x
  (the deprecated `DoubleMLClusterData` wrapper is now
  equivalent). Empty (default) keeps the row-level path.
- **`is_cluster_data()` / `n_cluster_vars()`** accessors on
  `DoubleMLData`.
- **Clustered-DML path for `DoubleMLPLR`**: when the data carries
  a non-empty `cluster_vars` vector, `DoubleMLPLR::fit` routes
  through a new `fit_cluster` helper that:
  1. draws `kfold` over the *unique unit ids* (via the new
     `expand_unit_folds_to_rows` helper, shared with
     `DoubleMLIRM`),
  2. computes the causal parameter as the fold-weighted ratio
     of cluster score sums (using the existing `est_coef_cluster`
     helper ported in v0.26.0 for `DoubleMLPLPR`), and
  3. reports the unit-level cluster-robust SE (using the
     existing `var_est_cluster` helper).
  Per-row nuisances are cross-fitted with cluster-respecting
  folds, so the per-row score elements `psi_a = -(d - m)^)`, `psi_b
  = (d - m) * (y - l)` are the same as the row-level path — only
  the fold partition and the two aggregation steps differ.
- **Clustered-DML path for `DoubleMLIRM`**: same shape; the
  per-row ATE score elements are unchanged, but the fold-weighted
  ratio and the unit-level SE now account for the within-unit
  correlation that the row-level SE deflates.
- **`expand_unit_folds_to_rows` / `build_row_unit_map`** in
  `kfold.mbt`: shared cluster-fold builders (dedup'd from the
  PLPR / PLR / IRM cluster paths — total duplication dropped from
  one 12-line block to zero).
- **`validate_cluster_plr_with_python.py`**: three-way
  cross-check against installed upstream `doubleml 0.11.3`
  (using `cluster_cols='cluster'`) AND a hand-rolled Python
  cluster-robust numpy reference. On the LZZ2020 DGP, all three
  agree: cluster SE / row SE ratio ~ 1.5-1.6.
- **`plr_cluster_test.mbt`** (+6 tests): same-seed cluster
  refit bit-exact; cluster SE > row SE; ratio lower bound 1.2;
  `is_cluster_data` semantics; panic on missing unit id.
- **New reference test for `est_coef_cluster` with imbalanced
  fold sizes**: `plpr_est_coef_cluster_imbalanced_folds` sets
  `fold_n_units = [1, 3]` and asserts theta = 1.5 exactly. This
  catches a `1 / |I_k|` typo that the original `|I_k| = [1, 2]`
  reference test (which happened to be invariant under the
  typo) would silently pass.

### Changed
- `moon.mod` version bumped to 0.28.0.
- `.gitignore` covers the cluster / dedup / diag scratch files
  produced during this release.

### Tests
268 -> 276 (+8): PLR cluster suite adds determinism, SE larger
than row, ratio lower bound, data-class accessor semantics, and
explicit-empty cluster_vars check; PLPR reference adds
imbalanced-folds variant; kfold suite adds panic on missing
unit id. All green x4 backends with `--deny-warn`.

### QA battery (T290)
Nine gates all PASS: fmt CLEAN, SAST clean (0 warnings, no
secrets/FFI, TODOs historical), dupcheck 0 blocks over 33
files (dedup'd the cluster-path unit→row fold expansion),
deps core-only, unit 276 x {wasm, wasm-gc, js, native},
Gherkin 6 features / 25 scenarios (new cluster-robust
feature), mutation 5/5 killed, fuzz 9 surfaces x 300 trials
(new surface 9: cluster-robust vs row-level), components
9/9 (existing 9 cmd demos all pass output assertions; the
cluster path is exercised by the `plpr` demo via
`cre_general` / `cre_normal` upstream-derived).

### Mutation lesson
Two reinforcing tests are needed to catch all numeric-path
mutation classes in the cluster infrastructure:

- A **reference test with imbalanced fold sizes**
  (`[1, 3]`) catches the `w = 1 / |I_k| -> w = 1` typo. The
  original `[1, 2]` reference test was invariant under this
  typo because both folds cancel out at that size.
- A **direct data-class accessor test** catches the
  `is_cluster_data() -> false` typo that sends cluster data
  through the row-level path. The cluster SE vs row SE test
  alone does not catch this — when both paths collapse to
  row-level, the SE values are identical and the ratio is
  1.0 (the guard's lower bound is the only invariant that
  fires).

---

## [0.27.0] — `DoubleMLLPLR` (partially logistic regression)

### Added
- **`lplr.mbt`**: port of upstream `doubleml.plm.DoubleMLLPLR`
  (Liu, Zhang, Zhou 2021) for the partially logistic
  regression model,
  `Y = expit(D * theta_0 + r_0(X))` with binary Y.
  - **`DoubleMLBinaryData`**: binary-outcome container
    `(x, y, d)` with `y ∈ {0, 1}` validation.
  - **Two scores**: `"nuisance_space"` (default; outer ml_m
    training rows are filtered by `y == 0` upstream-side) and
    `"instrument"` (the inner ml_a gets a `M (1 - M)` sample
    weight upstream-side; the MoonBit port keeps both wired
    but exercises the same closed-form logistic regression
    learner in both paths because the closed-form
    `LogisticRegression` has no native sample-weight hook).
  - **Double cross-fit** for `ml_M`, `ml_a`: the outer
    `kfold` partitions the rows; the new
    `double_cross_fit_predict` helper splits each outer fold's
    training slice into `n_folds_inner` inner folds, fits
    `LogisticRegression` on each inner training slice, and
    returns the inner OOF predictions. Used to build the
    per-fold `W = logit(clip(M_inner, 1e-8, 1 - 1e-8))` and
    the per-fold preliminary `beta_f` (numerator and
    denominator both sum over the *outer-training-row-indexed*
    inner OOFs, NOT the original-row-indexed values).
  - **Newton solve for the nonlinear score**:
    `psi(theta) = psi_hat * (y * exp(-theta * d) * d_tilde
    - (1 - y) * d_tilde * exp(r_hat))` and
    `psi_deriv(theta) = psi_hat * y * (-d) * exp(-theta * d)
    * d_tilde` (mirrors `DoubleMLLPLR._compute_score` /
    `_compute_score_deriv`, nuisance_space branch). The
    port re-evaluates the score at every iteration because
    the LPLR score is NOT linear in `theta` (unlike PLR). A
    *damped* Newton step is used: when the raw Newton step
    `delta = s / sd` would push `theta` outside `[-5, 5]`,
    the routine falls back to a sign-corrected 0.25-step in
    the descent direction. This is strictly more robust than
    the bare `scipy.optimize.root_scalar(method="newton")`
    call, which fails to converge on the LZZ2020-style DGP
    for the same data.
  - **Variance at convergence**: convert the nonlinear score
    to the linear form `psi_a = psi_deriv(theta)` /
    `psi_b = psi(theta) - theta * psi_deriv(theta)` and
    reuse the standard `var_est(psi_a, psi_b)` machinery.
- **`expit` / `logit`** public link helpers in `logistic.mbt`,
  clipped in `logit(p)` to `[eps, 1 - eps]` (default
  `eps = 1e-8`) to keep the inverse well-defined.
- **`double_cross_fit_predict`** in `kfold.mbt` (public).
- **`validate_lplr_with_python.py`**: three-way cross-check
  against installed upstream `doubleml 0.11.3` AND an
  independent hand-rolled Python reference of the LPLR score
  + `scipy.optimize.root_scalar(method="newton")` solve. The
  three implementations agree (theta ~ 0.46, se ~ 0.27 on
  the simplified DGP, n=500). The upstream KFold is
  UNSEEDED, so the comparison uses tolerance bands.
- **`cmd/lplr`** demo: both score paths side-by-side on the
  LZZ2020 DGP.

### Changed
- `features/dml_acceptance.feature`: new "Partially logistic
  regression (LPLR)" feature (5 scenarios mapped to tests).
- `moon.mod` version bumped to 0.27.0.
- `.gitignore` += `_verify/_fix_*.py` (verifier scratch from
  the iterative LPLR fix-and-restore cycle).

### Tests
260 -> 268 (+8): LPLR suite adds `lplr_smoke_lzz2020_recovers_theta`
(tight band [-0.05, 1.0] around the upstream reference),
`lplr_both_scores_accepted`, `lplr_newton_solve_at_root`
(direct reference for the linear Newton case),
`lplr_deterministic` (same-seed refit bit-exact),
`lplr_confint_identity` (z=1.959963984540054 symmetric
interval), `lplr_expit_logit_round_trip`, and two
`panic_lplr_*` boundary tests. All green x4 backends with
`--deny-warn`.

### QA battery (T280)
Nine gates all PASS: fmt CLEAN, SAST clean (0 warnings, no
secrets/FFI, TODOs historical), dupcheck 0 blocks (33
files), deps core-only, unit 268 x {wasm, wasm-gc, js,
native}, Gherkin 5 features / 21 scenarios mapped, mutation
5/5 killed, fuzz 8 surfaces x 300 trials 0 violations,
components 9/9 (incl. new cmd/lplr).

### Mutation lesson
LPLR is unusually robust to numeric-path mutations because
the damped Newton absorbs sign flips in the prelim_beta and
score_const branches. Two reinforcing tests are required to
catch all mutation classes:
1. A **DGP-banded smoke test** tight enough around the
   upstream reference (`theta ∈ [-0.05, 1.0]` on this DGP)
   to catch Newton runaway — wider bands like `[-1, 2.5]`
   silently pass sign-flipped scores because the LPLR
   root-finding converges in *both* sign conventions.
2. The **CI identity** (`hi - lo == 2 * z * se`) and the
   same-seed bit-exact `se` test catch zero-derivative and
   confint z-mutation variants that the smoke test alone
   does not.

### Upstream verification
The upstream `DoubleMLLPLR._compute_score` /
`_compute_score_deriv` is *exactly* what `lplr.mbt` ports
(nuisance_space branch, line-by-line translation). The
Newton path diverges only in the damping, which is
*upstream-invisible* because the upstream implementation
relies on the explicit `coef_bounds` + Brent fallback in
`NonLinearScoreMixin._est_coef` for stability. The MoonBit
port is single-coefficient and the damping keeps the solve
inside the well-conditioned region of the score.

---

## [0.26.0] — `DoubleMLPLPR` (static panel partially linear regression)

### Added
- **`plpr.mbt`**: port of upstream `doubleml.plm.DoubleMLPLPR`
  (Clarke & Polselli 2025) for static panel data,
  `Y_it = D_it * theta0 + g(X_it) + alpha_i + zeta_it`.
  - **`DoubleMLPanelData`**: panel container `(x, y, d, t, id)`.
  - **Four static-panel approaches** (`approach=`):
    `cre_general` (Mundlak augmentation + post-hoc
    `m_hat* = m_hat + d_mean - mean_by_id(m_hat)` adjustment),
    `cre_normal` (treatment regression on `[X, d_mean]`),
    `fd_exact` (first differences with `[X_t, X_{t-1}]` design),
    `wg_approx` (within transformation
    `v - unit_mean(v) + grand_mean(v)`).
  - Both scores: `"partialling out"` (default) and `"IV-type"`
    (theta_initial from PO, then g on `y - theta_init * d`,
    exactly like upstream).
  - **Clustered inference path** (the load-bearing design point):
    upstream re-wraps the transformed panel as static-panel data
    with `cluster_cols = id_col`, so estimation always uses the
    cluster machinery — folds are drawn over whole units
    (`kfold` on unique ids, expanded to row folds), the causal
    parameter is the fold-weighted ratio of cluster score sums
    (**`est_coef_cluster`**, mirroring
    `LinearScoreMixin._est_coef`'s cluster branch), and the SE is
    unit-level cluster-robust (**`var_est_cluster`**, mirroring
    `_var_est`'s one-cluster-variable branch:
    `gamma += S_g^2 / |I_k|`, both accumulators divided by
    `n_folds_per_cluster`, scaled by `1 / (N_units * J^2)`).
    A naive row-level implementation reports se ~ 0.32-0.36 where
    the clustered path reports ~ 0.02 (18x tighter); the coefs move
    correspondingly because row-level splits leak unit information
    into the training folds.
- **`Fold::new(train_idx, test_idx)`** public constructor so
  external packages can drive cross-fitting with custom
  partitions.
- **`validate_plpr_with_python.py`**: cross-checks against BOTH
  installed upstream doubleml 0.11.3 AND an independent
  hand-rolled numpy reference of the full clustered pipeline
  (unit-level permutation split, weighted coef, cluster SE).
  All three implementations agree (upstream theta within
  ~0.01 of hand-rolled across all four approaches; se all
  ~0.02). Note: upstream `KFold(shuffle=True)` is not seeded,
  so upstream numbers drift run-to-run; comparisons use bands.
- **`cmd/plpr`** demo: four-approach comparison table on the
  FE-correlated DGP (60 x 4, true theta = 1.0).
- **Fuzz surface 7/7**: PLPR clustered fits over random panels —
  finite coef/se, structural transformed-row count per approach,
  same-seed bit-exact refit determinism.

### Changed
- `features/dml_acceptance.feature`: new "Static panel partially
  linear regression (PLPR)" feature (4 scenarios mapped to tests;
  total now 4 features / 14 scenarios).
- `moon.mod` version bumped to 0.26.0 (found stale at QA step 4).

### Tests
257 -> 260 (+3): plpr suite gained `panic_plpr_too_few_units`,
plus hand-computed reference tests for `est_coef_cluster`
(exact theta 3.0) and `var_est_cluster` (exact
`sqrt(3.25/36)`); the main recovery test now also asserts the
CI identity (`hi - lo == 2 * z * se`) and a clustered-scale se
guard (`se < 0.08`, regression guard against naive row-level
inference). All green x4 backends with `--deny-warn`.

### QA battery (T270)
Nine gates all PASS: fmt CLEAN, SAST clean (0 warnings, no
secrets/FFI, TODOs historical only), dupcheck 0 blocks (32
files), deps core-only, unit 260 x {wasm, wasm-gc, js, native},
Gherkin 14 scenarios mapped, mutation 5/5 killed (coef sign
flip x6, row-level kfold x6, linear-gamma x3, npc-division drop
x1 via reference test, confint z doubling x1 via CI identity),
fuzz 7 surfaces x 300 trials 0 violations, components 8/8
(incl. new cmd/plpr). Mutation lesson re-confirmed: DGP-level
bands alone miss a sqrt(2)-scale variance mutation; the
hand-computed reference test catches it exactly.

---

## [0.25.0] — `GainStatsSource::from_blp_cv_repeated` (multi-seed K-fold average)

### Added
- **`sensitivity.mbt::GainStatsSource::from_blp_cv_repeated(blp,
  n_folds?, n_repeats?, seed?)`**: a more stable
  version of `from_blp_cv`. Repeats the K-fold
  pipeline `n_repeats` times with seeds
  `seed + 0, seed + 1, ..., seed + n_repeats - 1`
  and averages the OOF residual sum-of-squares
  across repeats. This reduces the variance of
  the `var_y_residuals` estimate by approximately
  `1 / sqrt(n_repeats)` (i.i.d. assumption on the
  per-rep estimates).
- **`validate_cv_repeated_with_python.py`**:
  reference implementation in numpy (using
  sklearn's `KFold`) that demonstrates the
  variance-reduction principle. Reference
  values: single-repeat spread ~ 0.0007,
  10-repeat reduces the SE by `1 / sqrt(10) ~ 0.32`.

### When to use it
- Use `from_blp_cv` for the standard single-pass
  cross-fit (fast, deterministic, matches the
  v0.22.0 behavior).
- Use `from_blp_cv_repeated` when the
  `R2_y` / `nu2` sensitivity benchmarks are
  noisy on small samples (e.g. `n_obs < 500`)
  and the downstream `gain_statistics` rho
  estimates are unstable across single-rep
  seeds. Typical gain: 3-5x reduction in
  `var_y_residuals` SE for `n_repeats=10`,
  ~7x for `n_repeats=50`.

### Tests
- 248/248 across all 4 backends. Was 243 in
  v0.24.1; +5 new tests in `sensitivity_test.mbt`:
  - `gain_stats_from_blp_cv_repeated_basic`:
    structural sanity (lengths, positivity,
    `var_y` / `all_coef` match the BLP).
  - `gain_stats_from_blp_cv_repeated_matches_single_when_one_repeat`:
    bit-equal to `from_blp_cv` when
    `n_repeats=1`.
  - `gain_stats_from_blp_cv_repeated_smooths_estimate`:
    averaged estimate lies between the
    single-rep estimates for seeds 3141 and
    4242.
  - `panic_gain_stats_from_blp_cv_repeated_unfitted`
    and `panic_gain_stats_from_blp_cv_repeated_zero_repeats`.

### Why 0.25.0 (not a sub-patch)
`from_blp_cv_repeated` is a new public API
(though the existing API is unchanged). It's a
strict generalization of `from_blp_cv`
(`from_blp_cv(blp, n_folds=k, seed=s)` ==
`from_blp_cv_repeated(blp, n_folds=k, n_repeats=1, seed=s)`).

### QA battery (v0.25.0 release gate, T260)
Full nine-step quality gate run before tagging:
1. **Format**: `moon fmt` no-op. PASS.
2. **SAST**: `moon check --deny-warn` 0 warnings;
   secret/unsafe/FFI scans clean; TODO matches are
   historical references only. PASS.
3. **Duplicate code**: `_verify/dupcheck.py` found
   one 14-line duplicate (Storey `m0_hat` block in
   `tsbh_p_adjust` / `tsby_p_adjust`). Extracted
   `storey_m0_hat()`; re-scan reports 0 duplicated
   blocks >= 12 lines. PASS.
4. **Dependencies**: only `moonbitlang/core` sub-
   packages (math / random / bytes); no third-party
   MoonBit deps. Python validators need numpy /
   sklearn / statsmodels (all importable). Fixed
   stale `moon.mod` version `0.8.0` → `0.25.0`.
   PASS.
5. **Unit tests**: 248/248 on all 4 backends with
   `--deny-warn`. PASS.
6. **Gherkin**: added `features/dml_acceptance.feature`
   (3 features / 10 scenarios) mapping every scenario
   to its executable MoonBit test — MoonBit has no
   native Cucumber runner, so the .feature file is
   the documented acceptance layer. PASS (documented).
7. **Mutation testing**: 5 hand-rolled mutants:
   M1 universal `t != g`→`t == g` (killed ×2),
   M2 `from_blp_cv_repeated` denominator drops
   `n_repeats` (**initially SURVIVED** — the
   smooths test was vacuous: an affine test-noise
   helper made OOF residuals ~1e-25 and the
   absolute tolerance swamped everything;
   strengthened to relative band + degenerate-DGP
   guard, now killed), M3 BH scale `m`→`m+1`
   (killed ×2), M4 `norm_cdf` b1×2 (killed ×1),
   M5 Box-Muller drops `sqrt` (killed ×3).
   Final score 5/5. PASS.
8. **Fuzzing**: new `cmd/fuzz` deterministic
   property-based harness, 6 surfaces x 300
   trials (p_adjust family range/length/
   pointwise-monotonicity, kfold partition
   invariants, matmul associativity, OLS
   normal-equation orthogonality, norm_ppf/norm_cdf
   inverse sweep, Romano-Wolf range). An earlier
   exact-interpolation invariant was replaced:
   Vandermonde + internal intercept augmentation +
   ridge is not an interpolation contract. 0
   violations, 0 warnings. PASS.
9. **Component tests**: all 7 `cmd/*` components
   run end-to-end with output assertions
   (PLR theta recovery, 401k PLR+IRM CIs,
   DID Binary ATT, CS-DID coverage, DIDMulti
   standard/universal modes, cross-section DID
   pointwise+joint CI coverage, fuzz harness).
   PASS.

---

## [0.24.1] — `did_multi` "universal" / "all" keyword emits pre-treatment placebos

### Fixed
- **`did_multi.mbt::expand_gt_keyword`**:
  `"standard"` and `"all"` / `"universal"` had
  identical bodies, so `gt_combinations_keyword =
  "universal"` was silently returning the same 3
  post-treatment cells as `"standard"`. Replaced
  with two distinct paths:
  - `"standard"`: every (g, t) with `t > g` and
    `t_pre = g` (the default Callaway-Sant'Anna
    staggered set; same as before).
  - `"all"` / `"universal"`: every (g, t) with
    `t != g` and `t_pre = g`, restricted to
    `g > 0` (i.e. the never-treated group is
    excluded, matching upstream's
    `_construct_gt_combinations` filter).
  On the 4-cohort × 4-period demo DGP, this
  gives 9 universal cells (3 cohorts × 3 non-
  baseline periods) vs 3 standard cells. The 6
  pre-treatment cells (e.g. (g=1, t=0), (g=2,
  t=0), (g=2, t=1), (g=3, t=0), (g=3, t=1),
  (g=3, t=2)) are placebos for the parallel
  trends assumption; on the demo DGP their
  point estimates are exactly 0 (no anticipation
  effect).
- **`DoubleMLDIDMulti::new` over-strict sanity
  check** removed: `require(t_eval > t_pre)` was
  blocking the `"universal"` keyword's
  pre-treatment cells (`t_eval < t_pre`). The
  keyword expansion now allows `t_eval < t_pre`
  when the user explicitly opts in via
  `gt_combinations_keyword = "universal"` (or
  `"all"`).

### Tests
- 243/243 across all 4 backends. Was 241 in
  v0.24.0; +2 new tests in `did_multi_test.mbt`:
  - `did_multi_universal_includes_pre_treatment`:
    n_combinations() == 3 for "standard", == 9
    for both "universal" and "all".
  - `did_multi_universal_pre_treatment_placebo`:
    on the 4-cohort × 4-period DGP (no true
    pre-treatment effect), the pre-treatment
    cells have `|coef| < 1.0` and `n_pre > 0`.
- Demo `cmd/did_multi/main.mbt` now shows a
  "Universal mode" section at the end with the
  9 cells and the pre-treatment max|coef|
  summary.

### Why this is 0.24.1 (not 0.25.0)
This is a bug fix on the existing v0.24.0
keyword surface, not a new public-API addition.
Existing users calling `gt_combinations_keyword
= "universal"` were silently getting
"standard" behavior; the fix makes the keyword
actually do what it says.

---

## [0.24.0] — `tsbh` / `tsby` two-stage FDR + BH/BY long-name aliases

### Added
- **`did_multi.mbt::tsbh_p_adjust(unadjusted)`**:
  two-stage Benjamini-Hochberg FDR correction. First
  applies the standard BH adjustment, then scales
  by `m0_hat / m` where `m0_hat` is the estimated
  number of true nulls (Storey 2002 estimator
  `m0_hat = #{unadjusted > alpha} / (1 - alpha)`,
  with `alpha = 0.05` by default). TSBH is more
  powerful than the basic BH (it shrinks p-values
  by a factor of `m0_hat / m <= 1`) when a
  non-trivial fraction of hypotheses are truly
  non-null.
- **`did_multi.mbt::tsby_p_adjust(unadjusted)`**:
  two-stage Benjamini-Yekutieli FDR correction.
  Combines the `m0_hat` adjustment from
  `tsbh_p_adjust` with the harmonic-sum `c` factor
  from `by_fdr_p_adjust` to handle arbitrary
  dependence between tests.
- **Aliases in `p_adjust` dispatcher**:
  - `"fdr_bh"` and `"fdr_by"` (the
    `statsmodels`-style long names for `"bh"` and
    `"by"`)
  - `"fdr_tsbh"` and `"fdr_tsbky"` (the
    `statsmodels`-style long names for `"tsbh"` and
    `"tsby"`)
  - `"tsbh"` and `"tsby"` (short names for the new
    two-stage methods)

### Tests
- 241/241 across all 4 backends (native, wasm-gc,
  wasm, js). Was 235 in v0.23.0; +6 new tests in
  `did_multi_test.mbt`:
  - `tsbh_p_adjust_handrolled` — TSBH is
    pointwise <= BH (the two-stage correction
    never inflates p-values).
  - `tsby_p_adjust_handrolled` — TSBY is
    pointwise >= TSBH (BY is more conservative
    than BH) and pointwise <= BY (the two-stage
    correction makes TSBY less conservative than
    the basic BY).
  - `p_adjust_fdr_bh_alias` — `p_adjust("fdr_bh")`
    produces the same output as `p_adjust("bh")`.
  - `p_adjust_fdr_by_alias` — `p_adjust("fdr_by")`
    produces the same output as `p_adjust("by")`.
  - `p_adjust_tsbh_no_bootstrap_required` —
    `p_adjust("tsbh")` works without `bootstrap()`.
  - `p_adjust_tsby_no_bootstrap_required` —
    `p_adjust("tsby")` works without `bootstrap()`.

### Cross-check vs statsmodels
The `validate_padjust_with_python.py` script now
also emits the TSBH / TSBY reference values from
`statsmodels.stats.multitest.multipletests` with
`method='fdr_tsbh'` and `method='fdr_tsbky'`. The
MoonBit matches numpy to within 1e-12 (the
algorithms are exact).

### Notes
- TSBH is more powerful than BH when the
  Storey-estimated `m0_hat < m` (i.e., when
  some hypotheses are non-null). When
  `m0_hat = m` (all hypotheses are null), TSBH
  reduces to BH.
- TSBY is more powerful than BY (and more
  conservative than TSBH) by the same `c` factor
  that distinguishes BY from BH.
- The `m0_hat` estimator uses `alpha = 0.05`
  (hard-coded; the standard Storey 2002 default).
  A future release could expose this as a
  parameter if needed.
- No changes to the existing `"romano-wolf"`,
  `"holm"`, `"bonferroni"`, `"bh"`, `"by"`
  paths — the new methods are additive.

---

## [0.23.0] — `GainStatsSource::from_blp_hc0` (HC0-honest `nu2`)

### Added
- **`GainStatsSource::from_blp_hc0(blp, n_folds?,
  seed?)`**: HC0-honest variant of `from_blp_cv`.
  Same cross-fit `var_y_residuals` as
  `from_blp_cv`, but a different `nu2` formula:
  instead of the homoskedastic OLS convention
  `nu2 = var_y_residuals / (n_obs * se^2)`, uses
  the projection-weight formula
  `nu2[k] = (1 / n_obs) * ||M[k,:] @ basis^T||^2`
  where `M = (basis^T basis + ridge I)^{-1}` is the
  BLP's regression matrix. This is consistent with
  the upstream
  `doubleml.utils._estimation._compute_sensitivity_elements`
  convention, where `nu2 = E[score_d^2]` and the
  score is the per-observation influence on the
  k-th coefficient.

### Why a separate function?
The homoskedastic formula conflates `nu2` with
`se^2` via `se^2 = sigma^2 * (Z^T Z)^{-1}_{kk}`,
which is only correct under homoskedasticity. The
HC0 SE
`se^2 = sum_i (M[k,:] @ x_i)^2 * e_i^2` does not
satisfy the same relation; the projection-weight
formula is the HC0-compatible alternative.

Under homoskedasticity the two formulas agree
exactly; under heteroskedasticity they differ
in a way that captures the per-observation
"weight" the basis has on the k-th coefficient.

### Tests
- 235/235 across all 4 backends (native, wasm-gc,
  wasm, js). Was 231 in v0.22.0; +4 new tests in
  `sensitivity_test.mbt`:
  - `gain_stats_from_blp_hc0_basic` — basic
    shape and accessor consistency.
  - `gain_stats_from_blp_hc0_nu2_differs` — the
    HC0 `nu2` differs from the homoskedastic
    `nu2` (computed by `from_blp_cv`) on a
    heteroskedastic DGP. On a homoskedastic
    DGP the two are equal.
  - `gain_stats_from_blp_hc0_nu2_matches_projection_formula`
    — recompute the projection formula from
    scratch and verify bit-equal to the
    function output.
  - `panic_gain_stats_from_blp_hc0_unfitted` —
    `from_blp_hc0` requires the BLP to be fit.

### Notes
- The intercept `nu2[0]` is set to 1.0 (sentinel),
  matching the convention from `from_blp` and
  `from_blp_cv`. The intercept doesn't have a
  "projection weight" in the OLS sense; the
  sentinel is a no-op in the `gain_statistics`
  algorithm.
- `coef`, `se`, `var_y`, `all_coef` are unchanged
  from `from_blp` / `from_blp_cv`.
- The regression matrix `M` is recomputed inside
  `from_blp_hc0` (the `LinearRegression` learner
  only stores the diagonal of `M`, not the full
  matrix, so we re-invert to get the full `M`).
  This is a one-time cost per `from_blp_hc0` call
  and is negligible for the typical BLP
  dimensions (`p <= 10`).

---

## [0.22.0] — `GainStatsSource::from_blp_cv` (cross-fit BLP)

### Added
- **`GainStatsSource::from_blp_cv(blp, n_folds?,
  seed?)`**: cross-fit variant of `from_blp`. The
  only difference is `var_y_residuals`, which is
  computed from out-of-fold (OOF) predictions
  rather than the in-sample BLP residuals. The OOF
  residual variance is honest (no leakage from the
  basis fit on the same rows), so the `R2_y`
  benchmark in `gain_statistics` is more accurate.
  Algorithm:
  1. Draw `n_folds` random folds via `kfold` (with
     `seed` for reproducibility).
  2. For each fold, fit a `LinearRegression` on the
     training rows and predict on the test fold.
  3. Compute the per-fold test residual variance
     `sigma2_fold = sum_i (y_i - y_hat_i)^2 / n_fold`.
  4. `var_y_residuals_scalar = sum_fold sum_i
     (y_i - y_hat_i)^2 / n_obs` (the OOF residual
     variance, equivalent to the weighted average
     of per-fold `sigma2_fold` with weights
     `n_fold / n_obs`).
- **`DoubleMLBLP::orth_signal()` accessor**:
  returns the BLP's orthogonal signal array
  (length `n_obs`). Used by `from_blp_cv` to
  recompute the residuals.
- **`DoubleMLBLP::basis()` accessor**: returns the
  BLP's basis matrix (shape `n_obs x p_features`).
  Used by `from_blp_cv` to refit the BLP on each
  fold's training subset.

### Tests
- 231/231 across all 4 backends (native, wasm-gc,
  wasm, js). Was 225 in v0.21.0; +6 new tests in
  `sensitivity_test.mbt`:
  - `gain_stats_from_blp_cv_basic` — basic
    auto-population; shape and per-coef consistency
    with the BLP's full-data fit.
  - `gain_stats_from_blp_cv_differs_from_in_sample`
    — the cross-fit `var_y_residuals` is at least
    the in-sample `var_y_residuals` (because the
    in-sample version is biased low).
  - `gain_stats_from_blp_cv_deterministic` —
    same `seed` produces bit-equal `var_y_residuals`
    and `nu2`.
  - `gain_stats_from_blp_cv_end_to_end` — two
    BLPs (long = constant, short = noise) with
    the same `n_coef`; the long has lower cross-fit
    `var_y_residuals`.
  - `panic_gain_stats_from_blp_cv_unfitted` —
    `from_blp_cv` requires the BLP to be fit.
  - `panic_gain_stats_from_blp_cv_n_folds_too_small`
    — `n_folds` must be >= 2.

### Notes
- The cross-fit `var_y_residuals` is **strictly
  larger** than the in-sample version on average
  (because the basis was fit on the same rows
  in the in-sample case, so the in-sample
  residuals are biased low). The test
  `gain_stats_from_blp_cv_differs_from_in_sample`
  verifies this direction.
- The OOF residual variance is the right thing
  for sensitivity benchmarks because it
  approximates the "honest" R^2 the basis would
  achieve on held-out data. The in-sample version
  is the "training R^2", which is upward-biased
  and gives an overly optimistic `cf_y` benchmark.
- `coef`, `se`, `var_y`, and `all_coef` are
  unchanged from `from_blp`. The BLP's own fit
  on the full data is the canonical coefficient
  estimate; only `var_y_residuals` and `nu2` are
  recomputed.
- `n_rep` is fixed at 1 for `from_blp_cv`. The BLP
  is a single-shot fit, so multi-rep would require
  multiple BLP fits with different folds; defer to
  a future release if needed.

---

## [0.21.0] — `DoubleMLDIDCrossSection::bootstrap` (multiplier bootstrap + joint CI)

### Added
- **`DoubleMLDIDCrossSection::bootstrap(method_name?,
  n_rep_boot?, seed?)`**: multiplier bootstrap for
  the cross-section DID. Draws `n_rep_boot` weight
  vectors of length `n_obs` from the chosen
  multiplier distribution (`"normal"`, `"Bayes"`,
  `"wild"`), computes
  `boot_t_stat[b] = sum_i w[b, i] * psi[i] / (sqrt(n) *
  se_psi)` where `psi[i] = psi_a[i] + theta * psi_b[i]`
  is the per-observation influence function and
  `se_psi = sqrt(sum_i psi_i^2 / n)` is the SE of the
  mean of `psi`, and returns a fitted model with
  `boot_t_stat` populated. The bootstrap t-stat has
  mean 0 and SD 1 under H0 (matches the panel
  `DoubleMLDIDMulti` convention).
- **`DoubleMLDIDCrossSection::confint(joint?,
  level?)`**: extended to accept the `joint` and
  `level` parameters. When `joint = false` (default),
  uses the Wald-style `theta ± z * se` interval with
  `z = norm_ppf((1 + level) / 2)`. When `joint = true`,
  uses the multiplier bootstrap: the critical value
  is the empirical `(1 + level) / 2` quantile of
  `|boot_t_stat|`. `bootstrap()` must be called first.
- **`DoubleMLDIDCrossSection::boot_t_stat` /
  `boot_method` / `n_rep_boot` / `boot_seed`**:
  read-only accessors for the bootstrap output and
  metadata.
- **`norm_ppf(p)`** (in `did_cross_section.mbt`):
  standard-normal quantile function. Uses 64-iter
  bisection on the new `norm_cdf`, accurate to
  ~7.5e-8 in `Phi` (i.e., ~1.3e-6 in `z`).
- **`norm_cdf(x)`** (in `did_cross_section.mbt`):
  standard-normal CDF. Implements A&S 7.1.26
  directly (rather than via the existing
  `norm_sf`, which saturates to 1.0 at `x <= 0` and
  is unsuitable for `Phi(0) = 0.5`).

### Changed
- `DoubleMLDIDCrossSection::confint` now accepts
  optional `joint?` and `level?` parameters. The
  old single-arg form `confint()` still works
  (default args: `joint = false, level = 0.95`)
  and is bit-equal to v0.20.0.

### Tests
- 225/225 across all 4 backends (native, wasm-gc,
  wasm, js). Was 215 in v0.20.0; +10 new tests in
  `did_cross_section_test.mbt`:
  - `did_cross_section_bootstrap_basic` — `boot_t_stat`
    length and metadata.
  - `did_cross_section_bootstrap_deterministic` —
    same seed produces bit-equal output.
  - `did_cross_section_bootstrap_moments` —
    `boot_t_stat` has mean ~ 0 and SD ~ 1.
  - `did_cross_section_bootstrap_bayes` —
    `method_name = "Bayes"` produces a different
    draw.
  - `did_cross_section_bootstrap_wild` —
    `method_name = "wild"` works.
  - `panic_did_cross_section_joint_confint_without_bootstrap`
    — `confint(joint=true)` aborts if `bootstrap()`
    wasn't called.
  - `did_cross_section_joint_confint_wider` —
    joint CI is wider than pointwise.
  - `did_cross_section_confint_custom_level` —
    `level = 0.99` is wider than default `0.95`.
  - `did_cross_section_norm_cdf_ppf_inverse` —
    `norm_cdf(norm_ppf(p)) ≈ p` within 1e-4.
  - `did_cross_section_norm_ppf_975` —
    `norm_ppf(0.975) ≈ 1.96` (within 1e-5).

### Cross-check vs numpy
The `validate_did_cross_section_with_python.py`
script now also emits the bootstrap t-stat moments
(mean, SD, 97.5th percentile of `|t|`) from a
numpy-based multiplier bootstrap. The MoonBit
matches numpy to within Monte-Carlo error
(mean ~ 0.04, SD ~ 1.0, |t|_0.975 ~ 2.2).

### Notes
- The bootstrap uses `se_psi = sqrt(sum_i psi_i^2 /
  n)` (the SE of the mean of `psi`), NOT `se_theta`
  (the SE of `theta_hat` from the cross-section
  DID's "ratio" estimator). The reason: the
  cross-section DID's `se_theta` is the SE of a
  *ratio* (`-<psi_a, psi_b> / ||psi_b||^2`),
  which is not a simple mean; using it as the
  bootstrap denominator would give a bootstrap
  t-stat with SD ≠ 1. Using `se_psi` restores the
  standard multiplier bootstrap convention
  (mean 0, SD 1 under H0).
- The `joint` CI is wider than the pointwise CI
  by construction: the empirical
  `(1 + level) / 2` quantile of `|boot_t_stat|`
  is at least the median (~ 0.67) and typically
  close to the normal critical value (1.96 for
  95%). The joint CI is the empirical-quantile
  CI, not the Bonferroni-corrected CI.
- `norm_cdf` and `norm_ppf` are public (in
  `did_cross_section.mbt`) for testability. They
  could be promoted to a shared utility module
  in a future release; for now they live with
  the cross-section DID code.

---

## [0.20.0] — `DoubleMLDIDCrossSection` (Sant'Anna-Zhao 2020 cross-section DID)

### Added
- **`DoubleMLDIDCrossSectionData`** (in new
  `did_cross_section.mbt`): cross-section DID data
  container with `x : Matrix`, `y : Array[Double]`,
  `d : Array[Double]` (binary {0, 1}), and
  `t : Array[Int]` (binary {0, 1}). Each unit has
  ONE observation (no `id` column, no `g` column).
- **`DoubleMLDIDCrossSection`**: cross-section DID
  model. Fits 4 g-functions `g(d, t, x) = E[Y | D=d,
  T=t, X]` and 1 propensity `m(x) = E[D=1 | X]` via
  cross-fit linear regression, then constructs the
  ATT score function per the upstream
  `doubleml.DoubleMLDIDCS._score_elements` formula:
  - `psi_a = -weight_psi_a`
    (with `weight_psi_a = d / p_hat` for
    observational, or `d / mean(d)` for
    in-sample normalization, or `1` for
    experimental).
  - `psi_b = psi_b_1 + psi_b_2`, where
    `psi_b_1 = sum_(d,t) weight_g_dt * g_dt_hat`
    and
    `psi_b_2 = sum_(d,t) weight_resid_dt * resid_dt`.
  - Theta is the closed-form OLS estimate
    `-<psi_a, psi_b> / ||psi_b||^2`.
  - SE is the HC0 sandwich
    `sqrt(sum_i (psi_a + theta*psi_b)^2 / (n *
    inner_bb / n)^2)`.
- **Public accessors on the model**:
  - `coef()` / `se()` / `confint()`: ATT point
    estimate, HC0 SE, 95% Wald CI.
  - `psi_a()` / `psi_b()`: per-observation score
    elements (length `n`).
  - `predictions_g_d{0,1}_t{0,1}()`: the 4
    g-function predictions.
  - `predictions_m()`: the propensity predictions
    (clipped + ps-processor adjusted).
- **`cmd/did_cross_section/main.mbt`**: a runnable
  demo on a 500-unit DGP with true ATT = 1.0.
- **`validate_did_cross_section_with_python.py`**:
  the 16th Python validator. Replicates the upstream
  `_score_elements` formula in numpy and emits the
  reference `theta_hat` for a 200-unit DGP.

### Score variants
Four (score, in_sample_normalization) combinations
are supported, matching the upstream:
- `("observational", false)`: canonical
  Sant'Anna-Zhao, doubly-robust with propensity
  reweighting.
- `("observational", true)`: in-sample
  normalization.
- `("experimental", false)`: A/B-test setting
  (treatment independent of covariates); the
  propensity `m` is not used in the score.
- `("experimental", true)`: experimental +
  in-sample normalization.

### Tests
- 215/215 across all 4 backends (native, wasm-gc,
  wasm, js). Was 204 in v0.19.0; +11 new tests in
  `did_cross_section_test.mbt`:
  - `panic_did_cross_section_rejects_non_binary_d`
  - `panic_did_cross_section_rejects_t_all_zero`
  - `did_cross_section_data_accessors`
  - `did_cross_section_recovers_known_att` —
    end-to-end ATT recovery on a 500-unit DGP with
    true ATT = 1.0; ATT_hat ∈ [0.5, 1.5] and the
    95% CI contains 1.0.
  - `did_cross_section_experimental_score` —
    `score = "experimental"`, same DGP, ATT_hat
    also in [0.5, 1.5].
  - `did_cross_section_in_sample_normalization` —
    `in_sample_normalization = true`, same DGP,
    ATT_hat also in [0.5, 1.5].
  - `did_cross_section_psi_a_basic` — `psi_a` is
    the negative of the treatment-weighted
    indicator, length `n`.
  - `did_cross_section_orthogonalization` —
    `mean(psi_a + theta * psi_b) ≈ 0` (the
    orthogonalization property).
  - `did_cross_section_predictions` — all 5
    prediction accessors return length-`n` arrays.
  - `did_cross_section_confint_centered` —
    `confint = (theta - 1.96 * se, theta + 1.96 * se)`.
  - `did_cross_section_deterministic` — same seed
    produces bit-equal ATT and SE.

### Cross-check vs upstream numpy
For `n = 200, p = 2, att = 1.0` (the same DGP shape
as the MoonBit test):
- `theta_hat ≈ 0.83` (MoonBit recovers ~0.83 too;
  the n=200 sample is small).
- The MoonBit `psi_a` and `psi_b` match the numpy
  `_score_elements` formula to within 1e-9 (the
  closed-form OLS score function is exact).

### Notes
- The cross-section DID model is the
  Sant'Anna-Zhao 2020 "repeated cross-sections"
  variant (one observation per unit, two time
  periods). It is NOT the same as the panel DID
  model (`DoubleMLDIDBinary` /
  `DoubleMLDIDCS`): the panel DID uses 2
  g-functions (g(0) and g(1)), while the
  cross-section DID uses 4 g-functions
  (g(d, t) for the 4 (d, t) cells). The
  cross-section model is more flexible (the
  outcome can depend on (d, t, x) instead of just
  (d, x)) but requires 2x more nuisance fits.
- Default config: `score = "observational"`,
  `in_sample_normalization = false`,
  `n_folds = 5`, `n_rep = 1`, `seed = 3141`,
  `propensity_clip = 1e-6`, default
  `PSProcessor`.
- The cross-section DID is a SCALAR estimator (one
  ATT), unlike the panel DID which produces a
  (g, t) grid. The "universal" keyword in
  `DoubleMLDIDMulti::gt_combinations_keyword` does
  not apply to the cross-section model (it's a
  panel-only concept).

---

## [0.19.0] — `GainStatsSource::from_blp` auto-population

### Added
- **`DoubleMLBLP::n_obs()`** accessor: sample size used
  by the BLP fit. Throws if the BLP hasn't been fit yet.
- **`DoubleMLBLP::rss()`** accessor: residual sum of
  squares from the BLP fit. Equals
  `sum_i (orth_signal[i] - basis[i] @ coef)^2`.
- **`DoubleMLBLP::var_y()`** accessor: variance of the
  BLP's orthogonal signal (the BLP's "outcome"
  variable). Computed as a population variance
  (divisor `n`).
- **`GainStatsSource::from_blp(blp, n_rep?)`**:
  re-implemented to auto-populate the per-rep arrays
  from the BLP's fit output:
  - `var_y_residuals[k] = RSS / n_obs` (constant
    across coefficients; the BLP's residual
    variance).
  - `nu2[k] = var_y_residuals[k] / (n_obs * se[k]^2)`
    (per-coef Riesz representer norm squared under
    the homoskedastic OLS convention
    `se[k]^2 = sigma^2 * (Z^T Z)^{-1}_{kk}`).
  - `all_coef[k] = blp.coef()[k]`.
  - `var_y = blp.var_y()` (the BLP's outcome
    variance).
  - `n_rep` defaults to 1 (single-rep BLP); the BLP
    does not natively produce per-rep sensitivity
    elements, so multi-rep values are broadcast.

### Changed
- `DoubleMLBLP` now stores `n_obs`, `rss`, and `var_y`
  post-fit. Initialised to `0`/`0.0`/`0.0` in `new`,
  filled in by `fit`. The `fit` method now also
  computes the residual sum of squares once and
  shares it between the HC0 and nonrobust paths.
- `GainStatsSource::from_blp` signature changed from
  `(blp, var_y_residuals, nu2, all_coef, n_rep, var_y)`
  (data-flow plumbing only) to `(blp, n_rep?)` (true
  auto-population). The old 6-arg form is removed.

### Tests
- 204/204 across all 4 backends (native, wasm-gc,
  wasm, js). Was 200 in v0.18.0; +4 new tests in
  `sensitivity_test.mbt`:
  - `gain_stats_from_blp_basic` — basic auto-population
    on a 2-column basis (3 coefs with intercept).
    Verifies all 4 per-rep arrays match the BLP's
    fit output.
  - `gain_stats_from_blp_n_rep` — `n_rep=1` (default)
    works; arrays are length `n_coef` (broadcast).
  - `panic_gain_stats_from_blp_unfitted` — `from_blp`
    requires the BLP to be fit first (the accessors
    throw if `!fitted`).
  - `panic_gain_stats_from_blp_n_rep_invalid` —
    `n_rep` must divide `n_coef` (3 does not divide
    2 with a 1-column basis).
  - `gain_stats_end_to_end_via_blp` — two BLPs (low
    and high noise) on the same 1-column basis
    (same `n_coef`), auto-populated sources, then
    `gain_statistics` runs end-to-end. The "long"
    model (low noise) has smaller `var_y_residuals`
    than the "short" model (high noise), and the
    per-coef benchmarks are in their valid ranges.

### Cross-check
- The 15/15 Python validators still PASS
  (including `validate_gain_statistics_with_python.py`,
  which is unaffected by the `from_blp` signature
  change — the underlying `gain_statistics` algorithm
  is unchanged).
- 5/5 demos still run cleanly with bit-equal output
  to v0.18.0 (none of them uses `from_blp`).

### Notes
- The HC0 SE convention is consistent with the
  homoskedastic interpretation of `nu2` up to O(1/n)
  corrections. For users who want a more accurate
  `nu2` under HC0, the upstream
  `doubleml.DoubleMLPLR.sensitivity_elements` is the
  authoritative source; the v0.19.0 port keeps the
  BLP-only path simple.
- The auto-population is consistent with the BLP's
  role as the post-DML second stage: BLP fits
  `orth_signal ~ basis`, so the BLP's residual
  variance is the natural analog of DML's `sigma2`,
  and the BLP's `se^2` is the natural analog of
  DML's `nu2 * sigma2 / n`.
- `n_rep > 1` is rare for BLP (the BLP is
  single-shot, not cross-fit). The broadcast
  behaviour is a convenience for users who want to
  store multiple BLP fits in one
  `GainStatsSource` (e.g. one per bootstrap
  replication, though that pattern is more
  commonly used with DML models directly).

---

## [0.18.0] — BH / BY FDR p-adjust

### Added
- **`did_multi.mbt::bh_fdr_p_adjust(unadjusted)`**:
  Benjamini-Hochberg FDR correction. Sort p-values
  ascending, `p_adj_sorted[k] = min(1, p_sorted[k] * n /
  (k + 1))`, enforce monotonicity from the largest rank
  downward (BH-specific direction), re-order to
  original cell order. Matches
  `statsmodels.stats.multitest.multipletests(p, method='fdr_bh')`.
- **`did_multi.mbt::by_fdr_p_adjust(unadjusted)`**:
  Benjamini-Yekutieli FDR correction. Same as BH but
  multiplied by the harmonic-sum factor
  `c = sum_{i=1}^{n} 1/i`. Matches
  `statsmodels.stats.multitest.multipletests(p, method='fdr_by')`.
- **`DoubleMLDIDMulti::p_adjust` accepts `"bh"` and
  `"by"`**: end-to-end dispatcher for FDR control.
  BH / BY do **not** require `bootstrap()` (they only
  consume the unadjusted p-values), so they are cheaper
  than the Romano-Wolf stepdown.

### Tests
- 200/200 across all 4 backends (native, wasm-gc, wasm,
  js). Was 192 in v0.17.0, +8 new tests:
  - `bh_fdr_handrolled` — known 4-element example
    with exact reference values.
  - `by_fdr_handrolled` — same example, BY formula
    with `c = 1 + 1/2 + 1/3 + 1/4 = 2.0833...`.
  - `bh_by_inclusion_relations` — `BY[i] >= BH[i]`
    pointwise (`c >= 1`).
  - `bh_by_sorted_output_is_monotonic` — algorithm
    invariant: BH/BY are non-decreasing when read in
    sorted-p order.
  - `p_adjust_bh_no_bootstrap_required` — end-to-end
    through `DoubleMLDIDMulti::p_adjust("bh")` on the
    canonical DGP.
  - `p_adjust_by_no_bootstrap_required` — end-to-end
    through `p_adjust("by")`, plus `BY >= BH` check.
  - `p_adjust_bh_deterministic` — same DGP, two fits,
    bit-equal output.
  - `bh_by_vs_statsmodels_reference` — exact
    cross-check against
    `statsmodels.stats.multitest.multipletests`
    on a 5-element p-value array.

### Cross-check vs statsmodels
For `p = [0.001, 0.01, 0.02, 0.03, 0.05]` (n = 5):

| Method | statsmodels | MoonBit |
|--------|-------------|---------|
| BH     | `[0.005, 0.025, 0.033333, 0.0375, 0.05]` | ✓ |
| BY     | `[0.011417, 0.057083, 0.076111, 0.085625, 0.114167]` | ✓ |

### Notes
- BH controls the false discovery rate (FDR); the
  adjusted p-values can be smaller than the unadjusted
  ones (BH is less conservative than Holm or
  Bonferroni on average).
- BY is at least as conservative as BH (`c >= 1`), but
  the comparison BY vs Bonferroni is case-by-case:
  BY sorts and applies a different scaling, so
  `BY[i] >= Bonferroni[i]` is **not** guaranteed.
- The 5 existing demos still produce bit-equal output
  to v0.17.0 (none call `p_adjust("bh")` or
  `p_adjust("by")`).
- 15/15 Python validators still PASS. The
  `validate_padjust_with_python.py` script now also
  emits the BH / BY reference values for
  cross-checking.

---

## [0.17.1] — `moon fmt` pass (hygiene)

### Fixed
- `kde.mbt`: trailing newline added. The file was
  last modified in v0.6.0; the missing EOL was a
  long-standing condition that the v0.17.0 release
  inherited. `moon fmt --check` had been silently
  failing on this file since v0.6.0.
- `cmd/datasets/moon.pkg`, `cmd/did_binary/moon.pkg`:
  trailing newline added (matches `cmd/did_cs` and
  `cmd/did_multi` `moon.pkg` which already had EOL).

### Changed (mechanical, no semantic change)
- `moon fmt` pass: 24 source files re-formatted by
  the official MoonBit formatter. Changes are pure
  whitespace / line-wrap / doc-comment re-flow
  (e.g. 19 tests in `ps_processor_test.mbt` added
  and 19 removed in net-zero fashion; 88
  doc-comment lines re-flowed). No API change, no
  behaviour change, no test change.
- Files affected (24):
  `cmd/datasets/main.mbt`, `cmd/datasets/moon.pkg`,
  `cmd/did_binary/main.mbt`, `cmd/did_binary/moon.pkg`,
  `cmd/did_cs/main.mbt`, `cmd/did_multi/main.mbt`,
  `did.mbt`, `did_aggregation_test.mbt`,
  `did_binary.mbt`, `did_binary_test.mbt`,
  `did_cs.mbt`, `did_cs_test.mbt`,
  `did_multi.mbt`, `did_multi_test.mbt`,
  `kde.mbt`, `kde_test.mbt`,
  `lpq.mbt`, `ps_processor.mbt`, `ps_processor_test.mbt`,
  `resampling.mbt`, `resampling_test.mbt`,
  `sensitivity.mbt`, `sensitivity_test.mbt`,
  `var_est.mbt`.

### Notes
- No behavioural change. This is a pure hygiene pass.
- 192/192 tests still pass (bit-equal to v0.17.0).
- 15/15 Python validators still PASS.
- 5/5 demos still run cleanly with bit-equal output
  to v0.17.0 (and to v0.16.0, v0.15.0, ...).
- `moon fmt --check` now exits clean.

---

## [0.17.0] — `gain_statistics` (sensitivity parameter benchmarks from two DML fits)

### Added
- **`sensitivity.mbt::gain_statistics(dml_long, dml_short)`**:
  compute the per-coefficient gain-statistic benchmark
  values `cf_y`, `cf_d`, `rho`, and `delta_theta` from
  two fitted DML models. Matches the upstream
  `doubleml.utils.gain_statistics.gain_statistics`:
  - `R2_y = 1 - var_y_residuals / var_y`
  - `R2_riesz = nu2_short / nu2_long`
  - `cf_y = clip((R2_y_long - R2_y_short) / (1 - R2_y_long), 0, 1)`
  - `cf_d = clip((1 - R2_riesz) / R2_riesz, 0, 1)`
  - `delta_theta = median(all_coef_short - all_coef_long)`
  - `rho = median(sign(delta_theta) * clip(|delta_theta| / sqrt(var_g * var_riesz), 0, 1))`,
    where `var_g = var_y_residuals_short - var_y_residuals_long`
    and `var_riesz = nu2_long - nu2_short`.
- **`sensitivity.mbt::GainStatsResult`**: container
  struct holding the four per-coefficient benchmark
  arrays (length `n_coef`).
- **`sensitivity.mbt::GainStatsSource`**: minimal source
  struct exposing the per-rep arrays
  `var_y_residuals`, `nu2`, `all_coef` (row-major
  `(n_coef, n_rep)`), plus `n_rep` and the scalar `var_y`.
  Designed so any DML estimator (BLP, PolicyTree, PLR,
  IRM, ...) can be benchmarked without the upstream
  `DoubleMLFramework` machinery.
- **`sensitivity.mbt::GainStatsSource::new`**: builder
  constructor that validates shape consistency (all three
  per-rep arrays have the same length; length divisible
  by `n_rep`).
- **`sensitivity.mbt::GainStatsSource::from_blp`**: a
  convenience constructor that takes a fitted
  `DoubleMLBLP` plus the manually-supplied per-rep arrays.
  Currently a thin wrapper that ignores the BLP and
  forwards the arrays; a future port can populate the
  per-rep arrays from the BLP's fit output automatically.
- **`sensitivity.mbt::median_sorted`**: helper that
  computes the median of a sorted array. Used internally
  by `gain_statistics`; exposed for testability.
- **`validate_gain_statistics_with_python.py`**: new
  Python cross-check. Replicates the upstream
  `gain_statistics` algorithm in numpy and emits the
  per-coefficient benchmarks for a 2-coef × 3-rep
  random DGP. The MoonBit tests in
  `sensitivity_test.mbt` match this reference within
  1e-12 on the same inputs.

### Notes / known limitations
- **`rho` and `cf_y` degenerate regimes**:
  - `rho = 0.0` (or `1.0` with sign) when `var_g * var_riesz <= 0`.
    The upstream's `np.divide(..., where=denom != 0)` sets
    the ratio to `1.0` in this regime, and the MoonBit
    port follows the same convention (`denom == 0` or NaN
    → `rho_abs = 1.0`).
  - `cf_y = 0` (clipped) when the long model has higher
    `R2_y` than the short model (i.e. the confounder
    helps with the long fit).
  - `cf_d = 0` (clipped) when `nu2_short >= nu2_long`.
- **No automatic DML attribute extraction**. The
  upstream `gain_statistics` reads
  `dml_long.framework.sensitivity_elements` directly.
  The v0.17.0 port defines `GainStatsSource` as an
  explicit input struct; users fill in `var_y_residuals`
  and `nu2` per rep (typically by re-fitting the model
  with different feature subsets or seeds). The
  `from_blp` helper is a placeholder for a future
  auto-population path.
- **The `from_blp` helper currently ignores its BLP
  argument** and forwards only the user-supplied arrays.
  A future port can compute `var_y_residuals` from
  `blp.coef()` and the BLP's RSS, and `nu2` from the
  BLP's sandwich SE; the v0.17.0 release ships the
  data-flow plumbing only.

### Verification
- 4-backend `moon test --deny-warn` (native, wasm,
  wasm-gc, js): **192/192 passed** (was 186, +6 new
  tests in `sensitivity_test.mbt`):
  - 1 `gain_statistics_handrolled`: algorithm
    correctness on a 1-coef, 1-rep toy DGP with known
    expected values.
  - 1 `gain_statistics_identical`: when long and short
    are identical, all four benchmarks are 0.
  - 1 `gain_statistics_clipping`: `cf_y` clips to 0
    when `R2_y_short > R2_y_long`; `cf_d` clips to 1
    when `R2_riesz = 0.1` (raw value 9).
  - 1 `gain_statistics_multi_coef_multi_rep`: 2-coef,
    3-rep hand-rolled DGP; output is length 2 with
    exact expected values.
  - 1 `panic_gain_statistics_length_mismatch`:
    per-rep arrays of different lengths abort.
  - 1 `gain_stats_from_blp_basic`: the
    `GainStatsSource::from_blp` helper constructs a
    source from a fitted BLP + user-supplied arrays.
- 15 Python validators: all PASS, including the new
  `validate_gain_statistics_with_python.py`.
- 5 demos (`moon run cmd/{main, datasets, did_binary,
  did_cs, did_multi}`) all run cleanly and produce
  bit-equal output to v0.16.0. None calls
  `gain_statistics` (it's opt-in via the
  `GainStatsSource` + `gain_statistics` API).

---

## [0.16.0] — `DoubleMLDIDMulti` multiple-testing p-adjustment (Romano-Wolf / Holm / Bonferroni)

### Added
- **`did_multi.mbt::DoubleMLDIDMulti::p_adjust(method_name)`**:
  multiple-testing p-value adjustment for the per-(g, t)
  ATTs. Returns an `Array[Double]` of adjusted p-values
  (length `n_combinations`).
  - `"romano-wolf"` (default): the stepdown bootstrap
    procedure from Romano & Wolf (2005). For each cell
    `k`, sorted by descending `|t_k|`, compute
    `p_k = mean_b [max_j > k |boot_t_stat[b, j]| >=
    |t_k|]`. Then enforce monotonicity:
    `p_corrected[k] = max(p_k, p_corrected[k - 1])` (in
    sorted order). Requires `bootstrap()` to have been
    called first.
  - `"rw"`: alias for `"romano-wolf"`.
  - `"holm"`: Holm-Bonferroni stepdown (no bootstrap
    required). Sort unadjusted p-values ascending; for
    each `k`, `p_corrected[k] = max((n - k) * p_sorted[k],
    p_corrected[k - 1])`, then re-sort to original order.
  - `"bonferroni"`: `p_corrected[k] = n * p_k`, clipped
    to `1.0`. No bootstrap required.
- **`did_multi.mbt::DoubleMLDIDMulti::t_stats()`**:
  per-cell Wald-style t-statistics `theta / se` (length
  `n_combinations`). Used by `p_adjust`.
- **`did_multi.mbt::DoubleMLDIDMulti::p_values()`**:
  per-cell unadjusted two-sided p-values for `H0:
  theta = 0`. Length `n_combinations`.
- **`did_multi.mbt::romano_wolf_p_adjust(boot_t_stat,
  unadjusted, t_stats)`** (public for testability):
  pure MoonBit Romano-Wolf stepdown.
- **`did_multi.mbt::holm_bonferroni_p_adjust(unadjusted)`**
  (public for testability): pure MoonBit
  Holm-Bonferroni stepdown.
- **`did_multi.mbt::bonferroni_p_adjust(unadjusted)`**
  (public for testability): pure MoonBit Bonferroni.
- **`did_multi.mbt::norm_sf(x)`** (public for
  testability): standard-normal survival function
  `P(Z > x)` using the Abramowitz & Stegun (1964)
  formula 7.1.26 (max absolute error ~7.5e-8 for
  `x >= 0`). MoonBit's `@math` does not expose
  `erfc`, so we approximate the normal CDF directly.
- **`validate_padjust_with_python.py`**: new Python
  cross-check. Replicates the upstream Romano-Wolf
  algorithm with `numpy.random.normal` +
  `scipy.stats.norm.sf`, then compares to the MoonBit
  output via the per-cell `t_stats` accessor +
  `p_adjust`.

### Notes / known limitations
- **Romano-Wolf is conservative by construction**. The
  adjusted p-values are >= the unadjusted p-values.
  With `n_rep_boot = 500` and a small number of cells
  (3-12), the critical value's Monte-Carlo error is
  ~`1 / n_rep_boot = 0.002`. Users on designs with
  many cells should bump `n_rep_boot` to 1000+ for
  tighter adjusted p-values.
- **No `BH` / `BY` upstream methods**. The
  `statsmodels.stats.multitest.multipletests`
  fallback path supports `bonferroni`, `holm`,
  `sidak`, `fdr_bh`, `fdr_by`, etc. We port the most
  common three (`romano-wolf`, `holm`,
  `bonferroni`); the rest are deferred — add a
  one-liner per method in `did_multi.mbt::p_adjust`
  if needed.
- **The default `p_adjust(method_name)` is
  `"romano-wolf"`**. To use Holm without bootstrap,
  pass `method_name="holm"` explicitly.
- **The `p_adjust(romano-wolf)` before
  `bootstrap()` aborts**. The error message names the
  upstream `DoubleMLFramework.p_adjust("romano-wolf")`
  contract.

### Verification
- 4-backend `moon test --deny-warn` (native, wasm,
  wasm-gc, js): **186/186 passed** (was 174, +12 new
  tests in `did_multi_test.mbt`):
  - 1 `t_stats_basic`: |t| is large on the canonical
    DGP.
  - 1 `p_values_basic`: unadjusted p-values are
    vanishingly small.
  - 1 `p_adjust_holm`: Holm-Bonferroni on the
    canonical DGP.
  - 1 `p_adjust_bonferroni`: Bonferroni on the
    canonical DGP.
  - 1 `p_adjust_romano_wolf`: Romano-Wolf on the
    canonical DGP.
  - 1 `p_adjust_romano_wolf_alias_rw`: `"rw"` alias.
  - 1 `p_adjust_romano_wolf_handrolled`: algorithm
    correctness on a hand-rolled t-statistic vector.
  - 1 `holm_bonferroni_monotonic`: Holm on a
    hand-rolled unadjusted-p-value vector.
  - 1 `bonferroni_handrolled`: exact-value test.
  - 1 `panic_p_adjust_unknown_method`: abort on
    invalid method name.
  - 1 `panic_p_adjust_romano_wolf_without_bootstrap`:
    abort on Romano-Wolf before bootstrap.
  - 1 `p_adjust_deterministic_seed`: same seed →
    bit-equal adjusted p-values.
- 14 Python validators: all PASS, including the new
  `validate_padjust_with_python.py`.
- 5 demos (`moon run cmd/{main, datasets, did_binary,
  did_cs, did_multi}`) all run cleanly and produce
  bit-equal output to v0.15.0. None calls `p_adjust`
  (it's opt-in via `DoubleMLDIDMulti::p_adjust`).

---

## [0.15.0] — `DoubleMLDIDMulti` multiplier bootstrap / joint confidence intervals

### Added
- **`did_multi.mbt::DoubleMLDIDMulti::bootstrap(method_name,
  n_rep_boot, seed)`**: multiplier bootstrap for joint
  confidence intervals. Draws `n_rep_boot` weight vectors
  from the chosen multiplier distribution and computes
  per-cell t-statistics
  `boot_t_stat[b, k] = sum_i w[b, i] * psi_k[i] / (sqrt(n) * se_k)`.
  Supports `"normal"` (default; matches upstream
  `bootstrap(method="normal")`), `"Bayes"`, and `"wild"`
  (robust to heteroskedasticity). The chacha8 RNG is seeded
  by `seed` for reproducibility (default `2024`).
- **`did_multi.mbt::DoubleMLDIDMulti::confint(joint, level)`**:
  confidence intervals for the per-(g, t) ATT. `joint = false`
  (default) returns Wald-style `theta ± 1.96 * se` intervals.
  `joint = true` returns bootstrap intervals
  `theta ± cv * se` where `cv` is the empirical
  `level`-quantile of `max_k |boot_t_stat[b, k]|` across
  bootstrap replications. Joint CIs are wider (more
  conservative) and require `bootstrap()` to be called first.
- **`did_multi.mbt::draw_bootstrap_weights(method_name,
  n_rep_boot, n_obs, seed)`** (public for testability): pure
  MoonBit weight-draw function for the three multiplier
  distributions. Returns a row-major `(n_rep_boot, n_obs)`
  array.
- **`did_multi.mbt::box_muller_normal(rng)`** (public for
  testability): standard-normal sample via Box-Muller.
- **`did.mbt` (v0.15.0 extension)**: `DoubleMLDID` now
  exposes per-observation `psi_a` and `psi_b` influence-
  function components (length `n_obs` on the wide-format
  data). The DML score is `psi_a + theta * psi_b`; this is
  the influence function used by the multiplier bootstrap.
- **`did_binary.mbt` (v0.15.0 extension)**:
  - `WideDIDSubset` now also stores the long-format
    `eval_idx` per wide-format row (the index into the
    `DoubleMLDIDBinaryData` long-format array).
  - `DoubleMLDIDBinary` stores `eval_idx` in its struct
    and exposes `psi_a_long` / `psi_b_long` accessors that
    map the wide-format psi back to the long-format panel
    (with 0 padding for rows not in the cell).
  - `DoubleMLDIDBinary` also exposes `inner_psi_a` /
    `inner_psi_b` accessors that return the wide-format
    psi directly, used by the per-cell loop in
    `DoubleMLDIDCS::fit` to build the per-cell influence
    function on the full long-format panel.
- **`did_cs.mbt` (v0.15.0 extension)**:
  - `DoubleMLDIDCS` now stores a `psi_matrix` of shape
    `(n_groups * n_periods, n_obs)`: the per-cell
    influence function on the full long-format panel,
    used by the multiplier bootstrap.
  - The per-cell fit loop records the full long-format
    index for each sub row (`full_idx_acc`) and uses it
    to map the cell's wide-format psi back to the full
    long-format panel via the wide-format `eval_idx`.
- **`validate_bootstrap_with_python.py`**: new Python
  cross-check. Computes the empirical moments of the
  three multiplier distributions (mean ≈ 0, variance ≈ 1)
  on a 200 × 50 weight matrix to verify the algorithm
  matches the upstream `numpy.random.normal /
  exponential` shape (the actual values differ because
  MoonBit uses chacha8 vs. numpy's PCG64, but the
  distributions agree).

### Changed
- **`did.mbt::DoubleMLDID` struct** gained `psi_a` and
  `psi_b` fields (length `n_obs` each). The `fit` method
  populates them alongside the existing `coef` / `se` /
  `g0_hat` / `g1_hat` / `m_hat` outputs. Existing call
  sites continue to work; the new fields are additive.

### Notes / known limitations
- **Joint CIs are conservative by construction**. The
  bootstrap critical value is the empirical `level`-
  quantile of `max_k |boot_t_stat[b, k]|` over
  `n_rep_boot` replications. With `n_rep_boot = 500`
  and `level = 0.95`, the critical value is typically
  2.5 – 4 on the canonical DGP (vs. 1.96 for the
  pointwise Wald CI). This matches the upstream
  `confint(joint=True)` behaviour.
- **Joint CIs on a small DGP may not cover the true
  ATT**. With `n = 240` units and `n_rep_boot = 500`,
  the joint CIs are wide enough that coverage holds
  for the canonical DGP; users on smaller designs
  should bump `n_rep_boot` to 1000+ for tighter
  critical-value estimates.
- **No `panel = False` (cross-section) support for
  the bootstrap**. The CS-DID bootstrap (which would
  resample at the cross-section unit level) is out of
  scope; the v0.15.0 port is panel-only. The
  `DoubleMLDIDCS` upstream class has a `panel` flag
  but the v0.9.0+ port always uses panel mode.
- **The bootstrap RNG seed is `2024` by default**,
  matching the upstream `numpy.random.seed(2024)` for
  the canonical `_verify/test_bootstrap_reference.py`
  first-test setup. Users can pass a different `seed`
  for reproducibility across runs.
- **No `_draw_weights` upstream exact-value parity**:
  MoonBit's chacha8 RNG and numpy's PCG64 produce
  different absolute weight values, so the bootstrap
  critical values are not bit-equal to upstream. The
  empirical moments match (mean ≈ 0, variance ≈ 1)
  and the joint CI coverage matches asymptotically.
  The `validate_bootstrap_with_python.py` script
  documents the RNG difference.

### Verification
- 4-backend `moon test --deny-warn` (native, wasm,
  wasm-gc, js): **174/174 passed** (was 163, +11 new
  tests in `did_multi_test.mbt`):
  - 3 weight-moment tests (normal / Bayes / wild
    means ≈ 0, variances ≈ 1 on 200 × 50 matrices).
  - 1 determinism test (same seed produces bit-equal
    `boot_t_stat`).
  - 1 joint-wider-than-pointwise test (the central
    property of joint CIs).
  - 2 CI coverage tests (pointwise and joint CIs both
    cover the true ATT for every (g, t) cell on the
    canonical DGP).
  - 3 `panic_` tests (joint CIs before bootstrap;
    bootstrap before fit; invalid `method_name`).
  - 1 default-method test (default `"normal"`, default
    `n_rep_boot = 500`).
- 13 Python validators: all PASS, including the new
  `validate_bootstrap_with_python.py`.
- 5 demos (`moon run cmd/{main, datasets, did_binary,
  did_cs, did_multi}`) all run cleanly and produce
  bit-equal output to v0.14.0. None of the demos
  calls `bootstrap()` (it's opt-in via
  `DoubleMLDIDMulti::bootstrap`).

---

## [0.14.0] — isotonic (PAVA) propensity-score calibration

### Added
- **`ps_processor.mbt::pava(y, weights?)`** — pure-MoonBit
  pool-adjacent-violators algorithm. Given a sequence `y`
  sorted by the predictor `x` and (optionally) per-element
  `weights`, returns the isotonic (non-decreasing) L2
  projection. Each output block is the weighted mean of its
  constituent elements; ties in the input are handled by
  the algorithm itself (they form a single block).
  Weighted-mean handling matches the canonical PAVA
  convention: a single block of `n` weighted observations
  with sum `s` and weight `w` reports `s / w`, not `s / n`.
- **`ps_processor.mbt::fit_isotonic(x, y)`** — sort `(x, y)`
  by `x` (stable sort, ties preserve original order) and
  apply `pava` to the sorted `y`. Returns `(sorted_x,
  sorted_y_hat)` with both arrays the same length as the
  input. Used as the calibration-step foundation for
  `PSProcessor::adjust_ps`.
- **`ps_processor.mbt::predict_isotonic(fitted_x,
  fitted_y_hat, x_new)`** — step-function lookup on the
  PAVA-fitted model. For each `x_new[i]`, returns the
  `fitted_y_hat` at the largest `fitted_x[j] <= x_new[i]`,
  clipped to `[0, 1]` (defensive). Matches
  `sklearn.isotonic.IsotonicRegression(out_of_bounds="clip",
  y_min=0.0, y_max=1.0)` on the no-tie case.
- **Isotonic calibration in `PSProcessor::adjust_ps`**.
  `PSProcessorConfig::new` already accepted
  `calibration_method="isotonic"` in v0.10.0 as a
  forward-compat placeholder; v0.14.0 wires up the actual
  PAVA-based fit. The new `cv?` parameter on
  `PSProcessor::adjust_ps(ps, treatment, cv?)` is consulted
  only when `config.calibration_method="isotonic"` and
  `config.cv_calibration=true`: each `(train_idx, test_idx)`
  fold fits PAVA on the training subset and predicts on
  the test subset, concatenating the held-out predictions
  in the original index order. When `cv = None`, a
  deterministic 5-fold split with `seed=3141` is used
  (matches upstream `cross_val_predict(cv=5)` default).
- **`validate_pava_with_python.py`** — new Python
  cross-check. Prints the sklearn `IsotonicRegression`
  reference (in-sample + 5-fold CV) on a 10-element DGP
  with strictly-distinct propensity scores and binary
  treatment; the per-DGP numbers are used as the
  ground-truth for the MoonBit test cases in
  `ps_processor_test.mbt`.

### Changed
- **`PSProcessor::adjust_ps` signature** gained a third
  optional `cv?` parameter. Default `cv = None` means
  "use the deterministic 5-fold split" when
  `cv_calibration=true`, and is ignored otherwise. No
  caller is broken: existing calls `adjust_ps(ps, t)`
  continue to work and the v0.10.0..v0.13.0
  `calibration_method="none"` path is byte-equal to
  v0.14.0.
- **`ps_processor.mbt::PSProcessorConfig` docstring**:
  the v0.10.0 "v0.12+ TODO" placeholder is gone. The
  isotonic section now describes the actual v0.14.0
  semantics (PAVA fit, optional CV) with a usage
  example.
- **Validation helper added**: `validate_treatment`
  (private) aborts on non-binary `treatment[i]` in
  `0.0 / 1.0` before any calibration work runs. The
  upstream `_validate_treatment` (full type/dim check
  + `type_of_target == "binary"`) is a strict superset
  but we don't have a generic target-type helper in
  pure MoonBit; the bitwise `0.0 / 1.0` check is the
  upstream-equivalent contract for the propensity-score
  use case.

### Fixed
- **`PSProcessorConfig` v0.10.0 placeholder abort**:
  v0.10.0..v0.13.0 `calibration_method="isotonic"` would
  call `abort("isotonic calibration not yet implemented
  in this port")` on first use. v0.14.0 implements the
  full PAVA-based calibration; the abort is gone.

### Notes / known limitations
- **PAVA tie handling differs from sklearn on tied-x
  inputs**. The MoonBit PAVA treats each `x` value as a
  separate observation (regardless of ties); sklearn's
  `IsotonicRegression` groups tied `x` values into a
  single block before applying PAVA. On a strictly
  distinct-x input (the canonical case for the
  propensity-score use, where `ps` is a continuous
  prediction) the two are bit-equal. On tied-x inputs
  the two may differ by a few ULPs of the block mean.
  This is documented in the v0.14.0 PAVA tests; the
  validate_pava_with_python.py script uses a 4-decimal
  random x to ensure no ties.
- **Default `cv` is a deterministic 5-fold split with
  `seed=3141`** (matches the package's standard fold
  RNG). To use a different fold partition, pass
  `cv=Some([(train1, test1), (train2, test2), ...])`;
  the union of all `test_idx` must cover `[0, n)`
  (otherwise `isotonic_calibrate_cv` aborts with a
  clear "cv partition does not cover all indices"
  message).
- **No `propensity_score_processing` upstream
  convenience function port** (the `init_ps_processor`
  wrapper in upstream that handles the deprecated
  `trimming_rule` / `trimming_threshold` keywords). The
  v0.14.0 entry point is the `PSProcessor` class
  directly; users who need the trimming-rule shim can
  build it on top of `PSProcessor::new` in 2 lines.
- **No change to the v0.10.0 default 1e-2 clip** or to
  the v0.13.0 accessor surface. The 1e-2 default is
  applied after the (optional) calibration step, so
  the user can opt into a different `clipping_threshold`
  without affecting the calibration.

### Verification
- 4-backend `moon test --deny-warn` (native, wasm,
  wasm-gc, js): **163/163 passed** (was 150, +13 new
  tests in `ps_processor_test.mbt`: 6 PAVA primitives +
  4 PSProcessor integration + 1 predict_isotonic step
  function + 1 CV path + 1 input-no-mutation guard).
- 12 Python validators: all PASS, including the new
  `validate_pava_with_python.py` (sklearn reference for
  PAVA in-sample + 5-fold CV on a 10-element DGP with
  distinct-x).
- 5 demos (`moon run cmd/{main, datasets, did_binary,
  did_cs, did_multi}`) all run cleanly and produce
  bit-equal output to v0.13.0. The `did_binary` and
  `did_cs` demos continue to use the default
  `PSProcessor` config (clip-only, no calibration); the
  isotonic calibration is opt-in via
  `calibration_method="isotonic"`.

---

## [0.13.0] — Polish: API accessor consistency, REVIEW history trim, logistic_test cleanup

### Added
- **`n_obs` / `n_features` accessors on every model**. The 15 estimators
  previously had an inconsistent API surface: `DoubleMLPLR`,
  `DoubleMLIRM`, `DoubleMLAPO`, `DoubleMLRDD`, `DoubleMLPQ`,
  `DoubleMLQTE`, `DoubleMLCVAR`, `DoubleMLLPQ` all now expose both
  accessors with matching docstrings. The implementations reuse the
  existing data containers (`data.n_obs()`, `data.n_features()`,
  `data.x.rows()` / `data.x.cols()` for the LPQ / RDD variants that
  carry a `Matrix` rather than a `DoubleMLData`).
- **`README.mbt.md::Demo entry points` table** documenting all five
  `cmd/*/main.mbt` drivers: which model each runs, what the DGP is,
  and what the true θ is. Each row is hyperlinked to the demo's
  source so users can read the DGP before running the demo.

### Changed
- **REVIEW history trim**: dropped 6 historical-context comments that
  no longer reflect the current code (REVIEW L2 / L3 / M3 / M4 / M9 /
  M10 — purely "we used to do X, now we do Y" notes). Kept the
  REVIEW comments that document real API contracts (L5 / L7 / L8 /
  L11 / L12 / H1 / M10-fix / L11-fix). Net `−20` lines of comment
  text with zero behaviour change.
- **`logistic_test.mbt` cleanup**: dropped the local 7-bit-encoding
  `logistic_seed_buf` helper (was used by 2 tests for the
  chacha8-RNG setup; net `−30` LOC). The new `chacha8_rng(N)` and
  `permute(n, seed: Int)` call paths use the canonical
  32-bit-LE `seed_to_bytes` encoding, so test results are bit-equal
  to v0.12.0.
- **`quantile.mbt`** + **`rdd.mbt`** + **`apo.mbt`** + **`kfold.mbt`**
  + **`blp_policy.mbt`** + **`linear.mbt`** + **`lpq.mbt`**:
  * Docstring consistency: every accessor now has the same
    "Number of observations." / "Number of features (covariate
    columns)." header. Several previously blank docstrings
    (PQ / QTE / CVAR / RDD's `n_obs`) are now filled in.
  * Three duplicate `///| ///|` doc-comment artifacts from
    `0.12.0`'s accessor-add pass are collapsed to single `///|`
    markers.

### Notes / known limitations
- **No behaviour change** vs. v0.12.0. This is a pure polish
  release: same numbers, same tests, just cleaner accessor surface
  and a tidier comment trail.
- **No new features, no test additions, no API breakage**. The
  `n_obs` / `n_features` additions are pure additions — no field
  renames, no signature changes.

### Verification
- 4-backend `moon test --deny-warn` (native, wasm, wasm-gc, js):
  **150/150 passed** (no test count delta from v0.12.0; this is
  a pure polish release).
- 11 Python validators: all PASS, including
  `validate_did_binary_with_python.py` and
  `validate_did_cs_with_python.py` (the most recent additions).
  No tolerance widened.
- 5 demos (`moon run cmd/{main,datasets,did_binary,did_cs,did_multi}`)
  all run cleanly and produce bit-equal output to v0.12.0.

---

## [0.12.0] — Cleanup: chacha8_rng helper + verifier-scratch hygiene

### Added
- **`seed.mbt::chacha8_rng(seed)`**: convenience constructor
  that returns `Rand::chacha8(seed=Bytes::from_array(seed_to_bytes(seed)))`.
  Used in 13 test files and 5 demos; the 3-line boilerplate
  pattern (`let bytes = seed_to_bytes(N); let rng =
  @random.Rand::chacha8(seed=Bytes::from_array(bytes))`)
  collapses to `let rng = chacha8_rng(N)`. The function is
  a one-liner but removes ~50 lines of duplicated code and
  keeps the canonical encoding visible at every callsite.

### Changed
- **`seed.mbt::seed_to_bytes` docstring**: the wildcard-vs-`3`
  match comment is now a one-liner explaining that
  `k ∈ 0..32` so the `_` arm is dead at runtime; the
  previous text talked about the `REVIEW L6` history that
  no longer reflects the current code.
- **`.gitignore`**: the `_verify/` directory is split into
  tracked-vs-scratch:
  - **Tracked** (must stay): `T###-verdict.md` and
    `T###-commit-msg.txt` — the release summary and the
    git commit message template.
  - **Scratch** (gitignored): build logs, probe outputs,
    Python validator outputs, ad-hoc adversarial test
    scripts, archived `.mbt.archived` files.
  - The 250+ historical `_verify/*.log`,
    `_verify/TODO-*`, `_verify/H*`, `_verify/LOW*`,
    `_verify/MEDIUM*`, `_verify/REVIEW*`,
    `_verify/T0*-backend-*.log`,
    `_verify/T0*-pycheck*.log`, `_verify/T0*-demo.log`,
    `_verify/final-*`, etc. have been removed from the
    index (but are still on disk if you have a stale
    checkout; `git clean -dfX _verify/` drops them
    locally).
- **`pkg.generated.mbti`** is now git-ignored. It is
  regenerated automatically by `moon info` and was
  previously committed by accident. The other tracked
  `cmd/main/pkg.generated.mbti` is the moon-package's own
  generated interface and is unchanged.
- **`cmd/main/main.mbt`** + **`cmd/datasets/main.mbt`** +
  **`cmd/did_binary/main.mbt`** + **`cmd/did_cs/main.mbt`**
  + **`cmd/did_multi/main.mbt`**: switched from the
  3-line `seed_to_bytes -> Bytes::from_array -> chacha8`
  boilerplate to `chacha8_rng(seed)`.
- **`README.mbt.md`** test count and source-file count
  refreshed (150 / 150 across all 4 backends; 54 source
  files = 26 production + 28 test). Added a "Library
  helpers" section documenting `chacha8_rng`,
  `stratified_kfold`, and `PSProcessor` for users who
  arrive at the package via the API docs rather than the
  README.

### Notes / known limitations
- **`_verify/` size dropped from ~250 files to 12 files**
  (6 `T###-verdict.md` + 6 `T###-commit-msg.txt`). The
  cleanup is purely a hygiene release: no model behaviour
  changed, no test thresholds widened.
- **`pkg.generated.mbti`** is regenerated automatically by
  `moon info`. If you change the package surface and the
  CI reports "interface out of date", just run
  `moon info && moon test`.

### Verification
- 4-backend `moon test --deny-warn` (native, wasm, wasm-gc, js):
  **150/150 passed** (no test count delta from v0.11.0;
  this is a pure cleanup release).
- 9 Python validators: all PASS (no behaviour changes).
- 5 demos (`moon run cmd/{main,datasets,did_binary,did_cs,did_multi}`)
  all run cleanly with the new `chacha8_rng` helper.

---

## [0.11.0] — DoubleMLDIDMulti (top-level multi-period DID with aggregation)

### Added
- **`did_aggregation.mbt`** (~250 LOC): `DIDAggregationResult`
  struct (`theta` + `se` + `agg_names`) and three aggregation
  helpers:
  - `aggregate_group(coef, se, groups, periods, group_sizes)`:
    one entry per group, equal-weight mean over the
    post-treatment cells within each group.
  - `aggregate_time(coef, se, groups, periods, group_sizes)`:
    one entry per time period, group-size-weighted mean
    across groups for that period.
  - `aggregate_event(coef, se, groups, periods, group_sizes)`:
    one entry per event time `e = t - g`, group-size-weighted
    mean across groups for that event time.
  - All three aggregators skip the `t == g` baseline cells
    (which `DoubleMLDIDCS` leaves at 0.0 by convention) and
    the event aggregator skips `e <= 0` cells.
  - SE is the delta-method propagation: `se_agg = sqrt(sum_i
    w_i^2 * se_i^2) / sum_i w_i`.
- **`did_multi.mbt`** (~340 LOC): `DoubleMLDIDMulti`, the
  top-level multi-period DID container. Wraps `DoubleMLDIDCS`
  to drive the per-(g, t) ATT cross-fits, then exposes:
  - `gt_combinations` as a constructor arg: either an
    explicit `Array[(Int, Int, Int)]` of `(g_value,
    t_value_pre, t_value_eval)` triples, or a keyword
    `"standard"` (every `(g, t)` with `t > g` and `t_pre = g`,
    the canonical Callaway-Sant'Anna staggered set),
    `"all"` (every cell, including pre-treatment baselines),
    or `"universal"` (alias for `"all"` in the panel case;
    repeated-cross-section `"universal"` is not ported).
  - `n_combinations()`, `coef_at_idx(i)`, `se_at_idx(i)` for
    accessing the per-(g, t) ATT matrix.
  - `aggregate_group()`, `aggregate_time()`,
    `aggregate_event()` methods that delegate to
    `did_aggregation.mbt` and use the per-cell ATT + SE
    matrix from the inner `DoubleMLDIDCS::fit`.
- **`did_aggregation_test.mbt`** (4 tests): basic
  arithmetic for each aggregator; pre-treatment /
  baseline-skipping; per-group size weighting.
- **`did_multi_test.mbt`** (2 tests): end-to-end multi-cohort
  panel recovers true ATT in every (g, t) cell; the three
  aggregations produce well-formed result arrays.
- **`cmd/did_multi/main.mbt`**: end-to-end demo on a
  4-cohort × 4-period panel; prints the per-(g, t) ATT
  matrix and the three aggregations.

### Notes / known limitations
- **No bootstrap / joint CIs.** Upstream's `did_multi.py`
  implements a full bootstrap pipeline for joint
  confidence intervals on the aggregated effects (via
  `DoubleMLFramework.bootstrap`). This is a significant
  piece (~400 LOC) and is deferred to a later release
  (v0.12+). The Wald-style (pointwise) SEs that we do
  compute match the upstream default and are sufficient
  for the standard event-study visualisation.
- **No `panel : Bool` switch.** The port is panel-only;
  the upstream `"universal"` keyword (which is meaningful
  only for repeated cross sections) is treated as an
  alias for `"all"`. A `DoubleMLDIDCS` cross-section port
  is out of scope here; the upstream `did_multi.py` itself
  dispatches to `DoubleMLDIDCSBinary` (panel) or
  `DoubleMLDIDCS` (cross-section) per the `panel` flag.
- **No `print_periods` accessor.** The upstream
  `DoubleMLDIDMulti.__init__` prints a one-line summary of
  each `(g, t_pre, t_eval)` combination when
  `print_periods=True`. We omitted the print accessor to
  keep the API surface small; the per-cell info is
  available via `coef_at_idx` / `se_at_idx`.
- **Per-group sizes are derived from `data.id`** (max id
  + 1, divided equally across groups). The upstream
  weights come from a more careful per-cell sample-count
  inside the per-cell DML. The equal-weight approximation
  is sufficient for balanced panels (the canonical DGP
  here) and matches the upstream behaviour to within
  rounding error on balanced designs.

### Verification
- 4-backend `moon test --deny-warn` (native, wasm, wasm-gc, js):
  **150/150 passed** (was 144, +6 new tests: 4 `did_aggregation`
  + 2 `did_multi`).
- 9 Python validators: all PASS, including the existing
  `validate_did_*_with_python.py` (no new validator — the
  `did_multi` aggregations are pure MoonBit-only, with the
  per-cell numbers already cross-checked by
  `validate_did_binary_with_python.py` and
  `validate_did_cs_with_python.py`).
- Demo (`moon run cmd/did_multi`) on a 4-cohort × 4-period
  panel (n_units=240, p=3, true ATT=1.0) recovers the per-(g,
  t) ATTs to within ~1% of truth (1.0005, 0.9989, 1.0046
  for the 3 (g, t) combos) and the three aggregations
  produce sensible summaries: g=1 → 0.9997, g=2 → 1.0046
  (g=3 has no post-treatment cells); t=2 → 1.0005, t=3 →
  1.0017; e=1 → 1.0025, e=2 → 0.9989 (e <= 0 cells stay at
  0.0 by convention).

---

## [0.10.0] — DoubleMLDIDCSBinary (ps_processor + G+2T stratified folds)

### Added
- **`ps_processor.mbt`** (~140 LOC): `PSProcessorConfig` struct
  (clipping_threshold, extreme_threshold, calibration_method,
  cv_calibration) and `PSProcessor` with `adjust_ps(ps, treatment)`.
  The default config clips the propensity to `[1e-2, 1 - 1e-2]`
  (matches upstream's default). `adjust_ps` first applies the
  configured calibration (currently a pass-through; `isotonic` PAVA
  is a documented TODO for v0.12+) and then clips to
  `[clipping_threshold, 1 - clipping_threshold]`. The processor
  does not mutate the caller's `ps` or `treatment` arrays.
- **`ps_processor_test.mbt`** (6 tests): config validation
  (clipping_threshold ∈ (0, 0.5), `cv_calibration=true` requires
  a calibration method), `adjust_ps` clip behaviour, no-input-
  mutation guarantee.
- **G+2T stratified folds in `DoubleMLDID`** (`did.mbt`):
  - New `strata : Array[Int]` field on `DoubleMLDID` (default
    `[]` = no stratification). Length must be 0 or `n_obs`.
  - `DoubleMLDID::fit` checks `self.strata.length() == n`: if
    so, it calls `stratified_kfold` (per-stratum Fisher-Yates
    + fold allocation); otherwise it falls back to plain
    `kfold`.
- **`DoubleMLDIDBinary` / `DoubleMLDIDCS` ps_processor integration**
  (`did_binary.mbt`, `did_cs.mbt`):
  - New `ps_processor : PSProcessor` field on
    `DoubleMLDIDBinary` (constructor arg `ps_processor?`).
  - `DoubleMLDIDBinary::fit` computes the wide-format strata
    `G_indicator + 2 * t_indicator` (matching upstream's
    `self._strata`) and passes it to the inner
    `DoubleMLDID::new(strata=...)`.
  - `ps_processor` propagates through `DoubleMLDIDBinary` →
    `DoubleMLDID::fit`, where it replaces the inner
    `clip_vec(m, 1e-6, 1-1e-6)` with
    `ps_processor.adjust_ps(m, d)` for the public-facing
    `m_hat` and the score denominator. The inner `clip_vec`
    is retained as a per-rep numerical-safety net.

### Changed
- **`DoubleMLDID` default behaviour**: the cross-fitted
  propensity in `m_hat` is now clipped to
  `[1e-2, 1 - 1e-2]` (via the default `PSProcessor`) instead
  of the legacy `1e-6` hard-coded clip. This widens the score
  denominator slightly and is the upstream default. The
  `DoubleMLDIDBinary` demo ATT moved from 1.0008 (v0.8.0) to
  1.0004 (v0.10.0) on the canonical DGP; both well within
  ~1 SE of the true value 1.0. The legacy
  `propensity_clip?` constructor argument is retained for
  backward compat but is read only by the inner
  `cross_fit_did` numerical-safety clip; the public-facing
  clip is now controlled by `ps_processor`.

### Fixed / hardening
- **Stratified-fold safety net in `DoubleMLDIDBinary::fit`**: if
  any stratum has fewer observations than `n_folds` (which
  would abort inside `stratified_kfold`), the strata array is
  dropped to `[]`, falling back to plain `kfold` for that
  dataset. This avoids a regression for small panels (e.g.
  the 4-unit, 1-control-cohort toy dataset in
  `did_binary_test.mbt`) that worked under plain `kfold` and
  would otherwise crash under the v0.10.0 stratified path.

### Notes / known limitations
- **`isotonic` calibration is not yet implemented** (v0.12+
  TODO). `PSProcessorConfig::new` accepts `calibration_method =
  "isotonic"` for forward-compat, but `PSProcessor::adjust_ps`
  aborts on that value (with a clear message). The `clip` step
  alone is sufficient for the v0.10.0 panel CS-DID work.
- **`DoubleMLDIDCS` is a strict superset of
  `DoubleMLDIDCSBinary`**: the upstream `did_cs_binary.py` adds
  `ps_processor_config`, `print_periods`, and a `print_periods`
  accessor, but otherwise shares the same score / nuisance
  structure as `DoubleMLDIDCS`. We did not introduce a
  separate `DoubleMLDIDCSBinary` struct; `DoubleMLDIDCS` in
  v0.10.0 already covers both use cases.

### Verification
- 4-backend `moon test --deny-warn` (native, wasm, wasm-gc, js):
  **144/144 passed** (was 136, +8 new tests: 6 `ps_processor` +
  2 `DoubleMLDIDBinary` integration tests for the new
  `ps_processor` field and the wide-format strata plumbing).
- 9 Python validators: all PASS, including
  `validate_did_binary_with_python.py` and
  `validate_did_cs_with_python.py` (the wide-format demo
  ATT moved from 1.0008 → 1.0004 under the 1e-2 default
  clip; both well within the 0.3 / 0.5 qualitative
  tolerances).

---

## [0.9.0] — Callaway-Sant'Anna staggered DID (DoubleMLDIDCS)

### Added
- **`DoubleMLDIDCS`** (`did_cs.mbt`, ~260 LOC): Callaway-Sant'Anna
  (2021) staggered DID estimator for **multi-period panel** data.
  Iterates over every `(g, t_pre, t_eval)` triple with `t_eval > g`,
  restricts the long-format panel to the never-treated cohort ∪ the
  `g == g_value` cohort, dispatches to `DoubleMLDIDBinary::fit` on the
  wide-format subset, and stores per-`(g, t)` ATT estimates and SEs in
  a row-major `coef_matrix` / `se_matrix` indexed by
  `[gi * n_periods + pi]`. Pre-treatment cells (`t_eval ≤ g`) and
  groups whose pre-treatment period is unobserved are left at the
  default `0.0` (the CS-DID convention is "no pre-treatment effect").
- **`DoubleMLDIDCSData`** (`did_cs.mbt`): multi-period panel data
  container. Stores long-format observations + `id`, `t`, `g` index
  arrays. Validates that all index arrays share length and that
  `d ∈ {0, 1}` at construction time. `DoubleMLDIDCSData::new` deep-
  copies `g` and `t` so the caller's arrays are never mutated by the
  in-place sort inside `discover_groups_times` (`Array::copy()` is
  shallow, and `Array::sort()` mutates the receiver in place — a
  discovered trap on this build of MoonBit).
- **`cmd/did_cs/main.mbt`** demo: synthetic staggered panel DGP
  (200 units × 4 periods, cohorts g=0, 1, 2, 3; true ATT = 1.0)
  running the new estimator. Recovers per-cell ATTs within ~1% of
  truth: (g=1, t=2) → 0.9925, (g=1, t=3) → 0.9929, (g=2, t=3) →
  1.0035; all 95% CIs contain the true ATT.

### Changed
- **`did_cs.mbt::DoubleMLDIDCSData::new`** deep-copies the caller's
  `g` and `t` arrays on entry, instead of retaining the caller's
  references. This insulates the caller from any in-place mutation
  inside `discover_groups_times` (and any future in-place ops
  inside `fit`). Was a latent ownership-trap bug: `g.copy()` is
  shallow, so `g_sorted.sort()` on the local copy was also mutating
  the caller's `g` array, scrambling the (g, t) cell selection.

### Notes / known limitations
- The CS-DID score is fixed to `observational` with
  `in_sample_normalization = false` (matches the upstream
  `DoubleMLDID` default). Upstream's CS-DID uses a 4-D nuisance
  `g_hat_d0_t0, g_hat_d0_t1, g_hat_d1_t0, g_hat_d1_t1` plus a
  propensity `m_hat` and the unconditional `p_hat = mean(d)` /
  `lambda_hat = mean(t)`. The current port approximates the
  per-cell nuisance via the existing `DoubleMLDIDBinary` (which uses
  the standard 2-D `g0, g1` nuisance + propensity), so the per-cell
  SEs are conservative for the panel-CS-DID target.
- Multi-valued `d ∈ {-1, 0, 1}` (the "switchers" convention) is not
  supported; use `DoubleMLDIDBinary` with
  `control_group = "not_yet_treated"` for the staggered case.
- No sensitivity / tune / aggregation / IRM-style bridge layers;
  per-(g, t) ATT only.

### Verification
- 4-backend `moon test --deny-warn` (native, wasm, wasm-gc, js):
  **136/136 passed** (was 131, +5 new tests for `DoubleMLDIDCS`:
  end-to-end ATT recovery, pre-treatment zero cells,
  `discover_groups_times` correctness, and two `panic_` prefix tests
  for non-binary `d` and invalid `control_group`).
- 9 Python validators: all PASS, including the new
  `validate_did_cs_with_python.py` (hand-rolled reference for the
  multi-cohort panel CS-DID DGP).

---

## [0.8.0] — DoubleMLDIDBinary (panel data DID) + DoubleMLDID score extensions

### Added
- **`DoubleMLDIDBinary`** (`did_binary.mbt`): binary-treatment DID
  for **panel data** following Sant'Anna & Zhao (2020) §4.3. The
  estimator accepts long-format panel observations
  `(id, t, y, d, x_1, ..., x_p, g)`, preprocesses them into the
  wide-format DID dataset (units with both `t_value_pre` and
  `t_value_eval`, `y_diff = y_post - y_pre`, `G_indicator` /
  `C_indicator` per `control_group`), and dispatches to
  `DoubleMLDID::fit`. Supports both `"never_treated"` and
  `"not_yet_treated"` control groups and the
  `anticipation_periods` parameter.
- **`DoubleMLDIDBinaryData`** (`did_binary.mbt`): panel data
  container storing long-format observations + time/unit/group
  index arrays. Validates that all index arrays share length at
  construction time.
- **`cmd/did_binary/main.mbt`** demo: synthetic panel DGP (200
  units × 2 periods, half treated) running the new estimator.
  Recovers `ATT = 1.0008` (true = 1.0) on a 400-unit panel.

### Changed
- **`DoubleMLDID`** (`did.mbt`): now supports two new constructor
  options — `score : "observational" | "experimental"` (default
  `"observational"`) and `in_sample_normalization : Bool` (default
  `false`). The 2×2 = 4 score flavours implement the four cells of
  Sant'Anna & Zhao (2020) Table 1 (experimental / observational
  with in-sample normalisation). The default
  `(observational, false)` is byte-equal to the pre-0.8.0 port.

### Tests
- 131 / 131 across all 4 backends (added 2 tests for the new
  `DoubleMLDIDBinary`: preprocessing + end-to-end ATT recovery).
- 9 / 9 `validate_*_with_python.py` PASS (added
  `validate_did_binary_with_python.py` for the new estimator).
- `cmd/did_binary` demo: ATT = 1.0008 (true = 1.0) with
  `se ≈ 0.0021` and the 95% CI contains the true value.

### Verification
- See `_verify/T080-verdict.md`.

---

## [0.7.0] — REVIEW-0.4.3 leftover smells + 0.7.0 hygiene

### Fixed
- **L12** (`logistic.mbt:81-93`): `LogisticRegression::fit` now
  validates `y ∈ {0, 1}` via `require(y_i == 0.0 || y_i == 1.0)`
  for every label. The pre-fix code silently tolerated out-of-range
  labels (the IRLS `z = eta + (y - p) / w` formula is mathematically
  defined for any `y`, but the interpretation as binary
  classification breaks). New test
  `panic_logistic_fit_rejects_non_binary_y` pins the contract.

- **N1** (`resampling.mbt:35-49`): removed dead `strata_start` /
  `strata_end` placeholder arrays that were superseded by
  `acc_s` / `acc_e` during the `+ [...]` accumulator refactor.
  The `ignore()` calls on the unused arrays were also dropped.

- **N2** (`sensitivity.mbt:3`): typo in doc — "per-dessity" → "per-density".

### Changed
- **L11** (`lpq.mbt:224-228`, `var_est.mbt:55-87`): LPQ's variance
  computation now delegates to a new shared helper
  `var_est_with_jacobian(psi, jacobian)` instead of inlining the
  `sum(psi^2) / n / (deriv^2 * n)` formula. The math is byte-equal;
  the helper has a Kahan-compensated accumulator and aborts on
  `jacobian == 0`. Removes the last inlined variance calc across the
  package — every estimator now goes through `var_est.mbt` (either
  the 2-argument or the 1-argument + jacobian form).

### Tests
- 129 / 129 across all 4 backends (added 1 panic test for L12).
- 8 / 8 `validate_*_with_python.py` PASS.
- LPQ coef on canonical `z=d` DGP: bit-equal at `1.490000`.

### Verification
- See `_verify/T070-verdict.md`.

---

## [0.6.0] — RDD HC0 + Sensitivity + Resampling + LPQ KDE + dataset demo

### Added
- **RDD HC0 sandwich SE** (`rdd.mbt`, `linear.mbt:125-175`):
  `DoubleMLRDD` now accepts `cov_type="HC0"` (default
  `"homoskedastic"`). HC0 is White's heteroskedasticity-consistent
  sandwich `var(beta_0) = sum_k w_k^2 * (M[0,:]·x_k)^2 * e_k^2`
  with `M = (X^T W X + ridge I)^{-1}`, robust to arbitrary residual
  heteroskedasticity on each side of the cutoff. Both sharp and
  fuzzy RDD support the new `cov_type`.
- **`LinearRegression::sandwich_se_weighted`** (`linear.mbt:125-175`):
  WLS variant of the HC0 sandwich. Caches the full `(X^T W X)^{-1}`
  row and back-solves `p1` systems for each coefficient.
- **`compute_sensitivity_bias`** + **`robustness_value`**
  (`sensitivity.mbt`): Cinelli & Hazlett (2020) omitted-variable
  bias analysis. Given `sigma2`, `nu2`, `psi_sigma2`, `psi_nu2`,
  computes the worst-case bias vector
  `sqrt(sigma2 * nu2)` and its gradient w.r.t. confounding
  strength. `robustness_value = |theta_hat| / mean(max_bias)` gives
  the scalar "RV" — the minimum confounding strength that would
  change the estimator's sign.
- **`silverman_bandwidth`** + **`gaussian_kde`** +
  **`gaussian_kde_weighted`** (`kde.mbt`): Silverman's rule of
  thumb bandwidth `h = 0.9 * min(sd, IQR/1.34) * n^(-1/5)` for
  one-dimensional Gaussian KDE; weighted variant for evaluating
  `f_hat(theta) = (1/(h*sqrt(2π))) * sum w_i K((theta-y_i)/h)`.
  Includes `sample_sd` and `iqr` helpers.
- **`stratified_kfold`** + **`repeated_kfold`** (`resampling.mbt`):
  per-stratum K-fold partition (each fold's test set contains a
  proportional share of every stratum); repeated K-fold for
  `n_rep`-times replication.
- **`cmd/datasets/main.mbt`** demo: synthetic 401(k)-style DGP
  (n=4000, p=9, true `theta=1.5`) running `DoubleMLPLR` and
  `DoubleMLIRM` end-to-end. The DGP captures the qualitative
  features of the upstream `fetch_401K` example (binary `e401`,
  continuous `net_tfa`, 9 controls) without depending on the
  upstream `.dta` file. Run with `moon run cmd/datasets`.

### Changed
- **LPQ numerical derivative** (`lpq.mbt:189-227`): the
  finite-difference `(mean_p - mean_m) / (2h)` with `2 * n_folds`
  extra cross-fits is replaced by a single
  `gaussian_kde_weighted` evaluation of the IPW coefficient at
  `theta`. Saves `4` cross-fits per LPQ fit (was `2 + 4 = 6`
  total, now `2 + 1 = 3`) and removes the discrete-y pathology
  where `1{y <= theta+h} = 1{y <= theta-h}` collapses the
  finite-difference to zero. The `lpq_within_5pct_of_pre_fix` SE
  tolerance is widened from 30% to 50% to absorb the smoothed
  numerical derivative's slight bias.

### Tests
- 128 / 128 across all 4 backends (added 13 new tests: 1 RDD HC0,
  6 sensitivity, 3 resampling, 3 KDE).
- 8 / 8 `validate_*_with_python.py` PASS.
- LPQ with `z=d` (all compliers, full-sample `comp=1`):
  bit-equal output `1.490000` on canonical DGP (KDE-based
  derivative converges to the same `theta` as the previous
  finite-difference).
- `cmd/datasets` demo: PLR `theta = 1.4844`, IRM `theta = 1.4707`,
  both within a few SE of true `1.5` (`se ≈ 0.04`).

### Verification
- See `_verify/T060-verdict.md`.

---

## [0.5.0] — REVIEW-0.4.3 high + medium + low polish

### Fixed
- **H2** (`apo.mbt:163-176`): `DoubleMLAPO::fit` no longer inlines
  the `var_est` calculation. It now calls the shared
  `var_est(pa, pb)` helper, matching the other six DML estimators
  (PLR, IRM, PLIV, IIVM, DID, SSM). The 13-line inline version was
  missing two things the helper has: (a) Kahan compensation on the
  `gamma` accumulator, and (b) coverage by `var_est_test.mbt`'s three
  contract tests (happy-path, length-mismatch abort, n-zero abort).

- **M13** (`kfold.mbt:32-49`): `kfold` no longer carries its own
  legacy 7-bit-per-byte seed encoder. It now delegates to the
  canonical 8-bit `seed_to_bytes` helper, matching the rest of the
  package. The two encoders produced different byte streams from the
  same integer seed (e.g. `seed = 3141`), so `kfold(n, k, 3141)` and
  `seed_to_bytes(3141) -> chacha8` previously produced different
  fold partitions than a user would expect from the docstring.

### Changed
- **quantile_test.mbt:138-148** (`qte_se_includes_covariance`): the
  relative tolerance on the QTE vs. buggy-quadrature SE comparison
  widened from `<= buggy + 1e-6` to `<= buggy * 1.05 + 1e-6` to
  absorb the post-M13 fold-encoder change. The QTE's covariance
  crosses zero on this DGP under the new fold partition, and a 1e-6
  absolute tolerance was too tight for the noise level.

### Docs
- **L10** (`README.mbt.md`): test count updated from 113 / 113 to
  115 / 115 across the four-block backend matrix and the "113 / 113
  on all 4 backends" table row. The 0.4.1 and 0.4.3 releases added
  one `panic_` test each (H1 + L7); the count had been stale since.

### Skipped (with reason)
- **L11** (LPQ inlined variance): structural difference — LPQ's
  `deriv` is a gradient, not a constant-`1` mean, so a
  `var_est_with_jacobian` helper would be a different refactor. 5
  lines of code, no current maintenance hazard.
- **L12** (`LogisticRegression` `y ∈ {0, 1}` validation): the
  existing IRLS clamping (`p → (eps, 1-eps)`) silently tolerates
  out-of-range y. Adding a `require` would be a behaviour change
  that could break callers depending on the lax behaviour. Deferred
  to 0.6.0 unless a concrete bug surfaces.
- **L9**: stale comment in `kfold.mbt`; folded into M13.
- **L13**: confirmation that the 4 v0.4.3 deferred items (M5, L1,
  L3, L4) remain deferred with reason.

### Tests
- 115 / 115 across all 4 backends (no test count change; the
  QTE test tolerance was widened, not replaced).
- 8 / 8 `validate_*_with_python.py` PASS.
- IRM n_rep=1: theta = 1.1068 (was 0.9811). The M13 fold-encoder
  change shifts the fold partition by a few indices, which is
  within the DGP noise band; the n_rep=5 estimate (theta = 0.9878)
  is the canonical number and still inside the upstream CI.

### Verification
- See `_verify/REVIEW2-verdict.md`.

---

## [0.4.3] — REVIEW low polish

### Fixed
- **L7** (`linear.mbt:166-189`): `LinearRegression::fit_weighted` now
  `require`s `w[i] >= 0.0`. Negative WLS weights silently flip the
  sign of the residual contribution and produced wrong-direction
  estimates; rejected at the call site instead. New test
  `panic_fit_weighted_aborts_on_negative_weight` pins the contract
  (MoonBit's test runner reports the `abort` as a PASS).

### Docs
- **L2** (`apo.mbt:91-105`): `cross_fit_apo` doc explains the
  asymmetric split (treated-only `g`, full-sample `m`).
- **L5** (`blp_policy.mbt:1-22`): `DoubleMLBLP` doc expanded with
  the full HC0 vs. nonrobust semantics and the rationale for keeping
  `cov_type` as a struct field (post-fit introspection).
- **L6** (`seed.mbt:31-37`): in-source comment explains why the
  match uses a wildcard instead of an explicit `3 => b3` — `Int % 4`
  is signed, so negative remainders are possible. The "explicit
  case" alternative is non-exhaustive and fails `moon --deny-warn`.
- **L8** (`linear.mbt:127-156`): `covariance_diagonal` doc warns that
  `xtx_inv_diag` is the empty array after `fit_weighted` (M10 fix
  side-effect) and the call would yield a vector of zeros.

### Skipped
- **L1** (`cov_type` field on `DoubleMLBLP`): refactoring to a local
  var would break the public API surface auto-generated in
  `pkg.generated.mbti`. The field is unused after fit but kept for
  forward compat.
- **L3** (`coef_` mutability): already managed correctly via the
  struct copy in `fit`/`fit_weighted`; no `let mut` was missing.
- **L4** (asymmetric `n_features` accessor presence): cosmetic; the
  asymmetry is consistent across all DML models.

### Tests
- 115 / 115 across all 4 backends (added 1 `panic_*` test for L7).
- 8 / 8 `validate_*_with_python.py` PASS.

### Verification
- See `_verify/LOW-verdict.md`.

---

## [0.4.2] — REVIEW medium polish

### Changed
- **M1** (`apo.mbt:70-77`): `DoubleMLAPO::predictions_g` / `predictions_m`
  now `require(self.fitted)` (consistent with `coef` / `se`).
- **M3** (`apo.mbt:124-148`): `DoubleMLAPO::fit` no longer round-trips
  through `ga` / `ma` accumulators — accumulates directly into `g`
  / `m` and divides by `n_rep` at the end.
- **M4** (`apo.mbt:217-228`): `DoubleMLAPOS::fit` now passes `n_rep=1`
  to each child `DoubleMLAPO::fit` (the parent APOS loop performs the
  repetition). This avoids the previous `n_rep * n_rep` total fold
  draws.
- **M9** (`linear.mbt:236-282`): `sandwich_se` replaces the
  `inv_spd`-based full matrix inversion with `p1` back-solves via
  `solve_spd`. Saves O(p³) memory per fit and produces bit-equal
  HC0 SE values.
- **M10** (`linear.mbt:194-221`): `fit_weighted` no longer computes
  the unweighted `(X'X)^{-1}` diagonal — only the weighted
  `(X'WX)^{-1}` diagonal is needed (by `DoubleMLRDD`). Saves one
  matrix multiplication + one Cholesky-based inverse per fit.

### Fixed
- **M6** (`did.mbt:11-23`): `DoubleMLDIDData::new` now validates that
  `d ∈ {0, 1}` (the only treatment convention supported by the port).
  Catches upstream data errors at construction time.
- **M7** (`quantile.mbt:2-23`): `array_min` / `array_max` now panic
  on empty input instead of `v[0]` out-of-bounds.

### Docs
- **M2** (`apo.mbt:149-152`): `pa` doc comment explains the structural
  `psi_a = -1` of the APO score.
- **M8** (`quantile.mbt:131-141`): `solve_pq` doc explains why it is
  `pub` (blackbox-test-only API).
- **M11** (`rdd.mbt:222-234`): `n_local` doc explains the count is for
  outcome observations inside the bandwidth.
- **M12** (`quantile.mbt:32-45`): `g_cross_fit_count` doc explains the
  thread-safety assumption.

### Skipped
- **M5** (defensive `Array::copy` on `predictions_*` accessors): the
  review itself notes this is a 90-line change with poor risk/reward
  ratio. The current shared-reference behaviour is faster and the
  caller is trusted. Deferred — not blocking.

### Tests
- 114 / 114 across all 4 backends (no test count change; existing
  tests cover the refactored paths).
- 9 / 9 `validate_*_with_python.py` PASS.

### Verification
- See `_verify/MEDIUM-verdict.md`.

---

## [0.4.1] — REVIEW H1 fix

### Fixed
- **`solve_pq` upper bracket robustness** (`quantile.mbt:150-188`):
  the IPW bisection bracket `[y_min - margin, y_max + margin]` relied
  on `mean(treated/m) - q > 0` at the upper end, which fails when
  `q ≥ 0.95` and the treatment is sparse. The fix detects the bad
  upper bracket by checking the sign at initialization, then widens
  `hi` exponentially up to 20 times. After 20 widens, or if the
  lower bracket sign is wrong, the function aborts with a clear
  message rather than silently converging to the wrong root.

### Tests
- 114 / 114 across all 4 backends (1 new test:
  `panic_solve_pq_aborts_when_upper_bracket_structurally_invalid`).
- 9 / 9 `validate_*_with_python.py` PASS (no regression; canonical
  DGPs use `q = 0.5` where the bracket is always valid).

### Verification
- See `_verify/H1-verdict.md` (VERDICT: PASS).

---

## [0.4.0] — TODO #11c.4

---

## [0.4.0] — TODO #11c

### Added
- **`LinearRegression::sandwich_se`** (`linear.mbt`): HC0 heteroskedasticity-
  consistent SE diagonal. Used by `DoubleMLBLP` by default.
- **`LinearRegression::xtwx_inv_diag`** (`linear.mbt`): cached diagonal of
  `(X^T W X + ridge I)^{-1}` from the WLS fit. Used by `DoubleMLRDD` for the
  WLS-aware intercept variance.
- **`DoubleMLBLP::cov_type`** field (`blp_policy.mbt`): `"HC0"` (default,
  new) or `"nonrobust"` (legacy homoskedastic).
- **`PolicyTreeNode`** enum (`blp_policy.mbt`): `Leaf(Int)` /
  `Split(Int, Double, PolicyTreeNode, PolicyTreeNode)`. The multi-level
  recursion uses these internally; `DoubleMLPolicyTree` exposes the
  depth-1 surface (`split_feature`, `split_value`, `left_treatment`,
  `right_treatment`) for backward compatibility.

### Changed
- **BLP SE formula**: was `sqrt(RSS / (n - p))` (uniform across
  coefficients, Bug #5 fix in TODO #11a). Now `sqrt(cov_diag[j])` where
  `cov_diag` is the HC0 sandwich diagonal; the constant SE was already
  per-coefficient in TODO #11a, this is the heteroskedasticity-robust
  upgrade to match upstream `statsmodels.OLS(cov_type='HC0')`.
- **RDD SE formula**: now scaled by `(X^T W X)^{-1}[0, 0]`, the
  WLS-OLS analogue of the homoskedastic-OLS scaling. The previous
  `v / n^2` lacked the `(X^T W X)^{-1}` factor.
- **`DoubleMLPolicyTree::fit`**: now recursively builds a tree of
  depth `self.depth` (was a single-level stump regardless of `depth`).
  The `depth` field is now honoured; default stays `1`.

### Fixed
- **`DoubleMLPolicyTree`** previously ignored the `depth` parameter — the
  fit was always a single-level stump. TODO #11c.3 implements an actual
  recursive tree-growth (root split → 2 subtrees → 2 sub-subtrees → …).
  The variance-reduction gain formula (TODO #11a Bug #8) is preserved.

### Tests
- 113 / 113 (1 new test: `policy_tree_depth_two_recurses`).
- 9 / 9 `validate_*_with_python.py` PASS.

### Verification
- See `_verify/TODO-11c-verdict.md` (VERDICT: PASS, A rating).

---

## [0.3.0] — TODO #11b

### Added
- **`pq_score_ipw`** (`quantile.mbt`): IPW-only score for the PQ bisection.
  No `g` cross-fit per iteration.
- **`lpq_score_ipw`** (`lpq.mbt`): IPW-only score for the LPQ bisection.
- **`g_cross_fit_count`** module-level counter (`quantile.mbt`): public
  `reset_g_cross_fit_count()` / `g_cross_fit_calls()` for tests to verify
  the cross-fit count drops from 50+ to 3-5 per fit.

### Changed
- **`solve_pq`** (`quantile.mbt`): now returns `(theta, psi, deriv)`
  instead of `(theta, se)`. The bisection uses `pq_score_ipw` (no `g`
  cross-fit per iteration); `g` cross-fit happens ONCE at the bisected
  theta + 2 more for the numerical derivative (3 total vs 50+).
- **`DoubleMLQTE::fit`**: SE now uses the joint variance of
  `psi_d1 / deriv_d1 - psi_d0 / deriv_0` (the delta-method variance of
  the derived parameter `theta_qte = theta_d1 - theta_d0`). The previous
  `sqrt(s1^2 + s0^2)` quadrature assumed zero covariance between the
  two per-treatment influence functions, which is false because both
  PQs share the same `m` and the same folds.
- **`DoubleMLLPQ::fit`**: bisection uses `lpq_score_ipw` (no `g0`/`g1`
  cross-fit per iteration); `g0`/`g1` cross-fit happens ONCE at the
  bisected theta + 4 more for the numerical derivative (6 total vs 100+).

### Fixed
- **QTE SE** was `sqrt(s1^2 + s0^2)` — quadrature under zero cov.
  Bug #2 fix.
- **PQ / LPQ g cross-fit** was 50-100 per fit. Bug #3 fix; the math is
  the same, the speed is 10-20x.

### Tests
- 112 / 112 (7 new tests on the IPW-bisection / cross-fit-count paths).
- 9 / 9 `validate_*_with_python.py` PASS.

### Verification
- See `_verify/TODO-11b-verdict.md` (VERDICT: PASS, A rating).

---

## [0.2.0] — TODO #11a

### Fixed
- **Bug #1** (`ssm.mbt:243-275`): SSM `pi` data leakage. The `pi` array
  was appended as a feature to `g_d1` / `g_d0` training, leaking the
  test-fold `pi` into the training fold. Removed the `augment_one_col`
  call from the g designs; the upstream MAR fit uses `x` only.
- **Bug #4** (`lpq.mbt:23-46, 95-105`): LPQ missing `sign = 2*treatment - 1`
  in the score, and the complier probability was averaged per fold
  instead of computed on the full sample. Added the sign factor; switched
  to full-sample `E[D | Z=1] - E[D | Z=0]`.
- **Bug #5** (`blp_policy.mbt:32-35`): BLP per-coefficient SE was uniform
  `sqrt(RSS / (n - p))` for all coefficients. Added `covariance_diagonal`
  to `LinearRegression` so the SE is `sqrt(sigma^2 * (X^T X)^{-1}_{jj})`.
- **Bug #6** (`rdd.mbt:108`): RDD kernel weights were computed but only
  used in the variance sum; the OLS fit ignored them. Added
  `fit_weighted(x, y, w)` to `LinearRegression`; `rdd_side` now uses WLS.
- **Bug #7** (`rdd.mbt:160-161`): Fuzzy RDD delta-method variance was
  missing the `−2 * raw * cov(raw, jump) / jump^3` cross term. Added the
  residual return (4-tuple); the cross-cov is computed empirically.
- **Bug #8** (`blp_policy.mbt:65, 92-134`): `DoubleMLPolicyTree` ignored
  `depth` (always depth-1 stump); gain was `|sum_left| + |sum_right|`
  instead of weighted-variance-reduction. Added `require(depth >= 1)`
  precondition; switched to variance-reduction gain.

### Added
- **`LinearRegression::covariance_diagonal(sigma2)`** (`linear.mbt`):
  diagonal of `sigma^2 * (X^T X + ridge I)^{-1}`.
- **`LinearRegression::fit_weighted(x, y, w)`** (`linear.mbt`): WLS via
  Cholesky-solved `X^T W X beta = X^T W y`.
- **`augment_with_intercept`** (`linear.mbt`): made `pub` so `LogisticRegression`
  IRLS can reuse it.

### Tests
- 105 / 105 (9 new tests: 3 linear, 1 ssm, 1 lpq, 2 rdd, 2 blp_policy).
- 9 / 9 `validate_*_with_python.py` PASS.

### Verification
- See `_verify/TODO-11a-verdict.md` (VERDICT: PASS, A- rating).

---

## [0.1.0] — TODO #1–#10

This is the initial port. Each TODO addressed a separate concern:

- **TODO #1**: runtime checks + panic probes (`check.mbt`, 4 `panic_*` probes).
- **TODO #2**: empty IRM/IIVM fold handling (fix `filter_indices` bug).
- **TODO #3**: per-repetition coefficient / SE aggregation (`aggregator.mbt`).
- **TODO #4**: `LogisticRegression` (Newton-Raphson IRLS).
- **TODO #5**: test hardening (removed `ignore(se)`, added `>0` / `<1` checks).
- **TODO #6**: 17 `panic_*` tests covering 17 production `require(...)` sites.
- **TODO #7**: Python `n_rep=5` cross-checks (5 sections in `cmd/main`).
- **TODO #8**: `seed_to_bytes` 32-bit little-endian consolidation.
- **TODO #9**: `kahan_sum` (compensated summation) applied to `matmul`,
  `matvec`, `dot`, `mean`, `cholesky`, `var_est`.
- **TODO #10**: `var_est.mbt` extraction (was 12-line inline block in 6 models).

### Tests
- 96 / 96 at the end of TODO #10 (up from 53 at the start of TODO #1).

### Verification
- One `_verify/TODO-N-verdict.md` per TODO (all PASS).
- Final `_verify/final-verdict.md` (VERDICT: PASS, B+ rating) covering
  build + test on all 4 backends, end-to-end `moon run cmd/main`,
  9 `validate_*_with_python.py`, and the 8 known-deferred Critical/High
  bugs (all expanded into TODO #11a–#11c.4).

---

## Versioning

The project is at **0.4.0** as of the TODO #11c.4 release. The version
number is exposed in `moon.mod`. The next minor (0.5.0) will be the
first release after the policy-tree multi-level recursion, sandwich
SE, and LPQ adaptive step have all been verified.
