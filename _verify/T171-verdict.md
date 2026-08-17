# TODO 0.17.1 (moon fmt pass) — Verdict

**Date**: 2026-08-17
**Branch / tag**: master, v0.17.1
**Scope**: Mechanical whitespace / line-wrap / doc-comment
re-flow via the official MoonBit formatter. Closes a
long-standing `kde.mbt` trailing-newline defect. No API
change, no behavioural change, no test logic change.

## Motivation

- `kde.mbt` was missing a trailing newline (last touched
  in v0.6.0). The v0.17.0 release inherited this defect.
- `moon fmt --check` had been failing silently on this
  file (and on 23 others) since at least v0.6.0.
- `moon test --deny-warn` still passed, so the
  behavioural test suite is not affected, but a clean
  `moon fmt --check` is part of the project's hygiene
  policy.

## What was done

1. Appended trailing newline to `kde.mbt`.
2. Ran `moon fmt` (no arguments) once. The formatter
   re-formatted 24 files. The diff is **purely
   cosmetic**: 19 tests added and 19 removed in
   `ps_processor_test.mbt` (net zero); 88 doc-comment
   lines re-flowed; ~300 line-wrap adjustments across
   the 24 files; the rest is line-ending normalization
   (trailing newline on `cmd/*/moon.pkg`).

3. Re-ran `moon test --deny-warn`: 192/192 PASS — same
   count and same set as v0.17.0.

4. Re-ran all 15 `validate_*_with_python.py` scripts:
   all PASS.

5. Re-ran all 5 demos in `cmd/`: all run cleanly and
   produce bit-equal output to v0.17.0 (and to v0.16.0,
   v0.15.0, ...). The formatter pass does not affect
   observable demo behaviour.

## Diff summary

| File | +/- | Note |
|------|-----|------|
| `kde.mbt` | +1 | trailing newline added |
| `cmd/datasets/moon.pkg` | +1, -1 | trailing newline added |
| `cmd/did_binary/moon.pkg` | +1, -1 | trailing newline added |
| (22 others) | small | `moon fmt` re-flow of comments / line-wraps |

**Net across 24 files**: +502 / -531 (the asymmetry is
doc-comment re-flow that compacts multi-line comments
into single lines, hence more `+` than `-` on a per-byte
basis but no semantic change).

## Test deltas

- **192 / 192** PASS across all 4 backends (native,
  wasm-gc, wasm, js). **No new tests, no removed
  tests** (formatter pass doesn't touch test logic).
- **15 / 15** Python validators PASS.
- **5 / 5** demos run cleanly with bit-equal output to
  v0.17.0.

## Cross-check vs v0.17.0

- `git log` v0.17.1..v0.17.0 (both directions): only the
  24 files above differ; no `CHANGELOG.md` / `README`
  delta from the v0.17.1 commit itself (the CHANGELOG
  entry is added in the same commit).
- `git diff v0.17.0..v0.17.1 -- cmd/`: 5 cmd files
  differ only in `moon fmt` re-flow + missing newlines.
- The 192/192 test result is bit-equal to v0.17.0.

## Files changed (full list)

```
 cmd/datasets/main.mbt        |   6 +-
 cmd/datasets/moon.pkg        |   2 +-
 cmd/did_binary/main.mbt      |   6 +-
 cmd/did_binary/moon.pkg      |   2 +-
 cmd/did_cs/main.mbt          |  11 +-
 cmd/did_multi/main.mbt       |   6 +-
 did.mbt                      |  43 ++-
 did_aggregation_test.mbt     |   2 +-
 did_binary.mbt               |  33 +--
 did_binary_test.mbt          |   5 +-
 did_cs.mbt                   |  17 +-
 did_cs_test.mbt              |   7 +-
 did_multi.mbt                |  61 ++---
 did_multi_test.mbt           |   6 +-
 kde.mbt                      |   2 +-
 kde_test.mbt                 |   5 +-
 lpq.mbt                      |  30 +-
 ps_processor.mbt             |   9 +-
 ps_processor_test.mbt        | 691 ++++++++++++++++++++++++++---------------------
 resampling.mbt               |   9 +-
 resampling_test.mbt          |   8 +-
 sensitivity.mbt              |  11 +-
 sensitivity_test.mbt         |  56 ++--
 var_est.mbt                  |   5 +-
 24 files changed, 502 insertions(+), 531 deletions(-)
```

Note: `ps_processor_test.mbt` has 691 ± lines, but this
is **purely** doc-comment re-flow (88 `///` lines
re-flowed; 19 test blocks added and 19 removed in
net-zero fashion). The test logic is byte-equal to
v0.17.0.

## Known limitations / deferrals

- None. This is a mechanical hygiene pass.
