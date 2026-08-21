# TODO 0.21.0 (DoubleMLDIDCrossSection::bootstrap) — Verdict

**Date**: 2026-08-21
**Branch / tag**: master, v0.21.0
**Scope**: Add a multiplier bootstrap to the
`DoubleMLDIDCrossSection` model. The bootstrap
exposes the per-observation influence function
`psi[i] = psi_a[i] + theta * psi_b[i]` and
populates a length-`n_rep_boot` `boot_t_stat` array
that has mean 0 and SD 1 under the null (matching
the panel `DoubleMLDIDMulti` convention). The
existing `confint` is extended to accept `joint?`
and `level?` parameters for empirical-quantile
joint CIs. Also adds `norm_cdf` and `norm_ppf`
helpers for the standard-normal CDF and inverse
CDF.

## Motivation

The cross-section DID is a scalar estimator (one
ATT), so the `psi_a` and `psi_b` accessors added
in v0.20.0 only enable joint CIs via a manual
bootstrap on the user's side. The v0.21.0 release
finishes that plumbing with a `bootstrap()` method
on the model itself, and adds a `norm_cdf` /
`norm_ppf` pair for the Wald-style critical value
used by the pointwise `confint`.

## What was added

### Public API (delta from v0.20.0)

```moonbit
// New: bootstrap method
pub fn DoubleMLDIDCrossSection::bootstrap(
  self : DoubleMLDIDCrossSection,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLDIDCrossSection

// Extended: confint now takes joint? and level?
pub fn DoubleMLDIDCrossSection::confint(
  self : DoubleMLDIDCrossSection,
  joint? : Bool = false,
  level? : Double = 0.95,
) -> (Double, Double)

// New accessors
pub struct DoubleMLDIDCrossSection { ...
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
}
// accessors via the public fit/boot/bootstrap return values

// New: standard-normal CDF and inverse CDF
pub fn norm_cdf(x : Double) -> Double
pub fn norm_ppf(p : Double) -> Double
```

### Algorithm

The bootstrap t-stat is:
```
psi[i] = psi_a[i] + theta * psi_b[i]
se_psi = sqrt(sum_i psi_i^2 / n)
boot_t_stat[b] = sum_i w[b, i] * psi[i] / (sqrt(n) * se_psi)
```

where `w[b, i]` is the multiplier weight for
replication `b` at observation `i` (drawn from
`"normal"`, `"Bayes"`, or `"wild"`).

Under H0 (independent weights with var 1):
- `E[boot_t_stat] = 0`
- `Var[boot_t_stat] = sum_i psi_i^2 * 1 / (n * se_psi^2) = 1`

So the bootstrap t-stat has mean 0 and SD 1 by
construction. The joint CI uses the empirical
`(1 + level) / 2` quantile of `|boot_t_stat|`.

## Diff summary

| # | File | +/- | What changed |
|---|------|-----|--------------|
| 1 | `did_cross_section.mbt` | +160 | `bootstrap`, `norm_cdf`, `norm_ppf`, `confint` extension, 4 accessors. |
| 2 | `did_cross_section_test.mbt` | +130 | 10 new tests. |
| 3 | `cmd/did_cross_section/main.mbt` | +8 | Added joint 95% CI line. |
| 4 | `validate_did_cross_section_with_python.py` | +25 | Bootstrap moments cross-check. |
| 5 | `README.mbt.md` | +9 | Test count to 225/225. |
| 6 | `CHANGELOG.md` | +100 | Full v0.21.0 entry. |
| 7 | `_verify/T210-verdict.md` | (this file) | T210 verdict. |
| 8 | `_verify/T210-commit-msg.txt` | +110 | T210 commit message. |

**Net**: +542 / -7 lines (most of the +542 is
tests + CHANGELOG + verdict + commit-msg; the
production code is +160 / -7).

## Test deltas

