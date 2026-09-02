///|
/// Stratified K-fold partition: per stratum, split the indices into
/// `n_folds` (train, test) pairs using the same Fisher-Yates + fold
/// allocation as `kfold.mbt::kfold`, then concatenate the per-stratum
/// folds in stratum order to form a single `n_folds`-long list of
/// `Fold` objects that together partition `[0, n_obs)`.
///
/// `stratum` is a length-`n_obs` integer array with one stratum label
/// per observation. The function collects indices per stratum, runs
/// `kfold` on each stratum with `seed + stratum_value` as the per-
/// stratum seed (so different strata produce different shuffles),
/// then zips the per-stratum folds together: fold `f` of the final
/// list contains the union of fold-`f` test rows across all strata.
///
/// Matches the upstream `doubleml.utils.resampling.DoubleMLResampling`
/// with `stratify=stratum` and `RepeatedKFold` collapsed to a single
/// repetition. For multi-repetition partitioning, wrap calls in a
/// loop over the seed.
pub fn stratified_kfold(
  stratum : Array[Int],
  n_folds : Int,
  seed : Int,
) -> Array[Fold] {
  try {
    let n_obs = stratum.length()
    require(n_obs > 0)
    require(n_folds > 0)
    require(n_folds <= n_obs)
    // Sort indices by stratum label, then walk to extract per-stratum
    // slices. Use a parallel sort by pairs.
    let pairs : Array[(Int, Int)] = Array::makei(n_obs, fn(i) {
      (stratum[i], i)
    })
    pairs.sort_by(fn(a, b) { a.0.compare(b.0) })
    // Walk and find each stratum's start/end indices in `pairs`.
    let mut acc_s : Array[Int] = []
    let mut acc_e : Array[Int] = []
    let mut i = 0
    while i < n_obs {
      let s = pairs[i].0
      let mut j = i + 1
      while j < n_obs && pairs[j].0 == s {
        j = j + 1
      }
      acc_s = acc_s + [i]
      acc_e = acc_e + [j]
      i = j
    }
    let n_strata = acc_s.length()
    // Per-stratum folds. Each entry is a list of `n_folds` test index
    // arrays (in observation-space coordinates).
    let per_stratum_folds : Array[Array[Array[Int]]] = []
    let mut per_stratum_folds_acc = per_stratum_folds
    for s = 0; s < n_strata; s = s + 1 {
      let start = acc_s[s]
      let end = acc_e[s]
      let stratum_size = end - start
      // Build the per-stratum index list (in `pairs` coordinates).
      let stratum_idx : Array[Int] = []
      let mut stratum_idx_acc = stratum_idx
      for k = start; k < end; k = k + 1 {
        stratum_idx_acc = stratum_idx_acc + [k]
      }
      // Run `kfold` on `stratum_size` indices with `seed + s + 1` as
      // the per-stratum seed (so each stratum gets its own shuffle).
      let stratum_folds = kfold(stratum_size, n_folds, seed + s + 1)
      // Translate each fold's test indices back to observation space.
      let fold_test : Array[Array[Int]] = []
      let mut fold_test_acc = fold_test
      for f = 0; f < n_folds; f = f + 1 {
        let test_local = stratum_folds[f].test_indices()
        let test_global : Array[Int] = []
        let mut test_global_acc = test_global
        for k = 0; k < test_local.length(); k = k + 1 {
          let loc = test_local[k]
          // `stratum_idx_acc[loc]` is the `pairs` coordinate;
          // `pairs[loc].1` is the observation index.
          test_global_acc = test_global_acc + [pairs[stratum_idx_acc[loc]].1]
        }
        fold_test_acc = fold_test_acc + [test_global_acc]
      }
      ignore(stratum_size)
      per_stratum_folds_acc = per_stratum_folds_acc + [fold_test_acc]
    }
    // Combine per-stratum folds: fold `f` of the result is the union
    // of fold-`f` test sets across all strata.
    let combined : Array[Fold] = []
    let mut combined_acc = combined
    for f = 0; f < n_folds; f = f + 1 {
      let test_idx : Array[Int] = []
      let mut test_idx_acc = test_idx
      for s = 0; s < n_strata; s = s + 1 {
        let stratum_fold_test = per_stratum_folds_acc[s][f]
        for k = 0; k < stratum_fold_test.length(); k = k + 1 {
          test_idx_acc = test_idx_acc + [stratum_fold_test[k]]
        }
      }
      // Train = all - test.
      let train_idx : Array[Int] = []
      let mut train_idx_acc = train_idx
      for k = 0; k < n_obs; k = k + 1 {
        let mut in_test = false
        for t = 0; t < test_idx_acc.length(); t = t + 1 {
          if test_idx_acc[t] == k {
            in_test = true
            break
          }
        }
        if !in_test {
          train_idx_acc = train_idx_acc + [k]
        }
      }
      combined_acc = combined_acc +
        [{ train_idx: train_idx_acc, test_idx: test_idx_acc, }]
    }
    combined_acc
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Repeated K-fold partition. Draws `n_rep` independent `kfold`
/// partitions with seeds `3141`, `3142`, ..., `3141 + n_rep - 1`,
/// and returns them as a list of length `n_rep`, each containing
/// `n_folds` `Fold` objects. Matches the upstream
/// `doubleml.utils.resampling.DoubleMLResampling` with
/// `RepeatedKFold` and `stratify=None`.
pub fn repeated_kfold(
  n_obs : Int,
  n_folds : Int,
  n_rep : Int,
) -> Array[Array[Fold]] {
  try {
    require(n_obs > 0)
    require(n_folds > 0)
    require(n_folds <= n_obs)
    require(n_rep >= 1)
    let reps : Array[Array[Fold]] = []
    let mut reps_acc = reps
    for r = 0; r < n_rep; r = r + 1 {
      reps_acc = reps_acc + [kfold(n_obs, n_folds, 3141 + r)]
    }
    reps_acc
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
