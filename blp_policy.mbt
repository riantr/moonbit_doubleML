///|
/// Best linear predictor of an orthogonal signal on a supplied basis.
///
/// `cov_type` selects the standard-error convention. Valid values:
///   - `"HC0"` (default): White's heteroskedasticity-consistent
///     sandwich SE — robust to arbitrary residual heteroskedasticity.
///     Matches the upstream `doubleml.utils.blp` call to
///     `statsmodels.OLS(cov_type='HC0')`.
///   - `"nonrobust"`: classic homoskedastic OLS SE
///     (`sigma^2 * (X^T X)^{-1}` with `sigma^2 = RSS / (n - p)`),
///     which is only valid under the homogeneous-error assumption.
///
/// REVIEW L5: the field is currently stored on the struct for forward
/// compatibility (post-fit introspection), but is not used outside
/// `fit`. Construct via `DoubleMLBLP::new` to validate the value.
pub struct DoubleMLBLP {
  basis : Matrix
  orth_signal : Array[Double]
  cov_type : String
  coef : Array[Double]
  se : Array[Double]
  fitted : Bool
} derive(Debug)

///|
pub fn DoubleMLBLP::new(
  basis : Matrix,
  orth_signal : Array[Double],
  cov_type? : String = "HC0",
) -> DoubleMLBLP {
  require(basis.rows() == orth_signal.length())
  require(cov_type == "HC0" || cov_type == "nonrobust")
  { basis, orth_signal, cov_type, coef: [], se: [], fitted: false }
}

///|
pub fn DoubleMLBLP::fit(self : DoubleMLBLP) -> DoubleMLBLP {
  let model = LinearRegression::new().fit(self.basis, self.orth_signal)
  let c = model.coefficients()
  let p = c.length()
  let s = Array::make(p, 0.0)
  // Per-coefficient SE. Two flavours:
  //   - HC0 (sandwich, default): `cov_jj = sum_i ((M[j,:] x_i)^2 * e_i^2)`
  //     matches upstream `statsmodels.OLS(cov_type='HC0')`. Robust
  //     to arbitrary heteroskedasticity.
  //   - nonrobust: `cov_jj = sigma^2 * (X^T X)^{-1}_{jj}` with
  //     `sigma^2 = RSS / (n - p)` (homogeneous-error assumption).
  // Bug #5 fix landed the per-coefficient SE; TODO #11c.1 promoted the
  // default to HC0 to match upstream.
  let n_obs = self.orth_signal.length()
  let cov_diag = if self.cov_type == "HC0" {
    model.sandwich_se(self.basis, self.orth_signal)
  } else {
    let pred = model.predict(self.basis)
    let mut rss = 0.0
    for i = 0; i < pred.length(); i = i + 1 {
      let e = self.orth_signal[i] - pred[i]
      rss = rss + e * e
    }
    let sigma2 = rss / (n_obs.to_double() - p.to_double())
    model.covariance_diagonal(sigma2)
  }
  for j = 0; j < p; j = j + 1 {
    s[j] = cov_diag[j].sqrt()
  }
  {
    basis: self.basis,
    orth_signal: self.orth_signal,
    cov_type: self.cov_type,
    coef: c,
    se: s,
    fitted: true,
  }
}

///|
pub fn DoubleMLBLP::coef(self : DoubleMLBLP) -> Array[Double] {
  require(self.fitted)
  self.coef
}

///|
pub fn DoubleMLBLP::se(self : DoubleMLBLP) -> Array[Double] {
  require(self.fitted)
  self.se
}

///|
/// A binary tree node used by `DoubleMLPolicyTree`. A `Leaf` is a
/// terminal that always returns the given treatment. A `Split` carries
/// the split feature, the threshold value, and the two child nodes.
/// Internal-only (not exposed in the public API) so the public
/// `DoubleMLPolicyTree` signature is unchanged from the depth-1 era.
pub enum PolicyTreeNode {
  Leaf(Int)
  Split(Int, Double, PolicyTreeNode, PolicyTreeNode)
} derive(Debug)

