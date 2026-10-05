# moonbit_doubleML - Double / Debiased Machine Learning in MoonBit

A pure-MoonBit port of the
[`doubleml-for-py`](https://github.com/DoubleML/doubleml-for-py) Python
package -- the Python ecosystem's most mature Double / Debiased Machine
Learning implementation -- covering **all 19 models** in upstream
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
pipeline (23 / 23 Python reference scripts PASS) -- on `native`,
`wasm`, `wasm-gc`, and `js` backends under `moon test --deny-warn`.

##Status

| Item | Value |
|------|-------|
| Repository | `https://github.com/riantr/moonbit_doubleML` |
| Author | `riantr` |
| License | MIT (port of upstream `doubleml-for-py`, BSD-3-Clause) |
| `moon.mod` version | **0.90.0** |
| Source layout | flat, `moonbit_doubleML/` (the library) |
| `.mbt` file count | **155** `.mbt` files (**62** production + **93** test) |
| Estimators | **22** `DoubleML*` estimator structs (PLR / IRM / PLIV / IIVM / DID family / SSM / APO(S) / PQ / QTE / LPQ / LPLR / CVAR / RDD / BLP / PLPR / PolicyTree) |
| Backends | `native`, `wasm`, `wasm-gc`, `js` -- all pass `moon test --deny-warn` |
| Tests (native / wasm / js) | **648 / 648** |
| Tests (wasm-gc) | **654 / 654** (lib + 6 doc tutorials) |
| Sandwich-variance coverage | **12 / 22** estimators expose `sandwich_se` / `cluster_sandwich_se` / `bias_corrected_coef` (v0.89.0) |
| Python cross-checks | **23 / 23 PASS** (`validate_*_with_python.py`) |
| HTTP service | `examples/api_server/` -- hand-rolled on `moonbitlang/async`, no third-party framework |

##Features

**Pure-MoonBit, all-4-backends port of `doubleml-for-py`** -- 22 `DoubleML*`
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

**Unified API surface** -- every estimator follows the same
`DoubleMLXxx::new(data, n_folds, n_rep, seed).fit()` shape and returns
the same `.coef()` / `.se()` / `.confint()` / `.bootstrap()` accessors.
No per-estimator interface drift.

**Cross-fitting infrastructure** -- `kfold`, repeated cross-fitting,
stratified K-fold (`kfold_stratified`), `chacha8_rng`-based seeded
PRNG (`chacha8_rng(seed)`), and Kahan summation. Default `seed=3141`;
same seed yields byte-identical DGP outputs across runs.

**Vectorised cross-fit helpers (v0.81.0+)** -- `vectorized.mbt`
exposes `matrix_predict` (Kahan-compensated `X @ weights + bias`),
`vector_subtract`, `vector_add`, and `vector_scale` as public
free functions. `DoubleMLIRM::fit` / `fit_cluster` /
`sensitivity_analysis` and the matching `DoubleMLPLR` paths now
route the per-observation residual extraction through
`vector_subtract` instead of an inlined per-iteration load /
subtract. The helpers are pure element-wise loop wrappers
today -- the public API is fixed so a v0.82+ release can swap
the bodies to a SIMD-vectorised backend (or external call to
a BLAS-style library) without breaking callers.

**Propensity-score processor (`PSProcessor`)** -- `clipping_threshold`
clipping, isotonic (PAVA) calibration, K-fold cross-validated (CV)
calibration. Plugs directly into `DoubleMLIRM` / `DoubleMLIIVM` /
`DoubleMLDID` and the rest of the IPW-based models.

**Robust variance & inference** -- heteroskedasticity-consistent (HC)
standard errors, cluster-robust variance, multiplier bootstrap
confidence intervals, joint CIs, and Romano-Wolf multiple-testing
p-value adjustment. Reused via the `bootstrap.mbt` helper extracted
in v0.55.0.

**Huber-White sandwich API (v0.79.0+, expanded through v0.89.0)** --
`sandwich.mbt` provides the `sandwich_variance_hc0` / `_hc1` /
`_hc2` / `_hc3` free functions, `cluster_sandwich_variance`, and
`bias_corrected_theta`, all driven by the `SandwichKind` enum. From
v0.86.0 they are reachable through ONE shared
`sandwich_variance(kind, psi_a, psi, m_inv, n_obs, n_params)`
dispatch, and **12 of the 22** `DoubleML*` estimators expose the
estimator-level triple `sandwich_se(kind)` /
`cluster_sandwich_se(cluster_ids)` / `bias_corrected_coef()`:
`DoubleMLIRM`, `DoubleMLPLR`, `DoubleMLIIVM`, `DoubleMLPLIV`,
`DoubleMLDID`, `DoubleMLDIDBinary`, `DoubleMLDIDCrossSection`,
`DoubleMLDIDCSBinary`, `DoubleMLCVAR`, `DoubleMLSSM`,
`DoubleMLAPO`, `DoubleMLPLPR`. (`DoubleMLRDD` and `DoubleMLBLP`
already emit HC0 intervals by calling
`LinearRegression::sandwich_se` internally.) Note the convention:
the per-observation score is `psi[i] = psi_at(coef, psi_a, psi_b)[i]`
= `coef * psi_a[i] + psi_b[i]` -- the estimating function
`f(theta) = E[theta * psi_a + psi_b]` that `var_est` inverts, whose
root is `theta_hat = -mean(psi_b) / mean(psi_a)` -- and
`M_inv = [[1 / mean(psi_a)]] = 1 / (d f / d theta)`. Only
`M_inv[0, 0]^2` enters the variance. The HC2 / HC3 leverage is the
constant mean-regression diagonal `h_ii = 1 / n_obs` (fixed in
v0.88.0), so `HC2 == HC1` and `HC3 == HC1^2 / HC0` and the ordering
is `HC1 == HC2 > HC0` and `HC3 > HC2` -- a monotonic widening.
See `expand_v090_test.mbt` for the score-order evidence and for the
still-open factor between `se()` and `sandwich_se(HC0)`.

**`DoubleMLRDD` is not in that list, and does not join it (v0.96.0).**
It has its own `hac_se(kind)` / `cluster_hac_se(cluster_ids)` /
`leverage()` / `n_local_params()`, and it is deliberately NOT named
`sandwich_se`, because the two HC0 formulas are different algebras.
RDD's is a kernel-weighted local-regression sandwich,
`sum_k w_k^2 * m_k^2 * e_k^2` with `m_k` the intercept row of a full
`p1 x p1` normal inverse and no `1 / n^2` divisor; the shared helper
is a scalar-Jacobian MEAN-moment sandwich,
`M_inv[0,0]^2 * sum_i psi[i]^2 / n^2`. Feeding RDD's influence function
`psi_a[k] * residuals[k]` into the pre-v0.91.0 accumulator
`sum (psi_a * psi)^2` yields `sum psi_a[k]^4 * e_k^2` -- a fourth
power against RDD's second -- and the resulting error is a plausible
`1e-2`, not an obvious one. RDD also has no DML moment, hence no
scalar `M_inv` to supply, and its HC2 / HC3 leverage is a real WLS hat
diagonal rather than the shared helper's constant `1 / n`, so
`HC2 == HC1` does not carry over. The anchor is
`hac_se(HC0) == se()` bit-identically on a `cov_type = "HC0"` fit; on
a `"homoskedastic"` fit it is deliberately not, and `hac_se` refuses a
non-OLS learner and a `fuzzy = true` fit rather than returning a
number under the wrong name. Sandwich coverage above is unchanged --
RDD is not sandwich coverage. See `CHANGELOG.md` [0.96.0] and
`expand_v096_test.mbt`.

**Coverage by class**:

- *Observational / quasi-experimental*: `DoubleMLDID`,
  `DoubleMLDIDBinary`, `DoubleMLDIDCS`, `DoubleMLDIDCSBinary`,
  `DoubleMLDIDMulti`, `DoubleMLDIDCrossSection`, `DoubleMLRDD`,
  `DoubleMLSSM`.
- *Strategy & distributional*: `DoubleMLAPO` / `DoubleMLAPOS`,
  `DoubleMLPQ`, `DoubleMLQTE`, `DoubleMLLPQ`, `DoubleMLCVAR`,
  `DoubleMLBLP`, `DoubleMLPolicyTree`.

**Reproducible DGPs + Python reference validation** -- 23 Python
scripts (`validate_*_with_python.py`) drive 23 DGPs
(`plr_CCDDHNR`, `plr_turrell`, `plr_confounded`, `irm_discrete`,
`irm_heterogeneous`, `irm_confounded`, `iivm`, `pliv` /
`pliv_cluster`, `SSM`, `simple_rdd`, `DID SZ2020` / `CS2021`, etc.)
and check within-tolerance equivalence against the upstream Python
outputs. CI greps the trailing `PASS` line from each script.

**Docs & demos** -- 6 `doc/<NNN_...>/` tutorials targeting `wasm-gc`,
plus 14 `examples/<bin>/` driver binaries (all listed in
`moon.work`), of which `examples/api_server/` is an HTTP service
built directly on `moonbitlang/async@0.20.3` -- no third-party HTTP
framework is pulled in.

**Strict dependency hygiene** -- only official `moonbitlang/*` packages
in the library. Non-official deps restricted to `riantr/*` (this
repo). Reproducible builds, minimal supply-chain surface.

**Learner injection via `LearnerDispatch`** -- every estimator's
`new()` / `fit()` accept `ml_g` / `ml_m` / `ml_l` / `ml_r` typed
optionals. Default is `LearnerDispatch::linear_regression()` (OLS);
v0.62.0+ also accepts `LearnerDispatch::logistic_regression(LR)` for
LPLR's binary-classification slots. Built-in learners:
`LinearRegression`, `ConstantLearner`, `NoopLearner`,
`RFLearner` (Breiman 2001 regression), `GBLearner` (Friedman 2001
regression). `RFLearner` and `GBLearner` now reach the 5 specialised
internals -- `DoubleMLDIDCrossSection::crossfit_nuisance`,
`DoubleMLDIDCSBinary::cs_bin_crossfit_nuisance`,
`DoubleMLPQ::solve_pq` / `DoubleMLQTE::solve_pq`,
`DoubleMLCVAR::cvar_inner_crossfit`, and
`DoubleMLLPLR::cross_fit_predict_dispatch` (binary classifier slots) /
`DoubleMLRDD::rdd_side` (kernel-weighted OLS for `ml_g = LinearRegression`,
unweighted fallback for other learners). Defaults preserve v0.61.0
byte-equality; non-default overrides change the IF and the coef.

##Quick Start

```console
$ moon test --deny-warn
Total tests: 593, passed: 593, failed: 0.

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

##Library Use

```moonbit nocheck
let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)  // x : Matrix, y / d : Array[Double]
let fitted = @moonbit_doubleML.DoubleMLPLR::new(data, n_folds=2, n_rep=1, seed=3141).fit()
let coef = fitted.coef()      // Double
let se   = fitted.se()        // Double
let (lo, hi) = fitted.confint()
```

Same shape for every other estimator -- e.g.
`@moonbit_doubleML.DoubleMLIRM::new(data, ml_g?, ml_m?, n_folds?, n_rep?, seed?).
fit()`, `@moonbit_doubleML.DoubleMLDID::new(data, ml_g?, ml_m?, ...).fit()`.

##Examples

14 `examples/<bin>/` directories in `moon.work`. 13 run end-to-end on
synthetic DGPs: 12 are CLI-style numeric demos (print true-vs-estimated
theta and a 95 % CI); the 13th -- `examples/api_server/` -- is an HTTP
service. The 14th -- `examples/consumer_demo/` -- is the library-user
pattern that mirrors what an external `moon add riantr/moonbit_doubleML`
consumer would write.

| Driver | Model | DGP | True theta |
|--------|-------|-----|--------|
| `examples/main` | `DoubleMLPLR` + 11 others (IRM / PLIV / IIVM / DID / SSM / BLP / RDD / PQ / QTE / LPQ / PolicyTree) | Simple partially linear, `n=500`, `p=5` | 1.0 |
| `examples/datasets` | `DoubleMLPLR` + `DoubleMLIRM` | Synthetic 401(k)-style, `n=5000`, 9 controls | 1.5 |
| `examples/did_binary` | `DoubleMLDIDBinary` | 2-period panel DID, 400 units | 1.0 |
| `examples/did_cs` | `DoubleMLDIDCS` | Staggered CS-DID, 4 cohorts x 4 periods | 1.0 |
| `examples/did_cs_binary` | `DoubleMLDIDCSBinary` | Staggered CS-DID with binary outcome | 1.0 |
| `examples/did_multi` | `DoubleMLDIDMulti` | Top-level multi-period DID + aggregation | 1.0 |
| `examples/did_cross_section` | `DoubleMLDIDCrossSection` | Sant'Anna-Zhao 2020 cross-section DID, 500 units | 1.0 |
| `examples/plpr`, `examples/lplr` | `DoubleMLPLPR` / `DoubleMLLPLR` | Static-panel PLR / partially logistic regression | 1.0 |
| `examples/apos`, `examples/cvar` | `DoubleMLAPOS` / `DoubleMLCVAR` | APO policy score / CVaR | 1.0 |
| `examples/fuzz` | wrappers | Random-property fuzz harness across 12 surfaces | n/a |
| `examples/consumer_demo` | library-user pattern | Minimal end-to-end PLR (no estimator-specific extras) | 1.0 |
| `examples/api_server` | `DoubleMLPLR` + `DoubleMLIRM` | HTTP service -- see below | n/a |

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
The service is built directly on `moonbitlang/async@0.20.3` --
no third-party HTTP framework is pulled in.

##Models

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

##Project layout

```
moonbit_doubleML/        <- the library (moon.mod v0.81.0, 144 .mbt files)
  moonbit_doubleML.mbt   <- main re-export file (the import surface)
  ...                    <- one file per estimator + DGPs + score / nuisance kernels
  vectorized.mbt         <- v0.81.0+ vectorised cross-fit helpers

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

