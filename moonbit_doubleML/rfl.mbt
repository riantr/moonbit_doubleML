///|
// Path A — `RFLearner` (random-forest regression learner). v0.56.0+.
//
// Pure-MoonBit CART tree + bootstrap-bagged random forest.
// Implements the `Learner` trait so it plugs directly into the
// `LearnerDispatch` enum (learner.mbt) and the cross-fit helpers
// in `kfold.mbt` / `learner.mbt`.
//
// Algorithm (Breiman 2001 random forest, regression flavour):
//
//   for b in 0..n_trees:
//     draw bootstrap sample of length n_obs (sample with
//       replacement) using chacha8_rng(bootstrap_seed + b)
//     trees[b] = cart_fit(x[bootstrap], y[bootstrap], max_depth,
//                         min_samples_leaf, mtry,
//                         chacha8_rng(bootstrap_seed + n_trees + b))
//   return RFLearner { trees, n_features, ..self }
//
//   predict(x):
//     for each row i in x:
//       avg = 0
//       for each tree t in trees:
//         avg += cart_predict(t, x, i)
//       preds[i] = avg / n_trees
//
// CART node is an immutable enum (Leaf / Split), so trees
// can be traversed without any mutable state and are
// trivially thread-safe (not that it matters in MoonBit
// single-threaded runtime). Splits are binary thresholds on
// a single feature column; leaf value is the per-leaf mean
// of the training residuals that landed there.
//
// Hyperparameters:
//   - n_trees         : number of trees in the forest (default 100)
//   - max_depth       : maximum tree depth (default 10;
//                       0 = unlimited which is risky on deep data)
//   - min_samples_leaf : minimum samples in a leaf to allow
//                        further splitting (default 5)
//   - mtry            : number of features considered per
//                       split (default -1 = sqrt(n_features),
//                       the standard regression default)
//   - bootstrap_seed  : base seed for both bootstrap draws and
//                       tree-internal randomness (default 3141)
//
// `mtry = -1` is resolved to `max(1, floor(sqrt(n_features)))`
// in `fit` (matches sklearn's `RandomForestRegressor`'s default
// `max_features="sqrt"`).
//
// Computational complexity (per tree):
//   O(n * d * log(n)) for the sort + O(n * mtry * depth) for the
// recursive splitting. With `n_trees = 100`, the typical
// DML cross-fit does `2 * 100 = 200` tree fits per observation
// row of `n` (once for outcome, once for treatment). On the
// default test fixtures (`n_obs ≤ 300, n_features ≤ 5`), total
// runtime is well under 1 s per fit.

///|
/// Immutable CART tree node. `Split` carries the feature
/// column index, the threshold, and the two child subtrees.
/// `Leaf` carries the per-leaf mean (the constant prediction
/// for rows that land here).
pub enum CART {
  Leaf(Double)
  Split(Int, Double, CART, CART)
} derive(Debug)

///|
pub extend CART with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Random forest learner (regression). Fits a forest of
/// CART trees on bootstrap samples; predicts by averaging
/// leaf values across all trees.
pub struct RFLearner {
  n_trees : Int
  max_depth : Int
  min_samples_leaf : Int
  mtry : Int // -1 = sqrt(n_features) at fit time
  bootstrap_seed : Int
  // Fitted state (empty until `fit` is called).
  trees : Array[CART]
  // Number of feature columns the forest was fit on. Used in
  // `predict` to validate input shape. -1 = not yet fit.
  n_features : Int
} derive(Debug)

///|
pub extend RFLearner with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Promote the `Learner` trait methods (`fit`, `predict`) as
/// explicit methods on `RFLearner`. Without this `extend`,
/// MoonBit raises an `unused_value` warning for the trait
/// impls below (the trait methods are reached only via
/// dispatch through `cross_fit_predict_dispatch`, never
/// directly), and the `--deny-warn` build gate treats that
/// as an error. Same pattern as the v0.54.0
/// `ConstantLearner` / `NoopLearner` setup.
pub extend RFLearner with Learner::{predict}

///|
pub fn RFLearner::new(
  n_trees? : Int = 100,
  max_depth? : Int = 10,
  min_samples_leaf? : Int = 5,
  mtry? : Int = -1,
  bootstrap_seed? : Int = 3141,
) -> RFLearner {
  {
    n_trees,
    max_depth,
    min_samples_leaf,
    mtry,
    bootstrap_seed,
    trees: [],
    n_features: -1,
  }
}

