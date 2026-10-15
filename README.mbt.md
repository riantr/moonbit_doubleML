# moonbit_doubleML - Double / Debiased Machine Learning in MoonBit

A pure-MoonBit port of the
[`doubleml-for-py`](https://github.com/DoubleML/doubleml-for-py) Python
package -- the Python ecosystem's most mature Double / Debiased Machine
Learning implementation -- 22 estimators in total. **20** match a
class of the same name in upstream; `DoubleMLRDD` is upstream's RDD
estimator renamed (upstream calls it `RDFlex`); and
`DoubleMLDIDCrossSection` has no upstream counterpart at all. Those
provenance labels are re-measured against the published `doubleml`
0.11.4 sdist, not asserted -- see the estimator table below.
`DoubleMLPLPR`, `DoubleMLLPLR` and `DoubleMLDIDCSBinary` were for
several releases described here as MoonBit-specific extras; all three
ship upstream and the table marks them *(upstream)*.

Targets library authors and tool developers who need causal inference,
panel data estimation, instrumental variable estimation, regression
discontinuity, policy evaluation, or interpretable machine learning
inside the MoonBit ecosystem. Delivers a unified
`DoubleMLXxx::new(data, n_folds, n_rep, seed).fit()` API across all
22 estimators, robust variance estimation, propensity-score
processing, multiple-testing correction, and a reproducible validation
pipeline (24 / 24 Python reference scripts PASS) -- on `native`,
`wasm`, `wasm-gc`, and `js` backends under `moon test --deny-warn`.

##Status

| Item | Value |
|------|-------|
| Repository | `https://github.com/riantr/moonbit_doubleML` |
| Author | `riantr` |
| License | MIT (port of upstream `doubleml-for-py`, BSD-3-Clause) |
| `moon.mod` version | **0.163.0** |
| Source layout | flat, `moonbit_doubleML/` (the library) |
| `.mbt` file count | **220** `.mbt` files (**65** production + **129** blackbox test + **26** whitebox test) |
| Estimators | **22** `DoubleML*` estimator structs (PLR / IRM / PLIV / IIVM / DID family / SSM / APO(S) / PQ / QTE / LPQ / LPLR / CVAR / RDD / BLP / PLPR / PolicyTree) |
| Backends | `native`, `wasm`, `wasm-gc`, `js` -- all pass `moon test --deny-warn` |
| Tests (native / wasm / js) | **1115 / 1115 / 1115** |
| Tests (wasm-gc) | **1121 / 1121** (lib + 6 doc tutorials) |
| Sandwich-variance coverage | **15 / 22** expose the scalar `sandwich_se` / `cluster_sandwich_se` / `bias_corrected_coef`; **4** more (`DoubleMLAPOS`, `DoubleMLDIDCS`, `DoubleMLDIDMulti`, `DoubleMLQTE`) expose per-cell variants `sandwich_se_at` / `..._at_idx`; **3** expose none (`DoubleMLBLP`, `DoubleMLPolicyTree`, `DoubleMLRDD`). Introduced v0.89.0 |
| Python cross-checks | **24 / 24 PASS** (`validate_*_with_python.py`); 25 of the 25 bit-exact items and 6 / 6 RNG keys are IEEE-754 identical to CPython |
| HTTP service | `examples/api_server/` -- hand-rolled on `moonbitlang/async`, no third-party framework |

##Features

**Pure-MoonBit, all-4-backends port of `doubleml-for-py`** -- 22 `DoubleML*`
estimators (`DoubleMLPLR`, `DoubleMLIRM`, `DoubleMLPLIV`, `DoubleMLIIVM`,
`DoubleMLDID`, `DoubleMLDIDBinary`, `DoubleMLDIDCS`,
`DoubleMLDIDCSBinary`, `DoubleMLDIDMulti`, `DoubleMLDIDCrossSection`,
`DoubleMLSSM`, `DoubleMLAPO`, `DoubleMLAPOS`, `DoubleMLPQ`,
`DoubleMLQTE`, `DoubleMLLPQ`, `DoubleMLLPLR`, `DoubleMLCVAR`,
`DoubleMLRDD`, `DoubleMLBLP`, `DoubleMLPLPR`, `DoubleMLPolicyTree`)
in 19 source files. **20** are marked *(upstream)* and mirror a
name-identical `doubleml-for-py` class. `DoubleMLRDD` is marked
*(upstream, renamed)* -- upstream calls it `RDFlex`. One row,
`DoubleMLDIDCrossSection`, is marked *(no upstream counterpart)*.
Three rows -- `DoubleMLDIDCSBinary`, `DoubleMLLPLR`, `DoubleMLPLPR`
-- were previously marked *(extra)*, which was wrong: all three ship
upstream, so they had a reference implementation all along.

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
| `linear_regression` | **-225.86** | 0.043 |
| `logistic_regression` | **1.44** | 0.842 |

The port used to default `ml_m` to `LearnerDispatch::linear_regression()`
everywhere. **`DoubleMLIRM` was migrated in v0.132.0**,
**`DoubleMLAPO` in v0.134.0**, **`DoubleMLAPOS` in v0.135.0**,
**`DoubleMLSSM` in v0.138.0** and **`DoubleMLPQ` / `DoubleMLQTE` in
v0.139.0**:
their `ml_m` default is now
`LearnerDispatch::logistic_regression(LogisticRegression::new())`, while
`ml_g` deliberately stays OLS (it models `E[y | x]`, not `P(y = 1 | x]`), so the
two defaults diverge on purpose. `LearnerDispatch::is_classifier()` reports
which constructors qualify.

The migrations do NOT all have the same margin, and the gates are shaped
accordingly. `DoubleMLIRM` on a saturated-propensity fixture (true `ATE = 1.5`)
across three seeds: default recovers within `0.198`, an OLS propensity misses
by at least `72.8` -- a 366x separation on the coefficient. `DoubleMLAPO`
(true `E[Y | D=1] = 1.2`): default within `0.531`, OLS misses by as little as
`5.246` -- only ~10x. APO's standard error is the honest discriminator
(`0.270` vs `86.28`, a 300x separation), because the mechanism is that an
unbounded propensity makes `1 / m_hat` explode and takes the variance with it.

`DoubleMLSSM` has the largest margin of the four, because its score carries
**two** reciprocals, one per direction (`ssm.mbt:73-74`): the treatment
propensity `m` and the selection propensity `pi`, so an unbounded regressor
breaks both denominators independently. On a saturated fixture with true
`theta = 1.0`, the OLS arm returns `242.116` with SE `185.45` where the
classifier returns `1.177` with SE `0.0982` -- roughly **200x** on the point
estimate and **1900x** on the standard error. Across three seeds the OLS
coefficient also **changes sign** (`+242`, `+106`, `-452`); the classifier's
spread over the same three seeds is `0.761`.

One caveat worth stating plainly: on a *mild* fixture, where the true
propensity never reaches the `0.02`/`0.98` clamp, the two learners agree to
three decimals and OLS is marginally better. The hazard is a property of the
clamp, not of the estimator in general, and the gate suite pins both regimes so
a future change cannot be scored on the flattering fixture alone.

**Nine structs still default `ml_m` to `linear_regression()`**:
`DoubleMLCVAR`, `DoubleMLDID`, `DoubleMLDIDBinary`,
`DoubleMLDIDCrossSection`, `DoubleMLDIDCS`, `DoubleMLDIDCSBinary`,
`DoubleMLDIDMulti`, `DoubleMLIIVM`, `DoubleMLLPLR`. Until each is
migrated, pass a classifier explicitly:

```moonbit
ml_m = LearnerDispatch::logistic_regression(LogisticRegression::new())
```

`LearnerDispatch::RandomForestClassifier` and
`LearnerDispatch::GradientBoostingClassifier` are the nonlinear options.

**The hazard is NOT uniform, and was measured per-estimator** (v0.136.0).
Migrating `DoubleMLDIDBinary` was attempted and abandoned on the evidence:
across four probe designs and ~14 configurations its OLS default matched a
logistic one to within ~1e-4, and where they differed the OLS default was the
BETTER of the pair. The reason is structural. In the observational DID score
(`did.mbt:708`) `w_d = d_i / m_i`, so `1 / m` enters **only for treated
rows** (controls get `w_d = 0`), and the score is **doubly robust** -- a
correct `g` carries identification, leaving `m` second-order. IRM and APO need
`m` for the estimand itself, which is why they showed a ~200-point error and
DID shows ~0.001. The sharpest DID case: at n=200 the CLASSIFIER default is
worse on both bias (0.0776 vs 0.00050) and SE.

| Estimator | OLS default | Evidence |
|---|---|---|
| `DoubleMLIRM` | hazardous | coef `-225.86` vs `1.44` |
| `DoubleMLAPO` | hazardous | bias `5.246` vs `0.531`; SE `86.28` vs `0.270` |
| `DoubleMLAPOS` | hazardous | per-level bias to `436.11` |
| `DoubleMLDIDBinary` | **not demonstrated** | 4 designs, ~14 configs, ~1e-4 |
| `DoubleMLSSM` | **hazardous -- fixed in v0.138.0** | coef `242.116` vs `1.177` |
| `DoubleMLCVAR` | not demonstrated | `2.300` vs `2.373` |
| `DoubleMLQTE` | **hazardous -- fixed in v0.139.0** | frozen at `-1.583` for tau 0.50-0.90 |
| `DoubleMLIIVM` | not demonstrated | `0.987` vs `1.031` (16x *smaller* SE) |
| `DoubleMLPLR` | not demonstrated | `1.015` vs `1.103` -- OLS better |
| `DoubleMLLPLR` | **not demonstrated -- root-caused in v0.140.0-v0.142.0** | not an `ml_m` hazard; two failure modes; see below |
| `DoubleMLPQ` | **hazardous -- fixed in v0.139.0** | ignored its `quantile` entirely |

All eleven remaining defaults were measured in v0.137.0. **Three showed a
defect: `DoubleMLSSM`** (`242.116` vs `1.177` -- its score divides by `m*pi`
AND `(1-m)*pi`, two reciprocals in both directions, `ssm.mbt:73-74`), **and
`DoubleMLPQ` / `DoubleMLQTE`**, which ignored their `quantile` outright.
SSM was fixed in v0.138.0 and the quantile pair in v0.139.0. The other eight
keep their OLS default **on measured evidence**. `DoubleMLLPLR`'s degenerate
standard error is real and was root-caused in v0.140.0, but it is **not** an
`ml_m` defect -- see the note below.

A static classifier (read the score: does it carry `1/m`? is it doubly robust?)
was used to prioritise the probes, and it reproduces all four earlier outcomes
-- but `DoubleMLIIVM` **refuted** it, carrying `1/m` and `1/(1-m)` on every row
and still measuring harmless. A reciprocal in the score is not sufficient for
the hazard; the classifier is a way to decide what to measure first, nothing
more.

> **`DoubleMLPQ` IGNORED its `quantile` argument on the default path -- fixed in
> v0.139.0.** An ordinary caller who never mentioned `ml_m` got the identical
> coefficient at every tau:
>
> | tau | old default (OLS `ml_m`) | shipped now |
> |---|---|---|
> | 0.10 | -0.38571498836568785 | -0.38571498836568785 |
> | 0.25 | **-0.38571498836568785** | 0.5268291897597495 |
> | 0.50 | **-0.38571498836568785** | 0.9570929867084059 |
> | 0.75 | **-0.38571498836568785** | 1.2753280162498020 |
> | 0.90 | **-0.38571498836568785** | 1.2753280162498020 |
>
> Cause: `score[i] = treated[i] / m[i] * 1{y[i] <= theta} - q`
> (`quantile.mbt:127`) with `m` clipped to `[propensity_clip, 1 - propensity_clip]`
> (`quantile.mbt:175-177`). An unbounded regressor propensity predicts outside
> `[0,1]`, so treated rows saturate at `m = 1e-6` and carry weight `1e6`; the
> IPW distribution is then dominated by whichever rows saturated and its
> tau-quantile is the same for every `q in (0,1)`. `DoubleMLQTE` shares
> `solve_pq`, and did freeze too -- at `-1.5829876410256796` for tau 0.50-0.90.
>
> **Every PQ test that existed passed `quantile=0.5`**, so nothing could catch
> this. `expand_v139_test.mbt` now sweeps five taus on the shipped path across
> two fixtures, counting changed steps with *exact* inequality -- the defect is
> an exact tie, and a tolerance would hide it.
>
> **The residual tie at tau 0.75 / 0.90 is a PLATEAU COLLISION, not a freeze**
> (root-caused in v0.143.0). The score is a **step function** of theta:
> `iy = if y[i] <= theta { 1.0 } else { 0.0 }` (`quantile.mbt:126`), so
> `mean(psi)` is constant between observed outcomes. Two taus whose crossings land
> on the same step get the same root. Measured in a 0.05-wide window around the
> tied value: **25 distinct plateaus**, longest flat run **62 of 400** grid steps.
>
> Two explanations were tested and **both refuted**:
>
> 1. *A gap in the weighted distribution* -- no. At seed 17 the treated outcomes
>    are **1033 of 1033 distinct**, 0.75-quantile `3.2723` vs 0.90-quantile
>    `3.8917`, about 155 observations apart.
> 2. *QTE ties where PQ does not* -- no. Across four seeds, **both** tie at seed
>    17 (`1.275328016249802` each) and **neither** ties at seeds 23, 29 or 41. The
>    v0.139.0 contrast was reading one fixture as an estimator difference.
>
> And it resolves as the sample grows, which is what a plateau collision must do:
>
> | n | coef @ 0.75 | coef @ 0.9 | tied |
> |---|---|---|---|
> | 1000 | `1.4491898789269633` | `1.4491898789269633` | **yes** |
> | 2000 | `1.275328016249802` | `1.275328016249802` | **yes** |
> | 4000 | `0.9570929867084059` | `1.3732758716025382` | no |
> | 8000 | `1.4356301994178935` | `1.7559108756022739` | no |
>
> More distinct outcomes means more steps, so two taus are less likely to share
> one. A solver defect would not behave this way. **Nothing is patched**: removing
> it would mean smoothing the indicator, which changes results in the healthy
> region to suppress correct behaviour.
>
> This is NOT the v0.137.0 defect, which froze the coefficient at **every** tau
> (`0 of 4` distinct steps) and is fixed.

> **`DoubleMLPQ` reported the IPW root while publishing the orthogonal score --
> fixed in v0.159.0.** A different defect from the two above, and the only one
> that made the estimator *silently self-inconsistent*.
>
> `solve_pq` bisected the **IPW** score and returned that root as the
> coefficient, then built `psi` from the `g` cross-fit. Those are two different
> functionals of the data, so the number reported did not satisfy the estimating
> equation the estimator itself publishes. Measured on a continuous-confounding
> DGP: the reported coefficient's own orthogonal score averaged **`-0.224968`**.
>
> Upstream (`doubleml` 0.11.3) is explicit that the IPW root is PRELIMINARY.
> `pq.py:378` solves it **only** to build `g`'s target (`pq.py:390` fits
> `ml_g(x_treat, y_treat <= ipw_est)`); `pq.py:423` then sets
> `_coef_start_val = mean(ipw_vec)`, and `double_ml_score_mixins.py:149` runs
> **Newton from there** against the orthogonal score `pq.py:268`. The reported
> coefficient is that root. `DoubleMLQTE` shares `solve_pq` and inherits it.
>
> Both halves matter, and the second half is the one that bites. The score
> contains `1{y <= theta}` -- the same step function the plateau collision
> above is built from -- so `mean(score)` is piecewise constant and **a
> bisection converges onto a jump, not a zero**; the midpoint of a jump is not
> a root. That is what upstream's Newton avoids. The `deriv` likewise must not
> be a central difference of a step: it is identically zero wherever no
> observation lies within `+/- h`, `fit` scales `psi` by `1/deriv` unguarded
> (`quantile.mbt:2427-2429`), and `0/0 = NaN` reaches `ses`. Measured
> `ses = [NaN, 0.3019, 0.1758, 0.1994, 1.6937]`. Upstream's `_compute_score_deriv`
> is a **Silverman-bandwidth weighted Gaussian KDE**, which is positive
> everywhere, so this is structurally unreachable rather than merely unlikely.
>
> | | before | after |
> |---|---|---|
> | reported root | IPW | orthogonal (Newton from IPW root) |
> | `mean(psi)` at reported theta | `-0.224968` | **`-0.0032`** |
> | `deriv` | central difference, can be `0` | Silverman KDE, strictly positive |
>
> On a DGP whose `Q_0.6(Y(1)) = 2.2` holds **by construction** (confounding
> enters `Y(0)` only), `theta = 2.230920809568266` with `se = 0.044753173108603286`,
> so the error `0.0309` is inside one SE. Newton moves theta only `0.0021` from
> the IPW root, which is the point: upstream treats that root as a **start
> value**, not the answer.

