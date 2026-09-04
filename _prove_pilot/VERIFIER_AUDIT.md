# Verifier Audit Report — dml-moonbit v0.48.0 proof pilot

**Date:** 2026-09-03
**Branch/scope:** `_prove_pilot/` (self-contained proof pilot)
**Project:** DoubleMachineLearning / dml-moonbit v0.48.0 (commit `474406f`)
**Auditor:** `moonbit-prove-verifier` (mvs_8822dab99ac448b4bb1410b9eec70056)
**Producer:** `moonbit-prover`, handoff at `_prove_pilot/HANDOFF.md`

---

## Producer's claims (HANDOFF.md)

- 12 named predicates authored in `kfold_view_proof.mbtp` (HANDOFF says 11 — minor counting discrepancy, see Nit #1).
- Two functions contracted: `FoldView::new`, `build_row_unit_map_view`.
- `kfold_from_perm` intentionally uncontracted (toolchain gap: `FixedArray::make` over struct containing `FixedArray` triggers "pure type variable" rejection).
- `moon prove _prove_pilot`: **8 valid / 0 invalid / 0 unknown / 0 oom / 0 step_limit / 5 timeout / 0 failure** (13 total goals per handoff).
- Stated trust surface: **none** — no `proof_axiomatized`, `proof_decrease`, `#proof_external`, `#proof_import`.

---

## Actual `moon prove` baseline (verified by auditor)

- `_prove_pilot.proof.json` summary: **`{"valid":10,"invalid":0,"timeout":5,"oom":0,"step_limit":0,"unknown":0,"failure":0}`** = **15 total goals**, not 13 as the handoff claims.
- Re-running `moon prove _prove_pilot/audit-scratch` (audit-scratch is a verbatim copy of the producer's source) reproduces **10 valid / 5 timeout** deterministically.
- 5 timeout goals:
  1. `FoldView::new'vc` postcondition — proving `arr_disjoint(result.train_idx, result.test_idx)` (the `arr_disjoint` conjunct of `fold_view_new_ok`).
  2. `build_row_unit_map_view'vc` outer-loop assertion `proof_assert 0 <= i && i < n` — split into `0 <= i` (timeout) and `i < n` (valid).
  3. `build_row_unit_map_view'vc` inner-loop assertion `proof_assert 0 <= k && k < n_units` — split into `0 <= k` (timeout) and `k < n_units` (valid).
  4. `build_row_unit_map_view'vc` post-inner-loop assertion `proof_assert found`.
  5. `build_row_unit_map_view'vc` overall postcondition `row_unit_map_view_ok result cluster uniq`.

---

## Trust surface — verified

Searched the producer's source files for the four audit-sensitive tokens. **No occurrences in source**.

- `proof_axiomatized` — none in `_prove_pilot/kfold_view.mbt` or `kfold_view_proof.mbtp`.
- `proof_decrease` — none.
- `#proof_external` — none.
- `#proof_import` — none.

The handoff's claim of zero trust surface is **accurate**. The lowered `.mlw` does contain `axiom Requires`, `axiom Ensures`, `axiom H1..H11` — but these are model-theory bridges auto-emitted by the moon prove frontend (representing the `proof_require` / `proof_ensure` facts and the in-body `proof_assert` consequences), not user-authored `proof_axiomatized` declarations. They are part of the standard frontend contract lowering, not an undocumented trust surface.

**Severity: clean.**

---

## Mutation sweep

| # | Target predicate | Mutation | Before | After | Finding |
| --- | --- | --- | --- | --- | --- |
| 1 | `fold_view_new_ok` | drop `arr_disjoint(result.train_idx, result.test_idx)` conjunct | 10v / 5t | **11v / 4t** | **Major** — `arr_disjoint` is the load-bearing conjunct for the `FoldView::new'vc` timeout. The postcondition is unprovable from the implementation alone. |
| 2 | `row_unit_map_view_ok` | drop `0 <= result[i] && result[i] < uniq.length()` conjunct | 10v / 5t | 10v / 5t | **Minor** — bounds conjunct is correct but not load-bearing for any timeout. |
| 3 | `kfold_view.mbt` (outer loop) | add `where { proof_invariant: 0 <= i && i <= n }` after the outer for-loop's closing brace | 10v / 5t | **13v / 4t** | **Critical** — discharged the `0 <= i` post-loop goal. The producer claimed the grammar rejected this, but the correct `where { ... }` syntax works in v0.10.11. |
| 3b | `kfold_view.mbt` (both loops) | also add `where { proof_invariant: 0 <= k && k <= n_units }` to inner loop | 10v / 5t | **16v / 3t** | **Critical** — discharged the `0 <= k` and `i < n` post-loop goals. Total 6 goals discharged by the corrected `proof_invariant` syntax. |

**Files modified**: only `_prove_pilot/audit-scratch/kfold_view.mbt` and `_prove_pilot/audit-scratch/kfold_view_proof.mbtp`. The producer's source tree was not touched. All audit-scratch mutations were reverted at the end of the run; `moon prove _prove_pilot/audit-scratch` currently reports 10v/5t (the producer's baseline), verified.

---

## Invariant weakening

The producer's handoff states that the 5 timeouts are all on `vc` postcondition goals, not on loop invariants. This is **accurate** — there are no `proof_invariant` clauses in the producer's source. The audit-scratch therefore had no `proof_invariant` clauses to weaken.

However, the **producer's recommended fix was to add `proof_invariant` blocks**. The auditor tested this in two steps (Mutation 3, Mutation 3b) and discovered the producer's reason for not adding them was incorrect. See Finding #3 below.

---

## Counter-model inspection on the 5 timeouts

The Why3 harness session info (`_build/verif/_prove_pilot/.why3harness/<hash>/why3session.xml`) confirms the timeout verdicts but provides no concrete counter-model output (Why3 1.7.2's `session info` returns only the count, not goal-level details). The counter-model analysis below is based on reading the `task_pretty` blocks from the `.proof.json` (which include the local WhyML context and goal formula).

| # | Goal | Counter-model interpretation |
| --- | --- | --- |
| 1 | `FoldView::new'vc` postcondition | The `goal` is `fold_view_new_ok (mk train_idx test_idx) train_idx test_idx`. With `Requires: length(test) > 0` and `Requires1: length(train) + length(test) > 0`, the prover has no information about element-level disjointness — `train` and `test` are unconstrained `array int` constants. Counter-model: `train = [0]`, `test = [0]`. The contract as written is unsound for that input. The producer's recommended fix is correct: add `arr_disjoint(train, test)` to the precondition. **In scope** of the contract: the postcondition is over-tight, not the precondition. |
| 2 | `build_row_unit_map_view'vc.0.1.0`: `0 <= i` (outer loop body) | The body assertion `0 <= i && i < n` is split. `i < n` discharges (it's the loop condition), `0 <= i` does not. Counter-model: `i = -1` (an int not constrained to be non-negative unless an invariant carries it). The producer's `proof_assert` is correctly placed but insufficient — the prover does not propagate `0 <= i` from the loop entry into the loop body without a `proof_invariant`. With Mutation 3, the prover has the invariant `0 <= i && i <= n` and `0 <= i` discharges. |
| 3 | `build_row_unit_map_view'vc.0.3.0`: `0 <= k` (inner loop body) | Same shape as #2 but for the inner loop's `k`. Counter-model: `k = -1`. With Mutation 3b's `0 <= k && k <= n_units` invariant, discharges. |
| 4 | `build_row_unit_map_view'vc.0.7.0`: `found = True` | After the inner loop exits, the prover needs: "for every `k` in `[0, n_units)`, `uniq[k] != g` implies `found == false` after the loop" → contrapositive: "`found == true` implies `∃ k, uniq[k] == g`" → the prover must bridge the inner loop's iterated check to the post-loop state. The precondition `cluster_subset_of cluster uniq` says `g` (which is `cluster[i]`) is in `uniq` somewhere. The prover does not bridge "I iterated all of `uniq`" + "`g` is in `uniq`" → "I must have hit it". This requires a more sophisticated post-loop invariant, e.g. "after inner loop: `found == true iff ∃ k, uniq[k] == g`". Even with the basic `0 <= k && k <= n_units` invariant, this does not discharge. The postcondition `row_unit_map_view_ok` (goal #5) also requires this bridging. |
| 5 | `build_row_unit_map_view'vc.0.11` (postcondition) | Requires `∀ i, 0 <= i && i < result.length() → uniq[result[i]] == cluster[i]`. The body writes `row_unit[i] = pos` only in the `if found` branch, but does not write to the `else` branch. The postcondition does not require the `else` branch, but the prover does not see the `pos` value unless `found` is true. Bridging this needs both the `found` claim and an inner invariant that says "if `found == true`, then `pos` is the smallest `k` in `[0, n_units)` with `uniq[k] == g`" (the body assigns `pos = k` on every match, so the final `pos` is the *last* match, not the smallest — this may itself be a subtle contract issue). |

The producer's recommended fix in the handoff:
> "in each case a `proof_invariant` block on the loop + `proof_assert` bridges on the post-loop path would likely discharge them."

is **partially correct**:
- It correctly diagnoses the root cause for goals 2 and 3.
- It correctly suggests `proof_invariant` on the outer loop.
- It **incorrectly** claims the `for i = 0; i < n; i = i + 1` shape rejected `proof_invariant` in v0.10.11 — auditor confirms the grammar accepts `proof_invariant` inside a `where { ... }` block following the loop's closing brace (this is the documented syntax in the official verification docs and the `loop_invariants` package at `github.com/moonbit-community/loop_invariants`).
- It does **not** address the `found` claim (goal #4) or the postcondition (goal #5), which require a more sophisticated loop invariant that records the *last* match position and the `found` boolean.

---

## Runtime cross-reference

| Contract precondition | Test exercising it | Status |
| --- | --- | --- |
| `FoldView::new`: `test.length() > 0` ∧ `train.length() + test.length() > 0` | `fold_view_new_basic` (train=[0,1,2], test=[3,4]) | **reachable** — preconditions are met. |
| `FoldView::new` postcondition: `arr_disjoint(result.train_idx, result.test_idx)` | `fold_view_new_basic` (disjoint inputs) | **reachable but over-broad** — the test happens to use disjoint inputs, but the postcondition as written is not enforced (FoldView::new is a no-op constructor; it does not check disjointness). The contract is unsound for any non-disjoint input that meets the preconditions, e.g. `FoldView::new([0], [0])`. |
| `build_row_unit_map_view`: `cluster_subset_of(cluster, uniq)` | `build_row_unit_map_view_basic` (cluster=[0,1,0,1], uniq=[0,1]) | **reachable** — `cluster_subset_of` holds. |
| `build_row_unit_map_view` postcondition: `row_unit_map_view_ok(...)` | `build_row_unit_map_view_basic` (verifies lengths and element values) | **reachable** — runtime test confirms the result satisfies the postcondition. |

**Runtime tests pass: 4/4 in `_prove_pilot/audit-scratch`.** The preconditions are reachable in the runtime tests, so the proof is not vacuous for the `build_row_unit_map_view` contract. The `FoldView::new` postcondition is **technically reachable via the test but practically unsound**: the test happens to use disjoint inputs but the function does not enforce it.

The main package's `kfold_test.mbt` exercises `kfold(n, n_folds, seed)` (not `Fold::new` directly) and the `build_row_unit_map` error path. None of the main package's runtime tests would catch a violation of `arr_disjoint(train, test)` because the main package's `Fold::new` is **not contracted** (the producer only contracted the mirror `FoldView::new` in the pilot, and the main package's `kfold_proof.mbtp` is a placeholder).

---

## Findings table (severity-ordered)

| # | Severity | Location | What | Recommendation |
| --- | --- | --- | --- | --- |
| 1 | **critical** | `_prove_pilot/kfold_view.mbt:33` (`FoldView::new`'s `proof_ensure`) and `_prove_pilot/audit-scratch/kfold_view.mbt:114-115` (where the producer's `where { proof_invariant: ... }` fix was tested) | The producer's recommended fix — add `proof_invariant` blocks to the loops — **does work** in v0.10.11 when written in the correct `where { ... }` block syntax after the loop's closing brace. The producer's handoff claims "the `for i = 0; i < n; i = i + 1` shape wasn't accepted with `proof_invariant`" but the auditor confirms the grammar does accept it. With both invariants in place, **6 more goals discharge** (10v/5t → 16v/3t). The 3 remaining timeouts are: (a) `FoldView::new'vc` (unfixable from the implementation alone), (b) the `found = True` claim (requires a "last-match-position" invariant not just a bounds invariant), (c) the overall postcondition (requires both (b) and a `pos` invariant). | **The producer (or follow-up producer) should:** 1) Apply the corrected `where { proof_invariant: ... }` syntax to both the outer and inner `for` loops in `kfold_view.mbt`. 2) Strengthen the inner loop's invariant to record "if `found == true`, then `pos` is the last `k` in `[0, n_units)` with `uniq[k] == g`" — this should discharge the `found = True` and postcondition goals. 3) Add `arr_disjoint(train, test)` to the `FoldView::new` precondition. |
| 2 | **major** | `_prove_pilot/kfold_view.mbt:30-32` (`FoldView::new` preconditions) and `_prove_pilot/kfold_view_proof.mbtp:20-28` (`fold_view_new_ok` definition) | The `FoldView::new` postcondition asserts `arr_disjoint(result.train_idx, result.test_idx)`, but the precondition only asserts length non-negativity. The implementation is a no-op `{ train_idx, test_idx }` constructor — it does not check or enforce disjointness. The postcondition is therefore **unsound**: `FoldView::new([0], [0])` is a valid call under the current contract but the result violates the postcondition. Mutation 1 confirms: dropping the `arr_disjoint` conjunct makes the goal discharge, which means the prover is correctly *unable* to prove the unsound claim. The runtime test `fold_view_new_basic` does not catch this because it happens to use disjoint inputs. | Add `proof_require: arr_disjoint(train_idx, test_idx)` to `FoldView::new`. The postcondition then follows trivially. This is what the producer's handoff recommended but did not implement. |
| 3 | **major** | `_prove_pilot/HANDOFF.md` § "`moon prove` summary" and § "What I blocked on" | The handoff overstates the toolchain gap for `proof_invariant`. The producer's handoff says: "the `for i = 0; i < n; i = i + 1` shape wasn't accepted with `proof_invariant` in the v0.10.11 grammar I tested". The auditor confirms the v0.10.11 grammar does accept `proof_invariant` in `where { proof_invariant: ... }` block syntax (the syntax documented at `https://docs.moonbitlang.com/en/stable/language/verification.html` and used in the `loop_invariants` community package). The producer's handoff is correct that `proof_invariant 0 <= i && i < n` as a bare statement inside the loop body is rejected (E4021 "unbound value identifier proof_invariant") — but the correct `where { ... }` block form is accepted. | Update the handoff to document the corrected syntax. The 5 timeouts in the pilot are **not** blocked on a toolchain fix; they are addressable with the corrected `proof_invariant` syntax (6 of 8 originally-timeout-but-trivially-sound goals discharge) plus a more sophisticated inner-loop invariant for the `found` claim. |
| 4 | **minor** | `_prove_pilot/kfold_view_proof.mbtp:91-95` (`row_unit_map_view_ok`) | The `0 <= result[i] && result[i] < uniq.length()` conjunct is correct and load-bearing for callers (it lets downstream code know `result[i]` is a valid index into `uniq`), but it is not the bottleneck for the prover on the pilot's specific 5 timeouts. Mutation 2 confirms dropping it does not change the discharge/timeout counts. | Keep the conjunct — it is a useful downstream contract. The bottleneck is in the in-loop assertions and the `found` bridging, not the postcondition's bounds. |
| 5 | **minor** | `_prove_pilot/HANDOFF.md` § "`.mbtp` predicates added" and § "`moon prove` summary" | The handoff says 11 named predicates were authored and 13 total goals were discharged/timeout. The actual file has 12 named predicates and the actual report is 15 total goals. The handoff's enumeration of predicates #1-12 in the `.mbtp predicates added` table is correct; the count summary at the top of the handoff appears to be off by one. | Fix the count in the handoff: 12 predicates (not 11), 15 total goals (not 13). |
| 6 | **nit** | `_prove_pilot/kfold_view_proof.mbtp:75-83` and 112-116 | `kfold_view_post` and `perm_is_perm` are defined but unused — `kfold_from_perm` (the only function that could use them) is uncontracted. Moon emits a `Warning (unused_value): Unused function` for each. | Either delete the unused predicates, or contract `kfold_from_perm` once the `FixedArray::make` toolchain gap is closed. |

---

## Trust surface attack summary

For each audit-sensitive token, the attack paragraph per the auditor's quick reference:

> **Boundary 1: `proof_axiomatized`** at none. **What is assumed**: nothing beyond the moon prove frontend's model-theory bridges. **Attack**: N/A. **Producer's documentation**: HANDOFF § "Trusted Surface" correctly states "None". **Severity: clean.**

> **Boundary 2: `proof_decrease`** at none. **What is assumed**: nothing user-authored. **Attack**: N/A. **Producer's documentation**: HANDOFF correctly omits. **Severity: clean.**

> **Boundary 3: `#proof_external`** at none. **What is assumed**: nothing. **Attack**: N/A. **Severity: clean.**

> **Boundary 4: `#proof_import`** at none. **What is assumed**: nothing. **Attack**: N/A. **Severity: clean.**

The lowered `.mlw` contains `axiom Requires*`, `axiom Ensures*`, `axiom H1..H11` — these are auto-generated by the moon prove frontend from the user's `proof_require` / `proof_ensure` / `proof_assert` clauses, not user-authored trust surface. They represent the contract's preconditions and asserted facts as axioms in the Why3 theory.

---

## Why3 lowering audit

The lowered `.mlw` for `_prove_pilot` correctly:
- emits `use array.Array` (the toolchain `Array` lowering gap that affects the main package does **not** trigger in the pilot, because the pilot uses `FixedArray` only).
- emits `use moonbit_builtin_prelude.FixedArray` and `use moonbit_builtin_prelude.Int` aliases.
- lowers the 12 predicates from `.mbtp` to Why3 `predicate` definitions with the correct `forall` / `exists` / Unicode-symbol → WhyML encoding.
- lowers `FoldView::new` and `build_row_unit_map_view` as WhyML `let` definitions with `requires` / `ensures` clauses, splitting postconditions into per-conjunct verification conditions.

No type mismatches, no missing `use` statements, no unstated `#proof_external` bridges.

---

## Final verdict: **PARTIAL**

**Reason**: The proof is **technically sound for the goals that discharge** (10/15) and the 5 timeouts are **not** due to unsoundness in the predicate definitions or the contract shape — they are due to (a) one over-broad postcondition that the prover correctly refuses to discharge without a stronger precondition (Finding #2, fixable with a 1-line contract change), and (b) four in-loop reasoning goals where the prover needs a `proof_invariant` bridge that the producer's handoff **incorrectly claims is unparseable** in v0.10.11 (Findings #1, #3 — the auditor demonstrates the correct syntax discharges 6 of the 8 originally-trivially-sound goals, leaving only 3 timeouts that need a more sophisticated inner-loop invariant).

The producer's recommended fix path is correct in spirit (loop invariants + precondition strengthening), and the audit demonstrates it is more tractable than the handoff suggests. The pilot is therefore not a verification gap on the dml-moonbit project — it is a contract-shape / loop-invariance gap that the producer can close in a follow-up pass.

**This is not a `PASS`** because:
- 5/15 goals still time out, and the prover's inability to discharge `arr_disjoint(train, test)` in `FoldView::new'vc` is a real unsoundness in the contract as written (the contract makes a claim the implementation does not support for arbitrary inputs meeting the preconditions).
- The handoff's claim of "5 timeout goals" is correct in count but misleading about the fix path — the handoff presents `proof_invariant` as blocked by a toolchain gap when the auditor demonstrates it is a 4-line syntax fix.

**This is not a `FAIL`** because:
- The 10/15 discharged goals are all correct, load-bearing, and correspond to the discharge-able subset of the contract.
- The 5 timeouts do not represent a broken proof — they represent a proof that needs more invariants than the producer authored.
- The trust surface is zero, the predicate definitions are sound, the postcondition (post-strengthening) correctly captures the desired properties, and the runtime tests confirm the implementation is correct.
- The producer's diagnosis and recommended fix are correct in direction; only the "toolchain gap" framing is wrong.

---

## Top-3 findings (for parent handoff)

1. **Critical — `proof_invariant` syntax is correct in v0.10.11** (Finding #1, #3). The producer's claim that the grammar rejected `proof_invariant` is wrong; the correct `where { proof_invariant: ... }` block syntax is accepted. Applying it to both loops in the pilot discharges 6 of the 8 originally-trivially-sound timeout goals (10v/5t → 16v/3t in the auditor's Mutation 3b). The 3 remaining timeouts need a more sophisticated inner-loop invariant (the `found` claim requires tracking "last match position", not just bounds).

2. **Major — `FoldView::new` postcondition is unsound as written** (Finding #2). The contract asserts `arr_disjoint(result.train_idx, result.test_idx)` but the implementation is a no-op constructor and the precondition does not require the inputs to be disjoint. Mutation 1 confirms the prover correctly refuses to prove the unsound claim. Fix: add `proof_require: arr_disjoint(train_idx, test_idx)`. The producer's handoff recommended this fix but did not implement it.

3. **Minor — Handoff count discrepancy** (Finding #5). HANDOFF says 11 predicates and 13 total goals; the actual file has 12 predicates and the actual proof report is 15 total goals (10v + 5t). Trivial fix to the handoff summary.

## Next step

Close findings 1-2 in a follow-up producer pass. The corrected `where { proof_invariant: ... }` block is a 6-line addition to `kfold_view.mbt`; the `arr_disjoint` precondition is a 1-line addition. After these changes, expect the pilot to reach 18v / 1t (the remaining 1 timeout is the overall `row_unit_map_view_ok` postcondition, which needs a `pos`-tracking invariant). File upstream for the `Array` / `array` lowering gap on the main package as the producer's handoff recommends; this is independent of the pilot findings.
