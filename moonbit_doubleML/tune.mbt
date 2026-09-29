///|
/// `TuneParam` — one row of the candidate grid passed to
/// `DoubleMLPLR::tune`. Holds a concrete nuisance-learner
/// combination (one `learner_l`, one `learner_m`) to be scored
/// against the others in the grid.
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
/// shape internally (a list of `{"learner_l": ..., "learner_m":
/// ...}` type) but exposes it via kwargs to `set_tune_params`.
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
    require(n_folds_tune >= 2)
    // v0.58.0: cluster-data not yet supported (see file header).
    require(!self.data.is_cluster_data())
    let scoring = TuneScoring::parse(scoring_method)
    // Single-entry grid: skip the scoring loop, re-fit directly
    // (TUNE_DESIGN.md §7: "param_set.length() == 1: skip tune,
    // return re-fit"). Re-bounded control flow keeps the loop
    // body uniform across all paths.
    if param_set.length() == 1 {
      let c0 = param_set[0]
      // No score comparison possible with one candidate, but
      // still record a TuneResult so callers can see what was
      // chosen. `best_score` is the in-sample MSE on `l_hat`
      // computed under `folds_tune` (purely informational —
      // tune() did not run an argmin over multiple candidates).
      let n = self.n_obs()
      let folds_tune = kfold(n, n_folds_tune, seed)
      let l_hat_0 = cross_fit_predict_dispatch(
        c0.learner_l,
        self.data.x,
        self.data.y,
        folds_tune,
      )
      let score_0 = if l_hat_0.length() == n {
        tune_score_outcome(self.data.y, l_hat_0, scoring)
      } else {
        TUNE_SCORE_FAIL_SENTINEL
      }
      let result : TuneResult = {
        best: c0,
        best_score: score_0,
        all_scores: [score_0],
      }
      return self.fit(
        learner_l=c0.learner_l,
        learner_m=c0.learner_m,
        score~,
        tune_result=Some(result),
      )
    }
    let n = self.n_obs()
    let folds_tune = kfold(n, n_folds_tune, seed)
    let scores : Array[Double] = Array::make(param_set.length(), 0.0)
    for i = 0; i < param_set.length(); i = i + 1 {
      let c = param_set[i]
      // Per-candidate cross-fit under `folds_tune`. A defensive
      // length check on `l_hat_c` covers the divergence case
      // (TUNE_DESIGN.md §7): if a learner returns a wrong-size
      // array (e.g. an RFLearner with 0 trees), the score is
      // set to +Inf so the argmin rule excludes the bad
      // candidate. True exception-based divergent-learner
      // recovery is deferred to v0.59.0+ when `Learner::predict`
      // becomes Result-typed.
      let l_hat_c = cross_fit_predict_dispatch(
        c.learner_l,
        self.data.x,
        self.data.y,
        folds_tune,
      )
      scores[i] = if l_hat_c.length() == n {
        tune_score_outcome(self.data.y, l_hat_c, scoring)
      } else {
        TUNE_SCORE_FAIL_SENTINEL
      }
    }
    // argmin over `scores`. For NegMSE (higher-is-better) we
    // negate so the same argmin rule applies uniformly.
    let best_idx = if scoring is NegMSE {
      let mut bi = 0
      let mut bv = scores[0]
      for i = 1; i < scores.length(); i = i + 1 {
        if scores[i] > bv {
          bv = scores[i]
          bi = i
        }
      }
      bi
    } else {
      let mut bi = 0
      let mut bv = scores[0]
      for i = 1; i < scores.length(); i = i + 1 {
        if scores[i] < bv {
          bv = scores[i]
          bi = i
        }
      }
      bi
    }
    let best_param = param_set[best_idx]
    // Build the TuneResult to record on the re-fitted model.
    // `best_score` is the raw winning score in the chosen
    // metric's natural scale (lower-is-better for MSE / RMSE,
    // higher-is-better for NegMSE). Callers compare across
    // scoring rules by re-running tune with a different rule.
    let result : TuneResult = {
      best: best_param,
      best_score: scores[best_idx],
      all_scores: scores,
    }
    // Final re-fit with the chosen (learner_l, learner_m) under
    // the FINAL-FIT fold schedule (`self.n_folds`), NOT under
    // `folds_tune`. The re-fit call produces its own OOF
    // cross-fit and DML score.
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
