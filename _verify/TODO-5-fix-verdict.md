# TODO #5 fix — independent read-only verification report

- **Verifier**: `moonbit-verifier`
- **Scope**: read-only re-verification of the TODO #5 fix on
  `D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit`
  after the producer updated `irm_test.mbt` to use `< 0.5` tolerance
  (was `< 1.0` at the time of the prior `_verify/TODO-5-verdict.md`,
  which reported `VERDICT: FAIL` for Check 6).
- **Baseline branch / commit**: working tree only, no commits in this repo
- **Verdict** is based on the project state at the time of the run; no project
  source/test files were modified. Verifier-owned temporary files were placed at
  `$env:TEMP\t5_probe\` (canonical source) and briefly copied into the project
  root for moon test discovery; both copies have been moved to the OS Trash
  (final `moon test --deny-warn` re-run: 65/65 pass, exit 0, 0 warnings).
- **Note on `_verify_TODO5_fix_irm_5seed.mbt.archived`**: this file is the
  prior round's archived/invalid verifier probe (renamed `.mbt.archived`).
  Its extension is `.mbt.archived` (not `.mbt`), so moon test discovery does
  NOT count it. The two probes this round were written to fresh names
  (`_verify_TODO5_fix_irm_5seed_test.mbt`, `_verify_TODO5_adversarial_test.mbt`)
  and removed after the run. The archived file is left in place untouched.

## Producer's stated claims (recap, post-fix)

1. `irm_test.mbt` tolerance changed from `< 1.0` → `< 0.5` to close the gap
   flagged in the prior verdict.
2. All other tolerance / sign / SE assertions remain as in the prior report.
3. `moon test --deny-warn` reports 65/65 pass, 0 warnings, exit 0.

---

## Check 1 — Tolerance in each of the 5 estimator test files

- **Method**: read each file, locate the `inspect((theta - theta0).abs() < ...)`
  (or equivalent for PLIV which uses `alpha0`) line, confirm the bound.
- **Evidence**:
  | File | Line | Assert |
  |---|---|---|
  | `plr_test.mbt`  | L51 | `inspect((theta - theta0).abs() < 0.2, content="true")` |
  | `irm_test.mbt`  | L49 | `inspect((theta - theta0).abs() < 0.5, content="true")` |
  | `pliv_test.mbt` | L80 | `inspect((theta - alpha0).abs() < 0.5, content="true")` |
  | `iivm_test.mbt` | L66 | `inspect((theta - theta0).abs() < 0.5, content="true")` |
  | `did_test.mbt`  | L61 | `inspect((theta - theta0).abs() < 0.5, content="true")` |
- **Result**: **PASS**. PLR is tightened to `< 0.2` as required; IRM (the file
  that was the prior FAIL's culprit) is now at `< 0.5`; PLIV/IIVM/DID hold at
  `< 0.5`. The tolerance change at `irm_test.mbt:49` is exactly the fix that
  closes the prior round's Check 6.

## Check 2 — 5 estimator tests each have parameter positive, `se>0`, `se<1`, no `ignore(se)`

- **Method**: read each of the 5 files and (a) confirm the presence of the
  three new `inspect(...)` asserts, (b) `grep -n 'ignore(se)'` across all
  `*.mbt` files in the project root.
- **Evidence — three new inspects**:
  | File | `param > 0.0` | `se > 0.0` | `se < 1.0` |
  |---|---|---|---|
  | `plr_test.mbt`  | L56 (`theta > 0.0`)  | L58 | L61 |
  | `irm_test.mbt`  | L54 (`theta > 0.0`)  | L55 | L57 |
  | `pliv_test.mbt` | L84 (`theta > 0.0`)  | L85 | L87 |
  | `iivm_test.mbt` | L71 (`theta > 0.0`)  | L72 | L74 |
  | `did_test.mbt`  | L65 (`theta > 0.0`)  | L66 | L68 |
- **Evidence — `ignore(se)`**:
  ```
  $ grep -n 'ignore(se)' *.mbt
  ssm_test.mbt:65:  ignore(se)
  ```
  Zero matches in any of the 5 estimator files. The lone remaining
  `ignore(se)` is in `ssm_test.mbt` which is explicitly out of the 5-file
  spec and unchanged in scope.
- **Result**: **PASS**. All 5 spec files have all 15 of the new
  `inspect(param > 0.0)` / `inspect(se > 0.0)` / `inspect(se < 1.0)` calls;
  the `se` binding in each file flows into real asserts, not into
  `ignore(se)`.

## Check 3 — `moon test --deny-warn` clean run

- **Method**: `cd 'D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit'
  && moon test --deny-warn`. Run before any verifier probe is dropped
  into the project root, run again after each probe is cleaned up.
- **Evidence (clean baseline and final re-run, identical)**:
  ```
  $ moon test --deny-warn
  Total tests: 65, passed: 65, failed: 0.
  $ echo $LASTEXITCODE
  0
  ```
  `--deny-warn` semantics: any compiler/test warning causes non-zero exit.
  `LASTEXITCODE = 0` ⇒ zero warnings.
- **Result**: **PASS**. 65/65, exit 0, no warnings.

## Check 4 — IRM 5-seed reproducibility probe (seeds 3141..3145)

- **Method**: write a verifier-owned probe that re-creates the exact DGP
  from `irm_test.mbt:6..37` (n=500, p=5, theta0=1.0, chacha8 seed=1111, the
  same Box-Muller pool feeding x + d-noise, the same `if rng.double() > 0.5`
  for `d[i]`, the same `y[i] = theta0 * d[i] + s`), then runs
  `DoubleMLIRM::new(data, n_folds=2, n_rep=1, seed=3141 + k).fit()` for
  k = 0..4 (i.e. estimator seeds 3141, 3142, 3143, 3144, 3145).
  The probe asserts per-run `|theta - 1.0| < 0.5`, `theta > 0.0`,
  `se > 0.0`, `se < 1.0`, plus aggregate `max |theta - 1.0| < 0.5`.
  Canonical source at
  `$env:TEMP\t5_probe\_verify_TODO5_fix_irm_5seed_test.mbt`; project-root
  copy used for `moon test`, then trashed via `mavis-trash`.
- **Evidence** (probe test output, captured during the run):
  ```
  VB TODO5 IRM summary max_dev=0.051840247655323246
                        min_se=0.09004659238559021
                        max_se=0.09428723157468684
  Total tests: 66, passed: 66, failed: 0.
  EXITCODE=0
  ```
  Interpretation:
  - max |theta - 1.0| across the 5 seeds = **0.0518402...**, strictly < 0.5.
  - min SE across the 5 seeds = **0.0900465...**, strictly > 0.
  - max SE across the 5 seeds = **0.0942872...**, strictly < 1.
  - The 66/66 result confirms 65 baseline tests + 1 verifier probe, all
    green.
  After probe cleanup, `moon test --deny-warn` returns to 65/65.
- **Result**: **PASS**. All 5 IRM seeds satisfy `|theta - 1.0| < 0.5` and
  `0 < se < 1.0`, with substantial headroom (max deviation 0.052 < 0.5,
  max SE 0.094 < 1.0). The probe also implies `theta > 0.0` for every seed
  (since |theta - 1.0| < 0.5 and theta0 = 1.0 ⇒ theta ∈ (0.5, 1.5)), so
  the sign-flip guard is automatically satisfied.

## Check 5 — Adversarial probe: assertion must fail when condition is violated

- **Method**: write a verifier-owned adversarial probe that re-uses the same
  IRM DGP / `seed_buf(1111)` / `DoubleMLIRM::new(..., seed=3141)` as
  `irm_test.mbt:6..40`, but substitutes three impossible asserts:
  - `inspect((theta - theta0).abs() < 0.001, content="true")` — IRM
    |theta - 1.0| ≈ 0.05, so this MUST fail.
  - `inspect(theta > 100.0, content="true")` — theta ≈ 0.95, MUST fail.
  - `inspect(se < 0.0001, content="true")` — SE ≈ 0.09, MUST fail.
  Run via `moon test --deny-warn _verify_TODO5_adversarial_test.mbt`.
  Canonical source at
  `$env:TEMP\t5_probe\_verify_TODO5_adversarial_test.mbt`;
  project-root copy used for discovery, then trashed.
- **Evidence** (probe test output, captured during the run):
  ```
  [mavis/dml] test _verify_TODO5_adversarial_test.mbt:10
    ("verify_TODO5_adversarial_irm_impossible_tolerance") failed
  expect test failed at
    D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit\_verify_TODO5_adversarial_test.mbt:50:3-50:58
  Diff: (- expected, + actual)
  ----
  -true
  +false
  ----
  Total tests: 1, passed: 0, failed: 1.
  EXITCODE=2
  ```
  The first impossible assert (line 50, the `< 0.001` substitute) trips
  the test. The diagnostic diff `expected: true / actual: false` shows
  MoonBit's `inspect` actually evaluated the boolean expression and
  raised on `false`. After probe cleanup, `moon test --deny-warn` returns
  to 65/65.
- **Result**: **PASS**. The `< 0.5` assert in the real `irm_test.mbt:49`
  is a real gate: if a future regression were to widen the IRM point
  estimate beyond 0.5, or to corrupt the `se` value, the corresponding
  `inspect(...)` would raise and the test would fail. The same logic
  protects the `theta > 0.0`, `se > 0.0`, `se < 1.0` asserts.

## Check 6 — No stray `.mbt` artifacts in the project root

- **Method**: `Get-ChildItem -File | Where-Object { $_.Name -like '*.mbt' }`
  before and after each probe run.
- **Evidence (final state of project root `.mbt` files)**:
  ```
  aggregator.mbt / aggregator_test.mbt
  apo.mbt / apo_test.mbt
  blp_policy.mbt / blp_policy_test.mbt
  check.mbt / check_test.mbt
  data.mbt
  did.mbt / did_test.mbt
  iivm.mbt / iivm_test.mbt
  irm.mbt / irm_iivm_empty_fold_test.mbt / irm_test.mbt
  kfold.mbt / kfold_test.mbt
  linalg.mbt / linalg_test.mbt
  linear.mbt / linear_test.mbt
  lpq.mbt / lpq_test.mbt
  matrix.mbt / matrix_test.mbt
  pliv.mbt / pliv_test.mbt
  plr.mbt / plr_test.mbt
  quantile.mbt / quantile_test.mbt
  rdd.mbt / rdd_test.mbt
  ssm.mbt / ssm_test.mbt
  ```
  Exactly the 18 expected `*_test.mbt` files plus their `*.mbt` siblings
  — no `_verify_TODO5_fix_irm_5seed_test.mbt`, no
  `_verify_TODO5_adversarial_test.mbt`, no other temporary `.mbt`.
  The archived prior-round probe `_verify_TODO5_fix_irm_5seed.mbt.archived`
  is in the project root but its extension is `.mbt.archived`, so it is
  NOT picked up by moon test discovery and does NOT affect the 65/65
  count (the suffix is the verifier convention for "no longer in
  service"). Its last-write timestamp (2026/8/7 7:52:31) predates this
  round; the file was untouched in this verification.
- **Result**: **PASS**. Project root is byte-clean of verifier artifacts;
  the archived prior-round file does not perturb the test count.

---

## Summary table

| # | Check / Probe | Result |
|---|---|---|
| 1 | Tolerance in 5 estimator files (PLR `< 0.2`, others `< 0.5`) | PASS |
| 2 | 5 files each have positive sign, `se>0`, `se<1`, no `ignore(se)` | PASS |
| 3 | `moon test --deny-warn` baseline (65/65, 0 warnings, exit 0) | PASS |
| 4 | IRM 5-seed reproducibility probe (3141..3145) | PASS |
| 5 | Adversarial probe — assertion raises on impossible condition | PASS |
| 6 | No stray `.mbt` artifacts in project root | PASS |

## Notes on what changed since the prior verdict

- The single FAIL point in `_verify/TODO-5-verdict.md` was Check 6:
  `irm_test.mbt:46` had `inspect((theta - theta0).abs() < 1.0, ...)`.
- In the current code, that line is `irm_test.mbt:49` and reads
  `inspect((theta - theta0).abs() < 0.5, content="true")`. The change
  closes the gap with no other observable regressions.
- All other checks from the prior report remain PASS and have been
  independently re-confirmed in this round.

---

VERDICT: PASS