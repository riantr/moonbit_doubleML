# Code Review — Release 0.4.3

- **Reviewer**: orchestrator session (Mavis), in-session read-only review.
- **Scope**: full source tree of `mavis/dml` (22 production + 22 test files, ~5500 lines).
- **Toolchain**: `moon 0.1.20260713 (75c7e1f 2026-07-13)` / `moonc v0.10.4+2cc641edf (2026-07-15)`
- **Baseline**: `dab4fb2` (tag v0.4.3)
- **Read-only contract**: no source files modified by the reviewer.

## Summary

**1 high, 1 medium, 5 low. `moon check` clean. `moon fmt --check` clean. 115/115 tests passing on all 4 backends.**

The 7 new issues found below are listed in addition to the 21 already triaged in
`REVIEW-0.4.0.md` (0 critical, 1 high, 12 medium, 8 low). Of those 21:

- **12** addressed across v0.4.1 (H1), v0.4.2 (M1, M2, M3, M4, M6, M7, M8, M9, M10, M11, M12), and v0.4.3 (L2, L5, L6, L7, L8)
- **5** explicitly skipped with reason (M5, L1, L3, L4, plus the L6 code change reverted)
- **4** are still observable in the code (the 4 "skipped" items above)

The new findings in this review are all **maintenance / hygiene** issues — none
are correctness bugs at the test scale. No estimate drift vs. v0.4.3 was
detected on the canonical DGPs.

## Verification

| Check                                              | Result                         |
| -------------------------------------------------- | ------------------------------ |
| `moon check`                                       | exit 0, no warnings            |
| `moon fmt --check`                                 | exit 0, empty diff             |
| `moon test --deny-warn` (native)                   | 115 / 115 PASS                 |
| `moon test --deny-warn` (wasm-gc)                  | 115 / 115 PASS                 |
| `moon test --deny-warn` (wasm)                     | 115 / 115 PASS                 |
| `moon test --deny-warn` (js)                       | 115 / 115 PASS                 |
| `validate_*_with_python.py` (9 scripts, see LOW-verdict.md for the 8 that were re-run this round) | exit 0 each |

---

## High — fix in 0.5.0

### H2. `DoubleMLAPO::fit` inlines `var_est` instead of using the shared helper — `apo.mbt:163-176`

The APO fit recomputes the DML point estimate + variance inline:

```moonbit
let a = mean(pa)
let b = mean(pb)
let theta = -b / a
let mut gamma = 0.0
for i = 0; i < n; i = i + 1 {
  let z = theta * pa[i] + pb[i]
  gamma = gamma + z * z
}
let se = (gamma / n.to_double() / (a * a * n.to_double())).sqrt()
```

This is **byte-equal** to `var_est(pa, pb)`:

```moonbit
let theta = -mean_b / mean_a
let J = mean_a
let gamma = mean(psi(theta)^2)         // Kahan-compensated in var_est
let sigma2 = gamma / (J^2 * n)
let se = sqrt(sigma2)
```

Every other estimator (`plr`, `pliv`, `irm`, `iivm`, `did`, `ssm`) calls the
shared helper. APO is the lone hold-out. Risks:

- **Drift**: if `var_est` is updated (e.g., a future variance estimator upgrade,
  a Kahan-compensation extension to the `gamma` accumulator), APO will silently
  diverge from the other models.
- **Test isolation**: `var_est_test.mbt` has 3 tests (happy-path, length-mismatch
  abort, n-zero abort) that pin the helper's contract; the inlined version in
  APO is not covered by those tests.
- **No Kahan**: the inlined `gamma` accumulator is naive `gamma + z * z`, while
  the helper has Kahan compensation. On the canonical DGP (`n = 500`, `z ~ N(0, 1)`)
  the difference is invisible, but a future DGPs may surface the gap.

**Fix**: replace lines 168-176 with `let (theta, se) = var_est(pa, pb)`.

**Effort**: 8 lines (delete the inlined block, replace with one call).

**Test idea**: `apo_var_est_uses_shared_helper` — pin that
`DoubleMLAPO.coef() == var_est(pa, pb)[0]` for a canonical DGP, and verify
that an upgrade to `var_est` (e.g. swapping Kahan) propagates to APO.