When you pass a classifier explicitly, name it on BOTH sides of any comparison: a
gate phrased against "the default" silently changes subject when the default
moves (hit four times across v0.134.0-v0.136.0).

> **`DoubleMLLPLR` can return a degenerate standard error -- and it is NOT an
> `ml_m` default problem.** Root-caused in v0.140.0. On the reference
> Liu-Zhang-Zhou 2021 design (`make_lplr_LZZ2020`, `dgp_lplr.mbt:37`) with a
> large true coefficient, both learners collapse to coef `~ -10` with SE `~ 1e-6`
> and a five-decimal confidence interval that EXCLUDES the truth:
>
> | true alpha | `ml_m = linear_regression` | `ml_m = logistic_regression` |
> |---|---|---|
> | 0.50 | `0.6636` / SE `0.1954` | `0.6293` / SE `0.1684` |
> | 0.75 | `1.3573` / SE `0.3861` | `1.2161` / SE `0.2993` |
> | 1.00 | **`-10.1863` / `1.39e-6`** | `2.9981` / SE `1.8142` |
> | 1.25 | **`-10.0567` / `1.62e-6`** | **`-10.4075` / `1.03e-6`** |
> | 2.00 | **`-9.0852` / `5.22e-6`** | **`-9.9926` / `1.93e-6`** |
>
> Across three seeds per cell, the regressor arm is degenerate at 3/3 for
> `alpha >= 1.0` and the classifier arm at 3/3 for `alpha >= 1.25`. The
> classifier **delays** the failure by roughly one step and then fails
> identically, so passing it explicitly is not a workaround.
>
> Cause, read from the source and confirmed by measurement:
>
> 1. `prelim_beta_per_fold` (`lplr.mbt:71-95`) returns `beta` built from
>    `w = ln(m / (1 - m))` -- the logit of the fitted propensity. As the effect
>    grows, `w` grows and `exp(r_hat)` in the score (`lplr.mbt:198-204`) reaches
>    `O(1e3)`. Measured at `alpha = 1.25`: `mean(psi) = 1097.07` and
>    `mean(psi_deriv) = -1097.07` -- the same order on BOTH arms, cancelling.
> 2. The Newton convergence flag WAS computed and **discarded** --
>    `let _ = converged`, now only documented at `lplr.mbt:885`; v0.145.0
>    replaced the bare flag with a `stop_reason` string (`lplr.mbt:887`).
>    With the step clamped to `0.25`
>    (`:853-854`), 50 iterations cannot span an arbitrary distance, so the loop
>    can stop away from the root, and `fit` computes a coefficient and a
>    variance there with no error raised.
> 3. `se = sqrt(gamma / (j*j*n))` with `j = mean(psi_deriv)`
>    (`var_est.mbt:52`). A huge `j` from step 1 makes the variance collapse.
>
> So the default keeps its regressor -- changing it would be the v0.136.0
> mistake again, trading a working default for a rationale that measurement
> does not support while leaving the cause untouched.
>
> **v0.141.0 / v0.142.0: in the degenerate region the objective is ROOTLESS.**
> Sweeping `mean(psi)` over `theta` in `[-30, 30]` and counting sign changes:
>
> | true alpha | sign changes | result |
> |---|---|---|
> | 0.50 | 1 | healthy -- a root exists |
> | 1.00 | 1 | degenerate anyway (the solve misses the root it has) |
> | 1.25 | **0** | degenerate -- **no root anywhere in range** |
>
> v0.141.0 said "the objective has no root" without qualifying the region; that
> was too strong and is corrected here. The accurate statement is that it is
> **rootless for `alpha >= 1.25`**, which is exactly the degenerate region. At
> `alpha = 1.0` a root does exist and the solver still fails to reach it -- so
> there are two distinct failure modes, not one.
>
> Every degenerate cell lands at `-8.3` to `-10.5` (mean `-9.85`) **while the true
> effect ranges 0.75 to 2.0** -- an output that does not move when the estimand
> moves by 2.7x.
>
> Three candidate fixes were measured and **all three were refuted**:
>
> 1. *Bound `t_pred`* -- degeneracy is uncorrelated with its range. A cell with
>    `t_pred` in `[-2.86, 4.16]` is degenerate; a cell reaching `+6.93` is
>    healthy.
> 2. *Rewrite the score in bounded form* -- `psi_hat * exp(r_hat) == expit(r_hat)`
>    looks like free numerical hygiene and **is not an identity here**: measured
>    `max_abs_diff = 0.546` and relative difference up to **0.92** on healthy
>    fixtures. Shipping it would silently change every LPLR result.
> 3. *Use a classifier for the `t` stage* -- **aborts** at `logistic.mbt:206`,
>    because that stage regresses on `w_inner = ln(m/(1-m))`, a continuous
>    unbounded logit propensity, not a 0/1 label.
>
> Where the objective is rootless (`alpha >= 1.25`), iteration budget, damping,
> start value and clipping are all inert; that case needs reparameterising the
> **objective** (a bounded link such as `expit`), which moves every LPLR result
> and is a model rewrite rather than a bug fix. Where a root exists but is missed
> (`alpha = 1.0`), solver quality genuinely is the issue.
>
> The diagnostic that settles which case you are in is cheap and general:
> **count sign changes of the objective over a wide parameter range before
> touching the solver.**
>
> **Port-vs-upstream (v0.142.0), recorded because fidelity alone would mislead:**
> the score formula is byte-identical to upstream (`lplr.mbt:194-204` vs
> `lplr.py:401-418`, including `exp(-coef*d)`), but two things differ.
> Upstream keeps `beta` **row-wise** (`lplr.py:315-346`) while this port folds it
> to one scalar (`lplr.mbt:866`). That is a real divergence -- but adopting
> upstream's per-row shape makes the root **worse** (1 -> 0 sign changes at
> `alpha = 1.0`), so it is not the cause and must not be changed on fidelity
> grounds. Upstream also handles solve failure in
> `double_ml_score_mixins.py:143-162` (brentq fallback on bounds; a warning or
> `ValueError` on non-convergence). This port omits that path entirely --
> `let _ = converged` (`lplr.mbt:885`) -- which was the one clear, low-risk
> divergence available to fix, and which v0.145.0 took.

