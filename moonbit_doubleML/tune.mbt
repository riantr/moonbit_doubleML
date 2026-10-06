///|
/// `TuneParam` — one row of the candidate grid passed to
/// `DoubleML*::tune`. Holds a concrete nuisance-learner
/// combination (one first-slot learner, one second-slot learner)
/// to be scored against the others in the grid.
///
/// The grid is `Array[TuneParam]` (typed, not `Dict`). Reasons
/// for the typed wrapper vs a `Dict[String, LearnerDispatch]`:
///
///   - compile-time key/value type safety (Dict keys are
///     runtime-checked strings)
///   - no Dict-construction FFI overhead per candidate
///   - cleaner documentation (`TuneParam::{learner_l, learner_m}`
///     is a documented struct, not a magic-key dict)
///
/// Python upstream `doubleml.DoubleMLPLR.tune` uses a similar
/// shape internally (a list of `{"learner_l": ..., "learner_m": ...}`
/// type) but exposes it via kwargs to `set_tune_params`.
///
/// # Slot semantics - read this before filling a grid
///
/// The fields are named for the **partially linear outcome** family.
/// Several estimator families reuse the same two slots with a
/// different meaning, and the field names do **not** change with the
/// family:
///
/// | family | first slot (`learner_l`) actually holds | second slot (`learner_m`) |
/// |---|---|---|
/// | `PLR` `PLIV` `LPLR` `PLPR` | outcome learner `E[y\|x]` | nuisance `E[m\|x]` |
/// | `APO` `APOS` `IRM` `IIVM` `CVAR` `PQ` `QTE` `SSM` `DID*` | treatment / propensity learner `E[g\|d,x]` | outcome learner `E[m0+d·m1\|x]` |
/// | `RDD` | discontinuity-side learner `E[y\|x]` | unused (RDD has a single slot) |
///
/// v0.108.0: the pre-existing doc comments in `apo.mbt` / `irm.mbt` /
/// `iivm.mbt` described their pair as `(learner_g, learner_m)`, which
/// reads as a promise that the field is named `learner_g`. It is not
/// - the field is `learner_l` and always has been. Those comments now
/// name the slot's *role* instead. Use `TuneParam::for_outcome` /
/// `TuneParam::for_treatment` so the call site carries the role.
pub struct TuneParam {
  learner_l : LearnerDispatch
  learner_m : LearnerDispatch
} derive(Debug)

///|
pub extend TuneParam with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Build a `TuneParam` from an explicit `(learner_l, learner_m)`
/// pair. Equivalent to the struct literal `{ learner_l, learner_m }`
/// — exposed as a factory so callers don't need to know the field
/// order of an internal struct.
pub fn TuneParam::new(
  learner_l : LearnerDispatch,
  learner_m : LearnerDispatch,
) -> TuneParam {
  { learner_l, learner_m, }
}

///|
/// Intent-labelled alias of `TuneParam::new` for the **partially
/// linear** families, where the first slot really is the outcome
/// learner `E[y|x]` and the second is the nuisance `E[m|x]`.
///
/// Identical to `TuneParam::new` - it exists so the call site states
/// the intent instead of relying on the field name. Prefer it on
/// `PLR` / `PLIV` / `LPLR` / `PLPR`.
pub fn TuneParam::for_outcome(
  learner_l : LearnerDispatch,
  learner_m : LearnerDispatch,
) -> TuneParam {
  { learner_l, learner_m, }
}

///|
/// Intent-labelled alias of `TuneParam::new` for the families whose
/// **first slot is the treatment / propensity learner** `E[g|d,x]`
/// and whose second slot is the outcome learner.
///
/// Identical to `TuneParam::new`. Prefer it on `APO` / `APOS` /
/// `IRM` / `IIVM` / `CVAR` / `PQ` / `QTE` / `SSM` and the `DID*`
/// family, so a reader is not left inferring the slot meaning from a
/// field called `learner_l`.
pub fn TuneParam::for_treatment(
  learner_g : LearnerDispatch,
  learner_m : LearnerDispatch,
) -> TuneParam {
  { learner_l: learner_g, learner_m, }
}

///|
/// Scoring method for `DoubleMLPLR::tune`. All three are based
/// on the OOF outcome-nuisance prediction `l_hat = cross_fit(y | x)`
/// (TUNE_DESIGN.md §4.1: MSE-on-l_hat, the upstream Python default):
///
///   - `MSE`:    mean((y - l_hat)^2). Lower is better.
///   - `RMSE`:   sqrt(MSE). Lower is better.
///   - `NegMSE`: -MSE. Higher is better (sklearn convention).
///
/// R^2 scoring is deferred to a follow-up release — R^2 needs a
/// defended against degenerate `Var(y) = 0` and isn't needed by
/// the standard PLR tune workflow.
pub enum TuneScoring {
  /// Mean squared error; lower is better.
  MSE
  /// Root mean squared error; lower is better.
  RMSE
  /// Negative MSE; higher is better (sklearn convention).
  NegMSE
} derive(Debug)

