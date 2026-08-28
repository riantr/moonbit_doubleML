///|
/// Error type raised by `var_est_cluster` when the fold-mean
/// `J = mean(psi_deriv)` lands below the `1e-6` floor (a
/// defensive guard added in v0.34.0 against divide-by-near-zero
/// inflations of the cluster SE; see the rationale comment in
/// `var_est_cluster` below). The payload captures the exact
/// `(j, g, n_units)` triple that triggered the floor so callers
/// can log or surface a meaningful diagnostic.
///
/// Callers that want to preserve the pre-v0.35.0 process-death
/// behavior should `match` on this variant and re-abort; callers
/// that want to retry or surface the error to downstream
/// consumers should propagate it via `?`.
pub suberror VarEstClusterError {
  JTooSmall(Double, Double, Int) // (j, g, n_units)
}

///|
/// Error type raised by `build_row_unit_map` when a row's unit
/// id is not present in the `uniq` list (a malformed cluster
/// vector — the cluster ids must form a subset of the unique
/// unit ids). The payload is the missing unit id, which the
/// caller can use to log or surface a meaningful diagnostic.
///
/// Added in v0.36.0 to convert the previous `abort()` call
/// into a testable error path. The pre-v0.36.0
/// `panic_build_row_unit_map_missing_unit` test was silently
/// skipped on native/wasm-gc (MoonBit's `panic_*` driver skips
/// panic-prefixed tests; see `_verify/WHITEBOX_T_REPORT.md`).
pub suberror ClusterDataError {
  MissingUnit(Int) // (unit_id)
}

///|
/// A single fold is represented by a pair of train and test index
/// arrays. Test indices are disjoint and together cover `[0, n_obs)`.
pub struct Fold {
  train_idx : Array[Int]
  test_idx : Array[Int]
} derive(Debug)

///|
/// Train indices (accessor for the `train_idx` private field).
pub fn Fold::train_indices(self : Fold) -> Array[Int] {
  self.train_idx
}

///|
/// Test indices (accessor for the `test_idx` private field).
pub fn Fold::test_indices(self : Fold) -> Array[Int] {
  self.test_idx
}

///|
/// Public constructor: build a fold from explicit train/test index
/// arrays (used by callers that drive cross-fitting with their own
/// partitions, e.g. the clustered panel path in `plpr.mbt`).
pub fn Fold::new(train_idx : Array[Int], test_idx : Array[Int]) -> Fold {
  require(test_idx.length() > 0)
  require(train_idx.length() + test_idx.length() > 0)
  { train_idx, test_idx }
}

///|
/// Draw `n_folds` (train, test) splits that together partition
/// `[0, n_obs)` using a deterministic shuffle seeded with `seed`. The
/// resulting list has length `n_folds`. If `n_obs` is not a multiple of
/// `n_folds`, the first `n_obs mod n_folds` folds get one extra
/// observation in the test set, matching the behaviour of sklearn's
/// `KFold(shuffle=True)` for non-divisible sizes.
pub fn kfold(n_obs : Int, n_folds : Int, seed : Int) -> Array[Fold] {
  require(n_obs > 0)
  require(n_folds > 0)
  require(n_folds <= n_obs)
  // Use the canonical `seed_to_bytes` helper (8-bit LE) so the
  // fold partition matches what a user would reproduce by hand
  // from `seed_to_bytes(seed)`.
  // The fold partition is still well-shuffled — only the specific
  // indices per fold change. Every test's tolerance is wide enough
  // to absorb the resulting ~0.01 theta drift.
  let bytes = seed_to_bytes(seed)
  let rng = @random.Rand::chacha8(seed=Bytes::from_array(bytes))
  // Fisher-Yates permutation of [0, n_obs)
  let perm : Array[Int] = Array::makei(n_obs, fn(i) { i })
  for i = n_obs - 1; i > 0; i = i - 1 {
    let j = rng.int(limit=i + 1)
    perm.swap(i, j)
  }
  let base = n_obs / n_folds
  let rem = n_obs - base * n_folds
  let folds : Array[Fold] = []
  let mut offset = 0
  for f = 0; f < n_folds; f = f + 1 {
    let test_size = if f < rem { base + 1 } else { base }
    let test_idx : Array[Int] = []
    for k = 0; k < test_size; k = k + 1 {
      test_idx.push(perm[offset + k])
    }
    let train_idx : Array[Int] = []
    for k = 0; k < n_obs; k = k + 1 {
      if k < offset || k >= offset + test_size {
        train_idx.push(perm[k])
      }
    }
    folds.push({ train_idx, test_idx })
    offset = offset + test_size
  }
  folds
}

///|
/// Slice a matrix by a list of row indices, returning a new `n x p`
/// matrix with the selected rows in the given order.
pub fn slice_matrix_rows(x : Matrix, idx : Array[Int]) -> Matrix {
  let n = idx.length()
  let out = Matrix::zeros(n, x.ncols)
  for i = 0; i < n; i = i + 1 {
    let row = idx[i]
    for j = 0; j < x.ncols; j = j + 1 {
      out.data[i * x.ncols + j] = x.data[row * x.ncols + j]
    }
  }
  out
}