///|
/// Recursively compute the variance-reduction gain for the best split
/// at the given depth. At `depth == 1` (the leaf level) we stop and
/// return the leaf treatment (sign of the mean signal). At deeper
/// levels we expand the recursion by one level.
fn policy_tree_build(
  features : Matrix,
  signal : Array[Double],
  depth : Int,
) -> PolicyTreeNode {
  let n = signal.length()
  if n == 0 {
    return Leaf(0)
  }
  // depth=0 means: this subtree is a leaf (no further splitting).
  // The build call at the root always passes `depth=self.depth` and
  // recurses with `depth-1`, so depth=1 builds a Split whose
  // children are leaves (depth-1 stump), depth=2 builds a Split
  // whose children are depth-1 stumps, etc.
  if depth == 0 {
    let mut sum = 0.0
    for s in signal {
      sum = sum + s
    }
    let mean = sum / n.to_double()
    return Leaf(if mean >= 0.0 { 1 } else { 0 })
  }
  // find the best-split feature and threshold
  let mut best = -1.0e308
  let mut bf = -1
  let mut bv = 0.0
  let mut bnl = 0
  let mut bnr = 0
  for j = 0; j < features.cols(); j = j + 1 {
    let mut threshold = 0.0
    for i = 0; i < n; i = i + 1 {
      threshold = threshold + features.get(i, j)
    }
    threshold = threshold / n.to_double()
    let mut sl = 0.0
    let mut sr = 0.0
    let mut nl = 0
    let mut nr = 0
    let mut ssl = 0.0
    let mut ssr = 0.0
    for i = 0; i < n; i = i + 1 {
      if features.get(i, j) < threshold {
        sl = sl + signal[i]
        ssl = ssl + signal[i] * signal[i]
        nl = nl + 1
      } else {
        sr = sr + signal[i]
        ssr = ssr + signal[i] * signal[i]
        nr = nr + 1
      }
    }
    let gain = if nl > 0 && nr > 0 {
      let mean_l = sl / nl.to_double()
      let mean_r = sr / nr.to_double()
      let var_l = ssl / nl.to_double() - mean_l * mean_l
      let var_r = ssr / nr.to_double() - mean_r * mean_r
      -(nl.to_double() / n.to_double()) * var_l -
      nr.to_double() / n.to_double() * var_r
    } else {
      -1.0e308
    }
    if gain > best {
      best = gain
      bf = j
      bv = threshold
      bnl = nl
      bnr = nr
    }
  }
  // If no split improves, return a leaf
  if bf < 0 {
    let mut sum = 0.0
    for s in signal {
      sum = sum + s
    }
    let mean = sum / n.to_double()
    return Leaf(if mean >= 0.0 { 1 } else { 0 })
  }
  // Build left and right sub-feature matrices / sub-signal arrays
  let left_signal : Array[Double] = Array::make(bnl, 0.0)
  let right_signal : Array[Double] = Array::make(bnr, 0.0)
  let left_idx : Array[Int] = []
  let right_idx : Array[Int] = []
  for i = 0; i < n; i = i + 1 {
    if features.get(i, bf) < bv {
      left_signal[left_idx.length()] = signal[i]
      left_idx.push(i)
    } else {
      right_signal[right_idx.length()] = signal[i]
      right_idx.push(i)
    }
  }
  // Build sub-feature matrices (same columns, fewer rows)
  let left_features = Matrix::zeros(bnl, features.cols())
  let right_features = Matrix::zeros(bnr, features.cols())
  for k = 0; k < bnl; k = k + 1 {
    for j = 0; j < features.cols(); j = j + 1 {
      left_features.data[k * features.cols() + j] = features.get(left_idx[k], j)
    }
  }
  for k = 0; k < bnr; k = k + 1 {
    for j = 0; j < features.cols(); j = j + 1 {
      right_features.data[k * features.cols() + j] = features.get(
        right_idx[k],
        j,
      )
    }
  }
  let left = policy_tree_build(left_features, left_signal, depth - 1)
  let right = policy_tree_build(right_features, right_signal, depth - 1)
  Split(bf, bv, left, right)
}

