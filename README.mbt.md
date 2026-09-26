# riantr/moonbit_doubleML · Double / Debiased Machine Learning in MoonBit

Pure-MoonBit port of the
[`doubleml`](https://github.com/DoubleML/doubleml-for-py) Python package,
covering all 19 models in upstream `doubleml-for-py` plus
3 MoonBit-specific extras (`DoubleMLPLPR` for static panel data,
`DoubleMLLPLR` for binary outcomes, `DoubleMLDIDCSBinary` for
binary-outcome CS-DID).

## Status

| Item | Value |
|------|-------|
| Source file count | 110 production `.mbt` (flat layout, no sub-folders) |
| Estimators | **22** `DoubleML*` structs in **17** files (19 upstream + 3 extras) |
| Tests | **401 / 401** on `native`, `wasm`, `js` (390 blackbox + 11 whitebox: 5 on `kfold`, 6 on `matrix`); **407 / 407** on `wasm-gc` (lib + 6 doc tutorials) |
| Warnings | 0 (under `moon test --deny-warn`) |
| Python cross-checks | 23 / 23 PASS |
| HTTP service | `examples/api_server/` — hand-rolled, no third-party framework |
| License | Apache-2.0 |

## Quick start

```console
$ moon test --deny-warn
Total tests: 390, passed: 390, failed: 0.

$ moon run examples/main
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

14 `examples/<bin>/` directories in `moon.work`. 13 run
end-to-end on synthetic DGPs: 12 are CLI-style numeric demos
(print true-vs-estimated θ and a 95% CI); the 13th —
`examples/api_server/` — is an HTTP service. The 14th —
`examples/consumer_demo/` — is the library-user pattern that
mirrors what an external `moon add riantr/moonbit_doubleML`
consumer would write.

| Driver | Model | DGP | True θ |
|--------|-------|-----|--------|
| `examples/main` | `DoubleMLPLR` (and 5 others) | Simple partially linear, `n=500`, `p=5` | 1.0 |
| `examples/datasets` | `DoubleMLPLR` + `DoubleMLIRM` | Synthetic 401(k)-style, `n=5000`, 9 controls | 1.5 |
| `examples/did_binary` | `DoubleMLDIDBinary` | 2-period panel DID, 400 units | 1.0 |
| `examples/did_cs` | `DoubleMLDIDCS` | Staggered CS-DID, 4 cohorts × 4 periods | 1.0 |
| `examples/did_cs_binary` | `DoubleMLDIDCSBinary` | Staggered CS-DID with binary outcome | 1.0 |
| `examples/did_multi` | `DoubleMLDIDMulti` | Top-level multi-period DID + aggregation | 1.0 |
| `examples/did_cross_section` | `DoubleMLDIDCrossSection` | Sant'Anna-Zhao 2020 cross-section DID, 500 units | 1.0 |
| `examples/plpr`, `examples/lplr` | `DoubleMLPLPR` / `DoubleMLLPLR` | Static-panel PLR / partially logistic regression | 1.0 |
| `examples/apos`, `examples/cvar` | `DoubleMLAPOS` / `DoubleMLCVAR` | APO policy score / CVaR | 1.0 |
| `examples/fuzz` | wrappers | Random-property fuzz harness across 12 surfaces | n/a |
| `examples/consumer_demo` | library-user pattern | Minimal end-to-end PLR (no estimator-specific extras) | 1.0 |
| `examples/api_server` | `DoubleMLPLR` + `DoubleMLIRM` | HTTP service — see below | n/a |

CLI demos:

```console
$ moon run examples/main
$ moon run examples/datasets
$ moon run examples/did_binary
$ moon run examples/did_cs
$ moon run examples/did_multi
$ moon run examples/did_cross_section
```

HTTP service:

```console
$ moon build --target native examples/api_server
$ _build/native/debug/build/api_server/api_server.exe        # listens on 127.0.0.1:4000

$ curl -s http://127.0.0.1:4000/healthz
{"status":"ok"}

$ curl -s -X POST http://127.0.0.1:4000/fit/plr \
    -H 'Content-Type: application/json' \
    -d '{"x":[[1.0,0.5],[2.0,1.5]],"y":[2.0,4.0],"d":[1.0,2.0],"n_folds":2,"seed":3141}'
{"estimator":"plr","coef":2,"se":0,"ci_lo":2,"ci_hi":2,"n_obs":2,"n_features":2}
```

The same `api_server.wasm` also runs under `moonrun --port 4000`
(see `examples/api_server/README.md` for the full curl recipe).
The service is built directly on `moonbitlang/async@0.20.3` —
no third-party HTTP framework is pulled in.

## Models

22 estimators (`DoubleML*` structs) in 17 files, all reachable through
the same `DoubleMLXxx::new(...).fit()` interface. The 19 marked
`(upstream)` mirror the upstream `doubleml-for-py` API surface; the 3
`(extra)` rows are MoonBit additions for static-panel PLR, partially
logistic regression, and binary-outcome CS-DID:

| Model | Score | Description |
|-------|-------|-------------|
| `DoubleMLPLR` | partialling-out | partially linear regression *(upstream)* |
| `DoubleMLIRM` | ATE | interactive regression model *(upstream)* |
| `DoubleMLPLIV` | partialling-out | partially linear IV regression *(upstream)* |
| `DoubleMLIIVM` | LATE | interactive IV model *(upstream)* |
| `DoubleMLDID` | observational | difference-in-differences *(upstream)* |
| `DoubleMLDIDBinary` | observational | DID with binary outcome *(upstream)* |
| `DoubleMLDIDCS` | observational | DID with staggered adoption (Callaway-Sant'Anna) *(upstream)* |
| `DoubleMLDIDCSBinary` | observational | CS-DID with binary outcome *(extra)* |
| `DoubleMLDIDMulti` | observational | multi-period DID with group-time ATT aggregation *(upstream)* |
| `DoubleMLDIDCrossSection` | observational | Sant'Anna-Zhao 2020 cross-section DID *(upstream)* |
| `DoubleMLSSM` | MAR | sample selection (missing-at-random) *(upstream)* |
| `DoubleMLAPO` | policy score | average prescriptive effect *(upstream)* |
| `DoubleMLAPOS` | policy score | APO with stratified treatment *(upstream)* |
| `DoubleMLPQ` | quantile | potential quantile *(upstream)* |
| `DoubleMLQTE` | quantile | quantile treatment effect *(upstream)* |
| `DoubleMLLPQ` | local polynomial | local potential quantile *(upstream)* |
| `DoubleMLLPLR` | partialling-out | partially logistic regression, Liu-Zhang-Zhou 2021 *(extra)* |
| `DoubleMLCVAR` | CVaR | conditional value-at-risk *(upstream)* |
| `DoubleMLRDD` | observational | regression discontinuity *(upstream)* |
| `DoubleMLBLP` | IV | best linear predictor of treatment effect *(upstream)* |
| `DoubleMLPLPR` | partialling-out | partially linear panel regression, Clarke-Polselli 2025 *(extra)* |
| `DoubleMLPolicyTree` | policy | policy tree *(upstream)* |

## Project layout

```
moonbit_doubleML/        <- the library (moon.mod v0.52.0, 110 .mbt files)
  moonbit_doubleML.mbt   <- main re-export file (the import surface)
  ...                    <- one file per estimator + DGPs + score / nuisance kernels

doc/                     <- wasm-gc-targeted numbered tutorials
  001_introduction/
  ...
  006_python_check/

examples/                <- 14 driver binaries (all listed in moon.work)
  main/                  <- 6 estimators, one perfect-DGP run each
  datasets/              <- 401(k)-style ATE / ATT recovery
  did_binary/            <- 2-period panel DID
  did_cs/                <- staggered CS-DID
  did_cs_binary/         <- staggered CS-DID (binary outcome)
  did_multi/             <- multi-period DID aggregation
  did_cross_section/     <- Sant'Anna-Zhao 2020
  plpr/, lplr/, apos/,   <- single-estimator focused demos
  cvar/, fuzz/
  consumer_demo/         <- library-user pattern (`example/consumer_demo`)
  api_server/            <- HTTP service built on `moonbitlang/async`

moon.work                <- 15-member workspace aggregator
AGENTS.md                <- this file (per moonbit agent convention)
skills/moonbit_doubleML.md  <- agent skill: API surface + anti-patterns
```

## Dependency rule (per `skills/moonbit_doubleML.md`)

- Only official `moonbitlang/*` packages.
- Non-official packages may only be `riantr/*` (this repo).
- Pin to the latest published version (e.g. `moonbitlang/async@0.20.3`).
- Consequence: `examples/api_server/` builds directly on
  `moonbitlang/async`'s raw `Server` API. No third-party HTTP
  framework is allowed.

## Determinism & validation

- All randomness flows through `chacha8_rng(seed)` (`seed.mbt`).
  Default `seed=3141`; same seed ⇒ byte-identical DGP outputs.
- Python reference scripts `validate_*_with_python.py` reproduce
  the upstream `doubleml-for-py` numbers. CI greps the trailing
  `PASS` line from each script.
- `dgp_recovery_test.mbt` enforces `|coef - theta| < MAX(MODEL_TOL=0.1,
  2.0 * handrolled_se)`. The tolerance is contractual.