///|
/// Number of feature columns the forest was fit on. Returns
/// -1 if the learner has not been fit yet.
pub fn RFLearner::n_features(self : RFLearner) -> Int {
  self.n_features
}

///|
/// Number of trees in the fitted forest. Returns 0 if not
/// yet fit (so callers can early-return on `RFLearner::new()`
/// without an explicit "is_fitted" flag).
pub fn RFLearner::n_trees(self : RFLearner) -> Int {
  self.trees.length()
}

// ---------------------------------------------------------------------------
// Bootstrap sampling helper
// ---------------------------------------------------------------------------

///|
/// Draw a bootstrap sample of length `n_obs` (sample with
/// replacement) using `chacha8_rng(seed)`. Returns an
/// `Array[Int]` of length `n_obs` whose entries are row
/// indices into the source dataset (each in `[0, n_obs)`).
///
/// Seed determinism: with the same seed, the returned index
/// sequence is bit-identical across runs (necessary for
/// `validate_*_with_python.py` parity tests).
fn bootstrap_indices(n_obs : Int, seed : Int) -> Array[Int] {
  let rng = chacha8_rng(seed)
  let out : Array[Int] = Array::make(n_obs, 0)
  for i = 0; i < n_obs; i = i + 1 {
    out[i] = rng.int(limit=n_obs)
  }
  out
}

// ---------------------------------------------------------------------------
// CART fitting
// ---------------------------------------------------------------------------

