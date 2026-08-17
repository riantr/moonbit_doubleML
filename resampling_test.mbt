///|
/// `stratified_kfold` partitions observations so each fold's test
/// set contains a proportional share of every stratum. With
/// `n_obs = 20` (10 in stratum 0, 10 in stratum 1) and `n_folds = 2`,
/// each fold's test set should contain exactly 5 from each stratum.
test "stratified_kfold_balanced_test_sets" {
  let stratum : Array[Int] = Array::makei(20, fn(i) {
    if i < 10 {
      0
    } else {
      1
    }
  })
  let folds = stratified_kfold(stratum, 2, 3141)
  inspect(folds.length(), content="2")
  for f = 0; f < 2; f = f + 1 {
    let test_idx = folds[f].test_indices()
    let mut n_s0 = 0
    let mut n_s1 = 0
    for k = 0; k < test_idx.length(); k = k + 1 {
      if stratum[test_idx[k]] == 0 {
        n_s0 = n_s0 + 1
      } else {
        n_s1 = n_s1 + 1
      }
    }
    inspect(n_s0, content="5")
    inspect(n_s1, content="5")
  }
}

///|
/// Train + test must cover `[0, n_obs)` with disjoint indices.
test "stratified_kfold_train_test_disjoint" {
  let stratum : Array[Int] = Array::makei(10, fn(i) { i % 3 })
  let folds = stratified_kfold(stratum, 2, 3141)
  for f = 0; f < folds.length(); f = f + 1 {
    let train = folds[f].train_indices()
    let te = folds[f].test_indices()
    inspect(train.length() + te.length(), content="10")
    for k = 0; k < te.length(); k = k + 1 {
      let t = te[k]
      for j = 0; j < train.length(); j = j + 1 {
        inspect(train[j] == t, content="false")
      }
    }
  }
}

///|
/// `repeated_kfold` returns `n_rep` partitions, each with `n_folds`
/// folds. With deterministic seeds the same fold layout is reused
/// across reps (which is the upstream convention for `RepeatedKFold`).
test "repeated_kfold_shape" {
  let reps = repeated_kfold(20, 4, 3)
  inspect(reps.length(), content="3")
  for r = 0; r < reps.length(); r = r + 1 {
    inspect(reps[r].length(), content="4")
  }
}