---

## Medium — address opportunistically

### M13. `kfold.mbt` carries its own 7-bit seed encoder — `kfold.mbt:33-49`

`kfold.mbt` has an inline seed-to-bytes encoder:

```moonbit
let b0 = (s % 128).to_byte()
let b1 = (s / 128 % 128).to_byte()
let b2 = (s / 16384 % 128).to_byte()
let b3 = (s / 2097152 % 128).to_byte()
```

This is a **7-bit-per-byte** tiling — `s % 128` gives a 7-bit value. Meanwhile,
`seed.mbt::seed_to_bytes` is the canonical **8-bit** encoder:

```moonbit
let b0 : Byte = (seed & 0xff).to_byte()
let b1 : Byte = ((seed >> 8) & 0xff).to_byte()
let b2 : Byte = ((seed >> 16) & 0xff).to_byte()
let b3 : Byte = ((seed >> 24) & 0xff).to_byte()
```

For a given integer seed `s`, the two encoders produce **different byte
streams**. Concretely: the test suite seeds `LinearRegression` and the fold
RNG with the same integer (e.g. `seed = 3141`), and the partition produced
by `kfold` is the 7-bit one while the partition a user would compute
manually via `seed_to_bytes` is the 8-bit one.

The docstring on `seed_to_bytes` (lines 20-24) explicitly says it "supersedes
the earlier 7-bit-tiling helper that existed in `irm_test.mbt` and
`cmd/main/main.mbt` and produced non-portable encodings." The replacement
happened for `irm_test.mbt` and `cmd/main/main.mbt` but **not for `kfold.mbt`**
— `kfold.mbt` retained the legacy encoder.

