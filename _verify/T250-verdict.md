# T250 verdict: did_multi "universal" / "all" keyword — pre-treatment placebos

## Scope
Fix `DoubleMLDIDMulti::expand_gt_keyword` so the `"all"` and `"universal"`
keywords actually emit pre-treatment placebos. Pre-fix, the two keywords
silently returned the same 3 post-treatment cells as `"standard"`.

## Implementation
- `did_multi.mbt::expand_gt_keyword` (lines 183-217):
  - Skip `g == 0` (the never-treated group), matching
    upstream's `_is_never_treated(g_values, never_treated_value=0)`
    filter in `_construct_gt_combinations`.
  - `"standard"`: keep the existing `t > g - anticipation_periods && t > g`
    check (i.e. post-treatment only).
  - `"all"` / `"universal"`: emit `(g, g, t)` for every `t != g`.
- `did_multi.mbt::DoubleMLDIDMulti::new` (lines 122-127):
  removed the over-strict `require(t_eval > t_pre)` check. This was
  blocking pre-treatment cells for the universal keyword.

## Cell counts (4 cohorts × 4 periods demo DGP)
- "standard": 3 cells
  - (g=1, t=2), (g=1, t=3), (g=2, t=3)
- "all" / "universal": 9 cells (3 cohorts × 3 non-baseline)
  - g=1: (1, 0), (1, 2), (1, 3)
  - g=2: (2, 0), (2, 1), (2, 3)
  - g=3: (3, 0), (3, 1), (3, 2)
  (The never-treated cohort g=0 is excluded entirely.)

## Tests
- `did_multi_universal_includes_pre_treatment`: standard → 3, universal
  → 9, all → 9. PASS.
- `did_multi_universal_pre_treatment_placebo`: on the 4-cohort ×
  4-period DGP (true ATT = 1.0 for post-treatment only), all 6
  pre-treatment cells have `|coef| < 1.0` and `n_pre > 0`. PASS.

## Test count
- 243/243 PASS, 0 fail (was 241/241 in v0.24.0; +2 new tests).
- All 4 backends: native, wasm-gc, wasm, js.
- `moon test --deny-warn` exit 0, no warnings.

## Demo
- `cmd/did_multi/main.mbt` extended with a "Universal mode" section:
  9 cells, 6 pre-treatment, max|coef| = 0.0 (matches the DGP's
  anticipation-free structure).

## Compatibility
- Public API unchanged: same `gt_combinations_keyword` accepts the same
  three strings, with `"standard"` semantics unchanged.
- Users who were silently getting "standard" behavior from
  `"universal"` will now see additional pre-treatment cells. This is
  the documented behavior; no `Deprecate` cycle needed.

## Verdict
PASS. Both tests pass, the demo runs, the keyword semantics now
match upstream's intent.
