# `moon prove`: `raise X` in contracted function body rejected

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
> | the restriction described here | last *observed* on `moonc v0.10.11` / `v0.10.12` | **re-audited 2026-10-20 on `moonc v0.10.16+b1a0e846e`**: still fires, with a **clean diagnostic** -- audit finding A3 is obsolete |
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
**Series**: Issue 3/6 of the moonbit_doubleML formal-verification
toolchain gap. See `_verify/UPSTREAM_BLOCKERS.md` for the master
document and issues 1, 2, 4-6 for the related restrictions.

**Reporter**: `ren-yongxiang` (moonbit_doubleML project, v0.52.0+)
**Affected toolchain (when observed)**: `moon 0.1.20260920 (914d7da
2026-09-20)` / `moonc v0.10.11`; originally observed on v0.10.11, reproduced
on v0.10.12+1634b282e, still present on the v0.52.0 release toolchain.
**Re-audited 2026-10-20** on `moon 0.1.20261016 (1af328f 2026-10-16)` /
`moonc v0.10.16+b1a0e846e`; see the banner above and
`_verify/upstream_prove_1649/`.
**Priority**: medium (frontend extension; required for DML
estimator precondition shims)

---

## Symptom

A function declared with `-> T raise EmptyArrayError` whose body
contains `raise EmptyArrayError(...)` is rejected by `moonc
prove`:

> "raise" in contracted function body is not supported

The `raise` boundary is fine in a non-contracted function (e.g. as
the body of an `apply_calibration` helper that is itself wrapped in
`try { ... } catch { ... }`). The rejection only fires when the
`raise` is inside a body that has a `where { proof_*: ... }` block
attached.

## Audit diagnostic feedback (finding A3)

The minimal reproducer for this issue does **not** produce the
clean "raise in contracted function body is not supported"
diagnostic. Instead, `moonc prove` exits with the help-text error
`moonc prove [options] <input files>`, indicating that the moonc
binary received no valid input file. The same help-text error
fires for any non-trivial body shape (any function whose body has
a `raise` typed signature). A user who tries to convert
`try { require() } catch { abort() }` to `raise
PreconditionError` will not see a clear diagnostic — they will see
the moonc help text and have to manually diagnose why the package
is un-provable.

A clean per-class diagnostic would let users pinpoint the issue
without reading moonc source.

> **Re-audit, 2026-10-20 — this section no longer describes the
> toolchain.** On `moonc v0.10.16+b1a0e846e` the same standalone
> reproducer produces a clean, specific diagnostic instead of the
> help-text dump:
>
> ```
> Error: [4207]  ... unsupported expression in contracted function body
> ```
>
> One error, one location, named. The missing-diagnostic problem this
> section describes has been fixed upstream, so there is no longer
> anything to file on that point. The *restriction* is unchanged: the
> `raise` is still rejected in a contracted body. Case and log:
> `_verify/upstream_prove_1649/cases/b3_raise_body/` and
> `_verify/upstream_prove_1649/out/b3_raise_body.log`.

## Minimal reproducer

`moonbit_doubleML/_verify/test-bucket3-raise/raise_test.mbt` — the source
that actually contains a `raise` in a contracted body. (The path this
section previously named,
`moonbit_doubleML/_verify/audit_bucket3_raise/raise_test.mbt`, holds the
**Bucket 2** Double source instead, and does not exercise Blocker 3 at
all.)

```moonbit
pub suberror SomeError

pub fn foo(x : Int) -> Int raise SomeError where {
  proof_require: x > 0,
} {
  if x <= 0 {
    raise SomeError
  }
  x
}
```