///|
/// Build a single CART tree on `(x, y)` using the sample
/// indices in `sample_idx` (each entry in `[0, x.nrows)`).
/// Recurses up to `max_depth` levels, stopping early when
/// a node has fewer than `min_samples_leaf` samples or when
/// no split improves the squared error.
///
/// `feature_rng` is the per-tree RNG used to sample the
/// `mtry` features at each split. Passing a fresh RNG per
/// tree keeps the bootstrap sequence and the tree-internal
/// feature sequence independent.
///
/// v0.117.0: `clf` and `hess` generalise the kernel from the
/// regression-only case to classification. Both default to the
/// regression behaviour and the `clf = false` path is kept
/// BYTE-IDENTICAL to the pre-v0.117.0 code -- this file has
/// Python-parity tests pinning regression tree output, so the
/// split arithmetic below is not refactored, only branched around.
///
///   - `clf = false` splits minimise weighted MSE and leaves hold
///     the node mean. This is the v0.56.0 behaviour.
///   - `clf = true` splits minimise weighted Gini impurity and a
///     node whose labels are already pure is never split.
///   - `hess` empty keeps the leaf value at the node mean.
///     `hess` non-empty (length `y.length()`) makes the leaf
///     `SUM(y[idx]) / SUM(hess[idx])` -- the Newton step that
///     gradient-boosting classification needs. Splitting still
///     uses MSE on `y`, because that is what upstream fits: a
///     `DecisionTreeRegressor` on the negative gradient, with
///     only the leaf value overridden.
///   - v0.118.0: `w` empty is the unweighted case and is
///     BYTE-IDENTICAL to the pre-v0.118.0 arithmetic. Non-empty
///     `w` makes every accumulation weighted -- the leaf becomes
///     `SUM(w*y) / SUM(w)`, or `SUM(w*g) / SUM(w*h)` when `hess`
///     is also present, and the split score becomes the weighted
///     variance / weighted Gini. That is scikit-learn's semantics:
///     the tree is handed the RAW target plus the weights, and
///     weights never pre-multiply the target, because that would
///     square them in the leaf.
fn cart_fit(
  x : Matrix,
  y : Array[Double],
  sample_idx : Array[Int],
  depth : Int,
  max_depth : Int,
  min_samples_leaf : Int,
  mtry : Int,
  feature_rng : @random.Rand,
  clf : Bool,
  hess : Array[Double],
  w : Array[Double],
) -> CART {
  let n = sample_idx.length()
  // v0.118.0: an empty `w` means unweighted and takes the verbatim
  // pre-v0.118.0 arithmetic in both the leaf value and the split
  // score. Hoisting the flag here keeps that condition testable
  // rather than re-derived inside the loop.
  let weighted = w.length() > 0
  // Stop conditions: leaf.
  if n < 2 * min_samples_leaf || depth >= max_depth {
    return CART::Leaf(cart_leaf_value(y, sample_idx, hess, w))
  }
  // v0.117.0: a pure node has zero impurity gain at every
  // threshold, so a Gini sweep would still "find" a split at
  // score 0 and recurse for nothing. Regression does not need
  // this guard -- its sentinel already treats a constant node as
  // score 0 and splits harmlessly -- so the guard is confined to
  // the classification branch to leave regression untouched.
  if clf {
    let first_y = y[sample_idx[0]]
    let mut pure = true
    for i = 1; i < n; i = i + 1 {
      // v0.118.0: a zero-weight row contributes nothing, so it must
      // not make a node look impure.
      if weighted && w[sample_idx[i]] == 0.0 {
        continue
      }
      if y[sample_idx[i]] != first_y {
        pure = false
        break
      }
    }
    if pure {
      return CART::Leaf(cart_leaf_value(y, sample_idx, hess, w))
    }
  }
  let n_features = x.ncols
  let mtry_eff = if mtry <= 0 || mtry > n_features {
    // sklearn default `sqrt(n_features)` for regression, with
    // a floor of 1 so we don't divide-by-zero on n_features=1.
    let mut s = 1
    while s * s <= n_features {
      s = s + 1
    }
    s - 1 // floor(sqrt(n_features))
  } else {
    mtry
  }
  // Pick mtry random feature indices WITHOUT replacement via
  // the Fisher-Yates partial shuffle on [0, n_features).
  let feat_pool : Array[Int] = Array::makei(n_features, fn(i) { i })
  let mtry_actual = if mtry_eff > n_features { n_features } else { mtry_eff }
  for i = 0; i < mtry_actual; i = i + 1 {
    let j = i + feature_rng.int(limit=n_features - i)
    let tmp = feat_pool[i]
    feat_pool[i] = feat_pool[j]
    feat_pool[j] = tmp
  }
  // Search each candidate feature for the best split.
  let mut best_score = 1.0e300 // sentinel "no split found yet"
  let mut best_feature = -1
  let mut best_threshold = 0.0
  let mut best_left : Array[Int] = []
  let mut best_right : Array[Int] = []
  for k = 0; k < mtry_actual; k = k + 1 {
    let f = feat_pool[k]
    // Sort sample indices by `x[idx, f]`. Use a simple
    // selection sort (n is small per tree-split in our test
    // fixtures; for production scale-up, swap in a counting
    // sort or quickselect).
    let sorted_idx = sort_indices_by_feature(x, y, sample_idx, f)
    // Sweep split points between consecutive DISTINCT values.
    // For each candidate split at index `i` (left = [0..i+1],
    // right = [i+1..n)), compute the weighted MSE reduction.
    let mut last_val = x.get(sorted_idx[0], f)
    for i = 0; i < n - 1; i = i + 1 {
      let cur_val = x.get(sorted_idx[i + 1], f)
      // Skip ties (no information gain between equal values).
      if cur_val == last_val {
        last_val = cur_val
        continue
      }
      let threshold = (last_val + cur_val) * 0.5
      let left_count = i + 1
      let right_count = n - left_count
      if left_count < min_samples_leaf || right_count < min_samples_leaf {
        last_val = cur_val
        continue
      }
      // Compute the split score. Both existing branches are the
      // pre-v0.118.0 arithmetic VERBATIM -- same association, same
      // divide -- because Python-parity tests pin them and an
      // "equivalent" rewrite would move the last bits. The weighted
      // branches are ADDITIONAL, reached only when `w` is non-empty.
      let score = if !clf && !weighted {
        // Weighted MSE of (y - left_mean)^2 on left +
        // (y - right_mean)^2 on right.
        let mut ss_left = 0.0
        let mut sum_left = 0.0
        for j = 0; j <= i; j = j + 1 {
          let yj = y[sorted_idx[j]]
          sum_left = sum_left + yj
          ss_left = ss_left + yj * yj
        }
        let mean_left = sum_left / left_count.to_double()
        ss_left = ss_left - sum_left * mean_left
        let mut ss_right = 0.0
        let mut sum_right = 0.0
        for j = i + 1; j < n; j = j + 1 {
          let yj = y[sorted_idx[j]]
          sum_right = sum_right + yj
          ss_right = ss_right + yj * yj
        }
        let mean_right = sum_right / right_count.to_double()
        ss_right = ss_right - sum_right * mean_right
        (ss_left + ss_right) / n.to_double()
      } else if !clf {
        // v0.118.0: WEIGHTED variance. `ss = SUM(w*(y-mean)^2)` is
        // computed as `SUM(w*y^2) - mean*SUM(w*y)` with
        // `mean = SUM(w*y)/SUM(w)`, the same algebraic form as the
        // unweighted branch so the two agree when `w` is all ones up
        // to rounding.
        let mut sum_left = 0.0
        let mut sum_left_sq = 0.0
        let mut sw_left = 0.0
        for j = 0; j <= i; j = j + 1 {
          let row = sorted_idx[j]
          let wi = w[row]
          let yj = y[row]
          sum_left = sum_left + wi * yj
          sum_left_sq = sum_left_sq + wi * yj * yj
          sw_left = sw_left + wi
        }
        let mut sum_right = 0.0
        let mut sum_right_sq = 0.0
        let mut sw_right = 0.0
        for j = i + 1; j < n; j = j + 1 {
          let row = sorted_idx[j]
          let wi = w[row]
          let yj = y[row]
          sum_right = sum_right + wi * yj
          sum_right_sq = sum_right_sq + wi * yj * yj
          sw_right = sw_right + wi
        }
        let ss_left = if sw_left == 0.0 {
          0.0
        } else {
          let mean_left = sum_left / sw_left
          sum_left_sq - sum_left * mean_left
        }
        let ss_right = if sw_right == 0.0 {
          0.0
        } else {
          let mean_right = sum_right / sw_right
          sum_right_sq - sum_right * mean_right
        }
        let sw_total = sw_left + sw_right
        if sw_total == 0.0 {
          1.0e300
        } else {
          (ss_left + ss_right) / sw_total
        }
      } else if !weighted {
        // v0.117.0: weighted Gini impurity, matching
        // `sklearn.tree.DecisionTreeClassifier`'s default
        // criterion. For binary labels, `gini = 1 - p^2 - (1-p)^2`
        // with `p` the node's mean label, which is exactly
        // `2 * p * (1 - p)`. The mean label doubles as the class
        // proportion, so the same accumulation serves both.
        let mut sum_left = 0.0
        for j = 0; j <= i; j = j + 1 {
          sum_left = sum_left + y[sorted_idx[j]]
        }
        let mut sum_right = 0.0
        for j = i + 1; j < n; j = j + 1 {
          sum_right = sum_right + y[sorted_idx[j]]
        }
        let p_left = sum_left / left_count.to_double()
        let p_right = sum_right / right_count.to_double()
        let gini_left = 2.0 * p_left * (1.0 - p_left)
        let gini_right = 2.0 * p_right * (1.0 - p_right)
        (
          left_count.to_double() * gini_left +
          right_count.to_double() * gini_right
        ) /
        n.to_double()
      } else {
        // v0.118.0: WEIGHTED Gini. `p` becomes the weighted class
        // proportion `SUM(w*y)/SUM(w)` and the child masses become
        // the weight sums rather than the row counts.
        let mut sum_left = 0.0
        let mut sw_left = 0.0
        for j = 0; j <= i; j = j + 1 {
          let row = sorted_idx[j]
          let wi = w[row]
          sum_left = sum_left + wi * y[row]
          sw_left = sw_left + wi
        }
        let mut sum_right = 0.0
        let mut sw_right = 0.0
        for j = i + 1; j < n; j = j + 1 {
          let row = sorted_idx[j]
          let wi = w[row]
          sum_right = sum_right + wi * y[row]
          sw_right = sw_right + wi
        }
        let sw_total = sw_left + sw_right
        if sw_total == 0.0 {
          1.0e300
        } else {
          let p_left = if sw_left == 0.0 { 0.0 } else { sum_left / sw_left }
          let p_right = if sw_right == 0.0 { 0.0 } else { sum_right / sw_right }
          let gini_left = 2.0 * p_left * (1.0 - p_left)
          let gini_right = 2.0 * p_right * (1.0 - p_right)
          (sw_left * gini_left + sw_right * gini_right) / sw_total
        }
      }
      if score < best_score {
        best_score = score
        best_feature = f
        best_threshold = threshold
        best_left = Array::makei(left_count, fn(j) { sorted_idx[j] })
        best_right = Array::makei(right_count, fn(j) { sorted_idx[j + i + 1] })
      }
      last_val = cur_val
    }
  }
  // If no valid split was found (all thresholds skipped),
  // this node is a leaf.
  if best_feature < 0 {
    return CART::Leaf(cart_leaf_value(y, sample_idx, hess, w))
  }
  let left_tree = cart_fit(
    x,
    y,
    best_left,
    depth + 1,
    max_depth,
    min_samples_leaf,
    mtry,
    feature_rng,
    clf,
    hess,
    w,
  )
  let right_tree = cart_fit(
    x,
    y,
    best_right,
    depth + 1,
    max_depth,
    min_samples_leaf,
    mtry,
    feature_rng,
    clf,
    hess,
    w,
  )
  CART::Split(best_feature, best_threshold, left_tree, right_tree)
}

