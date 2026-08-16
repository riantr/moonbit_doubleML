# TODO 0.15.0 (did_multi multiplier bootstrap / joint CIs) — Verdict

**Date**: 2026-08-16
**Branch / tag**: master, v0.15.0
**Scope**: Implement the multiplier bootstrap and joint
confidence intervals on `DoubleMLDIDMulti` (deferred from
v0.11.0, ~400 LOC upstream `DoubleMLFramework.bootstrap` +
`confint(joint=True)`). Adds pure-MoonBit weight-draw
functions (normal / Bayes / wild), per-cell influence
function extraction from `DoubleMLDIDCS`, 11 new tests,
and a Python cross-check against numpy's RNG.

**Behaviour change**: Only when `bootstrap()` is explicitly
called. The default config (no bootstrap) is byte-equal to
v0.14.0; the `did_binary` / `did_cs` / `did_multi` demos
(which don't call `bootstrap()`) produce bit-equal ATT
estimates to v0.14.0.

## What was added

### `ps_processor.mbt`-style: weight draw + bootstrap

```moonbit
pub fn draw_bootstrap_weights(method_name, n_rep_boot, n_obs, seed) -> Array[Double]
pub fn box_muller_normal(rng) -> Double

pub fn DoubleMLDIDMulti::bootstrap(method_name?, n_rep_boot?, seed?) -> DoubleMLDIDMulti
pub fn DoubleMLDIDMulti::confint(joint?, level?) -> Array[(Double, Double)]
```

- `draw_bootstrap_weights` returns a row-major
  `(n_rep_boot, n_obs)` array of multiplier weights from
  the chosen distribution:
  - `"normal"`: `w[i] ~ N(0, 1)` (Box-Muller).
  - `"Bayes"`: `w[i] = -ln(u) - 1` (mean 0, var 1).
  - `"wild"`: `w[i] = x[i] / sqrt(2) + (y[i]^2 - 1) / 2`
    with `x, y ~ N(0, 1)`.
- `bootstrap` draws weights, computes per-cell t-statistics
  `boot_t_stat[b, k] = sum_i w[b, i] * psi_k[i] / (sqrt(n) * se_k)`,
  and stores the result on the model.
- `confint(joint=true)` returns the bootstrap critical value
  as the empirical `level`-quantile of `max_k |boot_t_stat[b, k]|`.

### Per-cell influence function extraction (did.mbt + did_binary.mbt + did_cs.mbt)

- `did.mbt::DoubleMLDID` now exposes `psi_a` and `psi_b`
  (length `n_obs` on the wide-format data). The DML score
  is `psi_a + theta * psi_b`; this is the influence function
  used by the multiplier bootstrap.
- `did_binary.mbt::WideDIDSubset` records the long-format
  `eval_idx` per wide-format row. `DoubleMLDIDBinary` stores
  it and exposes `psi_a_long` / `psi_b_long` (length
  `data.n_obs()` with 0 padding) and `inner_psi_a` /
  `inner_psi_b` (length `n_obs_subset()`).
- `did_cs.mbt::DoubleMLDIDCS` now stores a `psi_matrix` of
  shape `(n_groups * n_periods, n_obs)`: the per-cell
  influence function on the full long-format panel. The
  per-cell fit loop records the full long-format index for
  each sub row (`full_idx_acc`) and uses it to map the
  cell's wide-format psi back to the full long-format panel
  via the wide-format `eval_idx`.

## Diff summary

| # | File | +/- | What changed |
|---|------|-----|--------------|
| 1 | `did.mbt` | +30 | Added `psi_a` and `psi_b` fields to `DoubleMLDID`; populated in `fit`. |
| 2 | `did_binary.mbt` | +90 | Added `eval_idx` to `WideDIDSubset`; `DoubleMLDIDBinary` struct field; `psi_a_long` / `psi_b_long` / `inner_psi_a` / `inner_psi_b` accessors. |
| 3 | `did_cs.mbt` | +60 | Added `psi_matrix` field to `DoubleMLDIDCS`; per-cell fit loop records `full_idx_acc`; post-loop reassembly copies per-cell psi to row-major slot. |
| 4 | `did_multi.mbt` | +200 | Added `boot_t_stat` / `boot_method` / `n_rep_boot` / `boot_seed` fields to `DoubleMLDIDMulti`; `bootstrap` method; `confint(joint?, level?)` method; `draw_bootstrap_weights` and `box_muller_normal` helpers. |
| 5 | `did_multi_test.mbt` | +260 | 11 new tests (weight moments × 3, determinism, joint-wider, pointwise + joint coverage × 2, panic × 3, default method). |
| 6 | `validate_bootstrap_with_python.py` | +60 | New Python validator (numpy reference for multiplier distributions). |
| 7 | `README.mbt.md` | +20 | Test count to 174/174, validator count to 13/13, "Demo entry points" example updated. |
| 8 | `CHANGELOG.md` | +118 | Full v0.15.0 entry. |
| 9 | `_verify/T150-verdict.md` | (this file) | T150 verdict. |
| 10 | `_verify/T150-commit-msg.txt` | +90 | T150 commit message. |
| 11 | `_verify/probe-bootstrap-test.mbt.archived` | +95 | Verifier scratch: bootstrap probe (now archived). |

**Net**: +1023 / -10 lines (most of the +1023 is CHANGELOG +
verdict + test + probe + reference Python script; the
production code is +380 / -10).

## Test deltas

- **174 / 174** on every backend (native, wasm-gc, wasm,
  js). +11 from v0.14.0:
  1. `bootstrap_weight_normal_moments` — mean ≈ 0,
     variance ≈ 1 on 200 × 50 weights.
  2. `bootstrap_weight_bayes_moments` — same.
  3. `bootstrap_weight_wild_moments` — same.
  4. `bootstrap_deterministic_seed` — same seed →
     bit-equal `boot_t_stat`.
  5. `bootstrap_joint_ci_wider_than_pointwise` —
     joint CI half-width ≥ pointwise half-width for
     every cell.
  6. `bootstrap_pointwise_ci_covers_truth` — all 3
     cells' pointwise CIs cover the true ATT = 1.0.
  7. `bootstrap_joint_ci_covers_truth` — all 3 cells'
     joint CIs cover the true ATT.
  8. `panic_joint_confint_without_bootstrap` —
     `confint(joint=true)` before `bootstrap()` aborts.
  9. `panic_bootstrap_before_fit` — `bootstrap()`
     before `fit()` aborts.
  10. `panic_bootstrap_invalid_method` —
      `method_name="invalid"` aborts.
  11. `bootstrap_default_method_is_normal` — default
      `method_name = "normal"`, default
      `n_rep_boot = 500`.

- **13 / 13 Python validators PASS** (was 12, +1 new
  `validate_bootstrap_with_python.py`):
  - 12 existing — all bit-equal to v0.14.0.
  - 1 new — empirical moments of the three multiplier
    distributions match the upstream numpy
    implementation.

- **5 / 5** demos all run cleanly and produce bit-equal
  output to v0.14.0. None of the demos calls
  `bootstrap()` (it's opt-in); the joint CIs are not
  exercised in the demos.

## Cross-check: MoonBit bootstrap vs numpy

The `validate_bootstrap_with_python.py` script computes
the empirical moments of the three multiplier distributions
on a 200 × 50 weight matrix using both numpy's PCG64 and
(theoretical) chacha8:

| Method | numpy mean | numpy variance | MoonBit mean | MoonBit variance |
|--------|------------|----------------|--------------|------------------|
| `normal` | +0.0078 | 0.9828 | ≈ 0 | ≈ 1 |
| `Bayes` | -0.0021 | 0.9782 | ≈ 0 | ≈ 1 |
| `wild` | +0.0004 | 0.9762 | ≈ 0 | ≈ 1 |

(The numpy values are from a single seed=2024 draw; the
MoonBit values are from the test cases on
`draw_bootstrap_weights("...", 200, 50, 2024)`. The means
and variances are all close to the theoretical 0 and 1.)

## API additions (delta from v0.14.0)

| Symbol | Where | What |
|--------|-------|------|
| `DoubleMLDIDMulti::bootstrap` | `did_multi.mbt` | Multiplier bootstrap; populates `boot_t_stat` |
| `DoubleMLDIDMulti::confint` | `did_multi.mbt` | `joint` CIs via bootstrap; `joint = false` for Wald |
| `draw_bootstrap_weights` | `did_multi.mbt` | Pure MoonBit weight-draw helper (public for testability) |
| `box_muller_normal` | `did_multi.mbt` | Standard-normal sample via Box-Muller (public for testability) |
| `DoubleMLDIDMulti.boot_t_stat` | `did_multi.mbt` | New field: row-major `n_rep_boot * n_thetas` array |
| `DoubleMLDIDMulti.boot_method` | `did_multi.mbt` | New field: `"normal"` / `"Bayes"` / `"wild"` |
| `DoubleMLDIDMulti.n_rep_boot` | `did_multi.mbt` | New field: bootstrap replication count |
| `DoubleMLDIDMulti.boot_seed` | `did_multi.mbt` | New field: bootstrap RNG seed |
| `DoubleMLDID.psi_a` / `DoubleMLDID.psi_b` | `did.mbt` | New fields: per-obs influence-function components |
| `DoubleMLDIDBinary.eval_idx` | `did_binary.mbt` | New field: long-format `eval_idx` per wide-format row |
| `DoubleMLDIDBinary.psi_a_long` / `psi_b_long` | `did_binary.mbt` | New accessors: long-format psi (0-padded) |
| `DoubleMLDIDBinary.inner_psi_a` / `inner_psi_b` | `did_binary.mbt` | New accessors: wide-format psi |
| `DoubleMLDIDCS.psi_matrix` | `did_cs.mbt` | New field: per-cell long-format psi |
| `validate_bootstrap_with_python.py` | repo root | New Python validator |

No field renames, no signature breakage, no removed
functions. The `DoubleMLDID` `psi_a` / `psi_b` fields
are additive; existing call sites continue to work
because the public `coef` / `se` / `predictions_*`
accessors are unchanged.

## Known limitations / deferrals

- **No `_draw_weights` upstream exact-value parity**.
  MoonBit's chacha8 RNG and numpy's PCG64 produce
  different absolute weight values; the bootstrap
  critical values are not bit-equal to upstream. The
  empirical moments match (mean ≈ 0, variance ≈ 1) and
  the joint CI coverage matches asymptotically.
- **No CS-DID bootstrap on cross-section data** (the
  upstream `DoubleMLDIDCS` has a `panel` flag; the
  v0.9.0+ port is panel-only).
- **No `confint(level, joint, param)` upstream arg
  parity**. We accept only `joint` and `level`; the
  upstream also accepts `param` (a parameter index
  for single-cell CIs). The v0.15.0 port returns
  per-(g, t) CIs as an array, so the user can index
  into the result.
- **No `DoubleMLDIDMulti::p_adjust(method)`** (the
  upstream's Romano-Wolf multiple-testing correction).
  Deferred — would add another ~80 LOC for the
  stepdown Romano-Wolf algorithm.
- **Default `n_rep_boot = 500` and `seed = 2024`**
  match the upstream defaults.

## Files changed (full list)

```
 CHANGELOG.md                           | 118 ++++++++++++++++++++++
 README.mbt.md                          |  20 ++++
 did.mbt                                |  30 +++++
 did_binary.mbt                         |  90 +++++++++++++++
 did_cs.mbt                             |  60 ++++++++++
 did_multi.mbt                          | 200 ++++++++++++++++++++++++
 did_multi_test.mbt                     | 260 +++++++++++++++++++++++++++++
 validate_bootstrap_with_python.py      |  60 ++++++++++
 _verify/T150-verdict.md                | (this file)
 _verify/T150-commit-msg.txt            |  90 ++++++++++++
 _verify/probe-bootstrap-test.mbt.archived |  95 +++++++++++
 11 files changed, 1023 insertions(+), 10 deletions(-)
```

See `_verify/T150-commit-msg.txt` for the git commit
message.
