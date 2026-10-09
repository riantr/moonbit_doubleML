///|
/// Configuration for propensity-score processing. The processor
/// applies (optionally) a calibration step and always a
/// `[clipping_threshold, 1 - clipping_threshold]` clip to keep the
/// propensity scores away from 0/1 in the score denominator.
///
/// **Calibration** (v0.14.0+): the only currently supported method is
/// `isotonic` regression (PAVA, pool-adjacent-violators algorithm).
/// Set `calibration_method="isotonic"` to fit an isotonic regression
/// of `treatment` on `ps` and use the fitted curve as the calibrated
/// propensity. Combine with `cv_calibration=true` to use K-fold
/// cross-validated calibration (matches upstream
/// `sklearn.model_selection.cross_val_predict`); pass `cv` to
/// `PSProcessor::adjust_ps` to control the fold partition.
pub(all) struct PSProcessorConfig {
  clipping_threshold : Double
  extreme_threshold : Double
  calibration_method : String
  cv_calibration : Bool
} derive(Debug)

///|
pub extend PSProcessorConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Returns `PSProcessorConfig raise PSConfigError`: the v0.44.0
/// conversion replaces the previous `abort()` call with
/// `raise PSConfigError::InconsistentCVCalibration` so the
/// inconsistent-configuration path becomes directly testable.
/// Callers that want the pre-v0.44.0 process-death behavior
/// should catch the error and re-abort (this is what
/// `PSProcessorConfig::default` does, although it never
/// triggers the error in practice). The `require` checks on
/// the four argument ranges are unchanged and still abort the
/// process (they are central `require` checks; refactoring
/// them is out of scope for this surgical release).
pub fn PSProcessorConfig::new(
  clipping_threshold? : Double = 1.0e-2,
  extreme_threshold? : Double = 1.0e-12,
  calibration_method? : String = "none",
  cv_calibration? : Bool = false,
) -> PSProcessorConfig raise PSConfigError {
  // v0.48.0: per-call wrap on each `require` because the body also
  // raises PSConfigError::InconsistentCVCalibration; a block-level
  // try/catch would partial_match the catch.
  ignore(
    require(clipping_threshold > 0.0) catch {
      PreconditionError::Violated(loc) =>
        abort("precondition failed at " + loc.to_string())
    },
  )
  ignore(
    require(clipping_threshold < 0.5) catch {
      PreconditionError::Violated(loc) =>
        abort("precondition failed at " + loc.to_string())
    },
  )
  ignore(
    require(extreme_threshold > 0.0) catch {
      PreconditionError::Violated(loc) =>
        abort("precondition failed at " + loc.to_string())
    },
  )
  ignore(
    require(extreme_threshold < 0.5) catch {
      PreconditionError::Violated(loc) =>
        abort("precondition failed at " + loc.to_string())
    },
  )
  ignore(
    require(calibration_method == "none" || calibration_method == "isotonic") catch {
      PreconditionError::Violated(loc) =>
        abort("precondition failed at " + loc.to_string())
    },
  )
  if cv_calibration && calibration_method == "none" {
    raise PSConfigError::InconsistentCVCalibration
  }
  { clipping_threshold, extreme_threshold, calibration_method, cv_calibration, }
}

///|
/// Default PS processor config (clipping_threshold=1e-2, no
/// calibration). v0.44.0: returns a pre-constructed default
/// via a private helper that doesn't raise, so this signature
/// stays `PSProcessorConfig` (no `raise`).
pub fn PSProcessorConfig::default() -> PSProcessorConfig {
  // The default args are valid (no cv_calibration,
  // calibration_method="none"), so the cv_calibration abort
  // is unreachable. Construct directly without going
  // through the `new()` raise path.
  {
    clipping_threshold: 1.0e-2,
    extreme_threshold: 1.0e-12,
    calibration_method: "none",
    cv_calibration: false,
  }
}

///|
/// Propensity-score processor. Stateless apart from its
/// configuration; safe to share across `DoubleMLDIDBinary` /
/// `DoubleMLDIDCS` instances. `adjust_ps` returns a new array of
/// the same length as the input, never mutating the caller's data.
///
/// **v0.14.0+**: the `isotonic` calibration method is now fully
/// implemented (was a placeholder in v0.10.0). The pure-MoonBit
/// PAVA implementation in `pava` produces a step-function
/// isotonic regression; with `cv_calibration=true`, K-fold
/// cross-validated predictions are used instead (one isotonic fit
/// per fold, predictions concatenated across folds).
pub struct PSProcessor {
  config : PSProcessorConfig
} derive(Debug)

