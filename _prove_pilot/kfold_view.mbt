// kfold_view.mbt -- proof-only view of the kfold Fold type.
//
// This file mirrors the contract shape from the main package's
// kfold.mbt (Fold::new, build_row_unit_map) using FixedArray so
// the proof pipeline can reason about the elements. The full
// kfold_from_perm is omitted from the contracted set because the
// MoonBit proof pipeline currently rejects `FixedArray::make` over
// a struct type that contains FixedArray fields (the Why3 "pure
// type variable" check) -- this is a toolchain-side limitation,
// not a contract authoring issue.

///|
/// Proof-side view of the main package's `Fold` struct. Same shape,
/// but uses `FixedArray[Int]` so the proof side can talk about
/// element-wise disjointness and bounds.
pub struct FoldView {
  train_idx : FixedArray[Int]
  test_idx : FixedArray[Int]
} derive(Debug)

///|
/// Fold::new equivalent: build a fold from explicit train/test index
/// arrays. Preconditions: the test side is non-empty, train and test
/// are element-wise disjoint (a fold never puts the same row on both
/// sides), and train+test have at least one index total. Postcondition:
/// the resulting fold preserves lengths, and the two sides are disjoint.
///
/// Note on disjointness: the constructor is a no-op `{ train_idx, test_idx }`,
/// so disjointness cannot be enforced at runtime. The postcondition
/// `arr_disjoint(result.train_idx, result.test_idx)` therefore depends
/// on the precondition `arr_disjoint(train_idx, test_idx)` to be sound.
pub fn FoldView::new(
  train_idx : FixedArray[Int],
  test_idx : FixedArray[Int],
) -> FoldView where {
  proof_require: test_idx.length() > 0,
  proof_require: train_idx.length() + test_idx.length() > 0,
  proof_require: arr_disjoint(train_idx, test_idx),
  proof_ensure: result => fold_view_new_ok(result, train_idx, test_idx),
} {
  { train_idx, test_idx, }
}

///|
/// kfold equivalent (shape only): produce an array of n_folds folds,
/// each carrying the (train, test) split. We don't reproduce the
/// random shuffle; instead we accept the perm array as input so the
/// postcondition is the structural partition property derived from
/// the algorithm shape. The contract expresses the properties the
/// real `kfold` function should satisfy (modulo the random shuffle,
/// which the prover cannot model anyway).
///
/// NOTE: This function is intentionally NOT marked `where { ... }`
/// because `FixedArray[FoldView]` triggers the Why3 "pure type
/// variable" check (FoldView contains FixedArray fields). The
/// runtime behaviour is exercised by `kfold_from_perm_basic` /
/// `kfold_from_perm_uneven` below; once the toolchain permits, a
/// `where { proof_ensure: result => kfold_view_post(result, n_obs, n_folds) }`
/// block should be added.
pub fn kfold_from_perm(
  perm : FixedArray[Int],
  n_obs : Int,
  n_folds : Int,
) -> FixedArray[FoldView] {
  let base = n_obs / n_folds
  let rem = n_obs - base * n_folds
  let out : FixedArray[FoldView] = FixedArray::make(n_folds, {
    train_idx: FixedArray::make(0, 0),
    test_idx: FixedArray::make(0, 0),
  })
  let mut offset = 0
  for f = 0; f < n_folds; f = f + 1 {
    let test_size = if f < rem { base + 1 } else { base }
    let test_idx : FixedArray[Int] = FixedArray::make(test_size, 0)
    for k = 0; k < test_size; k = k + 1 {
      test_idx[k] = perm[offset + k]
    }
    let train_size = n_obs - test_size
    let train_idx : FixedArray[Int] = FixedArray::make(train_size, 0)
    for k = 0; k < train_size; k = k + 1 {
      train_idx[k] = if k < offset { perm[k] } else { perm[k + test_size] }
    }
    out[f] = { train_idx, test_idx, }
    offset = offset + test_size
  }
  out
}

