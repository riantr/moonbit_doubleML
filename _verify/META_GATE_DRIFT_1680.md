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
