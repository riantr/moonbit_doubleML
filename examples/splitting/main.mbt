// examples/splitting -- the fail-closed half of the v0.109.0 sample-splitting
// gate.
//
// The in-process tests in `expand_v109_test.mbt` can only assert the
// ACCEPTED paths: a refusal is an `abort`, and an abort inside a test kills
// the whole test binary, taking every other test's result with it and making
// the failure unattributable. So the refusals are proven here, where a
// non-zero exit is a clean, attributable outcome.
//
//   moon run examples/splitting --target native -- <mode>
//
//   ok         legal 3-fold partition, two reps  -> exit 0, prints derived counts
//   overlap    two folds re-test the same rows   -> must abort (sets not disjoint)
//   short      the test sets miss a row          -> must abort (not a cover)
//   ragged     rep 0 has 3 folds, rep 1 has 2     -> must abort (inconsistent count)
//   outofrange a test index >= n_obs              -> must abort
//   empty      an empty repetition                -> must abort
//
// Driven by `validate_splitting_contract.py`, which requires mode `ok` to
// succeed AND every other mode to fail. A validator that only ran the happy
// path would pass against a `check_sample_splitting` that validated nothing.

///|
fn idx_range(lo : Int, hi : Int) -> Array[Int] {
  let out = Array::make(hi - lo, 0)
  for i = 0; i < hi - lo; i = i + 1 {
    out[i] = lo + i
  }
  out
}

///|
fn build_data(n : Int, p : Int, seed : Int) -> @moonbit_doubleML.DoubleMLData {
  let rng = @moonbit_doubleML.chacha8_rng(seed)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double() * 2.0 - 1.0
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    y[i] = 1.5 * d[i] +
      3.0 * x_flat[i * p + 0] +
      0.1 * (rng.double() - 0.5) * 2.0
  }
  let x = @moonbit_doubleML.Matrix::from_array(x_flat, n, p)
  @moonbit_doubleML.DoubleMLData::new(x, y, d)
}

///|
fn main {
  let args = @env.args()
  let mode = if args.length() > 1 { args[1] } else { "ok" }
  let n = 200
  let data = build_data(n, 2, 7)

  // Two legal 3-fold partitions of [0, 200).
  let good = @moonbit_doubleML.kfold(n, 3, 7)
  let good2 = @moonbit_doubleML.kfold(n, 3, 8)

  let smpls = match mode {
    "ok" => [good, good2]
    // rep 0's last two folds both test rows 0..4
    "overlap" =>
      [
        [
          good[0],
          good[1],
          @moonbit_doubleML.Fold::new([10, 11, 12], [0, 1, 2, 3, 4]),
        ],
      ]
    // DISJOINTNESS IN ISOLATION. Two folds whose test sets overlap on
    // rows 60..119 but whose union is still all of [0, 200).
    //
    // The first version of this harness shipped only `overlap`, whose
    // folds ALSO left rows untested -- so it was caught by the coverage
    // check even with the disjointness `require` deleted, and mutation
    // M3 survived. An input has to violate exactly ONE property to
    // pin that property.
    "overlapcover" =>
      [
        [
          @moonbit_doubleML.Fold::new(idx_range(120, 200), idx_range(0, 120)),
          @moonbit_doubleML.Fold::new(idx_range(0, 60), idx_range(60, 200)),
        ],
      ]
    // three folds covering rows 0..149 only; 150..199 is never tested,
    // so the test sets are not a cover
    "short" =>
      [
        [
          @moonbit_doubleML.Fold::new(idx_range(50, 200), idx_range(0, 50)),
          @moonbit_doubleML.Fold::new(idx_range(0, 50), idx_range(50, 100)),
          @moonbit_doubleML.Fold::new(idx_range(50, 100), idx_range(100, 150)),
        ],
      ]
    // rep 0 has 3 folds, rep 1 has 2
    "ragged" => [[good[0], good[1], good[2]], [good2[0], good2[1]]]
    // a test index past the end of the sample
    "outofrange" => [[@moonbit_doubleML.Fold::new([0], [999])]]
    "empty" => [[]]
    _ => abort("unknown mode: " + mode)
  }

  // Constructed as 9 folds / 7 reps on purpose: the supplied splitting is
  // 3 folds / 2 reps, so if the derivation did not take effect the model
  // would report 9 and 7.
  let model = @moonbit_doubleML.DoubleMLPLR::new(
    data,
    n_folds=9,
    n_rep=7,
    seed=7,
  ).set_sample_splitting(smpls)
  match model.sample_splitting() {
    None => abort("set_sample_splitting did not record the splitting")
    Some(ss) => {
      println("splitting folds=" + ss.folds.to_string())
      println("splitting reps=" + ss.reps.to_string())
    }
  }
  let fitted = model.fit()
  println("splitting coef=" + fitted.coef().to_string())
  println("splitting se=" + fitted.se().to_string())
}
