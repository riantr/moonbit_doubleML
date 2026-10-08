///|
// v0.117.0 -- `GBClassifier`: pure-MoonBit gradient-boosting
// CLASSIFICATION with binary log loss.
//
// # Why this exists
//
// The `RFClassifier` companion; see `rfclf.mbt` for why the package
// needed a nonlinear classifier for the propensity nuisance at all.
// This is the boosting half, so `ml_m` can be either a bagged or a
// boosted nonlinear classifier.
//
// # Algorithm
//
// Friedman (2001) gradient boosting under BINARY LOG LOSS, matching
// `sklearn.ensemble.GradientBoostingClassifier` with its modern
// default `loss="log_loss"`:
//
//   F_0(x) = log(pbar / (1 - pbar))       // log-odds of the base rate
//   for r in 1..n_trees:
//     p_i     = sigmoid(F_{r-1}(x_i))
//     g_i     = y_i - p_i                 // negative gradient
//     h_i     = p_i * (1 - p_i)           // second derivative
//     h_r     = cart_fit(x, g, ..., hess = h)   // MSE splits, Newton leaf
//     F_r(x) = F_{r-1}(x) + learning_rate * h_r(x)
//   predict(x) = sigmoid(F(x))
//
// # Three things that are easy to get wrong
//
// 1. **The initial constant is the log-ODDS, not the base rate.**
//    Squared error wants `F_0 = mean(y)`; log loss wants
//    `log(pbar/(1-pbar))`. Reusing the regression learner's `F_0`
//    silently mis-calibrates every prediction.
//
// 2. **The leaf is the Newton step, not the mean.** This is the whole
//    reason `cart_fit` gained a `hess` argument in v0.117.0. A leaf
//    value of `mean(g)` ignores that the local curvature `mean(h)`
//    differs per leaf, so high-uncertainty leaves get the same step as
//    confident ones. `gbl.mbt` (squared error) is unaffected because
//    there `h` is constant.
//
// 3. **Splits still use MSE, not Gini.** scikit-learn fits a
//    `DecisionTreeRegressor` to the negative gradient and overrides
//    only the leaf values. So `clf = false` here even though this is a
//    classifier -- using Gini here would be a plausible-looking
//    deviation that produces a different model.
//
// # Degenerate cases, handled rather than hoped away
//
// - `pbar == 0` or `pbar == 1` (a perfectly separated training fold)
//   would make `log(pbar/(1-pbar))` infinite. The `pbar` is clamped
//   into `[eps, 1-eps]` with `eps = 1e-9`, which is the same guard
//   `logistic.mbt` uses for the same reason.
// - A leaf whose hessian sum is zero returns 0.0 rather than NaN; see
//   `cart_leaf_value`. This is reachable when `p` saturates to 0 or 1
//   on every row in a leaf, i.e. a confident pure leaf, which is
//   exactly where a Newton step would otherwise be 0/0.
//
// # Parameters and defaults follow scikit-learn
//
// | this                | scikit-learn                    |
// |---------------------|---------------------------------|
// | `n_trees = 100`     | `n_estimators = 100`            |
// | `learning_rate = 0.1` | `learning_rate = 0.1`         |
// | `max_depth = 3`     | `max_depth = 3`                 |
// | `min_samples_leaf = 5` | `min_samples_leaf = 1`       |
// | `subsample = 1.0`   | `subsample = 1.0`               |
//
// `min_samples_leaf` is 5 to match `GBLearner` rather than
// scikit-learn's 1, for the overfitting reason given in `rfclf.mbt`.

///|
/// Gradient-boosting classifier (binary log loss). `predict` returns
/// `P(y = 1 | x)`.
pub struct GBClassifier {
  n_trees : Int
  learning_rate : Double
  max_depth : Int
  min_samples_leaf : Int
  mtry : Int // -1 = floor(sqrt(n_features)) at fit time
  subsample : Double
  bootstrap_seed : Int
  // Fitted state.
  initial : Double // log-odds of the base rate
  base_rate : Double // pbar, kept for the accessor's sake
  trees : Array[CART]
} derive(Debug)

///|
pub extend GBClassifier with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Promote the `Learner` trait methods as explicit methods so the
/// trait impl below is not reported as `unused_value` under
/// `--deny-warn`. Same pattern as `GBLearner`.
pub extend GBClassifier with Learner::{fit, predict}

///|
pub fn GBClassifier::new(
  n_trees? : Int = 100,
  learning_rate? : Double = 0.1,
  max_depth? : Int = 3,
  min_samples_leaf? : Int = 5,
  mtry? : Int = -1,
  subsample? : Double = 1.0,
  bootstrap_seed? : Int = 3141,
) -> GBClassifier {
  {
    n_trees,
    learning_rate,
    max_depth,
    min_samples_leaf,
    mtry,
    subsample,
    bootstrap_seed,
    initial: 0.0,
    base_rate: 0.0,
    trees: [],
  }
}

