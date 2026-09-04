# Upstream Toolchain Blockers — MoonBit 0.9+ `moon prove` Pipeline

**Discovered during**: dml-moonbit v0.48.0 formal verification pilot
**Reporter**: `ren-yongxiang` (gitee)
**Pilot evidence**: `_prove_pilot/` and `_prove_pilot2/` in dml-moonbit
**Toolchain**: moon v0.10.11+, Why3 1.7.2, CVC5 1.0.9 / Alt-Ergo 2.5.4

These four blockers prevent the dml-moonbit main package's `moon prove`
from running end-to-end on contracts that reference `Array[T]`, use
`Double` arithmetic, or wrap contracts around `raise` boundaries.
Fixing them would unlock formal verification of the 15+ DML estimators
in dml-moonbit (PLR / IRM / PLIV / IIVM / DID family / PLPR / LPLR /
bootstrap / quantiles / resampling / cluster-robust SE).

---

## Blocker 1 (highest priority): `Array[T]` → `array` Why3 lowering missing `use array.Array`

### Symptom

When `options("proof-enabled": true)` is set on a package whose `.mbt`
files reference `Array[T]` (either in struct fields OR in function
parameters), `moonc prove` lowers to Why3 and the generated `.mlw`
defines types like:

```why3
type mavis_dml__Matrix = { ..., mavis_dml__Matrix__data : array int }
```

The lowering does **not** emit `use array.Array` in the module
preamble. Why3 then fails with:

> `unbound type symbol 'array'`

### Confirmed scope (not struct-field-specific)

The Pilot 1 (kfold) reproducer triggered the error on a struct field
(`Fold::new` with `Array[Int]`). The Pilot 2 (quantile) reproducer
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

### Suggested fix

One-line change in `moonc prove`'s WhyML code generator: emit
`use array.Array` in the package preamble whenever any `.mbt` file in
the package references `Array[T]`.

### Workarounds tried (all partial)

- `#proof_import("moonbit_builtin_prelude.FixedArray")` — same error.
- `MOON_PROVE_PRELUDE_OVERRIDE` with a modified prelude re-exporting
  `array.Array` — override honored, but package-level `use` statements
  for `FixedArray` and `use array.Array` are not auto-propagated.
- Restricting the contract to `FixedArray[Int]` (Pilot 1 mirror
  pattern) — works, but is invasive for codebases that use `Array[T]`
  in their public surface.

### Pilot artifacts

- `_prove_pilot/` (uses `FixedArray[Int]` workaround successfully,
  17v/2t on the kfold surface).
- `_prove_pilot2/probe_int.mbt` (uses `FixedArray[Int]`, 5v/3t).
- `_prove_pilot2_error.txt` (captured main-package probe error trace,
  8 distinct `moonc prove` errors).
- `_verify/QUANTILE_HANDOFF.md` — full Pilot 2 narrative.

---

## Blocker 2: `Double` comparison primitives not supported in proof pipeline

### Symptom

Inside any `proof_require` / `proof_ensure` / `proof_invariant` /
contracted function body, the primitive operators `<`, `>`, `<=`, `>=`,
`==` on `Double` values are rejected by `moonc prove`. Integer
comparisons work fine.

### Confirmation

Pilot 2's `_prove_pilot2/quantile_view.mbt` (a `FixedArray[Double]`
mirror of `quantile.mbt::array_min`) hit this on every `<` in a
`proof_require: v[i] < result` and on `result < v[i]` in a
`proof_ensure`. The kfold pilot did not expose this because its
contracts used `Int` only.

### Suggested fix

Either:
- (preferred) extend the proof frontend's primitive-operator support
  to include `Double` comparisons.
- (workaround) require users to compare `Double` values via
  helper predicates defined in `.mbtp` (the helpers would carry the
  comparison logic in a form the prover can reason about).

### Impact

All numerical contracts are blocked. Without this fix, dml-moonbit's
15 estimators (which all compute on `Double` arrays) cannot be
verified, even with Blocker 1 resolved.

