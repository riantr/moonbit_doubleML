# mavis/dml — Double / Debiased Machine Learning in MoonBit

Pure-MoonBit port of the
[`doubleml`](https://github.com/DoubleML/doubleml-for-py) Python package,
covering all 15 models currently in upstream.

## Status

| Item | Value |
|------|-------|
| Source file count | 62 (31 production + 31 test) |
| Models ported | 16 / 16 (incl. cross-section DID) |
| Tests | **215 / 215** on all 4 backends (native, wasm-gc, wasm, js) |
| Warnings | 0 (under `moon test --deny-warn`) |
| Python cross-checks | 16 / 16 PASS |
| License | Apache-2.0 |

## Quick start

```console
$ moon test --deny-warn
Total tests: 215, passed: 215, failed: 0.

$ moon run cmd/main
=== MoonBit DML PLR (partialling out) ===
true theta_0      = 1
estimated theta   = 0.9763281577675552
standard error    = 0.08740490230937094
...

$ python validate_irm_with_python.py
======================================================================
PASS  |mb - handrolled_nrep5| (theta) = 5.24e-02 < max(MODEL_TOL=0.1, 2.0*handrolled_n5_se) = 1.91e-01
```

## Library use

```moonbit nocheck
let data = @dml.DoubleMLData::new(x, y, d)  // x : Matrix, y / d : Array[Double]
let fitted = @dml.DoubleMLPLR::new(data, n_folds=2, n_rep=1, seed=3141).fit()
let coef = fitted.coef()      // Double
let se = fitted.se()          // Double
let (lo, hi) = fitted.confint()
```

## Demo entry points

Six `cmd/*/main.mbt` drivers run end-to-end on synthetic DGPs. Each
prints the true vs. estimated coefficient plus a 95% CI:

| Driver | Model | DGP | True θ |
|--------|-------|-----|--------|
| `cmd/main` | `DoubleMLPLR` (and 5 others) | Simple partially linear, `n=500`, `p=5` | 1.0 |
| `cmd/datasets` | `DoubleMLPLR` + `DoubleMLIRM` | Synthetic 401(k)-style, `n=5000`, 9 controls | 1.5 |
| `cmd/did_binary` | `DoubleMLDIDBinary` | 2-period panel DID, 400 units | 1.0 |
| `cmd/did_cs` | `DoubleMLDIDCS` | Staggered CS-DID, 4 cohorts × 4 periods | 1.0 |
| `cmd/did_multi` | `DoubleMLDIDMulti` | Top-level multi-period DID + aggregation | 1.0 |
| `cmd/did_cross_section` | `DoubleMLDIDCrossSection` | Sant'Anna-Zhao 2020 cross-section DID, 500 units | 1.0 |

```console
$ moon run cmd/main
$ moon run cmd/datasets
$ moon run cmd/did_binary
$ moon run cmd/did_cs
$ moon run cmd/did_multi
$ moon run cmd/did_cross_section
```

## Models

15 models, all reachable through the same `DoubleMLXxx::new(...).fit()` interface:

| Model | Score | Description |
|-------|-------|-------------|
| `DoubleMLPLR` | partialling-out | partially linear regression |
| `DoubleMLIRM` | ATE | interactive regression model |
| `DoubleMLPLIV` | partialling-out | partially linear IV regression |
| `DoubleMLIIVM` | LATE | interactive IV model |
| `DoubleMLDID` | observational | difference-in-differences |
| `DoubleMLSSM` | MAR | sample selection (missing-at-random) |
| `DoubleMLAPO` | APO | average potential outcome |
| `DoubleMLAPOS` | APOS | average potential outcome (share) |
| `DoubleMLPQ` | PQ | potential quantile |
| `DoubleMLQTE` | PQ | quantile treatment effect |
| `DoubleMLLPQ` | LPQ | local potential quantile (compliers) |
| `DoubleMLCVAR` | CVaR | conditional value-at-risk |
| `DoubleMLRDD` | (sharp / fuzzy) | regression discontinuity |
| `DoubleMLBLP` | BLP | best linear predictor |
| `DoubleMLPolicyTree` | (depth-N) | policy tree on weighted-variance-reduction gain |

## Design

* **Pure MoonBit hot path** — no Python FFI, no native add-ons. The only
  `moonbitlang/core` imports are `random`, `math`, and `bytes`.
* **Single shared `LinearRegression`** learner for all nuisance functions,
  with the predicted propensity clipped to `[propensity_clip, 1 - propensity_clip]`.
* **Closed-form `solve_spd`** via Cholesky + small ridge (`1e-10`) for numerical stability.
* **Kahan compensated summation** in `matmul`, `matvec`, `dot`, `mean`, and
  the variance estimator.
* **`panic_`-prefixed tests** are expected to abort; `check.mbt::require`
  raises a `SourceLoc`-tagged abort that the test framework reports as PASS.
* **Field names `train` / `test`** are reserved in MoonBit so the data
  containers use `train_idx` / `test_idx`.

## Supported backends

```console
moon test --target native  --deny-warn   # 215/215
moon test --target wasm-gc --deny-warn   # 215/215
moon test --target wasm    --deny-warn   # 215/215
moon test --target js      --deny-warn   # 215/215
```

`wasm-gc` is the project's `preferred_target`. The `cmd/main` driver
produces a native executable that runs all 6 estimators end-to-end.

## Python cross-check

Sixteen `validate_*_with_python.py` scripts in the project root re-derive
the hand-rolled reference for each model and compare against the MoonBit
output:

```console
$ for s in validate_*_with_python.py; do echo "=== $s ==="; python $s | tail -1; done
=== validate_blp_policy_with_python.py === BLP/PolicyTree reference checks passed
=== validate_bootstrap_with_python.py === Multipliers match: PASS
=== validate_did_with_python.py === PASS  |mb - handrolled_nrep5| (theta) = 1.29e-02 ...
=== validate_did_binary_with_python.py === Reference: run `moon run cmd/did_binary` for the MoonBit output.
=== validate_did_cross_section_with_python.py === Cross-section DID reference: PASS
=== validate_did_cs_with_python.py === Reference: run `moon run cmd/did_cs` for the MoonBit output.
=== validate_gain_statistics_with_python.py === Gain statistics match: PASS
=== validate_iivm_with_python.py === PASS  |mb - handrolled_nrep5| (theta) = 8.58e-03 ...
=== validate_irm_with_python.py === PASS  |mb - handrolled_nrep5| (theta) = 5.24e-02 ...
=== validate_padjust_with_python.py === Romano-Wolf reference matches: PASS
=== validate_pava_with_python.py === PAVA cross-check passed
=== validate_pliv_with_python.py === PASS  |mb - handrolled_nrep5| (theta) = 1.41e-01 ...
=== validate_quantile_with_python.py === reference checks passed
=== validate_rdd_with_python.py === RDD reference checks passed
=== validate_ssm_with_python.py === SSM reference checks passed
=== validate_with_python.py === Sanity check: true theta = 1.0 is inside every confidence interval.
```

## Limitations

* The default learner is `LinearRegression` (closed-form OLS, WLS, or
  sandwich / homoskedastic SE) and `LogisticRegression` (Newton-Raphson IRLS).
  Classifier learners (RandomForest, etc.) are not ported.
* Hyperparameter tuning, cluster-robust SE, sensitivity analysis, and
  IPW-normalized scores are not included.
* `PALM` (potential-augmented local M-estimation) and `LPLR` (local PLR)
  are not part of the upstream `doubleml` package and are not ported.

## Library helpers

```moonbit nocheck
// Deterministic chacha8 RNG keyed by an integer seed.
// Replaces the 3-line `seed_to_bytes -> Bytes::from_array -> chacha8`
// boilerplate that used to live in every test file.
let rng = @dml.chacha8_rng(3141)

// Stratum labels for stratified K-fold partitioning.
// Pairs with `stratified_kfold` in `resampling.mbt` to balance
// (G, T) cells across folds when used inside `DoubleMLDID`.
let strata : Array[Int] = []
for i = 0; i < n; i = i + 1 {
  strata = strata + [g_indicator[i] + 2 * t_indicator[i]]
}

// Propensity-score processing. Default clips to `[1e-2, 1 - 1e-2]`.
let psp = @dml.PSProcessor::new()                    // defaults
let psp = @dml.PSProcessor::new(config=@dml.PSProcessorConfig::new(clipping_threshold=0.05))
let out = psp.adjust_ps(ps_array, treatment_array)

// v0.14.0+: isotonic (PAVA) calibration of the propensity
// scores. The calibrated output is a step function from
// PAVA on `(ps, treatment)`, then clipped to
// `[clipping_threshold, 1 - clipping_threshold]`. Combine
// with `cv_calibration=true` for K-fold cross-validated
// predictions (matches upstream `cross_val_predict(cv=5)`).
let cfg = @dml.PSProcessorConfig::new(
  calibration_method="isotonic",  // v0.14.0+: PAVA fit
)
let psp_iso = @dml.PSProcessor::new(config=cfg)
let out_iso = psp_iso.adjust_ps(ps_array, treatment_array)

// 5-fold CV calibration with the deterministic kfold split.
let cfg_cv = @dml.PSProcessorConfig::new(
  calibration_method="isotonic",
  cv_calibration=true,
)
let psp_cv = @dml.PSProcessor::new(config=cfg_cv)
let out_cv = psp_cv.adjust_ps(ps_array, treatment_array)

// v0.15.0+: multiplier bootstrap for joint confidence
// intervals on `DoubleMLDIDMulti`. Draws `n_rep_boot` weight
// vectors from the chosen multiplier distribution ("normal"
// / "Bayes" / "wild") and computes per-cell t-statistics.
// Joint CIs use the empirical 95th percentile of the
// max-abs-t distribution as the critical value; pointwise
// CIs use 1.96. `joint=true` CIs are wider (more
// conservative).
let fitted = @dml.DoubleMLDIDMulti::new(data, n_folds=2, seed=3141).fit()
let booted = fitted.bootstrap(method_name="normal", n_rep_boot=500, seed=2024)
let ci_pw = booted.confint(joint=false)  // Wald-style (1.96 * se)
let ci_joint = booted.confint(joint=true)  // bootstrap critical value

// v0.16.0+: multiple-testing p-value adjustment.
// "romano-wolf" (default) requires the bootstrap; "holm",
// "bonferroni", "bh", "by" don't. Returns an Array[Double]
// of length n_combinations.
let pv_rw = booted.p_adjust(method_name="romano-wolf")
let pv_holm = booted.p_adjust(method_name="holm")
let pv_bonf = booted.p_adjust(method_name="bonferroni")
// v0.18.0+: FDR-controlling adjustments (Benjamini-Hochberg
// and Benjamini-Yekutieli). Both consume only the unadjusted
// p-values, so they don't require `bootstrap()`.
let pv_bh = fitted.p_adjust(method_name="bh")
let pv_by = fitted.p_adjust(method_name="by")

// v0.17.0+: gain statistics for sensitivity parameter
// benchmarks. Pass two `GainStatsSource` (one for the
// "long" model with all confounders, one for the
// "short" model with benchmark confounders excluded);
// returns `cf_y / cf_d / rho / delta_theta` per
// coefficient. Use as the upper bound on the
// sensitivity parameters in `sensitivity_analysis`.
let src_long = @dml.GainStatsSource::new(
  var_y_residuals_long, nu2_long, all_coef_long, n_rep, var_y,
)
let src_short = @dml.GainStatsSource::new(
  var_y_residuals_short, nu2_short, all_coef_short, n_rep, var_y,
)
let gs = @dml.gain_statistics(src_long, src_short)

// v0.19.0+: `from_blp(blp)` auto-populates a
// `GainStatsSource` from a fitted `DoubleMLBLP`.
// `var_y_residuals = rss / n_obs`,
// `nu2[k] = var_y_residuals / (n * se[k]^2)`,
// `all_coef = blp.coef()`, `var_y = blp.var_y()`.
let src = @dml.GainStatsSource::from_blp(blp_fitted)
```

## Release flow / verifier scratch

Each release produces two tracked artefacts under `_verify/`:

* `T###-verdict.md` — what was added, what was tested, known
  limitations, grade.
* `T###-commit-msg.txt` — the human-readable summary that goes
  into the git commit message.

All other `_verify/*` files are verifier scratch (build logs,
probe outputs, Python validator outputs, ad-hoc adversarial
test scripts) and are excluded by `.gitignore`. To drop the
  accumulated scratch on a fresh checkout, run
  `git clean -dfX _verify/`.

## License

Apache-2.0. See `LICENSE`.

## See also

* `CHANGELOG.md` — list of fixes (TODO #1–#11c)
* `AGENTS.md` — project conventions for AI agents
* `_verify/` — per-TODO verification reports
* `doubleml-for-py/` — upstream Python reference (sibling directory)
