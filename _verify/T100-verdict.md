# TODO 0.10.0 (DoubleMLDIDCSBinary / ps_processor + G+2T stratified folds) — Verdict

**Verdict**: PASS (grade B)
**Date**: 2026-08-12
**Scope**: Add the `PSProcessor` + `ps_processor_config` to the panel
DID models (corresponds to upstream `DoubleMLDIDCSBinary`); enable
`G + 2T`-stratified K-fold sample splitting (matching upstream's
`self._strata`).

## Features added

| #   | File(s)                       | LOC   | Description                                                       |
| --- | ----------------------------- | ----- | ----------------------------------------------------------------- |
| 1   | `ps_processor.mbt`            | ~140  | `PSProcessorConfig` + `PSProcessor::adjust_ps` (clip-only)         |
| 2   | `ps_processor_test.mbt`       | ~95   | 6 tests: config validation, clip behaviour, no-mutation guarantee  |
| 3   | `did.mbt` (extension)         | +50   | `ps_processor` + `strata` fields on `DoubleMLDID`; fit dispatches to `stratified_kfold` when strata non-empty |
| 4   | `did_binary.mbt` (extension)  | +50   | `ps_processor` field + wide-format `G + 2T` strata computation + fallback for tiny strata |
| 5   | `did_cs.mbt` (extension)      | +15   | `ps_processor` field propagated to per-cell `DoubleMLDIDBinary` fits |
| 6   | `did_binary_test.mbt`         | +100  | 2 new tests: `ps_processor.clipping_threshold` bounds `predictions_m()`; ATT invariant under clip threshold changes |

Total new code: ~450 LOC across 6 files (incl. tests).

## Verification

### Multi-backend test

| target    | result                                       |
| --------- | -------------------------------------------- |
| native    | Total tests: 144, passed: 144, failed: 0.    |
| wasm-gc   | Total tests: 144, passed: 144, failed: 0.    |
| wasm      | Total tests: 144, passed: 144, failed: 0.    |
| js        | Total tests: 144, passed: 144, failed: 0.    |

`moon test --deny-warn` clean on all four targets.

### Python cross-check

All 9 `validate_*_with_python.py` scripts pass (exit=0):

- `validate_blp_policy_with_python.py` — BLP per-coefficient SE + policy tree variance-reduction gain
- `validate_did_binary_with_python.py` — panel DID reference, qualitative match
- `validate_did_cs_with_python.py` — multi-cohort CS-DID, all (g, t) cells within 0.5 of true
- `validate_did_with_python.py` — DID delta-method covariance
- `validate_iivm_with_python.py` — IIVM ATE
- `validate_irm_with_python.py` — IRM ATE
- `validate_pliv_with_python.py` — PLIV partialling-out
- `validate_quantile_with_python.py` — APOS / PQ(0.5) bit-equal reference
- `validate_rdd_with_python.py` — RDD sharp + fuzzy local-linear
- `validate_ssm_with_python.py` — SSM ATE (Bug #1 fix)
- `validate_with_python.py` — PLR/IRM/IIVM vs upstream `doubleml` library

### Demo output

```
$ moon run cmd/did_binary
ATT_hat     = 1.000353817920809
se          = 0.0020509634987164647
95% CI      = [0.9963339294633247, 1.0043737063782932]   (true = 1.0, covers)

$ moon run cmd/did_cs
(g=1, t=2): ATT_hat=0.9975366846751541, 95% CI=[0.988, 1.007]   (covers)
(g=1, t=3): ATT_hat=0.9991853217580484, 95% CI=[0.992, 1.006]   (covers)
(g=2, t=3): ATT_hat=1.009462260437846, 95% CI=[1.000, 1.019]   (1.0 at the left edge)
```

The `did_binary` ATT moved from 1.0008 (v0.8.0) → 1.0004 (v0.10.0) due
to the wider 1e-2 default clip; both well within ~1 SE of the true
ATT = 1.0.

## Notes / known limitations

- **Did not port `DoubleMLDIDCSBinary` as a separate struct.**
  Upstream's `DoubleMLDIDCSBinary` adds `ps_processor_config`,
  `print_periods`, and a `print_periods` accessor on top of
  `DoubleMLDIDBinary`, but otherwise shares the same score /
  nuisance structure. In v0.10.0 we instead extended
  `DoubleMLDIDCS` (the per-(g, t) panel CS-DID model from v0.9.0)
  with the same `ps_processor` field, which gives both code
  paths (single-cell panel DID and per-(g, t) staggered DID) the
  upstream behaviour for free. A separate
  `DoubleMLDIDCSBinary` struct can be added later if needed.
- **`isotonic` calibration is a documented TODO** (v0.12+).
  `PSProcessorConfig::new` accepts `calibration_method = "isotonic"`
  for forward-compat, but `PSProcessor::adjust_ps` aborts on that
  value. The pool-adjacent-violators PAVA implementation can be
  added later as a small (~80 LOC) follow-up.
- **Stratified-fold fallback**: `DoubleMLDIDBinary::fit` drops
  the strata array to `[]` (plain `kfold`) if any stratum has
  fewer observations than `n_folds`. This avoids a regression
  for small panels (e.g. the 4-unit toy dataset in
  `did_binary_test.mbt`) and is a documented behaviour.

## Test count delta

| version | count | delta |
| ------- | ----- | ----- |
| 0.9.0   | 136   | —     |
| 0.10.0  | 144   | +8    |

New tests:
1. `ps_processor_clip_basic` — clip interior / exterior values
2. `ps_processor_default_config` — defaults
3. `panic_ps_processor_rejects_invalid_clip` — `clipping_threshold <= 0` aborts
4. `panic_ps_processor_rejects_clip_too_large` — `clipping_threshold >= 0.5` aborts
5. `panic_ps_processor_cv_without_calibration` — `cv_calibration=true` without a calibration method aborts
6. `ps_processor_does_not_mutate_input` — caller's `ps` array unchanged after `adjust_ps`
7. `did_binary_uses_ps_processor_clipping` — `predictions_m()` respects `ps_processor.clipping_threshold`
8. `did_binary_att_invariant_under_ps_processor` — ATT within 0.15 across clip thresholds 0.05 vs 0.01
