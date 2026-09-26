# TUNE_DESIGN.md — `DoubleML.tune()` Architecture (v0.55+)

> **Status**: design proposal, no implementation yet.
> **Author**: v0.54.0 planning cycle.
> **Depends on**: v0.54.0 `Learner` injection (Item 2 of the v0.54.0 cycle — landed).

This document sketches the architecture for a `DoubleML.tune()` method
that runs a user-supplied grid-search over nuisance-learner hyperparameters
and selects the best combination by score-on-holdout. It is **not** a
specification — sections marked `[OPEN]` are explicit decision points.

## 1. Motivation

`doubleml-for-py` exposes a `tune()` method on every DoubleML model. The
use case is concrete: a researcher has several candidate
`learner_l` / `learner_m` configurations (random-forest with 50 / 100 /
500 trees, gradient boosting with depth 3 / 5 / 7, ...), wants the
pipeline to try each, score each combination by some held-out criterion,
and pick the best one before running the final DML fit. Without `tune()`
the researcher has to do this by hand — writing a loop that fits each
candidate, computes a score, then re-fits the best — which is tedious
and easy to get wrong (the DML orthogonality property depends on using
the *same* fold partitions across all candidates, so manual tuning
must replicate the cross-fit fold schedule exactly).

The MoonBit port at v0.53.0 has no `tune()` method. The user picked
`tune()` as Item 5 of the v0.54.0 cycle but the work is too large for a
single release; this document captures the design so v0.55+ can
implement it without re-deriving the trade-offs.

## 2. Design constraints (from v0.54.0 work)

1. **`Learner` injection is already there** (v0.54.0 Item 2). The
   `LearnerDispatch` enum + `cross_fit_predict_dispatch` helper give
   us a non-generic `DoubleMLPLR` struct that can hold any combination
   of `LinearRegression` / `ConstantLearner` / `NoopLearner` per
   nuisance. New learner types (logistic regression, gradient
   boosting, random forest) are 3 small edits each:
   `(a)` declare `impl Learner for X`,
   `(b)` add `X(x)` arm to `LearnerDispatch`,
   `(c)` add the matching arm to `cross_fit_predict_dispatch`.

2. **`cross_fit_predict[T : Learner]` is already generic** in `kfold.mbt`.
   It accepts any `T : Learner` and produces an OOF prediction vector.
   `tune()` does NOT need a new cross-fit primitive.

3. **Pure-MoonBit library**: only `moonbitlang/core/{math, random,
   debug}` deps in the library package (see `moon.pkg`). Gradient
   boosting / random forest must therefore be **implemented in
   MoonBit**, not pulled from external crates. This is a v0.55+
   scope decision — see §6 below.

4. **All 4 backends** must pass `moon test --target <X>` after every
   change. No backend-specific shortcuts.

5. **`moon check --deny-warn`** is the CI gate — every diagnostic
   warning becomes an error.

## 3. Public API sketch

```moonbit
/// Top-level entry point: `DoubleMLPLR::tune(...)` returns the
/// learner combination that minimises the per-criterion score,
/// then re-fits the model with that combination.
pub fn DoubleMLPLR::tune(
  self : DoubleMLPLR,
  param_set : Array[Dict],          // grid (one Dict per candidate combo)
  tune_settings : Array[Dict],      // scoring config (see §4)
  scoring_method? : String = "MSE", // "MSE" | "neg-MSE" | "RMSE" | ...
  n_folds_tune? : Int = 5,         // separate fold schedule for scoring
) -> DoubleMLPLR
```

### 3.1 `param_set` shape

Each entry of `param_set` is a `Dict[String, LearnerDispatch]`
keyed by `"learner_l"` / `"learner_m"`. For example, an RF-vs-LR grid:

```moonbit
let grid : Array[Dict] = [
  { "learner_l": LearnerDispatch::linear_regression(),
    "learner_m": LearnerDispatch::linear_regression() },
  { "learner_l": LearnerDispatch::rf(50),  // [OPEN] see §6.1
    "learner_m": LearnerDispatch::linear_regression() },
  { "learner_l": LearnerDispatch::linear_regression(),
    "learner_m": LearnerDispatch::rf(50) },
  { "learner_l": LearnerDispatch::rf(50),
    "learner_m": LearnerDispatch::rf(50) },
]
```

