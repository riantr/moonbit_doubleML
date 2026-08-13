# mavis/dml — Double / Debiased Machine Learning in MoonBit

Pure-MoonBit port of the
[`doubleml`](https://github.com/DoubleML/doubleml-for-py) Python package,
covering all 15 models currently in upstream.

## Status

| Item | Value |
|------|-------|
| Source file count | 60 (30 production + 30 test) |
| Models ported | 15 / 15 |
| Tests | **150 / 150** on all 4 backends (native, wasm-gc, wasm, js) |
| Warnings | 0 (under `moon test --deny-warn`) |
| Python cross-checks | 9 / 9 PASS |
| License | Apache-2.0 |

## Quick start

```console
$ moon test --deny-warn
Total tests: 150, passed: 150, failed: 0.

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

Five `cmd/*/main.mbt` drivers run end-to-end on synthetic DGPs. Each
prints the true vs. estimated coefficient plus a 95% CI:

| Driver | Model | DGP | True θ |
|--------|-------|-----|--------|
| `cmd/main` | `DoubleMLPLR` (and 5 others) | Simple partially linear, `n=500`, `p=5` | 1.0 |
| `cmd/datasets` | `DoubleMLPLR` + `DoubleMLIRM` | Synthetic 401(k)-style, `n=5000`, 9 controls | 1.5 |
| `cmd/did_binary` | `DoubleMLDIDBinary` | 2-period panel DID, 400 units | 1.0 |
| `cmd/did_cs` | `DoubleMLDIDCS` | Staggered CS-DID, 4 cohorts × 4 periods | 1.0 |
| `cmd/did_multi` | `DoubleMLDIDMulti` | Top-level multi-period DID + aggregation | 1.0 |

```console
$ moon run cmd/main
$ moon run cmd/datasets
$ moon run cmd/did_binary
$ moon run cmd/did_cs
$ moon run cmd/did_multi
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
moon test --target native  --deny-warn   # 115/115
moon test --target wasm-gc --deny-warn   # 115/115
moon test --target wasm    --deny-warn   # 115/115
moon test --target js      --deny-warn   # 115/115
```

`wasm-gc` is the project's `preferred_target`. The `cmd/main` driver
produces a native executable that runs all 6 estimators end-to-end.

## Python cross-check

Nine `validate_*_with_python.py` scripts in the project root re-derive
the hand-rolled reference for each model and compare against the MoonBit
output:

```console
$ for s in validate_*_with_python.py; do echo "=== $s ==="; python $s | tail -1; done
=== validate_blp_policy_with_python.py === BLP/PolicyTree reference checks passed
=== validate_did_with_python.py === PASS  |mb - handrolled_nrep5| (theta) = 1.29e-02 ...
=== validate_iivm_with_python.py === PASS  |mb - handrolled_nrep5| (theta) = 8.58e-03 ...
=== validate_irm_with_python.py === PASS  |mb - handrolled_nrep5| (theta) = 5.24e-02 ...
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
