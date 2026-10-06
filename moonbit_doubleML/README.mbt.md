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
| `moon.mod` version | **0.107.0** |
| Source layout | flat, `moonbit_doubleML/` (the library) |
| `.mbt` file count | 176 in the library (87 production + 89 test) |
| Estimators | **22** `DoubleML*` estimator structs (PLR / IRM / PLIV / IIVM / DID family / SSM / APO(S) / PQ / QTE / LPQ / LPLR / CVAR / RDD / BLP / PLPR / PolicyTree) |
| Backends | `native`, `wasm`, `wasm-gc`, `js` — all pass `moon test --deny-warn` |
| Tests (native / wasm / js) | **808 / 808** |
| Tests (wasm-gc) | **814 / 814** (lib 808 + 6 doc tutorials) |
| Python cross-checks | **23 / 23 PASS** (`validate_*_with_python.py`) |
| Memoize + vectorize coverage | **22 / 22 estimators** |
| Cache read-path audit | 13 estimators have a hit-vs-fresh assertion; **5 of those 13 additionally carry a corruption probe** (IRM, PLR, CVAR, BLP, PQ) since v0.99.0. A corruption probe writes a known-wrong value into one cached slot and requires the reported estimate to move, so a dead cache-read path fails the suite. A hit-vs-fresh assertion alone does not: the fresh recompute is deterministic, so replaying nothing and replaying correctly are indistinguishable to it. |
| Joint covariance | `DoubleMLQTE::joint_covariance(kind)` / `cluster_joint_covariance(cluster_ids)` since v0.101.0. The quantile estimates share observations, so their influence functions are correlated and the per-quantile `sandwich_se_at` cannot answer any question posed jointly over two levels. Measured off-diagonal correlations on the v0.101.0 DGP: `+0.076`, `-0.265`, `+0.124`; a two-level contrast's variance is **1.265x** the one an independence assumption predicts, and clustering can flip the SIGN of an off-diagonal term. The diagonal is bit-identical to the variance `ses[j]` is the square root of. |
| Sandwich variance coverage | **19 / 22 estimators** (`sandwich_se` + `cluster_sandwich_se` + `bias_corrected_coef`, the last a documented no-op since v0.91.0; `DoubleMLQTE` exposes the per-quantile `sandwich_se_at(j, kind)` / `cluster_sandwich_se_at(j, cluster_ids)` / `bias_corrected_coef_at(j)` form, and as of v0.100.0 so do the three multi-estimand estimators: `DoubleMLAPOS::sandwich_se_at(level, kind)`, `DoubleMLDIDCS::sandwich_se_at(group, period, kind)`, and `DoubleMLDIDMulti::sandwich_se_at_idx(idx, kind)`). Not covered: `DoubleMLRDD` and `DoubleMLBLP` (projection / local-regression families -- they take the separate `hac_se` API added in v0.96.0 / v0.97.0) and `DoubleMLPolicyTree` (honest-split inference, no persisted IF components) |
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

**v0.85.0 memoization + vectorization complete (22 / 22)** —
closes the memoize + vectorize expand on
`DoubleMLPolicyTree`, the last estimator without the API. With
this, **all 22 estimators** expose
`enable_memoize` / `disable_memoize` / `clear_cache` /
`has_cache`. (The v0.84.0 note below still listed "2 small DID
variants" as pending; those DID variants already carried the API
as of v0.82.0, so `DoubleMLPolicyTree` was in fact the only
remaining gap.)

`DoubleMLPolicyTree` is a deterministic policy learner, not a
cross-fitted nuisance-regression estimator: it has no `n_folds`,
no `n_rep`, and no `fit_cluster`. Its cache therefore holds the
**fitted tree structure plus the per-leaf statistics** rather
than per-fold nuisance predictions, reusing the `FitCache` slots
as a shape-compatible container (`fold_ids` = `leaf_assignment`,
`predictions[0]` = `leaf_signal_mean`, `predictions[3]` =
`leaf_count`, `n_folds` = `n_leaves` as a partition-count
analogue, `fold_split_seed` = `depth` as the structural
fingerprint). `PolicyTreeNode` is a recursive sum type with no
`Clone` derive, so the tree is flat-encoded into a fixed-width
5-slots-per-node pre-order `Array[Double]` and rebuilt on a cache
hit. A hit skips both `policy_tree_build` (the dominant
`O(n * p * nodes)` cost, which allocates a fresh `Matrix` per
node) and the `O(n * depth)` leaf-walk loop. The per-leaf mean
is computed with `vector_divide` (eps-guarded denominator), and
`sensitivity_analysis`'s per-observation residual is computed
with a single `vector_subtract` over a gathered per-row leaf
mean instead of one scalar subtract per row per leaf.

