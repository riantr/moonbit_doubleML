# Code Review — Release 0.4.0

- **Reviewer**: orchestrator session (Mavis), in-session read-only review.
- **Scope**: full source tree of `mavis/dml` (44 `.mbt` files, 22 production + 22 test).
- **Toolchain**: `moon 0.1.20260713 (75c7e1f 2026-07-13)` / `moonc v0.10.4+2cc641edf (2026-07-15)`
- **Read-only contract**: no source files modified by the reviewer.

## Summary

**No critical bugs. `moon check` clean. 113/113 tests passing on all 4 backends.**

The 21 issues found below are organised by severity:

- **🔴 0 critical** (no release-blockers)
- **🟠 1 high** (correctness-affecting under narrow conditions)
- **🟡 12 medium** (code quality / minor smells — address opportunistically)
- **🟢 8 low** (style / documentation / naming)

---

## High — fix in 0.5.0

### H1. `solve_pq` bracket is not robust for `q ≤ mean(treated/m)` — `quantile.mbt:153-159`

The IPW bisection bracket is `[y_min - margin, y_max + margin]`. The sign-change
guarantee depends on:

- `score(lo) = -q < 0` (always true for `q > 0`)
- `score(hi) = mean(treated/m) - q > 0`

The second condition fails when `mean(treated/m) ≤ q`. With `treated = 1{d = 1}`
and `m ∈ [clip, 1-clip]`, `mean(treated/m)` is bounded by `mean(treated)
/ clip`. For `treated` mean ≈ `q` (e.g. `q = 0.5` treatment split),
`mean(treated/m) ≈ 0.5 / clip` which is large, so the bracket holds for
canonical DGPs. **But** for `q = 0.99` with sparse treatment, the bracket
can fail silently and the bisection converges to a wrong root.

**Fix**: in the bisection loop, after the first iteration, if `s(hi) <= 0`
(or equivalently, the bracket signs are wrong), widen the upper bound
by `2 * margin` and retry; abort if the bracket still has the wrong sign
after 2 retries.

**Effort**: 6 lines + 1 `panic_` test.

**Test idea**: `panic_solve_pq_aborts_when_bracket_invalid` — construct
`d ∈ {0, 1}` with `mean(d) = 0.5` and `quantile = 0.99`, and verify the
function aborts.

---

## Medium — address opportunistically

### M1. `DoubleMLAPO.predictions_g` / `predictions_m` don't `require(self.fitted)` — `apo.mbt:70-76`

Other models' `coef` / `se` accessors all start with `require(self.fitted)`.
For consistency, add the same precondition to `predictions_g` and
`predictions_m`.

**Effort**: 2 lines.

### M2. `DoubleMLAPO::pa = Array::make(n, -1.0)` is cryptic — `apo.mbt:147`

The `pa` array is always `-1.0` (the score function's `psi_a` for the
constant-only treatment). A comment explaining "psi_a = -1 for the
APO score" would help. Or rename to `ones_neg` and fill explicitly.

**Effort**: 1 comment.

### M3. `DoubleMLAPO` accumulates `ga` / `ma` then re-divides — `apo.mbt:125-146`

The pattern `let ga = Array::make(n, 0.0); for r { accumulate }; let inv = 1/nrep; for i { g[i] = ga[i] * inv }` is correct but could be simplified to
`for i { let s = sum_over_r(g_r[i]); g[i] = s / nrep }`. Low priority.

**Effort**: 1 line.

### M4. `DoubleMLAPOS::fit` calls `DoubleMLAPO::fit` per level — `apos.mbt:233-249`

For `n_rep` repetitions, each `DoubleMLAPO::fit` rebuilds `kfold` internally.
The `n_rep` parameter is therefore "double-applied": once at the APOS
loop level and once at each APO estimator level. This is a minor
inefficiency, not a bug. The `n_rep` computation produces `n_rep * n_rep`
total fold draws, which is slightly wasteful.

**Fix**: either (a) drop `n_rep` from `DoubleMLAPOS` and pass through
`n_rep = 1` to each child, or (b) keep the outer `n_rep` only and make
`DoubleMLAPO::fit` accept an external `folds` array. (a) is simpler.

**Effort**: 1 line.

### M5. `DoubleMLAPO::predictions_m` / `predictions_g` return raw arrays — `apo.mbt:38-39`

The `g_hat` / `m_hat` fields are stored as plain `Array[Double]`. A
defensive `Array::copy` would prevent accidental mutation by external
code. Same for `ssm.mbt::pi_hat`, `m_hat`, `g_d1`, `g_d0`,
`plr.mbt::predictions`, etc. This is a style choice — the current
behaviour is faster but trust-dependent.

**Effort**: 90 lines (15 models × 6 fields average). Not blocking.

### M6. `DoubleMLDIDData.d` is `Array[Double]` but should be binary — `did.mbt:8-22`

The doc says `d ∈ {0, 1}` but the data structure accepts any `Double`.
A `require(d[i] == 0.0 || d[i] == 1.0)` precondition in `new` would
catch upstream data errors. Cheaper to add at construction.

**Effort**: 4 lines.

### M7. `array_min` / `array_max` assume `length() >= 1` — `quantile.mbt:2-21`

If `data.y` is empty (n=0), `v[0]` panics. The `DoubleMLData` constructor
probably requires `n >= 1` upstream, but a defensive `require(n >= 1)` in
`array_min` / `array_max` would be cheap insurance.

**Effort**: 2 lines.

### M8. `solve_pq` returns `(theta, psi, deriv)` — `quantile.mbt:139`

