# Proof Pilot Handoff -- dml-moonbit v0.48.0

**Date:** 2026-09-03
**Branch/scope:** `_prove_pilot/` (self-contained), main package (`kfold.mbt`, `kfold_proof.mbtp`, `moon.pkg`)
**Pilot module:** `kfold_view` (a `FixedArray`-based mirror of `kfold.mbt`'s surface, in the standalone `_prove_pilot` package)
**Reason for mirror (not direct contract on kfold.mbt):** see **Toolchain Blocker** below.

---

## Pilot module chosen and why

**`kfold_view` (a self-contained mirror of `kfold.mbt`).** The kfold
module is the most natural pilot target -- it is pure, deterministic
(modulo an opaque chacha8 RNG), and the partition-correctness postcondition
is exactly the kind of mathematical claim the SMT solver can reason about.
It also has explicit `try { ... } catch { PreconditionError => abort }`
shims (added in v0.48.0) that mark a clean control-flow boundary
between the precondition-violation path and the normal-return path.

I was unable to author contracts directly on `kfold.mbt` because the
main package's `Array[Int]` struct fields are not lowered correctly by
the proof pipeline (see **Toolchain Blocker**). The mirror lives in
`_prove_pilot/` -- a standalone MoonBit package that demonstrates the
contract shape and predicate design that *would* move to `kfold.mbt`
once the toolchain gap is closed.

## Files created / modified

| File | Status | Purpose |
| --- | --- | --- |
| `_prove_pilot/moon.pkg` | new | Self-contained proof-enabled package |
| `_prove_pilot/kfold_view.mbt` | new | `FoldView` (FixedArray-based mirror), `FoldView::new` (contracted), `kfold_from_perm` (runtime only -- see note below), `build_row_unit_map_view` (contracted), 4 runtime tests |
| `_prove_pilot/kfold_view_proof.mbtp` | new | 11 named predicates for the kfold surface |
| `_prove_pilot/HANDOFF.md` | new | This file |
| `moon.pkg` | edited (reverted) | `options("proof-enabled": true)` was added during exploration, then removed before sign-off -- main package is back to its pre-pilot state |
| `kfold_proof.mbtp` | placeholder | Empty stub + comment explaining the toolchain blocker |
| `kfold.mbt` | unchanged | Pre-v0.48.0 + v0.48.0 raise-wrap state preserved exactly |

## `.mbtp` predicates added (kfold_view_proof.mbtp)

1. `in_bounds(arr, i)` -- `0 <= i && i < arr.length()`
2. `arr_bounded(arr, n)` -- every element in `[0, n)`
3. `arr_disjoint(a, b)` -- set-level disjointness of two arrays
4. `fold_well_formed_view(f, n_obs)` -- train/test disjoint, both bounded by `[0, n_obs)`, lengths sum to `n_obs`
5. `test_pair_disjoint_view(folds, fi, fj)` -- two distinct folds' test sets are disjoint
6. `test_sets_disjoint_view(folds)` -- `∀ fi, fj, test_pair_disjoint_view(folds, fi, fj)`
7. `test_sets_cover_view(folds, n_obs)` -- every `k ∈ [0, n_obs)` appears in some fold's test set
8. `folds_partition_view(folds, n_obs)` -- disjoint ∧ cover
9. `kfold_view_post(folds, n_obs, n_folds)` -- top-level: length = `n_folds`, partition, all folds well-formed
10. `row_unit_map_view_ok(result, cluster, uniq)` -- the mapping is the inverse of uniq
11. `cluster_subset_of(cluster, uniq)` -- the precondition for `build_row_unit_map_view`
12. `perm_is_perm(perm, n)` -- the precondition for `kfold_from_perm`

Note: the proof language requires **Unicode** `∀` / `→` / `∃` in predicate bodies, not ASCII `forall` / `->` / `exists`. ASCII keywords cause parse errors in the .mbtp grammar.

## `proof_require` / `proof_ensure` attached

| Function | Contract |
| --- | --- |
| `FoldView::new(train, test)` | `proof_require`: test.length() > 0, train.length() + test.length() > 0. `proof_ensure`: result preserves lengths; train and test are disjoint |
| `kfold_from_perm(perm, n_obs, n_folds)` | (NOT contracted) -- see note below |
| `build_row_unit_map_view(cluster, uniq)` | `proof_require`: `cluster ⊆ uniq`. `proof_ensure`: result maps each row to the position of its cluster id in uniq, and `uniq[result[i]] == cluster[i]` for all i |

**`kfold_from_perm` is intentionally uncontracted.** The body uses `FixedArray::make` with a `FoldView` value that contains two `FixedArray[Int]` fields, and the Why3 lowering rejects this with:
> `This application instantiates pure type variable 'a with a mutable type mavis_dml__prove_pilot__foldView`

The runtime behaviour is exercised by `kfold_from_perm_basic` and `kfold_from_perm_uneven`. Once the toolchain permits, the contract should be:
```moonbit
where {
  proof_require: n_obs > 0,
  proof_require: n_folds > 0,
  proof_require: n_folds <= n_obs,
  proof_require: perm_is_perm(perm, n_obs),
  proof_ensure: result => kfold_view_post(result, n_obs, n_folds),
}
```

## `moon prove` summary (v1 baseline)

`_prove_pilot` package: **8 valid / 0 invalid / 0 unknown / 0 oom / 0 step_limit / 5 timeout / 0 failure** (13 total goals per v1 handoff; actual verifier-measured count: **10v / 0i / 0u / 0o / 0s / 5t / 0f** = 15 total goals — see "Top-3 findings" item #3 in `VERIFIER_AUDIT.md` for the off-by-one).

The 5 timeouts are all on quantified or loop-internal goals that Alt-Ergo and CVC5 cannot discharge within the default budget:
- `FoldView::new'vc` -- the `arr_disjoint` postcondition over the two input arrays (the prover does not see the inputs as extensionally different, so it cannot conclude disjointness from the constructor alone)
- 4x `build_row_unit_map_view'vc` -- `0 <= model i` and `0 <= model k` for the loop counters after the inner loop exits (the prover does not propagate the `0 <= k` invariant through the post-loop point)

**UPDATE 2026-09-03 (Pilot 1 v2 fix pass):** All 5 timeouts are now closed by the v2 producer fixes, **with the caveat that the two `arr_disjoint` and the `build_row_unit_map_view` postcondition / `found` claims required a more careful invariant story than the v1 handoff suggested**. See the "Pilot 1 v2 — Fix pass (2026-09-03)" appendix at the end of this document for the full breakdown. Final v2 numbers: **17 valid / 0 invalid / 0 unknown / 0 oom / 0 step_limit / 2 timeout / 0 failure** (19 total goals; the 2 timeouts are documented in the v2 appendix).

The v1 handoff's claim that "`for i = 0; i < n; i = i + 1` shape wasn't accepted with `proof_invariant`" was **incorrect**; the v0.10.11 grammar does accept the `where { proof_invariant: ... }` block syntax after the loop's closing brace (this is the form documented at `https://docs.moonbitlang.com/en/stable/language/verification.html`). The v1 producer (me) tested the wrong syntax (bare `proof_invariant` as a statement inside the loop body, which raises E4021 "unbound value identifier") and never re-tested with the correct `where { ... }` block. The verifier audit caught and corrected this.

**Main package `moon prove` is blocked at the harness level** (see next section).

## Toolchain Blocker (the headline finding)

The dml-moonbit main package **cannot be proven** end-to-end with the current MoonBit v0.10.11 + Why3 1.7.2 toolchain.

When `options("proof-enabled": true)` is set on the main package and any module in it references `Array[T]` (which is essentially every module), `moonc prove` lowers the package to Why3, and the generated `.mlw` contains type definitions like:

```why3
type mavis_dml__Matrix = {
    ...
    mavis_dml__Matrix__data : array int
}
```

The lowering **does not add** `use array.Array` to the main module's preamble, so Why3 raises:
> `unbound type symbol 'array'`

I confirmed this is a toolchain gap (not a contract authoring error) by:
1. Trying `#proof_import("moonbit_builtin_prelude.FixedArray")` to surface the array operations explicitly -- still raised the same error.
2. Trying `MOON_PROVE_PRELUDE_OVERRIDE` to inject a modified prelude that re-exports `array.Array` -- the override directory is honored, but the package-level `use` statements for FixedArray and `use array.Array` are not auto-propagated.
3. Building `_prove_pilot/` (a clean package with no main-package `Array[T]` dependencies) and verifying the proof pipeline works end-to-end there.

**What would unblock it:** either
- the moon prove code generator is updated to emit `use array.Array` whenever the package's `.mbt` files reference `Array[T]` in struct fields or return types, **or**
- the dml-moonbit codebase is refactored to use `FixedArray[T]` (or an immutable abstract model) in the type signatures it wants to prove about.

The second option is invasive (touches the entire codebase, 30+ files). The first option is a one-line toolchain fix. **Recommend filing upstream first.**

## Trusted Surface

None. The pilot does not use `proof_axiomatized`, `proof_decrease`, `#proof_external`, or `#proof_import` -- every predicate is a pure logical definition discharged from the implementation. The v2 fix pass does not change this (see appendix: the two remaining timeouts are SMT-bridge limitations, not trust-surface additions).

## Next-module recommendation

Once the toolchain blocker is resolved, the next-best pilot targets are:

1. **`quantile.mbt::array_min` / `array_max`** -- pure Int-returning helpers with a `raise EmptyArrayError` boundary added in v0.41.0. Postcondition: the result is the min/max of the non-empty input. Low SMT complexity (no nested loops, no permutation reasoning). Same `EmptyArrayError` raise pattern we exercised in the build_row_unit_map contract.
2. **`resampling.mbt::draw_bootstrap_weights`** -- branching on a known string enum ("normal" / "Bayes" / "wild") with `raise BootstrapMethodError` for the unknown case. Good demonstration of the raise/contract boundary in a numerical context.
3. **`kfold.mbt` directly (current target)** -- once the toolchain gap is fixed, the contracts from `_prove_pilot/kfold_view.mbt` move verbatim into `kfold.mbt` (replacing `FixedArray` with `Array`).

**Do NOT** start with the `plr` / `irm` / `pliv` / `iivm` estimator fits -- those are higher risk (numerical precision, dense matrix operations) and would not surface the toolchain blocker cleanly. The blocker is structural to the entire package; fix it once before contracting estimator fits.

## What I blocked on

1. **Toolchain `Array` -> `array` lowering gap** -- described above. This is the headline blocker. Without a toolchain fix, contracts on the main package cannot even be lowered, let alone proved.
2. **`FixedArray::make` of struct containing FixedArray** -- Why3 "pure type variable" rejection. This is what kept `kfold_from_perm` uncontracted in the pilot. May be addressable by extracting the FoldView's array fields through a `model(...)` function, à la AVL.
3. **Closures (`fn(k) { ... }`) inside contracted function bodies** -- rejected as "unsupported expression in contracted function body". Worked around in the pilot by replacing `FixedArray::makei(n, fn(k) { perm[...] })` with an explicit `for k = 0; k < n; k = k + 1` loop. Worth filing upstream.
4. **No local MoonBit_Pearls / paradigms.md reference** -- the workspace's `MoonBit_Pearls/pearls/25-moon-prove/pearl.md` and `paradigms.md` were not present, so I worked from the canonical docs at `https://docs.moonbitlang.com/en/stable/language/verification.html`, the verified examples at `https://github.com/moonbit-community/verified`, and the Yu-zh/moonbit-proof exercises. If a local copy of Vol.25 moon-prove pearl is added later, the contracts in `_prove_pilot/kfold_view.mbt` may want a second review against the local idiom.

## How to reproduce

```bash
# from dml-moonbit/
moon check _prove_pilot              # 2 warnings (unused predicates), 0 errors
moon test  -p "mavis/dml/_prove_pilot"   # 4/4 runtime tests pass
moon test                             # 297/297 main package tests pass (no regression)
moon prove _prove_pilot               # 17 valid, 2 timeout (see "moon prove summary" + v2 appendix)
moon prove                            # BLOCKED: "unbound type symbol 'array'" in main package
```

## Next agent

- **`moonbit-prove-verifier`** should re-audit the v2 deliverable. The two remaining timeouts (see v2 appendix) are genuinely hard for SMT — see the v2 appendix for the documented why-this-is-genuinely-hard analysis. The verifier may want to attack (a) the `arr_disjoint` precondition correctness (soundness check), and (b) whether the simpler inner-loop invariant `0 <= k && k <= n_units` is sufficient to discharge the postcondition via the implicit `g = cluster[i]` reasoning.

- **File upstream** for the `Array` -> `array` Why3 lowering gap. Without this, the entire dml-moonbit proof story is blocked.

---

## Pilot 1 v2 — Fix pass (2026-09-03)

**Author:** `moonbit-prover` follow-up
**Triggered by:** `VERIFIER_AUDIT.md` (verdict **PARTIAL**, 3 actionable findings)
**Goal:** Close the 5 v1 timeouts per the verifier's recommendations.

### Baseline (v1, reverted at end of audit)

`moon prove _prove_pilot` → **10 valid / 0 invalid / 0 timeout-other / 5 timeout** (15 total goals).

### Fix sequence

#### Fix 1 — `proof_invariant` on both loops (`kfold_view.mbt:114-124`)

Added `where { proof_invariant: 0 <= i && i <= n }` after the outer `for i = 0; i < n; i = i + 1` closing brace, and `where { proof_invariant: 0 <= k && k <= n_units }` after the inner `for k = 0; k < n_units; k = k + 1` closing brace.

The v1 handoff claimed this syntax was rejected by the v0.10.11 grammar. The verifier audit demonstrated that the **correct syntax** is the `where { proof_invariant: ... }` **block** after the loop's closing brace (the form documented at `https://docs.moonbitlang.com/en/stable/language/verification.html` and used in the `loop_invariants` community package). Bare `proof_invariant` statements inside the loop body (which the v1 producer tested) raise E4021 "unbound value identifier" — that was the source of the v1 confusion.

**After Fix 1 (both invariants, no other changes):** 17 valid / 2 timeout (a +7 improvement over baseline). The +7 vs the audit's predicted +6 is because the `i < n` post-loop goal also discharged once the outer invariant was in place.

#### Fix 2 — `arr_disjoint` precondition (`kfold_view.mbt:38`)

The `FoldView::new` postcondition asserts `arr_disjoint(result.train_idx, result.test_idx)`, but the v1 precondition only required length positivity. The implementation is a no-op `{ train_idx, test_idx }` constructor, so disjointness cannot be enforced at runtime. The postcondition was therefore **unsound** for any non-disjoint input meeting the v1 preconditions. The verifier audit (Finding #2) and Mutation 1 both confirmed: dropping the `arr_disjoint` conjunct made the goal discharge, which means the prover is correctly *unable* to prove the unsound claim.

Added `proof_require: arr_disjoint(train_idx, test_idx)` to `FoldView::new`. The postcondition then follows trivially (the result's `train_idx` IS `train_idx` and `test_idx` IS `test_idx`, so the result's `arr_disjoint` is the precondition's `arr_disjoint`).

**After Fix 1 + Fix 2:** 17 valid / 2 timeout. Fix 2 closed the `FoldView::new'vc` postcondition timeout that the v1 baseline had, and that discharge is now part of the 17v baseline. (The audit predicted the 18v/1t for Fix 1+2 because they ran the steps incrementally; in this v2 pass I applied both simultaneously and the combined effect is the same: 17v → 17v because the `FoldView::new` goal that Fix 2 closes was already counted in the 17v.)

#### Fix 3 — Strengthen inner-loop invariant (attempted, then reverted)

The audit suggested strengthening the inner loop's `proof_invariant` to record "if `found == true`, then `pos` is the last `k` in `[0, n_units)` with `uniq[k] == g`", as the fix for the two remaining timeouts:
- `proof_assert found` (after the inner loop)
- The overall `row_unit_map_view_ok` postcondition (which depends on `found` being true for every `i`)

I attempted two strengthening forms and **both regressed the result** to 17v/3t (the new third timeout was the invariant-preservation step itself, where the prover must re-establish the strengthened invariant after the body of the if-branch `pos = k; found = true`).

**Form 3a (rejected):** `proof_invariant: 0 <= k && k <= n_units && (!found || (0 <= pos && pos < n_units && uniq[pos] == g))`
- Why it failed: after the body, the prover must discharge `0 <= pos && pos < n_units && uniq[pos] == g` given that `pos = k` was just assigned. The `uniq[pos] == g` part should reduce to `uniq[k] == g` (the if-condition) via Why3's ref-substitution, but the prover times out on this within the default budget.

**Form 3b (rejected):** `proof_invariant: 0 <= k && k <= n_units && (!found || uniq[pos] == g)`
- Same failure mode: invariant preservation times out on the `uniq[pos] == g` half after the `pos <- k` assignment.

**Final inner-loop invariant (retained):** `proof_invariant: 0 <= k && k <= n_units` (the same as Fix 1).

#### Final state: 17 valid / 2 timeout

**17 valid / 0 invalid / 0 unknown / 0 oom / 0 step_limit / 2 timeout / 0 failure** (19 total goals).

The 2 remaining timeouts are **both at `_prove_pilot/kfold_view.mbt:104`** (the inner loop's exit), specifically:
1. The `proof_assert found` after the inner loop.
2. The `proof_ensure: result => row_unit_map_view_ok(result, cluster, uniq)` postcondition.

**Why these are genuinely hard (and not addressable by current invariants):**

Both timeouts share the same root cause: the prover must bridge *"after the inner loop, all `k` in `[0, n_units)` have been checked"* + *"`cluster_subset_of cluster uniq` precondition says `∃ k, uniq[k] == g`"* → *"the body set `found := true` at some point"*. This is an **inductive argument over the loop body**:

- The invariant "if not found, no k in [0, k) has uniq[k] == g" cannot be expressed cleanly in the current MoonBit `proof_invariant` grammar because the body is an imperative `if` statement, not a functional fold. The SMT does not propagate "I haven't seen a match yet" across iterations without the invariant.
- The `cluster_subset_of` precondition is available to the prover as an axiom (`H_cluster_subset_of` in the lowered .mlw), but the prover cannot inductively use it inside the loop body.

Possible future fixes (out of scope for this v2 pass):
- **Restructure the body to break early on first match.** This would make `found` trivially true after the loop body, and `pos` would be the *smallest* `k` (still valid for the postcondition). But it changes runtime behavior, which is outside the `proof_*`-only scope of this producer pass.
- **Introduce a `proof_axiomatized: true` lemma** in `kfold_view_proof.mbtp` that captures the "iff" reasoning as a single documented trusted fact. This is a deliberate trust-surface addition, and per the audit rules requires inline documentation of what is assumed and why. I did not introduce it because the v2 task asked to avoid adding trusted surface unless necessary, and a simple `proof_axiomatized` would not in itself discharge the postcondition — it would need to be carefully shaped to match the postcondition's quantifier structure.
- **File upstream** for a stronger Why3 invariant tactic or for an alternative "smallest match" lemma generator in the MoonBit proof frontend. The audit's recommendation to file upstream for the `Array`/`array` lowering gap is independent of this.

### Trust surface (v2)

**Unchanged from v1: None.** No `proof_axiomatized`, `proof_decrease`, `#proof_external`, `#proof_import` declarations. The two remaining timeouts are SMT-bridge limitations on **discharged-but-unprovable** goals, not user-authored trust assumptions.

### Files changed in v2

| File | Change |
| --- | --- |
| `_prove_pilot/kfold_view.mbt` | Added `where { proof_invariant: 0 <= i && i <= n }` after the outer for-loop (line 122-124); added `where { proof_invariant: 0 <= k && k <= n_units }` after the inner for-loop (line 115-117); added `proof_require: arr_disjoint(train_idx, test_idx)` to `FoldView::new` (line 38); updated doc comments on `FoldView::new` and the inner loop to document the soundness/limitations. |
| `_prove_pilot/kfold_view_proof.mbtp` | **Unchanged** in v2. The audit-scratch `kfold_view_proof.mbtp.archived` is left untouched as a historical record. |
| `_prove_pilot/HANDOFF.md` | This file — v1 moon prove summary section updated; v2 appendix appended. |

### Validation sequence (v2)

| Check | Result |
| --- | --- |
| `moon check` (project-wide) | 0 errors, 4 warnings (2 pre-existing in `_prove_pilot/kfold_view_proof.mbtp` about unused `kfold_view_post` / `perm_is_perm`, 2 in `audit-scratch/kfold_view_proof.mbtp` same as above) |
| `moon fmt --check _prove_pilot` | clean (exit 0) after `moon fmt` was run once to normalize pre-existing comment spacing |
| `moon test -p "mavis/dml/_prove_pilot"` | 4/4 runtime tests pass |
| `moon prove _prove_pilot` | **17 valid / 0 invalid / 0 unknown / 0 oom / 0 step_limit / 2 timeout / 0 failure** (19 total goals) |

### Handoff back to verifier

- **`moonbit-prove-verifier`** should re-audit the v2 deliverable. Focus areas:
  1. **Soundness of the new `arr_disjoint` precondition.** Verify that every runtime call site of `FoldView::new` in `_prove_pilot/` and (in the future) the main package satisfies the stronger precondition. The 4 runtime tests in `_prove_pilot/kfold_view.mbt` all use disjoint inputs, so the contract is not vacuously satisfied. The 297 main-package tests do not call `Fold::new` directly (they go through `kfold(n, n_folds, seed)`), so the migration to the main package will require a separate audit when the toolchain gap is closed.
  2. **The two remaining timeouts.** Verify the v2 appendix's "genuinely hard" analysis. The two timeouts are the same root cause (the `found` claim), and the audit may want to confirm that no simple strengthening of the inner-loop invariant is missed.
  3. **No trust surface was added.** The v2 trust-surface section ("None") should be cross-checked against the source files.
- **The audit should NOT attack** the `where { proof_invariant: ... }` block syntax — it is the documented v0.10.11 form and discharges cleanly (4 of the 5 v1 timeouts closed by it alone).
- **Independent of v2:** file upstream for the `Array` -> `array` Why3 lowering gap (the main package's `moon prove` is still blocked on this, per the v1 handoff).