Also in v0.85.0: adds the `moonbit-community/sqlite3@0.2.3`
dependency (with a `moonbitlang/async@0.20.3` pin) and the
matching `async` 0.22.4 header-map type fix in
`examples/api_server`.

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
in v0.55.0. See `#Sandwich variance` for the exact HC contract.

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

**Strict dependency hygiene** — the library imports only
`moonbitlang/*` official packages. `moon.mod` additionally *declares*
`moonbit-community/sqlite3@0.2.3` (added v0.85.0) so consumers can
reach a persistence backend through `moon add`; no `.mbt` file in
the library imports it yet. Non-official deps otherwise restricted
to `riantr/*` (this repo). Reproducible builds, minimal
supply-chain surface.

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
Total tests: 664, passed: 664, failed: 0.

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
| `examples/cluster` | `DoubleMLPLR` / `DoubleMLPLIV` | Cluster-robust SEs (row / `var_est_cluster` / `cluster_sandwich_variance`) reported at 1x and 4x the units, plus the all-singleton control that must reproduce `se()` | 1.0 |
| `examples/ssm` | `DoubleMLSSM` | MAR-selection SSM at two seeds x two sample sizes, printing `se()` and `sandwich_se(HC0)` side by side — the two must be bit-identical for a `var_est`-shaped estimator | 1.0 |
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
plus the supporting DGPs and score / nuisance kernels in 160 `.mbt`
files total: 87 production + 73 test), all reachable through the same
`DoubleMLXxx::new(...).fit()`
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
| `DoubleMLLPLR` | nuisance_space *(default)* / instrument | partially logistic regression, Liu-Zhang-Zhou 2021 *(extra)*. The two scores are upstream's two distinct formulas (`doubleml/plm/lplr.py:521-540`), both implemented since v0.105.0; before that the `score` argument was validated and then never read, so both names returned the same answer. |
| `DoubleMLCVAR` | CVaR | conditional value-at-risk *(upstream)* |
| `DoubleMLRDD` | observational | regression discontinuity *(upstream)* |
| `DoubleMLBLP` | IV | best linear predictor of treatment effect *(upstream)* |
| `DoubleMLPLPR` | partialling-out | partially linear panel regression, Clarke-Polselli 2025 *(extra)* |
| `DoubleMLPolicyTree` | policy | policy tree *(upstream)* |

#Sandwich variance

`sandwich.mbt` implements the Huber-White family
(`sandwich_variance_hc0` / `_hc1` / `_hc2` / `_hc3`, the
`sandwich_variance(kind, ...)` dispatch, and
`cluster_sandwich_variance`). **16 of the 22 estimators** are wired
up. 15 expose the no-index triple `sandwich_se(kind)` /
`cluster_sandwich_se(cluster_ids)` / `bias_corrected_coef()`:

`DoubleMLPLR` · `DoubleMLIRM` · `DoubleMLPLIV` · `DoubleMLIIVM` ·
`DoubleMLDID` · `DoubleMLDIDBinary` · `DoubleMLDIDCrossSection` ·
`DoubleMLDIDCSBinary` · `DoubleMLSSM` · `DoubleMLAPO` ·
`DoubleMLPLPR` · `DoubleMLCVAR` · `DoubleMLLPLR` · `DoubleMLLPQ` ·
`DoubleMLPQ`

The sixteenth, `DoubleMLQTE`, is a per-quantile estimator (one
scalar estimand per entry in the user-supplied `quantiles` array), so
its three methods take the quantile index --
`sandwich_se_at(j, kind)` / `cluster_sandwich_se_at(j, cluster_ids)` /
`bias_corrected_coef_at(j)`. No joint cross-quantile covariance is
implied or computed; see the v0.95.0 entry in `CHANGELOG.md` for why
its `M_inv` is `[[1.0]]` rather than `1 / deriv`.

