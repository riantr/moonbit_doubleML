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
| `moon.mod` version | **0.131.2** |
| Source layout | flat, `moonbit_doubleML/` (the library) |
| `.mbt` file count | **197** `.mbt` files (**90** production + **107** test) |
| Estimators | **22** `DoubleML*` estimator structs (PLR / IRM / PLIV / IIVM / DID family / SSM / APO(S) / PQ / QTE / LPQ / LPLR / CVAR / RDD / BLP / PLPR / PolicyTree) |
| Backends | `native`, `wasm`, `wasm-gc`, `js` -- all pass `moon test --deny-warn` |
| Tests (native / wasm / js) | **1005 / 1005 / 1005** |
| Tests (wasm-gc) | **1011 / 1011** (lib + 6 doc tutorials) |
| Sandwich-variance coverage | **15 / 22** expose the scalar `sandwich_se` / `cluster_sandwich_se` / `bias_corrected_coef`; **4** more (`DoubleMLAPOS`, `DoubleMLDIDCS`, `DoubleMLDIDMulti`, `DoubleMLQTE`) expose per-cell variants `sandwich_se_at` / `..._at_idx`; **3** expose none (`DoubleMLBLP`, `DoubleMLPolicyTree`, `DoubleMLRDD`). Introduced v0.89.0 |
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
in 19 source files. The 19 marked *(upstream)* mirror the upstream
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

**`ps_processor_config` is reachable (v0.121.0+, IRM v0.122.0, IIVM and SSM
v0.123.0, PQ v0.124.0, LPQ v0.125.0, CVaR v0.126.0, DID v0.127.0, CS-DID
v0.128.0).** `DoubleMLAPO`, `DoubleMLAPOS`, `DoubleMLIRM`, `DoubleMLIIVM`,
`DoubleMLSSM`, `DoubleMLPQ`, `DoubleMLLPQ`, `DoubleMLCVAR`, `DoubleMLDID`,
`DoubleMLDIDBinary`, `DoubleMLDIDCSBinary`, `DoubleMLDIDCrossSection` and
`DoubleMLDIDCS` now take a `PSProcessorConfig`, which is how the isotonic
and CV-calibration paths become callable from an estimator at all --
until v0.121.0 they were implemented and reachable from nowhere.
Resolution follows upstream's `init_ps_processor`: **the config wins
outright** and the deprecated scalar `propensity_clip` is read into it
only when no config is supplied. Measured against upstream 0.11.4, the
calibration is not cosmetic -- isotonic moves the propensity by up to
0.53 on the test fixture, the APO coefficient moves from
2.9641677613312316 to 2.9602088935501736, the IRM coefficient from
1.9609911300451515 to 1.9603016544875, and the CVaR coefficient runs
3.664307496539196 -> 3.3179262532001292 across the clip sweep (isotonic
lands at 3.471229424883473). CVaR is worth singling out because it is the
first estimator here whose estimate is *genuinely* a weighted quantile:
LPQ's root is pinned by its bisection bracket, so no threshold could move
it, while CVaR solves `mean(treated/m * 1{y <= theta}) = quantile` and
therefore does move.

