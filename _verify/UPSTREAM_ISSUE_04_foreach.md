# `moon prove`: `for x in arr` foreach rejected in contracted body (C-style range only)

> **Historical record. Read the status line, not the census.**
>
> This file was committed on 2026-09-25 as `3965c111` ("global-review: tighten CI Python loop + sync estimator/example counts in docs"). It
> describes the tree at `v0.52.0` (2026-09-19), plus the proof-toolchain
> observations of 2026-09-03 to 2026-09-12.
>
> **What has changed since**, measured 2026-10-20:
>
> | | at `v0.52.0` (2026-09-19) | now |
> |---|---|---|
> | the restriction described here | last *observed* on `moonc v0.10.11` / `v0.10.12` | **re-audited 2026-10-20 on `moonc v0.10.16+b1a0e846e`**: `for x in arr` still fires, with a **clean diagnostic** -- audit finding A4 is obsolete; but `for x in 0..<n` is now **accepted**, and the "workaround (verified)" snippet no longer compiles clean |
> | estimator structs (`DoubleML*` minus `*Data`) | 22 | 22, unchanged |
> | `validate_*_with_python.py` | 23 | 24 |
> | native tests | 329 | 1117 |
> | package layout | flat at the repository root | `moonbit_doubleML/` |
>
> **What is NOT verified here.** The proof *outcome* -- whether an accepted
> contract actually proves -- cannot be observed on native Windows, because
> `moon prove` cannot create its Why3 output directory there
> (`anomaly: Unix.Unix_error(Unix.EINVAL, "mkdir", "\\?")`). The 2026-10-20
> re-audit therefore measures what the proof *frontend* accepts and rejects,
> which is a weaker but still real result. See
> `_verify/upstream_prove_1649/README.md`.
**Series**: Issue 4/6 of the moonbit_doubleML formal-verification
toolchain gap. See `_verify/UPSTREAM_BLOCKERS.md` for the master
document and issues 1, 2, 3, 5, 6 for the related restrictions.

**Reporter**: `ren-yongxiang` (moonbit_doubleML project, v0.52.0+)
**Affected toolchain (when observed)**: `moon 0.1.20260920 (914d7da
2026-09-20)` / `moonc v0.10.11`; originally observed on v0.10.11, reproduced
on v0.10.12+1634b282e, still present on the v0.52.0 release toolchain.
**Re-audited 2026-10-20** on `moon 0.1.20261016 (1af328f 2026-10-16)` /
`moonc v0.10.16+b1a0e846e`; see the banner above and
`_verify/upstream_prove_1649/`.
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

> **Re-audit, 2026-10-20 — this section no longer describes the
> toolchain.** On `moonc v0.10.16+b1a0e846e` the standalone reproducer
> produces a clean diagnostic that names the restriction exactly:
>
> ```
> Error: [4207]  ... only single-binder I32 range foreach loops are
>                  supported in contracted function bodies
> ```
>
> And the same message was already reaching the **main package** in
> September: `_prove_pilot2_error.txt` (tracked) contains that exact
> string for `quantile.mbt:20:3`. So a user *did* see a clean
> diagnostic for the foreach in September; the help-text dump was
> specific to the standalone reproducer package, and the toolchain has
> since fixed that too. The *restriction* is unchanged: `for x in arr`
> is still rejected. Case and log:
> `_verify/upstream_prove_1649/cases/b4_foreach/` and
> `_verify/upstream_prove_1649/out/b4_foreach.log`.

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

> **Re-audit, 2026-10-20 — the `for x in 0..<n` claim is now false.**
> The current toolchain **accepts** a single-binder Int range foreach:
> the case `_verify/upstream_prove_1649/cases/b4r_range_foreach/`
> produces **zero** frontend errors, against 2 for the `for x in arr`
> shape. The toolchain's own message says as much -- "only single-binder
> I32 range **range** foreach loops are supported". So the two forms are
> different restrictions, and only the array-iterating form is
> restricted.

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

> **Re-audit, 2026-10-20 — "compiles and proves (no errors)" no longer
> holds for this snippet.** The snippet above is exactly the case
> `_verify/upstream_prove_1649/cases/b4c_style_control/`, and on
> `moonc v0.10.16` it produces **3** frontend errors: 1x "unsupported
> primitive operator in logic body" and 2x "unsupported primitive
> operator in contracted function body", all of them on `arr.length()`
> and `arr[i]`.
>
> The C-style rewrite fixes the **foreach**; it does not fix the
> **`Array[T]` lowering** (Issue 1), which this snippet still trips.
> The shape the current proof frontend *does* accept is `FixedArray`
> with a C-style range -- the `_prove_pilot` shape -- which is accepted
> with zero frontend errors
> (`_verify/upstream_prove_1649/cases/b1c_fixed_control/`).

## Confirmation

Pilot 2's `_prove_pilot2/probe_int.mbt` hit this when the body
used `for x in v` to iterate the input array. The C-style
rewrite is the moonbit_doubleML convention in contracted scope.

The v0.52.0 main-package contract integration attempt on
`kfold_stratified` did not trigger this on its body (it already
uses C-style range throughout — `for k = 0; k < arr.length(); k = k + 1`
at `kfold.mbt:331, 338, 342` **at `v0.52.0`**, where that file was 657
lines and sat at the repository root; all already C-style by v0.51+
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

  **Both are local-only and git-ignored** — the directory was never
  committed, so a reader cannot obtain them. The 2026-10-20 re-audit
  re-measures the same restriction from a tracked, self-contained case
  (`_verify/upstream_prove_1649/cases/b4_foreach/`) instead.
- `_verify/UPSTREAM_BLOCKERS.md` — master document (audit finding
  A4 in the v0.52 reproduction audit section).

## Status as of v0.52.0 release (2026-09-19)

v0.52.0 shipped with all 22 DML estimators working (4 backends ×
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
<https://github.com/DoubleML/doubleml-for-py>. The 22 estimators
covered in moonbit_doubleML v0.52.0 are the test surface for these
restrictions.