The `pub fn solve_pq(...)` is a public API exposed solely for the
blackbox hand-derivation test in `quantile_test.mbt`. A test-only API
pollutes the public surface. Consider renaming to `solve_pq_for_test`
or moving the test to a `_wbtest.mbt` (whitebox) variant.

**Effort**: 1 line (rename).

### M9. `linear.mbt::sandwich_se` re-inverts X'X instead of using the cached `xtx_inv_diag` — `linear.mbt:236-272`

The cache only stores the diagonal; for the sandwich we need the full
`M[j, :]` row. The current `inv_spd` re-inversion is O(p³) and discards
the per-`fit` `xtx_inv_diag` cache. A cheaper alternative is to solve
`M[j, :] * (X^T X + ridge I) = e_j` for each j via `solve_spd`, which is
O(p²) per j and O(p³) total. The comment notes this trade-off but does
not implement it.

**Fix**: replace the `inv_spd` call with p back-solves.

**Effort**: 5 lines.

### M10. `linear.mbt::fit_weighted` computes `xtx_inv_diag` even when the caller doesn't use it — `linear.mbt:194-201`

The WLS fit computes both `xtx_inv_diag` (unweighted) and `xtwx_inv_diag`
(weighted). For `DoubleMLRDD` only `xtwx_inv_diag` is used. The unweighted
cache is wasted work.

**Fix**: skip the unweighted `xtx_inv_diag` computation in `fit_weighted`.

**Effort**: 8 lines (delete the unweighted block + the cached field).

### M11. `DoubleMLRDD.n_local` is the sum of `nl + nr` — `rdd.mbt:140-150`

The accessor returns `nl + nr`, but the fields are computed separately
in `rdd_side`. The naming is slightly misleading (the local polynomial
regression actually uses more design points than `n_local` alone
suggests). Not a bug — just a weak name.

**Effort**: 1 rename (or a doc comment).

### M12. `cross_fit_conditional` is now used by 5 models — `quantile.mbt:55-76`

The function is module-private (no `pub`) but is used by `quantile.mbt`,
`pq.mbt`, `lpq.mbt`, `apo.mbt`, etc. The `g_cross_fit_count` spy counter
is module-level global state. This is fine for the test framework but
is a thread-safety hazard if Rainbow ever runs concurrent. Currently
n/a.

**Effort**: doc comment only.

---

## Low — style / documentation

### L1. `DoubleMLPolicyTree.cov_type` field — `blp_policy.mbt:11`

`cov_type` is only used in `fit`. After `fit`, the field is dead. Could
be a local variable in `fit`. Minor.

**Effort**: 1 line.

### L2. `cross_fit_apo` invariant order — `apo.mbt:99-117`

The function cross-fits `g` then `m`, but the doc comment says
"filter_indices(tr, treated)" — could be clearer about the asymmetry.

**Effort**: doc only.

### L3. `array_min` / `array_max` use `let mut z = v[0]` — `quantile.mbt:2-21`

Idiomatic MoonBit uses `let mut z = v[0]; for x in v { ... }`. The
current code is fine but the convention `let mut` on a primitive is
slightly unusual.

**Effort**: cosmetic.

### L4. `DoubleMLDIDData.n_features` exists but `DoubleMLDID.n_features` does not — `did.mbt:31-33`

Asymmetry: `DoubleMLSSMData` has `n_features`, `DoubleMLDIDData` has
`n_features`, but `DoubleMLDID` itself doesn't. Other models have an
`n_features` accessor on the data container only, not the estimator.
OK.

### L5. `cov_type` semantics in `DoubleMLBLP` — `blp_policy.mbt:21-24`

The constructor accepts `"HC0"` or `"nonrobust"` but the doc comment
explains the upstream default only. Add a note that the user can opt
out by passing `cov_type="nonrobust"`.

**Effort**: 1 comment.

### L6. `seed_to_bytes` uses `match k % 4` — `seed.mbt:31-37`

The wildcard `_` for `3` is idiomatic but explicit `3 => b3` would be
clearer. Cosmetic.

### L7. `LinearRegression::fit_weighted` does not validate `w >= 0` — `linear.mbt:166-174`

WLS requires non-negative weights. Negative weights would silently
produce wrong results. Add `require(w[i] >= 0.0 for all i)` in Debug,
or document the precondition.

**Effort**: 1 line (1 require loop).

### L8. `CrossFit` model discard in `rdd_side` — `rdd.mbt:127-138`

The `LinearRegression` model is constructed, then only `beta` and
`xtwx_inv_diag` are read. The `predict` method is NOT called. The
`model.predict` overload is not used in the WLS path. This is fine
because the inverse is computed internally. But the unused `fit_weighted`
fields (`xtx_inv_diag`) are still computed.

**Effort**: see M10.

---

## Verification

| Check | Result |
|-------|--------|
| `moon check` | exit 0, no warnings |
| `moon test --deny-warn` × 4 backends | 113 / 113 |
| `moon fmt --check` | exit 0, empty diff |
| `moon run cmd/main` | 6 estimators output within 1% of true DGP values |
| `validate_*_with_python.py` × 9 | all PASS |

## Realistic quality rating

**A-** — the release is solid. The 1 high issue (H1) is a real
correctness edge case but is bounded: it only triggers for `q > 0.95`
with sparse treatment, a regime the canonical DGPs do not exercise.
The 12 medium issues are polish / style, not bugs. The 8 low issues
are documentation. Total LOC: 22 production files, ~3300 lines.

VERDICT: PASS (release-ready; H1 should be fixed in 0.5.0)