This 2 × 2 grid is the smallest useful case. Practical research
workflows typically have 5–20 candidates.

### 3.2 `tune_settings` shape

Each entry of `tune_settings` is a `Dict[String, String|Int|Double]`
describing how to score that combination. The minimum-viable key set:

| key             | type   | meaning                                          |
|-----------------|--------|--------------------------------------------------|
| `"learner_l"`   | str    | name of the learner_l slot to vary               |
| `"learner_m"`   | str    | name of the learner_m slot to vary               |
| `"scoring"`     | str    | one of `"MSE"`, `"RMSE"`, `"neg-MSE"`, `"R2"`    |
| `"n_folds"`     | int    | (optional) override the global n_folds_tune      |
| `"seed"`        | int    | (optional) override the global seed              |

`[OPEN]` more keys (e.g. `"cv_strategy"`, `"stratify"`) are deferred.

## 4. Scoring algorithm

For each candidate `c` in `param_set`:

1. Draw a fresh fold schedule `folds_tune` via
   `kfold(n_obs, n_folds_tune, seed)`. **Crucial**: the tune-time
   fold schedule must be independent of the final-fit fold schedule
   to avoid information leakage (the final DML estimate uses its own
   `self.n_folds` for cross-fitting).

2. Cross-fit the nuisances under `c`:
   - `l_hat_c = cross_fit_predict_dispatch(c["learner_l"], x, y, folds_tune)`
   - `m_hat_c = cross_fit_predict_dispatch(c["learner_m"], x, d, folds_tune)`

3. Compute the candidate score `score_c`:
   - For `scoring_method = "MSE"`: `score_c = mean((y - l_hat_c)^2)`.
     Lower is better.
   - For `"RMSE"`: `score_c = sqrt(MSE)`. Lower is better.
   - For `"neg-MSE"`: `score_c = -MSE`. Higher is better.
   - `[OPEN]` for `"R2"`: 1 - SS_res / SS_tot.

4. Pick `c* = argmin_c score_c` (or `argmax_c` for `"neg-MSE"`).

5. Re-fit the DML model with `learner_l = c*["learner_l"]`,
   `learner_m = c*["learner_m"]` using the **final-fit fold schedule**
   (`self.n_folds`). This is a separate `DoubleMLPLR::fit()` call
   with the tuned learners as the per-fit overrides.

6. Return the re-fitted `DoubleMLPLR`.

### 4.1 Why MSE-on-l_hat (not the DML score)

The upstream `doubleml` library scores candidates by MSE on the
outcome nuisance (the `l_hat` prediction), not by the DML score
itself. This is deliberate: the DML score depends on `theta`, the
quantity we're trying to estimate; using it for model selection
would be a form of double-dipping. MSE-on-l_hat is the standard
"predict-the-outcome" loss for outcome-nuisance selection. For
treatment-nuisance selection the analogous metric is
MSE-on-m_hat against `d`.

`[OPEN]` should we expose a `"scoring_target": "outcome"|"treatment"|"both"`
key in `tune_settings`? Default `"outcome"` matches upstream.

## 5. Caching & fold reuse

A naive implementation re-runs `cross_fit_predict_dispatch` for every
candidate, even though the `folds_tune` partition is the same across
candidates. This is wasteful for large grids:

- 5 candidates × n=1000 obs × 5 folds × 100 ms/cross-fit = 25 s
- 20 candidates: 100 s

The fix is a **fold-aware cache**: key the cached `l_hat` /
`m_hat` vectors by `SHA256(folds_tune || c["learner_l"] || c["learner_m"])`.
This is a one-line change to `cross_fit_predict_dispatch` (it already
takes the folds explicitly, so adding a memoization layer in front is
non-invasive).

`[OPEN]` do we want a public `Learner::cache_id()` method that
returns the cache key, or do we just hash the struct fields
(SHA256 is type-agnostic)?

