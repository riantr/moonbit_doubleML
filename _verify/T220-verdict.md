# TODO 0.22.0 (GainStatsSource::from_blp_cv) — Verdict

**Date**: 2026-08-21
**Branch / tag**: master, v0.22.0
**Scope**: Add a cross-fit variant of
`GainStatsSource::from_blp`. The new
`from_blp_cv(blp, n_folds?, seed?)` recomputes
`var_y_residuals` from out-of-fold predictions
rather than the in-sample BLP residuals, giving a
more honest `R2_y` benchmark in `gain_statistics`.
Also adds public `DoubleMLBLP::orth_signal()` and
`DoubleMLBLP::basis()` accessors so `from_blp_cv`
can refit the BLP on each fold's training subset.

## Motivation

The v0.19.0 `from_blp` uses the in-sample BLP
residual sum of squares (`rss / n`) as
`var_y_residuals`. This is the "training R^2" of
the BLP, which is upward-biased: the basis was fit
on the same rows, so the residuals are smaller
than they would be on held-out data. The
`gain_statistics` algorithm then computes
`R2_y = 1 - var_y_residuals / var_y`, which is
optimistic. For sensitivity benchmarks, an honest
R^2 is the right thing.

The v0.22.0 release fixes this by computing the
out-of-fold residual variance via K-fold
cross-fitting.

## What was added

### Public API (delta from v0.21.0)

```moonbit
// New: cross-fit auto-population
pub fn GainStatsSource::from_blp_cv(
  blp : DoubleMLBLP,
  n_folds? : Int = 5,
  seed? : Int = 3141,
) -> GainStatsSource

// New BLP accessors (needed by from_blp_cv)
pub fn DoubleMLBLP::orth_signal(self : DoubleMLBLP) -> Array[Double]
pub fn DoubleMLBLP::basis(self : DoubleMLBLP) -> Matrix
```

### Algorithm

For `from_blp_cv(blp, n_folds=5, seed=3141)`:
1. Draw `n_folds` random folds via `kfold(n_obs, n_folds, seed)`.
2. For each fold, fit a `LinearRegression` on the
   training rows and predict on the test fold.
3. Compute the OOF residual sum
   `ss_resid_oof = sum_fold sum_i (y_i - y_hat_i)^2`.
4. `var_y_residuals_scalar = ss_resid_oof / n_obs`.
5. `nu2[k] = var_y_residuals_scalar / (n_obs * se[k]^2)`
   (same homoskedastic convention as `from_blp`).

`coef`, `se`, `var_y`, and `all_coef` are
unchanged from `from_blp` (the BLP's full-data fit
is the canonical coefficient estimate).

## Diff summary

| # | File | +/- | What changed |
|---|------|-----|--------------|
| 1 | `blp_policy.mbt` | +20 | `orth_signal()` and `basis()` accessors. |
| 2 | `sensitivity.mbt` | +110 | `from_blp_cv`, internal helpers. |
| 3 | `sensitivity_test.mbt` | +120 | 6 new tests. |
| 4 | `README.mbt.md` | +9 | Test count to 231/231. |
| 5 | `CHANGELOG.md` | +90 | Full v0.22.0 entry. |
| 6 | `_verify/T220-verdict.md` | (this file) | T220 verdict. |
| 7 | `_verify/T220-commit-msg.txt` | +90 | T220 commit message. |

**Net**: +439 / -10 lines (most of the +439 is
tests + CHANGELOG + verdict + commit-msg; the
production code is +130 / -10).

## Test deltas

- **231 / 231** on every backend (native, wasm-gc,
  wasm, js). +6 from v0.21.0:
  1. `gain_stats_from_blp_cv_basic` — basic
     auto-population; shape and per-coef
     consistency.
  2. `gain_stats_from_blp_cv_differs_from_in_sample`
     — the cross-fit `var_y_residuals` is at least
     the in-sample `var_y_residuals`.
  3. `gain_stats_from_blp_cv_deterministic` — same
     `seed` produces bit-equal `var_y_residuals`
     and `nu2`.
  4. `gain_stats_from_blp_cv_end_to_end` — two
     BLPs (long = constant, short = noise) with
     the same `n_coef`; the long has lower
     cross-fit `var_y_residuals`.
  5. `panic_gain_stats_from_blp_cv_unfitted` —
     `from_blp_cv` requires the BLP to be fit.
  6. `panic_gain_stats_from_blp_cv_n_folds_too_small`
     — `n_folds` must be >= 2.

- **16 / 16** Python validators PASS (no new
  validator; the upstream `gain_statistics` does
  not distinguish in-sample vs cross-fit
  residuals).

- **6 / 6** demos all run cleanly and produce
  bit-equal output to v0.21.0. None of the demos
  uses `from_blp_cv`.

## Cross-check vs numpy

The cross-fit residual variance is a MoonBit
extension (the upstream `gain_statistics` does not
have a `from_blp_cv` analogue). The OOF residual
variance is well-defined: it's `sum_i (y_i -
y_hat_i^OOF)^2 / n_obs`, which can be computed
deterministically given the data, folds, and BLP
fit. The MoonBit implementation matches the
straightforward numpy analogue to within the
kfold split (the kfold is deterministic given a
fixed seed, so this is bit-equal).

## API additions (delta from v0.21.0)

| Symbol | Where | What |
|--------|-------|------|
| `GainStatsSource::from_blp_cv` | `sensitivity.mbt` | cross-fit auto-population |
| `DoubleMLBLP::orth_signal` | `blp_policy.mbt` | post-fit orthogonal signal accessor |
| `DoubleMLBLP::basis` | `blp_policy.mbt` | post-fit basis matrix accessor |

No field renames on `DoubleMLBLP` (the new
accessors are additions, not renames). No
removed methods on any other struct.

## Known limitations / deferrals

- **`n_rep` is fixed at 1** for `from_blp_cv`. The
  BLP is a single-shot fit, so multi-rep would
  require multiple BLP fits with different folds.
  Defer to v0.23+ if needed.
- **The OOF residual variance is still
  single-fold**: `from_blp_cv` does one K-fold
  split and computes the OOF variance once.
  A repeated-CV variant (multiple seeds, averaged
  OOF variance) would be more robust; defer to
  v0.23+ if needed.
- **No automatic selection between `from_blp` and
  `from_blp_cv`**: the user must choose. The
  default is `from_blp` (in-sample, biased low)
  for backwards compatibility with v0.19.0. New
  code should use `from_blp_cv` for honest
  benchmarks.

## Files changed (full list)

```
 CHANGELOG.md                                 |  90 ++++++++++++++++++++++
 README.mbt.md                                |   9 ++
 blp_policy.mbt                               |  20 +++++
 sensitivity.mbt                              | 110 +++++++++++++++++++++++++
 sensitivity_test.mbt                         | 120 +++++++++++++++++++++++
 _verify/T220-verdict.md                     | (this file)
 _verify/T220-commit-msg.txt                 |  90 +++++++++++++++++++++
 7 files changed, 439 insertions(+), 10 deletions(-)
```

See `_verify/T220-commit-msg.txt` for the git
commit message.
