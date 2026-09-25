# `moon prove`: `try { ... } catch { ... }` and array-literal expressions rejected in contracted bodies

**Series**: Issue 6/6 of the moonbit_doubleML formal-verification
toolchain gap. See `_verify/UPSTREAM_BLOCKERS.md` for the master
document and issues 1, 2, 3, 4, 5 for the related restrictions.

**Reporter**: `ren-yongxiang` (moonbit_doubleML project, v0.52.0+)
**Affected toolchain**: `moon 0.1.20260920 (914d7da 2026-09-20)` /
`moonc v0.10.11`; originally observed on v0.10.11, reproduced on
v0.10.12+1634b282e, still present on the v0.52.0 release toolchain.
**Priority**: high (frontend extension; required for the
v0.48.0 cascade wrap pattern)

**New restriction** (not in the original 4-blocker summary; surfaced
during the v0.52 main-package attempt).

---

## Symptom

Inside a contracted function body, the following expressions are
rejected by `moonc prove`:

- `try { ... } catch { ... }` (block expression)
- `let x : Array[T] = []` (array literal initialization)
- `(key, [i])` (tuple literal with array literal)
- `[i]` (array literal)

All four surface as
`unsupported expression in contracted function body`.

The v0.52.0 main-package contract integration attempt reproduced
this on **19 / 80 errors = 24%** of the total.

## Why this is especially load-bearing

The moonbit_doubleML v0.48.0 release added a `PreconditionError`
cascade wrap: every `require` call is wrapped in

```moonbit
try {
  require(...)
} catch {
  PreconditionError::Violated(loc) =>
    abort("precondition failed at " + loc.to_string())
}
```

to preserve abort behavior at every call site. The very first
statement of **every** DML estimator's body is a
`try { ... } catch { ... }` shim. So this issue is not just a
stylistic restriction — it makes the v0.48.0 cascade wrap
un-provable at the function-body level.

A DML estimator body that builds a fold/vector necessarily
contains at least one array-literal expression (`[]`, `[i]`,
or `(key, [i])`). The v0.52.0 main-package attempt fired this on
every array-literal site in `kfold_stratified`.

## Suggested fix

Extend the proof frontend's expression support to accept:

- `try { ... } catch { ... }` (block expression), with the catch
  arm treated as opaque in the proof context.
- Array literal initialization `let x : Array[T] = []` and
  `[i]` (when the element type is provable from context).
- Tuple literals `(a, b, c)` when each component is provable.

## Impact

This blocks the v0.52.0 main-package attempt entirely, even with
Issues 1, 2, 3, 4, 5 fixed. The moonbit_doubleML v0.48.0 cascade
wrap is the v0.48+ idiomatic precondition pattern; rejecting
it means the contract scope and the production source can't
share the same function body.

The workaround is to split the body: a non-contracted helper
holds the `try { ... } catch { ... }` shim, and the contracted
function body contains only `#proof_pure` calls. This is the
approach recommended in the v0.52 reproduction log's
"Handoff" section, but it is invasive: the v0.48.0 cascade
wrap is at the estimator level, and a refactor that splits
every estimator's first statement is a substantial change.

## Pilot artifacts

All paths are under the current project root
`moonbit_doubleML/` (project was renamed from `dml-moonbit` in
commit `5d79625`).

- `_verify/audit-scratch-v0.52_categorization.csv` —
  audit-scratch mirror of `kfold_stratified` (exhibits this
  restriction on 14 sites categorized as `expr_body`; the audit-
  scratch directory was archived at v0.52.0 release time, log +
  categorization preserved as sibling files).
- `_verify/audit-scratch-v0.52_prove.log` — full 80-error log.
- `kfold.mbt:266-274, 280, 292, 298, 317, 319, 320, 347` —
  main-package sites that fire this restriction (kfold_stratified
  body in production source — `try { require(...) } catch { ... }`
  shim at lines 266-274 plus array-literal sites at 280, 292,
  298, 317, 319, 320, 347).
- `_verify/UPSTREAM_BLOCKERS.md` — master document (New Block B
  in the v0.52 reproduction log section).

## Status as of v0.52.0 release (2026-09-19)

v0.52.0 shipped with all 21 DML estimators working (4 backends ×
331/331 tests PASS, 11 fuzz 0 violations, 23/23 Python validators
PASS) but **without any of the 6 upstream blockers resolved** —
production code in moonbit_doubleML keeps the v0.48.0 cascade wrap
(`try { require(...) } catch { ... abort(...) }`) at the top of
every estimator body because production does not use formal
contracts. The wrap is *not* moved into a non-contracted helper
in v0.52.0 because there is no contract at all. Resolving this
issue is a prerequisite for any future v0.53+ attempt to add
contracts to DML estimator bodies — at which point the v0.48.0
cascade wrap would have to be either (a) lifted to a non-
contracted helper, or (b) supported directly in the proof
frontend (preferred, per the "Suggested fix" section).

These 6 drafts are ready for filing upstream against
<https://github.com/moonbitlang/core> (or the equivalent
`moonbitlang/moon` proof-frontend repo, depending on how the
toolchain project is organized).

## Acknowledgements

The moonbit_doubleML project is a pure-MoonBit port of
<https://github.com/DoubleML/doubleml-for-py>. The 21 estimators
covered in moonbit_doubleML v0.52.0 are the test surface for these
restrictions.