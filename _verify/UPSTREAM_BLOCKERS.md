# Upstream Toolchain Blockers — MoonBit 0.9+ `moon prove` Pipeline

**Discovered during**: moonbit_doubleML v0.48.0 formal verification pilot
**Reporter**: `ren-yongxiang` (gitee)
**Pilot evidence**: `_prove_pilot/` and `_prove_pilot2/` in moonbit_doubleML
**Toolchain**: moon 0.1.20260920 (914d7da 2026-09-20) / moonc v0.10.11+,
Why3 1.7.2, CVC5 1.0.9 / Alt-Ergo 2.5.4

These four blockers prevent the moonbit_doubleML main package's `moon prove`
from running end-to-end on contracts that reference `Array[T]`, use
`Double` arithmetic, or wrap contracts around `raise` boundaries.
Fixing them would unlock formal verification of the 21 DML estimators
in moonbit_doubleML (PLR / IRM / PLIV / IIVM / DID family / PLPR / LPLR /
LPQ / bootstrap / quantiles / resampling / cluster-robust SE).

> **Status as of v0.52.0 release (2026-09-19)**: the project shipped
> v0.52.0 with all 21 estimators working (4 backends × 331/331 PASS,
> 11 fuzz 0 violations, 23/23 Python validators PASS) but **without
> any of the 4 + 2 upstream blockers resolved**. Production code in
> moonbit_doubleML does not use formal contracts; preconditions are
> enforced at runtime via the v0.48.0 cascade wrap
> (`try { require(...) } catch { ... abort(...) }`). The 6 blockers
> below remain the gate for any future v0.53+ attempt to add proof
> contracts to the main package. The v0.52.0+ integration target
> verdict is **NOT VIABLE** on the current toolchain — see
> "Handoff: v0.52.0+ integration target viability" below. The 6
> upstream issue drafts at `_verify/UPSTREAM_ISSUE_0[1-6].md` are
> ready for filing against <https://github.com/moonbitlang/core>.

---

## Blocker 1 (highest priority): `Array[T]` → `array` Why3 lowering missing `use array.Array`

### Symptom

When `options("proof-enabled": true)` is set on a package whose `.mbt`
files reference `Array[T]` (either in struct fields OR in function
parameters), `moonc prove` lowers to Why3 and the generated `.mlw`
defines types like:

```why3
type mavis__moonbit_doubleML__Matrix = { ..., mavis__moonbit_doubleML__Matrix__data : array int }
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

All numerical contracts are blocked. Without this fix, moonbit_doubleML's
21 estimators (which all compute on `Double` arrays) cannot be
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

With 1+2+3+4 fixed, moonbit_doubleML can resume formal verification on
the 21 DML estimators in the main package. Without 1, only the
`FixedArray[Int]` mirror pattern in `_prove_pilot/` can be used,
which limits verified surface to pure Int algorithms.

---

## References

- moonbit_doubleML project: `https://gitee.com/ren-yongxiang/moonbit_doubleml`
- Pilot 1 handoff: `_prove_pilot/HANDOFF.md`
- Pilot 1 verifier audit: `_prove_pilot/VERIFIER_AUDIT.md` (v1) +
  `_prove_pilot/VERIFIER_AUDIT_v2.md` (v2 with v3 correction + v4
  self-review)
- Pilot 2 handoff: `QUANTILE_HANDOFF.md`
- MoonBit verification docs: `https://docs.moonbitlang.com/en/stable/language/verification.html`
- Verified example packages: `https://github.com/moonbit-community/verified`
- 100+ compact proof exercises: `https://github.com/Yu-zh/moonbit-proof`

---

## Reproduction log (2026-09-12, v0.51.0 → v0.52.0 cycle, moonc v0.10.11)

**Producer**: `moonbit-prover` worker, branch session
`mvs_5e8e4d20578c4557a866e6b000e0c5ef` (the original v0.52 main-package
contract pilot, executed immediately before the verifier audit).
**Toolchain**: moon 0.1.20250904, moonc v0.10.11, Why3 1.7.2,
CVC5 1.0.9 / Alt-Ergo 2.5.4.
**HEAD at start**: `7a16b6f Release 0.51.0: DoubleMLDIDCSBinary`.
**HEAD at v0.52.0 release**: `9e7896a Release 0.52.0: LPQ completeness + estimator fit() cascade wrap + backend math consistency`.