**`DoubleMLAPOS` honoured a configured `ml_m` everywhere except where it
counted (fixed in v0.133.0).** Its `fit` path built each child
`DoubleMLAPO` without forwarding `ml_g` / `ml_m`, while `bootstrap` and both
sensitivity paths did. Passing `LogisticRegression` to `DoubleMLAPOS` returned
`coefs()[0] = -201.32` on a fixture whose true ATE was `1.2` -- bit-identical
to ignoring the argument, and 203 points from the same learner applied
directly. Nothing raised. The defaults listed above are unchanged; this was a
plumbing fix, and the two are deliberately separate so a failing test can be
attributed to one or the other.

**Propensity-score processor (`PSProcessor`)** -- `clipping_threshold`
clipping, isotonic (PAVA) calibration, K-fold cross-validated (CV)
calibration. Plugs directly into `DoubleMLIRM` / `DoubleMLIIVM` /
`DoubleMLDID` and the rest of the IPW-based models.

> **Two PSProcessor defects fixed in v0.159.0.** Both were silent.
>
> **Isotonic calibration collapsed on tied `x`.** `fit_isotonic` ran PAVA over
> the raw sorted sequence **without first pooling observations that share an
> `x`**. An isotonic regression is a *function of x*, so ties must receive one
> shared fitted value; instead `predict_isotonic` resolved each tie to the LAST
> index of the run, and the `[0.01, 0.99]` clip turned the stray `1.0` into
> `0.99`. The reported case -- predictions `[0.5, 0.5]`, labels `[0, 1]` --
> returned `[0.99, 0.99]` where sklearn 1.9.0's `IsotonicRegression` gives
> `[0.5, 0.5]` with `y_thresholds_ = [0.5]`. The fix adds `pool_tied_x` and
> passes the group **size** to `pava` as a weight, because the L2 objective is
> over observations and the group statistic is therefore a size-weighted mean.
> `pava` itself is unchanged. A tie-free control is unchanged, which is what
> shows the pooling is what moved the tied case.
>
> **`cv` was never forwarded, so `cv_calibration=true` calibrated on the wrong
> split.** `adjust_ps` *declares* a `cv` parameter and upstream passes
> `cv=smpls` at every call site (`pq.py:410`, `did_binary.py:537`,
> `iivm.py:371`, `cvar.py:343`), but in this port **no estimator ever passed
> it**. With `cv_calibration=true` the processor silently calibrated on its own
> `default_5fold(n)` -- five *contiguous* blocks -- instead of the estimator's
> `n_folds` partition. Now wired at `irm.mbt:430` and `iivm.mbt:525` via
> `folds_to_cv_partition`, which is sound because `kfold`'s `Fold` guarantees
> disjoint test indices covering `[0, n_obs)` (`kfold.mbt:199`).
>
> Note this is **narrower than "IRM/IIVM has no hookup"**, which was measured
> and found too strong: the isotonic config *did* already reach both fits. The
> five remaining `adjust_ps` call sites (`apo.mbt:320`, `did.mbt:628`,
> `did_cross_section.mbt:615`, `did_cs_binary.mbt:374`, `cvar.mbt:736` and
> `:1005`) still do not forward `cv`.

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
(`did_cs_binary.py:845-866`) and mixes the four `(G, T)` cells. Measured, **240
of the 720 rows read had `t == 1`** — a period the subset never contains, and
the one in which `y` carries the treatment effect. `sigma2` came out **583x**
too large (1.1473 vs 0.00197), and **no test in the package exercised the
function at all**. `irm_style_sensitivity`'s `require(n == psi_a.length())`
guard passed throughout, because both arrays were length 720 while describing
different observations. Fixed, and both entry points now share one builder
(`cs_bin_sensitivity_residuals`) so they cannot drift apart again.

**THE RECOVERY TOLERANCE, and the `t_pre` defect it uncovered** -- v0.152.0.
v0.150.0 made `dgp_recovery_test` non-vacuous but left its band untouched: an
absolute `max_abs_err < 5.0`, inherited from before the fix and never examined.
It was wrong in both directions at once.

Measured across 12 seeds on `make_did_cs_CS2021(800, 3, 1.0, seed)`:

    max |att - 1.0|            14.41   <- the band FAILS on seeds 7, 77, 314
    max |att - 1.0| / se        2.41   <- in SE units the error IS bounded
    se range          0.589 .. 8.837

So `5.0` was TOO LOOSE -- at the tested seed it permits 2.9x the error the
estimator actually makes -- and TOO TIGHT: it rejects a quarter of the seeds, and
it rejects them for being CORRECT. At seed 314 the estimate is 6.5136 +/- 6.8728,
i.e. z = 0.802, an entirely ordinary answer the absolute band calls a failure.
The error is large precisely when the SE is large, which is what a correctly
scaled robust SE is for. The band is now `|att - 1| < 5 * se`, 5 chosen against
a measured worst case of 2.41 -- the same 5 the sibling DIDMulti test already
used. The point estimate and SE are ALSO pinned exactly at 1e-12 relative,
because with a fixed seed that is the stronger statement and catches drift a
relative band would forgive.

**`DoubleMLDIDMulti` ignores `t_pre`.** The test that runs on `make_did_CS2021`
was named `DIDMulti_DGP_estimator_recovers_some_ATT` and constructs
`DoubleMLDIDCS`. So `DoubleMLDIDMulti` -- the class that owns
`gt_combinations` and is the documented consumer of that DGP -- has NO recovery
test anywhere in the package, and the name made the gap invisible. Renamed here
rather than left claiming coverage it never had.

Why there still isn't one is a blocker, not an oversight. The API takes
`(g, t_pre, t_eval)` triples and promises control of the base period;
`coef_at_idx` calls `ignore(t_pre)` and the inner derives its own base as
`g - 1`. The proof is one line -- `(1, 0, 2)` and `(1, 1, 2)` return the
IDENTICAL coefficient 0.6790989134518333. And that makes the DGP unusable for
validating DIDMulti: `make_did_CS2021` treats cohort `g` at `tau_g = g - 1`, so
the inferred base IS the first treated period. Measured against a true theta of
1.0: 1.4166 / 0.6791 / 0.3153 / -2.3785 / -1.2812 / -10.5035. A recovery test on
those numbers would enshrine the bug.

4 gates added (`expand_v152_test.mbt`). GATE 2 pins that the old band WOULD have
failed, asserting `z < 1.0` alongside `err > 5.0` so the seed that breaks it is
demonstrably a good estimate -- which is what stops the change being reverted on
the grounds that `5.0` "was always fine". GATE 4 pins `t_pre`'s inertness as a
DECLARED DEFECT WITH A TRIPWIRE: it will fail the moment `t_pre` is honoured, at
which point it is inverted rather than deleted.

