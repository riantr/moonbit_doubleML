///|
/// `adjust_ps` should clip values into `[eps, 1 - eps]` while
/// leaving interior values untouched.
test "ps_processor_clip_basic" {
  let cfg = PSProcessorConfig::new(clipping_threshold=0.05)
  let psp = PSProcessor::new(config=cfg)
  let ps = [0.001, 0.2, 0.5, 0.8, 0.999]
  let treatment = [0.0, 1.0, 1.0, 0.0, 1.0]
  let out = psp.adjust_ps(ps, treatment)
  inspect(out.length(), content="5")
  // Below eps clipped up to eps.
  inspect(out[0] - 0.05 < 1.0e-12, content="true")
  // Above 1 - eps clipped down to 1 - eps.
  inspect((1.0 - out[4]) - 0.05 < 1.0e-12, content="true")
  // Interior values unchanged.
  inspect((out[1] - 0.2).abs() < 1.0e-12, content="true")
  inspect((out[2] - 0.5).abs() < 1.0e-12, content="true")
  inspect((out[3] - 0.8).abs() < 1.0e-12, content="true")
}

///|
/// The default config uses `clipping_threshold = 1e-2` and no
/// calibration.
test "ps_processor_default_config" {
  let cfg = PSProcessorConfig::default()
  inspect((cfg.clipping_threshold - 1.0e-2).abs() < 1.0e-15, content="true")
  inspect((cfg.extreme_threshold - 1.0e-12).abs() < 1.0e-15, content="true")
  inspect(cfg.calibration_method, content="none")
  inspect(cfg.cv_calibration, content="false")
}

///|
/// `clipping_threshold` must lie in `(0, 0.5)`; values outside
/// should abort.
test "panic_ps_processor_rejects_invalid_clip" {
  let _ = PSProcessorConfig::new(clipping_threshold=0.0)
}

///|
test "panic_ps_processor_rejects_clip_too_large" {
  let _ = PSProcessorConfig::new(clipping_threshold=0.6)
}

///|
/// `isotonic` calibration is reserved but not yet implemented; the
/// constructor should accept it for forward-compatibility, but
/// `cv_calibration=true` without a calibration method is a
/// configuration error.
test "panic_ps_processor_cv_without_calibration" {
  let _ = PSProcessorConfig::new(calibration_method="none", cv_calibration=true)
}

///|
/// `adjust_ps` must not mutate the caller's `ps` array.
test "ps_processor_does_not_mutate_input" {
  let cfg = PSProcessorConfig::new(clipping_threshold=0.05)
  let psp = PSProcessor::new(config=cfg)
  let ps = [0.001, 0.999, 0.5]
  let treatment = [0.0, 1.0, 1.0]
  let _ = psp.adjust_ps(ps, treatment)
  inspect((ps[0] - 0.001).abs() < 1.0e-15, content="true")
  inspect((ps[1] - 0.999).abs() < 1.0e-15, content="true")
  inspect((ps[2] - 0.5).abs() < 1.0e-15, content="true")
}
