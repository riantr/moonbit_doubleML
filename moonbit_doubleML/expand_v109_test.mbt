// v0.109.0 -- the sample-splitting gate.
//
// # The contract, and why the obvious test cannot check it
//
// Upstream `set_sample_splitting` (`double_ml_sampling_mixins.py:76`)
// derives BOTH counts from the supplied partition, so a two-fold split
// handed to a model built with `n_folds=5` yields a two-fold model.
// The tempting test -- "supply some folds, get a finite coefficient" --
// checks none of that, and it is the shape the v0.65.0 `tune` tests had:
// it cannot distinguish a supplied splitting that was used from one that
// was stored and ignored.
//
// # The gate is an equivalence identity, not a band
//
// Supplying the folds `kfold(n, k, seed)` itself returns must reproduce
// the estimator's own draw BIT-IDENTICALLY. There is no sampling
// involved on either side, so the tolerance is `==` on the coefficient
// and the standard error, not a 1/sqrt(n) margin.
//
//   * ignore the supplied folds  -> the estimate drifts off the identity
//   * honour them but use `self.n_rep` instead of the derived count
//                                -> identity breaks on the multi-rep case
//   * skip `check_sample_splitting` -> the non-partition test accepts
//
// and with the grid ordered so the DERIVED counts differ from the
// configured ones, a `set_sample_splitting` that forgot to update
// `n_folds` / `n_rep` fails too.
//
// # Staleness is its own gate
//
// The fit cache is keyed on data + learner + cluster hashes and has no
// fold-assignment term. The external path therefore turns memoize off.
// `v109_memoize_cannot_serve_a_stale_split` pins that: an external
// re-fit under a DIFFERENT partition must equal a fresh model fit under
// that same partition, which a cache hit could not achieve.

// ---------------------------------------------------------------------------
// DGP — private to this file (MoonBit `fn` is file-scoped)
// ---------------------------------------------------------------------------

///|
/// `y = 3.0*x0 + 0.1*u`, d Bernoulli. Linear and well-conditioned, so a
/// coefficient is a meaningful thing to compare bit-for-bit.
fn v109_plr_data(n : Int, p : Int, seed : Int) -> (DoubleMLData, Int) {
  let rng = chacha8_rng(seed)
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
  (DoubleMLData::new(Matrix::from_array(x_flat, n, p), y, d), seed)
}

///|
/// The exact folds the estimator's own draw would produce for `n_rep`
/// repetitions at `n_folds` folds, given the estimator's `seed`.
fn v109_drawn_reps(
  n : Int,
  n_folds : Int,
  n_rep : Int,
  seed : Int,
) -> Array[Array[Fold]] {
  let out : Array[Array[Fold]] = []
  for r = 0; r < n_rep; r = r + 1 {
    out.push(kfold(n, n_folds, seed + r))
  }
  out
}

// ---------------------------------------------------------------------------
// gate 1: equivalence -- supplying the drawn folds reproduces the draw
// ---------------------------------------------------------------------------

///|
test "v109_supplying_drawn_folds_reproduces_the_draw_exactly" {
  let n = 300
  let (data, _s) = v109_plr_data(n, 2, 7)
  // two repetitions, so the identity also covers the `seed + r` offset
  let base = DoubleMLPLR::new(data, n_folds=4, n_rep=2, seed=7).fit()
  let supplied = DoubleMLPLR::new(data, n_folds=4, n_rep=2, seed=7)
    .set_sample_splitting(v109_drawn_reps(n, 4, 2, 7))
    .fit()
  // bit-identical, not "close": both sides run the same arithmetic on
  // the same folds, so any drift means a different code path ran.
  assert_true(supplied.coef() == base.coef())
  assert_true(supplied.se() == base.se())
  assert_true(supplied.predictions_l() == base.predictions_l())
}

// ---------------------------------------------------------------------------
// gate 2: the counts are DERIVED, overriding the configured ones
// ---------------------------------------------------------------------------