Six details worth knowing before wiring it yourself. First, which array
is the calibration target differs by estimator, and upstream is not
uniform: `DoubleMLIIVM` passes the **instrument `z`**, not the treatment
`d` (`iivm.py:371`), because `m` is the propensity *of the instrument*;
`DoubleMLPQ` passes `treated`, the indicator it actually regresses on.
Second, `DoubleMLSSM` adjusts `m` only -- its selection propensity `pi`
is clipped but **never calibrated**, matching upstream (`ssm.py:407` vs
`ssm.py:414`). Third, on `DoubleMLLPQ` this port deliberately does
**not** overwrite `propensity_clip` with the config threshold the way
upstream does (`lpq.py:166`), because that scalar also floors the
estimated complier share here; upstream has no such floor, and where it
bites the two diverge by 4.2x. On `DoubleMLCVAR` the *opposite* choice is
made and is correct: upstream redirects the scalar to the config's
threshold (`cvar.py:156`) and so does this port, because all three of its
uses -- the preliminary clip, the final clip, and the re-clip inside
`sensitivity_analysis` -- are that same threshold and there is no second
job for it to disturb. Note also that CVaR's two `adjust_ps` sites take
*different* second arguments: the preliminary one is `d_train_1`
(`cvar.py:293`), the final one is the full `d` (`cvar.py:343`), and
swapping them aborts on `adjust_ps`'s length precondition. The third use is
worth a caveat -- `irm_style_sensitivity` has no `psi_b` parameter, so the
`psi_b` CVaR computes there is discarded and `propensity_clip` cannot reach
the returned `SensitivityResult` by any route. That is pre-existing, and
`v126_sensitivity_reclip_is_structurally_inert` pins it. Fourth, `adjust_ps`
requires a **binary**
treatment; `treatment_is_binary` is public if you want to check first. Fifth,
on `DoubleMLDID` / `DoubleMLDIDBinary` the resolution deliberately does **not**
read `propensity_clip`. Upstream's deprecated scalar there is
`trimming_threshold`, defaulted at `1e-2` (`did_binary.py:123`), and this
port's `PSProcessor::new()` also defaults to `1e-2` -- but this port's
`propensity_clip` defaults to `1e-6` and is read **only** by the inner
`cross_fit_did`'s `clip_vec`, a numerical-safety clip with a genuinely
different job. Redirecting it would silently turn the default public clip
from 1e-2 into 1e-6. So with no config supplied the stored threshold stays
`1e-2` whatever `propensity_clip` says, and the two knobs stay independent.
That family also has just **one** `adjust_ps` site (`did_binary.py:537`), and
that ATT responds much more strongly on the raw `DoubleMLDID` (spread 2.25e-2
across the clip sweep) than through the panel wrapper (1.8e-3, a 12x
damping), so the wrapper's gate is written as an exact inequality rather than
a threshold. Sixth, `DoubleMLDIDCSBinary` deliberately uses the group
indicator `G` for **both** its propensity regression and its `adjust_ps`
calibration -- so it models `P(G=1|X)`, not `P(D=1|X)`. That is **correct**,
and v0.128.0 got it wrong. Upstream's local variable at
`did_cs_binary.py:504` and `:516` is spelled `d`, but it is bound at `:472` to
`self._g_data_subset`, and that line's own trailing comment reads
`# (d is the G_indicator)`. The trap is that the data column is *also* called
`d`, and on a staggered design the two differ on 109 of 720 evaluated rows
(the two fits disagree by up to 0.365) -- so the substitution is large and
visible, and still correct. Confirmed at runtime by capturing the arguments
at both upstream call sites (`_verify/_oracle_1290.py`), not by reading names.
The invariant is stronger than a comment: **nothing in
`DoubleMLDIDCSBinary`'s fit path reads `data.d`**, so scrambling the treatment
column must leave the estimate bit-identical --
`v129_cs_binary_never_reads_the_treatment_column` pins exactly that, and
`v129_cs_binary_nuisance_is_a_group_propensity_like_upstream` keeps the
fixture premise. `DoubleMLDID` (panel) and `DoubleMLDIDCrossSection` do use
the real `D`, because upstream's counterparts there do
(`did.py:197` reads `self._dml_data.d`).
Seventh, and fixed in **v0.130.0**: `DoubleMLDIDCSBinary::sensitivity_analysis`
used to read `self.data.y[i]` and `self.data.d[i]` — the **full 1080-row
panel**, indexed at **subset** positions, with the per-period treatment rather
than `G`, and with a 2-way `y - g00 - (g10 - g00)*d` form that always used the
`T = 0` g-function. Upstream uses the subset's own `y`/`G`/`T_indicator`
(`did_cs_binary.py:846-867`) and mixes the four `(G, T)` cells. Measured, **240
of the 720 rows read had `t == 1`** — a period the subset never contains, and
the one in which `y` carries the treatment effect. `sigma2` came out **583x**
too large (1.1473 vs 0.00197), and **no test in the package exercised the
function at all**. `irm_style_sensitivity`'s `require(n == psi_a.length())`
guard passed throughout, because both arrays were length 720 while describing
different observations. Fixed, and both entry points now share one builder
(`cs_bin_sensitivity_residuals`) so they cannot drift apart again. `DoubleMLLPLR`, `DoubleMLRDD` and friends have **no upstream sensitivity
implementation at all** — upstream sets `_sensitivity_implemented = True` for
only seven classes (`did`, `did_binary`, `did_cs`, `did_cs_binary`, `apo`,
`irm`, `plr`), LPQ's `_sensitivity_element_est` is a bare `pass`, and
`ssm`/`lplr`/`plpr` explicitly disable it. So the port's extra sensitivity
entry points are **extensions, not divergences**. Eighth, fixed in
**v0.131.0**: for the seven that *are* upstream-faithful, the shared `nu2` was
`mean(psi_a^2)` — which is upstream's *fallback* formula, used only when the
primary comes out non-positive (`double_ml.py:1634-1641`) — and it was applied
to `psi_a`, the score's base element, rather than to `rr`, the **Riesz
representer**, which upstream keeps deliberately separate. The primary is
`nu2 = mean(2*m_alpha - rr^2)` (`did_cs_binary.py:932`). Measured: `nu2`
3.3028 → 26.7189 (8.1×), `rv` 12.2969 → 4.3234. `psi_sigma2`/`psi_nu2` turn
out to be **dead** on this path — they feed only `psi_max_bias`, which every
caller discards — so the whole reported result is a function of `sigma2` and
`nu2` alone. `DoubleMLDIDCSBinary` was migrated to
`irm_style_sensitivity_from_elements`; `did`, `did_binary`, `did_cs`, `apo`,
`irm` and `plr` still use the old convention and each needs its own
`m_alpha`/`rr` plumbing. Also still open: upstream defaults
`in_sample_normalization` to `True` (`did_cs_binary.py:118`) and this port to
`false` (`did_cs_binary.mbt:712`), which moves `coef` and `se`.
The config is also folded into the memoize key, not just its threshold,
so two estimators sharing a `clipping_threshold` but differing in
calibration are kept apart.

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