## 6. The big `[OPEN]`: learner implementations

The current `LearnerDispatch` enum covers `LinearRegression` /
`ConstantLearner` / `NoopLearner`. Real hyperparameter grids need
**random forest** and **gradient boosting**. Two paths:

### 6.1 Path A: in-package implementations

Write `RFLearner(n_trees, max_depth, ...)` and `GBLearner(n_trees,
learning_rate, max_depth, ...)` as new MoonBit types, add
`impl Learner for X`, add `X(x)` arms to `LearnerDispatch`. Estimated
effort: 2–3 weeks per learner family (Cart tree builder, bagging loop,
gradient-boosting loop with shrinkage). Total: 4–6 weeks.

### 6.2 Path B: external ML package

Add a thin MoonBit binding to an existing ML library. Constraints:
- The library must work on all 4 backends (no C-FFI-only).
- The library must be `pure-MoonBit`-eligible per §2.3 (only
  `moonbitlang/core/*` deps allowed in the library package).
- The library must support a `fit(x, y)` + `predict(x)` API that
  matches the existing `Learner` trait.

This requires a search for an existing MoonBit ML library
(monthly moonbitlang/core survey), or building a minimal pure-MoonBit
RF/GB library ourselves. Either way: 2–4 weeks minimum.

### 6.3 Recommendation

Path A is preferable because it keeps the package's "pure-MoonBit,
all-4-backends, no-FFI" purity property intact. RF and GB are small
enough to implement (~200–400 lines each) and we already have a
`LinearRegression` learner as a worked example. The
`cross_fit_predict_dispatch` extension is mechanical (3 edits per
new type).

`[OPEN]` decision: do we ship `tune()` with just `LinearRegression`
+ `ConstantLearner` + `NoopLearner` in v0.55 (Path A only, ~1 week),
or do we block v0.55 on RF/GB implementations first (Path A + B
combined, 4–6 weeks)?

## 7. Edge cases & abort conditions

| condition                                  | behaviour                          |
|--------------------------------------------|------------------------------------|
| `param_set.length() == 0`                  | abort: "tune() with empty grid"    |
| `param_set.length() == 1`                  | skip tune, return re-fit           |
| `n_folds_tune > n_obs`                     | abort: `require(false)` cascade    |
| `learner_l_c.predict()` raises             | catch, set score_c = +Inf, continue (don't abort the whole tune run) |
| `seed` not set                             | default to a fixed seed (3141) for reproducibility |
| `scoring_method` not in known set          | abort: "unknown scoring_method"    |

The "score_c = +Inf on a learner failure" rule lets the grid continue
even when one candidate diverges (e.g. random forest with
n_trees=0); the bad candidate is automatically excluded by the
argmin.

## 8. Open questions summary

1. §3 / `param_set` element type: `Dict[String, LearnerDispatch]`
   vs a more typed wrapper (`ParamSetEntry` struct).
2. §3.2 / extra `tune_settings` keys (`"cv_strategy"`,
   `"stratify"`).
3. §4.1 / `scoring_target` key.
4. §5 / cache-key API (`Learner::cache_id()` vs SHA256 of fields).
5. §6 / Path A-only vs Path A + B for v0.55.
6. §7 / divergent-learner recovery: keep +Inf scoring or abort.

Each `[OPEN]` is a code-review discussion point, not a blocker for
the design doc itself.

## 9. Out of scope (explicit)

- **Multi-treatment PLR** (`DoubleMLPLR` currently supports a single
  treatment column only). The `tune()` API as sketched is for the
  single-treatment case; multi-treatment tuning would need a
  per-treatment learner grid.
- **Bayesian optimisation / hyperopt**. Upstream `doubleml` supports
  `tune()` with both grid-search and `optuna`-driven search; this
  design is grid-search only. A future `tune_bayes()` method is a
  v0.56+ follow-up.
- **Cross-validated hyperparameter selection inside a single
  learner** (e.g. picking `max_depth` of an RF via inner CV). This
  is an "auto-ML" feature that upstream Python doesn't expose
  either — the user passes a pre-tuned learner.