# T290 verdict: v0.28.0 nine-step QA battery

Release gate for cluster-robust inference on
`DoubleMLPLR` / `DoubleMLIRM` (port of upstream
`DoubleMLData(cluster_cols=...)`). All steps executed in the
user's specified order on 2026-08-27.

## Pre-gate work included in this release

1. **Diagnostic round 1 (cluster SE == row SE)**: the first
   port of `DoubleMLPLR::fit_cluster` reported a cluster SE
   bit-equal to the row-level SE on the same data. Empirical
   trace showed `fit_cluster` was being called correctly with
   the cluster-respecting fold mask, but the comparison test
   *built the row-level twin with the same `build_clustered_dgp`
   helper* — which itself passed `cluster_vars` internally,
   so both fits took the cluster-robust path. Fixed by adding
   a `cluster? : Bool` parameter (later replaced with a
   separate `build_row_dgp` helper that omits `cluster_vars`)
   so the two fits actually take different paths. After this
   fix, cluster SE / row SE = 1.6 (matching upstream's 1.5-1.6
   pattern on the same DGP).

2. **Dedup**: the unit→row fold-expansion logic was the same
   12-line block in `plr.mbt`, `irm.mbt`, and `plpr.mbt`.
   Extracted to `expand_unit_folds_to_rows` +
   `build_row_unit_map` in `kfold.mbt`. Dupcheck: 0 blocks.

## Results summary

| # | Step | Tool / method | Result |
|---|------|---------------|--------|
| 1 | Format check | moon fmt + MD5 hash diff over .mbt | CLEAN |
| 2 | SAST | moon check --deny-warn + pattern scans | PASS (0 warnings, no secrets, no FFI, TODOs historical) |
| 3 | Duplicate code | _verify/dupcheck.py >=12-line windows | 0 blocks over 33 files |
| 4 | Dependency check | moon.mod / all moon.pkg imports | PASS (+ moon.mod 0.27.0 -> 0.28.0) |
| 5 | Unit tests | moon test --target all --deny-warn | 276/276 x {wasm, wasm-gc, js, native} |
| 6 | Gherkin | features/dml_acceptance.feature | 6 features / 25 scenarios mapped to tests |
| 7 | Mutation testing | 5 hand-rolled mutants in cluster infrastructure | 5/5 killed |
| 8 | Fuzzing | cmd/fuzz 9 surfaces x 300 trials | 0 violations |
| 9 | Component tests | 9 cmd demos with output assertions | ALL PASS |

## Step 3 detail: duplicate code
Pre-fix: `irm.mbt:364-375` <-> `plr.mbt:249-260` shared 12 lines
of unit→row fold-expansion logic. Post-fix: shared via
`expand_unit_folds_to_rows` (a single 24-line helper in
`kfold.mbt`). PLPR's `fit_cluster` uses a different per-fold
structure (build_inner_oof) and was left alone.

## Step 6 detail: Gherkin
New feature "Cluster-robust inference for PLR/IRM" with 4
scenarios: cluster SE > row SE (lower bound 1.5x),
`is_cluster_data` semantics, same-seed cluster refit bit-exact,
cluster SE / row SE ratio lower bound (1.2). A scenario fails
iff its mapped test fails.

## Step 7 detail: mutation testing
Backups via `Copy-Item` to `_verify/mut-bak-*.mbt` before
each mutation; restore via `Move-Item -Force` after each
run; final clean-state re-run 276/276 green.

| Mutant | Change | Killed by |
|--------|--------|-----------|
| M1 | `expand_unit_folds_to_rows`: `in_test[tu[k]] = true` -> `false` (cluster unit→row mask flipped) | plpr_cluster_deterministic, plpr_cluster_se_larger_than_row_se, plpr_cluster_se_ratio_lower_bound (3) |
| M2 | `est_coef_cluster`: `let w = 1.0 / fold_n_units[f].to_double()` -> `let w = 1.0` | plpr_est_coef_cluster_imbalanced_folds (1) |
| M3 | `var_est_cluster`: `let g = gamma / npc` -> `let g = gamma` (dropped the cluster-folds-per-unit division) | plpr_var_est_cluster_reference (1) |
| M4 | `build_row_unit_map`: removed the abort on missing unit id | panic_build_row_unit_map_missing_unit (1) |
| M5 | `DoubleMLData::is_cluster_data`: always returns `false` (route cluster data through row-level path) | plpr_cluster_data_class, plpr_cluster_se_ratio_lower_bound (2) |

### The M2 lesson (numeric-path)
The original `plpr_est_coef_cluster_reference` test used
`fold_n_units = [1, 2]`. With this fold-size pair, the typo
`w = 1 / |I_k|` -> `w = 1` produces the same `sa` and `sb`
ratios (both numerator and denominator get the same `w`
multiplier and cancel). The mutation passed. The fix was to
add a `plpr_est_coef_cluster_imbalanced_folds` reference test
with `fold_n_units = [1, 3]` — an asymmetric pair where the
typo flips the ratio (weighted theta = 1.5, unweighted theta =
1.4). Same lesson as v0.25.0 M2 and v0.27.0 M3: numeric-path
mutations need a function-level reference test with inputs
that break the symmetry.

### The M4 lesson (SAST coverage)
M4 (removing the missing-unit-id abort in
`build_row_unit_map`) was not caught by any unit test before
this release — the helper was new and only exercised through
`plr_cluster_test.mbt::plpr_cluster_*` tests where the data
construction guarantees every unit id appears in `uniq`. The
SAST step (`moon check --deny-warn`) flagged it only because
removing the abort left the `if !found { ... }` body empty
(an unused-value warning). Once the test
`panic_build_row_unit_map_missing_unit` is in place, the
mutation gets caught by the test. We list this in QA7 even
though the original kill came from QA2 SAST — the test makes
the kill robust against future refactors that touch the
`if !found` block.

## Step 8 detail: fuzzing
New surface 9/9 "DoubleMLPLR cluster-robust vs row-level" over
random clustered panels (8-27 units x 2-5 periods): finite
coef (1e6 upper), finite SE (1e10 upper — random clustered
panels with degenerate D can produce large SEs in the
closed-form OLS nuisances; the lower bound is zero to allow
near-degenerate fits to terminate without aborting), and
same-seed cluster refit bit-exact.

## Step 9 detail: component assertions
All 9 existing cmd demos pass output assertions unchanged.
The cluster path is exercised by the `plpr` demo via the
upstream-derived `cre_general` / `cre_normal` approaches
(which use unit-level folds and cluster-robust SE
internally — see plpr_test.mbt's cluster-path coverage).

## Side effects included in this release
- `DoubleMLData` gained `cluster_vars : Array[Int]` field.
- New public helpers `DoubleMLData::is_cluster_data`,
  `DoubleMLData::n_cluster_vars`,
  `kfold::expand_unit_folds_to_rows`,
  `kfold::build_row_unit_map` (the last is pub so tests in
  other test files can drive it directly).
- New internal `DoubleMLPLR::fit_cluster` /
  `DoubleMLIRM::fit_cluster` helpers (fn-private; the
  public `fit()` is the dispatch entry point).
- `kfold_test.mbt` panic test for `build_row_unit_map`.
- `plr_cluster_test.mbt` (+6 tests).
- `plpr_test.mbt` imbalanced-folds reference test.
- moon.mod bumped to 0.28.0.
- .gitignore covers the cluster / dedup / diag scratch files
  produced during this release.

## Verdict
PASS on all nine gates. Release tagged v0.28.0.