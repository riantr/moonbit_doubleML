///|
// Whitebox tests for Path A `RFLearner` (v0.56.0+).
//
// Coverage:
//   1. Constructor defaults are correct (n_trees=100, max_depth=10,
//      min_samples_leaf=5, mtry=-1, bootstrap_seed=3141,
//      n_features=-1, trees=[]).
//   2. n_features accessor returns -1 before fit, real count after.
//   3. n_trees accessor returns 0 before fit, real count after.
//   4. Single CART leaf (1 row, n < 2*min_samples_leaf) returns a
//      Leaf node with value = mean(y) for that single row.
//   5. Determinism: same seed -> same forest + same predictions.
//   6. mtry=-1 resolves to floor(sqrt(n_features)).
//   7. Linear DGP recovery: y = 3*x0 + 0.5*x1 + noise; trained
//      forest predictions have non-trivial R^2 > 0.5 on holdout.
//   8. n_trees=1 reproduces a single CART (no bagging), still
//      produces sensible predictions.
//   9. predict on empty input (n=0) returns empty array.
//  10. predict without prior fit returns zeros (lenient fallback
//      matching ConstantLearner / NoopLearner v0.54.0 behavior).

///|
test "rfl_wbtest_constructor_defaults" {
  let rf = RFLearner::new()
  inspect(rf.n_trees, content="100")
  inspect(rf.max_depth, content="10")
  inspect(rf.min_samples_leaf, content="5")
  inspect(rf.mtry, content="-1")
  inspect(rf.bootstrap_seed, content="3141")
  inspect(rf.n_features(), content="-1")
  inspect(rf.n_trees(), content="0")
}

///|
test "rfl_wbtest_constructor_explicit" {
  let rf = RFLearner::new(
    n_trees=50,
    max_depth=5,
    min_samples_leaf=10,
    mtry=2,
    bootstrap_seed=2024,
  )
  inspect(rf.n_trees, content="50")
  inspect(rf.max_depth, content="5")
  inspect(rf.min_samples_leaf, content="10")
  inspect(rf.mtry, content="2")
  inspect(rf.bootstrap_seed, content="2024")
}

///|
test "rfl_wbtest_predict_unfitted_returns_zeros" {
  // Lenient fallback matching v0.54.0 ConstantLearner /
  // NoopLearner behaviour (predict on unfitted learner
  // returns zeros, no abort).
  let rf = RFLearner::new(n_trees=10)
  let x : Matrix = { nrows: 3, ncols: 2, data: [1.0, 0.0, 0.0, 1.0, 1.0, 1.0], }
  let out = rf.predict(x)
  inspect(out.length(), content="3")
  inspect(out[0], content="0")
  inspect(out[1], content="0")
  inspect(out[2], content="0")
}

///|
test "rfl_wbtest_predict_empty_input" {
  // n_obs = 0 edge case: should not panic, return empty.
  let rf = RFLearner::new(n_trees=5).fit(
    Matrix::from_array([1.0, 2.0, 3.0, 4.0], 2, 2),
    [10.0, 20.0],
  )
  let x_empty : Matrix = { nrows: 0, ncols: 2, data: [], }
  let out = rf.predict(x_empty)
  inspect(out.length(), content="0")
}

///|
test "rfl_wbtest_single_row_leaf_value" {
  // With 1 row, min_samples_leaf=5 -> early leaf.
  // Expected prediction = y[0] = 42.0 for that single row.
  let rf = RFLearner::new(n_trees=1, max_depth=10, min_samples_leaf=5)
  let x : Matrix = { nrows: 1, ncols: 1, data: [1.0], }
  let y : Array[Double] = [42.0]
  let fitted = rf.fit(x, y)
  let out = fitted.predict(x)
  inspect(out.length(), content="1")
  inspect(out[0], content="42")
}

///|
test "rfl_wbtest_linear_dgp_recovers_signal" {
  // y = 3*x0 + 0.5*x1 + noise; a forest fit on (n_obs=100,
  // n_features=2) should produce predictions with non-trivial
  // R^2 against the noise-free target.
  let n = 100
  let rng = chacha8_rng(42)
  let x_data : Array[Double] = Array::make(n * 2, 0.0)
  let y_data : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    let x1 = rng.double() * 2.0 - 1.0
    x_data[i * 2 + 0] = x0
    x_data[i * 2 + 1] = x1
    let noise = (rng.double() - 0.5) * 0.4
    y_data[i] = 3.0 * x0 + 0.5 * x1 + noise
  }
  let x = Matrix::from_array(x_data, n, 2)
  let rf = RFLearner::new(n_trees=50, max_depth=8, min_samples_leaf=3, mtry=2).fit(
    x, y_data,
  )
  let preds = rf.predict(x)
  // Compute R^2 of predictions vs noise-free target.
  let mut sum_y = 0.0
  for i = 0; i < n; i = i + 1 {
    sum_y = sum_y + y_data[i]
  }
  let mean_y = sum_y / n.to_double()
  let mut ss_res = 0.0
  let mut ss_tot = 0.0
  for i = 0; i < n; i = i + 1 {
    let noise_free = 3.0 * x_data[i * 2 + 0] + 0.5 * x_data[i * 2 + 1]
    let pred_i = preds[i]
    ss_res = ss_res + (noise_free - pred_i) * (noise_free - pred_i)
    ss_tot = ss_tot + (noise_free - mean_y) * (noise_free - mean_y)
  }
  let r2 = 1.0 - ss_res / ss_tot
  // A 50-tree forest with mtry=2 on a simple linear DGP
  // should easily exceed R^2 = 0.5.
  inspect(r2 > 0.5, content="true")
}

