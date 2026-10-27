# Upstream proof restrictions: a re-audit on the toolchain of 2026-10-20

> **Status: re-audited 2026-10-20 on `moon 0.1.20261016 (1af328f 2026-10-16)` /
> `moonc v0.10.16+b1a0e846e (2026-10-16)`.** The 4 + 2 restrictions in
> `_verify/UPSTREAM_BLOCKERS.md` were last *observed* in September 2026 on
> `moonc v0.10.11` / `v0.10.12`. The toolchain this re-audit ran on is five
> patch releases after `v0.10.11`. Everything below refers to **the audited
> toolchain** -- `moon 0.1.20261016` / `moonc v0.10.16` -- and to no other: a
> newer toolchain may do something else. This directory records what the
> audited toolchain does with the same constructs.
>
> **What is measured here, and what is not.** Each case is run through the
> proof **frontend**, which lowers the contract and rejects it before Why3 is
> involved. A rejection is therefore a real, platform-independent result. The
> **proof outcome** -- whether an accepted contract actually proves -- is *not*
> measured here, because `moon prove` cannot complete its Why3 stage on native
> Windows (see "Platform limitation" below). Every claim below is of the form
> "the frontend accepts / rejects this construct".

## Why this exists

The upstream records were written against a September 2026 toolchain and
present their conclusions in the present tense, with no statement that they had
not been re-checked. The records also cite commands that no longer run: the
package layout changed (the package moved from the repository root into
`moonbit_doubleML/`), so the records' `moon prove _prove_pilot` now fails with

> `Error: Cannot find package to build based on input path ... is not inside
> any known module.`

measured 2026-10-20 on the audited toolchain.

## The cases

Each case is a **self-contained MoonBit package** under `cases/<name>/` with
its own `moon.mod` and a `moon.pkg` carrying `options("proof-enabled": true)`,
so `moon prove` can reach it in today's layout.

| case | construct under test | the record it checks |
|---|---|---|
| `b0_control` | nothing restricted | the harness itself |
| `b1c_fixed_control` | `FixedArray` + C-style range | the `_prove_pilot` workaround shape |
| `b1_array_param` | `Array[T]` in a contracted function parameter | Blocker 1 |
| `b1_array_field` | `Array[T]` in a struct field | Blocker 1 |
| `b2_double_cmp` | `Double` comparison **and** `Double` literal | Blocker 2 + finding A2 |
| `b3_raise_body` | `raise X` in a contracted body | Blocker 3 + finding A3 |
| `b4_foreach` | `for x in arr` in a contracted body | Blocker 4 + finding A4 |
| `b4c_style_control` | C-style range over `Array[T]` | Blocker 4's "workaround" |
| `b4r_range_foreach` | `for x in 0..<n` | Blocker 4's range-form claim |
| `blkA_call_whitelist` | a call that is not `#proof_pure` | New Block A |
| `blkB_block_expr` | `try { ... } catch { ... }` in a contracted body | New Block B |

### Why there are two controls

A control case is what makes a failure attributable. Without one, "every case
failed" is an indistinguishable answer: a platform failure and a proof
rejection look the same to the exit code.

`b0_control` uses no restricted construct at all. `b1c_fixed_control` uses
`FixedArray` with a C-style range -- the shape `_prove_pilot` actually uses --
so that the two `Array[T]` cases can be shown to fail *because of `Array[T]`*
and not because of the harness.

Both controls are **accepted by the proof frontend** (zero `Error: [4207]`),
which is what makes every rejection below attributable.

## How to run it

```
cd _verify/upstream_prove_1649
python run_reaudit.py          # runs `moon prove` in every case, writes out/<case>.log
python summarise.py            # per-case: which stage it reached, and which diagnostics
```

`run_reaudit.py` exits non-zero if the control case is neither accepted nor
rejected, because a run in which the harness is not classifying is void.

The raw logs are in `out/`. They contain absolute paths from the machine that
produced them.

## Results, measured 2026-10-20

`moon 0.1.20261016 (1af328f 2026-10-16)` / `moonc v0.10.16+b1a0e846e (2026-10-16)`.

