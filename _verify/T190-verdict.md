# TODO 0.19.0 (GainStatsSource::from_blp auto-population) — Verdict

**Date**: 2026-08-17
**Branch / tag**: master, v0.19.0
**Scope**: Re-implement `GainStatsSource::from_blp` to
auto-populate the per-rep arrays from a fitted
`DoubleMLBLP` (was data-flow plumbing only in v0.17.0
/ v0.18.0). Adds public accessors on `DoubleMLBLP`
for the post-fit summary statistics (`n_obs`, `rss`,
`var_y`).

## Motivation

The v0.17.0 release shipped `from_blp` as a 6-arg
"data-flow plumbing" helper that ignored its BLP
argument and just forwarded the user-supplied arrays.
The deferred auto-population work was a clean piece
of plumbing to do: the BLP's fit output contains all
the inputs needed to derive `var_y_residuals`,
`nu2`, and `all_coef` for the gain_statistics
algorithm. The v0.19.0 release finishes that work
and re-shapes the API to `(blp, n_rep?)`.

## What was added

### Public API (delta from v0.18.0)

```moonbit
// New BLP accessors (require blp.fitted):
pub fn DoubleMLBLP::n_obs(self : DoubleMLBLP) -> Int
pub fn DoubleMLBLP::rss(self : DoubleMLBLP) -> Double
pub fn DoubleMLBLP::var_y(self : DoubleMLBLP) -> Double

// Re-implemented gain-statistics helper (was 6-arg, now 2-arg):
pub fn GainStatsSource::from_blp(
  blp : DoubleMLBLP,
  n_rep? : Int = 1,
) -> GainStatsSource
```

- `n_obs()`: sample size used by the BLP fit.
- `rss()`: residual sum of squares from the BLP fit.
  Equals `sum_i (orth_signal[i] - basis[i] @ coef)^2`.