///|
/// Per-leaf value. With `hess` empty this is the mean of `y` over
/// the rows in this node -- the v0.56.0 behaviour, and the right
/// leaf value for BOTH regression trees (constant predictor per
/// leaf) and Gini classification trees (where `mean(y)` over
/// binary labels IS the class proportion `P(y = 1 | node)`).
///
/// v0.117.0: when `hess` is non-empty the leaf becomes the Newton
/// step `SUM(y[idx]) / SUM(hess[idx])`, which is what
/// `GradientBoostingClassifier` uses in place of the mean. With
/// `y` holding the negative gradient and `hess` the second
/// derivative of the loss, that ratio maximises the local
/// quadratic approximation -- and it is NOT the mean of the
/// negative gradient, because the denominator varies by leaf.
///
/// Returns 0.0 for an empty sample (defensive; `cart_fit` should
/// never produce an empty sample because we early-return on
/// `n < 2 * min_samples_leaf`), and 0.0 rather than NaN when the
/// Newton denominator sums to zero -- reachable on a degenerate
/// leaf, which is exactly why the guard exists and not just
/// `if h == 0.0 { 1.0 }` as some implementations do.
fn cart_leaf_value(
  y : Array[Double],
  sample_idx : Array[Int],
  hess : Array[Double],
  w : Array[Double],
) -> Double {
  let n = sample_idx.length()
  if n == 0 {
    return 0.0
  }
  let weighted = w.length() > 0
  let mut s = 0.0
  if !weighted {
    // Unweighted: the v0.56.0 accumulation, verbatim.
    for i = 0; i < n; i = i + 1 {
      s = s + y[sample_idx[i]]
    }
    if hess.length() == 0 {
      return s / n.to_double()
    }
  } else {
    // Weighted: the SAME accumulation with `w` folded in. `s` ends
    // up as SUM(w*y) and the denominator as SUM(w).
    let mut sw = 0.0
    for i = 0; i < n; i = i + 1 {
      let row = sample_idx[i]
      let wi = w[row]
      s = s + wi * y[row]
      sw = sw + wi
    }
    if hess.length() == 0 {
      if sw == 0.0 {
        return 0.0
      }
      return s / sw
    }
    let mut h = 0.0
    for i = 0; i < n; i = i + 1 {
      h = h + w[sample_idx[i]] * hess[sample_idx[i]]
    }
    if h == 0.0 {
      return 0.0
    }
    return s / h
  }
  let mut h = 0.0
  for i = 0; i < n; i = i + 1 {
    h = h + hess[sample_idx[i]]
  }
  if h == 0.0 {
    return 0.0
  }
  s / h
}

