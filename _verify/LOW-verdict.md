# TODO 0.4.3 (LOW polish) — Verdict

**Verdict**: PASS (grade A)
**Date**: 2026-08-10
**Scope**: REVIEW 0.4.0 low-priority smells (L1-L8)

## Smells addressed

| #   | File                                | Change                                                                                       |
| --- | ----------------------------------- | -------------------------------------------------------------------------------------------- |
| L2  | `apo.mbt:91-105`                    | `cross_fit_apo` doc added (treated-only `g`, full-sample `m`) — already landed in 0.4.2 branch |
| L5  | `blp_policy.mbt:1-22`               | `DoubleMLBLP` doc expanded: HC0 vs nonrobust semantics + field storage rationale              |
| L6  | `seed.mbt:31-37`                    | attempted `3 => b3` → REVERTED (MoonBit `%` is signed; wildcard required for `-k%4` cases)   |
| L7  | `linear.mbt:166-189`                | `fit_weighted` `require(wi >= 0.0)`; new `panic_*` test                                      |
| L8  | `linear.mbt:127-156`                | `covariance_diagonal` doc notes that `xtx_inv_diag` is empty after `fit_weighted`            |

## Smells skipped (with reason)

| #   | Reason                                                                                          |
| --- | ----------------------------------------------------------------------------------------------- |
| L1  | `cov_type` field kept on `DoubleMLBLP` struct for forward compat; refactor to local var breaks public API surface (`pkg.generated.mbti`) |
| L3  | `LinearRegression::coef_` is already `let mut`-managed via the struct copy in `fit`/`fit_weighted` |
| L4  | Asymmetric `n_features` accessor presence is consistent across models — cosmetic only            |
| L6  | Match exhaustiveness — `Int % 4` returns signed values, wildcard covers negative remainders      |

## Verification

### Multi-backend test

| target    | result                                       |
| --------- | -------------------------------------------- |
| native    | Total tests: 115, passed: 115, failed: 0.    |
| wasm-gc   | Total tests: 115, passed: 115, failed: 0.    |
| wasm      | Total tests: 115, passed: 115, failed: 0.    |
| js        | Total tests: 115, passed: 115, failed: 0.    |

`moon test --deny-warn` clean on all four targets.

### Python cross-check

All 8 `validate_*_with_python.py` scripts pass (exit=0):

- `validate_blp_policy_with_python.py` — BLP per-coefficient SE + policy tree variance-reduction gain
- `validate_did_with_python.py` — DID delta-method covariance
- `validate_iivm_with_python.py` — IIVM ATE
- `validate_irm_with_python.py` — IRM ATE (n_rep=1 and n_rep=5)
- `validate_pliv_with_python.py` — PLIV LATE
- `validate_quantile_with_python.py` — PQ/LPQ/QTE/CVaR
- `validate_rdd_with_python.py` — RDD sharp + fuzzy + cross-covariance
- `validate_ssm_with_python.py` — SSM (no-pi g design)

Sample IRM (n_rep=5):
- handrolled theta = 1.0769, se = 0.0956
- upstream  theta = 1.0603, se = 0.0949
- moonbit   theta = 1.0245, se = 0.0940
- |mb - handrolled| = 5.24e-02 < MODEL_TOL = 0.10 ✓

## Files modified

```
M  blp_policy.mbt     (L5: doc)
M  linear.mbt         (L7: require w>=0; L8: doc note on empty xtx_inv_diag)
M  linear_test.mbt    (L7: panic_fit_weighted_aborts_on_negative_weight)
M  seed.mbt           (L6: docstring note added; match reverted to wildcard)
```

## Sign-off

All eight REVIEW low smells triaged:

- **5 addressed** (L2, L5, L7, L8 + L6 doc note)
- **3 skipped with reason** (L1, L3, L4 — all surface/cosmetic with poor risk/reward)
- **1 partial** (L6 — doc note only; code change reverted due to signed-modulo semantics)

115/115 tests across 4 backends; 8/8 Python validators. No estimate drift vs. 0.4.2.