Mutation 3/4, and both survivors/results are worth reading. M4 (the stored SE
inflated 10x) confirmed a weakness I predicted in advance: an SE-relative band
DIVIDES by the SE, so inflating it drops z tenfold and every recovery gate still
passes. The band is one-sided -- it can catch a coefficient too far from the
truth in units of its own SE, never an SE that is too large. What caught M4 was
GATE 3's exact pin, so the release is not relying on the band alone.

M3 (`di` dropping its time condition) survived, and the first instinct is to
call that blindness. It is not: measured against baseline the canonical cell is
BIT-IDENTICAL on all three seeds -- coef and se agree to the last digit. A
mutant that cannot move a number cannot be caught by an assertion about that
number. The limitation is the FIXTURE, not the gates: a 2-period panel with a
single post-treatment cell cannot distinguish that relabelling. Recorded rather
than papered over with a tighter threshold.

Also caught by running all four targets, again: the `t_pre` gate's literal was
pinned with `==` and passed native while failing wasm AND wasm-gc -- the same
~1.5e-15 cross-backend spread as v0.150.0. The inertness assertion `base0 ==
base1` KEEPS its `==`, because both values come from the same backend and a
difference there would mean the base period mattered. Only the literal moved to
1e-12 relative. Native green is not evidence. Four targets, always.

Tests: 1087 native / 1087 wasm / 1093 wasm-gc / 1087 js, all four green.
213 .mbt files (65 production + 123 blackbox test + 25 whitebox test).

Still open: honouring `t_pre` is a real API defect, not a test gap, and it blocks
DIDMulti recovery testing until fixed. The port's cell-grid divergence from
upstream is unchanged.

**THE `alpha_i` RAMP IN `make_did_CS2021` -- the one v0.148.0 missed** -- v0.151.0.
v0.148.0 removed `alpha_i = 0.5 * unit_in_cohort` from `make_did_cs_CS2021` and
never applied the fix to its 4-cohort sibling. Same defect, same reasoning,
different file.

Measured before, on `make_did_CS2021(1600, 3, 1.0, 3141)` where
`n_per_cohort = 1600/4/4 = 100`:

    var(y)                                  206.75   (SD 14.38)
    corr(id, y)                               0.975
    r^2 X_0 / X_1 / X_2 vs y     1.0e-5 / 2.6e-3 / 9.2e-3
    share of var(y) that is time-invariant     99.65 %
    var(within unit)                            1.11

`0.25 * var(0..99) = 208.3` against a total of 206.75: THE RAMP WAS THE
VARIANCE. It is not even cohort-specific noise -- `unit_in_cohort` repeats in
every cohort, so it is a positional ramp. Covariates carried under 1% of the
outcome, exactly the condition v0.148.0 called out as making the did_cs
sensitivity migration untestable. After the fix: `var(y)` 11.06,
`corr(id, y)` -0.108, `r^2` 0.423 / 0.647 / 0.560.

A per-unit N(0,1) DRAW rather than deletion: unobserved unit heterogeneity IS the
hidden confounding `nu2` exists to price, so removing the term outright would
leave the fixture unable to represent what it is for. The draw is taken AFTER
the noise stream, so X and `eps` are untouched -- and the evidence that this
worked is that `var(within unit)` is BIT-IDENTICAL across the change
(1.1087561532787724 -> 1.1087561532787722), so the `r^2` columns moved only
through alpha's own contribution.

**8 gates added (`expand_v151_test.mbt`), and three of them exist only because
mutants survived.** GATE 0 asserts the correlation helper returns 1.0 against a
variable and itself, since every correlation gate is worthless if the measuring
routine is broken. GATE 1 pins covariate `r^2 > 0.35`; GATE 2 pins
`|corr(id, y)| < 0.25`; GATE 3 states the ramp's absence on the quantity the ramp
keyed on, the unit-level mean of `y` not being monotone in `unit_in_cohort`;
GATE 4 pins the outcome scale and the PRESENCE of heterogeneity; GATE 5 proves
the fix touched `y` and nothing else, without which the `r^2` gain could equally
mean the treatment effect had been shrunk.

GATE 4's presence check was BLIND, and the mutation run said so. With six gates
written the first run scored 2/5 killed: M1 (`alpha_i = 0.0`, deleted),
M4 (`alpha * 0.15`) and M5 (`alpha[u / 100]`, one intercept per cohort) all
SURVIVED. The reason is structural and is the same masking that caused the
original bug: X is ITSELF unit-level and time-invariant in this DGP, so it
supplies the time-invariant share and the variance floor on its own. Any gate
reading `corr(id, y)` or a variance band cannot tell "the unit intercept is
present" from "the unit intercept is gone but X is doing its job".

GATE 6 projects X out of the unit-level outcome and looks at what is left. Since
`alpha` is drawn independently of X, that residual IS alpha (plus `eps` averaged
over four periods): measured 1.279 against the predicted
`var(alpha) + var(eps)/4 = 1.25`. That kills M1 and M4.

GATE 7 handles M5, whose TOTAL heterogeneity is unchanged and so is invisible to
GATE 6. Its first version SURVIVED M5 as well: it asserted
`within_cohort_var > 0.2` on the reasoning that a constant-per-cohort intercept
drives it to zero. It does not -- the residual floor is ~0.27 from `eps/4` and
projection error, and the mutant walked straight through. The scale-free
statement is the real one, and it is a RATIO: under a per-unit intercept the
within-cohort spread equals the overall spread, because units within a cohort
are exchangeable. Measured 1.009 / 1.279 = 0.789, against ~0.21 under M5.

Final 5/5 killed, 0 survivors, 0 inconclusive, baseline 8/8.

Blast radius: 3 sites, all value pins on this fixture -- `expand_v146_test.mbt`
GATE 5, the v0.147.0 additivity gate, and that file's four-accessor mean gate.
Every number re-measured, none guessed. Exactness was re-established per
quantity rather than assumed: `g_d1t1`'s mean is 0.7510479216157833 on all four
backends and keeps its `==`; the other three differ in the last one or two digits
and take 1e-12 relative.

Tests: 1083 native / 1083 wasm / 1089 wasm-gc / 1083 js, all four green.
212 .mbt files (65 production + 122 blackbox test + 25 whitebox test).

Still open, unchanged: DIDCS has a `(group, period)` cell grid upstream lacks, and
`make_did_CS2021` sets `tau_g = cohort - 1`, so it does not satisfy DIDCS's
g-is-treatment-period convention under either base period rule. An explicit
`tau_g` on the estimator would remove that inference.

**THE ESTIMAND FIX -- base period `g - 1`, so `ATT(g, g)` exists** -- v0.150.0.
This is the first release in this thread that CHANGES REPORTED NUMBERS; every one
from v0.146.0 to v0.149.0 was additive.

`DoubleMLDIDCS::fit` used a cohort's OWN treatment period as its pre-treatment
baseline and then required `eval_period > pre_period`, so it could only ever
reach `t > g`. The ATT in a cohort's FIRST TREATED PERIOD was never estimated on
any panel, ever. Callaway & Sant'Anna's convention is the opposite: a cohort
treated at `g` is untreated at `g - 1`, and post-treatment begins AT `g`.

On the canonical fixture `make_did_cs_CS2021(800, 3, 1.0, 3141)` the panel is
`groups = [1]`, `times = [0, 1]`, so `t > g` admitted NOTHING. `final_coef` is
zero-initialised (`did_cs.mbt:1581`), so `coef_at(0, 1)` returned the `0.0` it
was created with and `dgp_recovery_test`'s `max_abs_err < 5.0` passed on
`|0 - 1| = 1.0` -- asserting against a hardcoded zero while claiming to recover
an ATT of 1.0. Three parts of the package already disagreed with the estimator:
the fixture's own DGP treats cohort 1 from `k >= cohort`, `dgp_recovery_test`
documents `ATT(g, t)` for `t >= g`, and `did_cs_test.mbt`'s fixture sets `d` at
`k >= cohort` and then ASSERTED `coef_at(0, 1) == 0`. The estimator was the only
thing that believed `t <= g` is pre-treatment.

    coef_at(0,1)   0.0 (the sentinel)      ->  2.727522673844541
    se_at(0,1)     0.0                     ->  1.9428873717680928

On a fixture that DOES satisfy the convention (`g` is the treatment period,
effect from `k > g`), ATT is recovered to within 0.5%: `(g=1,t=2)` 0.9965,
`(g=1,t=3)` 0.9982, `(g=2,t=3)` 1.0042 against a true 1.0, and -0.0052 / 0.0094
where the true effect is 0. The canonical panel's 2.7275 +/- 1.9429 is noisy
because it is ONE cell from ONE cohort with no repeated periods to average over
-- 0.89 SE from the truth, a property of the fixture, not of the fix.

**Nine tests pinned the defect, all from one cause.** The package consistently
treated `t <= g` as "not estimable"; `expand_v100_didcs_test.mbt` even documented
it -- "An unestimated cell (`t_eval <= g`)". Rewritten or re-pinned from measured
runs. Two mattered more than a re-pin. First, `expand_v149_test.mbt` GATE 6
asserted that EVERY cell is the 0.0 sentinel, which shipped in v0.149.0 with the
defect still live: a gate certifying "nothing was estimated" is indistinguishable
from one certifying "nothing changed". Second, `se_pooled > se_single` was not a
theorem -- the cluster sandwich exceeds the IID one only under POSITIVE
within-block score correlation, and cell (0,2) inverted (0.0042918 <
0.0044041) once the rows changed. It had been asserting a property of the data.
The sign is now pinned per cell (five of six widen, (0,2) narrows), which is
STRONGER than the bare `!=` it could have been weakened to.

**A latent convention mismatch, found on the way.** `make_did_CS2021` (the
4-cohort DGP behind the v0.146.0/v0.147.0 gates) sets `tau_g = cohort - 1`, so
cohort 1 is treated from t = 0, while `DoubleMLDIDCS` interprets `g_value` as the
treatment PERIOD. That fixture satisfies DIDCS's convention under NEITHER base
period rule, and its cells were never `ATT(g, t)`: they read 0.089, -0.706,
-6.29 against a true effect of 1.0. Those gates are re-pinned and now say
explicitly that they are regression locks, NOT ATT recoveries. The same file
still carries `alpha_i = 0.5 * unit_in_cohort`, the unit-intercept ramp
v0.148.0 removed from `make_did_cs_CS2021` but never applied here.

