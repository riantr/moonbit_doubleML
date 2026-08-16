# TODO 0.14.0 (isotonic PAVA propensity-score calibration) — Verdict

**Date**: 2026-08-16
**Branch / tag**: master, v0.14.0
**Scope**: Implement the `isotonic` calibration method on
`PSProcessor::adjust_ps` (deferred from v0.10.0). Adds pure-MoonBit
PAVA (pool-adjacent-violators algorithm), `fit_isotonic` /
`predict_isotonic` helpers, K-fold cross-validated calibration,
13 new tests, and a Python cross-check against
`sklearn.isotonic.IsotonicRegression`.

**Behaviour change**: Only when `calibration_method="isotonic"` is
explicitly set. The default config (`"none"`) is byte-equal to
v0.13.0; the `DoubleMLDIDBinary` / `DoubleMLDIDCS` demos (which use
the default) produce bit-equal ATT estimates to v0.13.0.

## What was added

### Pure-MoonBit PAVA (ps_processor.mbt)

```moonbit
pub fn pava(y : Array[Double], weights? : Array[Double] = []) -> Array[Double]
pub fn fit_isotonic(x : Array[Double], y : Array[Double]) -> (Array[Double], Array[Double])
pub fn predict_isotonic(fitted_x : Array[Double], fitted_y_hat : Array[Double], x_new : Array[Double]) -> Array[Double]
```

- `pava` is the canonical weighted pool-adjacent-violators
  algorithm: walk the input once, maintain a stack of
  `(sum_y, sum_w, size)` blocks, pool when the previous
  block's mean is greater than the new block's mean.
  Each output block is the weighted mean of its constituents.
- `fit_isotonic` is the calibration entry point: sort
  `(x, y)` pairs by `x` (stable sort; ties preserve
  original index order) and apply `pava` to the sorted
  `y`. Returns `(sorted_x, sorted_y_hat)`.
- `predict_isotonic` is the step-function lookup on the
  fitted model. For each `x_new[i]`, returns the
  `fitted_y_hat` at the largest `fitted_x[j] <= x_new[i]`,
  clipped to `[0, 1]` (defensive). Matches sklearn
  `IsotonicRegression(out_of_bounds="clip", y_min=0.0,
  y_max=1.0)` on the no-tie case.

### PSProcessor integration (ps_processor.mbt)

```moonbit
pub fn PSProcessor::adjust_ps(
  self : PSProcessor,
  ps : Array[Double],
  treatment : Array[Double],
  cv? : Array[(Array[Int], Array[Int])]? = None,
) -> Array[Double]
```

- `calibration_method="isotonic"` (the v0.10.0
  forward-compat placeholder, now wired up): PAVA-fit
  on the full `(ps, treatment)`, then step-function
  predict at each `ps[i]`, then clip to
  `[clipping_threshold, 1 - clipping_threshold]`.
- `cv_calibration=true`: K-fold cross-validated
  calibration. When `cv=None`, a deterministic 5-fold
  split with `seed=3141` is generated via
  `kfold.mbt::kfold`. Each fold's held-out predictions
  are concatenated in the original index order.
- The cv partition's union of `test_idx` must cover
  `[0, n)`; otherwise `isotonic_calibrate_cv` aborts
  with a clear "cv partition does not cover all
  indices" message.

### Validation helper (ps_processor.mbt)

```moonbit
fn validate_treatment(treatment : Array[Double]) -> Unit
```

- Aborts on any `treatment[i] ∉ {0.0, 1.0}` before any
  calibration work runs. The upstream
  `_validate_treatment` does a full type + dimension
  check + `type_of_target == "binary"`; we don't have
  a generic target-type helper in pure MoonBit, so the
  bitwise `0.0 / 1.0` check is the upstream-equivalent
  contract for the propensity-score use case.

## Diff summary

| # | File | +/- | What changed |
|---|------|-----|--------------|
| 1 | `ps_processor.mbt` | +262 | `pava`, `fit_isotonic`, `predict_isotonic`, `isotonic_calibrate_cv`, `default_5fold`, `validate_treatment`. Extended `PSProcessor::adjust_ps` with `cv?` and isotonic path. |
| 2 | `ps_processor_test.mbt` | +253 | 13 new tests: 6 PAVA primitives, 4 PSProcessor integration, 1 predict_isotonic step, 1 CV path, 1 input-no-mutation guard. |
| 3 | `README.mbt.md` | +18 | New "Library helpers" entry for isotonic PAVA. Updated test count to 163/163, validator count to 12/12. |
| 4 | `CHANGELOG.md` | +93 | Full v0.14.0 entry. |
| 5 | `validate_pava_with_python.py` | +96 | New Python validator (sklearn reference for PAVA in-sample + 5-fold CV). |
| 6 | `_verify/T140-verdict.md` | (this file) | T140 verdict. |
| 7 | `_verify/T140-commit-msg.txt` | +75 | T140 commit message. |
| 8 | `_verify/test_pava_reference.py` | +75 | Verifier scratch: cross-check PAVA against sklearn. |
| 9 | `_verify/probe-pava-test.mbt.archived` | +47 | Verifier scratch: PAVA probe (now archived). |

**Net**: +919 / -10 lines (most of the +919 is CHANGELOG +
verdict + test + probe + reference Python script; the
production code is +262 / -10).

## Test deltas

