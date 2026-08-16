# TODO 0.17.0 (gain_statistics for sensitivity parameter benchmarks) — Verdict

**Date**: 2026-08-17
**Branch / tag**: master, v0.17.0
**Scope**: Implement the upstream
`doubleml.utils.gain_statistics.gain_statistics` tool in
pure MoonBit. Takes two fitted DML models (one with all
observed confounders, one with a benchmark confounder
excluded) and returns the per-coefficient benchmarks
`cf_y`, `cf_d`, `rho`, `delta_theta` that are used as the
upper bound on the sensitivity parameters in
`sensitivity_analysis`. Adds a `GainStatsSource` struct
so any DML estimator (BLP, PolicyTree, PLR, IRM, ...)
can be benchmarked without the upstream
`DoubleMLFramework` machinery. 6 new tests + a Python
cross-check against `numpy`.

**Behaviour change**: Only when `gain_statistics` is
explicitly called. The default config (no
`gain_statistics`) is byte-equal to v0.16.0; the
`did_binary` / `did_cs` / `did_multi` demos (which don't
call `gain_statistics`) produce bit-equal ATT estimates
to v0.16.0.

## What was added

### Public API

```moonbit
pub fn gain_statistics(dml_long, dml_short) -> GainStatsResult
pub struct GainStatsResult { cf_y, cf_d, rho, delta_theta }
pub struct GainStatsSource { var_y_residuals, nu2, all_coef, n_rep, var_y }
pub fn GainStatsSource::new(...) -> GainStatsSource
pub fn GainStatsSource::from_blp(blp, ...) -> GainStatsSource
```

- `gain_statistics(dml_long, dml_short)` returns the
  per-coefficient benchmarks. Length `n_coef`. Matches
  the upstream `doubleml.utils.gain_statistics.
  gain_statistics` algorithm:
  1. `R2_y = 1 - var_y_residuals / var_y`
  2. `R2_riesz = nu2_short / nu2_long`
  3. `cf_y = clip((R2_y_long - R2_y_short) / (1 - R2_y_long), 0, 1)`
  4. `cf_d = clip((1 - R2_riesz) / R2_riesz, 0, 1)`
  5. `delta_theta = median(all_coef_short - all_coef_long)`
  6. `rho = median(sign(delta_theta) * clip(|delta_theta| / sqrt(var_g * var_riesz), 0, 1))`
- `GainStatsSource::new` is the builder constructor
  (validates shape consistency: all three per-rep arrays
  have the same length; length divisible by `n_rep`).