**The new sharp edge.** A cohort whose `g - 1` is unobserved cannot have
`ATT(g, g)` estimated and is now SKIPPED rather than quietly given another base.
`v068_wbtest.mbt`'s fixture has periods 1, 2, 3 and no period 0, so cohort
`g = 1` drops out entirely. That is correct: the old rule used `t = 1` as the
base for `g = 1`, which is that cohort's first TREATED period.

5 gates added (`expand_v150_test.mbt`). GATE 1 is the one that was missing --
the `(g=1, t=1)` cell must carry an actual estimate, witnessed by a POPULATED
per-cell IF row rather than `coef != 0.0`, since a coefficient could be non-zero
by accident. GATE 2 asserts the boundary as a partition over every cell. GATE 3
is the payoff: it pins the estimator to the TRUTH on the convention-conforming
fixture, which no other gate here can do. GATE 5 pins the dropped-cohort
behaviour.

Mutation evidence 5/5 killed, and THE KILLS ALL LOOK THE SAME: every one is a
process abort (`0xc0000409`), not a failed assertion. The cause is the cursor
desync -- any mutant moving one mirrored site without the other leaves the
reassembly pass admitting a cell the fit loop never estimated, so it reads
`coef_values_acc[coef_idx]` out of an empty array. A loud abort is right for
that; the alternative is a silently wrong coefficient copied one position off.
DECLARED BLIND SPOT: no gate here is shown to catch a mutation producing a WRONG
BUT IN-BOUNDS number. A mutant altering the arithmetic while keeping both
predicates in step would survive, and I did not build one.

An exact `==` I wrote myself failed on three backends: pinning the new canonical
ATT with `==` passed native and failed wasm / wasm-gc / js, the signature of the
known ~1.5e-15 did_cs spread. Native green is not evidence. Four targets,
always.

Tests: 1075 native / 1075 wasm / 1081 wasm-gc / 1075 js, all four green.
211 .mbt files (65 production + 121 blackbox test + 25 whitebox test).