The remaining 6 are deliberately not wired up, each for a
structural reason rather than a pending task. `DoubleMLAPOS`,
`DoubleMLDIDCS` and `DoubleMLDIDMulti` are documented in the
v0.89.0 entry below (no own scores, or a per-cell score matrix that
does not carry the sample width the HC identities need).
`DoubleMLBLP` / `DoubleMLPolicyTree` do not persist the
`(psi_a, psi_b)` influence-function pair the formulas are written
against.
`DoubleMLRDD` does persist a `psi_a`, but it is the intercept
Riesz-representer row for the sensitivity decomposition on the
bandwidth-restricted sample (length `n_local`), with no `psi_b`
counterpart, and its own `se` comes from the WLS / White form
(`cov_type`), not from `var_est` — giving it a sandwich SE is
score-field design work, not a wiring change.

As of v0.96.0 `DoubleMLRDD` and as of v0.97.0 `DoubleMLBLP` take the
other route: each exposes its OWN `hac_se(kind)` /
`cluster_hac_se(cluster_ids)` plus `leverage()`, and neither gets
`sandwich_se`. The reason is algebraic, not bookkeeping. BLP is an
OLS projection of an orthogonal signal onto `basis`, so its HC0 meat
is `sum_i ((M[j,:] . xa_i)^2 * e_i^2)` over the intercept-augmented
design `[1, basis]`, with a full `p1 x p1` normal inverse, one row
per coefficient, and no `1 / n^2`; the shared helper is a
scalar-Jacobian mean-moment sandwich. Routing BLP through it yields a
plausible, finite, wrong number, and the result is a length-`p1`
vector where the helper's `M_inv` is a 1x1. The anchor that proves
the wiring is `hac_se(HC0) == se` bit-identically, elementwise, on a
`cov_type = "HC0"` fit; it is not claimed on `cov_type = "nonrobust"`.
BLP and RDD are still NOT sandwich coverage and are not counted in
the 16 / 22 above.

`DoubleMLPolicyTree` remains deliberately unwired, and v0.97.0
records that as a decision rather than a pending task: its split
threshold is CHOSEN FROM THE DATA (`policy_tree_build` searches
features and values for the best split), so the naive per-observation
influence function of a leaf mean,
`(y_i - theta_k) / n_k * 1{i in k}`, omits the term contributed by the
split selection itself. Correct inference there is the policy-tree /
honest-splitting literature, not a derivation available from this
codebase, so no influence function was invented for it.

## The contract

`se()` is the reference and is never computed by this file. The
moment being inverted is the **mean** moment
`f(theta) = E[theta * psi_a + psi_b]` from `var_est.mbt`, so

```moonbit nocheck
sandwich_se(HC0) == se()                       // to the last ulp
HC1 / HC0 == sqrt(n / (n - 1))                 // to 1e-12
HC2 == HC1                                     // leverage h_ii = 1 / n
HC3 == HC1^2 / HC0                             // ditto
ordering:  HC3 > HC1 == HC2 > HC0              // monotonic widening
cluster(all-singleton) == IID HC0 == se()      // pooled clusters differ
bias_corrected_coef() == coef()                // documented no-op
```

**Exception — `DoubleMLDIDCrossSection`.** It is a projection
(`argmin_theta`) estimator, not a `var_est` Z-estimator: its `fit`
sets `theta_hat = -<psi_a, psi_b> / ||psi_b||^2` and derives its own
`se`, it persists `psi_a` as the OFFSET and `psi_b` as the SLOPE
(the second inverted-persistence estimator in the package, after
`DoubleMLLPLR`), and its `M_inv = [[1 / mean(psi_a)]]` is not
`1 / (d f / d theta)` in any principled sense — the argmin has a
vanishing first derivative. The HC ladder and the cluster
identities hold; the `HC0 == se()` identity does not, and since
v0.90.0 that is deliberate rather than pending.

`HC2` is **equal** to `HC1`, not strictly above it: the moment is
single-parameter, so its implicit regression is intercept-only with
equal weights, its projection matrix is `(1 / n) * J`, and every
leverage is the constant `h_ii = 1 / n_obs`. The pre-v0.88
ordering `HC1 > HC0 > HC2 > HC3` described a leverage bug (a
non-hat-matrix `h_ii` that came out negative and made HC2 / HC3
*shrink*), not the model. v0.88.0 fixed it; v0.91.0 fixed the
accumulator, which is what buys the `HC0 == se()` identity above.

