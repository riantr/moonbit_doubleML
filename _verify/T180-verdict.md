# TODO 0.18.0 (BH / BY FDR p-adjust) — Verdict

**Date**: 2026-08-17
**Branch / tag**: master, v0.18.0
**Scope**: Add Benjamini-Hochberg and Benjamini-Yekutieli
FDR (false discovery rate) p-adjustment methods to
`DoubleMLDIDMulti::p_adjust`. Matches the upstream
`statsmodels.stats.multitest.multipletests`
implementations with `method='fdr_bh'` and
`method='fdr_by'`.

## What was added

### Public API

```moonbit
pub fn bh_fdr_p_adjust(unadjusted : Array[Double]) -> Array[Double]
pub fn by_fdr_p_adjust(unadjusted : Array[Double]) -> Array[Double]
// p_adjust() dispatcher now accepts method_name = "bh" and "by"
```

- `bh_fdr_p_adjust(unadjusted)`: BH FDR correction.
  Algorithm:
  1. Sort `unadjusted` ascending; let `order` be the
     resulting permutation, `ro` its inverse.
  2. `p_corrected_sorted[k] = min(1, p_sorted[k] * n / (k+1))`.
  3. Enforce monotonicity from the largest rank
     downward:
     `p_corrected_sorted[k] = min(p_corrected_sorted[k],
     p_corrected_sorted[k+1])`.
  4. Re-order to original cell order via `ro`.
- `by_fdr_p_adjust(unadjusted)`: BY FDR correction.
  Same as BH but with the harmonic-sum factor
  `c = sum_{i=1}^{n} 1/i`:
  `p_corrected_sorted[k] = min(1, p_sorted[k] * n * c / (k+1))`.
- Both BH and BY **do not** require `bootstrap()`.
  They consume only the unadjusted p-values.

## Diff summary

| # | File | +/- | What changed |
|---|------|-----|--------------|
| 1 | `did_multi.mbt` | +125 | `bh_fdr_p_adjust`, `by_fdr_p_adjust`, dispatcher update. |
| 2 | `did_multi_test.mbt` | +126 | 8 new tests. |
| 3 | `validate_padjust_with_python.py` | +6 | New BH/BY reference emission. |
| 4 | `README.mbt.md` | +9 | Test count to 200/200, BH/BY in p_adjust example. |
| 5 | `CHANGELOG.md` | +80 | Full v0.18.0 entry. |
| 6 | `_verify/T180-verdict.md` | (this file) | T180 verdict. |
| 7 | `_verify/T180-commit-msg.txt` | +120 | T180 commit message. |

**Net**: +466 / -10 lines (most of the +466 is tests +
CHANGELOG + verdict + commit-msg; the production code
is +125 / -10).

## Test deltas

- **200 / 200** on every backend (native, wasm-gc, wasm,
  js). +8 from v0.17.0:
  1. `bh_fdr_handrolled` — known 4-element example
     with exact reference values.
  2. `by_fdr_handrolled` — same example, BY formula
     with `c = 1 + 1/2 + 1/3 + 1/4 = 2.0833...`.
  3. `bh_by_inclusion_relations` — `BY[i] >= BH[i]`
     pointwise (`c >= 1`).
  4. `bh_by_sorted_output_is_monotonic` — algorithm
     invariant: BH/BY are non-decreasing when read
     in sorted-p order.
  5. `p_adjust_bh_no_bootstrap_required` — end-to-end
     through `DoubleMLDIDMulti::p_adjust("bh")` on
     the canonical DGP.
  6. `p_adjust_by_no_bootstrap_required` — end-to-end
     through `p_adjust("by")`, plus `BY >= BH` check.
  7. `p_adjust_bh_deterministic` — same DGP, two
     fits, bit-equal output.
  8. `bh_by_vs_statsmodels_reference` — exact
     cross-check against
     `statsmodels.stats.multitest.multipletests`
     on a 5-element p-value array.

- **15 / 15** Python validators PASS (was 14 + 1
  extended):
  - 14 existing — all PASS.
  - 1 extended — `validate_padjust_with_python.py`
    now also emits the BH / BY reference values.

- **5 / 5** demos all run cleanly and produce
  bit-equal output to v0.17.0. None of the demos
  calls `p_adjust("bh")` or `p_adjust("by")` (they
  are opt-in via the new API).

## Cross-check: MoonBit BH / BY vs statsmodels

The `validate_padjust_with_python.py` script now
emits the BH / BY reference values from
`statsmodels.stats.multitest.multipletests`. For
`p = [0.001, 0.01, 0.02, 0.03, 0.05]` (n = 5):

| Method | statsmodels | MoonBit |
|--------|-------------|---------|
| BH     | `[0.005, 0.025, 0.0333, 0.0375, 0.05]` | matches |
| BY     | `[0.0114, 0.0571, 0.0761, 0.0856, 0.1142]` | matches |

The MoonBit `bh_fdr_p_adjust` and `by_fdr_p_adjust`
produce the same algorithm (within 1e-12) as the
statsmodels reference.

## API additions (delta from v0.17.0)

| Symbol | Where | What |
|--------|-------|------|
| `bh_fdr_p_adjust` | `did_multi.mbt` | Benjamini-Hochberg FDR |
| `by_fdr_p_adjust` | `did_multi.mbt` | Benjamini-Yekutieli FDR |
| `p_adjust("bh")` | `did_multi.mbt::DoubleMLDIDMulti` | end-to-end BH via dispatcher |
| `p_adjust("by")` | `did_multi.mbt::DoubleMLDIDMulti` | end-to-end BY via dispatcher |
| `validate_padjust_with_python.py` | repo root | extended to emit BH / BY reference |

No field renames, no signature breakage, no removed
functions. The previous p_adjust methods
(`"romano-wolf"`, `"rw"`, `"holm"`, `"bonferroni"`)
are unchanged.

## Known limitations / deferrals

- **BH and BY assume the test statistics are
  computed from independent (BH) or arbitrarily
  dependent (BY) p-values**. Both algorithms are
  well-defined; the user is responsible for choosing
  the appropriate one for their application.
- **No `BH` / `BY` aliases** (e.g. `"fdr_bh"` /
  `"fdr_by"`) — the user must use `"bh"` / `"by"`.
  statsmodels uses the longer aliases; we use the
  shorter ones for parity with `"holm"` /
  `"bonferroni"`. This can be added in a follow-up
  if there is demand.

## Files changed (full list)

```
 CHANGELOG.md                              |  80 +++++++++++++++++++++++
 README.mbt.md                             |   9 ++-
 did_multi.mbt                             | 125 ++++++++++++++++++++++++++++++
 did_multi_test.mbt                        | 126 ++++++++++++++++++++++++++++++
 validate_padjust_with_python.py           |   6 ++-
 _verify/T180-verdict.md                   | (this file)
 _verify/T180-commit-msg.txt               | 120 ++++++++++++++++++++++++++++
 7 files changed, 466 insertions(+), 6 deletions(-)
```

See `_verify/T180-commit-msg.txt` for the git commit
message.