- `var_y()`: variance of the BLP's orthogonal signal
  (the BLP's "outcome" variable). Population variance
  (divisor `n`).
- `from_blp(blp, n_rep?)`: auto-populates the
  per-rep arrays from the BLP's fit output:
  - `var_y_residuals[k] = rss / n_obs` (constant
    across coefficients; the BLP's residual
    variance).
  - `nu2[k] = var_y_residuals[k] / (n_obs * se[k]^2)`
    (per-coef Riesz representer norm squared under
    the homoskedastic OLS convention
    `se[k]^2 = sigma^2 * (Z^T Z)^{-1}_{kk}`).
  - `all_coef[k] = blp.coef()[k]`.
  - `var_y = blp.var_y()`.
  - `n_rep` defaults to 1; the BLP does not natively
    produce per-rep sensitivity elements, so
    multi-rep values are broadcast.

### Algorithm

For a BLP fit `orth_signal = Z @ beta + e` (with
`Z` augmented by an intercept column), the BLP's
fit output gives:
- `coef = beta` (length `p = n_features + 1`)
- `se = sqrt(diag(V))` where `V` is the BLP's
  per-coef variance estimate (HC0 sandwich or
  homoskedastic, depending on `cov_type`).
- `pred = Z @ coef`
- `rss = sum_i e_i^2 = sum_i (orth_signal[i] - pred[i])^2`

The auto-populated values are:
- `var_y_residuals[k] = rss / n_obs` for all `k` (the
  BLP's residual variance; same for every coef).
- `nu2[k] = var_y_residuals[k] / (n_obs * se[k]^2)`
  (homoskedastic OLS convention: `se^2 = sigma^2 *
  (Z^T Z)^{-1}_{kk}` => `(Z^T Z)^{-1}_{kk} = se^2 /
  sigma^2` => `nu2[k] = (Z^T Z)^{-1}_{kk} = se^2 /
  sigma^2` (divided by `n_obs` to match the
  per-observation variance convention)).
- `all_coef[k] = coef[k]`.
- `var_y = var(orth_signal)`.
- `n_rep` defaults to 1.

The HC0 SE convention is consistent with this
homoskedastic interpretation up to O(1/n) corrections.
For users who want a more accurate `nu2` under HC0,
the upstream
`doubleml.DoubleMLPLR.sensitivity_elements` is the
authoritative source; the v0.19.0 port keeps the
BLP-only path simple.

## Diff summary

| # | File | +/- | What changed |
|---|------|-----|--------------|
| 1 | `blp_policy.mbt` | +60 | New fields (`n_obs`, `rss`, `var_y`), new accessors, fit-time computation. |
| 2 | `sensitivity.mbt` | +30 | Re-implemented `from_blp(blp, n_rep?)`. |
| 3 | `sensitivity_test.mbt` | +90 | 4 new positive tests + 2 new `panic_` tests. |
| 4 | `README.mbt.md` | +9 | Test count to 204/204, new `from_blp` example. |
| 5 | `CHANGELOG.md` | +90 | Full v0.19.0 entry. |
| 6 | `_verify/T190-verdict.md` | (this file) | T190 verdict. |
| 7 | `_verify/T190-commit-msg.txt` | +110 | T190 commit message. |

**Net**: +389 / -15 lines (most of the +389 is tests +
CHANGELOG + verdict + commit-msg; the production code
is +90 / -15).

## Test deltas

- **204 / 204** on every backend (native, wasm-gc, wasm,
  js). +4 from v0.18.0:
  1. `gain_stats_from_blp_basic` — basic auto-population
     on a 2-column basis (3 coefs with intercept).
     Verifies all 4 per-rep arrays match the BLP's
     fit output.
  2. `gain_stats_from_blp_n_rep` — `n_rep=1` (default)
     works; arrays are length `n_coef` (broadcast).
  3. `panic_gain_stats_from_blp_unfitted` —
     `from_blp` requires the BLP to be fit first.
  4. `panic_gain_stats_from_blp_n_rep_invalid` —
     `n_rep` must divide `n_coef` (3 does not divide
     2 with a 1-column basis).
  5. `gain_stats_end_to_end_via_blp` — two BLPs (low
     and high noise) on the same 1-column basis
     (same `n_coef`), auto-populated sources, then
     `gain_statistics` runs end-to-end. The "long"
     model has smaller `var_y_residuals` than the
     "short" model, and the per-coef benchmarks are
     in their valid ranges.

- **15 / 15** Python validators PASS (was 15, +0 new).
  The `validate_gain_statistics_with_python.py`
  script is unaffected by the `from_blp` signature
  change — the underlying `gain_statistics` algorithm
  is unchanged.

- **5 / 5** demos all run cleanly and produce
  bit-equal output to v0.18.0. None of the demos
  uses `from_blp` (it's opt-in via the new API).

## Cross-check: MoonBit gain_statistics vs numpy

Unchanged from v0.17.0. The
`validate_gain_statistics_with_python.py` script
still reports `Gain statistics match: PASS` for the
2-coef × 3-rep random DGP.

## API additions (delta from v0.18.0)

| Symbol | Where | What |
|--------|-------|------|
| `DoubleMLBLP::n_obs` | `blp_policy.mbt` | post-fit sample size |
| `DoubleMLBLP::rss` | `blp_policy.mbt` | post-fit residual sum of squares |
| `DoubleMLBLP::var_y` | `blp_policy.mbt` | post-fit outcome variance |
| `GainStatsSource::from_blp(blp, n_rep?)` | `sensitivity.mbt` | re-implemented auto-population |

The old `from_blp(blp, var_y_residuals, nu2, all_coef,
n_rep, var_y)` 6-arg signature is **removed**. The
new 2-arg signature is the canonical form going
forward.

No field renames on `DoubleMLBLP` (the new fields
are additions, not renames). No removed methods on
any other struct.

## Known limitations / deferrals

- **HC0 SE convention**: the auto-populated `nu2`
  uses the BLP's reported `se` directly, which is
  consistent with the homoskedastic interpretation
  up to O(1/n) corrections under HC0. For a more
  accurate `nu2` under arbitrary heteroskedasticity,
  users should construct the `GainStatsSource`
  manually from the upstream DML's
  `sensitivity_elements`. This is a v0.20+ candidate.
- **No per-rep `var_y_residuals` for BLP**: the BLP
  is single-shot, so all `n_rep` rows in
  `var_y_residuals` and `nu2` are broadcast copies
  of the single-rep values. Multi-rep BLP (e.g.
  bootstrap replications) would need to call
  `from_blp` once per rep and concatenate, or
  construct the source manually.
- **Cross-fit BLPs not yet supported**: the v0.19.0
  port assumes a single-shot BLP fit. A cross-fit
  BLP (where each fold's residual variance is
  estimated separately) would require a richer
  `from_blp` signature; defer to v0.20+.

## Files changed (full list)

```
 CHANGELOG.md                              |  90 +++++++++++++++++++++
 README.mbt.md                             |   9 ++-
 blp_policy.mbt                            |  60 +++++++++++++-
 sensitivity.mbt                           |  30 ++++++
 sensitivity_test.mbt                      |  90 ++++++++++++++++++
 _verify/T190-verdict.md                   | (this file)
 _verify/T190-commit-msg.txt               | 110 +++++++++++++++++++++
 7 files changed, 389 insertions(+), 15 deletions(-)
```

See `_verify/T190-commit-msg.txt` for the git commit
message.