///|
/// Walk the policy tree to find the leaf treatment for one row.
fn policy_tree_predict(node : PolicyTreeNode, x : Matrix, row : Int) -> Int {
  match node {
    Leaf(t) => t
    Split(feature, threshold, left, right) =>
      if x.get(row, feature) < threshold {
        policy_tree_predict(left, x, row)
      } else {
        policy_tree_predict(right, x, row)
      }
  }
}

///|
/// A compact policy tree. It searches one split per level using weighted
/// variance-reduction gain (Bug #8); the `depth` parameter controls
/// how many levels of recursion to use (TODO #11c.3: previously the
/// `depth` field was unused and the fit was always a depth-1 stump).
pub struct DoubleMLPolicyTree {
  features : Matrix
  orth_signal : Array[Double]
  depth : Int
  // The fitted tree root. `Leaf(_)` means a single treatment for
  // all rows (depth=1 with no useful split, or depth exhaustion).
  root : PolicyTreeNode
  // The depth-1 public surface retained for backward compatibility:
  //   - `split_feature` and `split_value` are the root split if the
  //     root is a Split node, else -1 / 0.0.
  //   - `left_treatment` / `right_treatment` are the leaf treatments
  //     at the depth-1 layer; for depth > 1 they are the leaf
  //     treatments of the immediate left/right children.
  split_feature : Int
  split_value : Double
  left_treatment : Int
  right_treatment : Int
  fitted : Bool
} derive(Debug)

///|
pub fn DoubleMLPolicyTree::new(
  features : Matrix,
  orth_signal : Array[Double],
  depth? : Int = 1,
) -> DoubleMLPolicyTree {
  require(features.rows() == orth_signal.length())
  require(depth >= 1)
  {
    features,
    orth_signal,
    depth,
    root: Leaf(0),
    split_feature: -1,
    split_value: 0.0,
    left_treatment: 0,
    right_treatment: 0,
    fitted: false,
  }
}

///|
/// Extract the depth-1 left/right leaf treatments from the root. If
/// the root is itself a leaf, both sides get the same treatment.
fn policy_root_lr_treatments(root : PolicyTreeNode) -> (Int, Int) {
  match root {
    Leaf(t) => (t, t)
    Split(_, _, left, right) =>
      match (left, right) {
        (Leaf(l), Leaf(r)) => (l, r)
        (Leaf(l), _) => (l, l)
        (_, Leaf(r)) => (r, r)
        _ => (0, 0)
      }
  }
}

///|
pub fn DoubleMLPolicyTree::fit(self : DoubleMLPolicyTree) -> DoubleMLPolicyTree {
  let root = policy_tree_build(self.features, self.orth_signal, self.depth)
  let (split_feature, split_value) = match root {
    Leaf(_) => (-1, 0.0)
    Split(feature, threshold, _, _) => (feature, threshold)
  }
  let (lt, rt) = policy_root_lr_treatments(root)
  {
    features: self.features,
    orth_signal: self.orth_signal,
    depth: self.depth,
    root,
    split_feature,
    split_value,
    left_treatment: lt,
    right_treatment: rt,
    fitted: true,
  }
}

///|
pub fn DoubleMLPolicyTree::predict(
  self : DoubleMLPolicyTree,
  x : Matrix,
) -> Array[Int] {
  require(self.fitted)
  let out = Array::make(x.rows(), 0)
  for i = 0; i < x.rows(); i = i + 1 {
    out[i] = policy_tree_predict(self.root, x, i)
  }
  out
}

///|
pub fn DoubleMLPolicyTree::split_feature(self : DoubleMLPolicyTree) -> Int {
  require(self.fitted)
  self.split_feature
}

///|
pub fn DoubleMLPolicyTree::split_value(self : DoubleMLPolicyTree) -> Double {
  require(self.fitted)
  self.split_value
}
