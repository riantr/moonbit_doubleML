# TODO #1 Verification Report

- Verifier: moonbit-verifier (read-only session)
- Target: `D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit`
- Scope: TODO #1 — `check.mbt` / `check_test.mbt` 公共前置条件重构
- Moon toolchain: `moon 0.1.20260713 (75c7e1f 2026-07-13)` / `moonc v0.10.4+2cc641edf`
- Modified project files: none outside `_verify/` (verifier output only)
- Note: two transient probe files (`_verify_smoke_check_test.mbt`, `_verify_adversarial_test.mbt`) were added to the project root for the smoke/adversarial run, executed, and then moved to the Recycle Bin via `mavis-trash`. Final project root contains no `_verify_*` artifacts; `moon test --deny-warn` re-run confirms 59/59 still pass.

## Baseline run

```
PS D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit> moon fmt && moon test --deny-warn
Finished. moon: no work to do   (fmt clean)
Total tests: 59, passed: 59, failed: 0.
exit=0
```

Raw full output saved to `_verify/TODO-1-raw-test-output.txt`.

## C1.1 — 0 conditional `ignore` leftovers

- Method: `Select-String -Path '*.mbt' -Pattern 'ignore\([^\n]*(==|!=|>=|<=|>|<|self\.fitted)'`
- Evidence: 0 matches across the package.
- Result: PASS

## C1.2 — exactly one `fn require` definition, in `check.mbt`

- Method: `Select-String -Path '*.mbt' -Pattern 'fn require'`
- Evidence:
  ```
  D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit\check.mbt:20: pub fn require(condition : Bool, loc~ : SourceLoc) -> Unit {
  Count: 1
  ```
- Result: PASS

## C1.3 — 4 `panic_*` probes genuinely panic

- Method: copied `check_test.mbt` to a transient smoke file (`_verify_smoke_check_test.mbt`) and renamed the four `panic_*` tests to `smoke_*`. Ran `moon test _verify_smoke_check_test.mbt --deny-warn`. The hypothesis is: if the panic tests really call `abort()`, they will fail when the `panic_` prefix no longer applies; the happy-path test still passes.
- Evidence (WASM-GC default backend):
  ```
  Total tests: 5, passed: 1, failed: 4.
  exit=2
  ```
  The four failed tests are exactly `smoke_matvec_length_mismatch`, `smoke_cholesky_non_psd`, `smoke_plr_coef_before_fit`, `smoke_irm_new_n_folds_zero`. The happy `smoke_happy_path` (mirrors the original `check_accepts_valid_preconditions`) passed. Each failure carries a full backtrace through `@mavis/dml.check` (check.mbt:11) ← `@mavis/dml.require` (check.mbt:21) ← the specific public function. Saved to `_verify/TODO-1-smoke-native-{1..4}.txt` plus `_verify/TODO-1-adversarial-output.txt`.
- Result: PASS — the four `panic_*` probes really do panic; the `panic_` prefix is what allows the production test run to report them as green.

## C1.4 — `abort` message + stack point to the real caller

- Method: ran the four smoke variants under `--target native` to surface the `abort()` message (WASM-GC only shows "Error" without the message). Then ran a separate adversarial driver.
- Evidence (native backend, `moon test _verify_smoke_check_test.mbt -i <n> --target native`):
  ```
  precondition failed at matrix.mbt:139:3-139:33@mavis/dml   (smoke_matvec_length_mismatch)
  precondition failed at linalg.mbt:24:5-24:24@mavis/dml     (smoke_cholesky_non_psd)
  precondition failed at plr.mbt:80:3-80:23@mavis/dml        (smoke_plr_coef_before_fit)
  precondition failed at irm.mbt:61:3-61:24@mavis/dml        (smoke_irm_new_n_folds_zero)
  ```
  Cross-checked against source: each `loc` lands on the exact `require(...)` call site in the source file (matrix.mbt:139 `require(a.ncols == x.length())`, linalg.mbt:24 `require(diag > 0.0)`, plr.mbt:80 `require(self.fitted)`, irm.mbt:61 `require(n_folds >= 2)`). The message never points inside `check.mbt`, which confirms `#callsite(autofill(loc))` is auto-injecting the caller's `SourceLoc` into the labelled `loc` parameter and that `check.mbt` does not re-stamp it.
- Adversarial driver (separate `require(false)` call, native):
  ```
  test "adversarial_require_false_loc_driver" {
    require(false)
  }
  ```
  `moon test _verify_adversarial_test.mbt -i 0 --target native` produced:
  ```
  precondition failed at _verify_adversarial_test.mbt:7:3-7:17@mavis/dml
  ```
  Driver file/line — not `check.mbt`. Saved to `_verify/TODO-1-adversarial-output.txt`.
- Result: PASS

## C1.5 — file presence

- Method: `Test-Path` for the four files.
- Evidence:
  ```
  check.mbt                      -> True
  check_test.mbt                 -> True
  preconditions.mbt              -> False
  preconditions_test.mbt         -> False
  ```
- Result: PASS

## C1.6 — `moon info` exposes the new public API

- Method: ran `moon info`; inspected generated `pkg.generated.mbti`.
- Evidence:
  ```
  #callsite(autofill(loc))
  pub fn check(Bool, loc~ : SourceLoc) -> Unit          (line 13-14)
  #callsite(autofill(loc))
  pub fn require(Bool, loc~ : SourceLoc) -> Unit        (line 40-41)
  ```
  Both `pub fn require(...)` and `pub fn check(...)` are present, with `#callsite(autofill(loc))` preserved in the interface.
- Result: PASS

## Adversarial probe (must show ≥1 real panic)

- Built a stand-alone driver (`_verify_adversarial_test.mbt`) that calls `require(false)` directly, with no wrapper function in between. If `#callsite(autofill(loc))` is real, the abort message must name the driver file:line. If the loc were being lost or hard-coded, the message would say `check.mbt`.
- Evidence: native output `precondition failed at _verify_adversarial_test.mbt:7:3-7:17@mavis/dml` (see C1.4 above and `_verify/TODO-1-adversarial-output.txt`).
- Result: PASS — direct `require(false)` from a third-party caller still produces a real `abort` whose location is the caller's source line.

## Summary

| Check | Result |
|------|--------|
| C1.1 0 conditional `ignore` leftovers | PASS |
| C1.2 single `fn require` in `check.mbt` | PASS |
| C1.3 4 `panic_*` probes really panic | PASS |
| C1.4 `abort` message points to caller | PASS |
| C1.5 file presence matches design | PASS |
| C1.6 `moon info` publishes both fns | PASS |
| Adversarial driver panic with caller loc | PASS |
| Baseline `moon test --deny-warn` 59/59 | PASS |

Producer's deviation note ("MoonBit 0.1.20260713 不接受 `~loc=` 语法，改用 `#callsite(autofill(loc))`") is corroborated: the four `precondition failed at <file>:<line>` messages above are produced by `#callsite(autofill(loc))` auto-injection, not by an explicit `~loc=` argument. The behaviour matches the producer's claim.

No gap found. Producer is not required to change any code for this TODO.

VERDICT: PASS