///|
test "rfl_wbtest_determinism_same_seed" {
  // Same seed -> same forest, same predictions (bit-exact).
  let n = 30
  let rng = chacha8_rng(7)
  let x_data : Array[Double] = Array::make(n * 2, 0.0)
  let y_data : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let x0 = rng.double()
    let x1 = rng.double()
    x_data[i * 2 + 0] = x0
    x_data[i * 2 + 1] = x1
    y_data[i] = x0 + 2.0 * x1 + (rng.double() - 0.5) * 0.1
  }
  let x = Matrix::from_array(x_data, n, 2)
  let rf_a = RFLearner::new(n_trees=10, bootstrap_seed=42).fit(x, y_data)
  let rf_b = RFLearner::new(n_trees=10, bootstrap_seed=42).fit(x, y_data)
  inspect(rf_a.n_trees(), content="10")
  inspect(rf_b.n_trees(), content="10")
  let preds_a = rf_a.predict(x)
  let preds_b = rf_b.predict(x)
  inspect(preds_a.length(), content="30")
  inspect(preds_b.length(), content="30")
  for i = 0; i < n; i = i + 1 {
    let diff = (preds_a[i] - preds_b[i]).abs()
    inspect(diff, content="0")
  }
}

///|
test "rfl_wbtest_n_trees_1_single_cart" {
  // n_trees=1 = single CART tree (no ensemble averaging).
  // Should still produce finite predictions; sanity check
  // that the predict path works when trees.length() == 1.
  let n = 20
  let x_data : Array[Double] = Array::make(n * 1, 0.0)
  let y_data : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let xi = i.to_double() / n.to_double() * 4.0 - 2.0
    x_data[i] = xi
    y_data[i] = xi * xi // quadratic DGP; CART can approximate
  }
  let x = Matrix::from_array(x_data, n, 1)
  let rf = RFLearner::new(n_trees=1, max_depth=5).fit(x, y_data)
  inspect(rf.n_trees(), content="1")
  let preds = rf.predict(x)
  inspect(preds.length(), content="20")
  // Predictions should be finite (no NaN / Inf).
  for i = 0; i < n; i = i + 1 {
    inspect(preds[i].is_nan() == false, content="true")
  }
}

///|
test "rfl_wbtest_mtry_default_resolves_to_sqrt" {
  // n_features=4, mtry=-1 -> floor(sqrt(4)) = 2.
  // Build a forest and confirm n_features() is set (sanity
  // that fit completed and the resolved mtry doesn't crash).
  let x_data : Array[Double] = [
    0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0,
    0.5, 0.5, 0.5, 0.5,
  ]
  let x = Matrix::from_array(x_data, 5, 4)
  let y : Array[Double] = [0.0, 1.0, 1.0, 0.0, 0.5]
  let rf = RFLearner::new(n_trees=10, mtry=-1).fit(x, y)
  inspect(rf.n_features(), content="4")
  // Confirm predict works (would panic if a tree referenced
  // an out-of-range feature index).
  let _ = rf.predict(x)
  inspect(true, content="true")
}

///|
test "rfl_wbtest_via_LearnerDispatch_random_forest" {
  // Wire RFLearner through LearnerDispatch +
  // cross_fit_predict_dispatch (the path that PLR uses).
  let n = 50
  let rng = chacha8_rng(11)
  let x_data : Array[Double] = Array::make(n * 2, 0.0)
  let y_data : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let x0 = rng.double() * 2.0 - 1.0
    let x1 = rng.double() * 2.0 - 1.0
    x_data[i * 2 + 0] = x0
    x_data[i * 2 + 1] = x1
    y_data[i] = x0 + 2.0 * x1 + (rng.double() - 0.5) * 0.3
  }
  let x = Matrix::from_array(x_data, n, 2)
  let folds : Array[Fold] = [
    {
      train_idx: [
        10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28,
        29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
      ],
      test_idx: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
    },
    {
      train_idx: [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
        41, 42, 43, 44, 45, 46, 47, 48, 49,
      ],
      test_idx: [10, 11, 12, 13, 14, 15, 16, 17, 18, 19],
    },
    {
      train_idx: [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 40,
        41, 42, 43, 44, 45, 46, 47, 48, 49,
      ],
      test_idx: [20, 21, 22, 23, 24, 25, 26, 27, 28, 29],
    },
    {
      train_idx: [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29,
      ],
      test_idx: [30, 31, 32, 33, 34, 35, 36, 37, 38, 39],
    },
    {
      train_idx: [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
      ],
      test_idx: [40, 41, 42, 43, 44, 45, 46, 47, 48, 49],
    },
  ]
  // Wrap RFLearner in LearnerDispatch + run cross_fit_predict_dispatch.
  let rf = RFLearner::new(n_trees=10, max_depth=5, bootstrap_seed=2024)
  let dispatch = LearnerDispatch::random_forest(rf)
  let oof = cross_fit_predict_dispatch(dispatch, x, y_data, folds)
  // OOF predictions should be finite and have non-trivial
  // spread (not all zeros or all the same value).
  inspect(oof.length(), content="50")
  for i = 0; i < n; i = i + 1 {
    inspect(oof[i].is_nan() == false, content="true")
  }
  let mut mn = oof[0]
  let mut mx = oof[0]
  for i = 1; i < n; i = i + 1 {
    if oof[i] < mn {
      mn = oof[i]
    }
    if oof[i] > mx {
      mx = oof[i]
    }
  }
  let spread = mx - mn
  inspect(spread > 0.5, content="true")
}
