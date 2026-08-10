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
  // REVIEW M13 fix: use the canonical 8-bit `seed_to_bytes` helper
  // instead of the legacy 7-bit-per-byte tiling that lived here. The
  // two encoders produce *different* byte streams for the same
  // integer seed (e.g. `seed = 3141`); the 8-bit version is the one
  // the rest of the package uses via `seed_to_bytes` (and the one
  // the docstring says "supersedes the earlier 7-bit-tiling helper").
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
