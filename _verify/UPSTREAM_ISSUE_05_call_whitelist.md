# `moon prove`: only `#proof_pure` / primitive-operator calls allowed in contracted bodies

**Series**: Issue 5/6 of the moonbit_doubleML formal-verification
toolchain gap. See `_verify/UPSTREAM_BLOCKERS.md` for the master
document and issues 1, 2, 3, 4, 6 for the related restrictions.

**Reporter**: `ren-yongxiang` (moonbit_doubleML project, v0.52.0+)
**Affected toolchain**: `moon 0.1.20260920 (914d7da 2026-09-20)` /
`moonc v0.10.11`; originally observed on v0.10.11, reproduced on
v0.10.12+1634b282e, still present on the v0.52.0 release toolchain.
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
- `kfold.mbt:303-347` — main-package call sites that fire this
  restriction (kfold_stratified body in production source).
- `_verify/UPSTREAM_BLOCKERS.md` — master document (New Block A
  in the v0.52 reproduction log section).

## Status as of v0.52.0 release (2026-09-19)

v0.52.0 shipped with all 21 DML estimators working (4 backends ×
331/331 tests PASS, 11 fuzz 0 violations, 23/23 Python validators
PASS) but **without any of the 6 upstream blockers resolved** —
production code in moonbit_doubleML builds folds/vectors freely
without `#proof_pure` annotations, because no DML estimator body
has a proof contract attached at all. The `_prove_pilot`
directory's `kfold_view.mbt` (which is the only file with a
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
<https://github.com/DoubleML/doubleml-for-py>. The 21 estimators
covered in moonbit_doubleML v0.52.0 are the test surface for these
restrictions.