`moon prove _verify/audit_bucket3_raise` output: the help-text
error `moonc prove [options] <input files>` (no clean "raise in
contracted body" diagnostic). See
`moonbit_doubleML/_verify/audit_bucket3_raise/prove_v9.log`.

> **The path this section names does not hold the reproducer.**
> `_verify/audit_bucket3_raise/raise_test.mbt` contains the **Bucket 2**
> Double source (`double_cmp(x : Double, n : Int)` with `x < 1.5`), and
> its own header comment says "Minimal reproducer for Blocker 2". The
> `raise` source is the one shown above, in
> `_verify/test-bucket3-raise/`. The `prove_v9.log` in
> `audit_bucket3_raise/` was captured in the pre-rename project
> (`dml-moonbit`), before commit `5d79625` renamed the project to
> `moonbit_doubleML`.
>
> Both paths are local-only and git-ignored; neither is obtainable from
> a clone. The 2026-10-20 re-audit uses a self-contained, tracked case
> instead.

## Sanity check (audit A3)

The same help-text error fires for many different non-trivial body
shapes:

- `pub fn foo(x : Int) -> Int raise SomeError where { ... }` with
  `raise SomeError` in the body → fails.
- `pub fn foo(x : Int) -> Int where { ... }` with no `raise` but
  calling a helper that has `raise` → still fails.
- A bare contracted function with no `raise` at all (sanity check)
  → works (proof runs, no "raise" error).
- Same function with `abort(...)` instead of `raise` → works
  (this is the moonbit_doubleML v0.48.0 cascade wrap's workaround).

## Confirmation

Pilot 2 attempted to contract `quantile.mbt::array_min` with a
`proof_require: v.length() > 0` and an explicit `raise
EmptyArrayError` in the body. The contract lowered but the body
`raise` was flagged. Workaround: rewrite the contract so the
`raise` is in a sub-helper, with the contracted function's body
catching the `raise` and propagating as a return value — but this
loses the typed error contract for end users.

The v0.52.0 main-package contract integration attempt did **not**
trigger this on `kfold_stratified` because the function body uses
`try { require() } catch { abort() }` (no `raise X`). The shim
itself is rejected as **Issue 6 (block expressions)**. The shim
was specifically chosen to bypass this issue on the way to
isolating Issue 1 (Array lowering).

## Suggested fix

Allow `raise` in a contracted function body, as long as the raised
suberror type is either:

- (a) the same as the function's declared `raise X` (already
  declared in the signature), or
- (b) a sub-error that the caller would need to catch anyway.

And emit a clean diagnostic on rejection (see audit finding A3).

## Impact

Most DML estimators have a `try { ... } catch { ... }` shim
around their `check`/`require` calls (added in moonbit_doubleML
v0.48.0 to preserve abort behavior). Contracting these estimators
without first resolving this issue is awkward; the contract must
be at the shim level, not the inner function.

## Pilot artifacts

All paths are under the current project root
`moonbit_doubleML/` (project was renamed from `dml-moonbit` in
commit `5d79625`).

- `_verify/test-bucket3-raise/raise_test.mbt` — minimal
  reproducer (the source that contains the `raise`; the
  `_verify/audit_bucket3_raise/raise_test.mbt` path holds the Bucket 2
  source instead).
- `_verify/audit_bucket3_raise/prove_v9.log` — full log.
- `_verify/UPSTREAM_BLOCKERS.md` — master document (audit finding
  A3 in the v0.52 reproduction audit section).

## Status as of v0.52.0 release (2026-09-19)

v0.52.0 shipped with all 22 DML estimators working (4 backends ×
331/331 tests PASS, 11 fuzz 0 violations, 23/23 Python validators
PASS) but **without any of the 6 upstream blockers resolved** —
the v0.48.0 cascade wrap (`try { require(...) } catch { ... abort(...) }`)
was specifically chosen to avoid this issue at production sites;
`raise PreconditionError` is the v0.48.0 plan that was rolled back
in favor of the `abort(...)`-based shim. Resolving this issue is a
prerequisite for any future v0.53+ attempt to add typed-error
contracts to DML estimator bodies (where `raise PreconditionError`
would replace the `abort` shim).

These 6 drafts are ready for filing upstream against
<https://github.com/moonbitlang/core> (or the equivalent
`moonbitlang/moon` proof-frontend repo, depending on how the
toolchain project is organized).

## Acknowledgements

The moonbit_doubleML project is a pure-MoonBit port of
<https://github.com/DoubleML/doubleml-for-py>. The 22 estimators
covered in moonbit_doubleML v0.52.0 are the test surface for these
restrictions.