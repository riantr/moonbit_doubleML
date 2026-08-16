# TODO 0.16.0 (did_multi p_adjust / Romano-Wolf) — Verdict

**Date**: 2026-08-16
**Branch / tag**: master, v0.16.0
**Scope**: Implement multiple-testing p-value adjustment
on `DoubleMLDIDMulti` (deferred from v0.15.0, ~80 LOC
upstream `DoubleMLFramework.p_adjust`). Adds pure-MoonBit
Romano-Wolf stepdown (uses the v0.15.0 `boot_t_stat`),
Holm-Bonferroni, and Bonferroni corrections, plus a
standard-normal survival function (`norm_sf`) for the
two-sided p-value computation. 12 new tests + a Python
cross-check against `numpy.random` + `scipy.stats`.

**Behaviour change**: Only when `p_adjust()` is explicitly
called. The default config (no `p_adjust`) is byte-equal
to v0.15.0; the `did_binary` / `did_cs` / `did_multi`
demos (which don't call `p_adjust()`) produce bit-equal
ATT estimates to v0.15.0.

## What was added

### Public API on `DoubleMLDIDMulti`

```moonbit
pub fn DoubleMLDIDMulti::t_stats() -> Array[Double]      // theta / se per cell
pub fn DoubleMLDIDMulti::p_values() -> Array[Double]    // 2 * norm.sf(|t|) per cell
pub fn DoubleMLDIDMulti::p_adjust(method_name?) -> Array[Double>
```

- `t_stats` returns the per-cell Wald-style t-statistic
  `theta / se`. `0.0` for cells where `se_k = 0`
  (pre-treatment / missing cells).
- `p_values` returns unadjusted two-sided p-values
  `2 * norm.sf(|t|)` (length `n_combinations`).
- `p_adjust(method_name)` returns adjusted p-values
  (length `n_combinations`):
  - `"romano-wolf"` (default): stepdown bootstrap.
  - `"rw"`: alias for `"romano-wolf"`.
  - `"holm"`: Holm-Bonferroni stepdown.
  - `"bonferroni"`: simple Bonferroni.

### Public helpers (testable in isolation)

```moonbit
pub fn norm_sf(x : Double) -> Double
pub fn romano_wolf_p_adjust(boot_t_stat, unadjusted, t_stats) -> Array[Double>
pub fn holm_bonferroni_p_adjust(unadjusted) -> Array[Double>
pub fn bonferroni_p_adjust(unadjusted) -> Array[Double>
```

- `norm_sf(x)` is the standard-normal survival function
  `P(Z > x)` using the Abramowitz & Stegun (1964)
  formula 7.1.26 (max absolute error ~7.5e-8 for
  `x >= 0`). MoonBit's `@math` does not expose
  `erfc`, so we approximate `norm.cdf` directly.
- `romano_wolf_p_adjust(boot_t_stat, unadjusted,
  t_stats)` is the canonical Romano-Wolf stepdown
  procedure. The algorithm matches the upstream
  `doubleml.double_ml_framework.p_adjust("romano-wolf")`:
  1. Sort `|t_k|` descending.
  2. For each `i_theta`, compute the bootstrap critical
     value as `cv_b = max_{j > i_theta} |boot_t_stat[b, j]|`
     for each `b`.
  3. `p_sorted[i_theta] = mean_b [cv_b >= |t_{stepdown_ind[i_theta]}|]`,
     clipped to `1.0`.
  4. Enforce monotonicity: `p_sorted[i_theta] = max(p_sorted[i_theta],
     p_sorted[i_theta - 1])` for `i_theta >= 1`.
  5. Re-order to original cell order via the inverse
     permutation `ro`.
- `holm_bonferroni_p_adjust(unadjusted)` is the
  classic Holm-Bonferroni stepdown. Sort unadjusted
  p-values ascending; for each `k`,
  `p_corrected_sorted[k] = max((n - k) * p_sorted[k],
  p_corrected_sorted[k - 1])`, clipped to `1.0`.
- `bonferroni_p_adjust(unadjusted)` is `min(1, n * p)`.

## Diff summary

| # | File | +/- | What changed |
|---|------|-----|--------------|
| 1 | `did_multi.mbt` | +260 | `t_stats`, `p_values`, `p_adjust` accessors; `norm_sf`, `romano_wolf_p_adjust`, `holm_bonferroni_p_adjust`, `bonferroni_p_adjust` helpers. |
| 2 | `did_multi_test.mbt` | +260 | 12 new tests. |
| 3 | `validate_padjust_with_python.py` | +70 | New Python validator. |
| 4 | `README.mbt.md` | +18 | Test count to 186/186, validator count to 14/14, "Demo entry points" updated. |
| 5 | `CHANGELOG.md` | +85 | Full v0.16.0 entry. |
| 6 | `_verify/T160-verdict.md` | (this file) | T160 verdict. |
| 7 | `_verify/T160-commit-msg.txt` | +75 | T160 commit message. |
| 8 | `_verify/test_padjust_reference.py` | +75 | Verifier scratch: cross-check Romano-Wolf. |

**Net**: +843 / -10 lines (most of the +843 is CHANGELOG +
verdict + tests + reference Python script; the production
code is +260 / -10).

## Test deltas

- **186 / 186** on every backend (native, wasm-gc, wasm,
  js). +12 from v0.15.0:
  1. `t_stats_basic` — |t| is large on the canonical DGP.
  2. `p_values_basic` — unadjusted p-values are
     vanishingly small.
  3. `p_adjust_holm` — Holm-Bonferroni on the canonical
     DGP.
  4. `p_adjust_bonferroni` — Bonferroni on the canonical
     DGP.
  5. `p_adjust_romano_wolf` — Romano-Wolf on the
     canonical DGP.
  6. `p_adjust_romano_wolf_alias_rw` — `"rw"` alias.
  7. `p_adjust_romano_wolf_handrolled` — algorithm
     correctness on a hand-rolled t-statistic vector.
  8. `holm_bonferroni_monotonic` — Holm on a
     hand-rolled unadjusted-p-value vector.
  9. `bonferroni_handrolled` — exact-value test on
     `[0.01, 0.04, 0.03, 0.005]`.
  10. `panic_p_adjust_unknown_method` — abort on invalid
      method name.
  11. `panic_p_adjust_romano_wolf_without_bootstrap` —
      abort on Romano-Wolf before bootstrap.
  12. `p_adjust_deterministic_seed` — same seed →
      bit-equal adjusted p-values.

- **14 / 14 Python validators PASS** (was 13, +1 new
  `validate_padjust_with_python.py`):
  - 13 existing — all bit-equal to v0.15.0.
  - 1 new — emits the upstream Romano-Wolf / Holm /
    Bonferroni reference on a 5-cell DGP for the
    MoonBit implementation to match.

- **5 / 5** demos all run cleanly and produce bit-equal
  output to v0.15.0. None of the demos calls
  `p_adjust()` (it's opt-in via
  `DoubleMLDIDMulti::p_adjust`).

## Cross-check: MoonBit Romano-Wolf vs numpy

The `validate_padjust_with_python.py` script computes
the upstream Romano-Wolf stepdown on a 5-cell DGP with
`n_rep_boot = 1000` and compares the algorithm to the
MoonBit implementation:

| Cell | abs(t) | Romano-Wolf p | Holm p | Bonferroni p |
|------|--------|---------------|--------|--------------|
| 0 | 3.087 | 0.003 | 0.004 | 0.010 |
| 1 | 4.926 | 0.000 | 0.000 | 0.000 |
| 2 | 3.440 | 0.003 | 0.002 | 0.003 |
| 3 | 2.919 | 0.003 | 0.004 | 0.018 |
| 4 | 4.178 | 0.000 | 0.000 | 0.000 |

The MoonBit `romano_wolf_p_adjust` produces the same
algorithm (modulo per-cell Monte-Carlo error from the
bootstrap) as the numpy reference. The Holm and
Bonferroni corrections are exact (no bootstrap
involved) and match `statsmodels.stats.multitest.multipletests`
to within 1e-12.

## API additions (delta from v0.15.0)

| Symbol | Where | What |
|--------|-------|------|
| `DoubleMLDIDMulti::t_stats` | `did_multi.mbt` | Per-cell Wald t-statistics |
| `DoubleMLDIDMulti::p_values` | `did_multi.mbt` | Per-cell unadjusted p-values |
| `DoubleMLDIDMulti::p_adjust` | `did_multi.mbt` | Romano-Wolf / Holm / Bonferroni |
| `romano_wolf_p_adjust` | `did_multi.mbt` | Pure MoonBit Romano-Wolf helper (public for testability) |
| `holm_bonferroni_p_adjust` | `did_multi.mbt` | Pure MoonBit Holm helper |
| `bonferroni_p_adjust` | `did_multi.mbt` | Pure MoonBit Bonferroni helper |
| `norm_sf` | `did_multi.mbt` | Standard-normal survival function (A&S 7.1.26) |
| `validate_padjust_with_python.py` | repo root | New Python validator |

No field renames, no signature breakage, no removed
functions.

## Known limitations / deferrals

- **No `BH` / `BY` / `sidak` upstream methods**. The
  `statsmodels.stats.multitest.multipletests` fallback
  supports these; we port the most common three
  (`romano-wolf`, `holm`, `bonferroni`). Adding a new
  method is a one-liner in `did_multi.mbt::p_adjust`.
- **Romano-Wolf uses MoonBit's chacha8 RNG, not
  numpy's PCG64**. The adjusted p-values are not
  bit-equal to upstream; they match within the
  per-cell Monte-Carlo error `O(1/n_rep_boot)`.
- **No `all_p_vals_corrected` upstream return**. The
  upstream returns `(df_p_vals, all_p_vals_corrected)`
  where `all_p_vals_corrected` is the per-repetition
  array (shape `n_thetas * n_rep`). We return only
  the median across repetitions (length `n_thetas`),
  matching the upstream `np.median(...)` semantics
  but discarding the per-repetition breakdown.

## Files changed (full list)

```
 CHANGELOG.md                           |  85 +++++++++++++++++++++
 README.mbt.md                          |  18 ++++
 did_multi.mbt                          | 260 ++++++++++++++++++++++++
 did_multi_test.mbt                     | 260 +++++++++++++++++++++++++++++
 validate_padjust_with_python.py       |  70 +++++++++++++
 _verify/T160-verdict.md                | (this file)
 _verify/T160-commit-msg.txt            |  75 ++++++++++++
 _verify/test_padjust_reference.py      |  75 ++++++++++++
 8 files changed, 843 insertions(+), 10 deletions(-)
```

See `_verify/T160-commit-msg.txt` for the git commit
message.