///|
pub extend PSProcessor with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn PSProcessor::new(
  config? : PSProcessorConfig = PSProcessorConfig::default(),
) -> PSProcessor {
  { config, }
}

///|
/// Convenience constructor mirroring upstream
/// `PSProcessor.from_config`.
pub fn PSProcessor::from_config(config : PSProcessorConfig) -> PSProcessor {
  { config, }
}

///|
pub fn PSProcessor::clipping_threshold(self : PSProcessor) -> Double {
  self.config.clipping_threshold
}

///|
pub fn PSProcessor::extreme_threshold(self : PSProcessor) -> Double {
  self.config.extreme_threshold
}

///|
pub fn PSProcessor::calibration_method(self : PSProcessor) -> String {
  self.config.calibration_method
}

///|
pub fn PSProcessor::cv_calibration(self : PSProcessor) -> Bool {
  self.config.cv_calibration
}

///|
/// Port of upstream `init_ps_processor`
/// (`utils/propensity_score_processing.py:60`), the function twelve
/// upstream estimators call: `apo`, `apos`, `cvar`, `iivm`, `irm`,
/// `lpq`, `pq`, `qte`, `ssm`, `did_binary`, `did_cs_binary`,
/// `did_multi`.
///
/// Its whole body is a precedence rule, and it is worth stating
/// exactly because it is not the obvious one:
///
///     if ps_processor_config is not None:
///         config = ps_processor_config          # config wins outright
///     else:
///         config = PSProcessorConfig(clipping_threshold=trimming_threshold)
///
/// MEASURED against upstream 0.11.4 (`_probe_v121_psconfig.py`):
///
///   init_ps_processor(None, "truncate", None) -> clip=0.01
///   init_ps_processor(None, "truncate", 0.05) -> clip=0.05
///   init_ps_processor(cfg(0.3), "truncate", 0.05) -> clip=0.3   <- the
///       deprecated scalar is IGNORED once a config is present, not
///       merged with it and not used as a fallback for a missing field.
///
/// Upstream then derives the legacy attribute from the processor
/// (`self._trimming_threshold = self._ps_processor.clipping_threshold`),
/// so a caller reading `propensity_clip` back sees the CONFIG's value.
/// This port's estimators keep the same relationship.
///
/// Upstream's default when neither argument is given is
/// `clipping_threshold = 1e-2`. This port's estimators have historically
/// defaulted `propensity_clip` to `1e-6`, so the default lives at the
/// CALL SITE, not here: `trimming_threshold` is the value the caller
/// wants, and changing it would silently move every existing result.
///
/// Note the upstream validator rejects `cv_calibration=True` without a
/// calibration method ("cv_calibration=True requires a
/// calibration_method."). That check already lives in
/// `PSProcessorConfig::new`, so it fires on the `Some` arm before this
/// function ever sees it.
pub fn resolve_ps_processor(
  ps_processor_config? : PSProcessorConfig? = None,
  trimming_threshold? : Double = 1.0e-2,
) -> PSProcessor {
  PSProcessor::from_config(
    resolve_ps_processor_config(ps_processor_config~, trimming_threshold~),
  )
}

///|
/// The same resolution as `resolve_ps_processor`, returning the CONFIG
/// rather than the processor. An estimator stores the config (never
/// `None`) so it can hand `Some(this)` to a child and get a
/// byte-identical processor; building the processor from a stored
/// config is a struct wrap, so this is the natural thing to keep.
///
/// The single definition of the precedence rule lives here.
pub fn resolve_ps_processor_config(
  ps_processor_config? : PSProcessorConfig? = None,
  trimming_threshold? : Double = 1.0e-2,
) -> PSProcessorConfig {
  match ps_processor_config {
    Some(cfg) => cfg
    None =>
      PSProcessorConfig::new(clipping_threshold=trimming_threshold) catch {
        PSConfigError::InconsistentCVCalibration =>
          abort(
            "resolve_ps_processor: unreachable -- the fallback config " +
            "sets calibration_method = \"none\" and cv_calibration = " +
            "false, which cannot be inconsistent",
          )
      }
  }
}

