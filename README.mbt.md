# moonbit_doubleML - Double / Debiased Machine Learning in MoonBit

A pure-MoonBit port of the
[`doubleml-for-py`](https://github.com/DoubleML/doubleml-for-py) Python
package -- the Python ecosystem's most mature Double / Debiased Machine
Learning implementation -- with **22 estimators** in total. **19** match a
class of the same name in upstream; **2** are renamed -- `DoubleMLRDD` is upstream's RDD estimator (upstream
calls it `RDFlex`) and `DoubleMLDIDCrossSection` is upstream's
`DoubleMLDIDCS`; and **1**, `DoubleMLDIDCS`, has **no 1:1 upstream class**
-- it is this port's variant of upstream's multi-period `DoubleMLDIDMulti`,
which upstream keeps in a single class that this port splits in two. Those
provenance labels are re-measured against the **installed** `doubleml`
0.11.3 package, not asserted -- see the estimator table below and
`_verify/UPSTREAM_PROVENANCE.md`.
`DoubleMLPLPR`, `DoubleMLLPLR` and `DoubleMLDIDCSBinary` all ship
upstream, and the table marks them *(upstream)*.

Targets library authors and tool developers who need causal inference,
panel data estimation, instrumental variable estimation, regression
discontinuity, policy evaluation, or interpretable machine learning
inside the MoonBit ecosystem. Delivers one
`DoubleMLXxx::new(...).fit()` API across all 22 estimators -- the shape
is the same, but six take a different constructor, and those six are
named in **API reference** -- with robust variance estimation,
propensity-score processing, multiple-testing correction, and a
reproducible validation pipeline (24 / 24 Python reference scripts PASS)
-- on `native`,
`wasm`, `wasm-gc`, and `js` backends under `moon test --deny-warn`.

## Features

- ✅ **22 estimators** in 19 source files -- PLR, IRM, PLIV, IIVM, the DID
  family (6), SSM, APO, APOS, PQ, QTE, LPQ, LPLR, CVAR, RDD, BLP, PLPR and
  PolicyTree. The table is below.
- ✅ **One API shape** -- `DoubleMLXxx::new(...).fit()`. Two different sets of
  six differ -- six in their accessors, six in their constructors -- and both
  are named in **API reference** rather than left to be discovered.
- ✅ **Cross-fitting infrastructure** -- `kfold`, repeated cross-fitting,
  stratified K-fold, a `chacha8_rng(seed)` PRNG, and Kahan summation.
- ✅ **Robust variance and inference** -- heteroskedasticity-consistent (HC)
  standard errors, cluster-robust variance, multiplier bootstrap confidence
  intervals, joint CIs, and Romano-Wolf multiple-testing adjustment.
- ✅ **Propensity-score processing** -- `PSProcessorConfig`: clipping,
  isotonic calibration, CV calibration, all reachable from an estimator.
- ✅ **Four backends** -- `native`, `wasm`, `wasm-gc`, `js` -- all green under
  `moon test --deny-warn`.
- ✅ **24 / 24 Python reference scripts PASS** -- 25 of the 25 bit-exact items
  are IEEE-754 identical to CPython, and the 6 / 6 RNG keys are byte-identical.
- ✅ **No runtime third-party dependency** -- the library imports nothing
  outside `moonbitlang/core`.
- ✅ **21 runnable example binaries** -- 16 CLI demos, plus
  `examples/api_server/` (the HTTP service), `examples/consumer_demo/`,
  `examples/fuzz/`, and the two fixtures `examples/bitexact/` and
  `examples/parity/`.