Still open, and untouched here: the port's `DoubleMLDIDCS` has a `(group,
period)` cell grid that upstream's does not -- its `_check_data` rejects a `g`
column outright -- and upstream's class is deprecated in favour of
`DoubleMLDIDCSBinary`. Separately and now visible from this release: DIDCS
infers treatment timing from `g_value`, which `make_did_CS2021` does not
honour, so an explicit `tau_g` would remove that inference.

**did_cs sensitivity, stage 2 of 4** -- v0.149.0 adds upstream's PANEL-LEVEL
`sigma2` and `nu2` as five accessors on `DoubleMLDIDCS`:
`sensitivity_sigma2()`, `sensitivity_nu2()`, `sensitivity_psi_sigma2()`,
`sensitivity_psi_nu2()`, `sensitivity_riesz_rep()`. Purely additive -- no reported
number moves, and `sensitivity_analysis` is untouched, still running
`irm_style_sensitivity` over the DML score element. The two paths disagree by
construction, and both are now exposed.

**The formulas are pinned against a RUNNING upstream, not a reading of it.** Both
were transcribed from `did_cs.py:451-497`, then checked against upstream 0.11.3,
which is installed here. On a 2x2 panel built from its own CS2021 DGP it reports
`sigma2 = 256.4070590464714`, `nu2 = 18.253043736106648`, and
`_verify/_oracle_v1482_nu2_gap.py` reproduces BOTH TO THE LAST DIGIT. A first
cross-check reported 17.325 against 18.253 and read as a 5.1% input difference.
It was neither: my oracle omitted `.ravel()`, so a 2-D `(816,1)` `m_hat`
**silently broadcast** against `(816,)` into a `(816,816)` intermediate. A 5.1%
error is exactly the size that hides a shape bug behind a tolerance.

**These are PANEL-LEVEL, not per cell.** Upstream's `_sensitivity_element_est`
reads `self._dml_data` in its entirety, and its manual oracle
`fit_did_cs(y, x, d, t, ...)` takes no `g` and has no cell loop, so both are
single scalars for the whole panel. That corrects the v0.147.0 changelog, which
implied stage 2 would produce per-cell values.

Measured on `make_did_cs_CS2021(800, 3, 1.0, 3141)`: `sigma2 = 1.8855040509678376`;
`nu2 = 21.32163562345964` with `in_sample_normalization=false` (the port's default,
upstream's is `true`); and `NaN` with `true`. The `NaN` is the informative one --
that branch divides by `mean(d1t0)`, which is `0.0` because nobody is treated in
the pre-period, i.e. the `(d=1, t=0)` cell is structurally empty, the same fact
`expand_v147_test.mbt` GATE 5 pins. Upstream's arithmetic on the same input
produces the same Inf/NaN. **No fallback is substituted**, because a quiet
replacement number is indistinguishable from a correct one.

5 gates added (`expand_v149_test.mbt`). The scalars are pinned at 1e-12 relative
(the did_cs quantities carry the known ~1.5e-15 cross-backend spread) and are
asserted positive and finite, since `sqrt(sigma2 * nu2)` depends on it. GATE 3
proves the `in_sample_normalization` flag selects a genuinely different branch:
`sigma2` must agree exactly, `nu2` must not. GATE 4 asserts the per-row elements
are **centred**, per upstream's convention `psi_nu2 = element - nu2`
(`did_cs.py:529`), so `sensitivity_nu2()` is deliberately NOT the mean of
`sensitivity_psi_nu2()`.

Mutation evidence 5/5, and M4 is the one that matters: storing the RAW element
under the name `psi_nu2` is the exact defect that shipped in this stage's first
draft. A raw-vs-deviation swap preserves the array's length and shape, so only a
gate asserting the **mean** can see it -- which is why GATE 4 is written that way.
I DECLARED GATE 6 a control that would survive all five and the measurement
REFUTED it: GATE 6 ends in a liveness check (`sensitivity_sigma2() > 0.0`) and is
not purely an estimate-stability check, so it fires under M5. The declaration is
corrected in the harness.

**Still open.** The port's `DoubleMLDIDCS` has a `(group, period)` cell grid that
upstream's does not, and upstream's class is **deprecated** in favour of
`DoubleMLDIDCSBinary`. This release adds the panel-level elements *alongside* the
grid rather than resolving that, so it is correct whichever way it goes. The
estimand fix (base period `g - 1`, so `ATT(g, g)` exists) is unaffected and
remains open, as does `dgp_recovery_test`'s vacuous `max_abs_err < 5.0` against
a true effect of 1.0.

**DIDCS fixture: the unit intercept was drowning the covariates** -- v0.148.0
replaces `alpha_i = 0.5 * unit_in_cohort` (a deterministic ramp to 99.5, SD
~ 28.8) with a per-unit standard-normal draw. Measured on
`make_did_cs_CS2021(800, 3, 1.0, 3141)`: `var(y)` 828.42 -> 10.76; `r^2` of each
X column against y 7e-4 -> 0.451 / 0.572 / 0.670; `corr(id, y)` ~1.0 -> -0.063;
and `mse(g_hat)/mse(cell mean)` 1.052 -> 0.185 / 0.163 / 0.190. The last row is
the one that matters: before the fix NO conditional nuisance could beat a
constant, so `g_hat` was indistinguishable from a cell mean, `sigma2 =
mean((y - g_hat)^2)` collapsed onto `var(y)`, and the did_cs sensitivity
migration had nothing to condition on and no gate able to separate a correct
`g_hat` from a wrong one. After it, the nuisance explains ~82% of within-cell
variance. A draw rather than deletion, because unobserved unit heterogeneity IS
the hidden confounding `nu2` prices; SD 1 matches the true effect `theta = 1.0`
and makes it ~19% of the covariate signal.

**One of v0.147.0's own gates broke correctly and was rewritten.** GATE 5 there
asserted `v1470_mean(a) > 1.0` to mean "populated", which was an absolute scale
smuggled in from the DGP it was written against (`y` mean 49.87). After the fix
`mean(y)` is 0.085 with sd 3.28, so it went red on a perfectly well populated
nuisance. It now asserts the scale-free property it meant: not identically
zero.

5 gates added (`expand_v148_test.mbt`). GATE 1 reads the nuisance predictions and
demands the conditional fit BEAT A CONSTANT on every populated cell (ratio <
0.25) -- the property stage 2 depends on, and the only gate there that reads
code rather than the fixture. GATE 2 pins the ramp's absence and first asserts
`corr(id, id) > 0.999999` so a broken correlation routine cannot pass silently.
GATE 3 pins covariate `r^2 > 0.35`. GATE 4 pins the outcome scale. GATE 5 proves
the fix touched `y` and nothing else (occupancy still 400/200/0/200), without
which the v0.147.0 conclusions could not have carried over.

Mutation evidence 4/4 killed. GATE 5 and every v0.147.0 stage-1b gate survived
all four, as declared -- they read occupancy. I DECLARED THAT GATE 3 survives
M2/M4 and the measurement REFUTED it: tripling the unobserved term raises total
variance without raising the covariate's share, so `r^2` falls under the floor.
The declaration is corrected in the harness, because a declared control that
turns out not to be one is worse than none.

**Estimand blocker, still open.** The canonical 2-period panel yields ZERO
estimable cells (`groups = [1]`, `times = [0, 1]`, both candidates fail
`eval_period <= g_value` because the base period is the cohort's own treatment
period), so `dgp_recovery_test`'s `max_abs_err < 5.0` against a true effect of
1.0 is still vacuous. The estimand fix (base period `g - 1`) is next.

**did_cs sensitivity, stage 1b of 4** -- v0.147.0 adds the four upstream
`(d, t)` outcome nuisances `g_dXtY = E[Y | D=d, T=t, X]` on the long panel, as
FOUR NAMED accessors `predictions_g_d0_t0()` / `_d0_t1()` / `_d1_t0()` /
`_d1_t1()` on `DoubleMLDIDCS`, plus `cross_fit_predict_conditional_dispatch` in
`learner.mbt` mirroring upstream's `fit_predict(..., train_cond=...)`
(`doubleml/tests/_utils.py:33-45`). Upstream's `sigma2` needs `g_hat` assembled from
all four (`did_cs.py:445-449`, `456-461`); the port had two, split by `d` alone
and taken from each cell's child `DoubleMLDIDBinary` restricted to its own
subset -- a different object that cannot be reassembled on the full panel.

**Four names, not a 4-tuple, and measurement is why.** The obvious design is one
`predictions_g_d()` returning `(d0t0, d0t1, d1t0, d1t1)`. Two probes ruled it
out. First, the obvious discriminator does not exist: cell-wise RMSE has no
minimal diagonal -- `g_d0t1` beats `g_d0t0` on cell `(d0,t0)` -- because RMSE
~14 is dominated by noise while the four conditional means differ by under 2.
Second, nothing else sees a permutation either: all four arrays have length `n`,
are all finite and all vary, so a swapped return literal passes every
length/finiteness/variation gate while quietly building the wrong `g_hat`. With
four names the permutation is not expressible.

**The cells are `t` in {0,1}, settled from upstream's source.** Extending them
to later periods would be a NEW modelling decision, not a port.
`did/tests/_utils_did_cs_manual.py` selects `intersect1d(where(d == 0), where(t
== 0))` and three siblings; `dgp_did_CS2021.py:309` sets `"t":
time_matrix.flatten()`, so upstream's `t` IS the period; and `doubleml/tests/_utils.py:33-45`
intersects the condition with the training index and then predicts on the whole
test fold, so the condition gates FITTING, not prediction. Upstream's
`DoubleMLDIDCS` is therefore the 2x2 repeated-cross-section design (its
multi-period sibling is `DoubleMLIDMulti`). On the canonical 2-period panel this
is an exact transcription; on a longer panel -- which this port permits and
upstream does not -- rows with `t >= 2` train none of the four, reproducing
upstream.

**Purely additive -- no reported number moves**, asserted by GATE 4. A draft of
GATE 1 that asserted array LENGTH was discarded before shipping: the helper
pre-sizes its output to `n`, so restricting *prediction* to the cell still
returns four arrays of length `n`. GATE 1 now asserts COVERAGE (measured: zero
exact `0.0` entries anywhere on the 4-period panel, versus 1300/1400/1500/1400
under that mutation). GATE 7 pins one measured mean per named accessor and
restores exactness where available: `g_d0t1`, `g_d1t0`, `g_d1t1` are
bit-identical on all four backends and asserted with `==`; only `g_d0t0` differs
(js ends `...4715` vs `...472`, ~2e-16) and alone carries a 1e-12 tolerance.
Mutation evidence 6/6 killed, with GATE 3 declared NON-DISCRIMINATING: it reads
`data.d`/`data.t`, i.e. the fixture, so it cannot fail under any code mutation.

**Stage 1b blocker, recorded so it is not rediscovered.** The four nuisances now
exist; what remains is that upstream's `nu2` needs `m_alpha`/`rr` across four
upstream branches, one of which is unreachable because `DoubleMLDIDCS::new` has
no `score` parameter while the sub-DID hardcodes `score="observational"`.
Upstream's did_cs numbers are therefore an architectural change to the
estimator, not a formula swap; until stage 2 lands, `nu2` is still
`mean(psi_a^2)` on the DML score element and NOT upstream's
`mean(2*m_alpha - rr^2)`.

**did_cs sensitivity, stage 1 of 4** -- v0.146.0 adds
`DoubleMLDIDCS::predictions_m()`, the cross-fitted group propensity
`m_hat = E[D | X]` on the LONG panel, plus `sensitivity_folds()` exposing the
panel-wide folds behind it. Upstream's did_cs decomposition needs exactly this
(`did_cs.py:470`, `propensity_weight_d0 = m_hat / (1 - m_hat)`), and the port
could not produce it for two independent reasons: each `(g, t)` cell delegates
to a child `DoubleMLDIDBinary` restricted to that cell's two cohorts and two
periods, so its propensity is a different object; and `DoubleMLDIDCS` exposed
no prediction accessor at all. Strata mirror upstream's `d + 2*t`.

**Purely additive -- no reported number moves**, and that is asserted rather
than asserted-to: GATE 5 of `expand_v146_test.mbt` pins three `coef`/`se` pairs
against values recorded before this change existed. Its first draft pinned them
bit-for-bit and failed on three of four backends -- chasing that showed the
did_cs estimates differ by about 1.5e-15 relative across backends, which is
pre-existing and unrelated to this additive change. The gate now uses a 1e-12
relative tolerance drawn from that measurement, while GATE 5b pins the NEW
nuisance exactly, since it has no inherited spread: `mean(m_hat) =
0.5627032315060088` on all four backends.

**Stage 1b blocker, recorded so it is not rediscovered.** Upstream's `sigma2`
needs `g_hat` from **four** `(d, t)` outcome nuisances (`did_cs.py:445-449`);
the port has **two**, split by `d` only, taken from each cell's child, and they
cannot be recovered -- only refit on the full panel. Separately,
`DoubleMLDIDCS::new` has no `score` parameter while the sub-DID hardcodes
`score="observational"`, so upstream's two `experimental` branches are
unreachable. Upstream's did_cs numbers are therefore an architectural change to
the estimator, not a formula swap; until stage 1b lands, `nu2` is still
`mean(psi_a^2)` on the DML score element and NOT upstream's
`mean(2*m_alpha - rr^2)`.

`DoubleMLLPLR`, `DoubleMLRDD` and friends have **no upstream sensitivity
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
`irm` still uses the old convention and needs its own `m_alpha`/`rr`
plumbing. `plr` could not be migrated that way at all, and is resolved
separately in **v0.144.0**: its `nu2` is not a mean of a per-observation
element but the **scalar** `1 / mean((d - m_hat)^2)` (`plr.py:290-293`). The
port passed `psi_a = -v^2` into the shared helper, which squares its third
argument, so it reported `mean(v^4)` -- the **fourth** moment, a different
functional form rather than a differently-scaled version of the intended
quantity. Measured on a seeded confounded design (n = 500, seed 20261):
`mean(v^4) = 0.076516` against `1/mean(v^2) = 4.609163`, a factor of **60.24**
that moves with the data. `sigma2` was `mean((y - l_hat)^2)` rather than
upstream's `theta * v`-centred `mean((y - l_hat - theta*v)^2)` (`0.775939` vs
`0.336927`), so the "residual variance" still contained the coefficient's own
contribution. `rv` was therefore not the Cinelli-Hazlett robustness value.
Fixed IID and cluster, with six gates that recompute both formulas
independently. Upstream's per-observation `psi_nu2` has mean exactly zero by
construction, so transcribing it literally would route PLR through the
`nu2 <= 0` fallback and reach the right number by the branch reserved for a
degenerate case; the scalar is transcribed instead, and the new shared
`sensitivity_from_variance_baselines` is what licenses passing baselines
directly. `pliv` was added to the unsupported list in the same release --
upstream never sets `_sensitivity_implemented = True` for it either. Separately, upstream defaults
`in_sample_normalization` to `True` (`did_cs_binary.py:121`) and this port to
`false` (`did_cs_binary.mbt:732`) -- **uniformly across all six DID
estimators**, upstream being `True` in all five of its own. This is a
deliberate backward-compatibility choice, not a transcription slip: v0.8.0
picked `false` so the default stayed "byte-equal to the pre-0.8.0 port". Both
branches are implemented and were verified faithful in v0.131.0, so the formulas
agree; only the *default* differs. Measured on two independent staggered DGPs,
flipping it moves `coef` by 0.03%, `se` by 3-4% and sensitivity `nu2` by
0.6-1.2%, and leaves `sigma2` bit-identical (`sigma2` is unweighted upstream,
`did_cs_binary.py:867`). To match upstream exactly, pass
`in_sample_normalization=true` explicitly.
The config is also folded into the memoize key, not just its threshold,
so two estimators sharing a `clipping_threshold` but differing in
calibration are kept apart.

**Solver diagnostics** -- v0.145.0 gives `DoubleMLLPLR` a
`warnings()` accessor, the first diagnostic channel in the package. Until now
it had none by design (no `println`, no stderr: a numerical library that writes
to the console makes its own test output unreadable), and that same silence is
why `fit` could end its damped-Newton loop with `let _ = converged` and then
report a coefficient and standard error computed at a **non-solution** without
saying so. Warnings are **returned, never printed** -- the caller decides:

```moonbit
let model = DoubleMLLPLR::new(data, alpha=1.5).fit()
for w in model.warnings() { println(w) }
```

The failure is easy to miss because it does not look like one. `se` is
`sqrt(gamma / (j^2 * n))` with `j = mean(psi_deriv)`, so leaving the root makes
the reported standard error *smaller*. On the package's own
`make_lplr_LZZ2020` (n = 800, seed 17):

| alpha | warns | `se` | `coef` |
|---|---|---|---|
| 0.25 / 0.50 / 0.75 | no | `0.285` / `0.465` / `1.507` | `0.703` / `1.204` / `2.351` |
| **1.00** | **yes** | `1.7e-06` | `-10.367` |
| 1.25 / 1.50 / 2.00 | yes | `2.6e-06` / `3.8e-06` / `2.1e-05` | `-10.001` / `-9.702` / `-8.370` |

The boundary lands at **alpha = 1.00**, reproducing the cliff v0.140.0 located
indirectly from the SE and CI -- the same edge, found from a different
observable. The reason is `exhausted_step_budget` and the reported `theta` is
about `-10.7`: the damped step is clamped to `0.25`, so 50 steps walk the
iterate ~12 units out and simply run out of budget. Three distinct exits are
named, since they are different faults: `degenerate_derivative`, `diverged`,
`exhausted_step_budget`. This is unrelated to the v0.144.0 sensitivity work --
one is about the sensitivity API surface, the other about an estimate.

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
dispatch, and **15 of the 22** `DoubleML*` estimators expose the
estimator-level triple `sandwich_se(kind)` /
`cluster_sandwich_se(cluster_ids)` / `bias_corrected_coef()`:
`DoubleMLIRM`, `DoubleMLPLR`, `DoubleMLIIVM`, `DoubleMLPLIV`,
`DoubleMLDID`, `DoubleMLDIDBinary`, `DoubleMLDIDCrossSection`,
`DoubleMLDIDCSBinary`, `DoubleMLCVAR`, `DoubleMLSSM`,
`DoubleMLAPO`, `DoubleMLPLPR`, `DoubleMLPQ`, `DoubleMLLPQ`,
`DoubleMLLPLR`. (Re-measured: the quantile trio was missing from this
list while the Status table already counted all 15, so the two
disagreed inside one file.) (`DoubleMLRDD` and `DoubleMLBLP`
already emit HC0 intervals by calling
`LinearRegression::sandwich_se` internally.)

> **`DoubleMLBLP::confint_joint` ignored `level` -- fixed in v0.159.0.** It
> hardcoded `let z = 1.959963984540054` (`blp_policy.mbt:746`) while `level` was
> accepted, range-checked at line 727, and then never used -- so `level=0.50`
> and `level=0.95` returned byte-identical intervals, which removes the entire
> point of the argument. Now level-aware, following the convention already used
> in this package (`did_cross_section.mbt:485`): the exact constant at
> `level == 0.95`, so the default stays bit-exact, and `norm_ppf` otherwise.
> The multiplier is `sqrt(chi2(1, level)) = z_{(1+level)/2}`, the same value
> `statsmodels.OLS.conf_int(joint=True)` applies. Because the interval is
> symmetric, the width is exactly `2 * z * se`, so **width ratios are
> data-independent** and can be pinned without hard-coding a fitted number:
>
> | level | width (n=400, contrast on (intercept, x)) |
> |---|---|
> | 0.50 | `0.03691929183204845` |
> | 0.95 | `0.10728184750635172` |
> | 0.99 | `0.1409923584966286` |
>
> `width(0.95)/width(0.50)` measured `2.9058479234757097` against
> `1.959963984540054 / norm_ppf(0.75)` = `2.905847923475711`, agreeing to
> `1.3e-15`. Note the numerator is the **hardcoded** 95% constant, not
> `norm_ppf(0.975)`: this package's `norm_ppf` returns `1.9599627869916687`
> there (accurate to ~6e-7 relative), which is exactly why the special case
> exists. Note the convention:
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

**Reproducible DGPs + Python reference validation** -- 24 Python
scripts (`validate_*_with_python.py`) drive the DGPs
(`plr_CCDDHNR`, `plr_turrell`, `plr_confounded`, `irm_discrete`,
`irm_heterogeneous`, `irm_confounded`, `iivm`, `pliv` /
`pliv_cluster`, `SSM`, `simple_rdd`, `DID SZ2020` / `CS2021`, etc.)
and check within-tolerance equivalence against the upstream Python
outputs. CI runs each script and requires **both** a zero exit code and a
trailing `PASS` line -- the second condition alone used to be the only one
checked, and it is trivially satisfied by a script that never ran MoonBit.

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

22 estimators (`DoubleML*` structs) in 19 production files -- 16 with
one struct each, and three holding two (`apo.mbt`: `DoubleMLAPO` +
`DoubleMLAPOS`; `blp_policy.mbt`: `DoubleMLBLP` +
`DoubleMLPolicyTree`; `quantile.mbt`: `DoubleMLPQ` + `DoubleMLQTE`) --
out of 220 `.mbt` files in the package (65 production, 129 blackbox
test, 26 whitebox test). All are reachable through the same
`DoubleMLXxx::new(...).fit()` interface. 20 are marked *(upstream)*
against a name-identical `doubleml-for-py` class, `DoubleMLRDD` is
marked *(upstream, renamed)* because upstream calls it `RDFlex`, and
`DoubleMLDIDCrossSection` is marked *(no upstream counterpart)*:

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
| `DoubleMLDIDCrossSection` | observational | Sant'Anna-Zhao 2020 cross-section DID *(no upstream counterpart)* -- port-only |
| `DoubleMLSSM` | MAR | sample selection (missing-at-random) *(upstream)* |
| `DoubleMLAPO` | policy score | average prescriptive effect *(upstream)* |
| `DoubleMLAPOS` | policy score | APO with stratified treatment *(upstream)* |
| `DoubleMLPQ` | quantile | potential quantile *(upstream)* |
| `DoubleMLQTE` | quantile | quantile treatment effect *(upstream)* |
| `DoubleMLLPQ` | local polynomial | local potential quantile *(upstream)* |
| `DoubleMLLPLR` | partialling-out | partially logistic regression, Liu-Zhang-Zhou 2021 *(upstream)* |
| `DoubleMLCVAR` | CVaR | conditional value-at-risk *(upstream)* |
| `DoubleMLRDD` | observational | regression discontinuity *(upstream, renamed)* -- upstream `RDFlex` |
| `DoubleMLBLP` | IV | best linear predictor of treatment effect *(upstream)* |
| `DoubleMLPLPR` | partialling-out | partially linear panel regression, Clarke-Polselli 2025 *(upstream)* |
| `DoubleMLPolicyTree` | policy | policy tree *(upstream)*, + v0.98.0 honest split (`honest = true`) with `leaf_se` / `policy_value_se` |

**Provenance (v0.103.0, re-measured).** The counterpart modules in
`doubleml` 0.11.4 are `plm/{plr,pliv,lplr,plpr}.py`,
`irm/{irm,iivm,apo,apos,pq,qte,lpq,cvar,ssm}.py`,
`did/{did,did_binary,did_cs,did_cs_binary,did_multi}.py`, `rdd/rdd.py`
(the class there is `RDFlex`), and `utils/{blp,policytree}.py` --
verified against the published sdist, not the GitHub tree, so this is
the shipped artefact. **Not** all 22 have a counterpart: see the
measurement below.

Provenance was re-measured against the **0.11.4 sdist** itself
(`_verify/doubleml-0.11.4.tar.gz`, 388 members) rather than read off a
table. Result: **20** rows have a name-identical `class DoubleMLXxx`
upstream; `DoubleMLRDD` corresponds to upstream's `RDFlex`; and
`DoubleMLDIDCrossSection` has **no upstream estimator**.

For that last one the scan is specific, because "not upstream" and
"nothing upstream" are different claims. Over the sdist's 322 `.py`
members: `class DoubleMLDIDCrossSection` 0 hits, the bare identifier 0,
`did_cross_section` as a module name 0, any `class *CrossSection` 0. But
`cross_sectional_data` appears 25 times and `Sant'Anna` 13 -- upstream
ships `make_did_SZ2020` in `doubleml/did/datasets/dgp_did_SZ2020.py`,
"Generates data from a difference-in-differences model used in Sant'Anna
and Zhao (2020)". So the **design is known upstream and the DGP ships
there**; it is the *estimator* that is not ported. Labelled
`*(no upstream counterpart)*`, which refers to the estimator class.

