///|
// Path A — `GBLearner` (gradient-boosting regression learner).
// v0.57.0+.
//
// Pure-MoonBit gradient boosting regression (Friedman 2001).
// Reuses the CART tree + bootstrap_indices / cart_fit /
// cart_predict helpers from `rfl.mbt` (the random-forest
// sibling learner in the same package). Standard
// gradient-boosting regression algorithm:
//
//   F_0(x) = mean(y)        // initial constant prediction
//   for r in 1..n_trees:
//     r_i = y_i - F_{r-1}(x_i)               // pseudo-residual
//     h_r = cart_fit(x, r, ...)              // fit CART to residuals
//     F_r(x) = F_{r-1}(x) + learning_rate * h_r(x)
//   predict(x) = F_0 + sum_{r=1..n_trees} learning_rate * h_r(x_i)
//
// Algorithm uses squared-error loss with the negative gradient
// being the raw residual `y - F_{r-1}(x)` (Friedman §4.4).
// Initial F_0 = mean(y) is the optimal constant predictor under
// squared error; this matches sklearn's
// `GradientBoostingRegressor(init=None)` default.
//
// Hyperparameters:
//   - n_trees           : number of boosting rounds (= n_estimators
//                          in sklearn) (default 100)
//   - learning_rate     : shrinkage factor applied to each tree
//                          contribution (default 0.1)
//   - max_depth         : maximum CART depth (default 3, the
//                          shallow-tree default for boosting)
//   - min_samples_leaf  : CART min_samples_leaf (default 5)
//   - mtry              : feature subsampling per CART node
//                          (default -1 = floor(sqrt(n_features)),
//                          matching RFLearner)
//   - subsample         : row subsampling fraction per tree
//                          (default 1.0 = no subsampling; the
//                          stochastic-GB generalization is at
//                          subsample < 1.0; left at 1.0 here for
//                          parity with sklearn's default)
//   - bootstrap_seed    : base seed for bootstrap + per-tree
//                          feature sampling RNGs (default 3141)
//
// `mtry = -1` resolves to `floor(sqrt(n_features))` at `fit`
// time, same convention as `RFLearner`. Fitted state is empty
// (no trees) until `fit` is called.

///|
/// Gradient boosting learner (regression).
pub struct GBLearner {
  n_trees : Int
  learning_rate : Double
  max_depth : Int
  min_samples_leaf : Int
  mtry : Int // -1 = floor(sqrt(n_features)) at fit time
  subsample : Double // row subsampling fraction per tree (default 1.0)
  bootstrap_seed : Int
  // Fitted state (empty until `fit` is called).
  initial : Double // = mean(y) at fit time
  trees : Array[CART] // CART tree per boosting round
} derive(Debug)

///|
pub extend GBLearner with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Promote `Learner` trait methods as explicit methods on
/// `GBLearner` so the trait impl below doesn't trip
/// `unused_value` under `--deny-warn`. Same pattern as the
/// v0.54.0 `ConstantLearner` / `NoopLearner` and v0.56.0
/// `RFLearner` setup.
pub extend GBLearner with Learner::{fit, predict}

///|
pub fn GBLearner::new(
  n_trees? : Int = 100,
  learning_rate? : Double = 0.1,
  max_depth? : Int = 3,
  min_samples_leaf? : Int = 5,
  mtry? : Int = -1,
  subsample? : Double = 1.0,
  bootstrap_seed? : Int = 3141,
) -> GBLearner {
  {
    n_trees,
    learning_rate,
    max_depth,
    min_samples_leaf,
    mtry,
    subsample,
    bootstrap_seed,
    initial: 0.0,
    trees: [],
  }
}

///|
/// Number of trees in the fitted ensemble. Returns 0 if not
/// yet fit.
pub fn GBLearner::n_trees(self : GBLearner) -> Int {
  self.trees.length()
}

///|
/// Initial constant prediction (mean of y at fit time).
/// Returns 0.0 before fit.
pub fn GBLearner::initial(self : GBLearner) -> Double {
  self.initial
}

// ---------------------------------------------------------------------------
// Learner trait implementation
// ---------------------------------------------------------------------------

