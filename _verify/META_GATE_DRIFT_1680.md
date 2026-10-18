# The validator meta-gate is RED, and no CI workflow runs it

Measured at `7d5ef8a` on 2026-10-18. This is a finding about the verification
apparatus, not about any example's numbers -- every example number passes.
Filed here rather than in `LPLR_GATE_BLINDNESS_1680.md` because that file is
about LPLR and this is not.

## The headline

`_verify/run_pycross_ci_equiv.ps1` mirrors the CI job
`Run every validate_*_with_python.py script` (`check.yml:109`) exactly,
including its case-sensitive verdict glob. Result:

```
SUMMARY (CI-equivalent, case-sensitive): 24 pass, 0 fail
  FAIL validate_suite_meta.py (validator classification drifted)
```

**All 24 cross-validators pass.** So every example result matches upstream on
this commit, by CI's own definition of that comparison.

The single failure is `validate_suite_meta.py` -- and **it matches no CI glob
and runs in no workflow.** Its name is `validate_suite_meta.py`, not
`validate_*_with_python.py`, so the loop in `check.yml:114` skips it, and no
step invokes it. CI is green while this gate is red, and has been for however
long the drift below accumulated.

`validate_plotting_scope.py` is in the same position: no glob, no workflow,
invoked only from `_verify/` scratch.

## The 13 problems, classified

Run `python validate_suite_meta.py` to reproduce. Verbatim, grouped:

> **SUPERSEDED — this section is the original classification and it was wrong on
> two of four groups.** Measured outcome: **13 problems -> 2.** Groups A and D
> are not what they are described as here; both are fixed, and the fixes were in
> the DETECTOR, not in the validators. Groups B and C collapse into one open
> question. See "Corrections" at the foot of this file for the measurements.

### A. Mechanical, unambiguous -- the gate is telling you to do this

Six entries on `KNOWN_HARDCODED_VERDICT` no longer describe anything:

```
validate_blp_policy_with_python.py:  on KNOWN_HARDCODED_VERDICT but no longer
validate_bootstrap_with_python.py:   prints a hard-coded verdict -- remove it
validate_cv_repeated_with_python.py: from the list (that is good news)
validate_gain_statistics_with_python.py:
validate_padjust_with_python.py:
validate_quantile_with_python.py:
```

The module docstring says "Eight reference-only validators still print a
literal `PASS`". The detector finds **one** typed verdict now. The list is
stale, not the files. Deleting the six entries is what the gate asks for.

### B. A validator was added and never registered

```
validate_bitexact_with_python.py: on disk but missing from the expectation table
```

The table is documented as holding "every one of the 23 files"; there are 24
on disk. Its own row in the detector output says `moon: yes, verdict: ok,
typed: -, exit: yes` -- it spawns `moon` and computes its verdict, so it is a
GATE and belongs on `MUST_READ_MOONBIT`. The same run also reports
`MUST_NOT_READ_MOONBIT but spawns moon` for it, which is contradictory and
suggests the membership lookup is not doing what the message implies.

### C. Seven files cannot be shown to emit the verdict CI greps for

```
validate_cvar_with_python.py:           no string mentions both PASS and FAIL
validate_did_binary_with_python.py:
validate_did_cs_with_python.py:
```

so the gate cannot prove they are fail-closed. **All three DO emit a
`PASS`-containing last line** in the CI-equivalent run above, so this is the
gate failing to prove a property, not a demonstrated defect. Each needs
reading before it is classified either way.

### D. One real weak gate

```
validate_pava_with_python.py: gate file prints a hard-coded '...PASS' literal;
its verdict must be computed
```

`validate_pava_with_python.py` reads MoonBit (it is on `MUST_READ_MOONBIT`)
and therefore its verdict is one CI greps to decide red or green -- but that
verdict is a typed literal, so it would report PASS whatever the comparison
did. Its detector row agrees: `moon: yes, verdict: ok, typed: YES`. This is
the one item on the list that is a substantive defect in a validator rather
than staleness in the meta-gate.

## Why it was not fixed in the same commit that found it

Three of the four groups need a judgement call that is not mine to make
silently:

- Is `validate_bitexact_with_python.py` a gate? (The detector says yes; the
  expectation table does not list it at all.)
- Are the seven "cannot be shown fail-closed" files genuinely fail-closed?
  Three of them demonstrably print PASS; proving they go red needs reading.
- Is `validate_pava_with_python.py`'s hard-coded verdict acceptable, or does
  the comparison it claims to make need to actually gate?

And wiring the meta-gate into CI while it is RED would break every release,
which is exactly why it was left out in the first place. The ordering that
works is: clear the staleness, settle the judgement calls, then wire it in.

## Apply when

- Any CI run of `check.yml` reports green and `validate_suite_meta.py` is red.
  Both are true today and are not in conflict.
- Before trusting "the cross-validators all pass" as complete, note that this
  job covers the 24 `validate_*_with_python.py` scripts and nothing else. The
  QA loop's fast scope covers a different, mostly disjoint set (the 9
  `pyexample_*` gates). Neither set runs the meta-gate.

---

## Corrections (measured) — 13 problems down to 2

The classification above is superseded on groups A, C and D. The fixes were in
the **detector**, not in the validators, and the two surviving problems are one
question with two contradictory statements about the same file.

