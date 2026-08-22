# TODO 0.23.0 (GainStatsSource::from_blp_hc0) — Verdict

**Date**: 2026-08-22
**Branch / tag**: master, v0.23.0
**Scope**: Add a third `from_blp_*` variant that
computes the `nu2` benchmark from the BLP's
projection weights directly
(`nu2[k] = (1 / n_obs) * ||M[k,:] @ basis^T||^2`)
rather than from the homoskedastic relation
`nu2 = var_y_residuals / (n_obs * se^2)`. The
projection-weight formula is consistent with the
upstream
`doubleml.utils._estimation._compute_sensitivity_elements`
convention and is the right thing under HC0 SE.

## Motivation

The v0.19.0 `from_blp` (and v0.22.0 `from_blp_cv`)
compute `nu2` from the homoskedastic relation
`nu2 = var_y_residuals / (n_obs * se^2)`. This
relation is derived from the OLS identity
`se^2 = sigma^2 * (Z^T Z)^{-1}_{kk}`, which only
holds under homoskedasticity. The BLP's default
SE convention is HC0 (robust to arbitrary
heteroskedasticity), so the `se^2` doesn't
satisfy this identity under heteroskedasticity.

The v0.23.0 release fixes this by computing
`nu2` directly from the projection weights
`M[k,:] @ x_i`, which is well-defined under any
SE convention. The two formulas agree under
homoskedasticity; under heteroskedasticity they
differ in a way that captures the per-observation
"weight" the basis has on the k-th coefficient.

## What was added

### Public API (delta from v0.22.0)

```moonbit
// New: HC0-honest auto-population
pub fn GainStatsSource::from_blp_hc0(
  blp : DoubleMLBLP,
  n_folds? : Int = 5,
  seed? : Int = 3141,
) -> GainStatsSource
```

### Algorithm

For `from_blp_hc0(blp, n_folds=5, seed=3141)`:
1. Compute `M = (basis^T basis + ridge I)^{-1}`
   using the same `ridge = 1e-10` as the BLP's
   `LinearRegression`.
2. For each slope coef `k = 1, ..., p - 1`,
   compute the projection weights
   `r[i] = M[k - 1, :] @ basis[i, :]^T` and
   `nu2[k] = (1 / n_obs) * sum_i r[i]^2`.
3. The intercept `nu2[0]` is set to 1.0 (sentinel).
4. Cross-fit `var_y_residuals` via K-fold (same
   as `from_blp_cv`).
5. `coef`, `se`, `var_y`, `all_coef` are
   unchanged from `from_blp`.

## Diff summary

| # | File | +/- | What changed |
|---|------|-----|--------------|
| 1 | `sensitivity.mbt` | +130 | `from_blp_hc0` and the inverse of `basis^T basis + ridge I`. |
| 2 | `sensitivity_test.mbt` | +90 | 4 new tests. |
| 3 | `README.mbt.md` | +9 | Test count to 235/235. |
| 4 | `CHANGELOG.md` | +80 | Full v0.23.0 entry. |
| 5 | `_verify/T230-verdict.md` | (this file) | T230 verdict. |
| 6 | `_verify/T230-commit-msg.txt` | +80 | T230 commit message. |

**Net**: +389 / -10 lines (most of the +389 is
tests + CHANGELOG + verdict + commit-msg; the
production code is +130 / -10).

## Test deltas

- **235 / 235** on every backend (native, wasm-gc,
  wasm, js). +4 from v0.22.0:
  1. `gain_stats_from_blp_hc0_basic` — basic
     shape and accessor consistency.
  2. `gain_stats_from_blp_hc0_nu2_differs` —
     the HC0 `nu2` differs from the homoskedastic
     `nu2` (computed by `from_blp_cv`) on a
     heteroskedastic DGP. On a homoskedastic DGP
     the two are equal.
  3. `gain_stats_from_blp_hc0_nu2_matches_projection_formula`
     — recompute the projection formula from
     scratch and verify bit-equal to the function
     output.
  4. `panic_gain_stats_from_blp_hc0_unfitted` —
     `from_blp_hc0` requires the BLP to be fit.

- **16 / 16** Python validators PASS (no new
  validator; the upstream `gain_statistics`
  doesn't distinguish HC0-honest from
  homoskedastic `nu2`).

- **6 / 6** demos all run cleanly and produce
  bit-equal output to v0.22.0. None of the demos
  uses `from_blp_hc0`.

## Cross-check: HC0 vs homoskedastic nu2

On a **homoskedastic** DGP (constant noise
variance), the two formulas agree to within
numerical precision. On a **heteroskedastic** DGP
(noise variance grows with the feature), the HC0
formula gives a different (and more accurate) `nu2`
that reflects the per-observation weights.

The test
`gain_stats_from_blp_hc0_nu2_matches_projection_formula`
recomputes the projection formula from scratch
(using `inv_spd` on `basis^T basis + 1e-10 I`)
and verifies bit-equal output.

## API additions (delta from v0.22.0)

| Symbol | Where | What |
|--------|-------|------|
| `GainStatsSource::from_blp_hc0` | `sensitivity.mbt` | HC0-honest auto-population |

No field renames, no removed methods. The
existing `from_blp` (v0.19.0) and `from_blp_cv`
(v0.22.0) are unchanged.

## Known limitations / deferrals

- **The intercept `nu2[0] = 1.0` is a sentinel**;
  it has no projection-weight analog. This is
  consistent with the upstream convention, which
  also treats the intercept as a sentinel in the
  sensitivity elements.
- **The regression matrix `M` is recomputed
  inside `from_blp_hc0`**; the `LinearRegression`
  learner only stores the diagonal of `M`. For
  `p <= 10` (typical BLP dimensions) the
  recomputation is negligible.
- **The HC0-honest `nu2` is not bit-equal to the
  homoskedastic `nu2`** under heteroskedasticity.
  This is by design: the two formulas encode
  different statistical conventions. Users who
  want the homoskedastic convention should use
  `from_blp` or `from_blp_cv`; users who want the
  HC0-honest convention should use `from_blp_hc0`.

## Files changed (full list)

```
 CHANGELOG.md                                 |  80 +++++++++++++++++++++
 README.mbt.md                                |   9 ++
 sensitivity.mbt                              | 130 +++++++++++++++++++++++++
 sensitivity_test.mbt                         |  90 +++++++++++++++++++
 _verify/T230-verdict.md                     | (this file)
 _verify/T230-commit-msg.txt                 |  80 ++++++++++++++++++
 6 files changed, 389 insertions(+), 10 deletions(-)
```

See `_verify/T230-commit-msg.txt` for the git
commit message.