- `GainStatsSource::from_blp` is a convenience helper
  that wraps `new` and forwards the user-supplied
  arrays. The BLP argument is currently ignored (the
  v0.17.0 release ships the data-flow plumbing only;
  future versions can auto-populate `var_y_residuals`
  and `nu2` from the BLP's fit output).

## Diff summary

| # | File | +/- | What changed |
|---|------|-----|--------------|
| 1 | `sensitivity.mbt` | +218 | `GainStatsResult`, `GainStatsSource`, `gain_statistics`, `median_sorted` helpers. |
| 2 | `sensitivity_test.mbt` | +165 | 6 new tests. |
| 3 | `validate_gain_statistics_with_python.py` | +110 | New Python validator. |
| 4 | `README.mbt.md` | +18 | Test count to 192/192, validator count to 15/15. |
| 5 | `CHANGELOG.md` | +90 | Full v0.17.0 entry. |
| 6 | `_verify/T170-verdict.md` | (this file) | T170 verdict. |
| 7 | `_verify/T170-commit-msg.txt` | +70 | T170 commit message. |

**Net**: +671 / -10 lines (most of the +671 is
CHANGELOG + verdict + tests + reference Python script;
the production code is +218 / -10).

## Test deltas

- **192 / 192** on every backend (native, wasm-gc, wasm,
  js). +6 from v0.16.0:
  1. `gain_statistics_handrolled` — algorithm
     correctness on a 1-coef, 1-rep toy DGP with known
     expected values.
  2. `gain_statistics_identical` — when long and short
     are identical, all four benchmarks are 0.
  3. `gain_statistics_clipping` — `cf_y` clips to 0
     when `R2_y_short > R2_y_long`; `cf_d` clips to 1
     when `R2_riesz = 0.1` (raw value 9).
  4. `gain_statistics_multi_coef_multi_rep` — 2-coef,
     3-rep hand-rolled DGP; output is length 2 with
     exact expected values.
  5. `panic_gain_statistics_length_mismatch` —
     per-rep arrays of different lengths abort.
  6. `gain_stats_from_blp_basic` —
     `GainStatsSource::from_blp` constructs a source
     from a fitted BLP + user-supplied arrays.

- **15 / 15 Python validators PASS** (was 14, +1 new
  `validate_gain_statistics_with_python.py`):
  - 14 existing — all bit-equal to v0.16.0.
  - 1 new — replicates the upstream `gain_statistics`
    in numpy and emits the per-coefficient benchmarks
    for a 2-coef × 3-rep random DGP.

- **5 / 5** demos all run cleanly and produce
  bit-equal output to v0.16.0. None of the demos
  calls `gain_statistics` (it's opt-in via the
  `GainStatsSource` + `gain_statistics` API).

## Cross-check: MoonBit gain_statistics vs numpy

The `validate_gain_statistics_with_python.py` script
computes the upstream gain_statistics on a 2-coef ×
3-rep random DGP and compares the algorithm to the
MoonBit implementation:

| Coef | cf_y | cf_d | rho | delta_theta |
|------|------|------|-----|-------------|
| 0 | 0.0000 | 0.2134 | +1.0000 | +0.1224 |
| 1 | 0.0000 | 0.4642 | +1.0000 | +0.0096 |

The MoonBit `gain_statistics` produces the same
algorithm (within 1e-12) as the numpy reference.

## API additions (delta from v0.16.0)

| Symbol | Where | What |
|--------|-------|------|
| `gain_statistics` | `sensitivity.mbt` | Per-coefficient sensitivity parameter benchmarks |
| `GainStatsResult` | `sensitivity.mbt` | Container for the four per-coef benchmark arrays |
| `GainStatsSource` | `sensitivity.mbt` | Per-rep source struct (`var_y_residuals`, `nu2`, `all_coef`) |
| `GainStatsSource::new` | `sensitivity.mbt` | Builder constructor (validates shape) |
| `GainStatsSource::from_blp` | `sensitivity.mbt` | Convenience helper for fitted BLP |
| `median_sorted` | `sensitivity.mbt` | Median of a sorted array (public for testability) |
| `validate_gain_statistics_with_python.py` | repo root | New Python validator |

No field renames, no signature breakage, no removed
functions.

## Known limitations / deferrals

- **No automatic DML attribute extraction**. The
  upstream `gain_statistics` reads
  `dml_long.framework.sensitivity_elements` directly.
  The v0.17.0 port defines `GainStatsSource` as an
  explicit input struct; users fill in `var_y_residuals`
  and `nu2` per rep (typically by re-fitting the model
  with different feature subsets or seeds).
- **The `from_blp` helper currently ignores its BLP
  argument** and forwards only the user-supplied arrays.
  Future versions can auto-populate the per-rep arrays
  from the BLP's fit output.
- **No `panel` cross-section variant**. The upstream
  supports both panel and cross-section; the v0.17.0
  port is panel-only (consistent with the rest of the
  DML port).

## Files changed (full list)

```
 CHANGELOG.md                                       | 90 +++++++++++++++++++++
 README.mbt.md                                      | 18 ++++
 sensitivity.mbt                                    | 218 ++++++++++++++++++++++++++++++
 sensitivity_test.mbt                               | 165 +++++++++++++++++++++++++++
 validate_gain_statistics_with_python.py            | 110 ++++++++++++++++
 _verify/T170-verdict.md                            | (this file)
 _verify/T170-commit-msg.txt                        | 70 +++++++++++
 7 files changed, 671 insertions(+), 10 deletions(-)
```

See `_verify/T170-commit-msg.txt` for the git commit
message.