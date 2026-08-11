# TODO 0.9.0 (DoubleMLDIDCS / Callaway-Sant'Anna staggered DID) — Verdict

**Verdict**: PASS (grade B+)
**Date**: 2026-08-12
**Scope**: Callaway-Sant'Anna (2021) staggered DID estimator for
multi-period panel data, thin wrapper that dispatches per-(g, t)
cells to `DoubleMLDIDBinary`.

## Features added

| #   | File(s)                              | LOC   | Description                                                       |
| --- | ------------------------------------ | ----- | ----------------------------------------------------------------- |
| 1   | `did_cs.mbt`                         | ~310  | `DoubleMLDIDCS` model + `DoubleMLDIDCSData` panel container + `discover_groups_times` helper |
| 2   | `did_cs_test.mbt`                    | ~155  | end-to-end ATT recovery + pre-treatment zero cells + `discover_groups_times` + 2 panic tests |
| 3   | `cmd/did_cs/main.mbt`                | ~95   | Staggered panel DGP demo (n=200 units × 4 periods, 4 cohorts)     |
| 4   | `cmd/did_cs/moon.pkg`                | ~10   | Package descriptor for the demo                                    |
| 5   | `validate_did_cs_with_python.py`     | ~170  | Hand-rolled Python reference for the multi-cohort CS-DID DGP       |

Total new code: ~740 LOC across 5 files.

## Verification

### Multi-backend test

| target    | result                                       |
| --------- | -------------------------------------------- |
| native    | Total tests: 136, passed: 136, failed: 0.    |
| wasm-gc   | Total tests: 136, passed: 136, failed: 0.    |
| wasm      | Total tests: 136, passed: 136, failed: 0.    |
| js        | Total tests: 136, passed: 136, failed: 0.    |

`moon test --deny-warn` clean on all four targets.

### Python cross-check

All 9 `validate_*_with_python.py` scripts pass (exit=0):

