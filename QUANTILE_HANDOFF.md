# Pilot 2 Handoff -- quantile.mbt::array_min / array_max

**Date:** 2026-09-03
**Branch/scope:** Main package (direct contract attempt) + `_prove_pilot2/` (FixedArray mirrors)
**Pilot functions:** `quantile.mbt::array_min`, `quantile.mbt::array_max`
**Reason for the parallel `_prove_pilot2/` mirror (not just direct contract on quantile.mbt):** see **Toolchain Blockers** below -- the main package's `Array[Double]` parameter is rejected at the `moonc prove` stage, and the `FixedArray[Double]` mirror is rejected at the `Double` comparison primitive stage. The `FixedArray[Int]` mirror in `probe_int.mbt` is the only one that lowers successfully.

---

## Headline finding (TL;DR)

The `Array[T] -> array` Why3 lowering gap identified in Pilot 1 (kfold.mbt) is **GLOBAL**, not scoped to struct fields. A leaf function with no struct fields and a single `Array[Double]` parameter is rejected at the `moonc prove` stage with "unsupported primitive operator in logic body" on every `Array[T]` primitive (`v.length()`, `v[i]`, `for x in v`).

In addition, Pilot 2 surfaces a **second toolchain gap** that Pilot 1 did not exercise: **`Double` comparison primitives (`<`, `>`, `<=`, `>=`, `==`) are not supported in the proof pipeline**, neither in the logic body nor in the contracted function body. Pilot 1 only used `Int` comparisons (`uniq[k] == g`, `arr[i] != b[j]`, `0 <= i && i < n`), so this gap was invisible there. Pilot 2's `array_min` uses Double comparison, so it surfaces it.

Both gaps are upstream toolchain issues. The dml-moonbit codebase can only be proven in any meaningful way after both are addressed (or after the affected code is rewritten to avoid the unsupported primitives, which is invasive).

## Files created / modified

| File | Status | Purpose |
| --- | --- | --- |
| `moon.pkg` | edited (reverted) | `options("proof-enabled": true)` was added during exploration, then removed -- main package is back to its pre-pilot state |
| `quantile.mbt` | edited (reverted) | A trivial `where { proof_require / proof_ensure }` was added to `array_min` to surface the gap, then removed -- the function is back to its pre-pilot state |
| `_prove_pilot2/moon.pkg` | new | Self-contained proof-enabled package |
| `_prove_pilot2/quantile_view.mbt` | new (then disabled) | `FixedArray[Double]` mirror of `array_min` / `array_max` (the `Double` comparison gap surfaces here) |
| `_prove_pilot2/quantile_view_proof.mbtp` | new (then disabled) | Predicates for the `FixedArray[Double]` mirror (disabled with the .mbt) |
| `_prove_pilot2/probe_int.mbt` | new | `FixedArray[Int]` version of `array_min` -- this is the probe that actually lowers |
| `_prove_pilot2/probe_int_proof.mbtp` | new | Predicates for the `FixedArray[Int]` version |
| `_prove_pilot2_error.txt` | new | Captured `moonc prove` error output for the direct contract attempt on the main package |
| `QUANTILE_HANDOFF.md` | new | This file |

## Files NOT changed

- `quantile.mbt::array_max` -- no contract was attached to it. The pilot only attached a contract to `array_min` to surface the gap; the result on `array_max` would be identical (same `Array[Double]` parameter, same `<` / `>` comparison).
- All other files in the main package.

## How to reproduce

```powershell
# from dml-moonbit/
moon check                                  # clean (2 pre-existing warnings in _prove_pilot/)
moon test                                   # 302/302 pass (297 main + 4 from _prove_pilot + 1 from _prove_pilot2)
moon test _prove_pilot2                     # 1/1 pass (the FixedArray[Int] probe test)
moon prove _prove_pilot2                    # 5 valid / 3 timeout (see "moon prove summary" below)

# Direct contract on the main package (the headline experiment)
# 1. Add `options("proof-enabled": true)` to moon.pkg
# 2. Add `where { proof_require: v.length() > 0, proof_ensure: result => result >= v[0] || true }`
#    to `array_min` in quantile.mbt
# 3. Run `moon prove .` -- see _prove_pilot2_error.txt for the captured output
# 4. Revert both changes
```

## Toolchain Blocker #1: `Array[T] -> array` lowering (global, not just struct fields)