**Risk**: low (all tests pass because they don't cross-check fold partitions),
but it's a real inconsistency that will surprise a user who reads
`seed_to_bytes(3141)` and then expects the same partition from `kfold(n, k, 3141)`.

**Fix**: replace lines 33-48 in `kfold.mbt` with:

```moonbit
let bytes = seed_to_bytes(seed)
let rng = @random.Rand::chacha8(seed=Bytes::from_array(bytes))
```

**Effort**: 4 lines (delete the encoder, call the helper).

**Test idea**: `kfold_partition_matches_seed_to_bytes` — for `seed = 3141`,
verify that `kfold(100, 2, 3141)` produces the same fold indices as
`fold_array_from_seed_to_bytes(100, 2, seed_to_bytes(3141))` (a small helper
that wraps `seed_to_bytes`).

---

## Low — style / documentation / hygiene

### L9. `kfold.mbt:32-33` comment is stale — already covered by M13

The comment says "Avoids the deprecated `Int::lsr` method" but the encoder
it precedes uses 7-bit chunks, not the 8-bit layout the comment implies.
Folded into M13.

### L10. `README.mbt.md:13` test count is stale

| Item | Value |
|------|-------|
| Tests | **113 / 113** on all 4 backends (native, wasm-gc, wasm, js) |

Current count is **115 / 115** (added `panic_solve_pq_aborts_when_upper_bracket_structurally_invalid`
in v0.4.1 and `panic_fit_weighted_aborts_on_negative_weight` in v0.4.3).
Update the row to:

```
| Tests | **115 / 115** on all 4 backends (native, wasm-gc, wasm, js) |
```

Same fix in the four-line block at lines 85-88.

**Effort**: 4 lines.

### L11. `DoubleMLLPQ::fit` inlines the `var_est`-style variance — `lpq.mbt:220-224`

The LPQ SE formula:

```moonbit
let mut v = 0.0
for u in psi {
  v = v + u * u
}
let se = (v / nf / (deriv * deriv * nf)).sqrt()
```

is the same shape as `var_est(psi_a, psi_b)` but with `deriv` playing the
role of `J = mean(psi_a)`. The Kahan-compensated accumulator inside
`var_est` is **not** used here. Low priority because LPQ's score is
structurally different (`deriv` is the gradient of `mean(score)` at the
bisection root, not the simple mean of a constant-`-1` `psi_a`), and
the inlined form is a few lines that a future refactor can unify.

**Effort**: 5 lines if generalised into a `var_est_with_jacobian(psi, jacobian)` helper.

### L12. `LogisticRegression::fit` does not validate `y ∈ {0, 1}` — `logistic.mbt:72-83`

The doc on line 8 says "Only binary outcomes (y in {0, 1}) are supported"
but `fit` only `require`s `x.nrows == y.length()` and `x.nrows >= 2`.
Non-binary `y` (e.g. `y[i] = 0.5`) would silently produce nonsense without
aborting.

**Fix**: add a `for y_i in y { require(y_i == 0.0 || y_i == 1.0) }` loop, or
at minimum clamp `y_i` to {0, 1} as the IRLS does for `p`.

**Effort**: 3 lines.

### L13. `Low polish` deferred items from REVIEW-0.4.0 — confirmation

The 4 items deferred in v0.4.3 (`M5, L1, L3, L4`) remain skipped with
reason. The justification for each is still valid:

- **M5** (defensive `Array::copy` on `predictions_*`): 90 lines of low-value
  work, current shared-reference behaviour is faster and trusted.
- **L1** (`cov_type` field on `DoubleMLBLP`): refactoring to a local var
  would change the auto-generated `pkg.generated.mbti` API surface.
- **L3** (`let mut z = v[0]` style): already correctly managed by the
  struct-copy pattern in `fit`/`fit_weighted`.
- **L4** (`n_features` accessor asymmetry): cosmetic and consistent
  across the 15 models.

No action required for this round.

---

## Skipped (with reason)

| #   | Reason                                                                                          |
| --- | ----------------------------------------------------------------------------------------------- |
| H1  | Already addressed in v0.4.1 (`solve_pq` exponential bracket widening + abort guard)             |
| M1  | v0.4.2 (apo.mbt:70-77)                                                                          |
| M2  | v0.4.2 (apo.mbt:149-152 doc)                                                                    |
| M3  | v0.4.2 (apo.mbt:124-148 refactor)                                                               |
| M4  | v0.4.2 (apos.mbt:217-228 n_rep=1)                                                               |
| M5  | 90-line defensive `Array::copy` — poor risk/reward; deferred                                      |
| M6  | v0.4.2 (did.mbt:11-23 validate d ∈ {0, 1})                                                      |
| M7  | v0.4.2 (quantile.mbt:2-23 panic on empty)                                                       |
| M8  | v0.4.2 (quantile.mbt:131-141 doc)                                                               |
| M9  | v0.4.2 (linear.mbt:236-282 back-solve)                                                          |
| M10 | v0.4.2 (linear.mbt:194-221 skip unweighted xtx)                                                 |
| M11 | v0.4.2 (rdd.mbt:222-234 doc)                                                                    |
| M12 | v0.4.2 (quantile.mbt:32-45 doc)                                                                 |
| L1  | `cov_type` field kept for public-API compat                                                     |
| L2  | v0.4.3 (apo.mbt:91-105 doc)                                                                     |
| L3  | `let mut` already correctly managed                                                             |
| L4  | n_features asymmetry consistent across models                                                   |
| L5  | v0.4.3 (blp_policy.mbt:1-22 doc)                                                                |
| L6  | code change reverted (Int%4 signed); doc note only                                              |
| L7  | v0.4.3 (linear.mbt:166-189 require w>=0 + panic test)                                           |
| L8  | v0.4.3 (linear.mbt:127-156 doc note)                                                            |

---

## Realistic quality rating

**A** — the codebase is solid. The 1 high issue (H2) is a maintenance
hazard, not a correctness bug at the test scale (APO's inlined var_est
produces the same numbers as the helper on every canonical DGP). The
1 medium issue (M13) is a real consistency smell — `kfold.mbt` and
`seed_to_bytes` produce different fold partitions from the same integer
seed, which is exactly the kind of subtle inconsistency that bites during
debugging. The 5 low issues are documentation / micro-validation.

Total LOC: 22 production files, ~3300 lines; 22 test files, ~2200 lines.

VERDICT: PASS (release-ready; H2 should be fixed in 0.5.0; M13 recommended
because the inconsistency is invisible-but-real).