///|
/// The identity above uses a model whose CONFIGURED counts already equal
/// the supplied ones, so it cannot tell "honoured the derived repetition
/// count" from "ignored the supplied folds and drew its own" -- under
/// that mutation both sides coincidentally draw the same folds and the
/// identity still holds. Measured: mutation M1 (fit always draws) was
/// caught by exactly ONE test, and not this one.
///
/// So the derivation needs its own identity, with the counts
/// deliberately mismatched: configured as ONE repetition, supplied as
/// TWO. If `fit` still ran `self.n_rep` times it would aggregate over
/// one repetition and the coefficient would differ from the two-rep
/// reference; only a fit that honours the DERIVED count reproduces it.
test "v109_derived_reps_drive_the_fit_not_the_configured_ones" {
  let n = 300
  let (data, _s) = v109_plr_data(n, 2, 41)
  // reference: configured 2 reps, drawn as usual
  let base = DoubleMLPLR::new(data, n_folds=3, n_rep=2, seed=41).fit()
  // configured 1 rep, supplied the same two repetitions
  let supplied = DoubleMLPLR::new(data, n_folds=3, n_rep=1, seed=41)
    .set_sample_splitting(v109_drawn_reps(n, 3, 2, 41))
    .fit()
  assert_true(supplied.coef() == base.coef())
  assert_true(supplied.se() == base.se())
}

///|
/// And the derivation is readable, not merely observable through the
/// estimate. A `set_sample_splitting` that stored the folds and left the
/// configured counts alone would still fail the test above, so this one
/// exists to attribute the failure to the right place.
test "v109_counts_are_derived_from_the_supplied_partition" {
  let n = 300
  let (data, _s) = v109_plr_data(n, 2, 11)
  // configured as 5 folds / 1 rep, supplied as 3 folds / 2 reps
  let m = DoubleMLPLR::new(data, n_folds=5, n_rep=1, seed=11).set_sample_splitting(
    v109_drawn_reps(n, 3, 2, 11),
  )
  match m.sample_splitting() {
    None => assert_true(false)
    Some(ss) => {
      assert_true(ss.folds == 3)
      assert_true(ss.reps == 2)
    }
  }
  // and the derived counts are what the model actually reports
  assert_true(m.n_obs() == n)
  let fitted = m.fit()
  assert_true(fitted.coef().is_nan() == false)
}

///|
test "v109_no_supplied_splitting_reads_back_as_none" {
  let (data, _s) = v109_plr_data(200, 2, 12)
  let m = DoubleMLPLR::new(data, n_folds=4, seed=12)
  match m.sample_splitting() {
    None => ()
    Some(_) => assert_true(false)
  }
}

// ---------------------------------------------------------------------------
// gate 3: a non-partition is rejected, not silently accepted
// ---------------------------------------------------------------------------

///|
/// A non-partition must be REFUSED. Refusal is an `abort`, and an abort
/// inside a test kills the whole test binary -- which would take the
/// other 800-odd tests' results down with it and make the failure
/// unattributable (the reason v0.108.0's gate is written with
/// `assert_true` rather than `abort`). So the refusal is proven out of
/// process instead: `validate_splitting_contract.py` runs
/// `examples/splitting` on a deliberately broken partition and requires
/// a non-zero exit. A negative test that cannot run in-process is a
/// real limitation of the harness, not a reason to fake the assertion
/// in here.
test "v109_valid_partition_is_accepted_and_derived" {
  let n = 100
  let folds = kfold(n, 4, 5)
  let ss = check_sample_splitting([folds], n)
  assert_true(ss.folds == 4)
  assert_true(ss.reps == 1)
}

///|
/// The single-fold "no sample splitting" partition: train and test both
/// cover everything. Upstream detects this case explicitly and reports
/// `n_folds = 1`; the generic rules must reach the same answer.
test "v109_single_fold_full_coverage_is_accepted" {
  let n = 50
  let all = range_indices(n)
  let f = Fold::new(all.copy(), all.copy())
  let ss = check_sample_splitting([[f]], n)
  assert_true(ss.folds == 1)
  assert_true(ss.reps == 1)
}

