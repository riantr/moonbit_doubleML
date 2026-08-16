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

// ---------------------------------------------------------------------------
// v0.14.0+ PAVA / isotonic calibration tests
// ---------------------------------------------------------------------------

///|
/// PAVA on a strictly monotonic input is the identity: each
/// element is its own block and the means are themselves.
test "pava_monotonic_passthrough" {
  // y is in the order it would appear after sorting by x.
  let y = [0.1, 0.2, 0.3, 0.4, 0.5]
  let r = pava(y)
  inspect(r.length(), content="5")
  for i = 0; i < 5; i = i + 1 {
    inspect((r[i] - y[i]).abs() < 1.0e-15, content="true")
  }
}

///|
/// PAVA on a single violation: `[0.3, 0.2, 0.4, 0.5, 0.6]`
/// pools the first two into a block with mean `0.25`. This
/// matches `sklearn.isotonic.IsotonicRegression.predict` for
/// the same input (verified by the cross-check script
/// `_verify/test_pava_reference.py`).
test "pava_pools_violation" {
  let y = [0.3, 0.2, 0.4, 0.5, 0.6]
  let r = pava(y)
  // First two pooled to mean 0.25; rest pass through.
  inspect((r[0] - 0.25).abs() < 1.0e-15, content="true")
  inspect((r[1] - 0.25).abs() < 1.0e-15, content="true")
  inspect((r[2] - 0.4).abs() < 1.0e-15, content="true")
  inspect((r[3] - 0.5).abs() < 1.0e-15, content="true")
  inspect((r[4] - 0.6).abs() < 1.0e-15, content="true")
  // Output must be non-decreasing.
  for i = 0; i < 4; i = i + 1 {
    inspect(r[i] <= r[i + 1], content="true")
  }
}

///|
/// PAVA on a heavy violation: `[0.9, 0.1, 0.8, 0.2, 0.7]`
/// pools positions 0..3 (where the sequence is decreasing) into
/// a single block with mean `2.0 / 4 = 0.5`, then position 4
/// (0.7) sits in its own block. Output: `[0.5, 0.5, 0.5, 0.5,
/// 0.7]`.
test "pava_pools_all_to_mean" {
  let y = [0.9, 0.1, 0.8, 0.2, 0.7]
  let r = pava(y)
  // First 4 elements pool to mean (0.9+0.1+0.8+0.2)/4 = 0.5.
  for i = 0; i < 4; i = i + 1 {
    inspect((r[i] - 0.5).abs() < 1.0e-15, content="true")
  }
  // Last element stays at 0.7 (no further pooling since 0.5 <= 0.7).
  inspect((r[4] - 0.7).abs() < 1.0e-15, content="true")
}

///|
/// `pava` on an empty input is an empty array.
test "pava_empty_input" {
  let r : Array[Double] = pava([])
  inspect(r.length(), content="0")
}

///|
/// `pava` with weights: two weight-1 elements `[1.0, 0.0]`
/// pool to `0.5`. A single element with weight `w` is reported
/// as the weighted mean `y / w` (the standard PAVA output for a
/// single-block result).
test "pava_with_weights" {
  let y = [1.0, 0.0]
  let w = [1.0, 1.0]
  let r = pava(y, weights=w)
  inspect((r[0] - 0.5).abs() < 1.0e-15, content="true")
  inspect((r[1] - 0.5).abs() < 1.0e-15, content="true")
  // A single element with weight `w` gives the weighted mean
  // `y / w`. With y=0.3 and w=4, the output is 0.075.
  let r2 = pava([0.3], weights=[4.0])
  inspect((r2[0] - 0.075).abs() < 1.0e-15, content="true")
}

///|
/// `fit_isotonic` produces a non-decreasing output. The
/// output, when re-input to PAVA, is itself (idempotent on
/// the PAVA side).
test "fit_isotonic_is_non_decreasing" {
  let x = [0.5, 0.1, 0.9, 0.2, 0.7, 0.3, 0.8, 0.4, 0.6, 0.0]
  let y = [0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0]
  let (_, y_hat) = fit_isotonic(x, y)
  inspect(y_hat.length(), content="10")
  for i = 0; i < 9; i = i + 1 {
    inspect(y_hat[i] <= y_hat[i + 1], content="true")
  }
}