///|
/// Apply the configured calibration followed by the
/// `[clipping_threshold, 1 - clipping_threshold]` clip. Returns a
/// new array; the caller's `ps` and `treatment` are not mutated.
///
/// `cv` is consulted only when `config.calibration_method =
/// "isotonic"` and `config.cv_calibration = true`. It is a list of
/// folds, each a pair `(train_indices, test_indices)` — when
/// `cv = None`, a deterministic 5-fold split with `seed=3141` is
/// used. With `cv_calibration = false`, `cv` is ignored and the
/// isotonic fit uses the full `(ps, treatment)` (matches upstream
/// `IsotonicRegression` default: no CV).
///
/// With the default config this is exactly `clip_vec(ps, eps, 1-eps)`,
/// which is what all twelve estimators were doing inline before
/// `ps_processor_config` became reachable. MEASURED: on the
/// v0.121.0 oracle fixture `max |adjust_ps(ps, d) - ps| = 0.0` for
/// `calibration_method = "none"`, so routing the existing clip site
/// through here is behaviour-preserving and is asserted as such.
pub fn PSProcessor::adjust_ps(
  self : PSProcessor,
  ps : Array[Double],
  treatment : Array[Double],
  cv? : Array[(Array[Int], Array[Int])]? = None,
) -> Array[Double] {
  try {
    // The binary-treatment requirement, UNCONDITIONALLY, matching
    // upstream `PSProcessor.adjust_ps`.
    //
    // HISTORY, because the reason changed. v0.122.0 scoped this to
    // `calibration_method == "isotonic"`, on the stated grounds that
    // "upstream has no continuous-treatment estimator so it never
    // notices, but this port does". That diagnosis was WRONG about the
    // cause. Upstream `DoubleMLIIVM` does not pass the treatment here --
    // `iivm.py:371` passes the INSTRUMENT `z`, which is binary even when
    // `d` is not. The v0.122.0 abort came from THIS PORT passing `d` at
    // the IIVM clip site, which is the bug v0.123.0 fixed.
    //
    // So the scoping was papering over a port defect, and it had to go:
    // with the check skipped under the default config, passing `d`
    // instead of `z` would have been UNDETECTABLE -- the continuous-`d`
    // cluster fixture would still have passed. Restoring the
    // unconditional check is what turns that fixture into a real gate.
    validate_treatment(treatment)
    require(ps.length() == treatment.length())
    let n = ps.length()
    require(n > 0)
    // Calibration step. v0.37.0: extracted into apply_calibration
    // helper that raises InvalidCalibrationError on unknown
    // calibration method; catch and re-abort to preserve pre-v0.37.0
    // process-death behavior. v0.38.0: apply_calibration now also
    // propagates CalibrationFittingError from isotonic_calibrate_cv;
    // we re-abort to preserve the pre-v0.38.0 behavior on a malformed
    // cv partition.
    let calibrated = apply_calibration(self.config, ps, treatment, cv) catch {
      InvalidCalibrationError::UnknownMethod(m) =>
        abort(
          "unknown calibration_method (set in PSProcessorConfig::new): " + m,
        )
      CalibrationFittingError::IncompleteCVPartition =>
        abort("isotonic_calibrate_cv: cv partition does not cover all indices")
      _ => abort("apply_calibration: unknown error")
    }
    // Clip to [eps, 1 - eps].
    let lo = self.config.clipping_threshold
    let hi = 1.0 - self.config.clipping_threshold
    let out : Array[Double] = Array::make(calibrated.length(), 0.0)
    for i = 0; i < calibrated.length(); i = i + 1 {
      let v = calibrated[i]
      if v < lo {
        out[i] = lo
      } else if v > hi {
        out[i] = hi
      } else {
        out[i] = v
      }
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Apply the configured calibration method to a propensity-score
/// vector. Returns `Array[Double] raise InvalidCalibrationError`:
/// the v0.37.0 extraction lifts the previous `abort()` call from
/// `PSProcessor::adjust_ps` into this helper so the unknown-method
/// path becomes directly testable. `PSProcessor::adjust_ps` wraps
/// the call in `try ... catch { ... => abort(...) }` to preserve
/// pre-v0.37.0 process-death behavior.
///
/// Note: `PSProcessorConfig::new` also has a `require` check on
/// `calibration_method` (only `"none"` and `"isotonic"` are
/// allowed). That check normally fires first; this helper's
/// raise only fires if a config is constructed directly (bypassing
/// `new`), which the new `ps_processor_adjust_ps_raises_unknown_method`
/// test does deliberately.
pub fn apply_calibration(
  config : PSProcessorConfig,
  ps : Array[Double],
  treatment : Array[Double],
  cv : Array[(Array[Int], Array[Int])]?,
) -> Array[Double] raise Error {
  match config.calibration_method {
    "none" => ps
    "isotonic" =>
      if config.cv_calibration {
        isotonic_calibrate_cv(ps, treatment, cv)
      } else {
        let (sorted_x, y_hat) = fit_isotonic(ps, treatment)
        predict_isotonic_from_fit(ps, sorted_x, y_hat)
      }
    _ => raise InvalidCalibrationError::UnknownMethod(config.calibration_method)
  }
}

// ---------------------------------------------------------------------------
// Internal: propensity-score + treatment validation
// ---------------------------------------------------------------------------

///|
/// The rule `validate_treatment` enforces, as a total predicate.
///
/// Extracted in v0.122.0 so the rule itself is testable. The abort is not:
/// MoonBit's `panic_`-prefixed test convention cannot detect a MISSING abort
/// (a non-aborting `panic_` test still passes), so `validate_treatment`
/// alone had no load-bearing gate -- the mutation harness confirmed it
/// (`v122-adjust-ps-never-validates` SURVIVES). This predicate is the part
/// that carries meaning, and it can be asserted on directly.
///
/// Public so a caller can check its own treatment before handing it to
/// `adjust_ps` with a calibration configured. `true` for an empty array:
/// "no offending element" is vacuously binary, and `adjust_ps` separately
/// rejects `n == 0`.
pub fn treatment_is_binary(treatment : Array[Double]) -> Bool {
  for t in treatment {
    if !(t == 0.0 || t == 1.0) {
      return false
    }
  }
  true
}

///|
fn validate_treatment(treatment : Array[Double]) -> Unit {
  if !treatment_is_binary(treatment) {
    abort("precondition failed: treatment must be binary")
  }
}

// ---------------------------------------------------------------------------
// Internal: isotonic regression via PAVA
// ---------------------------------------------------------------------------

///|
/// Pool-adjacent-violators algorithm. Given a sequence of values
/// `y[0..n]` (assumed already sorted by the predictor `x`, which
/// is monotone non-decreasing in the index), `pava` returns the
/// isotonic (non-decreasing) L2 projection of `y`. Tied predictors
/// are handled naturally by the algorithm (they form a single
/// block whose mean is the projection value).
///
/// Optional `weights[0..n]` is a per-element weight; default is
/// unit weight for every element. Each output block is the
/// weighted mean of its constituent elements.
///
/// The algorithm walks the input once, maintaining a stack of
/// "blocks" — each block holds `(sum_y, sum_w, size)`. When a new
/// value would create a violation (the previous block's mean is
/// greater than the new block's mean), the algorithm pools the two
/// blocks and re-checks. The result is the canonical
/// weighted-PAVA output: a non-decreasing sequence that minimises
/// the weighted sum of squared residuals subject to the
/// monotonicity constraint.
///
/// The input MUST be sorted by `x` in non-decreasing order. Use
/// `fit_isotonic` for the public entry point that sorts and
/// returns the fitted model.
pub fn pava(y : Array[Double], weights? : Array[Double] = []) -> Array[Double] {
  try {
    let n = y.length()
    if n == 0 {
      return []
    }
    let w : Array[Double] = if weights.length() == 0 {
      Array::make(n, 1.0)
    } else {
      require(weights.length() == n)
      weights
    }
    // Parallel arrays as a poor man's stack of (sum_y, sum_w, size)
    // blocks. MoonBit has no native tuple-array sort, but the
    // per-field arrays stay synchronised because every push/pop
    // updates all three in lockstep.
    let block_sum : Array[Double] = []
    let block_w : Array[Double] = []
    let block_size : Array[Int] = []
    for i = 0; i < n; i = i + 1 {
      // v0.104.0: this seeded the block's weighted sum with the
      // RAW `y[i]`, so a block's mean came out as
      // `(sum of y) / (sum of w)` instead of
      // `(sum of w * y) / (sum of w)`. With unit weights the
      // two coincide, which is why the unweighted cases still
      // passed after the fix; with any non-uniform weight the
      // fitted block value is wrong. Caught by
      // `validate_pava_with_python.py` against
      // `sklearn.isotonic.isotonic_regression`: for
      // y = [0.2, 0.5, 0.1, 0.8], w = [1, 1, 0.25, 1] the pooled
      // block holds 0.5 and 0.1, whose correct weighted mean is
      // (1*0.5 + 0.25*0.1) / 1.25 = 0.42; this computed
      // (0.5 + 0.1) / 1.25 = 0.48.
      let mut cur_sum = w[i] * y[i]
      let mut cur_w = w[i]
      let mut cur_size = 1
      // Pool with previous blocks as long as the last block's
      // (weighted) mean is greater than the new block's mean.
      while block_size.length() > 0 {
        let last_idx = block_size.length() - 1
        let last_mean = block_sum[last_idx] / block_w[last_idx]
        let new_mean = cur_sum / cur_w
        if last_mean <= new_mean {
          break
        }
        // Pool: pop the last block, fold its content into the new
        // block, and continue checking.
        cur_size = cur_size + block_size[last_idx]
        cur_sum = cur_sum + block_sum[last_idx]
        cur_w = cur_w + block_w[last_idx]
        block_size.truncate(last_idx)
        block_sum.truncate(last_idx)
        block_w.truncate(last_idx)
      }
      block_size.push(cur_size)
      block_sum.push(cur_sum)
      block_w.push(cur_w)
    }
    // Flatten the block stack back to a per-element output. Each
    // block contributes `block_size[b]` copies of its (weighted)
    // mean `block_sum[b] / block_w[b]`.
    let out : Array[Double] = Array::make(n, 0.0)
    let mut k = 0
    for b = 0; b < block_size.length(); b = b + 1 {
      let mean = block_sum[b] / block_w[b]
      let size = block_size[b]
      let mut _i = 0
      while _i < size {
        out[k] = mean
        k = k + 1
        _i = _i + 1
      }
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Sort `(x, y)` pairs by `x` and apply PAVA to the sorted `y`.
/// Returns `(sorted_x, sorted_y_hat)` where `sorted_y_hat` is the
/// isotonic regression of `y` on `x`. The two arrays have the
/// same length as the input.
///
/// Use `predict_isotonic` to apply the fitted model to new `x`
/// values (or to the same `x` for in-sample predictions, which
/// is the upstream `IsotonicRegression` default).
pub fn fit_isotonic(
  x : Array[Double],
  y : Array[Double],
) -> (Array[Double], Array[Double]) {
  try {
    let n = x.length()
    require(y.length() == n)
    require(n > 0)
    // Sort indices by x.
    let order : Array[Int] = Array::makei(n, fn(i) { i })
    order.sort_by(fn(a, b) { x[a].compare(x[b]) })
    let sorted_x : Array[Double] = Array::make(n, 0.0)
    let sorted_y : Array[Double] = Array::make(n, 0.0)
    for k = 0; k < n; k = k + 1 {
      let i = order[k]
      sorted_x[k] = x[i]
      sorted_y[k] = y[i]
    }
    let sorted_y_hat = pava(sorted_y)
    (sorted_x, sorted_y_hat)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Predict the isotonic regression at new `x` values using the
/// fitted model `(fitted_x, fitted_y_hat)`. Behaviour matches
/// `sklearn.isotonic.IsotonicRegression(out_of_bounds="clip",
/// y_min=0.0, y_max=1.0)`:
/// - For `x_new[i]` strictly less than `min(fitted_x)`: return
///   `fitted_y_hat[0]` (clipped at the lower boundary).
/// - For `x_new[i]` strictly greater than `max(fitted_x)`: return
///   `fitted_y_hat[last]` (clipped at the upper boundary).
/// - Otherwise: return `fitted_y_hat` at the largest `fitted_x[j]
///   <= x_new[i]`, found by linear scan (PAVA produces a step
///   function, and the step boundaries are the `fitted_x` values
///   themselves).
///
/// We additionally clip the prediction to `[0.0, 1.0]` since the
/// fitted `y_hat` values are guaranteed to be in `[0, 1]` for
/// binary `y` (PAVA output on a 0/1 input lies in `[0, 1]`), but
/// the clip makes the contract explicit and protects against any
/// numerical drift.
pub fn predict_isotonic(
  fitted_x : Array[Double],
  fitted_y_hat : Array[Double],
  x_new : Array[Double],
) -> Array[Double] {
  try {
    let n_new = x_new.length()
    let n_fit = fitted_x.length()
    require(n_fit > 0)
    require(fitted_y_hat.length() == n_fit)
    let lo = fitted_y_hat[0]
    let hi = fitted_y_hat[n_fit - 1]
    let out : Array[Double] = Array::make(n_new, 0.0)
    // Pre-compute the right-edge index of the block containing each
    // fitted `x`. Since `fitted_x` is sorted in non-decreasing
    // order, the right edge of a block is the largest `j` such
    // that `fitted_y_hat[j]` is constant. Concretely: walk `j` from
    // 0 to `n_fit - 1`; whenever `fitted_y_hat[j]` changes, the
    // block ends at `j - 1`. The block containing `j` ends at the
    // first `k > j` with `fitted_y_hat[k] != fitted_y_hat[j] - 1`.
    // For prediction, the easiest lookup is: given `x_new[i]`,
    // find the largest `j` with `fitted_x[j] <= x_new[i]`, then
    // return `fitted_y_hat[j]`. We do that with a single linear
    // scan that walks `fitted_x` and `x_new` in lockstep.
    for i = 0; i < n_new; i = i + 1 {
      let x = x_new[i]
      if x < fitted_x[0] {
        out[i] = lo
      } else if x > fitted_x[n_fit - 1] {
        out[i] = hi
      } else {
        // Find the largest j with fitted_x[j] <= x.
        let mut j = 0
        while j < n_fit - 1 && fitted_x[j + 1] <= x {
          j = j + 1
        }
        let v = fitted_y_hat[j]
        // Defensive clip to [0, 1] (PAVA on {0, 1} stays in [0, 1]
        // by construction, but the clip makes the contract
        // explicit).
        if v < 0.0 {
          out[i] = 0.0
        } else if v > 1.0 {
          out[i] = 1.0
        } else {
          out[i] = v
        }
      }
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Predict at the original `x` values. Convenience for the
/// non-CV path where the in-sample prediction IS the calibrated
/// propensity. Since `fitted_y_hat` is the PAVA output on
/// `(sorted_x, sorted_y)`, predicting at the original (unsorted)
/// `x` requires a step-function lookup: for each `x[i]`, find
/// the largest `j` with `sorted_x[j] <= x[i]` and return
/// `fitted_y_hat[j]`.
fn predict_isotonic_from_fit(
  x : Array[Double],
  sorted_x : Array[Double],
  fitted_y_hat : Array[Double],
) -> Array[Double] {
  predict_isotonic(sorted_x, fitted_y_hat, x)
}

///|
/// K-fold cross-validated isotonic calibration. For each fold
/// `(train_idx, test_idx)`, fit an isotonic regression on
/// `(x[train], y[train])` and predict at `x[test]`. The output
/// array is built in the original `x` order (not the fold
/// order) by writing `out[test_idx[i]] = pred[i]`.
///
/// `cv` is a list of `(train_idx, test_idx)` pairs. When `cv =
/// None`, a deterministic 5-fold split with `seed=3141` is
/// generated via `kfold`. Each fold's prediction is independent
/// of every other fold's, so this is embarrassingly parallel
/// (sequential here for simplicity, but the per-fold work is
/// O(n log n) for the sort + O(n) for the PAVA scan).
///
/// Returns `Array[Double] raise CalibrationFittingError`: the
/// v0.38.0 conversion replaces the previous `abort()` call with
/// `raise CalibrationFittingError::IncompleteCVPartition` when
/// the cv partition fails to cover every input index. Callers
/// that want the pre-v0.38.0 process-death behavior should catch
/// the error and re-abort (this is what `apply_calibration` does);
/// callers that want to surface the error to downstream
/// consumers should propagate via `?`.
pub fn isotonic_calibrate_cv(
  x : Array[Double],
  y : Array[Double],
  cv : Array[(Array[Int], Array[Int])]?,
) -> Array[Double] raise CalibrationFittingError {
  let n = x.length()
  let folds : Array[(Array[Int], Array[Int])] = match cv {
    Some(f) => f
    None => default_5fold(n)
  }
  // v0.48.0: per-call wrap because the body also raises
  // CalibrationFittingError::IncompleteCVPartition; a block-level
  // try/catch would partial_match the catch.
  ignore(
    require(folds.length() > 0) catch {
      PreconditionError::Violated(loc) =>
        abort("precondition failed at " + loc.to_string())
    },
  )
  let out : Array[Double] = Array::make(n, 0.0)
  let seen : Array[Bool] = Array::make(n, false)
  for fold = 0; fold < folds.length(); fold = fold + 1 {
    let (train_idx, test_idx) = folds[fold]
    // Pull out the training data.
    let x_train : Array[Double] = []
    let y_train : Array[Double] = []
    let mut x_train_acc = x_train
    let mut y_train_acc = y_train
    for k = 0; k < train_idx.length(); k = k + 1 {
      let i = train_idx[k]
      x_train_acc = x_train_acc + [x[i]]
      y_train_acc = y_train_acc + [y[i]]
    }
    // Pull out the test x values.
    let x_test : Array[Double] = []
    let mut x_test_acc = x_test
    for k = 0; k < test_idx.length(); k = k + 1 {
      x_test_acc = x_test_acc + [x[test_idx[k]]]
    }
    // Fit on the training fold, predict on the test fold.
    let (sorted_x, sorted_y_hat) = fit_isotonic(x_train_acc, y_train_acc)
    let pred = predict_isotonic(sorted_x, sorted_y_hat, x_test_acc)
    for k = 0; k < test_idx.length(); k = k + 1 {
      let j = test_idx[k]
      out[j] = pred[k]
      seen[j] = true
    }
  }
  // Each input index must be predicted by exactly one fold.
  // Raise if any index is uncovered (a malformed cv partition).
  for i = 0; i < n; i = i + 1 {
    if !seen[i] {
      raise CalibrationFittingError::IncompleteCVPartition
    }
  }
  out
}

///|
/// Default 5-fold partition for cross-validated calibration.
///
/// v0.121.0 FIX. This used to call `kfold(n, 5, 3141)`, and its comment
/// claimed it "matches the upstream `cross_val_predict(cv=5)` default".
/// **That was false and the oracle proved it.** Upstream
/// `_apply_calibration` calls
///
///     cross_val_predict(estimator, X, y, cv=cv, method="predict")
///
/// with `cv=None`, which `check_cv` resolves to `KFold(n_splits=5,
/// shuffle=False)` -- contiguous and NOT shuffled. `kfold` shuffles, so
/// the two partitions differ, and on a miscalibrated propensity the
/// resulting isotonic fits differ materially: MEASURED 0.24 against
/// upstream on the v0.121.0 oracle fixture (and 0.14 between sklearn's
/// own `cv=None` and its shuffled equivalent on the same arrays, so the
/// effect is entirely the partition, not the estimator).
///
/// The rule below is sklearn's, verified against `KFold(shuffle=False)`
/// for n in {5,6,7,8,13,200,201} and k in {3,4,5}: contiguous blocks of
/// `base = n / k` rows, with the FIRST `rem = n % k` folds one row
/// longer. Feeding that partition back to `cross_val_predict` reproduces
/// `cv=None` at max diff 0.0.
///
/// Callers who want a different partition still pass `cv` explicitly;
/// that path is unchanged.
fn default_5fold(n : Int) -> Array[(Array[Int], Array[Int])] {
  let k = 5
  let base = n / k
  let rem = n % k
  let out : Array[(Array[Int], Array[Int])] = []
  let mut out_acc = out
  let mut start = 0
  for f = 0; f < k; f = f + 1 {
    let size = base + (if f < rem { 1 } else { 0 })
    let test_idx : Array[Int] = []
    let mut test_acc = test_idx
    let mut i = start
    while i < start + size {
      test_acc = test_acc + [i]
      i = i + 1
    }
    let train_idx : Array[Int] = []
    let mut train_acc = train_idx
    let mut j = 0
    while j < n {
      if j < start || j >= start + size {
        train_acc = train_acc + [j]
      }
      j = j + 1
    }
    out_acc = out_acc + [(train_acc, test_acc)]
    start = start + size
  }
  out_acc
}

// ---------------------------------------------------------------------------
// Inverse-probability-weight normalisation (v0.119.0)
// ---------------------------------------------------------------------------

///|
/// v0.119.0: normalize inverse probability weights so the mean weight
/// within each treatment group is 1. Ports upstream
/// `doubleml.utils._propensity_score._normalize_ipw`:
///
///     mean_treat1 = mean(treatment / propensity)
///     mean_treat0 = mean((1 - treatment) / (1 - propensity))
///     normalized  = treatment * propensity * mean_treat1
///                 + (1 - treatment) * (1 - (1 - propensity) * mean_treat0)
///
/// Intuition: the raw weight `treatment / propensity` is unbiased for
/// the treated count but its scale carries the nuisance model's bias,
/// so it inflates the variance of the score. Multiplying by
/// `mean_treat1` removes that constant-of-proportionality factor.
///
/// # The 1e-12 clamp is a DELIBERATE deviation
///
/// Upstream divides by `propensity` with no guard at all. This clamps
/// both denominators at `1e-12`, so a propensity of exactly 0 yields a
/// weight of 0 rather than `inf` or `NaN`.
///
/// The two agree bit-for-bit on any propensity bounded away from zero,
/// which is what `_verify/gen_v119_oracle.py` checks -- the goldens are
/// generated by calling upstream's own function on the fixture. The
/// clamp only matters on a degenerate propensity, where upstream
/// returns `inf` and propagates `NaN` through the whole estimator while
/// this returns a finite, bounded number. That is recorded as a
/// difference rather than hidden: v0.119.0's
/// `v119_normalized_ipw_matches_upstream` pins the agreement, and
/// `v119_normalized_ipw_survives_a_degenerate_propensity` pins the
/// clamp.
///
/// # Why this moved here
///
/// `cvar.mbt` has carried a private copy of exactly this function since
/// its `normalize_ipw` option landed. Two private copies of an
/// upstream-tracked formula is how the two drift apart, so this is the
/// single definition and `cvar.mbt` now calls it. It was promoted from
/// private to `pub` for the same reason: an oracle cross-check cannot
/// import a file-private function.
///
/// `treatment` must be the 0/1 indicator, matching upstream's
/// `treatment_indicator`; `validate_treatment` is the gate.
pub fn normalize_ipw(
  propensity : Array[Double],
  treatment : Array[Double],
) -> Array[Double] {
  let n = propensity.length()
  let m_clip = clip_vec(propensity, 1.0e-12, 1.0)
  // v0.119.0: the CONTROL denominator is `1 - p`, not `p`. This was
  // written as a second `clip_vec(m_clip, ...)` -- which clips the
  // propensity to itself and leaves the control weights un-normalised.
  // The upstream oracle caught it: on the fixture's row 18 (p ~ 0.09) the
  // port returned +0.9019 where upstream returns -0.0136, a sign flip
  // that only appears where `1 - p` and `p` disagree.
  //
  // That it survived the whole v0.119.0 gate suite is the sharper
  // point: `cvar.mbt` now DELEGATES here, so the bug was live in CVAR's
  // `normalize_ipw` path, and no pre-existing test noticed. One
  // external oracle bought more than the entire internal suite.
  let om_clip : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let om = 1.0 - m_clip[i]
    om_clip[i] = if om < 1.0e-12 { 1.0e-12 } else { om }
  }
  let mut sum_t1 = 0.0
  let mut sum_t0 = 0.0
  for i = 0; i < n; i = i + 1 {
    sum_t1 = sum_t1 + treatment[i] / m_clip[i]
    sum_t0 = sum_t0 + (1.0 - treatment[i]) / om_clip[i]
  }
  let mean_t1 = sum_t1 / n.to_double()
  let mean_t0 = sum_t0 / n.to_double()
  let out = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let w1 = treatment[i] * m_clip[i] * mean_t1
    let w0 = (1.0 - treatment[i]) * (1.0 - om_clip[i] * mean_t0)
    out[i] = w1 + w0
  }
  out
}

///|
/// v0.119.0: upstream `doubleml.utils._propensity_score
/// ._propensity_score_adjustment` -- the switch that decides whether the
/// propensity enters the score raw or IPW-normalized.
///
/// `normalize_ipw = false` is the IDENTITY, verified against upstream:
/// `gen_v119_oracle.py` reports `adjust_identity_max_diff = 0.0`. That
/// is the whole point of the flag, and it is why the default on
/// `DoubleMLAPO` / `DoubleMLAPOS` is `false` (upstream's
/// `apo.py:97` default) -- turning normalization on must move the
/// answer, and leaving it off must not.
pub fn propensity_score_adjustment(
  propensity : Array[Double],
  treatment : Array[Double],
  do_normalize? : Bool = false,
) -> Array[Double] {
  // v0.119.0: the parameter is deliberately NOT named `normalize_ipw`.
  // That would shadow the function of the same name, turning the call
  // below into an invocation of a Bool. It surfaced as a bare type
  // mismatch rather than anything a reader could diagnose.
  if do_normalize {
    normalize_ipw(propensity, treatment)
  } else {
    propensity
  }
}

///|
/// v0.119.0: upstream `doubleml.utils._propensity_score._trimm`.
///
/// `rule = "truncate"` clips to `[threshold, 1 - threshold]`; anything
/// else (upstream's `None`) is the identity. Kept because
/// `trimming_rule` / `trimming_threshold` are deprecated-but-still-live
/// upstream parameters (see the `DeprecationWarning` at
/// `propensity_score_processing.py:59`) and `DoubleMLDIDCSBinary`
/// still exposes the collapsed form of them.
pub fn trim_predictions(
  preds : Array[Double],
  rule : String,
  threshold : Double,
) -> Array[Double] {
  if rule == "truncate" {
    clip_vec(preds, threshold, 1.0 - threshold)
  } else {
    preds
  }
}
