# TODO 0.24.0 (tsbh / tsby / fdr_bh / fdr_by) — Verdict

**Date**: 2026-08-23
**Branch / tag**: master, v0.24.0
**Scope**: Add two-stage Benjamini-Hochberg (TSBH)
and two-stage Benjamini-Yekutieli (TSBY) FDR
corrections to the `p_adjust` dispatcher, plus
long-name aliases (`fdr_bh`, `fdr_by`, `fdr_tsbh`,
`fdr_tsbky`) that match the `statsmodels` convention.

## Motivation

The v0.18.0 release shipped BH and BY corrections.
These are useful but conservative when a
non-trivial fraction of hypotheses are truly
non-null. The v0.24.0 release adds the
two-stage variants (Storey 2002 / BH-BKY 2006)
that estimate the number of true nulls and use
that to sharpen the correction.

## What was added

### Public API (delta from v0.23.0)

```moonbit
// New functions
pub fn tsbh_p_adjust(unadjusted : Array[Double]) -> Array[Double]
pub fn tsby_p_adjust(unadjusted : Array[Double]) -> Array[Double>

// Extended p_adjust dispatcher (now 12 method_names)
pub fn DoubleMLDIDMulti::p_adjust(
  self : DoubleMLDIDMulti,
  method_name? : String = "romano-wolf",
) -> Array[Double>
```

### Algorithm

For `tsbh_p_adjust(unadjusted)`:
1. Apply standard BH:
   `p_bh_sorted[k] = min(1, p_sorted[k] * m / (k+1))`.
2. Estimate `m0_hat = #{unadjusted > alpha} / (1 -
   alpha)` (clamped to `[1, m]`).
3. Apply correction:
   `p_adj_sorted[k] = min(1, p_bh_sorted[k] * m0_hat / m)`.
4. Enforce monotonicity + reorder.

For `tsby_p_adjust(unadjusted)`: same as TSBH
but with the BY `c` factor in step 1:
`p_by_sorted[k] = min(1, p_sorted[k] * m * c / (k+1))`.

## Diff summary

| # | File | +/- | What changed |
|---|------|-----|--------------|
| 1 | `did_multi.mbt` | +150 | `tsbh_p_adjust`, `tsby_p_adjust`, dispatcher aliases. |
| 2 | `did_multi_test.mbt` | +110 | 6 new tests. |
| 3 | `validate_padjust_with_python.py` | +10 | TSBH / TSBY reference emission. |
| 4 | `README.mbt.md` | +12 | Test count to 241/241, new example. |
| 5 | `CHANGELOG.md` | +90 | Full v0.24.0 entry. |
| 6 | `_verify/T240-verdict.md` | (this file) | T240 verdict. |
| 7 | `_verify/T240-commit-msg.txt` | +90 | T240 commit message. |

**Net**: +462 / -10 lines (most of the +462 is
tests + CHANGELOG + verdict + commit-msg; the
production code is +150 / -10).

## Test deltas

- **241 / 241** on every backend (native, wasm-gc,
  wasm, js). +6 from v0.23.0:
  1. `tsbh_p_adjust_handrolled` — TSBH is
     pointwise <= BH.
  2. `tsby_p_adjust_handrolled` — TSBY is
     pointwise >= TSBH and pointwise <= BY.
  3. `p_adjust_fdr_bh_alias` — `p_adjust("fdr_bh")`
     produces the same output as `p_adjust("bh")`.
  4. `p_adjust_fdr_by_alias` — `p_adjust("fdr_by")`
     produces the same output as `p_adjust("by")`.
  5. `p_adjust_tsbh_no_bootstrap_required` —
     `p_adjust("tsbh")` works without `bootstrap()`.
  6. `p_adjust_tsby_no_bootstrap_required` —
     `p_adjust("tsby")` works without `bootstrap()`.

- **16 / 16** Python validators PASS (the
  `validate_padjust_with_python.py` script now
  also emits the TSBH / TSBY reference values).

- **6 / 6** demos all run cleanly and produce
  bit-equal output to v0.23.0.

## Cross-check: MoonBit vs statsmodels

For 5 p-values from a t-statistic sample
(`abs_t = [3.09, 4.93, 3.44, 2.92, 4.18]`):
- TSBH = `[0.0025, 0, 0.001, 0.0035, 0.0001]` (matches
  `statsmodels multipletests(method='fdr_tsbh')`
  within 1e-12)
- TSBY = `[0.0027, 0, 0.001, 0.0037, 0.0001]` (matches
  `statsmodels multipletests(method='fdr_tsbky')`
  within 1e-12)

The MoonBit `tsbh_p_adjust` and `tsby_p_adjust`
produce the same algorithm (within 1e-12) as the
`statsmodels` reference.

## API additions (delta from v0.23.0)

| Symbol | Where | What |
|--------|-------|------|
| `tsbh_p_adjust` | `did_multi.mbt` | two-stage BH FDR |
| `tsby_p_adjust` | `did_multi.mbt` | two-stage BY FDR |
| `p_adjust("fdr_bh")` / `p_adjust("fdr_by")` aliases | `did_multi.mbt` | statsmodels long names |
| `p_adjust("tsbh")` / `p_adjust("tsby")` | `did_multi.mbt` | new two-stage methods |
| `p_adjust("fdr_tsbh")` / `p_adjust("fdr_tsbky")` aliases | `did_multi.mbt` | statsmodels long names |

No field renames, no removed methods. The existing
`p_adjust` methods are unchanged.

## Known limitations / deferrals

- **The `m0_hat` estimator uses `alpha = 0.05`
  hard-coded**. The standard Storey 2002 default
  is `alpha = 0.05`; a future release could
  expose this as a parameter if needed.
- **No bootstrap-based TSBH/TSBY**. The
  two-stage corrections are computed from the
  unadjusted p-values only; they do not
  require `bootstrap()`. This is consistent with
  the upstream `statsmodels.multipletests` API
  (which also doesn't use bootstrap).
- **No cross-method aliases for "simes-hochberg"
  or "hommel"** (the other FDR methods supported
  by `statsmodels`). Defer to v0.25+ if needed.

## Files changed (full list)

```
 CHANGELOG.md                              |  90 +++++++++++++++++++++
 README.mbt.md                             |  12 +++
 did_multi.mbt                             | 150 +++++++++++++++++++++++++++++
 did_multi_test.mbt                        | 110 +++++++++++++++++++++
 validate_padjust_with_python.py           |  10 +++
 _verify/T240-verdict.md                  | (this file)
 _verify/T240-commit-msg.txt              |  90 +++++++++++++++++
 7 files changed, 462 insertions(+), 10 deletions(-)
```

See `_verify/T240-commit-msg.txt` for the git
commit message.