///|
/// Two repetitions of the same shape are two independent partitions, so
/// a row may be tested in both. `check_sample_splitting` allocates its
/// coverage marker PER repetition; sharing it across reps would reject
/// every legal repeated splitting.
test "v109_repeated_splitting_allows_a_row_tested_in_each_rep" {
  let n = 60
  let a = kfold(n, 3, 1)
  let b = kfold(n, 3, 2)
  let ss = check_sample_splitting([a, b], n)
  assert_true(ss.folds == 3)
  assert_true(ss.reps == 2)
}

// ---------------------------------------------------------------------------
// gate 4: the supplied folds are USED, not merely stored
// ---------------------------------------------------------------------------

///|
/// The complement of gate 1. A different partition must move the
/// estimate; if it does not, the splitting is being stored and ignored.
test "v109_a_different_partition_changes_the_estimate" {
  let n = 300
  let (data, _s) = v109_plr_data(n, 2, 21)
  let a = DoubleMLPLR::new(data, n_folds=4, n_rep=2, seed=21)
    .set_sample_splitting(v109_drawn_reps(n, 4, 2, 21))
    .fit()
  let b = DoubleMLPLR::new(data, n_folds=4, n_rep=2, seed=21)
    .set_sample_splitting(v109_drawn_reps(n, 4, 2, 999))
    .fit()
  assert_true(a.coef() != b.coef())
}

// ---------------------------------------------------------------------------
// gate 6: the shapes that differ from PLR
//
// The other eleven estimators route through the same shared core, so
// their selection logic is PLR's. What is NOT shared is the plumbing, and
// two of those shapes are distinctive enough to pin:
//   APOS  propagates the splitting DOWN to a child `DoubleMLAPO` per
//         treatment level, because it cross-fits nothing itself. A setter
//         that merely recorded the folds on the parent would be inert
//         -- precisely the v0.65.0 `tune` shape.
//   PQ    has no `n_rep` at all, so there is no repetition count to
//         derive and `fit` consumes `smpls[0]` directly.
// ---------------------------------------------------------------------------

///|
/// APOS: supplying a splitting must give each treatment level the SAME
/// coefficient a standalone `DoubleMLAPO` gets from that splitting. That
/// is an exact per-level identity, so it fails if the propagation is
/// dropped, if it reaches only the first child, or if the levels
/// silently get different partitions.

///|
/// APOS must PROPAGATE the splitting to each child `DoubleMLAPO`, because
/// it cross-fits nothing itself. A setter that recorded the folds on the
/// parent and returned would be inert -- the v0.65.0 `tune` shape.
///
/// Two assertions, and the pairing matters.
///
/// (a) per-level equality: each level's coefficient equals what a
///     standalone `DoubleMLAPO` gets from the SAME splitting.
///
/// (b) seed sensitivity: two APOS fits given the same SHAPE of splitting
///     but different seeds must differ. Without (b) this test is
///     vacuous, and it was: the first version compared a 4-fold/1-rep
///     supplied partition against the drawn 9-fold/3-rep one, and
///     dropping the propagation changed nothing, because under the
///     near-linear DGP the PLR/APO estimate is invariant to the fold
///     COUNT and the repetition COUNT to within double precision. A
///     fold-count change is therefore a poor discriminator here; a
///     partition SEED is not, and that is what the PLR gate above
///     already relies on.
test "v109_apos_propagates_the_splitting_to_every_child" {
  let n = 300
  let (data, _s) = v109_plr_data(n, 2, 51)
  let levels = [1.0]
  let part_a = [@moonbit_doubleML.kfold(n, 4, 51)]
  let part_b = [@moonbit_doubleML.kfold(n, 4, 52)]
  let aos_a = @moonbit_doubleML.DoubleMLAPOS::new(
      data,
      levels,
      n_folds=9,
      n_rep=3,
      seed=51,
    )
    .set_sample_splitting(part_a)
    .fit()
  let aos_b = @moonbit_doubleML.DoubleMLAPOS::new(
      data,
      levels,
      n_folds=9,
      n_rep=3,
      seed=51,
    )
    .set_sample_splitting(part_b)
    .fit()
  // (b) the supplied partition reaches the children: a different seed
  // must move the estimate. With the propagation dropped, both fits
  // would draw the same 9-fold/3-rep partition and coincide.
  assert_true(aos_a.coefs()[0] != aos_b.coefs()[0])
  // (a) and each level matches a standalone fit on the same splitting
  for j = 0; j < levels.length(); j = j + 1 {
    let single = @moonbit_doubleML.DoubleMLAPO::new(
        data,
        treatment_level=levels[j],
        n_folds=9,
        n_rep=3,
        seed=51,
      )
      .set_sample_splitting(part_a)
      .fit()
    assert_true(aos_a.coefs()[j] == single.coef())
    assert_true(aos_a.ses()[j] == single.se())
  }
}