##Dependency rule (per `skills/moonbit_doubleML.md`)

- Only official `moonbitlang/*` packages.
- Non-official packages may only be `riantr/*` (this repo).
- Pin to the latest published version (e.g. `moonbitlang/async@0.20.3`).
- Consequence: `examples/api_server/` builds directly on
  `moonbitlang/async`'s raw `Server` API. No third-party HTTP
  framework is allowed.

##Determinism & validation

- All randomness flows through `chacha8_rng(seed)` (`seed.mbt`).
  Default `seed=3141`; same seed => byte-identical DGP outputs.
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
- v0.64.0 verified counts: `moon test` 500 / 500 (native, wasm, js)
  and 506 / 506 (wasm-gc); 23 / 23 Python cross-validators PASS in
  ~73 s. Adds `bootstrap()` to 8 remaining estimators (SSM, DID,
  DIDBinary, DIDCSBinary, LPQ, PQ, QTE, DIDCS, BLP) via four new
  shared inner helpers in `bootstrap_helper.mbt`. RDD and
  PolicyTree bootstrap deferred to v0.65.0 (kernel-weighted n_local
  IF and tree IF need a different multiplier formula).
- v0.65.0 verified counts: `moon test` 506 / 506 (native, wasm, js)
  and 512 / 512 (wasm-gc); 23 / 23 Python cross-validators PASS in
  ~107 s. Adds `DoubleMLAPO::fit_cluster` (with `DoubleMLAPOS`
  inheriting the cluster dispatch transparently) and `tune()` on
  IRM / PLIV / IIVM / APO. PQ / QTE `fit_cluster` deferred to
  v0.66.0 (`solve_pq` bisection requires a folds-override refactor
  for true cluster-aware cross-fitting).