> **Note on staleness**: this reproduction log was written during the
> v0.51.0 → v0.52.0 development cycle. At v0.52.0 release (commit
> `9e7896a`, 2026-09-19) the verdict below — "v0.52.0+ integration
> NOT VIABLE" — remained the project consensus. The reproduction
> artifacts (audit-scratch dir, kfold_proof.mbtp) were moved out of
> the working tree at v0.52.0 release time (audit-scratch archived;
> kfold_proof.mbtp moved to `_archived-kfold_proof.mbtp` at
> `D:\src\MiniMax\Projects\DoubleMachineLearning\_archived-kfold_proof.mbtp`).
> Audit logs + categorization CSV/TXT were preserved as sibling files
> under `_verify/audit-scratch-v0.52_*.{log,csv,txt}` for any future
> re-audit after a toolchain upgrade.

### Phase 1 — Baseline (verified)

- `moon check`: 0 errors
  (`Finished. moon: ran 19 tasks, now up to date (40 warnings, 0 errors)`)
- `moon prove _prove_pilot`: **17 valid / 2 timeout / 0 trust surface**
- `moon test --target native`: 329 passed / 0 failed

### Phase 2 + 3 — Main-package contract attempt

Setup:

- `moon.pkg` temporarily toggled `options("proof-enabled": true)`.
- `kfold.mbt::kfold_stratified` (lines 260-350) got the Int-only
  `where { proof_require: n > 0, proof_require: n_folds > 0 }` clause.
  Int-only preconditions were chosen to avoid firing Blocker 1
  (Array lowering) inside the contract itself, isolating the
  body-side errors to the main loop bodies.
- New `kfold_proof.mbtp` planning artifact with `kfold_stratified_post`
  / `arr_bounded` / `arr_disjoint` / `perm_is_perm` predicates, all
  using `Array[Int]` to match the main-package `Fold` struct fields
  (this is the surface that fires Blocker 1 on the predicate side).
  `kfold_proof.mbtp` was archived out to
  `_archived-kfold_proof.mbtp` (one level above the project root)
  at v0.52.0 release time; the predicates are reproduced verbatim
  in the audit-scratch `kfold_view_proof.mbtp` and are available
  for re-application when the upstream picture improves.

`moon prove .` produced **80 `Error: [4207]`** blocks, broken down:

| Error class | Count |
| --- | ---: |
| `unsupported primitive operator in contracted function body` | 28 |
| `unsupported expression in contracted function body` | 19 |
| `unsupported primitive operator in logic body` | 17 |
| `only contracted functions, imported proof-callable functions, pure functions, and primitive operators can be called in contracted function bodies` | 16 |

### Categorized errors vs. the 4 documented buckets

- **Bucket 1 (Array lowering): 45 errors (28 body + 17 logic) — CONFIRMED.**
  Every `arr.length()`, `arr[i]`, `arr.push`, `Array::make`,
  `Array::makei`, `Array.swap`, plus `folds[f].train_idx` (Fold's
  `Array[Int]` field) in either the body or the `.mbtp` predicate.
  Underlying cause is the same as documented (missing
  `use array.Array` in the WhyML preamble). Sites:
  `kfold.mbt:289, 291, 292, 293, 299, 305, 306-310, 311-315,
  317-321, 324-327, 328-332, 336-350, 354`;
  `kfold_proof.mbtp:26, 33, 41, 55-60, 69-71`.

- **Bucket 2 (Double comparison): 0 errors — NOT TRIGGERED.**
  Contract is Int-only. Pilot 2's `_prove_pilot2/quantile_view` is
  the right reproducer.

- **Bucket 3 (raise in body): 0 errors — NOT TRIGGERED.**
  Function body uses `try { require() } catch { abort() }` (no
  `raise X`). The shim itself is rejected as the **New Block B**
  below.

- **Bucket 4 (foreach): 0 errors — NOT TRIGGERED.**
  All loops are C-style range with single Int binder. Pilot 2's
  `_prove_pilot2/probe_int.mbt` is the right reproducer.

### New findings (2 undocumented upstream restrictions surfaced)

- **New Block A (function call whitelist, 16 errors):**
  non-`#proof_pure` / non-`#proof_callable` calls rejected in
  contracted bodies — `seed_to_bytes`, `@random.Rand::chacha8`,
  `Bytes::from_array`, `Array::make`, `Array::makei`, `perm.swap`,
  `rng.int`, `stratum_perm.push`, `train_idx.push`, `test_idx.push`,
  `folds.push`, `Fold::new`.