///|
/// Sort `sample_idx` (length n) in-place-by-returning-a-new-
/// array, ordering indices by `x[idx, feature]`. Selection
/// sort: O(n^2), fine for the n ≤ 200 splits in our test
/// fixtures; for production scale, swap in introsort.
fn sort_indices_by_feature(
  x : Matrix,
  y : Array[Double],
  sample_idx : Array[Int],
  feature : Int,
) -> Array[Int] {
  let n = sample_idx.length()
  let out : Array[Int] = Array::makei(n, fn(i) { sample_idx[i] })
  // Insertion sort: stable, fast on small n.
  for i = 1; i < n; i = i + 1 {
    let key = out[i]
    let key_val = x.get(key, feature)
    let mut j = i - 1
    while j >= 0 && x.get(out[j], feature) > key_val {
      out[j + 1] = out[j]
      j = j - 1
    }
    out[j + 1] = key
  }
  ignore(y) // unused; sorted by feature value only
  out
}

// ---------------------------------------------------------------------------
// CART prediction (single row)
// ---------------------------------------------------------------------------

///|
/// Predict the per-tree value for row `i` of `x`. Recursive
/// descent through the tree; returns the leaf value at the
/// terminal node.
fn cart_predict(tree : CART, x : Matrix, row : Int) -> Double {
  match tree {
    CART::Leaf(v) => v
    CART::Split(f, t, l, r) =>
      if x.get(row, f) <= t {
        cart_predict(l, x, row)
      } else {
        cart_predict(r, x, row)
      }
  }
}

