///|
// v0.117.0 -- `RFClassifier`: pure-MoonBit random-forest CLASSIFICATION.
//
// # Why this exists
//
// v0.116.0 shipped `vce = "nn"` for RDD and, in the course of it,
// `examples/apo/` surfaced a systemic weakness that has nothing to do
// with RDD: `propensity_clip`'s default of `1e-6` is not safe against a
// propensity model that can extrapolate. Auditing the learner menu for
// that turned up a bigger structural gap.
//
// Every DML estimator's propensity nuisance `ml_m` is a CLASSIFIER when
// the treatment is binary. Upstream `doubleml` is learner-agnostic, so
// it accepts any `fit/predict` object and inherits scikit-learn's whole
// classifier surface -- `RandomForestClassifier` and
// `GradientBoostingClassifier` being the two most commonly plugged in.
//
// This port had exactly ONE classifier, `LogisticRegression`. Both tree
// learners (`rfl.mbt`, `gbl.mbt`) were regression-only: `rfl.mbt` splits
// on squared error, `gbl.mbt` uses squared-error loss. So for LPLR,
// DIDBinary, DIDCSBinary, RDD's fuzzy path and any binary-outcome IV
// problem there was no nonlinear option for `ml_m` at all.
//
// # Algorithm
//
// Breiman (2001) random forest, matching
// `sklearn.ensemble.RandomForestClassifier`:
//
//   - `n_trees` bootstrap samples of size `n_obs` (with replacement).
//   - At each node, `mtry` features are drawn WITHOUT replacement and
//     each is swept for the threshold minimising WEIGHTED GINI IMPURITY.
//     Gini, not MSE: `1 - p^2 - (1-p)^2 = 2p(1-p)` for binary labels,
//     which is the standard `DecisionTreeClassifier` default.
//   - A node whose labels are already pure is not split -- zero
//     impurity gain at every threshold.
//   - A leaf holds the node's mean label, which for binary `y` IS
//     `P(y = 1 | node)`.
//   - `predict` averages the per-tree leaf proportions, giving
//     `P(y = 1 | x)`.
//
// `mtry = -1` resolves to `floor(sqrt(n_features))`, the same default
// `RFLearner` uses and the same default modern scikit-learn uses for
// both regressor and classifier.
//
// # What `predict` returns, and why it matters here
//
// A CLASS PROBABILITY, not a 0/1 label. DML's AIPW correction divides
// the residual by the fitted propensity, so a hard 0.5 threshold would
// make the denominator 0 or 1 and destroy the estimator. This is the
// same reason `LogisticRegression::predict` returns `P(y = 1 | x)`.
//
// # Relation to `RFLearner`
//
// Shares the `CART` tree type, `bootstrap_indices`, `sort_indices_by_feature`
// and `cart_predict` from `rfl.mbt`. The only differences are the split
// criterion (Gini vs MSE) and the purity guard -- both reached through
// the `clf` flag added to `cart_fit` in v0.117.0, which leaves the
// regression arithmetic byte-identical.
//
// # Parameters and defaults follow scikit-learn
//
// | this                | scikit-learn                |
// |---------------------|-----------------------------|
// | `n_trees = 100`     | `n_estimators = 100`        |
// | `max_depth = 10`    | `max_depth = 10`            |
// | `min_samples_leaf = 5` | `min_samples_leaf = 1`   |
// | `mtry = -1`         | `max_features = "sqrt"`     |
//
// `min_samples_leaf` differs deliberately and is DOCUMENTED rather than
// silently inherited: this package's `RFLearner` uses 5, and dropping a
// tree learner to 1 leaf in a DML nuisance fit is an overfitting trap on
// small cross-fit folds. Both classifiers here use 5 to match their
// regression siblings, and `expand_v117_test.mbt` pins the resulting
// in-bag accuracy so the choice is visible rather than implicit.

