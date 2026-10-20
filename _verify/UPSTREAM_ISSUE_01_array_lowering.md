# `moon prove`: `Array[T]` Why3 lowering missing `use array.Array`

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
> | the restriction described here | last *observed* on `moonc v0.10.11` / `v0.10.12` | **re-audited 2026-10-20 on `moonc v0.10.16+b1a0e846e`**: still fires (3 frontend errors per isolated case); the `unbound type symbol 'array'` symptom text is not what the current toolchain reports |
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
**Series**: Issue 1/6 of the moonbit_doubleML formal-verification toolchain
gap. See `_verify/UPSTREAM_BLOCKERS.md` for the master document and
issues 2-6 for the related restrictions.

**Reporter**: `ren-yongxiang` (moonbit_doubleML project, v0.52.0+)
**Affected toolchain (when observed)**: `moon 0.1.20260920 (914d7da
2026-09-20)` / `moonc v0.10.11`; originally observed on v0.10.11, reproduced
on v0.10.12+1634b282e, still present on the v0.52.0 release toolchain.
**Re-audited 2026-10-20** on `moon 0.1.20261016 (1af328f 2026-10-16)` /
`moonc v0.10.16+b1a0e846e`; see the banner above and
`_verify/upstream_prove_1649/`.
**Priority**: highest (single-line toolchain fix; unblocks `moon prove`
for the entire main package, even with the other 5 restrictions in
place)

---

## Symptom

When `options("proof-enabled": true)` is set on a package whose
`.mbt` files reference `Array[T]` (either in struct fields OR in
function parameters), `moonc prove` lowers to Why3 and the generated
`.mlw` defines types like:

```why3
type mavis__moonbit_doubleML__Matrix = { ..., mavis__moonbit_doubleML__Matrix__data : array int }
```

The lowering does **not** emit `use array.Array` in the module
preamble. Why3 then fails with:

> `unbound type symbol 'array'`

## Confirmed scope (not struct-field-specific)

Pilot 1's kfold reproducer triggered this on a struct field
(`Fold::new` with `Array[Int]`). Pilot 2's quantile reproducer
triggered the same error on a **single function parameter** with no
struct involved:

```moonbit
pub fn array_min(arr : Array[Double]) -> Double raise EmptyArrayError {
  // ...
}
```

Pilot 2's `moon prove .` on the main package produced 8 distinct
errors. The captured log is `_prove_pilot2_error.txt` (tracked), and
its 8 diagnostics are, in order: 3x "unsupported primitive operator in
logic body", 3x "unsupported primitive operator in contracted function
body", 1x "unsupported expression in contracted function body" (the
`raise`) and 1x "only single-binder I32 range foreach loops are
supported in contracted function bodies" (the `for x in v`).

So they are the same *class* as the main-package Bucket 1 errors
("unsupported primitive operator", on `v.length()` and `v[0]`), but
**not** "unbound type symbol" -- that string does not appear in the
log.

