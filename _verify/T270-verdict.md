# T270 verdict: v0.26.0 nine-step QA battery

Release gate for `DoubleMLPLPR` (static panel partially linear
regression, Clarke & Polselli 2025). All steps executed in the
user's specified order on 2026-08-26.

## Pre-gate work included in this release

The battery ran AFTER completing the open cre_general/cre_normal
SE investigation from the WIP state. Root cause chain:

1. Installed doubleml 0.11.3's `DoubleMLPanelData.__init__` sets
   `cluster_cols = id_col` when `static_panel=True`
   (panel_data.py lines 108-113) — the repo snapshot under
   DoubleMachineLearning/doubleml-for-py has no such wiring (not
   a git checkout; version drift), which initially misled the
   investigation.
2. Empirical probe (`_verify/diag_cre2.py`, local-only):
   `_is_cluster_data = True`; zero units span both sides of a
   fold; reported se 0.020088 vs naive row-level 0.354707.
3. Upstream cluster machinery replicated exactly:
   - `Resampling.split_samples`: KFold over unique cluster
     VALUES, expanded to row-level folds.
   - `LinearScoreMixin._est_coef` cluster branch: fold-weighted
     score sums with `w_k = 1/|I_k|`.
   - `_var_est` one-cluster-variable branch: `gamma += S_g^2 /
     |I_k|`, both gamma and J divided by `n_folds_per_cluster`,
     sigma2 = (gamma/npc)/(N_units * (J/npc)^2).
4. MoonBit results after fix (60x4 DGP, seed 3141): all four
   approaches theta ~ 1.028-1.029, se 0.0170-0.0200 (pre-fix:
   cre_general 1.1746/se 0.357, cre_normal 1.0651/se 0.362,
   fd_exact 1.0281/se 0.0187, wg_approx 1.0164/se 0.0159).
5. Validator rewritten: upstream vs hand-rolled numpy cluster
   reference vs MoonBit — three-way agreement. Upstream
   KFold(shuffle=True) is UNSEEDED (drifts run-to-run), so
   tolerance bands are the correct comparison mode.

## Results summary

| # | Step | Tool / method | Result |
|---|------|---------------|--------|
| 1 | Format check | moon fmt + MD5 hash diff over .mbt | CLEAN |
| 2 | SAST | moon check --deny-warn + pattern scans | PASS (0 warnings, no secrets, no FFI, TODOs historical) |
| 3 | Duplicate code | _verify/dupcheck.py >=12-line windows | 0 blocks over 32 files |
| 4 | Dependency check | moon.mod / all moon.pkg imports | PASS (+ moon.mod 0.25.0 -> 0.26.0) |
| 5 | Unit tests | moon test --target all --deny-warn | 260/260 x {wasm, wasm-gc, js, native} |
| 6 | Gherkin | features/dml_acceptance.feature | 4 features / 14 scenarios mapped to tests |
| 7 | Mutation testing | 5 hand-rolled mutants in plpr.mbt | 5/5 killed |
| 8 | Fuzzing | cmd/fuzz 7 surfaces x 300 trials | 0 violations |
| 9 | Component tests | 8 cmd demos with output assertions | ALL PASS |

## Step 3 detail: duplicate code
The pre-fix cre_general block re-derived the transform's sorted
kept-id vector (~25 lines duplicating transform_panel logic).
Fixed by threading `id : Array[Int]` through PanelTransform; the
adjustment now reads tf.id directly. Re-scan: 0 duplicated
blocks.

## Step 6 detail: Gherkin
New feature "Static panel partially linear regression (PLPR)"
with scenarios: clustered-scale recovery for all four approaches
(+ CI identity), hand-computed est_coef_cluster/var_est_cluster
references, unit/fold integrity via too-few-units panic +
clustered se guard, and FE-free recovery. A scenario fails iff
its mapped test fails.

## Step 7 detail: mutation testing
Backups via Copy-Item to _verify/mut-bak-plpr.mbt before each
mutation; restore via Move-Item -Force after each run; final
clean-state re-run 260/260 green.

| Mutant | Change | Killed by |
|--------|--------|-----------|
| M1 | est_coef_cluster `-sb/sa` -> `sb/sa` | plpr_all_approaches_recover_theta, plpr_no_fe_recovery, plpr_iv_type_recovers_theta, plpr_n_rep_two, plpr_confint_covers_truth, plpr_est_coef_cluster_reference (6) |
| M2 | kfold(n_units, ...) -> kfold(n, ...) row-level folds | 6 tests (unit_fold index out-of-bounds abort; silent-leakage variant separately guarded by se < 0.08 band — pre-fix values 0.357/0.362 exceed it) |
| M3 | var_est_cluster `w*s*s` -> `w*s` | plpr_all_approaches_recover_theta (se bound), plpr_confint_covers_truth, plpr_var_est_cluster_reference (3) |
| M4 | `let g = gamma / npc` -> `let g = gamma` | plpr_var_est_cluster_reference only (1) |
| M5 | confint z doubled | plpr_all_approaches_recover_theta CI identity (1) |

### The M4 lesson
A sqrt(2)-scale variance mutation is INVISIBLE to DGP-level se
bands tuned at [0.004, 0.08] (0.017 * sqrt(2) = 0.024 sits
inside). The hand-computed reference test (expected
sqrt(3.25/36) within 1e-12) kills it instantly. Direct
function-level reference tests are the right tool for numeric-
path mutants; integration bands catch gross breakage.

## Step 8 detail: fuzzing
New surface 7/7 "DoubleMLPLPR clustered fit invariants" over
random panels (6-30 units x 2-5 periods, mixed approaches,
25% IV-type): finite coef/se with se > 0, structural transformed
row count (units*T for cre/wg, units*(T-1) for fd_exact), and
same-seed bit-exact refit determinism. Two toolchain notes: (a)
`trait` remains a reserved keyword — a local variable named
`trait` failed to parse (renamed unit_trait, per v0.26.0 lesson
re-learned); (b) optional-param call shorthand requires the
trailing tilde (`seed~`); a bare `seed` parses as positional.

## Step 9 detail: component assertions
- cmd/main: estimated theta values in [0.8, 1.2] (PLR 1.092,
  PLIV 0.937, DID 1.006, SSM 1.003).
- cmd/datasets: PLR/IRM estimates in [1.3, 1.7] (true 1.5).
- cmd/did_binary: ATT 1.00035 in [0.995, 1.005].
- cmd/did_cs: 2 covers=true.
- cmd/did_multi: exactly 3 standard covers=true + Universal
  mode section present.
- cmd/did_cross_section: 2 covers=true.
- cmd/fuzz: "ALL FUZZ SURFACES PASSED".
- cmd/plpr (NEW): 4/4 thetas in [0.9, 1.15] AND 4/4 ses in
  [0.004, 0.08]; CIs printed per approach.

## Side effects included in this release
- PanelTransform gained `id : Array[Int]` (all four approaches).
- Fold::new public constructor (external custom partitions).
- est_coef_cluster / var_est_cluster are pub API.
- Fuzz harness extended to 7 surfaces.
- moon.mod bumped to 0.26.0.
- .gitignore += __pycache__/, _verify/diag_cre*.py (diagnostics
  kept locally, out of repo).
- did_multi.mbt: moon fmt added one missing `///|` marker.

## Verdict
PASS on all nine gates. Release tagged v0.26.0.