///|
/// Number of trees in the fitted ensemble; 0 before fit.
pub fn GBClassifier::n_trees(self : GBClassifier) -> Int {
  self.trees.length()
}

///|
/// The initial constant `F_0` in LOG-ODDS, 0.0 before fit. This is
/// the v0.117.0 point that differs from `GBLearner::initial`, which
/// returns the mean under squared error.
pub fn GBClassifier::initial(self : GBClassifier) -> Double {
  self.initial
}

///|
/// The base rate `pbar = mean(y)`, 0.0 before fit.
pub fn GBClassifier::base_rate(self : GBClassifier) -> Double {
  self.base_rate
}

///|
// The logistic link is `sigmoid`, which already lives in
// `logistic.mbt` at package scope and is reused rather than
// duplicated. A second definition here would not compile -- MoonBit's
// top-level `fn` is package-scoped, so a "file-private" helper is
// still a whole-package name. The doubling-up is worth noting because
// the same numerically-safe formulation is easy to re-derive without
// noticing, and the reason the tails matter here is specific: the
// Newton hessian `p (1 - p)` goes to 0 as `p` saturates, and an
// `expit` that underflows to exactly 1.0 would zero it out.

///|
/// Fit the boosting ensemble under binary log loss. `y` must be in
/// `{0, 1}`; see `RFClassifier::fit` for why this learner refuses
/// rather than silently accepts.
impl Learner for GBClassifier with fn fit(self, x, y) {
  try {
    require(x.nrows == y.length())
    require(self.n_trees >= 1)
    require(self.max_depth >= 0)
    require(self.min_samples_leaf >= 1)
    require(self.learning_rate > 0.0 && self.learning_rate <= 1.0)
    require(self.subsample > 0.0 && self.subsample <= 1.0)
    for i = 0; i < y.length(); i = i + 1 {
      require(y[i] == 0.0 || y[i] == 1.0)
    }
    let n_obs = x.nrows
    // Base rate, clamped away from the open endpoints so the log-odds
    // below stays finite on a perfectly separated fold.
    let eps = 1.0e-9
    let mut sum_y = 0.0
    for i = 0; i < n_obs; i = i + 1 {
      sum_y = sum_y + y[i]
    }
    let raw_p = sum_y / n_obs.to_double()
    let base_rate = if raw_p < eps {
      eps
    } else if raw_p > 1.0 - eps {
      1.0 - eps
    } else {
      raw_p
    }
    let initial = @math.ln(base_rate / (1.0 - base_rate))
    // F_r(x_i), on the log-odds scale.
    let current_pred : Array[Double] = Array::make(n_obs, initial)
    let trees : Array[CART] = []
    for r = 0; r < self.n_trees; r = r + 1 {
      // Negative gradient and second derivative of the log loss.
      let neg_grad : Array[Double] = Array::make(n_obs, 0.0)
      let hess : Array[Double] = Array::make(n_obs, 0.0)
      for i = 0; i < n_obs; i = i + 1 {
        let p = sigmoid(current_pred[i])
        neg_grad[i] = y[i] - p
        hess[i] = p * (1.0 - p)
      }
      // Optional row subsampling (Friedman 1999 stochastic GB).
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
        y_sub[j] = neg_grad[sample_idx[j]]
      }
      // The hessian has to be indexed by the SAME row numbering the
      // tree sees, i.e. after the subsample remap.
      let hess_sub : Array[Double] = Array::make(sample_idx.length(), 0.0)
      for j = 0; j < sample_idx.length(); j = j + 1 {
        hess_sub[j] = hess[sample_idx[j]]
      }
      let feature_rng = chacha8_rng(self.bootstrap_seed + self.n_trees + r)
      // `clf = false`: splits use MSE on the negative gradient, which
      // is what scikit-learn fits (a DecisionTreeRegressor). Only the
      // leaf values are Newton steps, via `hess_sub`.
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
        hess_sub,
      )
      trees.push(tree)
      for i = 0; i < n_obs; i = i + 1 {
        current_pred[i] = current_pred[i] +
          self.learning_rate * cart_predict(tree, x, i)
      }
    }
    { ..self, initial, base_rate, trees, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// `sigmoid(F(x))` -- the class probability, never the raw margin.
impl Learner for GBClassifier with fn predict(self, x) {
  let n = x.nrows
  let n_trees = self.trees.length()
  if n_trees == 0 {
    // Unfitted: return the base rate implied by F_0 rather than zeros,
    // so the "constant predictor" fallback is still a probability.
    let out : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      out[i] = sigmoid(self.initial)
    }
    return out
  }
  let out : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let mut f = self.initial
    for t = 0; t < n_trees; t = t + 1 {
      f = f + self.learning_rate * cart_predict(self.trees[t], x, i)
    }
    out[i] = sigmoid(f)
  }
  out
}