// ---------------------------------------------------------------------------
// Learner trait implementation
// ---------------------------------------------------------------------------

///|
/// Build the forest: `n_trees` bootstrap-sampled CART trees.
///
/// v0.118.0: the body moved to `fit_weighted`, which takes the
/// per-row weights and hands them to `cart_fit`. An EMPTY `w` takes
/// the verbatim unweighted arithmetic at every accumulation, so
/// `fit_weighted(x, y, [])` is byte-identical to the pre-v0.118.0
/// `fit`.
pub fn RFLearner::fit_weighted(
  self : RFLearner,
  x : Matrix,
  y : Array[Double],
  w : Array[Double],
) -> RFLearner {
  try {
    require(x.nrows == y.length())
    require(self.n_trees >= 1)
    require(self.max_depth >= 0)
    require(self.min_samples_leaf >= 1)
    require(w_is_unweighted(w) || w.length() == x.nrows)
    for i = 0; i < w.length(); i = i + 1 {
      require(w[i] >= 0.0)
    }
    let n_obs = x.nrows
    let n_features = x.ncols
    let trees : Array[CART] = []
    for b = 0; b < self.n_trees; b = b + 1 {
      let sample_idx = bootstrap_indices(n_obs, self.bootstrap_seed + b)
      // Use a distinct RNG stream per tree so the per-tree
      // feature sampling is independent of the bootstrap draws.
      let feature_rng = chacha8_rng(self.bootstrap_seed + self.n_trees + b)
      let tree = cart_fit(
        x,
        y,
        sample_idx,
        0,
        self.max_depth,
        self.min_samples_leaf,
        self.mtry,
        feature_rng,
        false,
        [],
        w,
      )
      trees.push(tree)
    }
    { ..self, trees, n_features, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Unweighted forest fit. v0.118.0 moved the body to `fit_weighted`;
/// this inherent method keeps every existing
/// `RFLearner::new(..).fit(x, y)` call site working, since an inherent
/// method wins over the trait method of the same name.
pub fn RFLearner::fit(
  self : RFLearner,
  x : Matrix,
  y : Array[Double],
) -> RFLearner {
  self.fit_weighted(x, y, [])
}

///|
impl Learner for RFLearner with fn fit(self, x, y, w) {
  self.fit_weighted(x, y, w)
}

///|
/// Predict by averaging per-tree leaf values. Output length
/// is `x.nrows`. Each row's prediction is `mean over all trees
/// of cart_predict(tree, x, row)`.
impl Learner for RFLearner with fn predict(self, x) {
  let n = x.nrows
  let out : Array[Double] = Array::make(n, 0.0)
  let n_trees = self.trees.length()
  if n_trees == 0 {
    // Unfitted learner: returns zeros. Caller should have
    // called `fit` first; this matches the lenient behavior
    // of v0.54.0 ConstantLearner / NoopLearner which also
    // return 0 on predict-without-fit.
    return out
  }
  for i = 0; i < n; i = i + 1 {
    let mut s = 0.0
    for t = 0; t < n_trees; t = t + 1 {
      s = s + cart_predict(self.trees[t], x, i)
    }
    out[i] = s / n_trees.to_double()
  }
  out
}
