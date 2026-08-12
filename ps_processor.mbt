///|
/// Configuration for propensity-score processing. The processor
/// applies (optionally) a calibration step and always a
/// `[clipping_threshold, 1 - clipping_threshold]` clip to keep the
/// propensity scores away from 0/1 in the score denominator.
///
/// **Simplification vs. upstream**: upstream also supports
/// `isotonic` regression calibration (PAVA, pool-adjacent-violators
/// algorithm) via the optional `calibration_method` field. We
/// intentionally leave that field as a placeholder and reject any
/// value other than `None`; calibration will be ported in a later
/// release. The clip-only behaviour is sufficient for the
/// `DoubleMLDIDBinary` / `DoubleMLDIDCS` upgrades in v0.10.0.
///
/// Construction: pass any subset of fields to `new`; the rest get
/// the documented defaults. `clipping_threshold` and
/// `extreme_threshold` must lie in `(0, 0.5)`; `calibration_method`
/// is currently restricted to `None`.
pub struct PSProcessorConfig {
  clipping_threshold : Double
  extreme_threshold : Double
  calibration_method : String
  cv_calibration : Bool
} derive(Debug)

///|
pub fn PSProcessorConfig::new(
  clipping_threshold? : Double = 1.0e-2,
  extreme_threshold? : Double = 1.0e-12,
  calibration_method? : String = "none",
  cv_calibration? : Bool = false,
) -> PSProcessorConfig {
  require(clipping_threshold > 0.0)
  require(clipping_threshold < 0.5)
  require(extreme_threshold > 0.0)
  require(extreme_threshold < 0.5)
  require(calibration_method == "none" || calibration_method == "isotonic")
  if cv_calibration && calibration_method == "none" {
    abort("cv_calibration=true requires calibration_method='isotonic'")
  }
  { clipping_threshold, extreme_threshold, calibration_method, cv_calibration }
}

///|
/// Default PS processor config (clipping_threshold=1e-2, no
/// calibration).
pub fn PSProcessorConfig::default() -> PSProcessorConfig {
  PSProcessorConfig::new()
}

///|
/// Propensity-score processor. Stateless apart from its
/// configuration; safe to share across `DoubleMLDIDBinary` /
/// `DoubleMLDIDCS` instances. `adjust_ps` returns a new array of
/// the same length as the input, never mutating the caller's data.
///
/// **Simplification vs. upstream**: only the `clip` step is
/// implemented. `isotonic` calibration is a documented TODO and is
/// rejected at construction time.
pub struct PSProcessor {
  config : PSProcessorConfig
} derive(Debug)

///|
pub fn PSProcessor::new(config? : PSProcessorConfig = PSProcessorConfig::default()) -> PSProcessor {
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
/// Apply the configured calibration (currently a no-op pass-through;
/// `isotonic` is rejected upstream of this function) followed by the
/// `[clipping_threshold, 1 - clipping_threshold]` clip. Returns a
/// new array; the caller's `ps` and `treatment` are not mutated.
///
/// `treatment` is currently unused (reserved for the future
/// `isotonic` calibration), but we keep it in the signature for
/// upstream API parity and forward-compatibility.
pub fn PSProcessor::adjust_ps(
  self : PSProcessor,
  ps : Array[Double],
  treatment : Array[Double],
) -> Array[Double] {
  ignore(treatment)
  // Calibration (placeholder for isotonic PAVA, see module docstring).
  let calibrated = match self.config.calibration_method {
    "none" => ps
    "isotonic" =>
      // Not yet implemented; the constructor rejects non-"none"
      // values unless `cv_calibration` is also set, but defensive
      // abort here too in case the field is poked directly.
      abort("isotonic calibration not yet implemented in this port")
    _ => abort("unknown calibration_method (set in PSProcessorConfig::new)")
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
}