`bias_corrected_coef()` is a **documented no-op** returning `coef`
unchanged — all 13 methods (12 landed v0.86.0 - v0.91.0, LPLR's in
v0.92.0; v0.91.0 is what turned them into no-ops). `coef` is the
root of the moment, so `mean(coef * psi_a + psi_b) == 0`
identically: the estimating function is orthogonal by construction,
and there is no score-based bias to correct. The v0.79.0 - v0.90.0
form passed the score at `-coef` rather than at `coef` and returned
`coef * (1 - 2 * mean(psi_a))` — exactly `3 * coef` on every
constant-`psi_a` estimator.

`DoubleMLLPLR` (v0.92.0) is the other estimator whose persisted
influence-function components are **inverted**: it stores
`psi_a = score offset`, `psi_b = score derivative`, the mirror of
the package convention. Its methods therefore pass the two arrays
**swapped** — `psi_at(coef, self.psi_b, self.psi_a)` and
`M_inv = [[1 / mean(self.psi_b)]]` — which is the same treatment its
`bootstrap` call site has used since v0.90.0. Measured on the
v0.90.0 LZZ2020 binary DGP (`n = 500`): `mean(psi_a) =
0.01899446402902459` (a cancellation residual) vs the true Jacobian
`mean(psi_b) = -0.036387245464012986`, and `sandwich_se(HC0) ==
se() == 0.278056227496941` to the last ulp (bit-identical on
`native` / `wasm-gc` / `wasm`; the two spellings of the same
expression differ by one ulp on `js`, so the portable contract is
the 1e-12 above, not `==`).

#Project layout

```
moonbit_doubleML/        <- the library (moon.mod v0.97.0, 165 .mbt files)
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

moon.work                <- 16-member workspace aggregator (1 library + doc + 14 examples)
AGENTS.md                <- this file (per moonbit agent convention)
skills/moonbit_doubleML.md  <- agent skill: API surface + anti-patterns
```

#Dependency rule (per `skills/moonbit_doubleML.md`)

- Only official `moonbitlang/*` packages in the library's source.
- Non-official packages may only be `riantr/*` (this repo), plus the
  single `moonbit-community/sqlite3@0.2.3` entry in the `moon.mod`
  `import` block (v0.85.0) — declared, not imported by any `.mbt`.
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
- v0.85.0 verified counts: `moon test` 617 / 617 (native & wasm &
  js) and 623 / 623 (wasm-gc). Closes the memoize + vectorize
  expand for `DoubleMLPolicyTree` (a deterministic policy learner
  with no `n_folds` / `n_rep` / `fit_cluster`: the cache holds the
  flat-encoded `PolicyTreeNode` tree plus the per-leaf
  `leaf_assignment` / `leaf_signal_mean` / `leaf_count` statistics,
  keyed on `(data_hash, depth, hyperparams_hash)`; a cache hit
  skips `policy_tree_build` and the leaf-walk loop entirely). The
  per-leaf mean uses `vector_divide` and
  `sensitivity_analysis` uses a single `vector_subtract` over a
  gathered per-row leaf mean. **22 / 22 estimators** now carry
  memoize + vectorize. Also adds the
  `moonbit-community/sqlite3@0.2.3` dependency plus the `async`
  0.22.4 header-map type fix in `examples/api_server`. The three
  new white-box tests in `expand_v085_test.mbt` include a
  ground-truth cross-check of the cache-hit tree against an
  independent memoize-OFF fit, and a deliberately asymmetric DGP
  so that a left/right swap in the flat node encoding is
  detectable (a symmetric interaction DGP yields a
  mirror-invariant tree and would hide such a bug).
- v0.86.0 verified counts: `moon test` 623 / 623 (native & wasm &
  js) and 629 / 629 (wasm-gc). Adds the shared
  `sandwich_variance(kind, psi_a, psi, m_inv, n_obs, n_params)`
  dispatch in `sandwich.mbt` and the
  `sandwich_se` / `cluster_sandwich_se` / `bias_corrected_coef`
  triple on `DoubleMLIIVM` / `DoubleMLPLIV` / `DoubleMLDID` /
  `DoubleMLCVAR` (**6 of 22** estimators).