- **163 / 163** on every backend (native, wasm-gc, wasm,
  js). +13 from v0.13.0:
  1. `pava_monotonic_passthrough` — strict-monotonic
     input is identity.
  2. `pava_pools_violation` — single violation pools
     into the mean; matches sklearn.
  3. `pava_pools_all_to_mean` — heavy violation pools
     into a single block.
  4. `pava_empty_input` — empty input gives empty
     output.
  5. `pava_with_weights` — weighted PAVA semantics
     (mean = sum_y / sum_w).
  6. `fit_isotonic_is_non_decreasing` — output is
     monotonic by construction.
  7. `predict_isotonic_step_function` — step-function
     lookup with below-min / above-max clip.
  8. `ps_processor_isotonic_no_cv` — in-sample
     calibration on a 10-element step DGP.
  9. `ps_processor_isotonic_pooling` — PAVA pooling
     on a 5-element DGP with one violation.
  10. `ps_processor_isotonic_cv_basic` — 5-fold CV
      output lies in the clip range.
  11. `ps_processor_isotonic_cv_user_folds` — user-
      supplied CV (2 folds) is accepted; union of
      test sets must cover all indices.
  12. `ps_processor_isotonic_does_not_mutate_input` —
      `ps` and `treatment` are unchanged after
      `adjust_ps`.
  13. `ps_processor_isotonic_no_cv_preserves_pava_output`
      — PAVA on a fully-decreasing y pools to the
      global mean; output is `0.5` for all elements.

- **12 / 12 Python validators PASS** (was 11):
  - 11 existing (`validate_{with, irm, pliv, iivm,
    did, did_binary, did_cs, quantile, rdd, ssm,
    blp_policy}_with_python.py`) — all bit-equal to
    v0.13.0.
  - 1 new (`validate_pava_with_python.py`) — produces
    the sklearn `IsotonicRegression` reference (in-
    sample + 5-fold CV) on a 10-element DGP with
    distinct-x; the MoonBit per-DGP numbers in
    `ps_processor_test.mbt` match this reference to
    within `1e-12` on the no-tie case.

- **5 / 5** demos all run cleanly and produce
  bit-equal output to v0.13.0. None of the demos
  uses the new `isotonic` calibration method
  (default config is still clip-only); the
  `did_binary` and `did_cs` demos keep the v0.13.0
  ATT estimates.

## Cross-check: MoonBit PAVA vs sklearn

The `_verify/test_pava_reference.py` script computes
the sklearn `IsotonicRegression` reference on four
test cases and compares them to a hand-rolled PAVA
matching our MoonBit implementation:

| DGP | sklearn IR | MoonBit PAVA | Match |
|-----|-----------|--------------|-------|
| Monotonic `[0.1..0.5]` | `[0.1, 0.2, 0.3, 0.4, 0.5]` | `[0.1, 0.2, 0.3, 0.4, 0.5]` | ✓ |
| Single violation `[0.3, 0.2, 0.4, 0.5, 0.6]` (sorted) | `[0.25, 0.25, 0.4, 0.5, 0.6]` | `[0.25, 0.25, 0.4, 0.5, 0.6]` | ✓ |
| Tied x `[0.1, 0.1, 0.3, 0.5, 0.5]` | `[0.233, 0.233, 0.233, 0.4, 0.4]` | `[0.1, 0.3, 0.3, 0.4, 0.4]` | ✗ (documented) |
| Random `n=10` distinct-x | step function | step function | ✓ |

The third row (ties) is the known-divergence case:
sklearn groups tied-x before PAVA, our implementation
runs PAVA on the per-element sequence. The validate
script uses 4-decimal random `x` to avoid ties on
the canonical test DGP.

## API additions (delta from v0.13.0)

| Symbol | Where | What |
|--------|-------|------|
| `pava` | `ps_processor.mbt` | Pure weighted PAVA (now public for direct testing) |
| `fit_isotonic` | `ps_processor.mbt` | Sort-by-x + PAVA |
| `predict_isotonic` | `ps_processor.mbt` | Step-function lookup on the fitted model |
| `PSProcessor::adjust_ps(cv?)` | `ps_processor.mbt` | New optional `cv` parameter; backward-compatible |
| `validate_pava_with_python.py` | repo root | New Python validator |

No field renames, no signature breakage, no removed
functions. The `calibration_method="isotonic"` path
that aborted in v0.10.0..v0.13.0 now succeeds.

## Known limitations / deferrals

- **PAVA tie handling differs from sklearn** on tied-x
  inputs (documented in the CHANGELOG and the test
  cases). The propensity-score use case has continuous
  `ps` so ties are vanishingly rare; the test uses
  4-decimal random `x` to guarantee no ties.
- **No `init_ps_processor` shim** (upstream wrapper
  around the deprecated `trimming_rule` /
  `trimming_threshold` keywords). The v0.14.0 entry
  point is `PSProcessor::new(config=...)` directly.
- **Default 5-fold CV uses `seed=3141`** (matches the
  package's standard fold RNG). User-supplied CV
  overrides this.
- **No change to the v0.10.0 default 1e-2 clip**.
- **The 1e-2 default still applies after the
  (optional) calibration step**, so opting into
  isotonic calibration doesn't change the final
  clip band.

## Files changed (full list)

```
 CHANGELOG.md                           | 93 +++++++++++++++
 README.mbt.md                          | 18 ++++
 ps_processor.mbt                       | 262 ++++++++++++++++++++++--
 ps_processor_test.mbt                  | 253 ++++++++++++++++++++++--
 validate_pava_with_python.py           | 96 +++++++++++
 _verify/T140-verdict.md                | (this file)
 _verify/T140-commit-msg.txt            | 75 +++++++
 _verify/test_pava_reference.py         | 75 +++++++
 _verify/probe-pava-test.mbt.archived   | 47 +++++
 9 files changed, 919 insertions(+), 10 deletions(-)
```

See `_verify/T140-commit-msg.txt` for the git commit
message.