///|
/// Slice a vector by a list of indices.
pub fn slice_vector(v : Array[Double], idx : Array[Int]) -> Array[Double] {
  let out : Array[Double] = Array::make(idx.length(), 0.0)
  for i = 0; i < idx.length(); i = i + 1 {
    out[i] = v[idx[i]]
  }
  out
}

///|
/// The full index range `[0, n)`. Convenient for callers that need
/// to pass a complete index list to `filter_indices` (e.g. the LPQ
/// complier-prob computation in `lpq.mbt::DoubleMLLPQ::fit`).
pub fn range_indices(n : Int) -> Array[Int] {
  Array::makei(n, fn(i) { i })
}

///|
/// Clustered-path fold builder. Takes the unit-level fold
/// partition (a `kfold(n_units, n_folds, seed)` result) and
/// expands it to a row-level fold partition where every row of
/// a given unit lands on the same side of every split. Also
/// returns the per-unit test-fold index and the per-fold
/// unit count, both of which are needed by
/// `est_coef_cluster` / `var_est_cluster`.
///
///   `cluster`        : length-`n` vector of unit ids
///   `folds_u`        : unit-level folds (each `Fold` carries
///                      `test_indices` = unit positions)
///   `row_unit`       : length-`n` row → unit-position map
///                      (use `build_row_unit_map`)
///
/// Returns `(folds_row, unit_fold, fold_n_units)`:
///   - `folds_row`     : length-`n_folds` row-level folds
///   - `unit_fold`     : length-`n_units` per-unit test-fold index
///   - `fold_n_units`  : length-`n_folds` per-fold unit count
pub fn expand_unit_folds_to_rows(
  cluster : Array[Int],
  folds_u : Array[Fold],
  row_unit : Array[Int],
) -> (Array[Fold], Array[Int], Array[Int]) {
  let n = cluster.length()
  let n_units = row_unit_max(row_unit) + 1
  let folds_row : Array[Fold] = []
  let unit_fold : Array[Int] = Array::make(n_units, 0)
  let fold_n_units : Array[Int] = Array::make(folds_u.length(), 0)
  for f = 0; f < folds_u.length(); f = f + 1 {
    let tu = folds_u[f].test_indices()
    fold_n_units[f] = tu.length()
    let in_test : Array[Bool] = Array::make(n_units, false)
    for k = 0; k < tu.length(); k = k + 1 {
      in_test[tu[k]] = true
      unit_fold[tu[k]] = f
    }
    let train_rows : Array[Int] = []
    let test_rows : Array[Int] = []
    for i = 0; i < n; i = i + 1 {
      if in_test[row_unit[i]] {
        test_rows.push(i)
      } else {
        train_rows.push(i)
      }
    }
    folds_row.push(Fold::new(train_rows, test_rows))
  }
  (folds_row, unit_fold, fold_n_units)
}

///|
/// Build a row → unit-position map (length = `n`, each entry is
/// the position of the row's unit in the unique-ids array
/// produced by `unique_units(cluster)`). Aborts if any row's
/// unit is missing from the `uniq` list (a row whose unit is
/// not in `uniq` would be an unrecoverable data error).
///
/// Returns `Array[Int] raise ClusterDataError`: the v0.36.0
/// conversion replaces the previous `abort()` call with
/// `raise ClusterDataError::MissingUnit(g)` so the data-error
/// path becomes directly testable. Callers that want the
/// pre-v0.36.0 process-death behavior should catch the error
/// and re-abort (this is what every `DoubleMLXXX::fit_cluster`
/// does); callers that want to surface the error to downstream
/// consumers should propagate via `?`. The error type is declared
/// at the top of this file so the cluster helper stack can share it.
pub fn build_row_unit_map(
  cluster : Array[Int],
  uniq : Array[Int],
) -> Array[Int] raise ClusterDataError {
  let n = cluster.length()
  let n_units = uniq.length()
  let row_unit : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    let g = cluster[i]
    let mut found = false
    for k = 0; k < n_units; k = k + 1 {
      if uniq[k] == g {
        row_unit[i] = k
        found = true
        break
      }
    }
    if !found {
      raise ClusterDataError::MissingUnit(g)
    }
  }
  row_unit
}

///|
/// Helper: `max(row_unit)` (the largest unit position, equal to
/// `n_units - 1` when `row_unit` is built from a complete
/// `uniq` vector).
fn row_unit_max(row_unit : Array[Int]) -> Int {
  let mut m = 0
  for i = 0; i < row_unit.length(); i = i + 1 {
    if row_unit[i] > m {
      m = row_unit[i]
    }
  }
  m
}

