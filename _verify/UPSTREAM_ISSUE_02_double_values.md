# `moon prove`: `Double` value (literal or comparison) not supported in proof body

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
> | the restriction described here | last *observed* on `moonc v0.10.11` / `v0.10.12` | **re-audited 2026-10-20 on `moonc v0.10.16+b1a0e846e`**: still fires, **6 errors with the same four-way split -- reproduced exactly** |
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
**Series**: Issue 2/6 of the moonbit_doubleML formal-verification
toolchain gap. See `_verify/UPSTREAM_BLOCKERS.md` for the master
document and issues 1, 3-6 for the related restrictions.

**Reporter**: `ren-yongxiang` (moonbit_doubleML project, v0.52.0+)
**Affected toolchain (when observed)**: `moon 0.1.20260920 (914d7da
2026-09-20)` / `moonc v0.10.11`; originally observed on v0.10.11, reproduced
on v0.10.12+1634b282e, still present on the v0.52.0 release toolchain.
**Re-audited 2026-10-20** on `moon 0.1.20261016 (1af328f 2026-10-16)` /
`moonc v0.10.16+b1a0e846e`; see the banner above and
`_verify/upstream_prove_1649/`.
**Priority**: high (frontend extension; unlocks all numerical
contracts)

---

## Symptom

Inside any `proof_require` / `proof_ensure` / `proof_invariant` /
contracted function body, the primitive operators `<`, `>`, `<=`,
`>=`, `==` on `Double` values are rejected by `moonc prove`.
Integer comparisons work fine.

## Audit finding 2a (surfaces a related but distinct restriction)

The minimal reproducer at
`moonbit_doubleML/_verify/audit-bucket2-double/double_cmp.mbt` (full
log: `moonbit_doubleML/_verify/audit-bucket2-double/prove_v3.log`)
shows that a `Double` *literal* in any `proof_*` body or contracted
function body is also rejected, with a **different** error
message:

> `only Bool, Byte, Int, UInt, Int64, and UInt64 constants are
> supported in logic body` (on the `1.5` literal)
>
> `only Bool, Byte, Int, UInt, Int64, and UInt64 constants are
> supported in contracted function body` (on the `1.5` literal)

The audit reproducer triggers 6 errors total (2× comparison, 2×
literal in logic, 1× comparison in body, 1× literal in body). The
combined restriction is "**no `Double` value (literal or
comparison) in any `proof_*` body or contracted function body**",
which is a stronger statement than the Pilot 2 report's "no
Double comparison in proof body".

## Minimal reproducer

`moonbit_doubleML/_verify/audit-bucket2-double/double_cmp.mbt`:

```moonbit
pub fn double_cmp(x : Double, n : Int) -> Bool where {
  proof_require: x < 1.5,
  proof_require: n > 0,
  proof_ensure: result => result == (x < 1.5),
} {
  x < 1.5
}
```

`moon prove _verify/audit-bucket2-double` output (full log:
`moonbit_doubleML/_verify/audit-bucket2-double/prove_v3.log`):

- `unsupported primitive operator in logic body` on `x < 1.5`
  in `proof_require` (2 errors)
- `only Bool, Byte, Int, UInt, Int64, and UInt64 constants are
  supported in logic body` on the `1.5` literal (2 errors)
- `unsupported primitive operator in contracted function body`
  on `x < 1.5` in the body (1 error)
- `only Bool, Byte, Int, UInt, Int64, and UInt64 constants are
  supported in contracted function body` on the `1.5` literal
  (1 error)

Total: 6 errors fire.

**Re-audit, 2026-10-20 — reproduced exactly.** On
`moonc v0.10.16+b1a0e846e`, the same source
(`_verify/upstream_prove_1649/cases/b2_double_cmp/`) produces **6**
`Error: [4207]` diagnostics with the same four-way split: 2x
"unsupported primitive operator in logic body", 2x "only Bool, Byte,
Int, UInt, Int64, and UInt64 constants are supported in logic body",
1x "unsupported primitive operator in contracted function body", 1x
"only ... in contracted function body". Both halves of the restriction
-- the comparison and the literal -- are still in force. Log:
`_verify/upstream_prove_1649/out/b2_double_cmp.log`.