**RDD's own robust variance is a different thing again (v0.110.0-v0.116.0).**
Neither `se()` nor `hac_se()` is `rdrobust`'s robust variance for the
bias-corrected estimator, and RDD has a whole family of its own:

- `optimal_bandwidth()` / `optimal_bias_bandwidth()` -- `rdrobust`'s
  `bwselect = "CCT"` MSE-optimal estimation bandwidth `h` and
  bias-correction bandwidth `b`. They are different numbers because a
  degree-`j` local polynomial's bias is `O(h^(j+1))`, so the point
  (`p = 1`) and bias (`q = 2`) criteria carry different variance
  exponents. Measured `b / h = 0.907`.
- `nn_residual(x, y, nnmatch?)` -- the fit-free nearest-neighbour matched
  residual, transliterated from upstream's `_nn_residuals_jit` including
  its mass-point block walk. Byte-identical to the oracle at four
  `nnmatch` values and on a mass-point fixture.
- `tau_bc()` -- the bias-corrected point estimate, procedure (ii) and
  (iii) alike.
- `tau_bc_se_rb(vce = "nn" | "hc0")` -- procedure (iii)'s standard
  error. Its meat matrix is `Q`, the p-order fit *minus* its estimated
  bias term, with the p-order Gram at `h` as bread even though the
  estimate is a q-order quantity at `b`.

These are opt-in and leave `coef()` / `se()` untouched. They are checked
against the upstream Python port of `rdrobust`, not against internal
identities -- see the oracle paragraph below. Sharp designs only: fuzzy
CCT delta-method terms are not ported.

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

**An upstream ORACLE for RDD (v0.116.0)** -- the scripts above check
against hand-written reference outputs, which can only catch a
disagreement someone already thought to look for. RDD now also has a real
oracle: the **Python port of `rdrobust` shipped in the upstream
repository `rdpackages/rdrobust`**
(`Python/rdrobust/src/rdrobust/`), pinned under
`_verify/_upstream_rdrobust_py/` and runnable via `_verify/_oracle/`.
`_verify/gen_v116_oracle.py` calls it and writes
`_verify/_v116_golden.json`; every constant in
`moonbit_doubleML/expand_v116_test.mbt` comes from that file.