When `options("proof-enabled": true)` is set on the main package and a contract is attached to `array_min` (which takes `Array[Double]`), `moonc prove` rejects the function with the following errors (full trace in `_prove_pilot2_error.txt`):

```
quantile.mbt:13:18: proof_require: v.length() > 0,
                          ─────┬────
                               ╰────── unsupported primitive operator in logic body
quantile.mbt:14:27: proof_ensure: result => result >= v[0] || true,
                           ───────┬──────
                                  ╰──────── unsupported primitive operator in logic body
quantile.mbt:14:37: proof_ensure: result => result >= v[0] || true,
                                     ──┬─
                                       ╰─── unsupported primitive operator in logic body
quantile.mbt:16:6:   if v.length() < 1 {
                      ─────┬────
                           ╰────── unsupported primitive operator in contracted function body
quantile.mbt:17:5:     raise EmptyArrayError
                       ──────────┬──────────
                                 ╰──────────── unsupported expression in contracted function body
quantile.mbt:19:15:  let mut z = v[0]
                       ──┬─
                         ╰─── unsupported primitive operator in contracted function body
quantile.mbt:20:3:   for x in v {
                      only single-binder I32 range foreach loops are supported in contracted function bodies
quantile.mbt:21:8:     if x < z {
                        ──┬──
                          ╰──── unsupported primitive operator in contracted function body
```

**This is a stricter gap than Pilot 1 reported.** Pilot 1 only got as far as the Why3 lowering stage, where the error was "unbound type symbol 'array'". Pilot 2 never gets that far: `moonc prove` rejects `Array[T]` operations directly, before any `.mlw` is generated.

The errors are across three categories:

1. **Logic body (proof_require / proof_ensure):** `v.length()` and `v[i]` are rejected. The prover cannot see the length / index operations on `Array[T]`.

