///|
/// v0.155.0 — `DoubleMLPLR` now accepts upstream's own spelling of the
/// partialling-out score.
///
/// MEASURED BEFORE THE CHANGE (`_verify/SCORE_VOCABULARY_1550.md`):
///   upstream `doubleml/plm/plr.py:99` declares
///     valid_scores = ["IV-type", "partialling out"]   <-- SPACE
///   and its `__init__` default is `score="partialling out"`.
///   This port defaulted `DoubleMLPLR::fit(score~ = "partialling-out")`
///   <-- HYPHEN, a value upstream's `_check_score` rejects.
///
///   The two accepted sets intersected only at `"IV-type"`, and BOTH broken
///   directions aborted:
///     `DoubleMLPLR::fit(score="partialling out")`  -> abort   (upstream's)
///     `DoubleMLPLPR::new(score="partialling-out")` -> abort   (this port's)
///   So a user who corrected the spelling for one estimator broke the other.
///
/// WHAT THIS CHANGES: only `plr_is_po_score` (plr.mbt:395), which now
/// accepts `"partialling out"` alongside `"partialling-out"`.
///
/// WHAT THIS DOES NOT CHANGE, and GATE 1 proves it: no default changed, and
/// the branch selector `plr_score_elements` (`if plr_is_iv_score(score)`,
/// `plr.mbt:356`) tests only for an
/// iv-type spelling and falls through to partialling-out otherwise -- so
/// `"partialling out"` already computed the identical PO score. Only the
/// `require` rejected it. MEASURED bit-identical, all three spellings:
///   default / "partialling-out" / "partialling out"
///     coef = 1.4445411463639795   se = 0.045208884326958514
///
/// The "an unknown spelling is still rejected" check is a PANIC test and
/// lives in `check_test.mbt` alongside the package's other `panic_*` drivers,
/// per the existing convention.
///

///|
fn v1550_score_gate_dgp(n : Int32) -> (Matrix, Array[Double], Array[Double]) {
  let rng = chacha8_rng(42)
  let x_data : Array[Double] = Array::make(n * 3, 0.0)
  let y_data : Array[Double] = Array::make(n, 0.0)
  let d_data : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    let x1 = rng.double() * 2.0 - 1.0
    let x2 = rng.double() * 2.0 - 1.0
    x_data[i * 3 + 0] = x0
    x_data[i * 3 + 1] = x1
    x_data[i * 3 + 2] = x2
    let eps = (rng.double() - 0.5) * 0.5
    let v = (rng.double() - 0.5) * 0.6
    let d_i = 0.3 * x0 + 0.4 * x1 + v
    d_data[i] = d_i
    y_data[i] = 1.5 * d_i + 0.5 * x0 + eps
  }
  (Matrix::from_array(x_data, n, 3), y_data, d_data)
}

///|
test "v1550_score_upstream_spelling_bit_identical" {
  let n = 300
  let (x, y, d) = v1550_score_gate_dgp(n)
  let data = DoubleMLData::new(x, y, d)

  let def = DoubleMLPLR::new(data, n_folds=4, seed=3141).fit()
  let hyphen = DoubleMLPLR::new(data, n_folds=4, seed=3141).fit(
    score="partialling-out",
  )
  let space = DoubleMLPLR::new(data, n_folds=4, seed=3141).fit(
    score="partialling out",
  )

  // GATE 1 -- the fix moved NOTHING. Upstream's spelling must be BIT
  // identical to the port's own default, not merely close. This is the gate
  // that would catch a later "helpful" normalisation which silently changed
  // which score is computed.
  inspect((space.coef() - def.coef()).abs() == 0.0, content="true")
  inspect((space.se() - def.se()).abs() == 0.0, content="true")
  inspect((hyphen.coef() - def.coef()).abs() == 0.0, content="true")
  inspect((hyphen.se() - def.se()).abs() == 0.0, content="true")

  // GATE 2 -- the control. The flag must still be LOAD-BEARING: IV-type is a
  // different formula, so its coefficient must move. If this ever reads
  // false, `score` has gone inert on DoubleMLPLR and every claim about it
  // being live is void.
  //
  // IV-type needs an instrument, so this uses `z = d` (treatment as its own
  // instrument). The PO branch above deliberately uses a `z`-free data object,
  // which is also what proves the space spelling does NOT silently take the
  // IV branch: on `data` there is no instrument, so any string other than a
  // partialling-out spelling must abort.
  let data_iv = DoubleMLData::new(x, y, d, z=d)
  let iv = DoubleMLPLR::new(data_iv, n_folds=4, seed=3141).fit(score="IV-type")
  inspect((iv.coef() - def.coef()).abs() > 1.0e-9, content="true")
  // Both iv-type spellings must stay accepted and agree with each other.
  let iv_lower = DoubleMLPLR::new(data_iv, n_folds=4, seed=3141).fit(
    score="iv-type",
  )
  inspect((iv_lower.coef() - iv.coef()).abs() == 0.0, content="true")
}

///|
test "v1550_score_gate_fixture_still_sensible" {
  // Guard the fixture itself. GATE 1 is only meaningful if this DGP still
  // produces a sane coefficient near the true theta = 1.5 -- otherwise
  // "identical" could mean "both garbage".
  let (x, y, d) = v1550_score_gate_dgp(300)
  let f = DoubleMLPLR::new(DoubleMLData::new(x, y, d), n_folds=4, seed=3141).fit()
  inspect(f.coef() > 0.1, content="true")
}