## Confirmation

Pilot 2's `_prove_pilot2/quantile_view.mbt` (a `FixedArray[Double]`
mirror of `quantile.mbt::array_min`) hit this on every `<` in a
`proof_require: v[i] < result` and on `result < v[i]` in a
`proof_ensure`. The kfold pilot did not expose this because its
contracts used `Int` only.

The v0.52.0 main-package contract integration attempt on
`kfold_stratified` did **not** reproduce this on the body (the
contract was Int-only to isolate Bucket 1 / Array lowering) — see
`_verify/UPSTREAM_BLOCKERS.md` reproduction log: "Bucket 2 (Double
comparison): 0 errors — NOT TRIGGERED". This issue is documented
separately because Pilot 2's `quantile_view.mbt` reproducer
remains valid and the gap will fire the moment a numerical contract
on a DML estimator's body is attempted.

## Suggested fix

Either:
- (preferred) extend the proof frontend's primitive-operator
  support to include `Double` comparisons, AND extend the literal
  constant whitelist from `{Bool, Byte, Int, UInt, Int64, UInt64}`
  to also accept `Double`.
- (workaround) require users to compare `Double` values via
  helper predicates defined in `.mbtp` (the helpers would carry
  the comparison logic in a form the prover can reason about).
  This does not solve the literal-rejection problem; users would
  need to re-introduce the `Double` value as a function parameter.

## Impact

All numerical contracts are blocked. Without this fix,
moonbit_doubleML's 22 estimators (which all compute on `Double`
arrays) cannot be verified, even with Issue 1 (Array lowering)
resolved.

## Pilot artifacts

All paths are under the current project root
`moonbit_doubleML/` (project was renamed from `dml-moonbit` in
commit `5d79625`).

- `_verify/audit-bucket2-double/double_cmp.mbt` — minimal
  reproducer (6-error confirmation).
- `_verify/audit-bucket2-double/prove_v3.log` — full log.

  **Both are local-only and git-ignored** — the directory was never
  committed, so a reader cannot obtain them. The 2026-10-20 re-audit
  re-measures the same restriction from a tracked, self-contained case
  (`_verify/upstream_prove_1649/cases/b2_double_cmp/`) instead.
- `_prove_pilot2/quantile_view.mbt` — Pilot 2 Double mirror, hit
  the comparison restriction.
- `QUANTILE_HANDOFF.md` — Pilot 2 full narrative. (At the repository root,
  not under `_verify/`; tracked there since before `v0.52.0`.)
- `_verify/UPSTREAM_BLOCKERS.md` — the 6-blocker + reproduction
  log + audit (master document).

## Status as of v0.52.0 release (2026-09-19)

v0.52.0 shipped with all 22 DML estimators working (4 backends ×
331/331 tests PASS, 11 fuzz 0 violations, 23/23 Python validators
PASS) but **without any of the 6 upstream blockers resolved** —
production code does not use formal contracts; numerical
preconditions in DML estimators are enforced at runtime via
`require(...)` calls and the v0.48.0 cascade wrap. This issue
remains the gate for any future attempt to add proof contracts to
`LPQ::new` (which validates `quantile ∈ (0, 1)` against `Double`)
or `LinearRegression::fit` (which validates `n_features >= 1`
against `Int` and would need a Double sibling for ridge parameter
bounds).

These 6 drafts are ready for filing upstream against
<https://github.com/moonbitlang/core> (or the equivalent
`moonbitlang/moon` proof-frontend repo, depending on how the
toolchain project is organized).

## Acknowledgements

The moonbit_doubleML project is a pure-MoonBit port of
<https://github.com/DoubleML/doubleml-for-py>. The 22 estimators
covered in moonbit_doubleML v0.52.0 are the test surface for these
restrictions.