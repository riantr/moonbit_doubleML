# moonbit_doubleML · Double / Debiased Machine Learning in MoonBit

A pure-MoonBit port of the
[`doubleml-for-py`](https://github.com/DoubleML/doubleml-for-py) Python
package — the Python ecosystem's most mature Double / Debiased Machine
Learning implementation — covering **all 19 models** in upstream
plus **3 MoonBit-specific extras** (`DoubleMLPLPR` for static panel
data, `DoubleMLLPLR` for binary outcomes, `DoubleMLDIDCSBinary` for
binary-outcome CS-DID).

Targets library authors and tool developers who need causal inference,
panel data estimation, instrumental variable estimation, regression
discontinuity, policy evaluation, or interpretable machine learning
inside the MoonBit ecosystem. Delivers a unified
`DoubleMLXxx::new(data, n_folds, n_rep, seed).fit()` API across all
22 estimators, robust variance estimation, propensity-score
processing, multiple-testing correction, and a reproducible validation
pipeline (23 / 23 Python reference scripts PASS) — on `native`,
`wasm`, `wasm-gc`, and `js` backends under `moon test --deny-warn`.

#Status

| Item | Value |
|------|-------|
| Repository | `https://github.com/riantr/moonbit_doubleML` |
| Author | `riantr` |
| License | MIT (port of upstream `doubleml-for-py`, BSD-3-Clause) |
| `moon.mod` version | **0.84.0** |
| Source layout | flat, `moonbit_doubleML/` (the library) |
| `.mbt` file count | 148 production files |
| Estimators | **22** `DoubleML*` estimator structs (PLR / IRM / PLIV / IIVM / DID family / SSM / APO(S) / PQ / QTE / LPQ / LPLR / CVAR / RDD / BLP / PLPR / PolicyTree) |
| Backends | `native`, `wasm`, `wasm-gc`, `js` — all pass `moon test --deny-warn` |
| Tests (native / wasm / js) | **614 / 614** |
| Tests (wasm-gc) | **620 / 620** (lib + 6 doc tutorials) |
| Python cross-checks | **23 / 23 PASS** (`validate_*_with_python.py`) |
| HTTP service | `examples/api_server/` — hand-rolled on `moonbitlang/async`, no third-party framework |

#Features

**Pure-MoonBit, all-4-backends port of `doubleml-for-py`** — 22 `DoubleML*`
estimators (`DoubleMLPLR`, `DoubleMLIRM`, `DoubleMLPLIV`, `DoubleMLIIVM`,
`DoubleMLDID`, `DoubleMLDIDBinary`, `DoubleMLDIDCS`,
`DoubleMLDIDCSBinary`, `DoubleMLDIDMulti`, `DoubleMLDIDCrossSection`,
`DoubleMLSSM`, `DoubleMLAPO`, `DoubleMLAPOS`, `DoubleMLPQ`,
`DoubleMLQTE`, `DoubleMLLPQ`, `DoubleMLLPLR`, `DoubleMLCVAR`,
`DoubleMLRDD`, `DoubleMLBLP`, `DoubleMLPLPR`, `DoubleMLPolicyTree`)
in 17 source files. The 19 marked *(upstream)* mirror the upstream
`doubleml-for-py` API; the 3 marked *(extra)* are MoonBit-specific
additions for static-panel PLR, partially-logistic regression, and
binary-outcome CS-DID.

**Unified API surface** — every estimator follows the same
`DoubleMLXxx::new(data, n_folds, n_rep, seed).fit()` shape and returns
the same `.coef()` / `.se()` / `.confint()` / `.bootstrap()` accessors.
No per-estimator interface drift.

**v0.84.0 memoization + vectorization expand** —
extends the v0.83.0 layer to five more estimators:
`DoubleMLAPOS`, `DoubleMLAPO`, `DoubleMLPQ`,
`DoubleMLQTE`, and `DoubleMLRDD`. Each gains the
standard `enable_memoize` / `disable_memoize` /
`clear_cache` / `has_cache` API. `DoubleMLAPO`
(cache stores LAST-rep `g_hat` / `m_hat` /
`psi_a` / `psi_b`; cache-hit path re-runs `var_est`
from cached values), `DoubleMLAPOS` (parent-level
`(coefs, ses)` cache plus `enable_memoize()`
forwarding to each child `DoubleMLAPO`),
`DoubleMLPQ` (cache stores `(theta, deriv, psi)`;
cache-hit skips the entire `solve_pq` -- propensity
cross-fit + bisection + 3x outcome cross-fits),
`DoubleMLQTE` (cache stores per-quantile per-
treatment `(theta1, psi1, deriv1, theta0, psi0,
deriv0)`; cache-hit skips the `2 * n_quantiles`
`solve_pq` loop), and `DoubleMLRDD` (no-fold
estimator: cache stores the entire `(coef, se,
n_local, residuals, psi_a)` tuple under a
(data, cutoff, bandwidth, fuzzy, cov_type, ml_g)
key; cache-hit skips all four `rdd_side` calls).
Per-fold residual loops in each are rewritten in
terms of the `vectorized.mbt` helpers
(`vector_subtract`, `vector_scale`, `vector_divide`,
`vector_multiply`, `vector_add`). Coverage: **20
of 22 estimators** now carry memoize + vectorize.
Remaining 2 small DID variants are queued for
v0.85.

**v0.83.0 memoization + vectorization expand** —
extends the v0.82.0 layer to five additional estimators:
`DoubleMLCVAR`, `DoubleMLSSM`, `DoubleMLBLP`, `DoubleMLPLPR`,
and `DoubleMLLPLR`. Each gains the standard `enable_memoize` /
`disable_memoize` / `clear_cache` / `has_cache` API; the
per-fold residual loops in `cvar.mbt` /
`cvar_inner_crossfit`, `ssm.mbt`'s MAR IPW psi_a / psi_b,
`blp_policy.mbt`'s residual / RSS computation,
`plpr.mbt`'s v_hat / u_hat / y_resid subtractions, and
`lplr.mbt`'s psi_b residual computation are now written in
terms of the `vectorized.mbt` helpers (`vector_subtract`,
`vector_scale`, `vector_divide`, `vector_multiply`,
`vector_add`). Coverage: **15 of 22 estimators** now have
memoize + vectorize. Remaining 7 estimators (`RDD`, `PQ`,
`QTE`, `APOS`, `APO`, plus 2 small DID variants) were
queued for v0.84.

**v0.82.0 memoization + vectorization expand (partial)** —
extends the v0.80.0 `enable_memoize()` / `disable_memoize()` /
`clear_cache()` / `has_cache()` API and the v0.81.0
`vector_subtract` / `vector_add` / `vector_scale` /
`matrix_predict` helpers to nine additional estimators:
`DoubleMLPLR`, `DoubleMLIIVM`, `DoubleMLPLIV`, `DoubleMLDID`,
`DoubleMLDIDBinary`, `DoubleMLDIDCS`, `DoubleMLDIDCSBinary`,
`DoubleMLDIDMulti`, `DoubleMLDIDCrossSection`, and
`DoubleMLLPQ`. The `FitCache` struct was extended to support
`n_rep > 1` and the cluster path via a `cluster_ids_hash`
field; `vectorized.mbt` gained `vector_multiply` and
`vector_divide` (eps=1e-10 clamp on denominator).
Coverage: 10 of 22 estimators now have memoize +
vectorize. Remaining 7 estimators (`RDD`, `PQ`, `QTE`,
`CVAR`, `SSM`, `BLP`, `LPLR`, `PLPR`, `APOS`, `APO`,
plus 2 small DID variants) were queued for v0.83.

**Cross-fitting infrastructure** — `kfold`, repeated cross-fitting,
stratified K-fold (`kfold_stratified`), `chacha8_rng`-based seeded
PRNG (`chacha8_rng(seed)`), and Kahan summation. Default `seed=3141`;
same seed yields byte-identical DGP outputs across runs.

**Propensity-score processor (`PSProcessor`)** — `clipping_threshold`
clipping, isotonic (PAVA) calibration, K-fold cross-validated (CV)
calibration. Plugs directly into `DoubleMLIRM` / `DoubleMLIIVM` /
`DoubleMLDID` and the rest of the IPW-based models.

**Robust variance & inference** — heteroskedasticity-consistent (HC)
standard errors, cluster-robust variance, multiplier bootstrap
confidence intervals, joint CIs, and Romano-Wolf multiple-testing
p-value adjustment. Reused via the `bootstrap.mbt` helper extracted
in v0.55.0.

**Cross-estimator joint sensitivity (v0.77.0+)** — the
`joint_sensitivity(inputs, alpha)` helper in `sensitivity.mbt`
takes `K >= 2` per-estimator summaries `(name, coef, se,
sigma_sq, rho, cf_y, cf_d)` and emits Bonferroni-corrected
joint CIs (`[min(per_estimator_lower), max(per_estimator_upper)]`)
plus the joint RV / RV_q (`min(per_estimator_rv)` /
`min(per_estimator_rv_q)`). Closes Cinelli & Hazlett (2020) §3.6
for the multi-estimator setting — when the same hypothesis is
estimated by two or more estimators, the joint CI controls the
family-wise error rate across the bundle.

**Coverage by class**:

- *Observational / quasi-experimental*: `DoubleMLDID`,
  `DoubleMLDIDBinary`, `DoubleMLDIDCS`, `DoubleMLDIDCSBinary`,
  `DoubleMLDIDMulti`, `DoubleMLDIDCrossSection`, `DoubleMLRDD`,
  `DoubleMLSSM`.
- *Strategy & distributional*: `DoubleMLAPO` / `DoubleMLAPOS`,
  `DoubleMLPQ`, `DoubleMLQTE`, `DoubleMLLPQ`, `DoubleMLCVAR`,
  `DoubleMLBLP`, `DoubleMLPolicyTree`.

**Reproducible DGPs + Python reference validation** — 23 Python
scripts (`validate_*_with_python.py`) drive 23 DGPs
(`plr_CCDDHNR`, `plr_turrell`, `plr_confounded`, `irm_discrete`,
`irm_heterogeneous`, `irm_confounded`, `iivm`, `pliv` /
`pliv_cluster`, `SSM`, `simple_rdd`, `DID SZ2020` / `CS2021`, etc.)
and check within-tolerance equivalence against the upstream Python
outputs. CI greps the trailing `PASS` line from each script.

**Docs & demos** — 6 `doc/<NNN_…>/` tutorials targeting `wasm-gc`,
plus 14 `examples/<bin>/` driver binaries (all listed in
`moon.work`), of which `examples/api_server/` is an HTTP service
built directly on `moonbitlang/async@0.20.3` — no third-party HTTP
framework is pulled in.

**Strict dependency hygiene** — only official `moonbitlang/*` packages
in the library. Non-official deps restricted to `riantr/*` (this
repo). Reproducible builds, minimal supply-chain surface.

**Learner injection via `LearnerDispatch`** — every estimator's
`new()` / `fit()` accept `ml_g` / `ml_m` / `ml_l` / `ml_r` typed
optionals. Default is `LearnerDispatch::linear_regression()` (OLS);
v0.62.0+ also accepts `LearnerDispatch::logistic_regression(LR)` for
LPLR's binary-classification slots. Built-in learners:
`LinearRegression`, `ConstantLearner`, `NoopLearner`,
`RFLearner` (Breiman 2001 regression), `GBLearner` (Friedman 2001
regression). `RFLearner` and `GBLearner` now reach the 5 specialised
internals — `DoubleMLDIDCrossSection::crossfit_nuisance`,
`DoubleMLDIDCSBinary::cs_bin_crossfit_nuisance`,
`DoubleMLPQ::solve_pq` / `DoubleMLQTE::solve_pq`,
`DoubleMLCVAR::cvar_inner_crossfit`, and
`DoubleMLLPLR::cross_fit_predict_dispatch` (binary classifier slots) /
`DoubleMLRDD::rdd_side` (kernel-weighted OLS for `ml_g = LinearRegression`,
unweighted fallback for other learners). Defaults preserve v0.61.0
byte-equality; non-default overrides change the IF and the coef.

#Quick Start

```console
$ moon test --deny-warn
Total tests: 485, passed: 485, failed: 0.

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

#Library Use

```moonbit nocheck
let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)  // x : Matrix, y / d : Array[Double]
let fitted = @moonbit_doubleML.DoubleMLPLR::new(data, n_folds=2, n_rep=1, seed=3141).fit()
let coef = fitted.coef()      // Double
let se   = fitted.se()        // Double
let (lo, hi) = fitted.confint()
```

Same shape for every other estimator — e.g.
`@moonbit_doubleML.DoubleMLIRM::new(data, ml_g?, ml_m?, n_folds?, n_rep?, seed?).
fit()`, `@moonbit_doubleML.DoubleMLDID::new(data, ml_g?, ml_m?, ...).fit()`.

#Examples

14 `examples/<bin>/` directories in `moon.work`. 13 run end-to-end on
synthetic DGPs: 12 are CLI-style numeric demos (print true-vs-estimated
θ and a 95 % CI); the 13th — `examples/api_server/` — is an HTTP
service. The 14th — `examples/consumer_demo/` — is the library-user
pattern that mirrors what an external `moon add riantr/moonbit_doubleML`
consumer would write.

| Driver | Model | DGP | True θ |
|--------|-------|-----|--------|
| `examples/main` | `DoubleMLPLR` + 11 others (IRM / PLIV / IIVM / DID / SSM / BLP / RDD / PQ / QTE / LPQ / PolicyTree) | Simple partially linear, `n=500`, `p=5` | 1.0 |
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
    -d '{"x":[[1.0,0.5],[2.0,1.5],[3.0,2.5],[4.0,3.5],[5.0,4.5],[6.0,5.5]],"y":[2.0,4.0,6.0,8.0,10.0,12.0],"d":[1.0,2.0,3.0,4.0,5.0,6.0],"n_folds":2,"seed":3141}'
{"estimator":"plr","coef":2,"se":0,"ci_lo":2,"ci_hi":2,"n_obs":6,"n_features":2}
```