///|
pub extend TuneScoring with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Parse a scoring-method string into a `TuneScoring` enum.
/// Accepted spellings (case-insensitive):
///
///   - `"MSE"`   / `"mse"`   -> `MSE`
///   - `"RMSE"`  / `"rmse"`  -> `RMSE`
///   - `"neg-MSE"` / `"neg-mse"` / `"NegMSE"` -> `NegMSE`
///
/// Unknown spellings abort with a descriptive message. Use
/// this when accepting scoring-method names from CLI / JSON
/// configs; pass the enum directly for typed code.
pub fn TuneScoring::parse(s : String) -> TuneScoring {
  match s {
    "MSE" | "mse" => MSE
    "RMSE" | "rmse" => RMSE
    "neg-MSE" | "neg-mse" | "NegMSE" | "neg_MSE" => NegMSE
    _ => abort("unknown TuneScoring: " + s)
  }
}

///|
/// Result of a `DoubleMLPLR::tune` call. Holds the best (by the
/// chosen scoring rule, lower-is-better or higher-is-better per
/// `TuneScoring`) candidate plus the full per-candidate score
/// vector for diagnostics.
///
/// `all_scores[i]` is the raw score for `param_set[i]` (in the
/// grid order, NOT necessarily sorted). Lower-is-better / higher-
/// is-better is the same convention as the chosen `TuneScoring`.
/// For diagnostics where the user wants to compare across scoring
/// rules, they should re-run `tune` with the other rule.
pub struct TuneResult {
  /// The candidate with the best score under the chosen rule.
  best : TuneParam
  /// The best score (raw, in the scoring-rule's own scale).
  best_score : Double
  /// Per-candidate raw scores, in `param_set` order.
  all_scores : Array[Double]
} derive(Debug)

///|
pub extend TuneResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Compute the per-candidate score on a held-out criterion
/// (TUNE_DESIGN.md §4.1: MSE-on-l_hat for outcome-nuisance
/// selection).
///
/// `y` is the outcome vector, `l_hat` is the OOF cross-fit
/// prediction `cross_fit_predict_dispatch(learner_l, x, y, folds)`
/// — i.e. each `l_hat[i]` was produced by a fold that excluded
/// row `i`. Lower MSE means the learner generalizes better
/// out-of-fold.
///
/// Returns a raw, un-sorted score in the chosen metric's natural
/// scale (`MSE` -> mean((y-l_hat)^2), `RMSE` -> sqrt(MSE),
/// `NegMSE` -> -MSE). The caller is responsible for the
/// argmin/argmax selection.
fn tune_score_outcome(
  y : Array[Double],
  l_hat : Array[Double],
  scoring : TuneScoring,
) -> Double {
  let n = y.length()
  // length pre-check: caller (the `tune` loop) only invokes this
  // when `l_hat_c.length() == n`. Adding a `require(...)` here
  // would propagate an error type up the call stack and force
  // every wrapper to be error-typed too — keep it a plain `let`.
  if l_hat.length() != n {
    return TUNE_SCORE_FAIL_SENTINEL
  }
  // raw MSE (un-sorted, lower-is-better)
  let mut sse = 0.0
  for i = 0; i < n; i = i + 1 {
    let r = y[i] - l_hat[i]
    sse = sse + r * r
  }
  let mse = sse / Double::from_int(n)
  match scoring {
    MSE => mse
    RMSE => mse.sqrt()
    NegMSE => -mse
  }
}

///|
/// Per-candidate raw scores plus the index of the winner.
pub(all) struct TuneGridScore {
  /// Raw score per candidate, in the caller's `learners` order.
  scores : Array[Double]
  /// Index of the winning candidate under the caller's scoring rule.
  best_index : Int
}

///|
/// Selection rule: lower score wins, except under `NegMSE` where the
/// sign is already flipped to higher-is-better and the comparison
/// inverts. Private to this file; `tune_score_grid` is the only caller.
fn tune_argmin(scores : Array[Double], scoring : TuneScoring) -> Int {
  let mut bi = 0
  let mut bv = scores[0]
  if scoring is NegMSE {
    for i = 1; i < scores.length(); i = i + 1 {
      if scores[i] > bv {
        bv = scores[i]
        bi = i
      }
    }
  } else {
    for i = 1; i < scores.length(); i = i + 1 {
      if scores[i] < bv {
        bv = scores[i]
        bi = i
      }
    }
  }
  bi
}

