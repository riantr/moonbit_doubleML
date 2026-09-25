# `moon prove`: `Array[T]` Why3 lowering missing `use array.Array`

**Series**: Issue 1/6 of the moonbit_doubleML formal-verification toolchain
gap. See `_verify/UPSTREAM_BLOCKERS.md` for the master document and
issues 2-6 for the related restrictions.

**Reporter**: `ren-yongxiang` (moonbit_doubleML project, v0.52.0+)
**Affected toolchain**: `moon 0.1.20260920 (914d7da 2026-09-20)` /
`moonc v0.10.11`; originally observed on v0.10.11, reproduced on
v0.10.12+1634b282e, still present on the v0.52.0 release toolchain.
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
errors, all of the form "unsupported primitive operator / expression
in logic body" or "unbound type symbol".

The v0.52.0 main-package contract integration attempt on
`kfold_stratified` reproduced this on **45 / 80 errors = 56%** of the
total `Error: [4207]` count. The bucket covers every `arr.length()`,
`arr[i]`, `arr.push`, `Array::make`, `Array::makei`, `Array.swap`,
plus `folds[f].train_idx` (Fold's `Array[Int]` field) in either the
body or the `.mbtp` predicate. Sites (line numbers reference the
audit-scratch mirror `_verify/audit-scratch-v0.52/kfold_view.mbt`,
file archived, log + categorization preserved):
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

This is the single biggest blocker. Without it, `moon prove` on a
package that uses `Array[T]` anywhere produces 45+ errors out of
the box. With it fixed (and the other 5 restrictions in place), the
predicate side unblocks cleanly and only the body-side rejections
remain (which are issues 3-6 of this series).

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
- `_verify/QUANTILE_HANDOFF.md` — full Pilot 2 narrative.
- `_verify/audit-scratch-v0.52_categorization.csv` +
  `_verify/audit-scratch-v0.52_categorization.txt` — main-package
  `kfold_stratified` audit-scratch mirror (56-site categorization;
  audit-scratch directory archived at release time, logs/CSV/TXT
  preserved as sibling files; `.gitignore` patterns
  `audit-scratch*` no longer match).
- `_verify/audit-scratch-v0.52_prove.log` — full 80-error
  reproduction log.
- `_verify/UPSTREAM_BLOCKERS.md` — the 6-blocker + reproduction log
  + audit (master document).

## Status as of v0.52.0 release (2026-09-19)

v0.52.0 shipped with all 21 DML estimators working (4 backends ×
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
toolchain; reproduction log + audit at
`_verify/audit-scratch-v0.52_*.{log,csv,txt}` is the source of
truth for the 45 / 80 = 56% figure.

These 6 drafts are ready for filing upstream against
<https://github.com/moonbitlang/core> (or the equivalent
`moonbitlang/moon` proof-frontend repo, depending on how the
toolchain project is organized).

## Acknowledgements

The moonbit_doubleML project is a pure-MoonBit port of
<https://github.com/DoubleML/doubleml-for-py>. The 21 estimators
covered in moonbit_doubleML v0.52.0 are the test surface for these
restrictions.