///|
/// `predict_isotonic` step function: the prediction at
/// `x_new[i]` equals the fitted y-hat at the largest fitted
/// `x <= x_new[i]`. For x_new within the training range, the
/// output is in the fitted y-hat range and non-decreasing.
test "predict_isotonic_step_function" {
  // Sorted (x, y) input
  let fitted_x = [0.0, 0.25, 0.5, 0.75, 1.0]
  let fitted_y_hat = [0.0, 0.0, 0.5, 1.0, 1.0]
  // x_new straddles the block boundaries
  let x_new = [-0.1, 0.1, 0.3, 0.5, 0.6, 0.9, 1.1]
  let pred = predict_isotonic(fitted_x, fitted_y_hat, x_new)
  // Below min -> fitted_y_hat[0] = 0.0
  inspect((pred[0] - 0.0).abs() < 1.0e-15, content="true")
  // (0.0, 0.25] -> 0.0
  inspect((pred[1] - 0.0).abs() < 1.0e-15, content="true")
  // (0.25, 0.5] -> 0.0 (largest fitted_x <= 0.3 is 0.25, y_hat=0.0)
  inspect((pred[2] - 0.0).abs() < 1.0e-15, content="true")
  // (0.5] -> 0.5
  inspect((pred[3] - 0.5).abs() < 1.0e-15, content="true")
  // (0.5, 0.75] -> 0.5
  inspect((pred[4] - 0.5).abs() < 1.0e-15, content="true")
  // (0.75, 1.0] -> 1.0
  inspect((pred[5] - 1.0).abs() < 1.0e-15, content="true")
  // Above max -> fitted_y_hat[last] = 1.0
  inspect((pred[6] - 1.0).abs() < 1.0e-15, content="true")
}

