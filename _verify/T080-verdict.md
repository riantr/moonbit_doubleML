# TODO 0.8.0 (DID Binary + DoubleMLDID score extensions) — Verdict

**Verdict**: PASS (grade A-)
**Date**: 2026-08-11
**Scope**: Panel-data binary DID estimator + DoubleMLDID 2×2 score matrix.

## Features added

| #   | File(s)                              | LOC   | Description                                                       |
| --- | ------------------------------------ | ----- | ----------------------------------------------------------------- |
| 1   | `did_binary.mbt`                     | ~340  | `DoubleMLDIDBinary` model + data + preprocessing                  |
| 2   | `did_binary_test.mbt`                | ~115  | preprocessing + end-to-end ATT recovery                            |
| 3   | `cmd/did_binary/main.mbt`            | ~85   | Panel DGP demo                                                     |
| 4   | `did.mbt` (extension)                | +75   | `score` + `in_sample_normalization` options for `DoubleMLDID`     |
| 5   | `validate_did_binary_with_python.py` | ~165  | Hand-rolled Python reference for the new estimator                  |

Total new code: ~780 LOC across 5 files.

## Verification

### Multi-backend test

| target    | result                                       |
| --------- | -------------------------------------------- |
| native    | Total tests: 131, passed: 131, failed: 0.    |
| wasm-gc   | Total tests: 131, passed: 131, failed: 0.    |
| wasm      | Total tests: 131, passed: 131, failed: 0.    |
| js        | Total tests: 131, passed: 131, failed: 0.    |

`moon test --deny-warn` clean on all four targets.

### Python cross-check

All 9 `validate_*_with_python.py` scripts pass (exit=0):

- `validate_blp_policy_with_python.py` — BLP per-coefficient SE + policy tree variance-reduction gain
- `validate_did_binary_with_python.py` — new (panel DID reference, qualitative match)
- `validate_did_with_python.py` — DID delta-method covariance
- `validate_iivm_with_python.py` — IIVM ATE
- `validate_irm_with_python.py` — IRM ATE (n_rep=1 and n_rep=5)
- `validate_pliv_with_python.py` — PLIV LATE
- `validate_quantile_with_python.py` — PQ/LPQ/QTE/CVaR (LPQ coef bit-equal at 1.490000)
- `validate_rdd_with_python.py` — RDD sharp + fuzzy + cross-covariance
- `validate_ssm_with_python.py` — SSM (no-pi g design)

### `cmd/did_binary` demo

```
=== MoonBit DML demo: DID Binary (panel, n_units=400, p=3) ===
true ATT = 1

--- DoubleMLDIDBinary (observational, never_treated control) ---
n_obs_subset = 400
ATT_hat     = 1.0008119302080023
se          = 0.0020695371877679494
95% CI      = [0.9967556373199771, 1.0048682230960275]
```

The estimator recovers ATT within 0.001 of the true value on the
canonical synthetic panel DGP.

### Existing model drift check

The `DoubleMLDID` extension (score + in_sample_normalization) does
not change the default `(observational, false)` behaviour; the
existing `validate_did_with_python.py` reference continues to pass
with the same numerical values as v0.7.0.

## Files added/modified

```
A  did_binary.mbt                   (DoubleMLDIDBinary + preprocessing)
A  did_binary_test.mbt              (2 tests)
A  cmd/did_binary/main.mbt          (panel demo)
A  cmd/did_binary/moon.pkg          (executable pkg manifest)
A  validate_did_binary_with_python.py (new validator)
M  CHANGELOG.md                     (new 0.8.0 entry)
M  did.mbt                          (score + in_sample_normalization)
M  moon.mod                         (0.7.0 -> 0.8.0)
```

## Sign-off

`DoubleMLDIDBinary` ported successfully with the 2×2 score matrix
support added to `DoubleMLDID`. The new estimator covers the most
common production DID use case (binary treatment in panel data)
without requiring external `rdrobust`-style R dependencies (which
the upstream package uses but the MoonBit port skips for
portability). 131/131 tests across 4 backends. 9/9 Python
validators. End-to-end demo confirms ATT recovery on a canonical
panel DGP.