///|
/// PQ has no `n_rep`, so there is no repetition count to derive. What
/// must still hold is that the supplied folds are the ones used, and the
/// proof is the same equivalence identity as for PLR: the supplied
/// partition is the deterministic draw, so the two must agree bit for
/// bit.
test "v109_pq_uses_a_supplied_single_repetition_partition" {
  let n = 300
  let (data, _s) = v109_plr_data(n, 2, 61)
  let part = @moonbit_doubleML.kfold(n, 4, 61)
  let base = @moonbit_doubleML.DoubleMLPQ::new(
    data,
    treatment=1.0,
    n_folds=4,
    seed=61,
  ).fit()
  let supplied = @moonbit_doubleML.DoubleMLPQ::new(
      data,
      treatment=1.0,
      n_folds=9,
      seed=61,
    )
    .set_sample_splitting([part])
    .fit()
  assert_true(supplied.coef() == base.coef())
  assert_true(supplied.se() == base.se())
  // and the derived fold count replaced the configured 9
  match supplied.sample_splitting() {
    None => assert_true(false)
    Some(ss) => assert_true(ss.folds == 4)
  }
}

// ---------------------------------------------------------------------------
// gate 5: memoize cannot serve a stale split
// ---------------------------------------------------------------------------

///|
/// Enable memoize, fit under partition A, then supply partition B and
/// re-fit. The result must equal a FRESH model (memoize never enabled)
/// fitted under B. A cache entry written under A has no fold term in its
/// key, so if the external path did not switch memoize off this would
/// return A's numbers and fail.
test "v109_memoize_cannot_serve_a_stale_split" {
  let n = 300
  let (data, _s) = v109_plr_data(n, 2, 31)
  let part_a = v109_drawn_reps(n, 4, 1, 31)
  let part_b = v109_drawn_reps(n, 4, 1, 777)
  let warm = DoubleMLPLR::new(data, n_folds=4, n_rep=1, seed=31)
    .enable_memoize()
    .set_sample_splitting(part_a)
    .fit()
  let warm_again = warm.set_sample_splitting(part_b).fit()
  let cold = DoubleMLPLR::new(data, n_folds=4, n_rep=1, seed=31)
    .set_sample_splitting(part_b)
    .fit()
  assert_true(warm_again.coef() == cold.coef())
  assert_true(warm_again.se() == cold.se())
  // The staleness guarantee is not "the cache got the right key" -- it
  // is that an externally-split fit never touches the cache at all, so
  // no entry exists to be stale. Assert THAT, since it is the property
  // the design actually provides.
  //
  // This assertion was originally `assert_true(warm.has_cache())`,
  // written to prove memoize had really been switched on. It failed,
  // and correctly: `set_sample_splitting` clears the cache and the
  // external path sets `memoize = ... && !external`, so a warm fit
  // under supplied folds populates nothing. An assertion that asserts
  // the opposite of the design is worse than no assertion.
  assert_true(warm.has_cache() == false)
  assert_true(warm_again.has_cache() == false)
}