| case | frontend errors | diagnostics |
|---|---:|---|
| `b0_control` | 0 | accepted |
| `b1c_fixed_control` | 0 | accepted |
| `b1_array_param` | 3 | 1x "unsupported primitive operator in logic body"; 2x "unsupported primitive operator in contracted function body" |
| `b1_array_field` | 3 | 1x "... in logic body"; 2x "... in contracted function body" |
| `b2_double_cmp` | 6 | 2x "unsupported primitive operator in logic body"; 2x "only Bool, Byte, Int, UInt, Int64, and UInt64 constants are supported in logic body"; 1x "unsupported primitive operator in contracted function body"; 1x "only ... in contracted function body" |
| `b3_raise_body` | 1 | "unsupported expression in contracted function body" |
| `b4_foreach` | 2 | 1x "unsupported primitive operator in logic body"; 1x "only single-binder I32 range foreach loops are supported in contracted function bodies" |
| `b4c_style_control` | 3 | 1x "... in logic body"; 2x "... in contracted function body" (all on `arr.length()` / `arr[i]`) |
| `b4r_range_foreach` | 0 | accepted |
| `blkA_call_whitelist` | 1 | "only contracted functions, imported proof-callable functions, pure functions, and primitive operators can be called in contracted function bodies" |
| `blkB_block_expr` | 1 | "unsupported expression in contracted function body" |

## What changed against the September 2026 record

**Unchanged -- the restriction still fires.**

- **Blocker 1** (`Array[T]`). Fires on both the parameter shape and the struct
  field shape, with the same error class the record's own categorisation
  attributes to Bucket 1 ("unsupported primitive operator", 1 logic + 2 body
  per isolated case). The record's *symptom* text -- that the Why3 preamble
  lacks `use array.Array` and Why3 then reports `unbound type symbol 'array'`
  -- is **not** what the audited toolchain reports; it reports "unsupported
  primitive operator".
- **Blocker 2** (`Double`). **Reproduced exactly**: 6 errors, with the same
  four-way split the record gives (2x comparison in logic, 2x literal in
  logic, 1x comparison in body, 1x literal in body).
- **New Block A** (call whitelist). Fires with a byte-identical message.
- **New Block B** (block expressions). Fires.

**Changed -- the September record is now out of date.**

- **Finding A3 is obsolete.** The record says a `raise` in a contracted body
  makes `moonc prove` die with the help-text error
  `moonc prove [options] <input files>`, so "a user will not see a clean
  diagnostic". The audited toolchain reports a clean, specific
  `unsupported expression in contracted function body`.
- **Finding A4 is obsolete**, and the diagnostic is now *more* informative than
  anything the record contains: `only single-binder I32 range foreach loops
  are supported in contracted function bodies`.
- **The `for x in 0..<n` claim is now false.** The record says the same
  help-text error fires for the single-binder Int range form. The audited
  toolchain **accepts** it: `b4r_range_foreach` has zero frontend errors.
- **Issue 4's "Workaround (verified)" no longer holds as written.** Its
  snippet is the C-style range over `Array[Int]`, and it is claimed to
  "compile and prove (no errors)". The audited toolchain reports 3 frontend
  errors on that exact shape (`b4c_style_control`) -- all of them Blocker 1,
  on `arr.length()` and `arr[i]`. The C-style rewrite fixes the *foreach*; it
  does not fix the `Array[T]` lowering. The shape that the frontend accepts is
  `FixedArray` + C-style range (`b1c_fixed_control`), which is what
  `_prove_pilot` uses.

**Confirmed.**

- The `FixedArray` + C-style workaround shape is **accepted** by the audited
  proof frontend, which is the premise the `_prove_pilot` package rests on.

## Platform limitation

`moon prove` cannot complete its Why3 stage on native Windows: the harness
fails to create its output directory under the `\\?\` extended-length path
prefix.

```
anomaly: Unix.Unix_error(Unix.EINVAL, "mkdir", "\\?")
```

This is why `run_reaudit.py` classifies the control `PLATFORM_ERROR` rather
than `PROVED`: the frontend accepted the contract, and the run then died in
a later stage. The label is the runner's, not the log's -- `out/b0_control.log`
holds the raw evidence. The same limitation is recorded independently in
`_prove_pilot/moon.pkg`.

Because the rejection happens in the frontend, **before** the Why3 stage, a
rejection is still a real result on this platform. A *proof* is not
observable here. Re-run on a platform where `moon prove` can create its
output directory to observe the proof outcome itself.