- v0.87.0 verified counts: `moon test` 628 / 628 (native & wasm &
  js) and 634 / 634 (wasm-gc: lib 628 + 6 doc tutorials). Extends
  the sandwich-variance API to `DoubleMLSSM`, `DoubleMLPLPR`,
  `DoubleMLDIDCrossSection`, and `DoubleMLDIDCSBinary` (**10 of 22**
  estimators), all routing through the v0.86.0 shared
  `sandwich_variance(kind, ...)` dispatch. `DoubleMLLPLR` is
  deliberately skipped: it persists its influence-function
  components in the inverted `(offset, slope)` order
  (`psi_a = score - theta_hat * psi_deriv`, `psi_b =
  psi_deriv`), so `mean(psi_a)` is a cancellation residual rather
  than the Jacobian -- feeding it into `M_inv = [[1 / mean(psi_a)]]`
  inflates HC0 by ~60x over LPLR's own `se()`. See
  `expand_v087_test.mbt` for the full rationale and the two
  candidate fixes. The 5 new white-box tests assert the
  independently recomputed HC0 / HC2 / HC3 variances (not just
  finiteness), the exact HC1 `sqrt(n / (n - 1))` identity, exact
  singleton-cluster equality with the IID HC0, and the
  bias-correction identity. (The leverage-signed ordering
  `HC1 > HC0 > HC2 > HC3` they also asserted described the
  v0.79.0 - v0.87.0 leverage bug and is corrected in v0.88.0
  below.)
- v0.88.0 verified counts: `moon test` 634 / 634 (native & wasm &
  js) and 640 / 640 (wasm-gc: lib 634 + 6 doc tutorials).
  **BREAKING NUMERICAL CHANGE, HC2 / HC3 only.** Fixes the
  leverage used by `sandwich_variance_hc2` /
  `sandwich_variance_hc3` in `sandwich.mbt`. v0.79.0 - v0.87.0
  used `h_ii = psi_a[i] * M_inv[0,0] * psi_a[i]`, which is not a
  hat-matrix diagonal; with the package convention
  `M_inv = [[1 / mean(psi_a)]]` and the usual `mean(psi_a) < 0`
  it came out **negative**, so `1 - h_ii > 1` and HC2 / HC3
  **shrank** the variance instead of widening it -- the opposite
  of MacKinnon (2012) sec 5.4. Worst case (`psi_a = -1`
  constant, i.e. IRM / SSM / CVAR / DID ATT) `h_ii = -1` on every
  row, so HC2 was exactly `HC0 / 2` and HC3 exactly `HC0 / 4`.
  The moment actually being inverted is the single-parameter
  **mean** moment `E[psi_a * psi(theta)] = 0`, whose implicit
  regression is an intercept-only, equally weighted mean
  regression; its projection matrix is `(1 / n) * J`, so every
  leverage is the constant `h_ii = 1 / n_obs`. No estimator in
  the package persists a per-observation design matrix (only
  `psi_a`, `psi_b`, `coef`), so `1 / n_obs` is used uniformly --
  which is also what keeps the fix inside `sandwich.mbt` with no
  estimator-file changes. Under that leverage
  **HC2 == HC1 exactly** and **HC3 == HC1^2 / HC0 exactly**, and
  all three corrections widen (`HC3 > HC2 > HC1 == HC2 > HC0`).
  `sandwich_se(HC2)` / `sandwich_se(HC3)` therefore **increase**
  for all 10 estimators that expose them; `HC0` and `HC1` are
  bit-identical to v0.87.0 (regression-pinned in
  `expand_v088_test.mbt`, which adds the 6 falsifiable HC2 / HC3
  tests: the `HC2 == HC1` and `HC3 == HC1^2 / HC0` identities,
  `0 <= h_ii < 1` with `h_ii == 1 / n` across five `psi_a`
  families, the widening ordering, the HC0 / HC1 regression
  values, and the constant-`psi_a = -1` case).
