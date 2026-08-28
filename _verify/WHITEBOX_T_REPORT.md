# White-Box Test Report (v0.34.0)

**Date**: 2026-08-28
**Method**: Mutation testing — mutate production code, observe whether
existing test suite catches the regression.

## Mutation sweep on cluster-DML stack (v0.34.0)

Targets: `plpr.mbt::est_coef_cluster`, `plpr.mbt::var_est_cluster`.
These are the J-floor defensive guard + cluster coefficient / SE
formulas that v0.34.0 just hardened. The other cluster helpers
(`kfold.mbt::expand_unit_folds_to_rows`, `kfold.mbt::build_row_unit_map`)
are already exercised through the cluster PLR/IRM/PLIV/IIVM fuzz surfaces
and validator.

Orchestrator: `_verify/_whitebox_mut.py` (PowerShell-safe: direct
subprocess, not PowerShell pipeline which eats `moon` exit codes).

### Results

| ID  | Mutation                                              | Outcome   | Expected  |
|-----|--------------------------------------------------------|-----------|-----------|
| M01 | drop per-fold weight `w` in gamma accumulator          | KILLED    | KILLED ✓  |
| M02 | drop per-fold weight `w` in j_hat accumulator          | KILLED    | KILLED ✓  |
| M03 | relax `|J|<1e-6` abort floor to `|J|<1e-2`             | SURVIVED  | SURVIVED ✓|
| M04 | remove J-floor abort entirely (`if false`)             | SURVIVED  | SURVIVED ✓|
| M05 | divide by `j` once instead of `j*j` (off-by-one)       | KILLED    | KILLED ✓  |
| M06 | ignore `n_folds_per_cluster` (`npc=1`)                 | KILLED    | KILLED ✓  |
| M07 | drop per-fold weight `w` in `est_coef_cluster`         | KILLED    | KILLED ✓  |
| M08 | sign-flip cluster coefficient (`-sb / sa` → `sb / sa`) | KILLED    | KILLED ✓  |

**6 of 8 mutations were caught** by existing tests. The cluster-DML
stack is well-tested: `var_est_cluster` (numerator/denominator
weighting, n_folds_per_cluster scaling, j-floor, off-by-one in
denominator) and `est_coef_cluster` (fold weighting, sign) all have
tests that catch the obvious regressions.

### M03 / M04 (survived)

These target the v0.34.0 J-floor defensive guard:

```moonbit
if j.abs() < 1.0e-6 {
  abort("var_est_cluster: |J|=... < 1e-6; ...")
}
```

M03 (relax floor to 1e-2): no test currently lands on a J value in
[1e-6, 1e-2), so the relaxed floor is functionally indistinguishable
from the strict floor on the existing test corpus. Survived is
expected.

M04 (remove floor entirely): no test triggers the floor at all,
because the existing test fixtures don't construct fold splits where
`mean(psi_deriv) = 0`. Survived is expected.

**To make M04 catchable**, the J-floor would need a positive
regression test. I attempted to add one, which surfaced a much
bigger structural problem in this MoonBit version — see below.

## Meta-finding: panic_* tests are silently skipped on native / wasm-gc

While adding a regression test for M04, I discovered that all 64
`panic_*`-prefixed tests in this project do not actually run.

### Evidence

`__generated_driver_for_blackbox_test.mbt:823-828` (auto-generated,
identical on native/wasm-gc; `IS_NATIVE=true` there):

```moonbit
if MOONBIT_TEST_DRIVER_INTERNAL_IS_NATIVE {
  for attr in attrs {
    if attr is [.. "panic", ..] {
      raise MoonBitTestDriverInternalSkipTest(name~)
    }
  }
}
```

On **native / wasm-gc**, when the test name has a `panic` attribute,
the driver raises `SkipTest` BEFORE running the test body. The test
never executes. The runner counts it as "passed" because the skip
path is treated as success.

### Probe

`_verify/_probe_panic.py` bypasses the `require(approach in {...})`
in `DoubleMLPLPR::new` (so the constructor no longer aborts on
invalid input). I then ran the existing `panic_plpr_bad_approach`
test:

- **Without bypass** (correct: abort fires, process dies): reported
  PASS.
- **With bypass** (regression: no abort fires): reported PASS.

Both pass — the test never runs.

Same pattern on JS / wasm backend: the driver has
`MOONBIT_TEST_DRIVER_INTERNAL_IS_NATIVE = false`, so the skip block
does NOT run. But the panic_* tests on those backends are still
silent for a different reason: they contain only `let _ = func(...)`
calls, no assertions. If the function doesn't abort, the test
returns Unit successfully and is counted as PASS.

### Impact

| Test file                            | panic_* count |
|--------------------------------------|---------------|
| check_test.mbt                       | 21            |
| sensitivity_test.mbt                 | 9             |
| did_multi_test.mbt                   | 5             |
| irm_iivm_empty_fold_test.mbt         | 4             |
| plpr_test.mbt                        | 4             |
| did_cross_section_test.mbt           | 3             |
| logistic_test.mbt                    | 3             |
| ps_processor_test.mbt                | 3             |
| did_cs_test.mbt                      | 2             |
| lplr_test.mbt                        | 2             |
| var_est_test.mbt                     | 2             |
| aggregator_test.mbt                  | 1             |
| blp_policy_test.mbt                  | 1             |
| kahan_test.mbt                       | 1             |
| kfold_test.mbt                       | 1             |
| linear_test.mbt                      | 1             |
| quantile_test.mbt                    | 1             |
| **Total**                            | **64**        |

64 of 283 tests = **22.6%** of the test suite is silent. The test
count of 283 is misleading — only **219 tests actually execute**.

### Recommended fix

Two paths:

1. **Upstream MoonBit fix**: the `panic_` prefix skip is documented
   as "test only passes if panic triggers". The current behavior
   (skip on native, run-once-and-assert-nothing on JS) does not
   match the docs.

2. **API change in this repo**: replace `abort("...")` calls with
   `raise MyError("...")` and have the function return `T!Error`.
   Then tests can `try? func_call()` and inspect the error. This
   makes the panic path actually testable across all backends.

The J-floor regression test (M04 catchable) is a small motivation
for (2): a `Double!Error` return on `var_est_cluster` would let us
write `let result = try? var_est_cluster(...); inspect(result is Err,
content="true")` — which works on every backend and would catch the
abortion bypass.

## Conclusion

- **Cluster-DML stack test coverage is strong** (6/8 mutations
  killed by existing tests). The recent v0.28.0–v0.34.0 work added
  genuine regression coverage for cluster inference.
- **J-floor defensive guard is unreachable by the current test
  framework** (M04 survived). This is acceptable: the validator's
  30-seed empirical study already confirms the J-floor fires on
  ~3% of random DGPs in practice (v0.32.0 empirical data). The
  guard is exercised by fuzz + validator, just not by unit tests.
- **22.6% of the test suite is silently skipped** (panic_* tests).
  This is the most important finding of this white-box pass. It
  affects the validity of the 283-test count metric. Future release
  notes should either (a) reclassify panic_* tests as "smoke
  filters, not assertions" or (b) commit to the API change in
  (2) above.

## Artifacts

- `_verify/_whitebox_mut.py` — mutation orchestrator
- `_verify/whitebox_mut_results.json` — sweep results
- `_verify/_probe_panic.py` — panic_* skip probe (artifact only)
- `_verify/_soften_validator.py.archived` — leftover from previous
  mutation rounds (do not delete; pre-existing)

## Suggested follow-ups (out of scope for this report)

- Convert `var_est_cluster` (and other abort paths in `plpr.mbt`,
  `pliv.mbt`, `iivm.mbt`, `irm.mbt`, `ps_processor.mbt`,
  `quantile.mbt`, `sensitivity.mbt`) from `abort` to `raise Error`
  so the existing 64 panic_* tests actually exercise the abort
  path. This is a mechanical change (~30 minutes) and would convert
  22.6% of silent tests into actual assertions.
- Add a positive J-floor regression test once the above is done.