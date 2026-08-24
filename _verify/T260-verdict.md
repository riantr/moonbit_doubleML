# T260 verdict: v0.25.0 nine-step QA battery

Release gate for `from_blp_cv_repeated` plus the accumulated
v0.24.1-uncommitted surface. All steps executed in the user's
specified order on 2026-08-24.

## Results summary

| # | Step | Tool / method | Result |
|---|------|---------------|--------|
| 1 | Format check | `moon fmt` + git status diff | CLEAN |
| 2 | SAST | `moon check --deny-warn` + pattern scans | PASS (0 warnings, no secrets, no FFI) |
| 3 | Duplicate code | `_verify/dupcheck.py` sliding-window hash | 14-line dup found -> fixed -> 0 |
| 4 | Dependency check | moon.mod / moon.pkg / pip imports | PASS (+ fixed stale version 0.8.0 -> 0.25.0) |
| 5 | Unit tests | `moon test --target all --deny-warn` | 248/248 x4 backends |
| 6 | Gherkin | `features/dml_acceptance.feature` | 10 scenarios mapped to tests (documented) |
| 7 | Mutation testing | 5 hand-rolled mutants | 5/5 killed after test strengthening |
| 8 | Fuzzing | `cmd/fuzz` 6 surfaces x 300 trials | 0 violations, 0 warnings |
| 9 | Component tests | 7 cmd components with output assertions | ALL PASS |

## Step 3 detail: duplicate code
- Scanner: normalized lines (strip comments/whitespace), MD5
  windows of >= 12 consecutive lines across 31 production files,
  chain-merged into maximal regions.
- Finding: `did_multi.mbt` tsbh/tsby shared an identical Storey
  m0_hat block (estimator + clamping).
- Fix: extracted `storey_m0_hat(unadjusted) -> Double`; both
  functions now call it. Re-scan reports 0 duplicated blocks.
- Test suite unchanged and green after refactor (248/248).

## Step 6 detail: Gherkin
MoonBit has no Cucumber/step-definition runner. The feature file
is the acceptance-criteria documentation layer; each scenario
carries a comment naming the executable MoonBit test that
implements it. Scenarios cover: universal/all/standard keyword
expansion, placebo estimates, cv_repeated stability contract,
and two-stage FDR behavior. A scenario is failing iff its mapped
test fails.

## Step 7 detail: mutation testing
Backups of target files were taken before mutation (working tree
was uncommitted); mutants were reverted by restoring backups or
inverse edits; probe prints were removed afterward.

| Mutant | File | Change | Killed by |
|--------|------|--------|-----------|
| M1 | did_multi.mbt expand_gt_keyword universal branch `t != g` -> `t == g` | semantic inversion | did_multi_universal_includes_pre_treatment, ..._placebo (2 tests) |
| M2 | sensitivity.mbt from_blp_cv_repeated denominator `(n_repeats * n_obs)` -> `(1 * n_obs)` | inflates variance n_repeatsx | initially SURVIVED; after strengthening: gain_stats_from_blp_cv_repeated_smooths_estimate |
| M3 | did_multi.mbt bh_fdr_p_adjust scale `n_d` -> `n_d + 1.0` | BH inflation | bh_fdr_handrolled, bh_by_vs_statsmodels_reference (2 tests) |
| M4 | did_cross_section.mbt norm_cdf b1 `0.319381530` -> `0.638763060` | A&S coefficient doubling | did_cross_section_norm_ppf_975 (ppf inherits cdf error) |
| M5 | did_multi.mbt box_muller_normal drops `.sqrt()` | wrong distribution moments | bootstrap_weight_normal_moments, bootstrap_weight_wild_moments, did_cross_section_bootstrap_moments (3 tests) |

### M2 survival analysis (the valuable find)
The original smooths test compared three values with an absolute
tolerance of 1e-10 against a range computed from them. The helper
`rng_double2(i)` used `(i+1)*7 mod p`, producing noise affine in
`i` — perfectly predictable from the basis columns — so all OOF
residual variances collapsed to ~1e-25 and every comparison was
vacuously true under any scaling bug. Fixes:
1. `rng_double2` now draws from a fresh per-index chacha8 stream
   (`chacha8_rng(i+1).double() - 0.5`) — genuinely non-affine.
2. Assertions changed to a relative band `[lo/2, hi*1.5]` plus
   degenerate-DGP guards `v_a > 1e-6`, `v_b > 1e-6`.
Re-run with mutant: killed. Re-run without mutant: 248/248 green.

## Step 8 detail: fuzzing
No libFuzzer/AFL integration exists for MoonBit; the harness is a
deterministic property-based fuzzer (fixed master seed, per-surface
derived RNGs, abort-with-message on first violated invariant).
Surfaces:
1. p_adjust family (bh/by/tsbh/tsby/holm/bonferroni): length
   preserved, outputs in [0,1], holm/bonferroni pointwise >= input.
2. kfold: every index in exactly one test fold, train/test sizes
   sum to n_obs, fold sizes balanced within 1.
3. matmul associativity ((A·B)·C == A·(B·C), rel tol 1e-9).
4. LinearRegression normal equations: residuals orthogonal to the
   implicit intercept column and every feature column.
   NOTE: an initial exact-interpolation invariant (Vandermonde)
   aborted mid-fuzz — not a library bug: LinearRegression augments
   an intercept internally (making the system n x (n+1) +
   ridge 1e-10) and Vandermonde conditioning makes interpolation
   meaningless there. Replaced with the normal-equation invariant,
   which is the defining OLS property.
5. norm_ppf/norm_cdf inverse consistency over random p in
   (0.001, 0.999).
6. romano_wolf_p_adjust length + range invariants over random
   t-stat blocks.

## Step 9 detail: component assertions
- cmd/main: PLR theta 1.092 in [0.8, 1.2] (true = 1.0).
- cmd/datasets: PLR 1.4844 / IRM 1.4707 both in [1.3, 1.7]
  (true = 1.5), 95% CI printed.
- cmd/did_binary: ATT 1.00035 in [0.995, 1.005], CI printed.
- cmd/did_cs: 2 cells with covers=true.
- cmd/did_multi: exactly 3 standard CIs cover=true; Universal
  mode section present with n_combos=9 and pre-treatment max|coef|=0.
- cmd/did_cross_section: pointwise + joint bootstrap CI both
  covers=true (ATT 1.0024 vs true 1.0).
- cmd/fuzz: "ALL FUZZ SURFACES PASSED".

## Side effects included in this release
- `storey_m0_hat` extraction (dedup fix).
- Strengthened smooths test + non-affine rng_double2 helper.
- New files: `features/dml_acceptance.feature`, `cmd/fuzz/{main.mbt,moon.pkg}`,
  `_verify/dupcheck.py`.
- `moon.mod` version bumped to 0.25.0.
- `.gitignore`: added `_verify/mut-bak-*`.

## Verdict
PASS on all nine gates. Release tagged v0.25.0.
