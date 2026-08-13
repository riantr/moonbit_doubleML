# TODO 0.13.0 (Polish: API accessor consistency + REVIEW history trim + logistic_test cleanup) — Verdict

**Date**: 2026-08-13
**Branch / tag**: master, v0.13.0
**Scope**: Codebase polish. (a) Add `n_obs` / `n_features` accessors to
the 8 estimators that were missing one or both. (b) Trim 6 historical
REVIEW context comments that no longer reflect the current code. (c)
Drop the local 7-bit-encoding `logistic_seed_buf` helper from
`logistic_test.mbt` and route the 3 callsites through the canonical
`chacha8_rng(N)` / `permute(n, seed: Int)` path. (d) Add a "Demo
entry points" table to the README so the `cmd/*/main.mbt` drivers
are discoverable from the package front page. (e) Add docstrings
on previously-bare accessor definitions, and collapse the 3
`///| ///|` comment-artifact duplicates from the v0.12.0 accessor
add pass.

**Behaviour change**: NONE. Pure polish — every existing test result
is byte-equal to v0.12.0, every Python validator passes, every
demo output is bit-equal.

## Diff summary

| # | File | +/- | What changed |
|---|------|-----|--------------|
| 1 | `plr.mbt` | +6 | Added `n_features` accessor (had `n_obs` already) |
| 2 | `irm.mbt` | +6 | Added `n_features` accessor (had `n_obs` already) |
| 3 | `apo.mbt` | +6 | Added `n_features` accessor (had `n_obs` already) |
| 4 | `rdd.mbt` | +12 | Added both `n_obs` and `n_features` (RDD uses `DoubleMLRDDData`) |
| 5 | `pq/qte/cvar` (`quantile.mbt`) | +33 | Added both `n_obs` and `n_features` to PQ, QTE, CVAR |
| 6 | `lpq.mbt` | +12 | Added both `n_obs` and `n_features` (LPQ uses `DoubleMLLPQData`) |
| 7 | `apo.mbt` | -10 | Trimmed REVIEW L2 / M3 / M4 / H2 historical context |
| 8 | `kfold.mbt` | -4 | Trimmed REVIEW M13 (now a one-liner pointer) |
| 9 | `linear.mbt` | -4 | Trimmed REVIEW M9 / M10 historical context |
| 10 | `blp_policy.mbt` | -2 | Trimmed REVIEW Bug #5 / TODO #11c.1 historical context |
| 11 | `logistic_test.mbt` | -22 | Dropped `logistic_seed_buf` (7-bit encoder, -17 LOC), rewrote `permute(n, seed: Int)` to take `Int` directly (-5 LOC) |
| 12 | `quantile.mbt` | -3 | Collapsed 3 duplicate `///| ///|` comment artifacts |
| 13 | `README.mbt.md` | +21 | Added "Demo entry points" table (5 drivers) |

**Net**: +129 lines, −67 lines (the new accessors are big because
each one is a triple-line `///|` + docstring + `pub fn`, the
trimmed REVIEW comments are net negative).

## Test deltas

- **150 / 150** on every backend (native, wasm, wasm-gc, js). Zero
  test count delta from v0.12.0 — this is a pure polish release.
- **11 / 11** Python validators PASS:
  - `validate_with_python.py` (PLR smoke test, true θ = 1.0 in CI)
  - `validate_irm_with_python.py` (IRM hand-rolled nrep5 reference)
  - `validate_pliv_with_python.py` (PLIV)
  - `validate_iivm_with_python.py` (IIVM)
  - `validate_did_with_python.py` (DID observational)
  - `validate_did_binary_with_python.py` (panel DID — added 0.8.0)
  - `validate_did_cs_with_python.py` (CS-DID — added 0.9.0)
  - `validate_quantile_with_python.py` (PQ / QTE / LPQ / CVAR)
  - `validate_rdd_with_python.py` (sharp / fuzzy)
  - `validate_ssm_with_python.py` (sample selection)
  - `validate_blp_policy_with_python.py` (BLP + policy tree)
- **5 / 5** demos (`cmd/{main, datasets, did_binary, did_cs, did_multi}`)
  all run cleanly and produce bit-equal output to v0.12.0.

## Accessor surface after v0.13.0

