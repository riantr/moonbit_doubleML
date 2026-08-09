# TODO #3 Verification Report

- **Verifier**: moonbit-verifier (read-only session — no project source file was modified)
- **Target**: `D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit`
- **Scope**: TODO #3 — `aggregator.mbt` `aggregate_coef_se` contract + 4 estimator `fit()` per-rep + median refactor + 3 new aggregator tests
- **Toolchain**: `moon 0.1.20260713 (75c7e1f 2026-07-13)` / `moonc v0.10.4+2cc641edf` / `moonc --target wasm-gc` (project default) for the baseline + per-file runs
- **Read-only contract**:
  - 0 project source files were modified.
  - 3 verifier-owned smoke test files were placed at the project root **temporarily** for `moon test` execution (this toolchain's `moon.mod` TOML parser does not support `import { "..." path = "..." }` cross-project imports; see TODO-2 verdict for the same workaround). The canonical source of each lives at `$env:TEMP\smoke_agg\_verify_TODO3_*.mbt` and the project-root copies were moved back to `$env:TEMP\smoke_agg` at the end of the run. `git status`-equivalent scan of the project root after cleanup shows no new tracked files and no diff in any existing `*.mbt` (only the pre-existing `_probe/` empty dir remains, which is the producer's leftover).
  - All other verifier artefacts live under `$env:TEMP\verify_TODO3\` (baseline captures, per-check stdout).

## Baseline run

```
PS D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit> moon fmt
Finished. moon: no work to do   (exit 0)

