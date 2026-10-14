///|
// Whitebox tests for ps_processor.mbt internals.
//
// `default_5fold(n)` is the cross-validation fallback used whenever an
// estimator runs with `cv=None`. It is package-private, so no blackbox
// `_test.mbt` can reach it -- and nothing in the blackbox suite asserted its
// central property: that the result is a true partition of 0..n-1.
//
// The blackbox suite DOES have a partition-completeness test, but for
// `folds_to_cv_partition` (added v0.159.0). `default_5fold` itself had none.
//
// Mutation evidence. The qa_loop mutation battery flips the half-open interval
// test at ps_processor.mbt:850 from `j >= start + size` to `j > start + size`.
// The mutant drops the row `start + size` from BOTH train and test -- it lands
// in neither set, so it silently never contributes to any fit. Measured over
// n in {7, 10, 20, 23}, the mutant loses 4 rows per 5-fold CV (every fold
// except the last, where start + size == n falls out of range).
//
// The whole 1114-test suite stayed green under that mutation. The gap was
// found by mutation testing, not by inspection.

///|
test "v1630_default_5fold_is_a_true_partition" {
  let sizes : Array[Int32] = [7, 10, 20, 23]
  for n in sizes {
    let part = default_5fold(n)
    assert_eq(part.length(), 5)
    let tested : Array[Int32] = Array::make(n, 0)
    for f in part {
      let train_idx = f.0
      let held_idx = f.1
      // THE assertion that kills the `>=` -> `>` mutant: train is exactly the
      // complement of test. Under the mutant one index is in neither set, so
      // this is short by one on every fold except the last.
      assert_eq(train_idx.length() + held_idx.length(), n)
      // Disjointness: no index may sit on both sides of the split.
      let held_flag : Array[Int32] = Array::make(n, 0)
      for h in held_idx {
        assert_true(h >= 0 && h < n)
        held_flag[h] = 1
        tested[h] = tested[h] + 1
      }
      for tr in train_idx {
        assert_true(tr >= 0 && tr < n)
        assert_eq(held_flag[tr], 0)
      }
    }
    // Completeness: every index is tested EXACTLY once across the partition.
    for v in tested {
      assert_eq(v, 1)
    }
  }
}