The v0.52.0 main-package contract integration attempt on
`kfold_stratified` reproduced this on **45 / 80 errors = 56%** of the
total `Error: [4207]` count. The bucket covers every `arr.length()`,
`arr[i]`, `arr.push`, `Array::make`, `Array::makei`, `Array.swap`,
plus `folds[f].train_idx` (Fold's `Array[Int]` field) in either the
body or the `.mbtp` predicate. Sites (line numbers reference the
audit-scratch mirror `_verify/audit-scratch-v0.52/kfold_view.mbt`;
**that mirror is local-only and git-ignored**, so these pointers are
not checkable from a clone -- see `_verify/UPSTREAM_BLOCKERS.md`,
"Audit-scratch cleanup"):
`kfold_view.mbt:50, 61-65, 75-82, 84-91` (body-side `arr.length()` /
`arr[i]` / `Array::make` / `Array::makei` / `arr.push` /
`@random.Rand::chacha8`-initialized arrays);
`kfold_view_proof.mbtp:26, 33, 34-36, 41, 42, 44, 53-57` (predicate-
side `Fold.train_idx` / `Fold.test_idx` references).

## Suggested fix

One-line change in `moonc prove`'s WhyML code generator: emit
`use array.Array` in the package preamble whenever any `.mbt` file
in the package references `Array[T]`.

## Workarounds tried (all partial)

- `#proof_import("moonbit_builtin_prelude.FixedArray")` — same error.
- `MOON_PROVE_PRELUDE_OVERRIDE` with a modified prelude re-exporting
  `array.Array` — override honored, but package-level `use` statements
  for `FixedArray` and `use array.Array` are not auto-propagated.
- Restricting the contract to `FixedArray[Int]` (Pilot 1 mirror
  pattern) — works, but is invasive for codebases that use
  `Array[T]` in their public surface.

## Impact

This is the single biggest blocker **in the v0.52.0 main-package
measurement** (45 / 80 = 56% of the errors). Without it, `moon prove`
on a package that uses `Array[T]` anywhere produces that many errors
out of the box. With it fixed (and the other 5 restrictions in place),
the predicate side unblocks cleanly and only the body-side rejections
remain (which are issues 3-6 of this series).

**Re-audit, 2026-10-20**: the restriction still fires, and it is still
the widest of the 4 + 2 in the sense that it blocks *every* contract
that touches an `Array[T]`. Measured per isolated case on `moonc
v0.10.16`: 3 frontend errors each for the parameter shape and for the
struct-field shape (1x "unsupported primitive operator in logic body"
+ 2x "unsupported primitive operator in contracted function body"), and
the `FixedArray` + C-style control is **accepted**. The `unbound type
symbol 'array'` symptom text above is the September toolchain's wording;
the current toolchain reports "unsupported primitive operator" instead.
Cases: `_verify/upstream_prove_1649/cases/`.

## Pilot artifacts

All paths are under the current project root
`moonbit_doubleML/` (project was renamed from `dml-moonbit` in
commit `5d79625`).

- `_prove_pilot/kfold_view.mbt` + `_prove_pilot/kfold_view_proof.mbtp`
  — Pilot 1, uses `FixedArray[Int]` workaround successfully,
  `moon prove _prove_pilot`: 17v/2t on the kfold surface.
- `_prove_pilot2/probe_int.mbt` — uses `FixedArray[Int]`, 5v/3t.
- `_prove_pilot2_error.txt` — captured main-package probe error
  trace, 8 distinct `moonc prove` errors.
- `QUANTILE_HANDOFF.md` — full Pilot 2 narrative. (At the repository root,
  not under `_verify/`; tracked there since before `v0.52.0`.)
- `_verify/audit-scratch-v0.52_categorization.csv` +
  `_verify/audit-scratch-v0.52_categorization.txt` — main-package
  `kfold_stratified` audit-scratch mirror (56-site categorization;
  **local-only and git-ignored** — neither the mirror directory nor
  these siblings were ever committed, so they are not obtainable from a
  clone).
- `_verify/audit-scratch-v0.52_prove.log` — full 80-error
  reproduction log (**local-only and git-ignored**, same reason).
- `_verify/UPSTREAM_BLOCKERS.md` — the 6-blocker + reproduction log
  + audit (master document).

## Status as of v0.52.0 release (2026-09-19)

v0.52.0 shipped with all 22 DML estimators working (4 backends ×
331/331 tests PASS, 11 fuzz 0 violations, 23/23 Python validators
PASS) but **without any of the 6 upstream blockers resolved** —
production code does not use formal contracts; the v0.48.0 cascade
wrap (`try { require(...) } catch { ... abort(...) }` at the top of
every estimator body) handles preconditions outside the proof
frontend. The `_prove_pilot` directory's `FixedArray[Int]`
workaround remains the only path that `moon prove` accepts at all,
and it is restricted to the pilot's surface (kfold + quantile views
only). The main-package contract integration attempt against
`kfold_stratified` remains NOT VIABLE on the v0.52.0 release
toolchain. The 45 / 80 = 56% figure is the record's own measurement;
the reproduction log and audit it came from
(`_verify/audit-scratch-v0.52_*.{log,csv,txt}`) are **local-only and
git-ignored**, so the figure is not re-derivable from a clone. The
2026-10-20 re-audit in `_verify/upstream_prove_1649/` re-measures the
restriction itself from scratch instead.

These 6 drafts are ready for filing upstream against
<https://github.com/moonbitlang/core> (or the equivalent
`moonbitlang/moon` proof-frontend repo, depending on how the
toolchain project is organized).

## Acknowledgements

The moonbit_doubleML project is a pure-MoonBit port of
<https://github.com/DoubleML/doubleml-for-py>. The 22 estimators
covered in moonbit_doubleML v0.52.0 are the test surface for these
restrictions.