It earns its keep. The oracle found that v0.115.0's `tau_bc` -- which had
a green suite and two gates asserting a stated identity -- was not
`rdrobust`'s bias-corrected estimate whenever `b != h`. The v0.115.0 gate
had compared two internal routes to the same wrong number, so no
internal assertion could ever have caught it. `_verify/mut_v116_rdd.ps1`
records the equivalent.

**Docs & demos** -- 6 `doc/<NNN_...>/` tutorials targeting `wasm-gc`,
plus 19 `examples/<bin>/` driver binaries (all listed in
`moon.work`), of which `examples/api_server/` is an HTTP service
built directly on `moonbitlang/async@0.20.3` -- no third-party HTTP
framework is pulled in.

**Strict dependency hygiene** -- only official `moonbitlang/*` packages
in the library. Non-official deps restricted to `riantr/*` (this
repo). Reproducible builds, minimal supply-chain surface.

**Learner injection via `LearnerDispatch`** -- every estimator's
`new()` / `fit()` accept `ml_g` / `ml_m` / `ml_l` / `ml_r` typed
optionals. Default is `LearnerDispatch::linear_regression()` (OLS).
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
learner surface. This package ships eleven. The four tree/logistic
learners' `predict` returns `P(y = 1 | x)` for classification, never a
hard label, because DML's AIPW correction divides by the fitted
propensity.

**The regularised learners penalise the slopes, not the intercept.**
All three centre the design, solve for the slopes, and recover the
intercept as `y_mean - x_mean . beta`; scikit-learn does the same.
Folding the intercept into `X` as a column of ones -- which is what
`LinearRegression` does -- and penalising it is a *different estimator*,
and the two intercepts differ by 2.7e-2 at `alpha = 0.7`.

**`alpha` means two different things across the two families.** `Ridge`
minimises `||y - Xw||^2 + alpha*||w||^2`; `Lasso` / `ElasticNet`
minimise `(1/2n)||y - Xw||^2 + alpha*(...)`. Equal numeric `alpha`
therefore shrinks far harder for Lasso. The identity that pins it:
`ElasticNet(l1_ratio = 0, alpha = a) == Ridge(alpha = a*sum(sample_weight))`
-- note `sum(sample_weight)`, which reduces to `n` unweighted.

**Learner surface is at parity with doubleml 0.11.4.** An earlier
version of this README listed "GLM families (Poisson, Gamma, negative
binomial)" as a gap. **That was wrong**, in the same way an earlier
release claimed a `ps_dm` the sdist does not contain: doubleml 0.11.4
has no `DoubleMLPoisson` / `DoubleMLGamma` / `DoubleMLNegativeBinomial`,
and no `PoissonRegressor` / `GammaRegressor` / `QuantileRegressor`
anywhere in it. `DoubleMLPQ` fits its outcome model as a *classifier on
the indicator `1{y <= theta}`* (`pq.py:253`, `pq.py:390`), which this
port already has. GLMs would be an extension beyond upstream, not a
parity gap.

`sample_weight` landed in v0.118.0 -- the trait
is `fit(x, y, sample_weight)` with an empty array meaning unweighted,
matching upstream's protocol and scikit-learn's `sample_weight=None`.

`RFLearner`, `GBLearner`, `RFClassifier` and `GBClassifier` reach the 5
specialised internals -- `DoubleMLDIDCrossSection::crossfit_nuisance`,
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

19 `examples/<bin>/` directories in `moon.work`. 18 run end-to-end on
synthetic DGPs: 17 are CLI-style numeric demos (print true-vs-estimated
theta and a 95 % CI); the 18th -- `examples/api_server/` -- is an HTTP
service. The 19th -- `examples/consumer_demo/` -- is the library-user
pattern that mirrors what an external `moon add riantr/moonbit_doubleML`
consumer would write.