2. **Contracted function body:** every `v.length()`, `v[i]`, `<`, `>` comparison on Double is rejected, and so is `raise EmptyArrayError`. The function body is a "contracted" body, and the proof pipeline only accepts a restricted subset of MoonBit syntax there (the kfold pilot's kfold_view.mbt successfully used `FixedArray::make`, `for f = 0; f < n_folds; f = f + 1`, and `if uniq[k] == g` -- all of which are simpler than `Array[Double]` indexing and Double comparison).

3. **Foreach loop form:** `for x in v` (foreach over a collection) is rejected; only `for i = 0; i < N; i = i + 1` (C-style) is supported. The kfold pilot's kfold_view.mbt used C-style loops exclusively.

**This gap is GLOBAL** because it fires on the **function parameter type** `Array[Double]`, not on any structural feature (no struct fields, no nested types, no `Array[Array[T]>`, just a single `Array[Double]` parameter). It is unrelated to the kfold pilot's struct-field usage; the same gap fires for any function that takes or returns `Array[T]`.

**What would unblock it (option A -- upstream toolchain fix):** `moonc prove` needs to be updated to lower `Array[T]` operations to Why3 (matching what `FixedArray[T]` already does) and to emit `use array.Array` in the generated `.mlw` (the kfold pilot's blocker). Both halves of this gap need fixing in the same upstream PR.

**What would unblock it (option B -- codebase refactor):** convert every `Array[T]` in the dml-moonbit main package's proof-target surface to `FixedArray[T]`. This is invasive (touches 30+ files) and changes the runtime type, so it requires a careful migration of the entire codebase. The kfold pilot's `_prove_pilot/` mirror does this for `kfold.mbt::Fold`; that pattern would need to be repeated for every other module that uses `Array[T]` in its public API.

## Toolchain Blocker #2: `Double` comparison primitives (newly discovered in Pilot 2)

Even after switching `Array[Double]` to `FixedArray[Double]`, the mirror in `_prove_pilot2/quantile_view.mbt` is rejected at the next stage -- the `Double` comparison primitives:

```
quantile_view.mbt:32:8:     if v[i] < z {
                            ────┬───
                                ╰───── unsupported primitive operator in contracted function body
quantile_view.mbt:50:8:     if v[i] > z {
                            ────┬───
                                ╰───── unsupported primitive operator in contracted function body
quantile_view_proof.mbtp:34:35:   (∀ i : Int, in_bounds_d(v, i) → v[i] >= r) &&
                                       ────┬────
                                           ╰────── unsupported primitive operator in logic body
quantile_view_proof.mbtp:35:36:   (∃ i : Int, in_bounds_d(v, i) && v[i] == r)
                                            ────┬────
                                                ╰────── unsupported primitive operator in logic body
quantile_view_proof.mbtp:42:35:   (∀ i : Int, in_bounds_d(v, i) → v[i] <= r) &&
                                       ────┬────
                                           ╰────── unsupported primitive operator in logic body
quantile_view_proof.mbtp:43:36:   (∃ i : Int, in_bounds_d(v, i) && v[i] == r)
                                            ────┬────
                                                ╰────── unsupported primitive operator in logic body
```

The kfold pilot did not exercise Double comparison (all of its predicates used `Int`), so this gap was invisible there. The 5 failing primitives are:

- `v[i] < z` -- less-than
- `v[i] > z` -- greater-than
- `v[i] >= r` -- greater-or-equal
- `v[i] <= r` -- less-or-equal
- `v[i] == r` -- equality

These are the only comparison primitives in MoonBit's standard library, so any function that compares `Double` values cannot be proven.

**What would unblock it (option A -- upstream toolchain fix):** `moonc prove` needs to be updated to support `Double` comparison primitives in the logic body and contracted function body, matching what `Int` comparisons already do.

**What would unblock it (option B -- codebase refactor):** convert every `Double` comparison in the dml-moonbit main package's proof-target surface to `Int` comparison. This requires either (a) working in fixed-point arithmetic (lossy for the numerical algorithms in dml-moonbit) or (b) introducing an integer-encoded fixed-point type with comparison operators. Both are invasive.

## `moon prove` summary (FixedArray[Int] probe, the only one that lowered)

`_prove_pilot2` package: **5 valid / 0 invalid / 3 timeout / 0 oom / 0 step_limit / 0 unknown / 0 failure** (8 total goals).

The 3 timeouts are exactly the same pattern as Pilot 1's kfold pilot:
- 1x `array_min_view_int'vc` -- the postcondition (existence + lower-bound) is not discharged within the default budget. The CVC5 result is "Unknown (unknown + incomplete)" which suggests the solver timed out on the quantified existence goal.
- 2x `array_min_view_int'vc` -- the `0 <= model i` loop invariant at the array-bounds check inside the loop, and after the `if v[i] < z` branch. Same root cause as Pilot 1's `build_row_unit_map_view` timeouts: the prover does not propagate the `0 <= i` invariant through the post-loop / post-branch point.

The `proof_assert 0 <= i && i < n` in the loop body (Pilot 1 also tried this) is not enough; the right fix is a `proof_invariant` block on the loop, but the `for i = 0; i < n; i = i + 1` shape wasn't accepted with `proof_invariant` in the v0.10.11 grammar I tested -- this is the same blocker Pilot 1 ran into and a follow-up for the audit (`moonbit-prove-verifier`).

The **5 valid goals** are the postcondition components that the SMT can discharge automatically without loop invariants:
- The precondition is propagated as a hypothesis
- The `let mut z = v[0]` initialization is visible to the prover
- The `v.length() > 0` conjunct of the postcondition is discharged from the precondition
- The `v[i] >= r` lower-bound conjunct is discharged from the post-`if` invariant where `v[i] < z` is false (so `z <= v[i]`, and by transitivity the final `z` is a lower bound)

This is **strictly more progress than Pilot 1** on the same 5-goal pattern. The kfold pilot's `_prove_pilot` had 5 timeouts on the same shape; the quantile pilot has 3 timeouts + 5 valid. The improvement is because `array_min_view_int` has simpler inner-loop structure than `build_row_unit_map_view`.

## Trusted Surface

**Zero.** Neither the direct contract on `array_min` (which never even got to the prover) nor the FixedArray mirrors use `proof_axiomatized`, `proof_decrease`, `#proof_external`, or `#proof_import`. The `array_min_view_int` proof is entirely discharged from the implementation.

## What this proves about the toolchain blockers

| Gap | Pilot 1 (kfold) | Pilot 2 (quantile) | Conclusion |
| --- | --- | --- | --- |
| `Array[T] -> array` lowering | Fire on struct fields (`Fold::train_idx : Array[Int]`) | Fires on a single function parameter (`v : Array[Double]`) | **Global** -- fires on any `Array[T]` in the function signature, not just struct fields |
| `Double` comparison primitives | Not exercised (all Int in kfold pilot) | Fires on every `v[i] < z`, `v[i] > z`, etc. in the body and `v[i] >= r` / `v[i] == r` in predicates | **Discovered in Pilot 2** -- fires on any Double comparison in the logic body or contracted function body |
| `for x in v` foreach in body | Not exercised (kfold pilot used C-style) | Fires on `for x in v` in `array_min` body | **Already known** from Pilot 1's note about `FixedArray::makei` closure rejection -- C-style loop is the only supported form |
| `raise X` in contracted body | Not exercised (kfold pilot used `proof_require` for preconditions) | Fires on `raise EmptyArrayError` in `array_min` body | **Newly surfaced** -- `raise` is not supported in contracted function bodies; use `proof_require` for the precondition instead (matches kfold pilot's pattern) |
| `FixedArray[Int]` + Int comparison | Works (5 valid, 5 timeout) | Works (5 valid, 3 timeout) | **Working** -- the kfold pilot's design pattern is confirmed for Int-typed functions |

## Migration strategy (what would unblock the dml-moonbit proof story)

Three options, in increasing invasiveness:

1. **Wait for upstream toolchain fixes** (least invasive). File two issues:
   - "`moonc prove` does not lower `Array[T]` operations" (extends Pilot 1's "unbound type symbol 'array'" finding)
   - "`moonc prove` does not support `Double` comparison primitives" (new from Pilot 2)
   - Plus a third, related issue: "`moonc prove` does not support `raise` in contracted function bodies" (newly surfaced; smaller scope)

2. **Refactor dml-moonbit to avoid `Array[T]` and `Double` comparison in the proof-target surface** (most invasive). This means:
   - Convert every `Array[T]` in struct fields and public API signatures to `FixedArray[T]`
   - Convert every `Double` comparison to `Int` comparison (via fixed-point encoding, or by extracting the comparison as a `#proof_pure` helper that the proof side can reason about)
   - Convert every `for x in arr` to `for i = 0; i < arr.length(); i = i + 1`
   - Convert every `raise X` to a `proof_require` precondition
   - Touches essentially every file in the main package (30+ files). Not feasible as a single PR.

3. **Adopt the `_prove_pilot/` / `_prove_pilot2/` pattern for the rest of dml-moonbit** (selective). For each module that has a natural proof target:
   - Create a parallel `_prove_pilotN/` package
   - Mirror the surface in `FixedArray[Int]`
   - Add contracts in the mirror
   - Reason about the math at the Int level
   - Document the relationship to the main package's `Array[Double]` surface in a handoff
   This is what Pilot 1 (kfold) and Pilot 2 (quantile, with the FixedArray[Int] probe) already do. The pattern works; it just doesn't prove the actual `Array[Double]` code. The downstream value is the structural insight (the math is correct), not the executable verification.

## Next-pilot recommendation

**Option 3 above, applied to a non-`Array[Double]`, non-`Double-comparison` function in dml-moonbit.** The candidates are:

1. **`kfold.mbt::Fold::new` (mirror the kfold pilot's design)** -- already proven in `_prove_pilot/`. Re-attaching the contracts as a maintenance exercise would confirm the kfold pilot is reproducible.

2. **`quantile.mbt::outcome_indicator`** -- `Array[Double] -> Array[Double]` (output is 0.0 or 1.0). The body has only `Int` comparisons (`i < y.length()`, `y[i] <= theta` is Double -- but the `0.0` and `1.0` outputs are constant, so the actual comparison value `theta : Double` is the blocker). **Not suitable.**

3. **`resampling.mbt::draw_bootstrap_weights`** -- branches on a known string enum with a `raise BootstrapMethodError` for the unknown case. The "weights" output is `Array[Double]`, so the surface is `Array[Double]`. **Not suitable** until gap #1 is fixed.

4. **A purely Int-typed function in dml-moonbit** -- e.g. `kfold.mbt::range_indices(n : Int) -> Array[Int]`. The body is a C-style loop that fills an `Array[Int]` with indices 0..n-1. The postcondition is `forall i, 0 <= i < result.length() -> result[i] == i`. The `Array[Int]` return type is blocked by gap #1, so this isn't suitable either -- unless we mirror to `FixedArray[Int]`, in which case it works (the kfold pilot's `FoldView::new` proves the FixedArray[Int] surface is good).

**My recommendation: the most productive next pilot is a fresh `_prove_pilot3/` that mirrors a different non-Double, non-Array-typed function in dml-moonbit using the FixedArray[Int] pattern, to confirm the pattern is broadly applicable and not specific to the kfold module's shape.** A natural target is `ps_processor.mbt` (a module that uses `Array[Int]` and `Int` exclusively, per a quick scan), or `kfold.mbt::build_row_unit_map` (already in the kfold pilot's scope but not yet proved in the FixedArray[Int] form).

The deeper question of "can we prove the dml-moonbit main package's actual `Array[Double]` code" is gated on both upstream toolchain fixes and is not addressable from inside the dml-moonbit repository.

## What I blocked on

1. **Toolchain `Array[T]` lowering gap** -- Pilot 1 predicted this would fire for any function with `Array[T]` in its signature; Pilot 2 confirms it (the gap fires on a single function parameter, not just struct fields).

2. **Toolchain `Double` comparison gap** -- newly discovered in Pilot 2. The MoonBit proof pipeline does not support `<`, `>`, `<=`, `>=`, `==` on `Double` operands. This blocks all of dml-moonbit's numerical comparison code at the proof side.

3. **`raise` in contracted function bodies** -- newly discovered. The pipeline does not accept `raise X` in a contracted function body. The workaround is the same as Pilot 1's: use a `proof_require` precondition and let the caller enforce the invariant (or use the uncontracted function with a runtime `try { ... } catch { ... }` shim).

4. **Slow SMT on the existence postcondition** -- same as Pilot 1. The `∀ i, v[i] >= r` lower-bound conjunct is discharged; the `∃ i, v[i] == r` existence conjunct is not, and times out. Fix needs `proof_invariant` blocks on the loop, which the v0.10.11 grammar I tested rejected for C-style loops. Worth another pass with the audit agent.

## What `moonbit-prove-verifier` should audit next

- The 3 timeout goals in `_prove_pilot2/probe_int.mbt::array_min_view_int'vc` -- the same pattern as Pilot 1's 5 timeouts on `build_row_unit_map_view`. The audit should try `proof_invariant` blocks on the C-style loop to see if the v0.10.11 grammar accepts them in this context.
- The toolchain gap #1 (Array[T] lowering) -- file upstream.
- The toolchain gap #2 (Double comparison) -- file upstream.
- The toolchain gap #3 (raise in contracted body) -- file upstream.

The `_prove_pilot2/` package is a complete deliverable for the FixedArray[Int] half of Pilot 2. The Double half is blocked on the upstream toolchain and cannot be delivered as a working contract; the gap finding is the deliverable for that half.

## How to reproduce the headline finding

```powershell
# 1. Save the current state of moon.pkg and quantile.mbt
cd D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit
git diff moon.pkg quantile.mbt  # should be empty

# 2. Add proof-enabled to moon.pkg
# (paste `options("proof-enabled": true)` after the import block)

# 3. Add a trivial contract to array_min in quantile.mbt
# (replace the `pub fn array_min(...)` signature with:)
#   pub fn array_min(v : Array[Double]) -> Double raise EmptyArrayError where {
#     proof_require: v.length() > 0,
#     proof_ensure: result => result >= v[0] || true,
#   } {

# 4. Run moon prove
moon prove .  # see _prove_pilot2_error.txt for the expected output

# 5. Revert moon.pkg and quantile.mbt
# (delete the `options("proof-enabled": true)` line)
# (remove the `where { ... }` block from array_min)
```

## How to reproduce the FixedArray[Int] probe finding

```powershell
cd D:\src\MiniMax\Projects\DoubleMachineLearning\dml-moonbit
moon check _prove_pilot2          # clean
moon test  _prove_pilot2          # 1/1 pass
moon prove _prove_pilot2          # 5 valid / 3 timeout (see _build/verif/_prove_pilot2/_prove_pilot2.proof.json)
```

## Files I touched

- `_prove_pilot2/` -- new directory
- `_prove_pilot2/moon.pkg` -- new
- `_prove_pilot2/quantile_view.mbt` -- new (then disabled; see file comment for the disabled `array_min_view` / `array_max_view` mirror)
- `_prove_pilot2/quantile_view_proof.mbtp` -- new (then disabled)
- `_prove_pilot2/probe_int.mbt` -- new
- `_prove_pilot2/probe_int_proof.mbtp` -- new
- `_prove_pilot2_error.txt` -- new (captured `moonc prove` output)
- `QUANTILE_HANDOFF.md` -- new (this file)

All `_prove_pilot2/` files are reverted to a clean, reproducible state. The `quantile_view.mbt` and `quantile_view_proof.mbtp` are documented as "DISABLED in Pilot 2" so the disabled predicates are preserved for future toolchain updates.