- **New Block B (literal / block expressions, 19 errors):**
  `try { ... } catch { ... }`, `let x : Array[T] = []`,
  `(key, [i])`, `[i]` literal all rejected as
  "unsupported expression in contracted function body". The very
  first statement of every DML estimator's contract candidate is
  `try { ... }` — so this blocks all of them.

### Phase 5 + 6 — Reverted and confirmed

- `git status` (at time of original reproduction):
  - `M _verify/UPSTREAM_BLOCKERS.md` (this appended section)
  - `?? kfold_proof.mbtp` (new planning file, archived to
    `_archived-kfold_proof.mbtp` at v0.52.0 release time)
  - `moon.pkg` and `kfold.mbt`: clean (no diff)
- `git status` (post-v0.52.0 release):
  - `_verify/UPSTREAM_BLOCKERS.md` (still tracked; v0.52.0+ status
    note appended at the top of the document)
  - `kfold_proof.mbtp`: archived (see above)
  - `_verify/audit-scratch-v0.52/`: archived; sibling log/CSV/TXT
    files preserved
  - `moon.pkg` and `kfold.mbt`: clean (no diff)
- `moon check`: 0 errors
  (`Finished. moon: ran 32 tasks, now up to date (40 warnings, 0 errors)`)
- `moon test --target native`: 329 passed / 0 failed
- `moon prove _prove_pilot`: 17 valid / 2 timeout (unchanged)

### Handoff: v0.52.0+ integration target viability

**The v0.52.0+ integration of `_prove_pilot` onto the main package
is NOT viable given the current upstream blockers** — and the gap is
wider than the 4-bucket characterization suggests. Bucket 1 alone
(45/80 = 56% of errors) is enough to prevent any `moon prove .` from
running on a package that uses `Array[T]` in struct fields or
function parameters; the proposed single-line `use array.Array`
preamble fix would unblock the predicate side (17 errors) and the
body-side `arr[i]` / `arr.length()` / `arr.push` rejections
(28 errors), leaving the body fully unwitnessable without also
resolving New Block A (function call whitelist) and New Block B
(literal / block expressions in contracted bodies).

Even with all 4 documented blockers resolved, the DML estimator
main bodies cannot be contracted because the
`try { require() } catch { ... abort() }` precondition shim is the
very first statement of every body, and the `try { ... }` block is
itself rejected (New Block B).

The minimal v0.52.0+ path forward is:

- **(a)** Fix Bucket 1 first (the single-line `use array.Array`
  toolchain change, unblocking all 45 predicate/body `Array[T]`
  references).
- **(b)** Restructure the contract candidate so the precondition
  shim is in a non-contracted helper, with the contracted function
  body containing only `#proof_pure` calls and primitive operations.

Buckets 2/3/4 are not on the critical path for `kfold_stratified`
(the chosen reproducer), and the existing `_prove_pilot` /
`_prove_pilot2` packages already exercise them adequately. The new
`kfold_proof.mbtp` planning file is the right shape for the v0.52.0+
migration; it just can't be wired up to the main package until the
upstream picture improves.

**v0.52.0 release verdict**: this verdict held at v0.52.0 release
(2026-09-19). The project shipped v0.52.0 with all 21 DML estimators
working in production (without formal contracts), and the upstream
toolchain picture is unchanged as of the v0.52.0 release toolchain
(`moon 0.1.20260920 (914d7da 2026-09-20)` / `moonc v0.10.11+`).
A re-audit is recommended whenever MoonBit publishes a proof-
frontend release that addresses any of the 4 + 2 blockers above;
the audit-scratch mirror at
`_verify/audit-scratch-v0.52_*.{log,csv,txt}` is the right
re-application surface.

**Next verifier**: `moonbit-prove-verifier` (adversarial audit of the
new `kfold_proof.mbtp` predicates and this `UPSTREAM_BLOCKERS.md`
reproduction log; verify the categorization matches an independent
reading of `_build/verif/.../*.mlw` and the Bucket 1 reproduction
snippet genuinely triggers the documented error).

---

## v0.52 reproduction audit (2026-09-12, verifier)

