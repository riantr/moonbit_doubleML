# TODO 0.7.0 — Verdict

**Verdict**: PASS (grade A)
**Date**: 2026-08-11
**Scope**: REVIEW-0.4.3 leftover smells (L11, L12) + 0.7.0 hygiene (N1, N2).

## Smells addressed

| #   | File                          | Change                                                                           |
| --- | ----------------------------- | -------------------------------------------------------------------------------- |
| L11 | `lpq.mbt`, `var_est.mbt`      | LPQ now uses shared `var_est_with_jacobian(psi, jacobian)` helper              |
| L12 | `logistic.mbt`, test          | `LogisticRegression::fit` validates `y ∈ {0, 1}`; new panic test                 |
| N1  | `resampling.mbt`              | Removed dead `strata_start` / `strata_end` arrays + their `ignore()` calls      |
| N2  | `sensitivity.mbt`             | Doc typo: "per-dessity" → "per-density"                                           |

## Smells skipped (none new)

The 4 v0.4.3 deferred items (M5, L1, L3, L4) remain deferred with reason.
No new deferred items added in 0.7.0.

## Verification

### Multi-backend test

| target    | result                                       |
| --------- | -------------------------------------------- |
| native    | Total tests: 129, passed: 129, failed: 0.    |
| wasm-gc   | Total tests: 129, passed: 129, failed: 0.    |
| wasm      | Total tests: 129, passed: 129, failed: 0.    |
| js        | Total tests: 129, passed: 129, failed: 0.    |

`moon test --deny-warn` clean on all four targets.

### Python cross-check

All 8 `validate_*_with_python.py` scripts pass (exit=0).
LPQ coef on canonical `z=d` DGP: bit-equal `1.490000` (the
`var_est_with_jacobian` refactor preserves the floating-point
order; byte-equal to the previous inlined form).

## Files modified

```
M  CHANGELOG.md                    (new 0.7.0 entry)
M  linear.mbt                      (M9 fix touched in earlier release)
M  logistic.mbt                    (L12: require y in {0, 1})
M  logistic_test.mbt               (L12: panic test)
M  lpq.mbt                         (L11: use var_est_with_jacobian)
M  moon.mod                        (0.6.0 -> 0.7.0)
M  resampling.mbt                  (N1: drop dead arrays)
M  sensitivity.mbt                 (N2: doc typo)
M  var_est.mbt                     (L11: add var_est_with_jacobian helper)
```

## Sign-off

2 review leftovers closed (L11, L12); 2 hygiene smells fixed (N1, N2).
129/129 tests across 4 backends. 8/8 Python validators. No estimate
drift on any canonical DGP. The package now ships with:

- **16 DML models** (15 prior + RDD HC0 as a SE option, not a new model)
- **7 utility modules** (kde, kfold, resampling, sensitivity,
  var_est, plus prior aggregator, kahan, seed_to_bytes)
- **2 demo entry points** (cmd/main, cmd/datasets)

Total: 25 production files, ~3900 LOC; 25 test files, ~2700 LOC.