///|
/// Fit the gradient-boosting ensemble. Builds `n_trees` CART
/// trees sequentially, each fitted to the negative gradient
/// (residual) of the current ensemble.
impl Learner for GBLearner with fn fit(self, x, y) {
  try {
    require(x.nrows == y.length())
    require(self.n_trees >= 1)
    require(self.max_depth >= 0)
    require(self.min_samples_leaf >= 1)
    require(self.learning_rate > 0.0 && self.learning_rate <= 1.0)
    require(self.subsample > 0.0 && self.subsample <= 1.0)
    let n_obs = x.nrows
    // Initial F_0 = mean(y) (squared-error-optimal constant).
    let mut sum_y = 0.0
    for i = 0; i < n_obs; i = i + 1 {
      sum_y = sum_y + y[i]
    }
    let initial = sum_y / n_obs.to_double()
    // current_pred[i] = F_r(x_i) at round r; start with F_0.
    let current_pred : Array[Double] = Array::make(n_obs, initial)
    let trees : Array[CART] = []
    for r = 0; r < self.n_trees; r = r + 1 {
      // Residual r_i = y_i - current_pred[i].
      let residual : Array[Double] = Array::make(n_obs, 0.0)
      for i = 0; i < n_obs; i = i + 1 {
        residual[i] = y[i] - current_pred[i]
      }
      // Optional subsample: stochastic GB generalisation
      // (Friedman 1999). With subsample=1.0 (default), all rows
      // participate. With subsample<1.0, take a bootstrap-style
      // random subset of size floor(n_obs * subsample).
      let sample_idx : Array[Int] = if self.subsample < 1.0 {
        let n_sub = (n_obs.to_double() * self.subsample).to_int()
        let n_sub_eff = if n_sub < 1 {
          1
        } else if n_sub > n_obs {
          n_obs
        } else {
          n_sub
        }
        let full = bootstrap_indices(n_obs, self.bootstrap_seed + r)
        Array::makei(n_sub_eff, fn(j) { full[j] })
      } else {
        Array::makei(n_obs, fn(i) { i })
      }
      // Fit CART on the residual using the sample_idx slice.
      // Need to extract (x, residual) restricted to sample_idx.
      let x_sub : Matrix = {
        nrows: sample_idx.length(),
        ncols: x.ncols,
        data: Array::make(sample_idx.length() * x.ncols, 0.0),
      }
      for j = 0; j < sample_idx.length(); j = j + 1 {
        for k = 0; k < x.ncols; k = k + 1 {
          x_sub.data[j * x.ncols + k] = x.data[sample_idx[j] * x.ncols + k]
        }
      }
      let y_sub : Array[Double] = Array::make(sample_idx.length(), 0.0)
      for j = 0; j < sample_idx.length(); j = j + 1 {
        y_sub[j] = residual[sample_idx[j]]
      }
      let feature_rng = chacha8_rng(self.bootstrap_seed + self.n_trees + r)
      let tree = cart_fit(
        x_sub,
        y_sub,
        Array::makei(sample_idx.length(), fn(j) { j }),
        0,
        self.max_depth,
        self.min_samples_leaf,
        self.mtry,
        feature_rng,
        false,
        [],
      )
      trees.push(tree)
      // Update current_pred[i] += learning_rate * tree(x[i]).
      for i = 0; i < n_obs; i = i + 1 {
        current_pred[i] = current_pred[i] +
          self.learning_rate * cart_predict(tree, x, i)
      }
    }
    { ..self, initial, trees, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Predict by summing initial + sum of (learning_rate * leaf
/// value) across all trees for each row. Unfitted learner
/// returns zeros (lenient fallback matching RFLearner /
/// ConstantLearner / NoopLearner).
impl Learner for GBLearner with fn predict(self, x) {
  let n = x.nrows
  let out : Array[Double] = Array::make(n, self.initial)
  let n_trees = self.trees.length()
  if n_trees == 0 {
    return out
  }
  for i = 0; i < n; i = i + 1 {
    for t = 0; t < n_trees; t = t + 1 {
      out[i] = out[i] + self.learning_rate * cart_predict(self.trees[t], x, i)
    }
  }
  out
}