///|
/// build_row_unit_map equivalent (shape only): map each row's cluster
/// id to its position in the uniq array. The contract asserts the
/// resulting map is total (every row is mapped) and the map is
/// inverse of the uniq array (uniq[result[i]] == cluster[i]).
pub fn build_row_unit_map_view(
  cluster : FixedArray[Int],
  uniq : FixedArray[Int],
) -> FixedArray[Int] where {
  proof_require: cluster_subset_of(cluster, uniq),
  proof_ensure: result => row_unit_map_view_ok(result, cluster, uniq),
} {
  let n = cluster.length()
  let n_units = uniq.length()
  let row_unit : FixedArray[Int] = FixedArray::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    proof_assert 0 <= i && i < n
    let g = cluster[i]
    let mut pos = 0
    let mut found = false
    for k = 0; k < n_units; k = k + 1 {
      proof_assert 0 <= k && k < n_units
      if uniq[k] == g {
        pos = k
        found = true
      }
    } where {
      // Inner-loop invariant. Just the bounds for now. The stronger
      // "if found, uniq[pos] == g" form was tried (see HANDOFF.md
      // Pilot 1 v2) but it adds a third timeout because the prover
      // cannot propagate `uniq[k] == g` through `pos <- k` fast
      // enough to discharge the invariant preservation step.
      //
      // The `proof_assert found` and overall `row_unit_map_view_ok`
      // postcondition therefore remain timed out. See HANDOFF.md
      // "Pilot 1 v2 — Fix pass" for the documented why-this-is-
      // genuinely-hard analysis.
      proof_invariant: 0 <= k && k <= n_units,
    }
    proof_assert found
    if found {
      row_unit[i] = pos
    }
  } where {
    proof_invariant: 0 <= i && i <= n,
  }
  row_unit
}

// ============================================================================
// Runtime tests (not proof tests)
// ============================================================================

///|
test "fold_view_new_basic" {
  let f = FoldView::new(
    FixedArray::makei(3, fn(i) { i }), // train: 0, 1, 2
    FixedArray::makei(2, fn(i) { i + 3 }),
  ) // test: 3, 4
  inspect(f.train_idx.length(), content="3")
  inspect(f.test_idx.length(), content="2")
}

///|
test "kfold_from_perm_basic" {
  let perm = FixedArray::makei(6, fn(i) { i }) // identity perm
  let folds = kfold_from_perm(perm, 6, 2)
  inspect(folds.length(), content="2")
  // First fold: test = [0, 1, 2] (base=3, rem=0 → first fold gets 3
  // test rows), train = [3, 4, 5].
  inspect(folds[0].test_idx.length(), content="3")
  inspect(folds[0].train_idx.length(), content="3")
  inspect(folds[0].test_idx[0], content="0")
  inspect(folds[0].test_idx[2], content="2")
  inspect(folds[0].train_idx[0], content="3")
  inspect(folds[0].train_idx[2], content="5")
}

///|
test "kfold_from_perm_uneven" {
  // 7 obs, 3 folds → base=2, rem=1 → fold 0 gets 3 tests, folds 1+2 get 2 each.
  let perm = FixedArray::makei(7, fn(i) { i })
  let folds = kfold_from_perm(perm, 7, 3)
  inspect(folds.length(), content="3")
  inspect(folds[0].test_idx.length(), content="3")
  inspect(folds[1].test_idx.length(), content="2")
  inspect(folds[2].test_idx.length(), content="2")
  // Total test indices = 7.
  let total = folds[0].test_idx.length() +
    folds[1].test_idx.length() +
    folds[2].test_idx.length()
  inspect(total, content="7")
}

///|
test "build_row_unit_map_view_basic" {
  let cluster = FixedArray::makei(4, fn(i) { i % 2 }) // [0, 1, 0, 1]
  let uniq = FixedArray::makei(2, fn(i) { i }) // [0, 1]
  let row_unit = build_row_unit_map_view(cluster, uniq)
  inspect(row_unit.length(), content="4")
  inspect(row_unit[0], content="0")
  inspect(row_unit[1], content="1")
  inspect(row_unit[2], content="0")
  inspect(row_unit[3], content="1")
}