Three rows were previously marked *(extra)* -- `DoubleMLDIDCSBinary`,
`DoubleMLLPLR`, `DoubleMLPLPR`. That was wrong: all three ship
upstream, so they had a reference implementation all along and
simply were not being compared against it. `DoubleMLDIDCSBinary`,
`DoubleMLDIDBinary` and `DoubleMLDIDMulti` are additionally absent from
upstream's `__all__` while still being importable from their modules.

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

**Current state: the rule is not met, by one line.** `moonbit_doubleML/moon.mod`
declares two packages, and **neither is imported by any `.mbt` in the library**
(measured: 0 references each):

| declared | imported by the library? | note |
|---|---|---|
| `moonbitlang/async@0.20.3` | no | used only by `examples/api_server/main.mbt`, which declares it in its own `moon.mod` |
| `moonbit-community/sqlite3@0.2.3` | no | **not `moonbitlang/*`** -- added in v0.85.0 for `DoubleMLPolicyTree` memoisation, which now uses an in-memory `FitCache` |

So the library has no runtime third-party dependency today, while `moon.mod`
carries two dead entries -- one of which does not satisfy the rule above.
Deleting both lines is the change that would make this section true.

##Determinism & validation

### What CI actually gates

Measured from `.github/workflows/` and confirmed against the run list. Eight
gates, all of which run on push to `master` and again before publishing:

| Gate | Where | Scope |
|---|---|---|
| Shipped README == edited README | `check.yml` `readme-sync` | `moonbit_doubleML/README.mbt.md` byte-identity |
| `moon build` + `moon test --deny-warn` | `check.yml` x4 matrix | `native`, `wasm-gc`, `wasm`, `js` |
| `moon fmt --check` | `check.yml` "Format check" x4, `publish.yml` | see caveat below |
| `moon check --deny-warn` x4 | `publish.yml` | warnings are errors |
| Generated-interface drift | `publish.yml` | public surface |
| `typos` (pinned 1.19.0) | `publish.yml` | prose |
| 24 `validate_*_with_python.py` | `check.yml` | estimator parity; see the two-tier note below |
| 21-activity QA LOOP (fast scope) | `check.yml` `qa-loop`, `publish.yml` | 22 registered checks, 12 of them fast |

`nightly.yml` additionally runs the package against the MoonBit **nightly**
toolchain, so a breaking upstream change surfaces before it reaches stable.

**Two of these are weaker than the table makes them look, and both are stated
here rather than left for a reader to assume.**

- **`moon fmt --check` has not been shown to be able to fail.** On the local
  toolchain (`moon 0.1.20261012`) it exits 0 on a package containing a
  deliberately mis-formatted file, silently. CI installs the *latest* `moon`
  from `cli.moonbitlang.com` rather than a pinned version, and its run log is
  not readable without authentication, so its behaviour there is unverified.
  The step reports success; treat "format is clean" as unproven until a
  mis-formatted file is shown to turn it red.