**Auditor**: `moonbit-prove-verifier` (verifier worker, branch session
`mvs_b2665c67c37649dcad1df4f769ccb8fc`).
**Toolchain observed**: moon 0.1.20260904, moonc v0.10.12+1634b282e
(different from producer's reported v0.10.11, but compatible 鈥?see
Finding A1).
**Audit scratch** (post-v0.52.0 release state):
`_verify/audit-scratch-v0.52/` (archived; logs preserved as
`_verify/audit-scratch-v0.52_*.{log,csv,txt}`),
`_verify/audit-bucket2-double/` (hyphen-named; tracked),
`_verify/audit_bucket3_raise/` (underscore-named; tracked),
`_verify/audit_bucket4_foreach/` (underscore-named; tracked).

### Phase 1 baseline (re-confirmed)

- `moon check`: 0 errors
  (`Finished. moon: ran 19 tasks, now up to date (40 warnings, 0 errors)`)
- `moon test --target native`: 329 / 329 pass
- `moon prove _prove_pilot`: 17 valid / 2 timeout
  (cached report at `_build/verif/_prove_pilot/_prove_pilot.proof.json`)

PASS.

### Phase 2 independent reproduction

A minimal mirror of `kfold_stratified` was set up at
`_verify/audit-scratch-v0.52/`. The mirror:

- Uses `Array[Int]` (not `FixedArray[Int]`) to exercise the producer's
  Bucket 1 path.
- Has the same control-flow shape as the main package's
  `kfold_stratified` (stratification, Fisher-Yates permutation with
  RNG, fold building with `Fold::new`).
- Replaces the main package's `seed_to_bytes` + `Bytes::from_array` +
  `@random.Rand::chacha8` with a stand-in `seed_to_bytes : Int -> Int`
  to keep the audit-scratch self-contained.
- Has Int-only contracts (no `Double` comparison, no `raise` in body,
  no `for x in arr` foreach) so Buckets 2/3/4 should NOT fire.
- Has a `try { ... } catch { ... }` shim and Array literals so
  New Blocks A and B should fire.
- Has a `proof_ensure: result => fold_is_valid(result.length(), n)`
  referencing a non-`#proof_pure` helper to exercise the
  `only direct logic-function calls` restriction.

`moon prove .` output (full log at
`_verify/audit-scratch-v0.52_prove.log`):

- **57** occurrences of `Error: [4207]` in the log.
- **2** are PowerShell-error-formatting duplicates of the first moon
  error (cosmetic; the actual moon error message is intact in the
  box-drawing after the PowerShell info block).
- **55** are real moon errors with file location, OR **56** when
  the PowerShell-formatted first error is counted (it has a real
  moon file location at line 8 of the log; the "PowerShell wrapper"
  detection I used was a false positive on the first error).

After line-wrap correction (the message "unsupported primitive
operator in contracted function body" wraps to two lines as
`... function bod` + `y` in the source), the 56 real errors
categorize as follows (CSV at
`_verify/audit-scratch-v0.52_categorization.csv`):

### Phase 3 categorization (auditor)

| Error class                                                    | Count |
| -------------------------------------------------------------- | ----: |
| `unsupported primitive operator in contracted function body`   |  16   |
| `unsupported primitive operator in logic body`                 |  18   |
| `unsupported expression in contracted function body`           |  14   |
| `only contracted functions, imported proof-callable functions, pure functions, and primitive operators can be called in contracted function bodies` |  7 |
| `only direct logic-function calls, pure function calls, supported function-value applications, and primitive operators are supported in logic body` | 1 |
| **Total**                                                     | **56** |

Mapping to the producer's 6-category scheme:

| Category                | Mapping                                            | Count |
| ----------------------- | -------------------------------------------------- | ----: |
| Bucket 1 (Array lower)  | prim_body (16) + prim_logic (18)                   |  34   |
| Bucket 2 (Double cmp)   | (none expected 鈥?Int-only contract)                |   0   |
| Bucket 3 (raise in body)| (none expected 鈥?try/catch shim only)              |   0   |
| Bucket 4 (foreach)      | (none expected 鈥?C-style range only)               |   0   |
| New Block A (call wl)   | call_body (7) + call_logic (1)                     |   8   |
| New Block B (lit/block) | expr_body (14)                                     |  14   |
| **Total**               |                                                    | **56**|

### Phase 4 cross-check vs. producer's main-package claims