- v0.66.0 verified counts: `moon test` 517 / 517 (native, wasm, js)
  and 523 / 523 (wasm-gc); 23 / 23 Python cross-validators PASS in
  ~48 s. Adds `sensitivity_analysis()` on 7 IRM-style estimators
  (PLR / IRM / PLIV / IIVM / APO / DID / DIDBinary / DIDCSBinary)
  via a shared `irm_style_sensitivity` helper; `confint(joint=true)`
  on 3 multi-theta estimators (APOS / QTE / DIDCS) using a
  max-|t|-bootstrap critical value. Sensitivity on LPQ / PQ /
  QTE / SSM / RDD / BLP / PolicyTree and PQ / QTE `fit_cluster`
  deferred to v0.67.0.
- v0.67.0 verified counts: `moon test` 522 / 522 (native, wasm, js)
  and 528 / 528 (wasm-gc); 23 / 23 Python cross-validators PASS in
  ~47 s. Refactors `solve_pq` to accept `folds?` and adds
  `fit_cluster` on `DoubleMLPQ` / `DoubleMLQTE` (cluster-aware
  folds + unit-level cluster-robust SE). Adds `confint(joint?)`
  API parity to 9 single-theta estimators. Adds
  `sensitivity_analysis()` on LPQ / PQ via a shared
  `single_psi_sensitivity` helper (centered-IF form).