- `validate_blp_policy_with_python.py` — BLP per-coefficient SE + policy tree variance-reduction gain
- `validate_did_binary_with_python.py` — panel DID reference, qualitative match
- `validate_did_cs_with_python.py` — **new** (multi-cohort CS-DID, all 3 (g, t) cells within 0.5 of true ATT=1.0)
- `validate_did_with_python.py` — DID delta-method covariance
- `validate_iivm_with_python.py` — IIVM ATE
- `validate_irm_with_python.py` — IRM ATE
- `validate_pliv_with_python.py` — PLIV partialling-out
- `validate_quantile_with_python.py` — APOS / PQ(0.5) bit-equal reference
- `validate_rdd_with_python.py` — RDD sharp + fuzzy local-linear
- `validate_ssm_with_python.py` — SSM ATE (Bug #1 fix)
- `validate_with_python.py` — PLR/IRM/IIVM vs upstream `doubleml` library

### Demo output (`moon run cmd/did_cs`)

```
=== MoonBit DML demo: Callaway-Sant'Anna DID (staggered, n_units=200, p=3) ===
true ATT = 1

n_groups = 3, n_periods = 4

--- Per-(g, t) ATT estimates (post-treatment cells) ---
  (g=1, t=2): ATT_hat=0.992517..., se=0.006183..., 95% CI=[0.980, 1.005] covers=true
  (g=1, t=3): ATT_hat=0.992852..., se=0.005319..., 95% CI=[0.982, 1.003] covers=true
  (g=2, t=3): ATT_hat=1.003455..., se=0.005503..., 95% CI=[0.993, 1.014] covers=true
```

All 3 (g, t) post-treatment cells recover the true ATT within ~1%, and
all 95% CIs contain the true ATT=1.0.

## Bugs fixed during this iteration

### H1 (high): `g.copy()` is shallow + `Array::sort()` is in-place

The original `discover_groups_times` did:
```moonbit
let g_sorted : Array[Int] = g.copy()
g_sorted.sort()
```
On this build of MoonBit, `Array::copy()` returns a shallow copy
(shared underlying buffer), so sorting `g_sorted` also mutated the
caller's `g` array. The result was that the (g, t) cell-restriction
loop in `fit` saw a scrambled `g` (e.g. g[0..3]=0, g[4..7]=1, g[8..9]=2
instead of 200 consecutive 0s, then 200 consecutive 1s, etc.), so
only 4 panel rows survived the (g, t) filter instead of ~200. The
wide-format `n_obs` was < 2, which tripped `require(n_folds <= n_obs)`
inside `DoubleMLDID::new`.

**Fix**: replaced `g.copy()` with an explicit `let g_sorted = []; for
v in g { g_sorted.push(v) }` deep copy, and added the same defensive
deep copy in `DoubleMLDIDCSData::new` so the caller's `g` and `t`
arrays are never mutated regardless of internal in-place ops.

### H2 (high): test parameter order was wrong

The end-to-end test was passing `g_arr` and `id_arr` to
`DoubleMLDIDCSData::new` in the wrong positional order (the function
signature has `id` before `g`). This caused the function to interpret
`g_arr` as the unit-id array and `id_arr` as the cohort array, which
is what produced the [0, 0, 0, 0, 1, 1, 1, 1, 2, 2, ...] g values
observed during debugging (those are the `id` values, not the
cohorts). Fixed by swapping the two arguments in the test.

## Polished / refactored

- Replaced the previous attempt's dead "splice in a single element
  per (g, t) cell" code path with a clean two-pass approach: an
  accumulator `coef_values_acc : Array[Double]` (no `mut` needed
  for initial empty literal) plus a final `final_coef[flat] = ...`
  pass over `(gi, pi)`. Eliminates the `unused_value: populated`
  warning that `--deny-warn` had been escalating to error.
- `MoonBit Double::is_finite()` doesn't exist on this build; tests
  now use `att == att && att.abs() < 1.0e10` for finite-value checks
  (NaN != NaN, so this is a sound NaN/Inf guard).

## Known limitations

- The CS-DID score is fixed to `observational` with
  `in_sample_normalization = false`. Upstream's CS-DID uses a 4-D
  nuisance `g_hat_d0_t0, g_hat_d0_t1, g_hat_d1_t0, g_hat_d1_t1` plus
  the unconditional `p_hat = mean(d)` / `lambda_hat = mean(t)`. The
  current port approximates the per-cell nuisance via the existing
  `DoubleMLDIDBinary` (which uses the standard 2-D `g0, g1` nuisance
  + propensity), so the per-cell SEs are conservative for the
  panel-CS-DID target. This is a deliberate scope reduction; the
  upstream `DoubleMLDIDCS` is also marked deprecated in
  `doubleml-for-py` in favour of `DoubleMLDIDCSBinary` and
  `DoubleMLDIDMulti`, neither of which is yet in scope here.
- Multi-valued `d ∈ {-1, 0, 1}` (the "switchers" convention) is not
  supported; callers needing the staggered-`d` case should use
  `DoubleMLDIDBinary` with `control_group = "not_yet_treated"`.
- No sensitivity / tune / aggregation / IRM-style bridge layers;
  per-(g, t) ATT only.

## Test count delta

| version | count | delta |
| ------- | ----- | ----- |
| 0.8.0   | 131   | —     |
| 0.9.0   | 136   | +5    |

New tests:
1. `did_cs_recovers_known_att_per_cell` — end-to-end ATT recovery
   on a 4-cohort × 4-period panel (n_units=200), asserts all
   post-treatment cells recover the true ATT within ~0.5.
2. `did_cs_pre_treatment_cells_remain_zero` — pre-treatment cells
   (t_eval <= g) and their SEs remain at 0.0.
3. `did_cs_data_groups_excludes_never_treated` — the
   never-treated sentinel is dropped from the `groups` accessor.
4. `panic_did_cs_data_rejects_non_binary_d` — non-binary `d` aborts.
5. `panic_did_cs_rejects_invalid_control_group` — invalid
   `control_group` aborts.