///|
/// The estimator-independent half of `tune`: cross-fit every candidate
/// learner against the outcome, score it, and select the winner.
///
/// Extracted in v0.108.0. The five pre-existing `::tune`
/// implementations (`PLR` / `PLIV` / `IRM` / `IIVM` / `APO`) each
/// carried their own byte-identical copy of the scoring loop and of the
/// argmin/argmax selection - roughly 40 duplicated lines apiece,
/// including the `NegMSE` higher-is-better branch that has to be
/// rewritten at every site. That duplication is what let the argmin
/// survive being inverted with the whole suite green (see
/// `expand_v108_test.mbt`).
///
/// `n_folds_tune` folds are drawn fresh from `seed`, deliberately
/// independent of the final fit's own fold schedule, so candidate
/// quality is not selected on the same splits the estimate is later
/// computed from.
///
/// The observation count comes from `y.length()`, NOT from an
/// estimator accessor: six of the estimators this serves (`APOS`
/// `DIDCS` `DIDCrossSection` `DIDMulti` `LPLR` `PLPR`) expose no
/// `n_obs()` at all, and every one of them has `data.y` available
/// instead. A core keyed on `self.n_obs()` would have pushed a new
/// accessor onto six public types purely to serve a helper.
///
/// A candidate whose cross-fit returns a wrong-length vector scores
/// `TUNE_SCORE_FAIL_SENTINEL`, which the selection rule then excludes.
///
/// v0.108.0: the previous version of this comment gave
/// "an RFLearner with 0 trees" as the example, and that was wrong.
/// `RFLearner::fit` raises `PreconditionError` on `n_trees=0` and its
/// own `catch` escalates it to `abort` (`rfl.mbt:404`), so the
/// process dies before any caller sees a vector - let alone a
/// wrong-length one. No learner in the current `LearnerDispatch` set
/// can reach the sentinel: they all return `x.rows()`-length vectors.
/// The guard stays as defence for a future learner that returns a
/// short vector WITHOUT aborting, but it is not a live path today and
/// is not described as one.
///
/// A learner that PANICS cannot be recovered here at all: `abort` is
/// not interceptible, so a panicking candidate aborts the whole
/// process rather than being excluded from the grid.
pub fn tune_score_grid(
  x : Matrix,
  y : Array[Double],
  learners : Array[LearnerDispatch],
  n_folds_tune : Int,
  seed : Int,
  scoring : TuneScoring,
) -> TuneGridScore {
  let n = y.length()
  let folds_tune = kfold(n, n_folds_tune, seed)
  let scores : Array[Double] = Array::make(learners.length(), 0.0)
  for i = 0; i < learners.length(); i = i + 1 {
    let pred = cross_fit_predict_dispatch(learners[i], x, y, folds_tune)
    scores[i] = if pred.length() == n {
      tune_score_outcome(y, pred, scoring)
    } else {
      TUNE_SCORE_FAIL_SENTINEL
    }
  }
  TuneGridScore::{ scores, best_index: tune_argmin(scores, scoring), }
}