- v0.68.0 verified counts: `moon test` 524 / 524 (native, wasm, js)
  and 530 / 530 (wasm-gc); 23 / 23 Python cross-validators PASS in
  ~47 s. Adds `sensitivity_analysis()` on SSM (psi_a = -1,
  residuals = y - g_d1_hat) and APOS (per-level re-fit pattern).
  DIDCS / BLP / RDD / PolicyTree sensitivity deferred to v0.69.0+
  (each requires a structural IF / nuisance-persistence plumbing
  beyond the shared helpers already in place).
- v0.69.0 verified counts: `moon test` 528 / 528 (native, wasm, js)
  and 534 / 534 (wasm-gc); 23 / 23 Python cross-validators PASS.
  Closes the v0.69.0 sensitivity cycle: BLP (closed-form OLS
  precision matrix), DIDCS (per-cell long-format panel),
  RDD (kernel-weighted local polynomial), and PolicyTree
  (per-leaf DFS IRM-style decomposition).
- v0.86.0 verified counts: `moon test` 623 / 623 (native, wasm, js)
  and 629 / 629 (wasm-gc); 23 / 23 Python cross-validators PASS.
  Adds the shared `sandwich_variance(kind, ...)` dispatch to
  `sandwich.mbt` and the `sandwich_se(kind)` /
  `cluster_sandwich_se(cluster_ids)` / `bias_corrected_coef()`
  triple on `DoubleMLIIVM`, `DoubleMLPLIV`, `DoubleMLDID`, and
  `DoubleMLCVAR` (coverage 2 -> 6 of 22). `DoubleMLLPQ` is
  deliberately skipped: its Jacobian `deriv` is a `fit()` local and
  is never persisted, and its `psi` is the centered check function
  at the bisection root with no `coef * psi_a + psi_b` split, so
  neither `psi_a` nor `M_inv` is recoverable post-fit. The 6 new
  white-box tests assert the HC1 `sqrt(n/(n-1))` identity, the
  independently recomputed HC0 variance, the leverage-driven
  ordering, exact singleton-cluster equality with the IID HC0, and
  the bias-correction identity -- not just finiteness.