- **225 / 225** on every backend (native, wasm-gc,
  wasm, js). +10 from v0.20.0:
  1. `did_cross_section_bootstrap_basic` —
     `boot_t_stat` length and metadata.
  2. `did_cross_section_bootstrap_deterministic`
     — same seed produces bit-equal output.
  3. `did_cross_section_bootstrap_moments` —
     `boot_t_stat` has mean ~ 0 and SD ~ 1.
  4. `did_cross_section_bootstrap_bayes` —
     `method_name = "Bayes"` produces a different
     draw.
  5. `did_cross_section_bootstrap_wild` —
     `method_name = "wild"` works.
  6. `panic_did_cross_section_joint_confint_without_bootstrap`
     — `confint(joint=true)` aborts if `bootstrap()`
     wasn't called.
  7. `did_cross_section_joint_confint_wider` —
     joint CI is wider than pointwise.
  8. `did_cross_section_confint_custom_level` —
     `level = 0.99` is wider than default `0.95`.
  9. `did_cross_section_norm_cdf_ppf_inverse` —
     `norm_cdf(norm_ppf(p)) ≈ p` within 1e-4.
  10. `did_cross_section_norm_ppf_975` —
      `norm_ppf(0.975) ≈ 1.96` (within 1e-5).

- **16 / 16** Python validators PASS (the
  `validate_did_cross_section_with_python.py`
  script now also emits the bootstrap t-stat
  moments: mean, SD, 97.5th percentile of |t|).

- **6 / 6** demos all run cleanly and produce
  sensible output. The `cmd/did_cross_section`
  demo now also prints the joint 95% CI after
  a multiplier bootstrap.

## Cross-check: MoonBit vs numpy

The `validate_did_cross_section_with_python.py`
script now also emits the bootstrap t-stat moments
from a numpy-based multiplier bootstrap. The
MoonBit matches numpy to within Monte-Carlo error
(mean ~ 0.04, SD ~ 1.0, |t|_0.975 ~ 2.2).

## API additions (delta from v0.20.0)

| Symbol | Where | What |
|--------|-------|------|
| `DoubleMLDIDCrossSection::bootstrap` | `did_cross_section.mbt` | multiplier bootstrap |
| `DoubleMLDIDCrossSection::confint(joint?, level?)` | `did_cross_section.mbt` | extended to joint CIs |
| `DoubleMLDIDCrossSection::boot_t_stat` / `boot_method` / `n_rep_boot` / `boot_seed` | `did_cross_section.mbt` | bootstrap metadata accessors |
| `norm_cdf` | `did_cross_section.mbt` | standard-normal CDF |
| `norm_ppf` | `did_cross_section.mbt` | standard-normal inverse CDF |

No field renames on `DoubleMLDIDCrossSection`
(the new fields are additions, not renames). No
removed methods on any other struct.

## Known limitations / deferrals

- **`norm_cdf` / `norm_ppf` live in
  `did_cross_section.mbt`**, even though they're
  generally useful. A future refactor could
  promote them to a shared utility module (e.g.
  `stats.mbt` or `dist.mbt`).
- **Bootstrap does not yet support `level`
  adjustments for Bonferroni-style FWER control**
  in the multi-cell case. The cross-section DID
  is a scalar estimator, so this is moot; if
  someone wants a multi-cell variant (e.g. for
  multiple outcome variables), the existing
  `holm_bonferroni_p_adjust` /
  `bonferroni_p_adjust` helpers in
  `did_multi.mbt` could be reused.
- **Bisection-based `norm_ppf` is ~1.3e-6
  accurate in `z`** (limited by the A&S 7.1.26
  accuracy of `norm_sf` / `norm_cdf`). For the
  typical use case (95% CI) this is more than
  enough; for sub-percentile accuracy, a higher-
  precision algorithm (e.g. Acklam's rational
  approximation) would be needed.

## Files changed (full list)

```
 CHANGELOG.md                                  | 100 +++++++++++++++++++++
 README.mbt.md                                 |   9 ++
 cmd/did_cross_section/main.mbt                |   8 ++
 did_cross_section.mbt                         | 160 +++++++++++++++++++++++++++++
 did_cross_section_test.mbt                    | 130 +++++++++++++++++++++
 validate_did_cross_section_with_python.py     |  25 ++++
 _verify/T210-verdict.md                      | (this file)
 _verify/T210-commit-msg.txt                  | 110 ++++++++++++++++++++
 8 files changed, 542 insertions(+), 7 deletions(-)
```

See `_verify/T210-commit-msg.txt` for the git
commit message.