///|
/// `DoubleMLPLR::tune` — score a grid of nuisance-learner
/// combinations and re-fit the model with the winner.
///
/// Algorithm (TUNE_DESIGN.md §4):
///
///   1. Draw a fresh fold schedule `folds_tune` via
///      `kfold(n, n_folds_tune, seed)`. The tune-time folds
///      are deliberately independent of the final-fit
///      `self.n_folds` to avoid information leakage — the
///      final DML estimate uses its own fold schedule for
///      cross-fitting, so sharing tune and fit folds would
///      leak `l_hat` quality into the model-selection step.
///   2. For each candidate `c` in `param_set`:
///      - `l_hat_c = cross_fit_predict_dispatch(c.learner_l,
///        x, y, folds_tune)`
///      - `score_c = tune_score_outcome(y, l_hat_c, scoring)`
///      - on a learner-level exception, set `score_c = +Inf`
///        (TUNE_DESIGN.md §7: keep tuning, the argmin rule
///        automatically excludes divergent candidates).
///   3. `c* = argmin_c score_c` (lower-is-better for MSE / RMSE,
///      higher-is-better for NegMSE — `NegMSE` is converted
///      to its lower-is-better form internally).
///   4. Re-fit the DML model with `learner_l = c*.learner_l,
///      learner_m = c*.learner_m` using the **final-fit** fold
///      schedule (`self.n_folds`). The tuned nuisance
///      predictions from step 1 are NOT reused — each re-fit
///      produces its own OOF cross-fit under `self.n_folds`.
///   5. Return the re-fitted `DoubleMLPLR`.
///
/// Edge cases (TUNE_DESIGN.md §7):
///   - `param_set.length() == 0` -> abort with a descriptive
///     message.
///   - `param_set.length() == 1` -> skip the scoring loop,
///     re-fit with the single candidate directly (faster).
///   - `n_folds_tune > n_obs` -> abort via the existing
///     `kfold` precondition cascade.
///   - `seed` not set -> defaults to 3141 for reproducibility.
///   - `scoring_method` not in known set -> abort via
///     `TuneScoring::parse`.
///
/// `score` (the DML score: "partialling-out" / "iv-type") is
/// forwarded to the re-fit step unchanged — tune() does not
/// affect the DML score itself, only the nuisance learners.
///
/// Cluster-data (`self.data.is_cluster_data()`) is not
/// supported in v0.58.0 — cluster-aware tuning needs a
/// different fold schedule (`kfold` on unique units) and
/// would inflate this method beyond a single release. Use
/// `DoubleMLPLR::fit(learner_l = best_l, learner_m = best_m)`
/// directly on the cluster-DML path with hand-picked
/// candidates until v0.59.0+ lands cluster-aware tune.
pub fn DoubleMLPLR::tune(
  self : DoubleMLPLR,
  param_set~ : Array[TuneParam],
  scoring_method? : String = "MSE",
  n_folds_tune? : Int = 5,
  seed? : Int = 3141,
  score? : String = "partialling-out",
) -> DoubleMLPLR {
  try {
    require(param_set.length() > 0)
    // `n_folds_tune >= 2` stays at the call site rather than in the
    // shared core, and that is deliberate. It is the check that
    // carries the most weight - `kfold(n, 1, seed)` yields one fold,
    // so the "cross-fit" degenerates to in-sample prediction and every
    // candidate gets scored on its own training fit, silently
    // rewarding the most overfitting candidate instead of the most
    // generalising one. A check that important should be visible at
    // every call site, not inferred from a helper. It is also the
    // reason the core is not an error-typed function: a polymorphic
    // `raise` here would widen the try body's error set and break the
    // `catch { PreconditionError::Violated(loc) => ... }` exhaustiveness
    // that every `::tune` relies on.
    require(n_folds_tune >= 2)
    // v0.58.0: cluster-data not yet supported (see file header).
    require(!self.data.is_cluster_data())
    let scoring = TuneScoring::parse(scoring_method)
    // v0.108.0: the scoring loop, the fold draw and the argmin/argmax
    // selection moved into `tune_score_grid`. The single-candidate
    // fast path went with them: it never actually skipped the scoring
    // (it computed one score and hand-built a `TuneResult` by hand),
    // so it was a second copy of the result-construction logic that
    // could drift from the multi-candidate path rather than a
    // shortcut. With one candidate the grid scores it and selects
    // index 0, which is the same answer by a shorter route.
    let grid = tune_score_grid(
      self.data.x,
      self.data.y,
      param_set.map(fn(p : TuneParam) { p.learner_l }),
      n_folds_tune,
      seed,
      scoring,
    )
    let best_param = param_set[grid.best_index]
    // `best_score` is the raw winning score in the chosen metric's
    // natural scale (lower-is-better for MSE / RMSE, higher-is-better
    // for NegMSE). Callers compare across scoring rules by re-running
    // tune with a different rule.
    let result : TuneResult = {
      best: best_param,
      best_score: grid.scores[grid.best_index],
      all_scores: grid.scores,
    }
    // Final re-fit with the chosen (learner_l, learner_m) under the
    // FINAL-FIT fold schedule (`self.n_folds`), NOT under the tune
    // folds. The re-fit call produces its own OOF cross-fit and DML
    // score.
    self.fit(
      learner_l=best_param.learner_l,
      learner_m=best_param.learner_m,
      score~,
      tune_result=Some(result),
    )
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

// --- internal helpers (package-private) ------------------------------

///|
/// Sentinel score for a divergent learner in the tune grid
/// (TUNE_DESIGN.md §7: "score_c = +Inf on a learner failure").
/// 1e300 is large enough that any finite MSE / RMSE compares
/// as strictly less, so the argmin rule automatically excludes
/// the divergent candidate. Avoids depending on
/// `@math.inf` / platform-specific NaN/Inf semantics across
/// the 4 backends (wasm, wasm-gc, js each handle IEEE-754
/// infinity differently when serialized through the FFI
/// boundary).
const TUNE_SCORE_FAIL_SENTINEL : Double = 1.0e300
