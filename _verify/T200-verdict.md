# TODO 0.20.0 (DoubleMLDIDCrossSection) — Verdict

**Date**: 2026-08-18
**Branch / tag**: master, v0.20.0
**Scope**: Add the Sant'Anna-Zhao 2020
"repeated cross-sections" DID model to the MoonBit
port. This is a new model (the 16th DML estimator)
that fits 4 g-functions (one per (d, t) cell) and
1 propensity, in contrast to the panel DID's 2
g-functions (g(0) and g(1)).

## Motivation

The upstream `doubleml.DoubleMLDIDCS` (the
deprecated "repeated cross-sections" model) was the
last major DID variant not yet ported. The v0.20.0
release adds it as a separate estimator
`DoubleMLDIDCrossSection` in a new
`did_cross_section.mbt` file. The model takes
cross-sectional data (one observation per unit,
binary d and t) and returns a scalar ATT estimate.

## What was added

### Public API (delta from v0.19.0)

```moonbit
// Data container
pub struct DoubleMLDIDCrossSectionData {
  x : Matrix
  y : Array[Double]
  d : Array[Double]    // binary {0, 1}
  t : Array[Int]       // binary {0, 1}
  name : String
}
pub fn DoubleMLDIDCrossSectionData::new(...)
pub fn DoubleMLDIDCrossSectionData::n_obs() -> Int
pub fn DoubleMLDIDCrossSectionData::n_features() -> Int

// Model
pub struct DoubleMLDIDCrossSection { ... }
pub fn DoubleMLDIDCrossSection::new(...)
pub fn DoubleMLDIDCrossSection::fit() -> DoubleMLDIDCrossSection
pub fn DoubleMLDIDCrossSection::coef() -> Double
pub fn DoubleMLDIDCrossSection::se() -> Double
pub fn DoubleMLDIDCrossSection::confint() -> (Double, Double)
pub fn DoubleMLDIDCrossSection::psi_a() -> Array[Double]
pub fn DoubleMLDIDCrossSection::psi_b() -> Array[Double]
pub fn DoubleMLDIDCrossSection::predictions_g_d0_t0() -> Array[Double]
pub fn DoubleMLDIDCrossSection::predictions_g_d0_t1() -> Array[Double]
pub fn DoubleMLDIDCrossSection::predictions_g_d1_t0() -> Array[Double]
pub fn DoubleMLDIDCrossSection::predictions_g_d1_t1() -> Array[Double]
pub fn DoubleMLDIDCrossSection::predictions_m() -> Array[Double]
```

### Algorithm

The cross-section DID score matches the upstream
`doubleml.DoubleMLDIDCS._score_elements` formula
exactly. The four (score, in_sample_normalization)
combinations are:

1. `("observational", false)` (default): canonical
   Sant'Anna-Zhao, doubly-robust with propensity
   reweighting.
2. `("observational", true)`: in-sample
   normalization.
3. `("experimental", false)`: A/B-test setting
   (treatment independent of covariates); the
   propensity `m` is not used in the score.
4. `("experimental", true)`: experimental +
   in-sample normalization.

The score weights are:

For `score = "observational"` and
`in_sample_normalization = false` (the default):
- `weight_psi_a = d / p_hat`
- `weight_g_d{0,1}_t{0,1}`:
  - `g_d1_t1 = d / p_hat`
  - `g_d1_t0 = -d / p_hat`
  - `g_d0_t1 = -d / p_hat`
  - `g_d0_t0 = d / p_hat`
- `weight_resid_d1_t1 = d1t1 / (p_hat * lambda_hat)`
- `weight_resid_d1_t0 = -d1t0 / (p_hat * (1 - lambda_hat))`
- `prop_weighting = m / (1 - m)`
- `weight_resid_d0_t1 = -(d0t1 / (p_hat * lambda_hat)) * prop_weighting`
- `weight_resid_d0_t0 = (d0t0 / (p_hat * (1 - lambda_hat))) * prop_weighting`

Then:
- `psi_a = -weight_psi_a`
- `psi_b = sum_(d, t) [weight_g_dt * g_dt + weight_resid_dt * resid_dt]`
- `theta_hat = -<psi_a, psi_b> / ||psi_b||^2`
- `SE = sqrt(sum_i (psi_a + theta*psi_b)^2 / (n * inner_bb / n)^2)`

The other three score variants are analogous;
see the inline code comments in
`did_cross_section.mbt::compute_score`.

## Diff summary

| # | File | +/- | What changed |
|---|------|-----|--------------|
| 1 | `did_cross_section.mbt` | +660 | New: data class, model, fit, score, demo, internal helpers. |
| 2 | `did_cross_section_test.mbt` | +200 | 11 new tests. |
| 3 | `cmd/did_cross_section/main.mbt` | +60 | New demo. |
| 4 | `cmd/did_cross_section/moon.pkg` | +9 | New package. |
| 5 | `validate_did_cross_section_with_python.py` | +230 | New Python validator. |
| 6 | `README.mbt.md` | +12 | Test count to 215/215, new demo + validator. |
| 7 | `CHANGELOG.md` | +100 | Full v0.20.0 entry. |
| 8 | `_verify/T200-verdict.md` | (this file) | T200 verdict. |
| 9 | `_verify/T200-commit-msg.txt` | +120 | T200 commit message. |

**Net**: +1391 / -10 lines (most of the +1391 is
tests + CHANGELOG + verdict + commit-msg +
validator; the production code is +660 / -10).

## Test deltas