**Pure-MoonBit, all-4-backends port of `doubleml-for-py`** -- 22 `DoubleML*`
estimators (`DoubleMLPLR`, `DoubleMLIRM`, `DoubleMLPLIV`, `DoubleMLIIVM`,
`DoubleMLDID`, `DoubleMLDIDBinary`, `DoubleMLDIDCS`,
`DoubleMLDIDCSBinary`, `DoubleMLDIDMulti`, `DoubleMLDIDCrossSection`,
`DoubleMLSSM`, `DoubleMLAPO`, `DoubleMLAPOS`, `DoubleMLPQ`,
`DoubleMLQTE`, `DoubleMLLPQ`, `DoubleMLLPLR`, `DoubleMLCVAR`,
`DoubleMLRDD`, `DoubleMLBLP`, `DoubleMLPLPR`, `DoubleMLPolicyTree`)
in 19 source files. **19** are marked *(upstream)* and mirror a
name-identical `doubleml-for-py` class; **2** are marked
*(upstream, renamed)* -- `DoubleMLRDD` (upstream `RDFlex`) and
`DoubleMLDIDCrossSection` (upstream `DoubleMLDIDCS`); and **1**,
`DoubleMLDIDCS`, is marked *(upstream design, no 1:1 class)*.
The DID family is where the naming crosses, so it is worth spelling out.
Upstream's `DoubleMLDIDCS` is the *repeated cross-sections* estimator,
which is this port's `DoubleMLDIDCrossSection`. Upstream's
`DoubleMLDIDMulti` is the *multi-period* estimator, and upstream keeps
it in **one** class -- this port splits it in two: `DoubleMLDIDMulti`
is the 1:1 counterpart (it carries upstream's `gt_combinations`
selector and upstream's `standard` / `all` / `universal` keywords),
and `DoubleMLDIDCS` is the port's variant without the selector, which
derives its own `(g, t)` grid and transcribes upstream's `did_cs.py`
machinery. A 1:1 map cannot give one upstream class two counterparts,
so `DoubleMLDIDCS` is labelled for what it is rather than given a
partner by name coincidence. Three rows -- `DoubleMLDIDCSBinary`,
`DoubleMLLPLR`, `DoubleMLPLPR` -- ship upstream, so each has a reference
implementation.

## Installation

```bash
moon add riantr/moonbit_doubleML
```

Then reference it from `moon.mod`:

```moonbit nocheck
///|
import {
  "riantr/moonbit_doubleML@0.164.37",
}
```

## Quick Start

Run these from the **repository root** -- the directory holding `moon.work`.
`moon test --target native` prints the same total from either directory, but
`moon run examples/main` and `python validate_irm_with_python.py` are
repo-root paths and fail from inside `moonbit_doubleML/`.

```console
$ moon test --target native --deny-warn
Total tests: 1117, passed: 1117, failed: 0.

$ moon run examples/main
=== MoonBit DML PLR (partialling out) ===
true theta_0      = 1
estimated theta   = 1.092018247331361
standard error    = 0.08875683254582736
...

$ python validate_irm_with_python.py
======================================================================
PASS  |mb - handrolled_nrep5| (theta) = 8.868664e-02 < max(MODEL_TOL=0.1, 2.0*handrolled_n5_se) = 1.912555e-01
```

`--target native` is spelled out because the package's `preferred_target` is
`wasm-gc`, where the suite is **1123** -- 1117 plus 6 doc tutorials; the
per-target numbers are in the Status table. A bare `moon test` runs only
three of the four declared backends -- on `moon 0.1.20261023` it prints
`Total tests: 0` for `wasm` and `native` and reports `no test entry found`
for `js`, which it never runs -- so the per-target counts here come from
explicit `--target` runs.

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

## The 22 estimators

22 estimators (`DoubleML*` structs) in 19 production files -- 16 with
one struct each, and three holding two (`apo.mbt`: `DoubleMLAPO` +
`DoubleMLAPOS`; `blp_policy.mbt`: `DoubleMLBLP` +
`DoubleMLPolicyTree`; `quantile.mbt`: `DoubleMLPQ` + `DoubleMLQTE`) --
out of 220 `.mbt` files in the package (65 production, 129 blackbox
test, 26 whitebox test). All are reachable through the same
`DoubleMLXxx::new(...).fit()` interface. 19 are marked *(upstream)*
against a name-identical `doubleml-for-py` class; two are marked
*(upstream, renamed)* -- `DoubleMLRDD` (upstream `RDFlex`) and
`DoubleMLDIDCrossSection` (upstream `DoubleMLDIDCS`); and one,
`DoubleMLDIDCS`, is marked *(upstream design, no 1:1 class)* -- the
port's variant of upstream's `DoubleMLDIDMulti`:

| Model | Score | Description |
|-------|-------|-------------|
| `DoubleMLPLR` | partialling-out | partially linear regression *(upstream)* |
| `DoubleMLIRM` | ATE | interactive regression model *(upstream)* |
| `DoubleMLPLIV` | partialling-out | partially linear IV regression *(upstream)* |
| `DoubleMLIIVM` | LATE | interactive IV model *(upstream)* |
| `DoubleMLDID` | observational | difference-in-differences *(upstream)* |
| `DoubleMLDIDBinary` | observational | DID with binary outcome *(upstream)* |
| `DoubleMLDIDCS` | observational | DID with staggered adoption (Callaway-Sant'Anna) *(upstream design, no 1:1 class)* -- the port's variant of upstream `DoubleMLDIDMulti`, without its `gt_combinations` selector |
| `DoubleMLDIDCSBinary` | observational | CS-DID with binary outcome *(upstream)* |
| `DoubleMLDIDMulti` | observational | multi-period DID with group-time ATT aggregation *(upstream)* |
| `DoubleMLDIDCrossSection` | observational | Sant'Anna-Zhao 2020 cross-section DID *(upstream, renamed)* -- upstream `DoubleMLDIDCS` |
| `DoubleMLSSM` | MAR | sample selection (missing-at-random) *(upstream)* |
| `DoubleMLAPO` | policy score | average potential outcomes for one treatment level *(upstream)* |
| `DoubleMLAPOS` | policy score | average potential outcomes across several treatment levels *(upstream)* |
| `DoubleMLPQ` | quantile | potential quantile *(upstream)* |
| `DoubleMLQTE` | quantile | quantile treatment effect *(upstream)* |
| `DoubleMLLPQ` | local polynomial | local potential quantile *(upstream)* |
| `DoubleMLLPLR` | partialling-out | partially logistic regression, Liu-Zhang-Zhou 2021 *(upstream)* |
| `DoubleMLCVAR` | CVaR | conditional value-at-risk *(upstream)* |
| `DoubleMLRDD` | local polynomial | regression discontinuity *(upstream, renamed)* -- upstream `RDFlex` |
| `DoubleMLBLP` | IV | best linear predictor of treatment effect *(upstream)* |
| `DoubleMLPLPR` | partialling-out | partially linear panel regression, Clarke-Polselli 2025 *(upstream)* |
| `DoubleMLPolicyTree` | policy | policy tree *(upstream)*, + v0.98.0 honest split (`honest = true`) with `leaf_se` / `policy_value_se` |

The **Score** column is a prose label for the estimand family, not a
machine string, and three vocabularies are in play. The port accepts
**8** spellings -- `partialling-out`, `partialling out`, `iv-type`,
`IV-type`, `observational`, `experimental`, `nuisance_space` and
`instrument` -- and only **7 of the 22 estimators take a `score`
argument at all**: `DoubleMLPLR` on `fit()`, six others on `new()`.
The upstream vocabulary is a different set of **15** spellings, and
upstream `doubleml-for-py` 0.11.4 uses `APO`, `ATE`, `PQ`, `LPQ`,
`CVaR`, `LATE`, `ATTE`, `IV-type`, `experimental`, `instrument`,
`missing-at-random`, `nonignorable`, `nuisance_space`, `observational`
and `partialling out`; it takes **no score argument at all** for
`RDFlex`, `DoubleMLBLP` or `DoubleMLPolicyTree`. The
`doc/004_estimators` tutorial lists the port's own strings, one row
per estimator.

> **How the names map.** `DoubleMLDIDCS` has **no 1:1 upstream class**
> -- it is this port's variant of upstream's `DoubleMLDIDMulti` -- and the
> two *renamed* pairs are `DoubleMLRDD` (upstream `RDFlex`) and
> `DoubleMLDIDCrossSection` (upstream `DoubleMLDIDCS`). The derivation, and
> the parameter that distinguishes them, are in
> `_verify/UPSTREAM_PROVENANCE.md` and in `ENGINEERING.md`.

## API reference

**One API shape, with the differences named** -- every estimator is built
`DoubleMLXxx::new(...).fit()`. The *shape* is uniform; the signature and the
accessor set are not, and **both** sets of differences are listed here rather
than discovered later. They are two different sets of six, and they overlap in
only three estimators.

**The accessor differences:**

| estimator | instead of | because |
|---|---|---|
| `DoubleMLAPOS` | `coef` / `se` -> `coefs` / `ses` | one estimate per treatment level |
| `DoubleMLQTE` | `coef` / `se` -> `coefs` / `ses` | one estimate per quantile |
| `DoubleMLDIDCS` | `coef` / `se` -> `coef_at` / `se_at` | one ATT per (group, period) |
| `DoubleMLDIDMulti` | `coef` / `se` -> `coef_at_idx` / `se_at_idx` | the same cells, by row-major index |
| `DoubleMLBLP` | `confint` -> `confint_joint` | the interval is for a contrast of the IV coefficient vector |
| `DoubleMLPolicyTree` | no scalar coefficient at all | `leaf_influence`, `leaf_se`, `policy_value`, `policy_value_se` |

The other 16 expose `.coef()` / `.se()` / `.confint()` / `.bootstrap()`.

**The constructor differences** -- which estimators take `n_folds` / `n_rep` /
`seed`. This is a different partition from the accessor table above, so the
two groups of "the other 16" are not the same sixteen:

| estimators | `n_folds` | `n_rep` | `seed` |
|---|---|---|---|
| the other 16 | yes | yes | yes |
| `DoubleMLPQ`, `DoubleMLQTE`, `DoubleMLLPQ` | yes | **no** | yes |
| `DoubleMLBLP`, `DoubleMLRDD`, `DoubleMLPolicyTree` | no | no | no |

The quantile estimators cross-fit once -- `solve_pq` has no repetition loop,
so there is no `n_rep` to set. The last three take no cross-fitting option
at all: `DoubleMLBLP` is given a basis and an orth signal, `DoubleMLRDD`
fits locally around a cutoff, and `DoubleMLPolicyTree` splits the sample
once for its honest split (its own `split_seed`).

Constructor arguments also differ in ways a table cannot show:
`DoubleMLDIDBinary` needs `g_value` / `t_value_pre` / `t_value_eval`,
`DoubleMLAPOS` needs `treatment_levels`, `DoubleMLPolicyTree` needs
`features` / `orth_signal` / `depth` / `honest`, and the DID variants take
four data types, not one each: `DoubleMLDIDData` for `DoubleMLDID`,
`DoubleMLDIDBinaryData` for `DoubleMLDIDBinary`, `DoubleMLDIDCSData` for
`DoubleMLDIDCS`, `DoubleMLDIDCSBinary` AND `DoubleMLDIDMulti`, and
`DoubleMLDIDCrossSectionData` for `DoubleMLDIDCrossSection`. The `score` argument is the one that moves between
`new()` and `fit()`: `DoubleMLPLR` takes it on `fit()`, and
`DoubleMLDID`, `DoubleMLDIDBinary`, `DoubleMLDIDCrossSection`,
`DoubleMLDIDCSBinary`, `DoubleMLLPLR` and `DoubleMLPLPR` take it on
`new()`.

**Learner injection via `LearnerDispatch`** -- the learner arguments are
`LearnerDispatch` optionals, and **the set differs by estimator**, so there is
no single argument to pass:

| learner arguments | estimators |
|---|---|
| `ml_g` / `ml_m` | `DoubleMLAPO`, `DoubleMLAPOS`, `DoubleMLCVAR`, `DoubleMLDID`, `DoubleMLDIDBinary`, `DoubleMLDIDCS`, `DoubleMLDIDCSBinary`, `DoubleMLDIDCrossSection`, `DoubleMLDIDMulti`, `DoubleMLIRM`, `DoubleMLLPLR` |
| `ml_l` / `ml_m` | `DoubleMLPQ`, `DoubleMLQTE` |
| `ml_g` / `ml_m` / `ml_r` | `DoubleMLIIVM` |
| `ml_g` / `ml_m` / `ml_pi` | `DoubleMLSSM` |
| `ml_g` | `DoubleMLBLP`, `DoubleMLRDD` |
| `learner_l` / `learner_m` | `DoubleMLPLR` |
| `learner` | `DoubleMLPLIV`, `DoubleMLPLPR` |
| none | `DoubleMLLPQ`, `DoubleMLPolicyTree` |

That is **8** argument sets over the **22** estimators. `ml_r` is
`DoubleMLIIVM`'s instrument propensity (at `fit()` it reuses the
constructor's choice) and `ml_pi` is `DoubleMLSSM`'s selection propensity
(at `fit()` it reuses the `ml_m` choice). The constructor default is
`LearnerDispatch::linear_regression()` (OLS) -- except `ml_m` on the seven
structs migrated to a classifier, named below.
Built-in learners:

| learner | kind | `sample_weight` | note |
|---|---|---|---|
| `LinearRegression` | regression | WLS | OLS, the default |
| `Ridge` | regression | weighted | **v0.120.0+**, L2 penalty, unpenalised intercept |
| `Lasso` | regression | weighted | **v0.120.0+**, L1 penalty, coordinate descent |
| `ElasticNet` | regression | weighted | **v0.120.0+**, the convex L1/L2 blend |
| `LogisticRegression` | **classification** | weighted IRLS | binary, IRLS Newton-Raphson |
| `RFClassifier` | **classification** | weighted | v0.117.0+, Breiman 2001, Gini splits |
| `GBClassifier` | **classification** | weighted Newton leaf | v0.117.0+, Friedman 2001, binary log loss |
| `RFLearner` | regression | weighted splits/leaf | Breiman 2001, MSE splits |
| `GBLearner` | regression | weighted leaf | Friedman 2001, squared-error loss |
| `ConstantLearner`, `NoopLearner` | either | ignored | constant / zero predictors |

Upstream `doubleml` is learner-agnostic -- `ml_g` / `ml_m` are any
object with `fit` / `predict` -- so it inherits scikit-learn's whole
learner surface. This package ships eleven. The three classification
learners' `predict` returns `P(y = 1 | x)`, never a hard label, because
DML's AIPW correction divides by the fitted propensity.

## Propensity processing

**`ml_m` is a classifier where the propensity carries identification --
and that is NOT everywhere.** Upstream makes no OLS default: `ml_m` is a
required argument, validated as `regressor=False, classifier=True`
(`irm.py:157`) and read back with `predict_proba` (`irm.py:161`). Where
`m_hat` is first-order in the score, an OLS propensity is unbounded, enters
as `1 / m_hat`, and `propensity_clip` (default `1e-6`) merely caps that at
`1e6` -- so nothing raises, it just returns wrong numbers. Measured on a
fixture with true `ATE = 1.5`:

| `ml_m` | `coef` | `rv` |
|---|---|---|
| `linear_regression` | **`-225.86`** | `0.043` |
| `logistic_regression` | **`1.44`** | `0.842` |

`coef` is the estimated effect; `rv` is upstream's **robustness value** -- the
sensitivity-analysis reading of how much confounding the estimate survives, so
**higher is more robust**. The OLS propensity lands at `0.043`; the classifier
reaches `0.842`.

The port used to default `ml_m` to `LearnerDispatch::linear_regression()`
everywhere. **`DoubleMLIRM` was migrated in v0.132.0**,
**`DoubleMLAPO` in v0.134.0**, **`DoubleMLAPOS` in v0.135.0**,
**`DoubleMLSSM` in v0.138.0**, **`DoubleMLPQ` / `DoubleMLQTE` in
v0.139.0** and **`DoubleMLLPLR` in v0.163.3**:
their `ml_m` default is now
`LearnerDispatch::logistic_regression(LogisticRegression::new())`, while
`ml_g` deliberately stays OLS (it models `E[y | x]`, not `P(y = 1 | x]`), so the
two defaults diverge on purpose. `LearnerDispatch::is_classifier()` reports
which constructors qualify.

The migrations do NOT all have the same margin, and the gates are shaped
accordingly. `DoubleMLIRM` on a saturated-propensity fixture (true `ATE = 1.5`)
across three seeds: the default's worst bias is `0.1983`, the OLS arm's
smallest bias is `72.797` -- a 367x separation on the coefficient.
`DoubleMLAPO` (true `E[Y | D=1] = 1.2`): the default's worst bias is `0.5307`,
the OLS arm's smallest bias is `5.2464` -- only ~10x. APO's standard error is
the honest discriminator (`0.270` vs `86.28`, a 320x separation), because the
mechanism is that an
unbounded propensity makes `1 / m_hat` explode and takes the variance with it.

`DoubleMLSSM` has the largest margin of the four migrations of
v0.132.0-v0.138.0 -- `DoubleMLIRM`, `DoubleMLAPO`, `DoubleMLAPOS` and
`DoubleMLSSM` -- because its score carries **two** reciprocals, one per
direction (`ssm.mbt:73-74`): the treatment propensity `m` and the selection
propensity `pi`, so an unbounded regressor breaks both denominators
independently. On a saturated fixture with true `theta = 1.0`, the OLS arm
returns `242.116` with SE `185.45` where the classifier returns `1.177` with
SE `0.0982` -- roughly **200x** on the point estimate and **1900x** on the
standard error. Across three seeds the OLS coefficient also **changes sign**
(`+242`, `+106`, `-452`); the classifier's spread over the same three seeds
is `0.761`.

One caveat worth stating plainly: on a *mild* fixture, where the true
propensity never reaches the `0.02`/`0.98` clamp, the two learners agree to
three decimals and OLS is marginally better. The hazard is a property of the
clamp, not of the estimator in general, and the gate suite pins both regimes so
a future change cannot be scored on the flattering fixture alone.

**Eight structs still default `ml_m` to `linear_regression()`**:
`DoubleMLCVAR`, `DoubleMLDID`, `DoubleMLDIDBinary`,
`DoubleMLDIDCrossSection`, `DoubleMLDIDCS`, `DoubleMLDIDCSBinary`,
`DoubleMLDIDMulti`, `DoubleMLIIVM`. Until each is
migrated, pass a classifier explicitly -- `ml_m` is a named argument on the
constructor, so the learner goes where the estimator is built:

```moonbit
let fitted_cvar = @moonbit_doubleML.DoubleMLCVAR::new(
  data,
  ml_m=@moonbit_doubleML.LearnerDispatch::logistic_regression(
    @moonbit_doubleML.LogisticRegression::new(),
  ),
).fit()
```

`LearnerDispatch::random_forest_classifier(RFClassifier::new(...))` and
`LearnerDispatch::gradient_boosting_classifier(GBClassifier::new(...))` are
the nonlinear options.

**The hazard is NOT uniform, and was measured per-estimator** (v0.132.0-v0.142.0).
Migrating `DoubleMLDIDBinary` was attempted and abandoned on the evidence:
across four probe designs and ~14 configurations its OLS default matched a
logistic one to within ~1e-4, and where they differed the OLS default was the
BETTER of the pair. The reason is structural. In the observational DID score
(`did.mbt:97`) the residual weight is `(D - m) / (p_hat * (1 - m))`, so the
score never divides by `m`: for a **treated** row the `m` dependence cancels,
and `m` reaches the control rows only. The score is **doubly robust** -- a
correct `g` carries identification, leaving `m` second-order. IRM and APO need
`m` for the estimand itself, which is why they showed a ~200-point error and
DID shows ~0.001. The sharpest DID case: at n=200 the CLASSIFIER default is
worse on both bias (0.0776 vs 0.00050) and SE.

| Estimator | OLS default | Evidence |
|---|---|---|
| `DoubleMLIRM` | hazardous | coef `-225.86` vs `1.44` |
| `DoubleMLAPO` | hazardous | bias `5.246` vs `0.531`; SE `86.28` vs `0.270` |
| `DoubleMLAPOS` | hazardous | per-level bias to `436.11` |
| `DoubleMLDIDBinary` | **not demonstrated** | 4 designs, ~14 configs, ~`1e-4` |
| `DoubleMLDID`, `DoubleMLDIDCS`, `DoubleMLDIDCSBinary`, `DoubleMLDIDCrossSection`, `DoubleMLDIDMulti` | not demonstrated | doubly robust -- `m` cancels for treated rows |
| `DoubleMLSSM` | **hazardous -- fixed in v0.138.0** | coef `242.116` vs `1.177` |
| `DoubleMLCVAR` | not demonstrated | `2.300` vs `2.373` |
| `DoubleMLQTE` | **hazardous -- fixed in v0.139.0** | OLS arm frozen at `-1.583` at the three measured taus `0.50` / `0.75` / `0.90` |
| `DoubleMLIIVM` | not demonstrated | `0.987` vs `1.031`; SE `0.0047` vs `0.0747` (16x *smaller*) |
| `DoubleMLPLR` | not demonstrated | `1.015` vs `1.103` -- OLS better |
| `DoubleMLLPLR` | **not demonstrated -- root-caused in v0.140.0-v0.142.0** | not an `ml_m` hazard; two failure modes; see below |
| `DoubleMLPQ` | **hazardous -- fixed in v0.139.0** | ignored its `quantile` entirely |

Every row above is a **measured verdict**, and each was settled in the release
that decided it: `DoubleMLIRM` (v0.132.0), `DoubleMLAPO` (v0.134.0),
`DoubleMLAPOS` (v0.135.0) and `DoubleMLDIDBinary` (v0.136.0) first, the rest
in v0.137.0. `DoubleMLQTE` is the one row whose verdict is later than its
measurement: v0.137.0 recorded it as *not demonstrated* (`0.162` vs `0.249`),
and the freeze was only found in v0.139.0. **Six rows turned out hazardous**:
`DoubleMLIRM` (`-225.86` vs `1.44`), `DoubleMLAPO` (bias `5.246` vs `0.531`),
`DoubleMLAPOS` (per-level bias to `436.11`), `DoubleMLSSM` (`242.116` vs
`1.177` -- its score divides by `m*pi` AND `(1-m)*pi`, two reciprocals in both
directions, `ssm.mbt:73-74`), and `DoubleMLPQ` / `DoubleMLQTE`, which ignored
their `quantile` outright. All six default to a classifier today.
`DoubleMLDIDBinary`, `DoubleMLCVAR`, `DoubleMLIIVM` and `DoubleMLPLR` (whose
propensity role is `learner_m`, not `ml_m`) kept their OLS default **on
measured evidence** -- no flip was warranted.
`DoubleMLLPLR`'s degenerate standard error is real and was root-caused in
v0.140.0, but it is **not** an `ml_m` defect -- see the note below.

A static classifier (read the score: does it carry `1/m`? is it doubly robust?)
was used to prioritise the probes, and it reproduces the four hazardous
verdicts of v0.132.0-v0.138.0 -- `DoubleMLIRM`, `DoubleMLAPO`,
`DoubleMLAPOS` and `DoubleMLSSM` -- but `DoubleMLIIVM` **refuted** it,
carrying `1/m` and `1/(1-m)` on every row and still measuring harmless. A
reciprocal in the score is not sufficient for the hazard; the classifier is a
way to decide what to measure first, nothing more.

## Cross-fitting

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
today -- the public API has been fixed since v0.82, so a future
release can swap the bodies to a SIMD-vectorised backend (or external
call to a BLAS-style library) without breaking callers.

## Examples

21 `examples/<bin>/` directories in `moon.work`. 16 are CLI-style numeric
demos that print an estimate; measured per driver, **14** of the 16 print a
true value and **11** of the 16 print a 95 % CI -- `examples/pava` and
`examples/splitting` print neither, and `examples/apos`, `examples/cluster`
and `examples/ssm` print a true value but no CI. `examples/api_server/`
is an HTTP service; `examples/consumer_demo/` is the library-user pattern
that mirrors what an external `moon add riantr/moonbit_doubleML` consumer
would write; `examples/fuzz/` is the property-based fuzz harness; and
`examples/bitexact/` and `examples/parity/` are the MoonBit fixtures the
bit-exact and LPLR parity validators drive, kept as runnable binaries so
their numbers are inspectable without a Python reference.

Every example's `moon.mod` pins the library at the release this document
describes, so an example copied out of the tree and resolved there with
`moon update` installs the same library these numbers came from.

`examples/apo/` and `examples/apos/` are the pair worth reading together:
APO returns the potential outcome AT one treatment level, APOS returns
those levels plus pairwise CONTRASTS, and a contrast is off by the
reference level's entire outcome. `examples/apo/` prints both so the gap
is visible rather than described.

| Driver | Model | DGP | True theta |
|--------|-------|-----|--------|
| `examples/main` | `DoubleMLPLR` + 11 others (IRM / PLIV / IIVM / DID / SSM / BLP / RDD / PQ / QTE / LPQ / PolicyTree) | Simple partially linear, `n=500`, `p=5` | 1.0 |
| `examples/datasets` | `DoubleMLPLR` + `DoubleMLIRM` | Synthetic 401(k)-style, `n=4000`, 9 controls | 1.5 |
| `examples/did_binary` | `DoubleMLDIDBinary` | 2-period panel DID, 400 units | 1.0 |
| `examples/did_cs` | `DoubleMLDIDCS` | Staggered CS-DID, 4 cohorts x 4 periods | 1.0 |
| `examples/did_cs_binary` | `DoubleMLDIDCSBinary` | Staggered CS-DID with binary outcome | 1.0 |
| `examples/did_multi` | `DoubleMLDIDMulti` | Top-level multi-period DID + aggregation | 1.0 |
| `examples/did_cross_section` | `DoubleMLDIDCrossSection` | Sant'Anna-Zhao 2020 cross-section DID, 500 units | 1.0 |
| `examples/plpr` | `DoubleMLPLPR` | Static-panel PLR (60 units x 4 periods) | 1.0 |
| `examples/lplr` | `DoubleMLLPLR` | Partially logistic regression, LZZ2020 | 0.5 (logit-scale `alpha`) |
| `examples/apo` | `DoubleMLAPO` | 3-level discrete treatment (`D` in 0/1/2): the LEVEL `E[Y(t)]` | 1.0 (`E[Y(1)]`) / 2.5 (`E[Y(2)]`) |
| `examples/apos` | `DoubleMLAPOS` | 2-level discrete treatment: per-level `E[Y(t)]` PLUS pairwise CONTRASTS | 1.0 per level; contrast 0.0 |
| `examples/cvar` | `DoubleMLCVAR` | CVaR at `q=0.5` | 1.74 |
| `examples/ssm` | `DoubleMLSSM` | Sharp synthetic treatment | 1.0 |
| `examples/cluster` | `DoubleMLPLIV` / `DoubleMLPLR` + `cluster_*` | Clustered data, cluster-robust SEs | 1.0 |
| `examples/splitting` | `DoubleMLPLR` + `set_sample_splitting` | External sample splitting (n=200, p=2) | 1.5 |
| `examples/pava` | `pava` core | Isotonic regression, exact (no MC error) | n/a -- fixed input cases, not a theta demo |
| `examples/fuzz` | wrappers | Random-property fuzz harness across 11 surfaces (native-only) | n/a |
| `examples/bitexact` | fixture | The bit-exact values and RNG keys `validate_bitexact_with_python.py` drives | n/a |
| `examples/parity` | fixture | The LPLR nuisance-space / instrument values the parity gate drives | n/a |
| `examples/consumer_demo` | library-user pattern | Minimal end-to-end PLR (no estimator-specific extras) | 1.0 |
| `examples/api_server` | `DoubleMLPLR` + `DoubleMLIRM` | HTTP service -- see below | n/a |

CLI demos (all 16 run bare; most print an estimate against a true value):

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
$ _build/native/debug/build/example/api_server/api_server.exe   # listens on 127.0.0.1:4000

$ curl -s http://127.0.0.1:4000/healthz
{"status":"ok"}

$ curl -s -X POST http://127.0.0.1:4000/fit/plr \
    -H 'Content-Type: application/json' \
    -d '{"x":[[1.0,0.5],[2.0,1.5],[3.0,2.5],[4.0,3.5],[5.0,4.5],[6.0,5.5]],"y":[2.0,4.0,6.0,8.0,10.0,12.0],"d":[1.0,2.0,3.0,4.0,5.0,6.0],"n_folds":2,"seed":3141}'
{"estimator":"plr","coef":2,"se":0,"ci_lo":2,"ci_hi":2,"n_obs":6,"n_features":2}
```

The same `api_server.wasm` also runs under `moonrun <path-to-the-wasm>`.
The listen port is hard-coded to `4000` in `main.mbt`, so the service
ignores any argument it is given (see `examples/api_server/README.md`
for the full PowerShell smoke recipe).
The service is built directly on `moonbitlang/async@0.20.3` --
no third-party HTTP framework is pulled in.

## Common pitfalls and best practices

### ⚠️ Partially logistic regression: the small-n regime

This port damps LPLR's Newton step so the answer stays finite; upstream does
not. What follows is why that is a fragility the two implementations SHARE, and
not a defect this port introduced.

**What the cause actually is, and why it is not a port defect.** The port's own
`t_pred`, `m_pred`, `a_pred` and `beta` were dumped on the exact n = 66 rows
where the unclamped port dies, and handed to *upstream's own* solver. The
`t`/`m`/`a` values are harmless; `beta` alone reproduces the divergence, all 8
of 8 swap cells. And inside `beta`, it is not `r_hat = t - beta * a` that hurts
but the **Newton start value** `mean(beta)`, which upstream also uses verbatim
(`plm/lplr.py:326`, `np.average(beta)`).

Upstream never sets `_coef_bounds` for LPLR, so `double_ml_score_mixins.py:149`
runs `root_scalar(..., method="newton")` -- an **unbracketed** Newton from that
same start. This port is structurally identical; the clamp is standing in for a
robustness upstream does not have either. On the n = 66 rows the score is nearly
flat past `theta ≈ 3.5`: at `theta0 = 6.842` the score is `-0.1119` but the
derivative is `-8.07e-05` -- down a factor of **344** from the `-0.0277` it
was at upstream's start value `theta0 = 1.003` -- so the first step
`theta - score/deriv` overshoots to about `-1381` and overflows. That is the
`e+70` / `e+122` / `NaN` mechanism, and the basin edge is draw-specific.

The decisive number, on 40 **pinned** redraws of those same rows, with nothing
instrumented -- upstream's own `DoubleMLLPLR(...).fit()`, reading `.coef[0]`:
**17 of 40 (42%) return a non-finite or absurd coefficient** (`-648`, `5.18e+70`,
`8.44e+122`, `172149`, `nan` × 4, …), raising upstream's own `Could not find a
root of the score function` warning on 18 of 40. Upstream's `mean(beta)` over
those draws has mean 2.56, sd 3.39, range `[-3.21, 13.85]`, and this port's
`6.842` sits at the **90th percentile** -- an unremarkable draw, not a port bias.

So the clamp is not rescuing a defect this port introduced. It is covering a
fragility upstream shares and does not guard against either, and on this row set
it is what makes the port *no worse* rather than better. Record:
`_verify/LPLR_GATE_BLINDNESS_1680.md` sections 25g-25h and 27.

### ✅ DO

1. **Pass a classifier for `ml_m` wherever the propensity carries
   identification.** The estimators that need one default to
   `logistic_regression`; the ones that do not are named in **Propensity
   processing** above, with the measurement behind each. `ml_g` deliberately
   stays OLS -- it models `E[y | x]`, not `P(y = 1 | x]`.
   `LearnerDispatch::is_classifier()` reports which constructors qualify.
2. **Read the warnings.** `DoubleMLLPLR::fit()` can return a degenerate
   standard error, and it says so rather than returning a confident wrong
   number. LPLR's outcome is BINARY, so it takes a `DoubleMLBinaryData`
   rather than the `DoubleMLData` the other estimators take --
   `DoubleMLBinaryData::new` aborts on any outcome that is not 0 or 1:

   ```moonbit
   let data = @moonbit_doubleML.DoubleMLBinaryData::new(x, y, d)
   let model = @moonbit_doubleML.DoubleMLLPLR::new(data).fit()
   for w in model.warnings() { println(w) }
   ```

3. **Treat `n < 200` as ill-posed for partially logistic regression.** Both
   this port and upstream fail there, in opposite directions, and the port
   damps its Newton step to keep the answer finite.

### ❌ DON'T

1. **Don't read a small-n LPLR standard error as an estimate.** At `n = 500`
   the port and upstream agree to ~0.007. Below that the gate is a *report*,
   not a guarantee.
2. **Don't assume every `adjust_ps` call forwards `cv`.** The `adjust_ps`
   call sites that do not forward `cv` are **eight**, in seven files:
   `apo.mbt:320`, `cvar.mbt:736`, `cvar.mbt:1005`, `did.mbt:628`,
   `did_cross_section.mbt:615`, `did_cs_binary.mbt:374`, `quantile.mbt:217`
   and `ssm.mbt:671`. The only two that do are IRM's and IIVM's -- `cv=` is
   passed at `irm.mbt:430` and `iivm.mbt:525`.
3. **`DoubleMLRDD`'s shipped default arm is still the one absence.** `coef()` / `se()` are
   homoskedastic and **uncorrected**, so they are a *different estimator* from
   `rdrobust`'s default rather than a worse implementation of the same one, and matching
   them would be a re-specification rather than a bug fix. What `pyexample_rdd.py` gates is
   the arm that does match: `tau_bc` against upstream's `tau.bc` (measured gap **6.2e-15**
   absolute, **3.1e-15** relative) and `tau_bc_se_rb` against `se.rb` (**1.9e-15** absolute,
   **1.4e-14** relative), both at relative bound `1e-11`. The default arm
   is printed beside the gate on every run — `~5.9e-3` relative on the point estimate and
   `0.053x` upstream's on the SE (`~19x` smaller) — so the divergence is visible rather
   than asserted.

## Development status

| Item | Value |
|------|-------|
| Repository | `https://github.com/riantr/moonbit_doubleML` |
| Author | `riantr` |
| License | MIT (port of upstream `doubleml-for-py`, BSD-3-Clause) |
| `moon.mod` version | **0.164.37** |
| Toolchain | `moon 0.1.20261023` -- the version this release's tests, cross-checks and bit-exactness gate were run on, and the version every number in this table was re-verified on; a bare `moon` from `cli.moonbitlang.com` may be newer |
| Source layout | flat, `moonbit_doubleML/` (the library) |
| `.mbt` file count | **220** `.mbt` files (**65** production + **129** blackbox test + **26** whitebox test) |
| Estimators | **22** `DoubleML*` estimator structs (PLR / IRM / PLIV / IIVM / DID family / SSM / APO(S) / PQ / QTE / LPQ / LPLR / CVAR / RDD / BLP / PLPR / PolicyTree) |
| Backends | `native`, `wasm`, `wasm-gc`, `js` -- all pass `moon test --deny-warn` |
| Tests (native / wasm / js) | **1117 / 1117 / 1117** |
| Tests (wasm-gc) | **1123 / 1123** (lib + 6 doc tutorials) |
| Sandwich-variance coverage | **15 / 22** expose the scalar `sandwich_se` / `cluster_sandwich_se` / `bias_corrected_coef`; **4** more (`DoubleMLAPOS`, `DoubleMLDIDCS`, `DoubleMLDIDMulti`, `DoubleMLQTE`) expose per-cell variants `sandwich_se_at` / `..._at_idx`; **3** expose none of that API (`DoubleMLBLP`, `DoubleMLPolicyTree`, `DoubleMLRDD`) -- but `DoubleMLRDD` (v0.96.0) and `DoubleMLBLP` (v0.97.0) do expose a heteroskedasticity-robust `hac_se` under their own name; `DoubleMLPolicyTree` exposes no robust SE at all. Introduced v0.79.0 (on `DoubleMLIRM` and `DoubleMLPLR`), extended to **19 / 22** by v0.100.0 |
| Python cross-checks | **24 / 24 PASS** (`validate_*_with_python.py`); 25 of the 25 bit-exact items are IEEE-754 identical to CPython, and the 6 / 6 RNG keys are byte-identical |
| HTTP service | `examples/api_server/` -- hand-rolled on `moonbitlang/async`, no third-party framework |

### Validated against upstream, not only against ourselves

**Nine gates whose reference is UPSTREAM, not ours** -- the `pyexample_*`
family. Every script above compares the port against a second implementation
written in this repository, which on its own can only catch a disagreement
someone already thought to look for. The `pyexample_*` scripts instead run
upstream's own code on the port's rows and compare that: not "does the port
agree with our second implementation" but "does the port agree with upstream".

The `validate_*` family is not exclusively ours, though: **9** of its 24
scripts import the upstream `doubleml` wheel, and **2** of those gate the port
against upstream rather than only against a hand-rolled reference --
`validate_did_cs_binary_with_python.py` (the port's ATT against upstream's)
and `validate_lplr_with_python.py` (the port's coefficient against upstream's
*and* the hand-rolled one, together). The other **7** import the wheel for
context (`validate_apos`, `validate_cluster_iv`, `validate_cluster_plr`,
`validate_iivm`, `validate_irm`, `validate_pliv`, `validate_plpr`); upstream's
numbers are printed there, and in some of them upstream's own quantities are
separately gated rows.

Measured designs, one script per upstream class or family:

| script | upstream class | how the two sides get their rows |
|---|---|---|
| `pyexample_did.py` | `DoubleMLDID` on `make_did_SZ2020` | upstream's own DGP |
| `pyexample_did_cs2021.py` | `DoubleMLDIDMulti` on `make_did_CS2021` | upstream's own DGP |
| `pyexample_did_binary.py` | `DoubleMLDIDBinary` | shared rows |
| `pyexample_did_cs_binary.py` | `DoubleMLDIDCSBinary` | shared rows |
| `pyexample_lplr.py` | `DoubleMLLPLR` | shared rows + pinned outer partition |
| `pyexample_pq.py` | `DoubleMLPQ` / `DoubleMLQTE` / `DoubleMLLPQ` | integer-only DGP, rebuilt independently on both sides |
| `pyexample_policytree.py` | `DoubleMLPolicyTree` | integer-only DGP; the **label vector over every row** is compared, because the port's builder and upstream's `DecisionTreeClassifier` differ in threshold convention, criterion and leaf rule |
| `pyexample_rdd.py` | `DoubleMLRDD` vs `rdrobust` | integer-only DGP **with genuine non-collinear noise**; the bias-corrected arm is gated |
| `pyexample_suite.py` | the core estimator family | mixed |

### Numerical parity with CPython

**Bit-exact parity is a second, stronger tier.** A tolerance cannot tell "the
port is arithmetically identical to the reference" apart from "the port lands
within 1e-4 of it". `validate_bitexact_with_python.py` compares IEEE-754 bit
patterns instead, against `examples/bitexact/`. Measured scope, not assumed --
re-measured on `moon 0.1.20261023` vs CPython 3.13.14, unchanged from the
`moon 0.1.20261012` vs CPython 3.14 pair it was first taken on:

| operation | bit-exact | why |
|---|---|---|
| `+ - * /` | yes | IEEE-754 requires correct rounding, so same operands in the same order MUST agree |
| `sqrt` | yes | same guarantee -- **6 / 6** measured |
| `cos`, `sin` | observed 6 / 6 | agreement today, **not** guaranteed: neither is correctly rounded |
| `ln` | **5 / 6** | `ln(3.0)` differs by exactly 1 ULP: MoonBit `1.0986122886681096`, CPython `1.0986122886681098` |

Because `box_muller_pair` uses `ln`, `cos` and `sin`, **no random-number DGP in
this package can be bit-exact against CPython**, and neither can anything routed
through BLAS/LAPACK (numpy reduces with pairwise summation; LAPACK blocks its
pivots). The check therefore asserts the surface where bit-exactness is
guaranteed -- **25 / 25 items and 6 / 6 RNG keys, currently identical** -- and
prints the rest as deliberately not asserted, so the absence is not mistaken
for an oversight. A mutation battery (`_verify/_bitexact_mutation_1640.py`)
confirms the gate discriminates: all four mutations killed, including a
truncated and a mis-tiled RNG key.

### Not covered, so not claimed

The `coverage` check is a
test-reachability proxy, not instrumented line coverage. There is no
dependency-vulnerability scan -- `moon update` resolves versions, it is not an
audit. `mutation` kills three mutants on one kernel, not a whole-codebase
surviving-mutant ledger, and no CI workflow runs it. `examples/fuzz/` has no
crash-regression corpus, and its seed argument is **ignored** -- `fn main`
takes no parameters -- so the fuzz check replays one fixed master seed
(20260824) three times rather than sweeping seeds. Each invocation is a real
property-based run -- 11 surfaces, 300 trials per surface -- so the check
repeats that one run, and no CI workflow runs it either. And the two
declared `moon.mod` dependencies -- `moonbit-community/sqlite3@0.2.3`
and `moonbitlang/async@0.22.5` -- are dead: nothing imports them, and
`dependencies` already WARNs about exactly that (`2 declared; non-conforming:
['moonbit-community/sqlite3@0.2.3']; declared but unreferenced by library code:
['moonbit-community/sqlite3@0.2.3', 'moonbitlang/async@0.22.5']`) rather than
passing quietly. Removing them is an open call, not an oversight.

### Honest policy trees (v0.98.0)

`DoubleMLPolicyTree::new(features, orth_signal, depth = 1, honest = false,
split_seed = 2024, min_leaf_n = 5)` splits the sample when `honest` is on:
`policy_tree_build` sees only
the splitting half, and every reported leaf statistic (`leaf_assignment`,
`leaf_signal_mean`, `leaf_count`, `leaf_se`) is computed on the
estimation half. That is the honesty of Athey & Imbens (2016, PNAS
113(27):7353-7360), and it makes their property a property rather
than a claim: with the partition held fixed, a leaf value is a plain
sample mean, so `leaf_se[k] = sd(y_k) / sqrt(n_k)` has its usual
sampling interpretation. `is_honest()` reports which regime produced a
number, and `honest` defaults to `false` so existing callers are
byte-identical.

Two caveats are load-bearing and are documented in-source. Honesty
fixes the *bias*, not the small-leaf variance: Cattaneo, Klusowski &
Yu (arXiv:2509.11381) show that CART-type greedy splitting picks
highly imbalanced splits with nonvanishing probability and that
"sample splitting ... does not remove this limitation", which is why
`min_leaf_n` (default 5) guards on estimation-half leaf counts and
`unreliable_leaves()` names the offenders instead of reporting an
untrustworthy `leaf_se` silently. And a single honest tree spends
about half the sample on each of its two jobs -- Wager & Athey
(2018, JASA) recover that precision by averaging many honest trees,
which this package deliberately does not attempt.

`policy_value_se()` is the EXACT standard error of the plain sample
mean, **not** the tempting `sum_k (n_k/n)^2 se_k^2`: that form
assumes independent leaf means, but group means of one sample are
negatively correlated, and the independence form collapses to exactly
zero when all the variation is between leaves.

## Project layout

```
moonbit_doubleML/        <- the library (moon.mod v0.164.37, 220 .mbt files)
  moon.pkg              <- the package's imports and supported targets
  ...                    <- one file per estimator + DGPs + score / nuisance kernels
  vectorized.mbt         <- v0.81.0+ vectorised cross-fit helpers

doc/                     <- wasm-gc-targeted numbered tutorials
  001_introduction/
  ...
  006_python_check/

examples/                <- 21 driver binaries (all listed in moon.work)
  main/                  <- 12 estimators in 18 runs: 5 also run with
                            n_rep=5, and RDD runs twice (sharp, fuzzy)
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

moon.work                <- 23-member workspace aggregator (the library, doc/, 21 examples)
AGENTS.md                <- agent guide for coding agents (MoonBit convention)
skills/moonbit_doubleML.md  <- agent skill: API surface + anti-patterns
```

## Dependency rule

- Only official `moonbitlang/*` packages.
- Non-official packages may only be `riantr/*` (this repo).
- Pin to the latest published version (e.g. `moonbitlang/async@0.22.5`).
- Consequence: `examples/api_server/` builds directly on
  `moonbitlang/async`'s raw `Server` API. No third-party HTTP
  framework is allowed.

**Current state: the rule is not met, by one line.** `moonbit_doubleML/moon.mod`
declares two packages, and **neither is imported by any `.mbt` in the library**
(measured: 0 references each):

| declared | imported by the library? | note |
|---|---|---|
| `moonbitlang/async@0.22.5` | no | referenced by nothing: `examples/api_server/` uses the same package, but at its own pin -- `moonbitlang/async@0.20.3` -- so this line matches no import |
| `moonbit-community/sqlite3@0.2.3` | no | **not `moonbitlang/*`** -- added in v0.85.0 for `DoubleMLPolicyTree` memoisation, which now uses an in-memory `FitCache` |

So the library has no runtime third-party dependency today, while `moon.mod`
carries two dead entries -- one of which does not satisfy the rule above.
Deleting both lines is the change that would make this section true.

## Attribution

`moonbit_doubleML` is a port of the upstream
[`DoubleML/doubleml-for-py`](https://github.com/DoubleML/doubleml-for-py)
package (BSD 3-Clause License). Upstream's 19 name-matched estimator
classes are re-implemented in pure MoonBit with the same score
formulae and variance estimators, as is its RDD implementation
(`RDFlex` upstream, `DoubleMLRDD` here). `DoubleMLPLPR`,
`DoubleMLLPLR` and `DoubleMLDIDCSBinary` are **not** MoonBit-only -- all
three ship upstream, and are compared against it. The last candidate
for a port-only estimator, `DoubleMLDIDCrossSection`, is upstream's
`DoubleMLDIDCS` under a different name. One estimator does have **no
1:1 upstream class**: `DoubleMLDIDCS`, this port's variant of
upstream's multi-period `DoubleMLDIDMulti` -- see the estimator table
and `_verify/UPSTREAM_PROVENANCE.md`.

### Differences from upstream `doubleml-for-py`

- Native MoonBit package layout, type system, and test organization.
- Independent implementations of `Matrix`, linear / logistic
  regression, stratified K-fold, ChaCha8 PRNG, and Kahan summation
  in MoonBit; **no NumPy / scikit-learn dependency**.
- `DoubleMLData` / `DoubleMLXxx::new().fit()` as the canonical
  MoonBit-idiomatic API, on native / wasm-gc / wasm / js backends
  (Serverless / Wasm / edge deployments). The library exports
  **no** JSON in/out -- the JSON surface is `examples/api_server/`'s
  own request/response encoding.
- Behaviour-level parity check via the 24 Python reference scripts: 23
  compare under `within-tolerance equivalence`, and one
  (`validate_bitexact_with_python.py`) compares IEEE-754 bit patterns
  instead. The tolerance tier keeps the port resilient to upstream
  refactors; the bit-exact tier is where it must not drift at all.
- Strict dependency rule (see above): only `moonbitlang/*` official
  packages -- **one declared line does not meet it today**
  (`moonbit-community/sqlite3`, which nothing imports). The
  library's runtime supply chain is still `moonbitlang/core`
  only.

## Used By

- [`riantr/pyroduct`](https://mooncakes.io/docs/riantr/pyroduct) --
  downstream consumer that models Ren Yongxiang's MA thesis
  (Gadamer/Habermas, Shanghai Academy of Social Sciences 2008)
  plus its appendix as runnable multi-agent state machines. Its
  `dmlref` package cross-checks its own from-scratch DoubleML
  PLR against `riantr/moonbit_doubleML`: same nuisance (OLS),
  `n = 400`, true `theta = 1.5`, `theta` delta `0.017` (1.667 vs
  1.685) and `se` delta `0.001` (0.153 vs 0.152).
  Source lives on
  [`gitee.com/ren-yongxiang/pyroduct`](https://gitee.com/ren-yongxiang/pyroduct).
- `examples/api_server/` -- this repo's HTTP service.
- `examples/consumer_demo/` -- minimal end-to-end PLR showing the
  consumer-side import pattern (`moon add riantr/moonbit_doubleML`).

## Development

The test suite, the Python cross-checks, the QA harness and the
reproducibility commands are all documented in `ENGINEERING.md`, together with
the history of the defects that moved the estimator defaults and the
derivation of the upstream naming map. Both files are in the repository; the
registry publishes this one.

```console
$ moon test --target native --deny-warn
Total tests: 1117, passed: 1117, failed: 0.
```

## License

MIT. The upstream package, `DoubleML/doubleml-for-py`, is BSD 3-Clause; this
port is MIT-licensed and credits it (see **Attribution** above).