- **`validate_splitting_contract.py` never runs.** It is tracked, but does not
  match CI's `validate_*_with_python.py` glob, so no workflow executes it.

**All 24 now spawn a MoonBit process, but they are not all the same kind of
check, and saying "24 / 24 PASS" without saying that would overstate what
passed.**

- **All 24 spawn MoonBit and compare its output**, over **248 comparison rows**
  across the ten that were rewritten. `validate_quantile_with_python.py` used to
  print `reference checks PASS` having never run MoonBit; `validate_rdd_with_python.py`
  used to `assert abs(2.0 - 2) < 1e-12`, which is `assert abs(0.0)` and cannot
  fail. Both now run the port. (`padjust` is 108 of the 248 -- it runs two
  p-value vectors through five methods since v0.163.0, up from one vector.)
- **The references are not equally strong, so neither is the claim:**
  - `padjust` runs `statsmodels.stats.multitest.multipletests` -- the *actual*
    upstream library the port delegates to. `rdd` reimplements the
    local-linear WLS from `rdd.mbt`'s definition and agrees to **4.8e-15**.
    `gain_statistics` is checked against two independent references on a fixture
    built so all six branches are taken.
  - The rest compare against a population target or an independent estimate on
    the port's own data. That catches a regression; it is not bit-equivalence.
- **None of them compare against the real `doubleml` wheel**; most restate the
  upstream formula in Python. The wheel is what `doubleml-for-py` is, and
  matching it is stricter than what is actually being done.
- **One parity gap closed, one still open.** `tsbh` now matches statsmodels
  **bit for bit**: `tsbh_p_adjust` runs statsmodels' own lambda search
  (`n0 = m - r1` from the stage-1 rejections, `alpha_star = alpha*m/n0`, then
  rescale by `n0/m`) instead of a global Storey-2002 rescale. Measured
  `max |moonbit - statsmodels| = 0` on both fixture vectors, so the validator
  gates it at exact equality rather than at a tolerance. `tsby` still uses the
  old estimator and still diverges from `fdr_tsbky` -- but **not** by a constant
  factor: measured `max |port - statsmodels| = 0.1595`, ratio spanning
  0.5129 ... 1.1970. It has no validator rows, so nothing in CI would catch a
  drift in it.

**Each rewritten validator has been observed failing.**
`_verify/_parity_mutation_1650.py` perturbs the emitter once per validator and
requires a non-zero exit: **11 of 11 killed**, tree restore verified by sha256.
One mutation survived and was *documented rather than fixed* -- changing the
`padjust` p-vector's first entry -- because the validator feeds that vector to
statsmodels itself, so it is the check's input, not its expected value.

**Bit-exact parity is a second, stronger tier.** A tolerance cannot tell "the
port is arithmetically identical to the reference" apart from "the port lands
within 1e-4 of it". `validate_bitexact_with_python.py` compares IEEE-754 bit
patterns instead, against `examples/bitexact/`. Measured scope, not assumed:

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

**Acceptance-criteria traceability** lives in
`features/moonbit_doubleML_acceptance.feature`: 6 `Feature`, 24 `Scenario`, 80
Given/When/Then steps, each scenario annotated `# mapped to: <test name>`. 23
of the 27 named tests resolve to real `test` declarations; the other four are
descriptive prose. The MoonBit tests are the executable form -- there is no
separate Gherkin runner.

**Coverage is two-tier, and the tiers are not the same size.** The QA LOOP
(`.github/scripts/qa_loop/`, v0.162.0) registers 22 checks over the 21 named
activities: **12 in `fast` scope**, which CI runs on every push and again before
publishing, and **10 in `full` scope**, which is release-time.

- fast: `format`, `static_code_check`, `duplicate_code`, `dependencies`,
  `gherkin`, `qa_process`, `contract`, `security_sast`, `perf_test`,
  `benchmark`, `coverage`, `quality_metrics`
- full: `static_analysis`, `unit_tests`, `component_tests`, `integration`,
  `api_test`, `security_dast`, `fuzz`, `mutation`, `load_stress`, `e2e`

CI deliberately runs **fast only**: the full scope re-runs `moon test` several
more times and all 24 Python cross-checks, which `moon-test` (x4 backends) and
`python-cross-check` already do. Re-measuring them would multiply release time
for no new information.

**Still not covered, so not claimed.** The `coverage` check is a
test-reachability proxy, not instrumented line coverage. There is no
dependency-vulnerability scan -- `moon update` resolves versions, it is not an
audit. `mutation` kills three mutants on one kernel, not a whole-codebase
surviving-mutant ledger. `examples/fuzz/` has no crash-regression corpus. And
the two declared `moon.mod` dependencies -- `moonbit-community/sqlite3@0.2.3`
and `moonbitlang/async@0.20.3` -- are dead: nothing imports them, and
`dependencies` already WARNs about exactly that (`2 declared; non-conforming:
['moonbit-community/sqlite3@0.2.3']; declared but unreferenced by library code:
[both]`) rather than passing quietly. Removing them is an open call, not an
oversight.

### Reproducing CI locally

`.github/scripts/ci_local.py` runs these jobs on this machine. It executes the
`run:` steps **straight out of the workflow YAML** rather than from a
hand-maintained copy -- a copy drifts the first time someone edits a workflow,
and a simulator that lies about what CI does is worse than no simulator.

```
python .github/scripts/ci_local.py list        # which jobs exist, and their steps
python .github/scripts/ci_local.py provision   # build the WSL guest toolchain
python .github/scripts/ci_local.py run --jobs "qa-loop"
python .github/scripts/ci_local.py run --all --release-tag v0.163.0
python .github/scripts/ci_local.py selftest    # prove the simulator can fail
```

`--release-tag` sets `$GITHUB_REF_NAME`. It is not cosmetic: `publish.yml`'s
`Resolve release version` reads that variable to decide what it is about to
publish, and with it unset the tag comes out empty and the job dies on
`Release tag must use the v* format, got:`.

It runs against `git archive <ref>`, so it sees a pristine tracked checkout --
no untracked scratch, no dirty tree -- and every step goes through `bash -e`,
which is the shell string GitHub logs. The checkout is a real git repository,
because a step is allowed to rely on that (`publish.yml` gates on
`git diff --exit-code`). Four verdicts, kept distinct on purpose:

| Verdict | Means |
|---|---|
| `PASS` | the step ran and succeeded |
| `FAIL` | the step ran and failed -- a real defect |
| `SKIP` | a `uses:` step; deliberately not simulated, never a silent PASS |
| `BLOCKED` | **this machine** lacks a tool the step needs; nothing was proven |

`BLOCKED` exists because "the runner has `python` and this box does not" is not
a red build. It is cross-checked with `command -v` in the guest, so a command
the guest *does* have and that fails anyway still reports `FAIL`.

`selftest` is the guard on the guard: every discriminating rule has a paired
control arm, so a gate that cannot fail cannot pass here either. **20
self-tests.** Eight simulator bugs it has caught, every one of which read as a
project failure:

- Windows `text=True` put a `\r` on every line of the script, so
  `>> $GITHUB_PATH` wrote to a file named `<path>\r\r`. The write *succeeded*
  (rc 0, empty stderr), and the next step could never find the tool it
  installed.
- `to_wsl` was not idempotent, turning a guest path `/mnt/c/...` into
  `/mnt/d/mnt/c/...` when a PATH entry was read back.
- `${{ matrix.target }}` was never expanded, so all four backends ran the
  literal text and bash reported "bad substitution" -- four FAILs that looked
  like the package was built for the wrong backend.
- `git archive` produced files but not a repository, so
  `git diff --exit-code` exited 129 with a usage dump naming `--output` -- read
  as `moon info` having the wrong flags.
- The index was written by Windows git (`autocrlf=true`, normalizing
  `CHANGELOG.md` to LF) and read by Linux git, so a **pristine** checkout
  reported a diff.
- `$GITHUB_REF_NAME` was never set, so `Resolve release version` failed on an
  empty tag.
- `--engine none` was advertised by `--help` and rejected by `plan()`.
- `publish.yml` runs `moon publish` and `gh release` from plain `run:` steps, so
  nothing structural stopped a local `run --all` from shipping a release. Such
  steps are now refused, never executed.

Not simulated: `uses:` steps beyond provisioning, secrets, `GITHUB_TOKEN`,
release publishing, `steps.*.outputs`, and the exact OS image (WSL Ubuntu is
close to `ubuntu-latest`, but not equal to it).

- All randomness flows through `chacha8_rng(seed)` (`seed.mbt`).
  Default `seed=3141`; same seed => byte-identical DGP outputs.
- Python reference scripts `validate_*_with_python.py` reproduce
  the upstream `doubleml-for-py` numbers. CI runs each one and requires both a
  zero exit code and a trailing `PASS` line on stdout.
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
package (BSD 3-Clause License). Upstream's 20 name-matched estimator
classes are re-implemented in pure MoonBit with the same score
formulae and variance estimators, as is its RDD implementation
(`RDFlex` upstream, `DoubleMLRDD` here). `DoubleMLPLPR`,
`DoubleMLLPLR` and `DoubleMLDIDCSBinary` are **not** MoonBit-only -- all
three ship upstream, and are compared against it. The one genuinely
port-only estimator is `DoubleMLDIDCrossSection`, which has no
upstream counterpart in 0.11.4.

#### Differences from upstream `doubleml-for-py`

- Native MoonBit package layout, type system, and test organization.
- Independent implementations of `Matrix`, linear / logistic
  regression, stratified K-fold, ChaCha8 PRNG, and Kahan summation
  in MoonBit; **no NumPy / scikit-learn dependency**.
- `DoubleMLData` / `DoubleMLXxx::new().fit()` as the canonical
  MoonBit-idiomatic API, with optional JSON in/out for native /
  wasm-gc / wasm / js backends (Serverless / Wasm / edge
  deployments).
- Behaviour-level parity check via the 24 Python reference scripts:
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