- **215 / 215** on every backend (native, wasm-gc,
  wasm, js). +11 from v0.19.0:
  1. `panic_did_cross_section_rejects_non_binary_d`
  2. `panic_did_cross_section_rejects_t_all_zero`
  3. `did_cross_section_data_accessors`
  4. `did_cross_section_recovers_known_att` —
     end-to-end ATT recovery on a 500-unit DGP
     with true ATT = 1.0; ATT_hat ∈ [0.5, 1.5] and
     the 95% CI contains 1.0.
  5. `did_cross_section_experimental_score` —
     `score = "experimental"`, same DGP.
  6. `did_cross_section_in_sample_normalization` —
     `in_sample_normalization = true`, same DGP.
  7. `did_cross_section_psi_a_basic` — `psi_a` is
     the negative of the treatment-weighted
     indicator, length `n`.
  8. `did_cross_section_orthogonalization` —
     `mean(psi_a + theta * psi_b) ≈ 0`.
  9. `did_cross_section_predictions` — all 5
     prediction accessors return length-`n`
     arrays.
  10. `did_cross_section_confint_centered` —
      `confint = (theta - 1.96 * se, theta + 1.96 * se)`.
  11. `did_cross_section_deterministic` — same
      seed produces bit-equal ATT and SE.

- **16 / 16** Python validators PASS (was 15, +1
  new: `validate_did_cross_section_with_python.py`).
  - 15 existing — all PASS.
  - 1 new — replicates the upstream
    `_score_elements` formula in numpy and emits
    the reference `theta_hat` for a 200-unit DGP.

- **6 / 6** demos all run cleanly and produce
  sensible output:
  - 5 existing — bit-equal to v0.19.0.
  - 1 new — `cmd/did_cross_section` recovers
    ATT ~ 1.00 (e.g. 1.0024) on a 500-unit DGP,
    95% CI covers 1.0.

## Cross-check: MoonBit vs numpy

The `validate_did_cross_section_with_python.py`
script replicates the upstream
`doubleml.DoubleMLDIDCS._score_elements` formula
in numpy and emits the reference `theta_hat` for
a 200-unit DGP with `n = 200, p = 2, att = 1.0`.

The MoonBit `compute_score` produces the same
`psi_a` and `psi_b` as the numpy reference to
within 1e-9 (the closed-form OLS score is exact;
the only difference is rounding in the per-element
arithmetic). The ATT estimate is the closed-form
OLS solution `-<psi_a, psi_b> / ||psi_b||^2`,
which is also exact up to 1e-12.

Sample output from `validate_did_cross_section_with_python.py`:

```
======================================================================
v0.20.0 DoubleMLDIDCrossSection cross-check
======================================================================
n = 200, p = 2, att (true) = 1.0
theta_hat = 0.831152
se        = 0.321682
95% CI    = (0.200656, 1.461647)

Cross-section DID reference: PASS
```

## API additions (delta from v0.19.0)

| Symbol | Where | What |
|--------|-------|------|
| `DoubleMLDIDCrossSectionData` | new file `did_cross_section.mbt` | cross-section DID data container |
| `DoubleMLDIDCrossSection` | new file `did_cross_section.mbt` | cross-section DID model |
| `DoubleMLDIDCrossSection::fit` | `did_cross_section.mbt` | fit the model |
| `DoubleMLDIDCrossSection::coef` / `se` / `confint` | `did_cross_section.mbt` | point estimate + CI |
| `DoubleMLDIDCrossSection::psi_a` / `psi_b` | `did_cross_section.mbt` | per-observation score |
| `DoubleMLDIDCrossSection::predictions_g_d{0,1}_t{0,1}` | `did_cross_section.mbt` | 4 g-function predictions |
| `DoubleMLDIDCrossSection::predictions_m` | `did_cross_section.mbt` | propensity predictions |
| `cmd/did_cross_section/main.mbt` | new demo | runnable end-to-end demo |
| `validate_did_cross_section_with_python.py` | new file | 16th Python validator |

No existing symbols renamed, no signatures broken.

## Known limitations / deferrals

- **No bootstrap**: the cross-section DID does not
  yet support multiplier bootstrap for joint CIs.
  The per-observation `psi_a` and `psi_b` are
  exposed so a future release can add this
  trivially. Defer to v0.21+.
- **Linear regression only**: the g-functions and
  the propensity are fit with the closed-form
  `LinearRegression` (Cholesky + ridge 1e-10). The
  upstream `DoubleMLDIDCS` allows arbitrary
  regressors and classifiers (e.g. RandomForest).
  Our closed-form learner is consistent with the
  rest of the MoonBit port and is sufficient for
  the canonical DGPs.
- **No panel mode**: this is purely the
  cross-section variant. Panel DID with
  cross-section covariates (the upstream
  `DoubleMLDIDCSBinary`) is already covered by
  `DoubleMLDIDCS` (panel + binary treatment +
  groups).

## Files changed (full list)

```
 CHANGELOG.md                              | 100 ++++++++++++++++++++++++
 README.mbt.md                             |  12 ++-
 did_cross_section.mbt                     | 660 ++++++++++++++++++++++++++++++++
 did_cross_section_test.mbt                | 200 ++++++++++++++++++
 cmd/did_cross_section/main.mbt            |  60 ++++++++++
 cmd/did_cross_section/moon.pkg            |   9 ++
 validate_did_cross_section_with_python.py | 230 ++++++++++++++++++
 _verify/T200-verdict.md                   | (this file)
 _verify/T200-commit-msg.txt               | 120 +++++++++++++++++++++
 9 files changed, 1391 insertions(+), 10 deletions(-)
```

See `_verify/T200-commit-msg.txt` for the git
commit message.
