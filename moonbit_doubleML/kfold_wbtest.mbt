///|
// Whitebox tests for kfold.mbt internals.
//
// `kfold_test.mbt` covers the public surface (`Fold`, `kfold`,
// `kfold_stratified`, `slice_*`). This file tests two internal
// helpers that `_test.mbt` cannot reach because they have
// package-private visibility:
//
//   - `expand_unit_folds_to_rows(cluster, folds_u, row_unit)`
//     — the cluster-aware fold expansion used by every
//     clustered-DML path. The contract is that no row of a
//     unit lands on both sides of any split, and that the
//     per-fold unit count matches the unit-level fold size.
//
//   - `build_row_unit_map(cluster, uniq)` — the row → unit-
//     position lookup. The contract is correctness under
//     non-contiguous unit ids (e.g. {3, 5, 7, 11} not
//     {0, 1, 2, 3}), which the public surface never exercises
//     but real panel data often has.
//
// These tests are scoped to package-internal symbols; they
// would not compile if moved to `kfold_test.mbt`.

///|
test "expand_unit_folds_to_rows_partition_is_row_complete" {
  // 4 units × 2 rows each = 8 rows. 2 folds. The unit-level
  // kfold puts {u0, u1} in fold 0 and {u2, u3} in fold 1,
  // which at the row level becomes {r0, r1, r4, r5} in fold 0
  // and {r2, r3, r6, r7} in fold 1.
  let cluster : Array[Int] = [0, 0, 1, 1, 2, 2, 3, 3]
  let row_unit : Array[Int] = [0, 0, 1, 1, 2, 2, 3, 3]
  let folds_u = kfold(4, 2, 3141)
  let (folds_row, _unit_fold, _fold_n_units) = expand_unit_folds_to_rows(
    cluster, folds_u, row_unit,
  )
  inspect(folds_row.length(), content="2")
  // Every row 0..7 must appear exactly once across all folds.
  let seen : Array[Int] = Array::make(8, 0)
  for fold in folds_row {
    for i in fold.test_indices() {
      seen[i] = seen[i] + 1
    }
    for i in fold.train_indices() {
      seen[i] = seen[i] + 1
    }
  }
  // Each row lands on exactly one side per fold, and there
  // are 2 folds: row i is in one fold's test_indices and in
  // the other fold's train_indices, so total visits per row
  // is 2.
  for k = 0; k < 8; k = k + 1 {
    inspect(seen[k], content="2")
  }
}

///|
test "expand_unit_folds_to_rows_no_unit_straddles_split" {
  // Cluster contract: every row of a unit lands on the same
  // side of every split. For each fold, for each unit, the
  // intersection of `row_unit == u` with `test_indices` is
  // either empty or all-of-u.
  let cluster : Array[Int] = [0, 1, 2, 0, 1, 2, 0, 1, 2, 0]
  let row_unit : Array[Int] = [0, 1, 2, 0, 1, 2, 0, 1, 2, 0]
  let folds_u = kfold(3, 3, 7)
  let (folds_row, _, _) = expand_unit_folds_to_rows(
    cluster, folds_u, row_unit,
  )
  for fold in folds_row {
    let test_set : Array[Bool] = Array::make(10, false)
    for i in fold.test_indices() {
      test_set[i] = true
    }
    // For each unit u: either 0 rows in test_indices (u all in
    // train) or all rows of u in test_indices (u all in test).
    // The contiguity of the row_unit vector lets us check this
    // per unit block.
    for u = 0; u < 3; u = u + 1 {
      let mut n_test_for_u = 0
      let mut n_rows_for_u = 0
      for i = 0; i < 10; i = i + 1 {
        if row_unit[i] == u {
          n_rows_for_u = n_rows_for_u + 1
          if test_set[i] {
            n_test_for_u = n_test_for_u + 1
          }
        }
      }
      // Either u is fully in test, or u is fully in train.
      // n_test_for_u must be 0 or n_rows_for_u.
      inspect(n_test_for_u == 0 || n_test_for_u == n_rows_for_u, content="true")
    }
  }
}

///|
test "expand_unit_folds_to_rows_fold_n_units_matches_unit_fold" {
  // The third return value (fold_n_units) must equal the
  // number of units in each unit-level test fold.
  let cluster : Array[Int] = [0, 1, 2, 3, 4, 5, 6, 7]
  let row_unit : Array[Int] = [0, 1, 2, 3, 4, 5, 6, 7]
  let folds_u = kfold(8, 4, 99)
  let (_folds_row, _unit_fold, fold_n_units) = expand_unit_folds_to_rows(
    cluster, folds_u, row_unit,
  )
  inspect(fold_n_units.length(), content="4")
  for f = 0; f < 4; f = f + 1 {
    inspect(fold_n_units[f], content=folds_u[f].test_indices().length().to_string())
  }
}

///|
test "build_row_unit_map_non_contiguous_unit_ids" {
  // Real panel data has non-contiguous unit ids (e.g. firm
  // ids {3, 5, 7, 11}). The mapping is positional, so the
  // output must still be [0, 1, 2, 3] for rows in cluster-id
  // order.
  let cluster : Array[Int] = [3, 3, 5, 7, 7, 7, 11, 5, 3]
  let uniq : Array[Int] = [3, 5, 7, 11]
  let row_unit = build_row_unit_map(cluster, uniq)
  // Expected: [0, 0, 1, 2, 2, 2, 3, 1, 0]
  inspect(row_unit.length(), content="9")
  inspect(row_unit[0], content="0")
  inspect(row_unit[1], content="0")
  inspect(row_unit[2], content="1")
  inspect(row_unit[3], content="2")
  inspect(row_unit[4], content="2")
  inspect(row_unit[5], content="2")
  inspect(row_unit[6], content="3")
  inspect(row_unit[7], content="1")
  inspect(row_unit[8], content="0")
}

///|
test "build_row_unit_map_raises_on_missing_unit" {
  // A cluster id not present in `uniq` must raise the
  // ClusterDataError::MissingUnit variant (introduced in
  // v0.36.0 to make this data-error path testable). The
  // pre-v0.36.0 behaviour was an `abort()`.
  let cluster : Array[Int] = [0, 1, 99]
  let uniq : Array[Int] = [0, 1]
  let raised = (try {
    ignore(build_row_unit_map(cluster, uniq))
    false
  } catch {
    ClusterDataError::MissingUnit(_) => true
  })
  inspect(raised, content="true")
}