///|
/// Cluster-robust causal parameter + SE computation. Combines
/// `est_coef_cluster` (fold-weighted ratio of cluster score
/// sums) and `var_est_cluster` (unit-level cluster-robust SE)
/// over the same per-row score elements. Used by every
/// clustered-DML path that follows the PLR-style
/// `psi_a, psi_b` pattern (PLR, IRM, PLPR, PLIV, IIVM).
/// The `n` argument is the row count used for `psi_res`
/// allocation; the caller pre-computes `psi_a` and `psi_b` at
/// its converged coefficient / nuisance values.
///
/// Returns `(theta_r, se_r)`. The `!VarEstClusterError` annotation
/// propagates the J-floor defensive guard from `var_est_cluster`
/// (v0.34.0+) so callers can decide whether to abort, retry with
/// a different seed, or surface the error to downstream consumers.
/// All fit_cluster() methods in PLR / IRM / PLPR / PLIV / IIVM
/// catch this error and re-abort to preserve the pre-v0.35.0
/// process-death behavior on pathological fold splits.
pub fn cluster_causal_param_and_se(
  psi_a : Array[Double],
  psi_b : Array[Double],
  folds_row : Array[Fold],
  fold_n_units : Array[Int],
  unit_rows : Array[Array[Int]],
  unit_fold : Array[Int],
  n_folds_u : Int,
  n_folds_per_cluster : Int,
) -> (Double, Double) raise VarEstClusterError {
  let theta_r = est_coef_cluster(psi_a, psi_b, folds_row, fold_n_units)
  let n = psi_a.length()
  let psi_res : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    psi_res[i] = theta_r * psi_a[i] + psi_b[i]
  }
  let se_r = var_est_cluster(
    psi_res, psi_a, unit_rows, unit_fold, n_folds_u, n_folds_per_cluster,
  )
  (theta_r, se_r)
}

///|
/// Cross-fit prediction helper. For each fold, fit the learner on the
/// training slice `(x[train], y[train])` and predict on the test slice
/// `x[test]`. The returned vector has length `n_obs` and contains
/// the predictions in the original observation order. Assumes the
/// folds together cover `[0, n_obs)`.
pub fn[T : Learner] cross_fit_predict(
  learner : T,
  x : Matrix,
  y : Array[Double],
  folds : Array[Fold],
) -> Array[Double] {
  let n_obs = x.nrows
  let preds : Array[Double] = Array::make(n_obs, 0.0)
  for fold in folds {
    let xt = slice_matrix_rows(x, fold.train_idx)
    let yt = slice_vector(y, fold.train_idx)
    let fitted = learner.fit(xt, yt)
    let p = fitted.predict(slice_matrix_rows(x, fold.test_idx))
    for k = 0; k < fold.test_idx.length(); k = k + 1 {
      preds[fold.test_idx[k]] = p[k]
    }
  }
  preds
}

///|
/// Double cross-fit prediction helper used by IRM-style models
/// (e.g. LPLR). `outer` is the row-level outer-fold partition;
/// for each outer fold, the model's training slice is re-split
/// into `n_inner` inner folds via `kfold`, the learner is fit on
/// each inner training slice and predicts on the corresponding
/// inner test slice, and the resulting `n_inner` arrays of
/// predictions are returned. The outer model then has, for each
/// outer test row, an inner OOF prediction — used downstream to
/// construct nuisance `W` and the preliminary `beta`.
///
/// Returns an `Array[Array[Double]]` of length `outer.length()`,
/// one entry per outer fold. Each entry has length
/// `inner_train_count` (the size of the outer fold's training
/// slice); values are filled at the original training-row
/// positions in the order the inner folds visit them.
pub fn[T : Learner] double_cross_fit_predict(
  learner : T,
  x : Matrix,
  y : Array[Double],
  outer : Array[Fold],
  n_inner : Int,
  seed : Int,
) -> Array[Array[Double]] {
  let mut rng_state : Int = seed
  let out : Array[Array[Double]] = Array::new()
  for fold in outer {
    let train_idx = fold.train_idx
    let m = train_idx.length()
    // Build inner folds on the outer training indices.
    let inner = kfold(m, n_inner, rng_state)
    rng_state = rng_state + 1
    let preds : Array[Double] = Array::make(m, 0.0)
    for ifold in inner {
      let xt_rows : Array[Int] = Array::makei(ifold.train_idx.length(), fn(k) {
        train_idx[ifold.train_idx[k]]
      })
      let yt_rows : Array[Int] = Array::makei(ifold.train_idx.length(), fn(k) {
        train_idx[ifold.train_idx[k]]
      })
      let xt = slice_matrix_rows(x, xt_rows)
      let yt = slice_vector(y, yt_rows)
      let fitted = learner.fit(xt, yt)
      let te_rows : Array[Int] = Array::makei(ifold.test_idx.length(), fn(k) {
        train_idx[ifold.test_idx[k]]
      })
      let p = fitted.predict(slice_matrix_rows(x, te_rows))
      for k = 0; k < ifold.test_idx.length(); k = k + 1 {
        preds[ifold.test_idx[k]] = p[k]
      }
    }
    out.push(preds)
  }
  out
}