- v0.89.0 verified counts: `moon test` 640 / 640 (native & wasm &
  js) and 646 / 646 (wasm-gc: lib 640 + 6 doc tutorials). Extends
  the v0.86.0 sandwich API to the APO family and the binary-DID
  wrapper (coverage **10 -> 12** of 22 estimators):
  - `DoubleMLAPO` -- clean add. `psi_a` (structurally the constant
    `-1`) and `psi_b` (the IPW-centred potential-outcome score)
    are both persisted struct fields, so `sandwich_se(kind)` /
    `cluster_sandwich_se(cluster_ids)` / `bias_corrected_coef()`
  - `DoubleMLDIDBinary` -- pure forwarder. The wrapper holds the
    whole fitted inner `DoubleMLDID` (`inner : DoubleMLDID`),
    which already implements the v0.86.0 API, so the three methods
    delegate instead of recomputing (the tests assert
    bit-identical results against `self.inner`). The inner owns the
    IF components, so the sandwich sample is the POST-SUBSET
    wide-format width `n_obs_subset()` (300 of a 600-row
    long-format panel in the test DGP), NOT the panel width and NOT
    the length of the zero-filled `psi_a_long()`.
  - `DoubleMLAPOS`, `DoubleMLDIDCS`, `DoubleMLDIDMulti`
    deliberately skipped -- see the CHANGELOG entry. APOS persists
    only `(coefs, ses)` per level and discards the child APOs' IF
    components (no own scores, no inner estimator to forward to);
    DIDCS is multi-cell and stores its per-cell `psi_a_matrix` on
    the long panel with out-of-cell rows zero-filled, so the
    per-cell subset width the HC1 identity needs is not
    recoverable; DIDMulti is a pure wrapper around DIDCS with no
    own scores and no scalar coefficient.
  - The 6 new white-box tests in `expand_v089_test.mbt` assert the
    v0.88.0 leverage identities on the estimator methods
    (`HC1 == HC0 * sqrt(n / (n - 1))`, `HC2 == HC1`,
    `HC3 == HC1^2 / HC0`, i.e. the WIDENING ordering
    `HC1 == HC2 > HC0` and `HC3 > HC2` -- the pre-v0.88 ordering
    `HC1 > HC0 > HC2 > HC3` is the bug, not the contract),
    independently recomputed HC0 / HC2 / HC3 / cluster variances
    (not just finiteness), exact singleton-cluster equality with
    the IID HC0 plus a strictly different pooled-cluster value
    (proving `cluster_ids` is consumed), the
    `coef + mean(psi_b - coef * psi_a)` bias-correction identity
    (plus APO's closed form `3 * coef`, since
    `theta_hat = mean(psi_b)` and `psi_a = -1`) -- that
    identity is **superseded by v0.91.0**, which removed the
    method's score-based correction and made it return `coef`
    unchanged, and the post-subset `n` pin for the DID binary
    wrapper.
  - Observed `n`: `DoubleMLAPO` persists its IF components on the
    FULL sample domain (`psi_a.length() == n_obs()`, both the IID
    and the `fit_cluster` path), so it has no `n` hazard;
    `DoubleMLDIDBinary` is on the post-subset wide-format panel
    (300 of 600), like `DoubleMLDIDCSBinary` (400 of 600) and
    unlike `DoubleMLPLPR` (180 of 240).
- v0.90.0 verified counts: `moon test` 648 / 648 (native & wasm &
  js) and 654 / 654 (wasm-gc: lib 648 + 6 doc tutorials). Routes
  every sandwich and bootstrap call site through a single
  `psi_at(coef, psi_a, psi_b)` helper in `sandwich.mbt`, replacing
  13 inline copies of `psi_a[i] + coef * psi_b[i]` in which the
  roles of `psi_a` (the Jacobian / coefficient row) and `psi_b`
  (the offset) were **swapped** — so the sandwich and
  multiplier-bootstrap families were evaluating
  `g(theta) = E[psi_a + theta * psi_b]`, a different function
  whose root is not `theta_hat`. On a fixed DGP the resulting
  `sandwich_se(HC0)` differed from the analytic `se()` by three
  orders of magnitude. `psi_at` makes the order explicit in one
  place so 13 copies cannot drift again. The score is now also
  evaluated **at the estimate** rather than at zero on every path.
  LPLR's own `bootstrap` call site is verified bit-identical
  across v0.89.0 / v0.90.0 (the two errors cancelled there), and
  its `psi` is now expressed as the explicit swap
  `(self.psi_b, self.psi_a)`. `DoubleMLLPLR` still got no
  `sandwich_se` at this point: its HC0 sat at `0.879 * se()`
  because the accumulator defect v0.91.0 fixed was still open.