`examples/apo/` and `examples/apos/` are the pair worth reading together:
APO returns the potential outcome AT one treatment level, APOS returns
those levels plus pairwise CONTRASTS, and a contrast is off by the
reference level's entire outcome. `examples/apo/` prints both so the gap
is visible rather than described.

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
| `examples/apo`, `examples/apos` | `DoubleMLAPO` / `DoubleMLAPOS` | 3-level discrete treatment: the LEVEL `E[Y(t)]` vs the CONTRAST | 1.0 / 2.5 |
| `examples/cvar` | `DoubleMLCVAR` | CVaR | 1.0 |
| `examples/ssm` | `DoubleMLSSM` | Sharp synthetic treatment | 1.0 |
| `examples/cluster` | `DoubleMLPLIV` / `DoubleMLPLR` + `cluster_*` | Clustered data, cluster-robust SEs | 1.0 |
| `examples/splitting` | `DoubleMLPLR` + `set_sample_splitting` | External sample splitting | 1.0 |
| `examples/pava` | `pava` core | Isotonic regression, exact (no MC error) | 1.0 |
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
| `DoubleMLDIDCSBinary` | observational | CS-DID with binary outcome *(upstream)* |
| `DoubleMLDIDMulti` | observational | multi-period DID with group-time ATT aggregation *(upstream)* |
| `DoubleMLDIDCrossSection` | observational | Sant'Anna-Zhao 2020 cross-section DID *(upstream)* |
| `DoubleMLSSM` | MAR | sample selection (missing-at-random) *(upstream)* |
| `DoubleMLAPO` | policy score | average prescriptive effect *(upstream)* |
| `DoubleMLAPOS` | policy score | APO with stratified treatment *(upstream)* |
| `DoubleMLPQ` | quantile | potential quantile *(upstream)* |
| `DoubleMLQTE` | quantile | quantile treatment effect *(upstream)* |
| `DoubleMLLPQ` | local polynomial | local potential quantile *(upstream)* |
| `DoubleMLLPLR` | partialling-out | partially logistic regression, Liu-Zhang-Zhou 2021 *(upstream)* |
| `DoubleMLCVAR` | CVaR | conditional value-at-risk *(upstream)* |
| `DoubleMLRDD` | observational | regression discontinuity *(upstream)* |
| `DoubleMLBLP` | IV | best linear predictor of treatment effect *(upstream)* |
| `DoubleMLPLPR` | partialling-out | partially linear panel regression, Clarke-Polselli 2025 *(upstream)* |
| `DoubleMLPolicyTree` | policy | policy tree *(upstream)*, + v0.98.0 honest split (`honest = true`) with `leaf_se` / `policy_value_se` |

**Provenance (v0.103.0).** Every one of the 22 has a counterpart in
`doubleml` 0.11.4 -- verified against the published sdist, not the
GitHub tree, so this is the shipped artefact. Modules:
`plm/{plr,pliv,lplr,plpr}.py`, `irm/{irm,iivm,apo,apos,pq,qte,lpq,cvar,ssm}.py`,
`did/{did,did_binary,did_cs,did_cs_binary,did_multi}.py`, `rdd/rdd.py`
(the class there is `RDFlex`), `utils/{blp,policytree}.py`.

Three rows were previously marked *(extra)* -- `DoubleMLDIDCSBinary`,
`DoubleMLLPLR`, `DoubleMLPLPR`. That was wrong: all three ship
upstream, so they had a reference implementation all along and
simply were not being compared against it. The labels are corrected
here. `DoubleMLDIDCSBinary` and `DoubleMLDIDBinary` are absent from
upstream's `__all__` but present as importable classes in their
modules.

### Honest policy trees (v0.98.0)

`DoubleMLPolicyTree::new(x, orth_signal, depth, honest = true,
split_seed = 2024)` splits the sample: `policy_tree_build` sees only
the splitting half, and every reported leaf statistic (`leaf_assignment`,
`leaf_signal_mean`, `leaf_count`, `leaf_se`) is computed on the
estimation half. That is the honesty of Athey & Imbens (2016, PNAS
113(27):7353-7358), and it makes their property a property rather
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

examples/                <- 19 driver binaries (all listed in moon.work)
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
  sites through it. `DoubleMLDIDCrossSection` was deliberately NOT
  routed then, on the stated ground that it is a projection
  (`argmin_theta`) estimator with the offset / slope roles
  inverted and its own `se` formula -- **v0.102.0 removed that
  exception**: upstream `DoubleMLDIDCS` is a `LinearScoreMixin`
  subclass on the plain linear score, so this port's `fit` now
  routes through `var_est` like the others and its sandwich uses
  the same order. See `CHANGELOG.md` v0.102.0, including the
  measured point estimate and SE.
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