---

## Blocker 3: `raise X` in contracted function body rejected

### Symptom

A function declared with `-> T raise EmptyArrayError` whose body
contains `raise EmptyArrayError(...)` is rejected by `moonc prove`:

> "raise" in contracted function body is not supported

The `raise` boundary is fine in a non-contracted function (e.g. as
the body of an `apply_calibration` helper that is itself wrapped in
`try { ... } catch { ... }`). The rejection only fires when the
`raise` is inside a body that has a `where { proof_*: ... }` block
attached.

### Confirmation

Pilot 2 attempted to contract `quantile.mbt::array_min` with a
`proof_require: v.length() > 0` and an explicit `raise
EmptyArrayError` in the body. The contract lowered but the body
`raise` was flagged. Workaround: rewrite the contract so the
`raise` is in a sub-helper, with the contracted function's body
catching the `raise` and propagating as a return value — but this
loses the typed error contract for end users.

### Suggested fix

Allow `raise` in a contracted function body, as long as the
raised suberror type is either:
- (a) the same as the function's declared `raise X` (already
  declared in the signature), or
- (b) a sub-error that the caller would need to catch anyway.

### Impact

Most DML estimators have a `try { ... } catch { ... }` shim around
their `check`/`require` calls (added in v0.48.0 to preserve abort
behavior). Contracting these estimators without first resolving
this blocker is awkward; the contract must be at the shim level,
not the inner function.

---

## Blocker 4: `for x in arr` foreach (only single-binder I32 range supported)

### Symptom

Inside a contracted function body, `for x in v` (where `v` is an
`Array[T]` or `FixedArray[T]`) is rejected by `moonc prove`. Only
`for i = 0; i < N; i = i + 1` (the C-style range form, with a
single Int binder `i`) is accepted.

### Confirmation

Pilot 2's `_prove_pilot2/probe_int.mbt` hit this when the body used
`for x in v` to iterate the input array. Workaround: rewrite as
`for i = 0; i < v.length(); i = i + 1` with `v[i]` access. The
`moonfmt` style prefers the former, so this requires a manual
rewrite for the contract scope.

### Suggested fix

Extend the `for` desugaring in the proof frontend to accept arbitrary
single-binder iterables. Multi-binder `for` (`for (i, x) in
arr.enumerates()`) is presumably out of scope.

### Impact

Cosmetic for most code, but the rewrite is mandatory in the
contract scope, which can clutter the source and obscure the
predicate intent.

---

## Priority recommendation

1. **Blocker 1** (Array lowering) — fix first. Unblocks `moon prove`
   for the entire main package, even with the other 3 blockers
   in place. Single-line toolchain fix.
2. **Blocker 2** (Double comparisons) — fix second. Unlocks all
   numerical contracts. Frontend extension.
3. **Blocker 3** (raise in body) — fix third. Frontend extension.
4. **Blocker 4** (for x in arr) — fix last. Cosmetic.

With 1+2+3+4 fixed, dml-moonbit can resume formal verification on
the 15+ DML estimators in the main package. Without 1, only the
`FixedArray[Int]` mirror pattern in `_prove_pilot/` can be used,
which limits verified surface to pure Int algorithms.

---

## References

- dml-moonbit project: `https://gitee.com/ren-yongxiang/moonbit_double-ml`
- Pilot 1 handoff: `_prove_pilot/HANDOFF.md`
- Pilot 1 verifier audit: `_prove_pilot/VERIFIER_AUDIT.md` (v1) +
  `_prove_pilot/VERIFIER_AUDIT_v2.md` (v2 with v3 correction + v4
  self-review)
- Pilot 2 handoff: `QUANTILE_HANDOFF.md`
- MoonBit verification docs: `https://docs.moonbitlang.com/en/stable/language/verification.html`
- Verified example packages: `https://github.com/moonbit-community/verified`
- 100+ compact proof exercises: `https://github.com/Yu-zh/moonbit-proof`