- v0.91.0 verified counts: `moon test` 656 / 656 (native & wasm &
  js) and 662 / 662 (wasm-gc: lib 656 + 6 doc tutorials).
  **BREAKING NUMERICAL CHANGE, all 12 sandwich estimators.**
  Corrects two independent errors in the `sandwich.mbt`
  accumulator, both of which were open items in the v0.90.0
  entry:
  - It summed `(psi_a[i] * psi[i])^2`. The DML moment being
    inverted is the **mean** moment `E[theta * psi_a + psi_b]`,
    whose implicit regressor is the constant `1`, so the
    per-observation quadratic form is `psi[i]^2` with no
    `psi_a` weight. For constant `psi_a` the spurious `c^2`
    cancelled against `M_inv^2 = 1 / c^2` (a no-op); for
    non-constant `psi_a` it re-weighted the meat by a
    data-dependent factor (`0.229` on the PLR DGP).
  - It returned the variance of `sqrt(n) * (theta_hat -
    theta)` rather than of `(theta_hat - theta)`: `var_est`
    divides by `n` a **second** time, and the sandwich did not.
    This is the `sqrt(n)` the v0.90.0 release had to
    accommodate.
  - `sandwich_variance_hc0 / _hc1 / _hc2 / _hc3` and
    `cluster_sandwich_variance` now accumulate `sum_i psi[i]^2`
    and return `M_inv[0,0]^2 * acc / n / n`, so
    **`se() == sandwich_se(HC0)` for every estimator** --
    including the non-constant-`psi_a` ones, which no scaling
    of the old accumulator could produce. Measured on the
    v0.90.0 DGP (`n = 400`): IRM `0.21652894217092453` ->
    `0.010826447108546225` = its `se()`; PLR
    `0.19759510529621752` -> `0.020629646119313564` = its
    `se()`. Every HC kind moves by the same `sqrt(n)`, and
    because the HC identities are ratios, `HC1 == HC0 *
    sqrt(n / (n - 1))`, `HC2 == HC1`, `HC3 == HC1^2 / HC0` and
    the ordering `HC3 > HC1 == HC2 > HC0` all survive
    untouched. `HC2 == HC1` is now 1e-12 rather than
    bit-exact, so a test asserting `HC2 > HC1` was asserting
    a falsehood and is now `HC2 == HC1`.
    All-singleton clusters still equal IID HC0, and both now
    equal `se()`.
  - `bias_corrected_coef` (12 methods) is now a **documented
    no-op** returning `coef` unchanged. Under `var_est`'s
    convention `coef` is the root of the moment, so
    `mean(coef * psi_a + psi_b) == 0` identically: the
    estimating function is orthogonal by construction and
    there is no score-based bias to correct. The old form
    passed the score at `-coef` rather than at `coef` and
    returned `coef * (1 - 2 * mean(psi_a))`, i.e. exactly
    `3 * coef` on every constant-`psi_a` estimator -- a
    number that looks like a bias correction and is not one.
    Removing the methods outright is the obvious follow-up.
  - Not changed: `M_inv = [[1 / mean(psi_a)]]`, the v0.88.0
    leverage `h_ii = 1 / n_obs`, the v0.90.0 `psi_at`
    helper, and `var_est.mbt` (the reference, not the bug).
    `DoubleMLLPLR` still gets no `sandwich_se` in this release --
    its accumulator blocker is now resolved (its HC0 equals its
    `se()` to the last ulp, was `0.879 * se()`), but
    exposing the accessor is a separate API decision, taken in
    v0.92.0 below.
