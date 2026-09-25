# `moon prove`: `for x in arr` foreach rejected in contracted body (C-style range only)

**Series**: Issue 4/6 of the moonbit_doubleML formal-verification
toolchain gap. See `_verify/UPSTREAM_BLOCKERS.md` for the master
document and issues 1, 2, 3, 5, 6 for the related restrictions.

**Reporter**: `ren-yongxiang` (moonbit_doubleML project, v0.52.0+)
**Affected toolchain**: `moon 0.1.20260920 (914d7da 2026-09-20)` /
`moonc v0.10.11`; originally observed on v0.10.11, reproduced on
v0.10.12+1634b282e, still present on the v0.52.0 release toolchain.
**Priority**: low (cosmetic; C-style range works as a workaround)

---

## Symptom

Inside a contracted function body, `for x in v` (where `v` is an
`Array[T]` or `FixedArray[T]`) is rejected by `moonc prove`. Only
`for i = 0; i < N; i = i + 1` (the C-style range form, with a
single Int binder `i`) is accepted.

## Audit diagnostic feedback (finding A4)

Same shape as audit finding A3 (Issue 3): the minimal reproducer
at `moonbit_doubleML/_verify/audit_bucket4_foreach/foreach_test.mbt`
causes `moonc prove` to fail with the help-text error
`moonc prove [options] <input files>` (not a clean
"`for x in v` not supported" diagnostic). A user who tries
`for x in arr` in a contracted body will not see a clean
diagnostic.

## Minimal reproducer

`moonbit_doubleML/_verify/audit_bucket4_foreach/foreach_test.mbt`:

```moonbit
pub fn sum_array(arr : Array[Int]) -> Int where {
  proof_require: arr.length() > 0,
  proof_ensure: result => result > 0,
} {
  let mut total = 0
  for x in arr {
    total = total + x
  }
  total
}
```

`moon prove _verify/audit_bucket4_foreach` output: the help-text
error `moonc prove [options] <input files>` (no clean
"`for x in v`" diagnostic). See
`moonbit_doubleML/_verify/audit_bucket4_foreach/prove.log`.

The same help-text error fires for `for x in 0..<n` (the
single-binder Int range form), not just the `for x in arr` form.
The reproducer cannot be tested in isolation because the test
package becomes un-provable in any shape that uses
`for x in <range>`.

## Workaround (verified)

```moonbit
pub fn sum_array(arr : Array[Int]) -> Int where {
  proof_require: arr.length() > 0,
  proof_ensure: result => result > 0,
} {
  let mut total = 0
  for i = 0; i < arr.length(); i = i + 1 {
    total = total + arr[i]
  }
  total
}
```

This compiles and proves (no errors) under `moon prove`.

## Confirmation

Pilot 2's `_prove_pilot2/probe_int.mbt` hit this when the body
used `for x in v` to iterate the input array. The C-style
rewrite is the moonbit_doubleML convention in contracted scope.

The v0.52.0 main-package contract integration attempt on
`kfold_stratified` did not trigger this on its body (it already
uses C-style range throughout — `for k = 0; k < arr.length(); k = k + 1`
at kfold.mbt:331, 338, 342 etc., all already C-style by v0.51+
convention). The `kfold_stratified` body is therefore a "negative
confirmation" of this issue: pre-existing C-style code passes
through `moon prove` with no foreach rejections.

## Suggested fix

Extend the `for` desugaring in the proof frontend to accept
arbitrary single-binder iterables. Multi-binder `for`
(`for (i, x) in arr.enumerates()`) is presumably out of scope.

And emit a clean diagnostic on rejection (see audit finding A4).

## Impact

Cosmetic for most code, but the rewrite is mandatory in the
contract scope, which can clutter the source and obscure the
predicate intent.

## Pilot artifacts

All paths are under the current project root
`moonbit_doubleML/` (project was renamed from `dml-moonbit` in
commit `5d79625`).

- `_verify/audit_bucket4_foreach/foreach_test.mbt` — minimal
  reproducer (help-text error).
- `_verify/audit_bucket4_foreach/prove.log` — full log.
- `_verify/UPSTREAM_BLOCKERS.md` — master document (audit finding
  A4 in the v0.52 reproduction audit section).

## Status as of v0.52.0 release (2026-09-19)

v0.52.0 shipped with all 21 DML estimators working (4 backends ×
331/331 tests PASS, 11 fuzz 0 violations, 23/23 Python validators
PASS) but **without any of the 6 upstream blockers resolved**.
Production code in moonbit_doubleML has used C-style range
(`for i = 0; i < arr.length(); i = i + 1`) in all contracted-
scope loops since v0.51.0 specifically to anticipate this issue,
so the v0.52.0 source already complies with the workaround.
Resolving this issue would let contracted bodies use
`for x in arr` (more idiomatic MoonBit) without conversion cost.

These 6 drafts are ready for filing upstream against
<https://github.com/moonbitlang/core> (or the equivalent
`moonbitlang/moon` proof-frontend repo, depending on how the
toolchain project is organized).

## Acknowledgements

The moonbit_doubleML project is a pure-MoonBit port of
<https://github.com/DoubleML/doubleml-for-py>. The 21 estimators
covered in moonbit_doubleML v0.52.0 are the test surface for these
restrictions.