The same `api_server.wasm` also runs under `moonrun --port 4000`
(see `examples/api_server/README.md` for the full curl recipe).
The service is built directly on `moonbitlang/async@0.20.3` —
no third-party HTTP framework is pulled in.

#Models

22 estimators (`DoubleML*` structs) in 22 files (one struct per file,
plus the supporting DGPs and score / nuisance kernels in 129 files
total), all reachable through the same `DoubleMLXxx::new(...).fit()`
interface. The 19 marked *(upstream)* mirror the upstream
`doubleml-for-py` API surface; the 3 *(extra)* rows are MoonBit
additions for static-panel PLR, partially-logistic regression, and
binary-outcome CS-DID:

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

#Project layout

```
moonbit_doubleML/        <- the library (moon.mod v0.80.0, 148 .mbt files)
  moonbit_doubleML.mbt   <- main re-export file (the import surface)
  ...                    <- one file per estimator + DGPs + score / nuisance kernels

doc/                     <- wasm-gc-targeted numbered tutorials
  001_introduction/
  ...
  006_python_check/

examples/                <- 14 driver binaries (all listed in moon.work)
  main/                  <- 12 estimators, one perfect-DGP run each
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

#Dependency rule (per `skills/moonbit_doubleML.md`)

- Only official `moonbitlang/*` packages.
- Non-official packages may only be `riantr/*` (this repo).
- Pin to the latest published version (e.g. `moonbitlang/async@0.20.3`).
- Consequence: `examples/api_server/` builds directly on
  `moonbitlang/async`'s raw `Server` API. No third-party HTTP
  framework is allowed.

#Determinism & validation

- All randomness flows through `chacha8_rng(seed)` (`seed.mbt`).
  Default `seed=3141`; same seed ⇒ byte-identical DGP outputs.
- Python reference scripts `validate_*_with_python.py` reproduce
  the upstream `doubleml-for-py` numbers. CI greps the trailing
  `PASS` line from each script.
- `dgp_recovery_test.mbt` enforces `|coef - theta| < MAX(MODEL_TOL=0.1,
  2.0 * handrolled_se)`. The tolerance is contractual.
- v0.62.0 verified counts: `moon test` 485 / 485 (native & wasm &
  js) and 491 / 491 (wasm-gc); `python _verify/run_all_validators.py`
  23 / 23 PASS in ~70 s. `moon fmt --check` is now clean (was
  failing on every release since v0.57.0).
- v0.63.0 verified counts: `moon test` 491 / 491 (native & wasm &
  js) and 497 / 497 (wasm-gc); 23 / 23 Python cross-validators PASS
  in ~90 s. Adds 6 new wbtests (`v063_wbtest.mbt`) covering
  APO learner plumbing + APOS bootstrap/confint + BLP plumbing.
- v0.74.0 verified counts: `moon test` 554 / 554 (native & wasm &
  js) and 560 / 560 (wasm-gc); 23 / 23 Python cross-validators PASS.
  Closes the cluster-aware sensitivity family with
  `sensitivity_analysis_cluster` on LPQ / PQ / QTE / APOS / SSM /
  BLP / CVaR (7 wbtests in `v074_wbtest.mbt`); 20/22 estimators
  now expose both IID and cluster-aware sensitivity.
- v0.77.0 verified counts: `moon test` 561 / 561 (native & wasm &
  js) and 567 / 567 (wasm-gc); 23 / 23 Python cross-validators PASS.
  Adds cross-estimator joint sensitivity (`joint_sensitivity` in
  `sensitivity.mbt`, 3 white-box tests in `joint_sensitivity_test.mbt`):
  per-estimator Bonferroni-corrected CIs plus cross-estimator
  joint CI / RV / RV_q via `min(per_estimator_*)` collapse
  (Cinelli & Hazlett 2020 §3.6 family setting).
- v0.78.0 verified counts: `moon test` 566 / 566 (native & wasm &
  js) and 572 / 572 (wasm-gc); 23 / 23 Python cross-validators PASS.
  Closes the v0.72-v0.74 cluster-aware sensitivity family for
  the kernel-weighted local-polynomial `DoubleMLRDD` estimator:
  extends `irm_style_sensitivity_cluster` (in `sensitivity.mbt`)
  with an optional `kernel_weights` parameter (default empty =
  uniform weights, v0.72 behavior); when non-empty, each
  observation's residual and Riesz row are scaled by the
  triangular kernel weight `w[k] = 1 - |u_k| / h` on the
  bandwidth-restricted sample before the cluster sum. Adds
  `DoubleMLRDD::sensitivity_analysis_cluster(cluster_ids, cf_y?,
  cf_d?) -> SensitivityResult` plus 5 white-box tests in
  `rdd_cluster_test.mbt` (smoke + sigma2-differs-from-IID +
  3 panic tests); 22 / 22 estimators now expose both IID and
  cluster-aware sensitivity.
- v0.83.0 verified counts: `moon test` 607 / 607 (native & wasm &
  js) and 613 / 613 (wasm-gc); 23 / 23 Python cross-validators
  PASS. Closes the v0.80/v0.81/v0.82 memoize + vectorize expand
  for `DoubleMLCVAR` (complete v0.82 partial: fix `pq_est`
  cache-hit path; cache also stores `ipw_vec`), `DoubleMLSSM`
  (complete v0.82 partial: add `memoize_enabled` / `fit_cache`
  struct fields correctly), `DoubleMLBLP` (single-pass OLS
  projection cached byte-for-byte), `DoubleMLPLPR` (clustered
  path: cache stores `(l_pred, m_pred, g_pred)` plus
  row-to-fold map; cache-hit path re-runs the cluster-robust
  SE pipeline from cached values), and `DoubleMLLPLR`
  (Newton-solved binary-outcome estimator: cache stores
  `(t_pred, m_pred, a_pred, beta_start)`; cache-hit path re-runs
  Newton + score + SE from cached values). Per-fold residual
  loops in each are rewritten in terms of the `vectorized.mbt`
  helpers (`vector_subtract`, `vector_scale`, `vector_divide`,
  `vector_multiply`, `vector_add`). 15 / 22 estimators now
  carry memoize + vectorize.
- v0.84.0 verified counts: `moon test` 614 / 614 (native & wasm &
  js) and 620 / 620 (wasm-gc); 23 / 23 Python cross-validators
  PASS. Closes the v0.80/v0.81/v0.82/v0.83 memoize + vectorize
  expand for `DoubleMLAPO` (clean add: cache stores LAST-rep
  `(g_hat, m_hat, psi_a, psi_b)`; cache-hit path re-runs
  `var_est` from cached values), `DoubleMLAPOS` (memoize
  forwarding: parent-level `(coefs, ses)` cache + `.enable_memoize()`
  forwarded to each child `DoubleMLAPO`), `DoubleMLPQ`
  (cache stores `(theta, deriv, psi, fold_ids)`; cache-hit
  skips the entire `solve_pq`), `DoubleMLQTE` (cache stores
  per-quantile per-treatment `(theta1, psi1, deriv1, theta0,
  psi0, deriv0)`; cache-hit skips the `2 * n_quantiles`
  `solve_pq` loop), and `DoubleMLRDD` (no-fold estimator:
  cache stores the entire `(coef, se, n_local, residuals,
  psi_a)` tuple under a (data, cutoff, bandwidth, fuzzy,
  cov_type, ml_g) key; cache-hit skips all four `rdd_side`
  calls). Per-fold residual loops in each are rewritten in
  terms of the `vectorized.mbt` helpers (`vector_subtract`,
  `vector_scale`, `vector_divide`, `vector_multiply`,
  `vector_add`). 20 / 22 estimators now carry memoize +
  vectorize.

#Attribution

`moonbit_doubleML` is a port of the upstream
[`DoubleML/doubleml-for-py`](https://github.com/DoubleML/doubleml-for-py)
package (BSD 3-Clause License). All 19 upstream models are faithfully
re-implemented in pure MoonBit with the same score formulae and
variance estimators; the 3 MoonBit-only additions (`DoubleMLPLPR`,
`DoubleMLLPLR`, `DoubleMLDIDCSBinary`) are extensions beyond the
upstream scope.

### Differences from upstream `doubleml-for-py`

- Native MoonBit package layout, type system, and test organization.
- Independent implementations of `Matrix`, linear / logistic
  regression, stratified K-fold, ChaCha8 PRNG, and Kahan summation
  in MoonBit; **no NumPy / scikit-learn dependency**.
- `DoubleMLData` / `DoubleMLXxx::new().fit()` as the canonical
  MoonBit-idiomatic API, with optional JSON in/out for native /
  wasm-gc / wasm / js backends (Serverless / Wasm / edge
  deployments).
- Behaviour-level parity check via the 23 Python reference scripts:
  `within-tolerance equivalence` rather than bit-exact re-implementation.
  This keeps the port resilient to upstream refactors.
- Strict dependency rule (see above): only `moonbitlang/*` official
  packages. Minimal supply-chain surface.

#Used By

- `examples/api_server/` — this repo's HTTP service.
- `examples/consumer_demo/` — minimal end-to-end PLR showing the
  consumer-side import pattern (`moon add riantr/moonbit_doubleML`).