| Model | `n_obs()` | `n_features()` | Data container |
|-------|-----------|----------------|----------------|
| `DoubleMLPLR`    | ✓ | ✓ | `DoubleMLData` |
| `DoubleMLIRM`    | ✓ | ✓ | `DoubleMLData` |
| `DoubleMLPLIV`   | ✓ | ✓ | `DoubleMLPLIVData` |
| `DoubleMLIIVM`   | ✓ | ✓ | `DoubleMLIIVMData` |
| `DoubleMLDID`    | ✓ | ✓ | `DoubleMLDIDData` |
| `DoubleMLDIDBinary` | ✓ | ✓ | `DoubleMLDIDBinaryData` |
| `DoubleMLDIDCS`  | ✓ | ✓ | `DoubleMLDIDCSData` |
| `DoubleMLDIDMulti` | ✓ | ✓ | `DoubleMLDIDCSData` |
| `DoubleMLSSM`    | ✓ | ✓ | `DoubleMLSSMData` |
| `DoubleMLAPO`    | ✓ | ✓ | `DoubleMLAPOData` |
| `DoubleMLAPOS`   | ✓ | ✓ | `DoubleMLAPOSData` |
| `DoubleMLPQ`     | ✓ | ✓ | `DoubleMLData` |
| `DoubleMLQTE`    | ✓ | ✓ | `DoubleMLData` |
| `DoubleMLCVAR`   | ✓ | ✓ | `DoubleMLData` |
| `DoubleMLLPQ`    | ✓ | ✓ | `DoubleMLLPQData` (uses `data.x.rows()/cols()`) |
| `DoubleMLRDD`    | ✓ | ✓ | `DoubleMLRDDData` (uses `data.x.cols()`) |
| `DoubleMLBLP`    | — | — | (model has no `data`, operates on `orth_signal` directly) |
| `DoubleMLPolicyTree` | — | — | (consumes BLP output, no data) |

The two exceptions (`DoubleMLBLP` and `DoubleMLPolicyTree`) are
intentional: BLP is a meta-estimator that consumes a BLP-fitted
orthogonalised signal and a basis matrix from the upstream
`DoubleMLBLP`; it has no data container of its own.

## Known limitations / deferrals

- **Did not add `coef` / `se` accessors on every model** — these
  already exist on the 7 score-bearing models (PLR, IRM, PLIV,
  IIVM, DID, SSM, DIDBinary) and on RDD. The remaining 7
  estimators (APO, APOS, PQ, QTE, CVAR, LPQ, BLP) already expose
  `coef()` / `coefs()` / `se()` / `ses()`; this was not a gap.
- **No bootstrap / joint CIs on `DoubleMLDIDMulti`** — deferred
  from v0.11.0 (~400 LOC upstream `DoubleMLFramework.bootstrap`).
  Still candidate for v0.14+ if user wants to continue.
- **No `isotonic` PAVA calibration on `PSProcessor`** — deferred
  from v0.10.0 (~80 LOC upstream `propensity_score_processing.py`).
  Still candidate for v0.14+ if user wants to continue.
- **REVIEW comments kept on purpose** (L5 / L7 / L8 / L11 / L12 /
  H1 / M10-fix / L11-fix) document real API contracts (panic
  paths, fixed-tolerance values, library-helper usage). Trimmed
  only the comments that had become historical noise.

## Grade

**Pass.** v0.13.0 is a pure polish release — no behaviour change,
no test delta, all 4 backends + 11 Python validators + 5 demos
pass cleanly. The accessor surface is now consistent across
the 15-estimator public API. The README's new "Demo entry
points" table makes the `cmd/*` drivers discoverable for
first-time users. The `logistic_test.mbt` cleanup lands the
last 7-bit-encoding helper in the package on the canonical
8-bit `chacha8_rng` path.

## Files changed (full list)

```
 README.mbt.md     | 21 +++++++++++++++++++++
 apo.mbt           | 26 +++++++++++++-------------
 blp_policy.mbt    |  4 ++--
 irm.mbt           |  6 ++++++
 kfold.mbt         |  9 +++------
 linear.mbt        | 15 ++++++++-------
 logistic_test.mbt | 49 ++++++++++---------------------------------------
 lpq.mbt           | 12 ++++++++++++
 plr.mbt           |  6 ++++++
 quantile.mbt      | 36 ++++++++++++++++++++++++++++++++++++
 rdd.mbt           | 12 ++++++++++++
 CHANGELOG.md      | 60 ++++++++++++++++++++++++++++++++++++++++++++++++++++
 12 files changed, 256 insertions(+), 67 deletions(-)
```

See `_verify/T130-commit-msg.txt` for the git commit message.