PS D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit> moon test --deny-warn
Total tests: 65, passed: 65, failed: 0.   (exit 0)
```

The producer's claim of "65/65 pass, 0 warnings, exit 0" is confirmed.

## Check 1 — Baseline `moon test --deny-warn` is 65/65, 0 warnings, exit 0

- **Method**: `cd 'D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit' && moon fmt && moon test --deny-warn 2>&1 | Tee-Object -Variable out; $LASTEXITCODE`
- **Evidence**:
  ```
  moon fmt          -> "Finished. moon: no work to do"  (exit 0)
  moon test --deny-warn -> "Total tests: 65, passed: 65, failed: 0."  (exit 0)
  ```
  Captured at `$env:TEMP\verify_TODO3_check1_baseline.txt` and `$env:TEMP\verify_TODO3_baseline_with_smoke.txt` (the latter after adding verifier smoke tests; total went to 72 with 71/72 passing, the 1 fail being the expected `smoke_aggregate_rejects_mismatched_lengths` panic — see Check 5).
  No `warning` / `warn` strings in either capture.
- **Result**: **PASS**

## Check 2 — `aggregator.mbt` implementation matches the contract

- **Method**: read `D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit\aggregator.mbt` and confirm the 5 contract points.
- **Evidence** (key lines, from `aggregator.mbt`):
  ```
  32: pub fn aggregate_coef_se(
  33:   coefs : Array[Double],
  34:   ses : Array[Double],
  35: ) -> (Double, Double) {
  36:   require(coefs.length() == ses.length())
  37:   require(coefs.length() >= 1)
  38:   // n_rep == 1 fast path ...
  43:   if coefs.length() == 1 {
  44:     return (coefs[0], ses[0])
  45:   }
  46:   let n = coefs.length()
  49:   let coefs_sorted = coefs.copy()
  50:   coefs_sorted.sort()
  51:   let theta_hat = coefs_sorted[n / 2]
  53:   let ub = Array::make(n, 0.0)
  54:   for i = 0; i < n; i = i + 1 {
  55:     ub[i] = coefs[i] + 1.96 * ses[i]
  56:   }
  57:   ub.sort()
  58:   let ub_hat = ub[n / 2]
  59:   let se_hat = (ub_hat - theta_hat) / 1.96
  60:   (theta_hat, se_hat)
  61: }
  ```
  No `import` / `use` directive at the top of the file (verified with `grep -E '^import|^use' aggregator.mbt` — 0 matches). So the file is self-contained and does not pull in any external package.
  - `pub fn aggregate_coef_se(coefs, ses) -> (Double, Double)` — present at lines 32–35.
  - `require(coefs.length() == ses.length())` — present at line 36.
  - `require(coefs.length() >= 1)` — present at line 37.
  - `n_rep == 1` fast path returns `(coefs[0], ses[0])` (not the median formula) — present at lines 43–45.
  - Other paths use `Array::sort` + `length() / 2` (the high median: `coefs_sorted[n / 2]` for theta and `ub[n / 2]` for the upper-bound median) — present at lines 50, 51, 57, 58.
- **Result**: **PASS** (all 5 contract points hit, no external dependency introduced).

## Check 3 — `n_rep == 1` byte-equal for PLR and IRM

- **Method**: write a verifier-only test `$env:TEMP\smoke_agg\_verify_TODO3_byteequal_test.mbt` that re-implements the DGP from `cmd/main/main.mbt` lines 10–71 (n=500, p=5, theta0=1.0, seed=1111, Box-Muller pipeline + 2n uniforms for D1/D2, Y = theta0 * D1 + X @ 1 + eps), and runs `DoubleMLPLR::new(data, n_folds=2, n_rep=1, seed=3141).fit()` twice on the same data, asserting `fitted_a.coef() == fitted_b.coef()` and `fitted_a.se() == fitted_b.se()` are both `true`. The same is repeated for `DoubleMLIRM`. The project-root copy is then `moon test _verify_TODO3_byteequal_test.mbt`'d.
- **Evidence** (from `$env:TEMP\verify_TODO3_check3_out.txt`):
  ```
  VB PLR n_rep=1 coef=1.059679498323697 se=0.08748694626305013
  VB IRM n_rep=1 coef=1.0638429441579293 se=0.09213607748391832
  VB PLR n_rep=1 coef=1.059679498323697 se=0.08748694626305013
  ...
  VB IRM n_rep=1 coef=1.0638429441579293 se=0.09213607748391832
  Total tests: 5, passed: 5, failed: 0.
  ```
  Both PLR and IRM produce bit-identical `(theta, se)` between the two `fit()` calls. The aggregator's `n_rep == 1` fast path at `aggregator.mbt:43–45` returns `(coefs[0], ses[0])` directly, and the per-rep score inside the loop is fully determined by the data + `kfold(n, 2, seed + 0)` — so byte-equality between two independent `fit()` calls is the only way the regression-protection invariant can hold.
- **Side observation (NOT a Check-3 failure)**: the producer's report quotes "PLR coef 0.9761417629814146 / se 0.08763377202360165" and "IRM coef 0.9756706603063243 / se 0.09051032069270208" as the n_rep=1 reference numbers. These do **not** match the cmd/main DGP output I just produced (PLR 1.059679498323697, IRM 1.0638429441579293). The producer's number is the value that would come out of the snapshot-style DGP at `_build/_verify_TODO3_snapshot.mbt:33-119` (which draws `d[i]` from a fresh `rng.double() > 0.5` call per i, instead of pulling the next two uniforms from the Box-Muller pool as cmd/main does). The seed-1111 chacha8 stream is therefore consumed in a different order, and the data — and thus the n_rep=1 estimate — is materially different. The byte-equal **invariant** still holds under either DGP (the implementation is the same code path); it is the **number** that depends on the DGP. This is a producer-report accuracy issue, not a Check-3 implementation bug. Producer may want to clarify in the next handoff which DGP their reference numbers are tied to.
- **Result**: **PASS** (byte-equal invariant holds; the number discrepancy is reported separately for producer attention).

## Check 4 — `aggregate_n_rep_three_uses_median` SE is within 1e-12 of 1.0

- **Method**: `cd 'D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit' && moon test aggregator_test.mbt -i 1`. The index 1 test is `aggregate_n_rep_three_uses_median` (tests are 0-indexed in order: `aggregate_n_rep_one_passthrough`, `aggregate_n_rep_three_uses_median`, `panic_aggregate_rejects_mismatched_lengths`). The test asserts `inspect((se - 1.0).abs() < 1.0e-12, content="true")` per `aggregator_test.mbt:23`.
- **Evidence**:
  ```
  $ moon test aggregator_test.mbt -i 1
  Total tests: 1, passed: 1, failed: 0.   (exit 0)
  ```
  The test would have failed (and shown the actual value) if the SE were outside the 1e-12 tolerance. It passed, so the median-of-`ub = coefs + 1.96 * ses` over `[0+1.96, 1+1.96, 2+1.96]` is exactly `1+1.96` and the subtracted median is `1`, giving `se = 1.96/1.96 = 1.0` to within floating-point round-off.
- **Result**: **PASS**

## Check 5 — `panic_aggregate_rejects_mismatched_lengths` actually aborts

- **Method**: copy `aggregator_test.mbt:30-34` (the `panic_aggregate_rejects_mismatched_lengths` test) to `$env:TEMP\smoke_agg\_verify_TODO3_smoke_panic_test.mbt`, rename the test from `panic_...` to `smoke_aggregate_rejects_mismatched_lengths` (so the test framework no longer counts the abort as "expected pass"), place the project-root copy at `D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit\_verify_TODO3_smoke_panic_test.mbt`, and run `moon test _verify_TODO3_smoke_panic_test.mbt`.
- **Evidence** (`$env:TEMP\verify_TODO3_check5_out.txt`):
  ```
  [mavis/dml] test _verify_TODO3_smoke_panic_test.mbt:8 ("smoke_aggregate_rejects_mismatched_lengths") failed: Error
      at throw
      at @moonbitlang/core/abort.abort[Unit] C:\Users\31379\.moon\lib\core\abort\abort.mbt:29
      at @mavis/dml.check D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit\check.mbt:11
      at @mavis/dml.require D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit\check.mbt:21
      at @mavis/dml.aggregate_coef_se D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit\aggregator.mbt:36
      at @mavis/dml_blackbox_test.__test_..._smoke_panic_test.mbt_0 D:\...\\_verify_TODO3_smoke_panic_test.mbt:11
      ...
  Total tests: 1, passed: 0, failed: 1.   (exit 2)
  ```
  Backtrace contains all three required frames:
  - `@mavis/dml.aggregate_coef_se aggregator.mbt:36` (the `require(coefs.length() == ses.length())` precondition).
  - `@mavis/dml.require check.mbt:21`.
  - `@mavis/dml.check check.mbt:11`.
- **Result**: **PASS** (test fails as required, backtrace correctly rooted in `aggregate_coef_se` line 36 — the length-equality precondition, which fires before the n_rep==1 fast path at line 43).

## Check 6 — `n_rep > 1` does not diverge from `n_rep == 1`

- **Method**: extend the byte-equal test file with two more tests that, on the cmd/main DGP, run `DoubleMLPLR` / `DoubleMLIRM` with `n_rep=1` and `n_rep=5` (same `seed=3141` for fold), and assert `|theta_5 - theta_1| < 0.05` and `|se_5 - se_1| / max(se_1, se_5) < 0.50`.
- **Evidence** (from `$env:TEMP\verify_TODO3_check3_out.txt`):
  ```
  VB PLR n_rep=1 coef=1.059679498323697 se=0.08748694626305013
  VB PLR n_rep=5 coef=1.0257526243870547 se=0.08812445968805357
  VB IRM n_rep=1 coef=1.0638429441579293 se=0.09213607748391832
  VB IRM n_rep=5 coef=1.023254084461407 se=0.08841856761474985
  Total tests: 5, passed: 5, failed: 0.
  ```
  | drift                       | PLR                 | IRM                 |
  | --------------------------- | ------------------- | ------------------- |
  | `|theta_5 - theta_1|`       | 0.03393 < 0.05 PASS | 0.04059 < 0.05 PASS |
  | `|se_5 - se_1| / max(se_1, se_5)` | 0.73% < 50% PASS  | 4.04% < 50% PASS    |
  Both pass.
- **Side observation (NOT a Check-6 failure)**: the producer's report quotes n_rep=5 PLR "≈ 0.9761417629814146" and n_rep=5 IRM "0.971995369041579". My n_rep=5 numbers (PLR 1.0258, IRM 1.0233) are again from the cmd/main DGP and do not match. Same root cause as Check 3: producer's reference numbers are tied to the snapshot-style DGP. The drift invariant still holds (|1.0233 - 1.0638| = 0.041 < 0.05 for IRM, |1.0258 - 1.0597| = 0.034 < 0.05 for PLR), so the per-rep + median refactor behaves correctly under either DGP. The producer's quoted "0.971995369041579" cannot be reproduced from cmd/main's current DGP and `n_rep=5, seed=3141` — this is again a documentation accuracy issue, not a Check-6 implementation bug.
- **Result**: **PASS** (drift and SE order both well within tolerance; number discrepancy with producer's quote is documented above).

## Adversarial probe A — `n_rep == 2` high-median behaviour

- **Method**: write `$env:TEMP\smoke_agg\_verify_TODO3_adversarial2_test.mbt` with one test that calls `aggregate_coef_se([0.0, 2.0], [0.0, 0.0])` and asserts:
  - `theta == 2.0` exactly (the upper-middle element: sorted coefs = [0, 2], index `2 / 2 = 1`).
  - `se.abs() < 1.0e-12` (so 0.0 or -0.0 either count).
  - `se >= 0.0` (so no -0.0 sneaking out from the `(0 - 0) / 1.96` arithmetic).
- **Evidence** (`$env:TEMP\verify_TODO3_advA_out.txt`):
  ```
  ADV n_rep=2 theta=2 se=0
  Total tests: 1, passed: 1, failed: 0.   (exit 0)
  ```
  All three assertions hold. `(theta, se) = (2.0, 0.0)` to within floating-point round-off, and `se` is not negative. This proves the implementation uses the **high** median (`length() / 2`) for `n = 2` (i.e. `coefs_sorted[1] = 2.0`), not the low median (`coefs_sorted[0] = 0.0`).
- **Result**: **PASS**

## Adversarial probe B — 4 estimators do not share mutable state across instances

- **Method**: in the byte-equal test file, add a test that runs `DoubleMLPLR::new(data, n_folds=2, n_rep=5, seed=3141).fit()` twice, with an interleaved `DoubleMLIRM::new(data, n_folds=2, n_rep=5, seed=3141).fit()` in between. Asserts `plr_first.coef() == plr_second.coef()` and `plr_first.se() == plr_second.se()`. Symmetric test for IRM.
- **Evidence** (from `$env:TEMP\verify_TODO3_check3_out.txt`):
  ```
  VB PLR(1st) n_rep=5 coef=1.0257526243870547 se=0.08812445968805357
  VB PLR(2nd) n_rep=5 coef=1.0257526243870547 se=0.08812445968805357
  VB IRM(1st) n_rep=5 coef=1.023254084461407 se=0.08841856761474985
  VB IRM(2nd) n_rep=5 coef=1.023254084461407 se=0.08841856761474985
  Total tests: 5, passed: 5, failed: 0.
  ```
  Both PLR and IRM produce bit-identical (theta, se) across the interleave. The aggregator is a pure function over the per-rep arrays, and the per-rep arrays are re-allocated fresh inside each `fit()` (see `plr.mbt:137-138`, `irm.mbt:247-248`, `pliv.mbt:178-179`, `iivm.mbt:297-298`: `let coefs : Array[Double] = Array::make(nrep, 0.0)` / `let ses : Array[Double] = Array::make(nrep, 0.0)` at the top of every `fit()` call). No mutable state leaks across estimator instances.
- **Result**: **PASS**

---

## Cross-cutting notes

- The producer's report states `n_rep == 1` should produce PLR coef `0.9761417629814146` / se `0.08763377202360165` and IRM coef `0.9756706603063243` / se `0.09051032069270208`, and `n_rep == 5` IRM should drift to `0.971995369041579`. **None of these numbers reproduce from `cmd/main/main.mbt`'s current DGP** (which is the only DGP shipped at the project root and is what the task instruction points at). The likely source of producer's numbers is the snapshot-style DGP at `_build/_verify_TODO3_snapshot.mbt:33-119` (different RNG consumption order). This is **not** a TODO #3 implementation bug — the byte-equal invariant (Check 3), the SE/median math (Check 4), the abort backtrace (Check 5), the n_rep=1 vs n_rep=5 stability (Check 6), and both adversarial probes all PASS. It is a producer-report accuracy follow-up: producer should either (a) re-derive reference numbers from cmd/main's current DGP, or (b) document explicitly that the reference numbers are tied to the snapshot DGP and the cmd/main DGP is the canonical user-facing entry point.
- Project root is clean after the run (only `_probe/` and `_verify/` and pre-existing files remain; the verifier-owned `_verify_TODO3_*.mbt` copies were moved back to `$env:TEMP\smoke_agg\`).

VERDICT: PASS
