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
pub fn PSProcessor::adjust_ps(
  self : PSProcessor,
  ps : Array[Double],
  treatment : Array[Double],
  cv? : Array[(Array[Int], Array[Int])]? = None,
) -> Array[Double] {
  try {
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
fn validate_treatment(treatment : Array[Double]) -> Unit {
  try {
    for t in treatment {
      require(t == 0.0 || t == 1.0)
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
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
      let mut cur_sum = y[i]
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
/// Default 5-fold partition with `seed=3141`. Matches the
/// upstream `cross_val_predict(cv=5)` default.
fn default_5fold(n : Int) -> Array[(Array[Int], Array[Int])] {
  let folds = kfold(n, 5, 3141)
  let out : Array[(Array[Int], Array[Int])] = []
  let mut out_acc = out
  for f = 0; f < folds.length(); f = f + 1 {
    out_acc = out_acc + [(folds[f].train_idx, folds[f].test_idx)]
  }
  out_acc
}