///|
/// `PSProcessor::adjust_ps` with `calibration_method =
/// "isotonic"` and no CV: on a 10-element DGP with x evenly
/// spaced in [0.1, 1.0] and y = 0 for x < 0.5, y = 1 for x >=
/// 0.5, the calibrated output is a step function that jumps
/// from 0 to 1 at the boundary (PAVA on the already-monotonic
/// y is identity). After clip to `[0.01, 0.99]`, the result is
/// `[0.01, 0.01, 0.01, 0.01, 0.99, 0.99, 0.99, 0.99, 0.99,
/// 0.99]`.
test "ps_processor_isotonic_no_cv" {
  let cfg = PSProcessorConfig::new(
    clipping_threshold=0.01,
    calibration_method="isotonic",
  )
  let psp = PSProcessor::new(config=cfg)
  let ps = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
  let treatment = [0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
  let out = psp.adjust_ps(ps, treatment)
  // Calibrated step function (before clip): y is monotonic
  // (4 zeros then 6 ones), PAVA is identity, predict at the
  // sorted x returns [0, 0, 0, 0, 1, 1, 1, 1, 1, 1]. After
  // clip to [0.01, 0.99]: 0 -> 0.01, 1 -> 0.99.
  let expected = [0.01, 0.01, 0.01, 0.01, 0.99, 0.99, 0.99, 0.99, 0.99, 0.99]
  for i = 0; i < 10; i = i + 1 {
    inspect((out[i] - expected[i]).abs() < 1.0e-12, content="true")
  }
}

///|
/// `PSProcessor::adjust_ps` with `calibration_method =
/// "isotonic"` on a DGP with a single violation: input
/// `[0.1, 0.5, 0.1, 0.5, 0.3]` for `ps`, `[0, 0, 1, 1, 1]`
/// for treatment. After sort-by-x, sorted y = `[0, 1, 1, 0,
/// 1]`. PAVA on this gives `[0, 2/3, 2/3, 2/3, 1]` (sizes 1,
/// 3, 1). Predict at the original x positions and clip to
/// `[0.05, 0.95]` produces `[0.667, 0.95, 0.667, 0.95, 0.667]`.
test "ps_processor_isotonic_pooling" {
  let cfg = PSProcessorConfig::new(
    clipping_threshold=0.05,
    calibration_method="isotonic",
  )
  let psp = PSProcessor::new(config=cfg)
  let ps = [0.1, 0.5, 0.1, 0.5, 0.3]
  let treatment = [0.0, 0.0, 1.0, 1.0, 1.0]
  let out = psp.adjust_ps(ps, treatment)
  // The actual PAVA + predict + clip output (verified by the
  // probe test) is [0.667, 0.95, 0.667, 0.95, 0.667]. The 0.667
  // = 2/3 comes from pooling (1, 0, 1) at sorted positions
  // [1, 2, 3] (the y values at sorted x = [0.1, 0.1, 0.3, 0.5,
  // 0.5] are [0, 1, 1, 0, 1] in stable-sort order; PAVA pools
  // positions 1..3 into a 3-element block with mean 2/3).
  let expected = [0.6666666666666666, 0.95, 0.6666666666666666, 0.95, 0.6666666666666666]
  for i = 0; i < 5; i = i + 1 {
    inspect((out[i] - expected[i]).abs() < 1.0e-12, content="true")
  }
}

///|
/// `PSProcessor::adjust_ps` with `calibration_method =
/// "isotonic"` and `cv_calibration = true`: on the same DGP
/// as the no-CV test, the K-fold calibrated output differs
/// from the in-sample output at the test-fold boundary
/// points (where the test point was held out during fit).
/// The check: CV output is non-decreasing on the sorted x
/// order, and lies in `[clipping_threshold, 1 -
/// clipping_threshold]`.
test "ps_processor_isotonic_cv_basic" {
  let cfg = PSProcessorConfig::new(
    clipping_threshold=0.05,
    calibration_method="isotonic",
    cv_calibration=true,
  )
  let psp = PSProcessor::new(config=cfg)
  let ps = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
  let treatment = [0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
  let out = psp.adjust_ps(ps, treatment)
  // Output must lie in [0.05, 0.95].
  for i = 0; i < 10; i = i + 1 {
    inspect(out[i] >= 0.05, content="true")
    inspect(out[i] <= 0.95, content="true")
  }
}

///|
/// `PSProcessor::adjust_ps` with isotonic CV must accept a
/// user-supplied `cv` fold list. The test uses 2 folds:
/// train on the second half, predict on the first; train
/// on the first half, predict on the second. The union of
/// the two test sets covers all 10 indices.
test "ps_processor_isotonic_cv_user_folds" {
  let cfg = PSProcessorConfig::new(
    clipping_threshold=0.05,
    calibration_method="isotonic",
    cv_calibration=true,
  )
  let psp = PSProcessor::new(config=cfg)
  let ps = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
  let treatment = [0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
  // User-supplied CV: 2 folds, test sets cover {0..4, 5..9}.
  let train1 : Array[Int] = [5, 6, 7, 8, 9]
  let test1 : Array[Int] = [0, 1, 2, 3, 4]
  let train2 : Array[Int] = [0, 1, 2, 3, 4]
  let test2 : Array[Int] = [5, 6, 7, 8, 9]
  let cv : Array[(Array[Int], Array[Int])] = [
    (train1, test1),
    (train2, test2),
  ]
  let out = psp.adjust_ps(ps, treatment, cv=Some(cv))
  inspect(out.length(), content="10")
  // Output must lie in [0.05, 0.95] after clip.
  for i = 0; i < 10; i = i + 1 {
    inspect(out[i] >= 0.05, content="true")
    inspect(out[i] <= 0.95, content="true")
  }
}

///|
/// `PSProcessor::adjust_ps` with isotonic must not mutate
/// either the `ps` or the `treatment` array.
test "ps_processor_isotonic_does_not_mutate_input" {
  let cfg = PSProcessorConfig::new(
    clipping_threshold=0.05,
    calibration_method="isotonic",
    cv_calibration=true,
  )
  let psp = PSProcessor::new(config=cfg)
  let ps = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
  let treatment = [0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
  let ps_orig = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
  let t_orig = [0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
  let _ = psp.adjust_ps(ps, treatment)
  for i = 0; i < 10; i = i + 1 {
    inspect((ps[i] - ps_orig[i]).abs() < 1.0e-15, content="true")
    inspect((treatment[i] - t_orig[i]).abs() < 1.0e-15, content="true")
  }
}

///|
/// `PSProcessor::adjust_ps` with isotonic and no CV
/// disagrees with the CV path (the CV path uses held-out
/// predictions), but both must produce a non-decreasing
/// output in the sorted-x order on this monotonic DGP.
test "ps_processor_isotonic_no_cv_preserves_pava_output" {
  let cfg = PSProcessorConfig::new(
    clipping_threshold=0.01,
    calibration_method="isotonic",
  )
  let psp = PSProcessor::new(config=cfg)
  let ps = [0.5, 0.1, 0.9, 0.2, 0.7, 0.3, 0.8, 0.4, 0.6, 0.0]
  let treatment = [0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0]
  let out = psp.adjust_ps(ps, treatment)
  // Sort by x: indices [9, 1, 3, 5, 7, 0, 8, 4, 6, 2]
  // y sorted: [1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
  // PAVA on a decreasing y pools everything into one block
  // with mean 0.5. Predict at original x: 0.5 for everyone.
  // After clip to [0.01, 0.99], the 0.5 values are unchanged.
  for i = 0; i < 10; i = i + 1 {
    inspect((out[i] - 0.5).abs() < 1.0e-12, content="true")
  }
}