- v0.90.0 verified counts: `moon test` 648 / 648 (native, wasm, js)
  and 654 / 654 (wasm-gc). **BREAKING NUMERICAL CHANGE:**
  `sandwich_se` / `cluster_sandwich_se` and every multiplier
  `bootstrap()` t-stat change for the 11 affected estimators; `se()`
  is unchanged and remains the reference. The sandwich family and
  the bootstrap evaluated `E[psi_a + theta * psi_b]`, a different
  function from `var_est`'s `E[theta * psi_a + psi_b]` whose root is
  not `theta_hat`; on a fixed DGP the resulting `sandwich_se(HC0)`
  was off by up to ~1100x. v0.90.0 adds one `psi_at(coef, psi_a,
  psi_b)` helper in `sandwich.mbt` and routes all 13 psi-construction
  sites through it. `DoubleMLDIDCrossSection` is deliberately NOT
  routed: it is a projection (`argmin_theta`) estimator with the
  offset / slope roles inverted and its own `se` formula.
  `DoubleMLLPLR` also persists its IF components in the inverted
  (offset, slope) order and is handled by passing the two arrays
  swapped at its single call site -- its bootstrap output is
  bit-identical to v0.89.0. (The list above was not backfilled for
  v0.70-v0.85 or v0.87-v0.89; see `CHANGELOG.md` for those entries.)

##Attribution

`moonbit_doubleML` is a port of the upstream
[`DoubleML/doubleml-for-py`](https://github.com/DoubleML/doubleml-for-py)
package (BSD 3-Clause License). All 19 upstream models are faithfully
re-implemented in pure MoonBit with the same score formulae and
variance estimators; the 3 MoonBit-only additions (`DoubleMLPLPR`,
`DoubleMLLPLR`, `DoubleMLDIDCSBinary`) are extensions beyond the
upstream scope.

#### Differences from upstream `doubleml-for-py`

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

##Used By

- [`riantr/pyroduct`](https://mooncakes.io/docs/riantr/pyroduct) --
  downstream consumer that models Ren Yongxiang's MA thesis
  (Gadamer/Habermas, Shanghai Academy of Social Sciences 2008)
  plus its appendix as runnable multi-agent state machines. Its
  `dmlref` package cross-checks its own from-scratch DoubleML
  PLR against `riantr/moonbit_doubleML` v0.64.0+: same nuisance,
  `theta` delta 0.017, `se` delta 0.001. Source lives on
  [`gitee.com/ren-yongxiang/pyroduct`](https://gitee.com/ren-yongxiang/pyroduct).
- `examples/api_server/` -- this repo's HTTP service.
- `examples/consumer_demo/` -- minimal end-to-end PLR showing the
  consumer-side import pattern (`moon add riantr/moonbit_doubleML`).