- v0.92.0 verified counts: `moon test` 664 / 664 (native & wasm &
  js) and 670 / 670 (wasm-gc: lib 664 + 6 doc tutorials). Adds the
  `sandwich_se` / `cluster_sandwich_se` / `bias_corrected_coef`
  triple to `DoubleMLLPLR` (coverage **12 -> 13** of 22) and
  backfills the README for v0.87.0 - v0.92.0. `se()` and the 12
  existing sandwich estimators are numerically unchanged;
  `sandwich.mbt` and `var_est.mbt` are untouched.
  - `DoubleMLLPLR` was skipped in v0.87.0 and again in v0.90.0 for
    one structural reason: it persists its influence-function
    components **inverted** (`self.psi_a` = the score OFFSET
    `sc.psi - theta_hat * sc.psi_deriv`, `self.psi_b` = the
    DERIVATIVE `sc.psi_deriv`), the mirror of the package
    convention. So both the score and the Jacobian take the arrays
    **swapped** -- `psi_at(coef, self.psi_b, self.psi_a)` and
    `M_inv = [[1 / mean(self.psi_b)]]` -- which is exactly the
    treatment its `bootstrap` call site has used since v0.90.0, so
    the two paths cannot drift apart. v0.87.0 fed
    `mean(self.psi_a)` (a catastrophic-cancellation residual) into
    `M_inv`; on the test DGP that is `+0.01899446402902459` where
    the Jacobian is `-0.036387245464012986`, i.e. the wrong sign
    and a `1.9156763469825346`x inflation of HC0.
    (The v0.87.0 report's "~60x" was a different DGP at
    `n = 400` measured through the then-still-broken v0.87.0
    accumulator; the two figures are not in conflict.)
  - The payoff invariant now holds for LPLR, **to the last ulp**:
    on the v0.90.0 LZZ2020 binary DGP (`n = 500`, `p = 6`,
    `n_folds = n_folds_inner = 2`, `n_rep = 1`, `seed = 3141`)
    with `coef = 0.5220088464187301`:
    `mean(psi_a) = 0.01899446402902459` (offset) vs
    `mean(psi_b) = -0.036387245464012986` (derivative);
    `se() == HC0 == 0.278056227496941`; `HC1 == HC2 ==
    0.2783347015051384`; `HC3 == 0.27861345440575247`; cluster
    singleton `0.278056227496941` == `se()`, pooled (blocks of 4)
    `0.28937508055158356`. The wrong-Jacobian HC0 would have been
    `0.5326657381470845`. On `native` / `wasm-gc` / `wasm` the
    `HC0 == se()` equality is bit-exact; on `js` the two spellings of
    the same expression (`M_inv[0,0]^2 * acc / n / n` vs
    `acc / n / (j * j * n)`) differ by one ulp, so the portable
    contract is 1e-12 and the test asserts 1e-14, not `==`.
  - `bias_corrected_coef` is the v0.91.0 documented no-op (returns
    `coef` exactly), for the same orthogonality reason as the other
    12; LPLR's `coef` is the root of
    `f(theta) = E[theta * psi_b + psi_a]` in its persisted order.
  - 8 white-box tests in `expand_v092_test.mbt`:
    `lplr_se_equals_sandwich_hc0` (the decisive one, at 1e-14 with
    a documented `js`-backend ulp caveat, plus the negative control
    that the package-order score does *not* reproduce `se()`),
    `lplr_hc1_hc0_ratio`,
    `lplr_hc2_equals_hc1`, `lplr_hc3_equals_hc1_squared_over_hc0`,
    `lplr_ordering`, `lplr_singleton_cluster_equals_se`,
    `lplr_bias_corrected_coef_is_identity`, and
    `lplr_jacobian_is_the_derivative_not_the_offset` (the
    regression pin against the v0.87.0 bug: it recomputes HC0 under
    *both* candidate Jacobians and requires the shipped value to
    match the derivative one).
  - README audit beyond the version / count / ordering updates:
    the v0.90.0 release entry was missing entirely; the
    `#Quick start` block still claimed `Total tests: 485`
    (v0.62.0); `#Project layout` still said `moon.mod v0.80.0` and
    `148 .mbt files`; `#Models` said `129 files total`; `moon.work`
    was called a 15-member workspace (it has 16); and the
    "strict dependency hygiene" / `#Dependency rule` claims that
    the library uses only official `moonbitlang/*` packages had
    been false since v0.85.0, which added a declared
    `moonbit-community/sqlite3@0.2.3` import. A new
    `#Sandwich variance` section now states the HC contract once,
    in one place, including the `DoubleMLDIDCrossSection`
    projection-estimator exception.

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