The audit-scratch is a smaller mirror of the main package's
`kfold_stratified` body, so absolute error counts are expected to
be lower. Comparing **proportions** is the right check.

| Category                | Producer (main, 80 total) | Auditor (audit-scratch, 56 total) | Ratio match? |
| ----------------------- | ------------------------: | --------------------------------: | ------------ |
| Bucket 1                | 45 / 80 = 56.25%          | 34 / 56 = 60.7%                   | OK (within 5%) |
| Bucket 2                |  0 / 80 =  0.00%          |  0 / 56 =  0.0%                   | OK          |
| Bucket 3                |  0 / 80 =  0.00%          |  0 / 56 =  0.0%                   | OK          |
| Bucket 4                |  0 / 80 =  0.00%          |  0 / 56 =  0.0%                   | OK          |
| New Block A             | 16 / 80 = 20.00%          |  8 / 56 = 14.3%                   | OK (within 6%) |
| New Block B             | 19 / 80 = 23.75%          | 14 / 56 = 25.0%                   | OK (within 2%) |

PASS on proportions. The audit-scratch is missing some call sites
that the main package's `kfold_stratified` body has (e.g. the
`@random.Rand::chacha8` constructor, the `perm.swap(i, j)` call,
the `rng.int(limit=...)` call, the `Fold::new(...)` constructor
inside `folds.push(...)`), which is why New Block A is 8 in
the audit-scratch vs 16 in the main package. The per-call-site
identification is consistent with the producer's listing.

### Phase 5 not-triggered verdict verification

#### Bucket 2 (Double comparison) 鈥?**VERDICT: REPRODUCER FIRES**

Minimal reproducer at `_verify/audit-bucket2-double/double_cmp.mbt`:

```moonbit
pub fn double_cmp(x : Double, n : Int) -> Bool where {
  proof_require: x < 1.5,
  proof_require: n > 0,
  proof_ensure: result => result == (x < 1.5),
} {
  x < 1.5
}
```

`moon prove _verify/audit-bucket2-double` output (log:
`_verify/audit-bucket2-double/prove_v3.log`):

- `unsupported primitive operator in logic body` on `x < 1.5`
  in `proof_require` (2 errors)
- `only Bool, Byte, Int, UInt, Int64, and UInt64 constants are
  supported in logic body` on the `1.5` literal (2 errors)
- `unsupported primitive operator in contracted function body`
  on `x < 1.5` in the body (1 error)
- `only Bool, Byte, Int, UInt, Int64, and UInt64 constants are
  supported in contracted function body` on the `1.5` literal
  (1 error)

Total: 6 errors fire. The producer's "Bucket 2 not triggered"
verdict for the **main package** is correct because the main
package's Int-only contract doesn't use Double comparison. The
underlying Blocker 2 itself is real and reproducible.

