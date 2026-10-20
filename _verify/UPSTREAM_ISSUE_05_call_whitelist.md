# `moon prove`: only `#proof_pure` / primitive-operator calls allowed in contracted bodies

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
> | the restriction described here | last *observed* on `moonc v0.10.11` / `v0.10.12` | **re-audited 2026-10-20 on `moonc v0.10.16+b1a0e846e`**: still fires, with a byte-identical message |
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
**Series**: Issue 5/6 of the moonbit_doubleML formal-verification
toolchain gap. See `_verify/UPSTREAM_BLOCKERS.md` for the master
document and issues 1, 2, 3, 4, 6 for the related restrictions.

**Reporter**: `ren-yongxiang` (moonbit_doubleML project, v0.52.0+)
**Affected toolchain (when observed)**: `moon 0.1.20260920 (914d7da
2026-09-20)` / `moonc v0.10.11`; originally observed on v0.10.11, reproduced
on v0.10.12+1634b282e, still present on the v0.52.0 release toolchain.
**Re-audited 2026-10-20** on `moon 0.1.20261016 (1af328f 2026-10-16)` /
`moonc v0.10.16+b1a0e846e`; see the banner above and
`_verify/upstream_prove_1649/`.
**Priority**: high (frontend extension; required for any DML body
that builds a fold or vector)

**New restriction** (not in the original 4-blocker summary; surfaced
during the v0.52 main-package attempt).

---

## Symptom

Inside a contracted function body, calls to functions that are not
explicitly marked `#proof_pure` or `#proof_callable` are rejected
by `moonc prove`:

> `only contracted functions, imported proof-callable functions,
> pure functions, and primitive operators can be called in
> contracted function bodies`

The Pilot 1 / Pilot 2 docs mention this restriction but do not
enumerate which specific call sites it blocks in a real DML body.
The v0.52.0 main-package contract integration attempt on
`kfold_stratified` reproduced this on **16 / 80 errors = 20%** of
the total.

## Failing call sites in moonbit_doubleML v0.52.0

The following call sites fire this restriction on the
moonbit_doubleML `kfold_stratified` body (audit-scratch mirror
line numbers; the audit-scratch directory was archived at v0.52.0
release time, log/csv/txt preserved as sibling files):

- `seed_to_bytes` (8-byte LE helper)
- `@random.Rand::chacha8` (constructor)
- `Bytes::from_array` (constructor)
- `Array::make` (constructor)
- `Array::makei` (constructor)
- `perm.swap` (method)
- `rng.int(limit=...)` (method)
- `stratum_perm.push` (method)
- `train_idx.push` (method)
- `test_idx.push` (method)
- `folds.push` (method)
- `Fold::new(...)` (constructor)

## Why this is especially load-bearing

This is the difference between "the contracted body can call a
small set of pre-approved helpers" and "the contracted body can do
anything a normal body can do, as long as each call is annotated
`#proof_pure`". The current whitelist excludes:

- Every standard library constructor (`Array::make`, `Array::makei`,
  `Fold::new`, `Bytes::from_array`, `@random.Rand::chacha8`).
- Every deterministic `Array` method (`arr.push`, `perm.swap`).
- Every struct constructor in user code (`Fold::new`).

A DML estimator body that builds a fold, vector, or matrix
necessarily calls one of these. The v0.52.0 main-package attempt
fired this on every `Array::make`, `Array::makei`, `Array::push`,
and `Fold::new` in the `kfold_stratified` body.

## Suggested fix

Extend the whitelist to also accept:

- `Array::make` / `Array::makei` (constructors that allocate from
  the value of a function — these are deterministic given their
  input).
- `Array::push` (deterministic mutation, monomorphic on the
  element type).
- Struct constructors (e.g. `Fold::new(...)`) — these are the
  same as `Array::make` modulo the field shape.
- A user-decorated `#proof_safe` annotation that the user
  attaches to a function to opt it in.

The exact minimal whitelist should be discussed, but at minimum
the current restriction blocks any DML body that builds a fold
or vector.

## Impact

This blocks the v0.52.0 main-package attempt entirely, even with
Issues 1, 2, 3, 4 fixed. Without this, the contracted body can
only call `#proof_pure` functions (and primitive operators),
which excludes every DML estimator's body in the current shape.

## Pilot artifacts

All paths are under the current project root
`moonbit_doubleML/` (project was renamed from `dml-moonbit` in
commit `5d79625`).

- `_verify/audit-scratch-v0.52_categorization.csv` —
  audit-scratch mirror of `kfold_stratified` (simplified to
  Int-only contracts, exhibits this restriction on 8 sites
  categorized as `call_body`).
- `_verify/audit-scratch-v0.52_prove.log` — full 80-error log.

  **Both are local-only and git-ignored**: neither the mirror
  directory nor these sibling files was ever committed, so a reader
  cannot obtain them, and the 8-site / 16-site categorisations above
  are not re-derivable from a clone. The 2026-10-20 re-audit
  re-measures the restriction itself from a tracked, self-contained
  case instead.
- `kfold.mbt:303-347` — main-package call sites that fire this
  restriction (kfold_stratified body in production source).
  **These are line numbers at `v0.52.0`**, where `kfold.mbt` was 657
  lines at the repository root. All twelve of the call sites listed
  above fall inside that range; today's
  `moonbit_doubleML/kfold.mbt` is 826 lines, so the pointers no longer
  resolve.
- `_verify/UPSTREAM_BLOCKERS.md` — master document (New Block A
  in the v0.52 reproduction log section).

## Status as of v0.52.0 release (2026-09-19)

v0.52.0 shipped with all 22 DML estimators working (4 backends ×
331/331 tests PASS, 11 fuzz 0 violations, 23/23 Python validators
PASS) but **without any of the 6 upstream blockers resolved** —
production code in moonbit_doubleML builds folds/vectors freely
without `#proof_pure` annotations, because no DML estimator body
has a proof contract attached at all. The `_prove_pilot`
directory's `_prove_pilot/kfold_view.mbt` (which is the only file with a
contract attached) deliberately inlines `Array::make` etc. into a
non-contracted helper, with the contracted function calling
`#proof_pure`-tagged wrappers around them. Resolving this issue
would let the contracted `kfold_view.mbt` body call those
constructors directly without the wrapper split, simplifying the
pilot substantially.

These 6 drafts are ready for filing upstream against
<https://github.com/moonbitlang/core> (or the equivalent
`moonbitlang/moon` proof-frontend repo, depending on how the
toolchain project is organized).

## Acknowledgements

The moonbit_doubleML project is a pure-MoonBit port of
<https://github.com/DoubleML/doubleml-for-py>. The 22 estimators
covered in moonbit_doubleML v0.52.0 are the test surface for these
restrictions.