### 1. Group A was NOT mechanical, and following the gate's advice changes nothing

The gate says "on `KNOWN_HARDCODED_VERDICT` but no longer prints a hard-coded
verdict -- remove it from the list (that is good news)". Removing the entries is
the obvious reading, so it was measured rather than assumed:

```
before            13 problems
entries emptied   12 problems, still FAIL
```

**It does not work, and the reason is structural.** The 7 stale entries were also
*exempting* those files from the neighbouring "no string mentions both PASS and
FAIL" check, so each removal traded one problem for another. For a file that
neither computes a verdict nor types one, the two checks are mutually exclusive:
exempt it and it is stale, drop it and it cannot emit. A count that barely moves
is the tell that the diagnosis was wrong, not that the edit was too small.

The real cause: **all ten reference-only validators emit their verdict through
`parity_helper.report(title, rows, ok)`.** Both detector heuristics are
single-file AST scans, so neither can see a delegation:

* `emits_computed_verdict` wants a `PASS` literal and a `FAIL` literal in the
  file. Ten files have neither — the strings live in the helper.
* `has_hard_coded_pass` wants a `print()` whose first argument is a literal
  ending in `PASS`. Same blind spot.

`KNOWN_HARDCODED_VERDICT` was a hand-maintained exemption for exactly that blind
spot, and it went stale the moment those files were refactored onto the helper.
Fixed by teaching `emits_computed_verdict` to recognise the delegation
(`delegates_verdict_to_helper`: imports `parity_helper` **and** calls
`.report(...)`), which is *checked* where the exemption was a standing
assertion nobody ever verified. 13 -> 3.

The delegation was confirmed not to weaken anything. All ten call
`return ph.report(...)`, so the helper's exit code propagates — a validator
that called it and discarded the return would print a verdict and always exit 0.
And the helper is genuinely fail-closed on both paths that matter: `if not rows`
prints `FAIL: ... no rows were compared` and returns 1, and the verdict is
`return 0 if verdict == "PASS" else 1` with `bad` taken from each row's own
`good` flag rather than from the `ok` the caller passes. All ten pass `ok=True`
literally, which is safe precisely because `rows[i][3]` carries the comparison.

### 2. Group D was a FALSE POSITIVE — the gate flagged a row, not a verdict

`validate_pava_with_python.py` was reported as "prints a hard-coded '...PASS'
literal; its verdict must be computed". It computes its verdict. Which lines the
detector actually matched:

```
has_hard_coded_pass() matches exactly one line:
   294   '  accepts the true optimum                            -> PASS'
the real verdict, line 415:
   "PAVA cross-check " + ("PASS" if ok_all else "FAIL")   -> BinOp, skipped
```

Line 294 is one row of an oracle self-test, and pava reports a status line per
case by design. The rule could not tell a *row* from *the verdict*, because it
matched "any `print()` whose first argument is a literal ending in `PASS`" — while
its own docstring's concern is that **the verdict** was typed. The loop-based
rule that would have worked instead ("ignore prints inside a loop") does not
apply: 294 is in an `if`/`else` at function level, not a loop.

Fixed by scoping the rule to the verdict: a bare `PASS` literal counts as the
verdict only when the file emits no computed PASS/FAIL verdict of its own.

**Control arm, five fixtures, all as specified** — the rule narrowed, it did not
go vacuous:

| fixture | `has_hard_coded_pass` |
|---|---|
| hard-coded verdict only | **True** (still flagged) |
| computed verdict | False |
| pava's shape: literal row + computed verdict | False |
| delegates to `parity_helper` | False |
| delegates *and* has a literal PASS row | False |

`known typed verdicts` is now **0**, and 3 -> 2.

### 3. A latent crash in the gate, found by following its own advice

`KNOWN_HARDCODED_VERDICT = {}` — the obvious way to "remove it from the list" —
is a **dict** in Python, not an empty set, and the gate then dies on its own
arithmetic:

```
TypeError: unsupported operand type(s) for -: 'dict' and 'set'
```

It is now `set()`, with the reason recorded inline. Anyone following the gate's
printed instruction hit a crash rather than a clean "nothing to do".

### 4. Groups B and C are one question, and it is not mechanical

Both surviving problems are `validate_bitexact_with_python.py`:

```
on disk but missing from the expectation table
MUST_NOT_READ_MOONBIT but spawns `moon`; either wire it up or move it off the list
```

The file spawns `moon` and computes a fail-closed verdict (the detector's own row
reads `moon: yes, verdict: ok, exit: yes`), which makes it a GATE — so it belongs
on `MUST_READ_MOONBIT`. It is currently classified reference-only. The two
statements contradict, and only a human can say which is intended:

* it **is** a gate -> move it to `MUST_READ_MOONBIT`; both problems go at once.
* it **is** reference-only -> then its `subprocess` call to `moon` is
  unintentional and should be removed, which is a code change, not a table edit.

That is the whole remaining decision, and it is why this gate is at 2 and not 0.
Note the stale count on record too: group A was written as **six** entries and
has since become **seven**, `validate_rdd_with_python.py` having been converted
in the interim. A classification list that drifts is a classification list that
needs re-measuring, not re-reading.