///|
/// Random-forest classifier (binary). `predict` returns
/// `P(y = 1 | x)`, not a hard class label -- see the file header.
pub struct RFClassifier {
  n_trees : Int
  max_depth : Int
  min_samples_leaf : Int
  mtry : Int // -1 = floor(sqrt(n_features)) at fit time
  bootstrap_seed : Int
  // Fitted state (empty until `fit` is called).
  trees : Array[CART]
  n_features : Int // -1 = not yet fit
} derive(Debug)

///|
pub extend RFClassifier with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Promote the `Learner` trait methods as explicit methods so the
/// trait impls below are not reported as `unused_value` under
/// `--deny-warn`. Same pattern as `RFLearner`.
pub extend RFClassifier with Learner::{predict}

///|
pub fn RFClassifier::new(
  n_trees? : Int = 100,
  max_depth? : Int = 10,
  min_samples_leaf? : Int = 5,
  mtry? : Int = -1,
  bootstrap_seed? : Int = 3141,
) -> RFClassifier {
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
/// Number of feature columns the forest was fit on; -1 before fit.
pub fn RFClassifier::n_features(self : RFClassifier) -> Int {
  self.n_features
}

///|
/// Number of trees in the fitted forest; 0 before fit.
pub fn RFClassifier::n_trees(self : RFClassifier) -> Int {
  self.trees.length()
}

///|
/// Build the forest on binary labels. `y` must be in `{0, 1}` --
/// the Gini criterion and the leaf-proportion reading of the node mean
/// are both defined for that case only, and a multiclass `y` would
/// silently produce class proportions that are not probabilities.
///
/// Unlike the other learners in this package there is NO lenient
/// fallback here: a non-binary `y` aborts rather than returning a
/// plausible-looking probability. `LogisticRegression` is lenient for
/// historical reasons; this learner is new, and there is no
/// byte-compatibility to preserve.
///
/// v0.118.0: `w` carries per-row weights into `cart_fit`, which turns
/// both the leaf proportion and the Gini criterion into their WEIGHTED
/// forms -- scikit-learn's semantics. An EMPTY `w` keeps every
/// accumulation verbatim, so this is byte-identical to the v0.117.0
/// unweighted fit.
pub fn RFClassifier::fit_weighted(
  self : RFClassifier,
  x : Matrix,
  y : Array[Double],
  w : Array[Double],
) -> RFClassifier {
  try {
    require(x.nrows == y.length())
    require(self.n_trees >= 1)
    require(self.max_depth >= 0)
    require(self.min_samples_leaf >= 1)
    require(w_is_unweighted(w) || w.length() == x.nrows)
    for i = 0; i < y.length(); i = i + 1 {
      require(y[i] == 0.0 || y[i] == 1.0)
    }
    for i = 0; i < w.length(); i = i + 1 {
      require(w[i] >= 0.0)
    }
    let n_obs = x.nrows
    let n_features = x.ncols
    let trees : Array[CART] = []
    for b = 0; b < self.n_trees; b = b + 1 {
      let sample_idx = bootstrap_indices(n_obs, self.bootstrap_seed + b)
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
        true,
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
/// Unweighted fit. v0.118.0 moved the body to `fit_weighted`; this
/// inherent method keeps `RFClassifier::new(..).fit(x, y)` working.
pub fn RFClassifier::fit(
  self : RFClassifier,
  x : Matrix,
  y : Array[Double],
) -> RFClassifier {
  self.fit_weighted(x, y, [])
}

///|
impl Learner for RFClassifier with fn fit(self, x, y, w) {
  self.fit_weighted(x, y, w)
}

///|
/// Average the per-tree leaf proportions to get `P(y = 1 | x)`.
impl Learner for RFClassifier with fn predict(self, x) {
  let n = x.nrows
  let out : Array[Double] = Array::make(n, 0.0)
  let n_trees = self.trees.length()
  // Unfitted learner returns zeros, matching `RFLearner`.
  if n_trees == 0 {
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