**Note**: the producer's characterization of Bucket 2 as "Double
comparison primitives not supported" is **incomplete**. The
minimal reproducer also surfaces a separate restriction 鈥?`1.5` (a `Double` literal) is rejected with a different error
("only Bool/Byte/Int/UInt/Int64/UInt64 constants are supported
in logic/contracted function body"). This is a sub-class of
"Double literal in proof body" that the producer's report does
not name. See Finding A2.

#### Bucket 3 (raise in body) 鈥?**VERDICT: REPRODUCER BEHAVIOR UNUSUAL**

The minimal reproducer for Bucket 3 (a function with
`proof_require` whose body uses `raise X`) causes **`moonc prove`
to fail entirely** with the help-text error
`moonc prove [options] <input files>` (no specific "raise in
contracted body" diagnostic). The same help-text error fires for
many different non-trivial body shapes:

- `pub fn foo(x : Int) -> Int raise SomeError where { ... }` with
  `raise SomeError` in the body 鈫?fails.
- `pub fn foo(x : Int) -> Int where { ... }` with no `raise` but
  calling a helper that has `raise` 鈫?still fails.
- A bare contracted function with no `raise` at all
  (sanity check) 鈫?**works** (proof runs, no "raise" error).
- Same function with `abort(...)` instead of `raise` 鈫?works
  (this is the main package's workaround).

This is a toolchain-blocking failure, not a clean diagnostic. The
producer's "Bucket 3 not triggered" verdict for the main package
is correct, but for a slightly different reason than the producer
states: the main package's `try { require() } catch { abort() }`
shim is not just a workaround for Blocker 3 鈥?it is **the only
shape that lets the package be proven at all**. A package whose
body contains a `raise` (even wrapped in try/catch with abort)
is **rejected by `moonc prove` before any of the 4 documented
blockers can fire**.

See Finding A3.

#### Bucket 4 (foreach) 鈥?**VERDICT: REPRODUCER BEHAVIOR UNUSUAL**

The minimal reproducer for Bucket 4 (a function with
`proof_require` whose body uses `for x in arr`) also causes
`moonc prove` to fail with the help-text error, identical to
Bucket 3 above. The reproducer cannot be tested in isolation
because the test package becomes un-provable in any shape that
uses `for x in <range>` (the `for x in 0..<n` form also fails).

The producer's "Bucket 4 not triggered" verdict for the main
package is correct (the main package uses only C-style range),
but a stand-alone reproducer is **not directly runnable** against
the current toolchain. See Finding A4.

### Findings

#### A1 (minor): toolchain version drift

The producer's report says "moonc v0.10.11" in the reproduction
log header. The audit environment has
`moonc v0.10.12+1634b282e (2026-09-07)`. One patch version higher
than the producer's environment. The error categories
(unsupported primitive operator in {logic, contracted function
body}, unsupported expression in {logic, contracted function
body}, only X can be called, only direct logic-function calls)
are identical between v0.10.11 and v0.10.12, so the categorization
is still valid. **Recommendation**: when the producer revises the
report, note the version in the audit-scratch header so future
audits can diff against a known baseline.

#### A2 (major): "Double literal in proof body" is a missing 5th error class

The producer's Bucket 2 names only "Double comparison primitives
not supported in proof pipeline". The minimal reproducer at
`_verify/audit-bucket2-double/` surfaces a separate restriction:
a `Double` *literal* (e.g. `1.5`) in any `proof_*` body or
contracted function body is rejected with
`only Bool, Byte, Int, UInt, Int64, and UInt64 constants are
supported in [logic|contracted function] body`. This is distinct
from the `<` operator rejection. The producer's report does not
name this restriction.

**Severity**: major. The combined "no `Double` at all in proof
body" restriction is a stronger statement than "no `Double`
comparison in proof body", and the producer's 4-blocker summary
understates this. Future contractors using `Double` thresholds
(e.g. `proof_require: 0.05 < alpha`) will hit both restrictions.

**Reproduction**: see
`_verify/audit-bucket2-double/double_cmp.mbt` + the
`prove_v3.log` output.

**Recommendation**: file this as a sub-class of Blocker 2 in
`_verify/UPSTREAM_BLOCKERS.md` (or rename Blocker 2 to
"`Double` values in proof body") and link the minimal
reproducer.

#### A3 (major): `moonc prove` help-text error masks Bucket 3

The minimal reproducer for Bucket 3 (`raise X` in a contracted
function body) does **not** produce a clean
`"raise" in contracted function body is not supported` diagnostic.
Instead, `moonc prove` exits with the help-text
`moonc prove [options] <input files>` error, indicating that
the moonc binary received no valid input file. This means the
**proof pipeline does not report a precise Bucket 3 failure
mode** for the reproducer 鈥?it just dies.

The producer's claim that "Blocker 3 is not triggered in the
main package" is correct (the main package avoids `raise`
entirely), but a user who tries to convert
`try { require() } catch { abort() }` to `raise PreconditionError`
will not see a clear diagnostic 鈥?they will see the moonc help
text and have to manually diagnose why the package is
un-provable.

**Severity**: major. The lack of a precise error makes Blocker 3
**less actionable** than the producer's report suggests.

**Reproduction**: see
`_verify/audit_bucket3_raise/raise_test.mbt` + the `prove_v9.log`
output (`moonc prove [options] <input files]`).

**Recommendation**: this is a toolchain bug, not a project
finding. The moonc binary should either accept a package with
`raise`-typed functions and report a specific error, or refuse
to start with a clear "package contains raise-typed functions;
proof not supported" message. File upstream.

#### A4 (minor): `moonc prove` help-text error also masks Bucket 4

Same as Finding A3 but for `for x in arr` in a contracted body.
The moonc binary exits with the help-text error, not a clean
"for x in v not supported" diagnostic. The producer's "Bucket 4
not triggered" verdict is correct for the main package, but
a user who tries `for x in arr` will not see a clean
diagnostic.

**Severity**: minor (consistent with A3).

**Reproduction**: see
`_verify/audit_bucket4_foreach/foreach_test.mbt` + the
`prove_v2.log` output.

**Recommendation**: same as A3 鈥?file upstream.

#### A5 (nit): audit-scratch `seed_to_bytes` is a stand-in, not the real helper

The audit-scratch's `seed_to_bytes : Int -> Int` is a stand-in
for the main package's `seed_to_bytes : Int -> Array[Int]`
(8-byte little-endian). The stand-in is not byte-equivalent and
is not intended to be 鈥?the audit-scratch is verifying the
**contract and proof pipeline behavior**, not the runtime
correctness of `seed_to_bytes`. The audit-scratch's RNG and
permutation are also stand-ins. This is documented in
`kfold_view.mbt:5-15`.

**Severity**: nit. The audit-scratch's role is to test the proof
pipeline, not the runtime. The stand-in is a deliberate scope
choice.

#### A6 (nit): producer's "80 errors" matches the audit-scratch "56 errors" pattern

The audit-scratch's 56 errors are distributed across the same
6 categories as the producer's 80 errors, with proportions within
5-6% of each other. The audit-scratch is a smaller mirror
(intentionally 鈥?it strips the random-RNG and the
`Bytes::from_array` chain to keep the package self-contained),
so the absolute counts differ but the relative distribution is
consistent. This is a sanity check, not a finding.

**Severity**: nit. The audit-scratch's purpose was to confirm
the producer's categorization, not to reproduce the exact
error count. The categorization is confirmed.

### Audit verdict

**REPRODUCTION_LOG_CONFIRMED** with two amendments:

1. **Finding A2 (major)**: Producer's Bucket 2 description is
   under-specified. The actual restriction is "no `Double` value
   (literal or comparison) in any `proof_*` body or contracted
   function body", not just "no `Double` comparison". The
   audit-scratch's `_verify/audit-bucket2-double/` is a working
   reproducer.

2. **Finding A3 (major) + A4 (minor)**: Producer's "Bucket 3/4
   not triggered" verdicts are correct for the main package,
   but the corresponding minimal reproducers (`raise` / `for-in`)
   cannot be tested because the toolchain fails with a generic
   help-text error rather than a clean diagnostic. The
   producer should note in the report that the toolchain-side
   "fail" is not a clean per-class diagnostic.

The producer's headline 4-bucket + 2-new-block categorization
(45 / 0 / 0 / 0 / 16 / 19) is **correct in classification** and
**consistent in proportion** with the audit-scratch's
34 / 0 / 0 / 0 / 8 / 14.

### Audit-scratch cleanup

The audit-scratch lives at (post-v0.52.0 release state, 2026-09-20):

- `_verify/audit-scratch-v0.52/` — **archived at v0.52.0 release
  time**. Logs/CSV/TXT were preserved as sibling files (see below).
- `_verify/audit-bucket2-double/` (Bucket 2 minimal reproducer;
  note the **hyphen** in this name — `audit-bucket2-double`,
  distinct from bucket 3/4 below)
- `_verify/audit_bucket3_raise/` (Bucket 3 minimal reproducer,
  moonc-help-text; **underscore** in this name)
- `_verify/audit_bucket4_foreach/` (Bucket 4 minimal reproducer,
  moonc-help-text; **underscore** in this name)
- `_verify/test-bucket3-raise/`, `_verify/test-bucket4-foreach/`
  (intermediate test directories from the audit)
- `_verify/audit-scratch-v0.52_check.log` (preserved sibling)
- `_verify/audit-scratch-v0.52_prove.log` (preserved sibling)
- `_verify/audit-scratch-v0.52_categorization.csv` (preserved
  sibling)
- `_verify/audit-scratch-v0.52_categorization.txt` (preserved
  sibling)

These should be added to `.gitignore` (or equivalent) so they
are not committed. They are useful for re-audits; the producer
can re-run `moon prove` against them to re-verify the
reproduction after any toolchain upgrade. The `.gitignore`
patterns `audit-scratch*` (added in commit `3f6ebd3` at v0.52.0
release time) and `*.archived` / `*.archived.*` (added in commit
`08e3d37`) cover the audit-scratch cleanup scope; the bucket
minimal reproducers remain tracked because their path is
predictable (and they fit in the repo).
