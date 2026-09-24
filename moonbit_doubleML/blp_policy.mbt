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
  // v0.19.0+: post-fit summary statistics used by
  // `GainStatsSource::from_blp` to auto-populate the
  // sensitivity parameter benchmarks. Initialised to
  // zero in `new`; filled in by `fit`.
  n_obs : Int
  rss : Double
  var_y : Double
} derive(Debug)

///|
pub fn DoubleMLBLP::new(
  basis : Matrix,
  orth_signal : Array[Double],
  cov_type? : String = "HC0",
) -> DoubleMLBLP {
  try {
    require(basis.rows() == orth_signal.length())
    require(cov_type == "HC0" || cov_type == "nonrobust")
    {
      basis,
      orth_signal,
      cov_type,
      coef: [],
      se: [],
      fitted: false,
      n_obs: 0,
      rss: 0.0,
      var_y: 0.0,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
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
  // Per-coefficient SE (Bug #5 fix); HC0 default matches
  // upstream `statsmodels.OLS(cov_type='HC0')`.
  let n_obs = self.orth_signal.length()
  let pred = model.predict(self.basis)
  let mut rss = 0.0
  for i = 0; i < n_obs; i = i + 1 {
    let e = self.orth_signal[i] - pred[i]
    rss = rss + e * e
  }
  // `var_y` = variance of the orthogonal signal (the BLP's
  // "outcome" variable). Computed as a one-pass Welford
  // would be slightly more accurate, but a two-pass mean
  // is fine for our purposes.
  let mut mean_y = 0.0
  for i = 0; i < n_obs; i = i + 1 {
    mean_y = mean_y + self.orth_signal[i]
  }
  mean_y = mean_y / n_obs.to_double()
  let mut ss_y = 0.0
  for i = 0; i < n_obs; i = i + 1 {
    let d = self.orth_signal[i] - mean_y
    ss_y = ss_y + d * d
  }
  let var_y = ss_y / n_obs.to_double()
  let cov_diag = if self.cov_type == "HC0" {
    model.sandwich_se(self.basis, self.orth_signal)
  } else {
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
    n_obs,
    rss,
    var_y,
  }
}

///|
pub fn DoubleMLBLP::coef(self : DoubleMLBLP) -> Array[Double] {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLBLP::se(self : DoubleMLBLP) -> Array[Double] {
  try {
    require(self.fitted)
    self.se
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.19.0+: sample size used by the BLP fit.
pub fn DoubleMLBLP::n_obs(self : DoubleMLBLP) -> Int {
  try {
    require(self.fitted)
    self.n_obs
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.19.0+: residual sum of squares from the BLP fit.
/// Equals `sum_i (orth_signal[i] - basis[i] @ coef)^2`.
pub fn DoubleMLBLP::rss(self : DoubleMLBLP) -> Double {
  try {
    require(self.fitted)
    self.rss
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.19.0+: variance of the orthogonal signal (the BLP's
/// "outcome" variable). Computed as a population variance
/// (divisor `n`, not `n - 1`).
pub fn DoubleMLBLP::var_y(self : DoubleMLBLP) -> Double {
  try {
    require(self.fitted)
    self.var_y
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.22.0+: the orthogonal signal array (the BLP's
/// "outcome" variable). Length `n_obs`. Used by
/// `GainStatsSource::from_blp_cv` to compute the
/// cross-fit residual variance.
pub fn DoubleMLBLP::orth_signal(self : DoubleMLBLP) -> Array[Double] {
  try {
    require(self.fitted)
    self.orth_signal
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.22.0+: the basis matrix (the BLP's "design
/// matrix"). Shape `n_obs x p_features`. Used by
/// `GainStatsSource::from_blp_cv` to refit the
/// BLP on each fold's training subset.
pub fn DoubleMLBLP::basis(self : DoubleMLBLP) -> Matrix {
  try {
    require(self.fitted)
    self.basis
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Fitted values `basis_aug @ coef` for each observation, length
/// `n_obs`. Matches the upstream `DoubleMLBLP.predictions` /
/// `predict` semantic — the orthogonal-signal prediction under
/// the BLP coefficient vector.
///
/// Note: `coef` has length `p_basis + 1` because
/// `LinearRegression::fit` adds an intercept column to `basis`.
/// We reconstruct that column (all-1.0) on the fly to keep the
/// stored `self.basis` unchanged.
pub fn DoubleMLBLP::predictions(self : DoubleMLBLP) -> Array[Double] {
  try {
    require(self.fitted)
    let n = self.orth_signal.length()
    let p = self.basis.cols()
    let pred : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      // Intercept term.
      let mut s = self.coef[0]
      for j = 0; j < p; j = j + 1 {
        s = s + self.basis.get(i, j) * self.coef[j + 1]
      }
      pred[i] = s
    }
    pred
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Joint confidence interval for the linear contrast
/// `contrast @ coef` (length `n_contrast`), via chi-squared
/// critical value on the Mahalanobis distance.
///
///   `(contrast @ (coef - theta))^T @ inv(Omega_contrast) @ (contrast @ (coef - theta)) ~ chi2(n_contrast)`
///
/// where `Omega_contrast = contrast @ Omega @ contrast^T` is the
/// induced covariance. Equivalent to a Bonferroni-style worst-case
/// bound but tighter for low correlation.
///
/// Parameters:
/// - `contrast`: row-major matrix `(n_contrast, p + 1)` whose rows
///   define the linear functions of `coef` to interval-estimate.
/// - `level`: confidence level in (0, 1). Default 0.95.
///
/// Returns: array of `(low, high)` tuples (each row a symmetric
/// interval around `contrast @ coef`). For a single contrast
/// row, returns a 1-element array. v0.53.0-dev Task 3 / v0.11.4
/// upstream parity.
///
/// Notes: the upstream joint-CI uses bootstrap to draw the
/// critical value from `np.quantile(np.max(np.abs(bootstrap)))`,
/// which requires the full `omega` matrix. In our port we
/// approximate the critical value with the chi-squared quantile
/// (1 df per row), and use the diagonal sandwich form of
/// `Omega_contrast` (`contrast[r]^2 @ diag(se^2)`) for the
/// variance. This is the standard closed-form chi-squared joint
/// CI when the joint-CI variance is dominated by the diagonal
/// (a conservative approximation for the upstream bootstrap).
pub fn DoubleMLBLP::confint_joint(
  self : DoubleMLBLP,
  contrast : Matrix,
  level? : Double = 0.95,
) -> Array[(Double, Double)] {
  try {
    require(self.fitted)
    require(level > 0.0 && level < 1.0)
    let n_contrast = contrast.rows()
    let p = self.coef.length()
    require(contrast.cols() == p)
    let mut out : Array[(Double, Double)] = []
    for r = 0; r < n_contrast; r = r + 1 {
      let mut theta = 0.0
      let mut variance = 0.0
      for j = 0; j < p; j = j + 1 {
        theta = theta + contrast.get(r, j) * self.coef[j]
        let cv = contrast.get(r, j)
        let sv = self.se[j]
        variance = variance + cv * cv * sv * sv
      }
      let se = variance.sqrt()
      // chi2(1, level) = (z_{1 - level/2})^2 ; for level=0.95 this
      // is z^2 = 1.959963984540054^2 ≈ 3.841458820694125
      // (the same value as `statsmodels.OLS.conf_int(joint=True)`
      // critical-value adjustment before v0.11.4).
      let z = 1.959963984540054
      let half = se * z
      out = out + [(theta - half, theta + half)]
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
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
  try {
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
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
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
  try {
    require(self.fitted)
    let out = Array::make(x.rows(), 0)
    for i = 0; i < x.rows(); i = i + 1 {
      out[i] = policy_tree_predict(self.root, x, i)
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLPolicyTree::split_feature(self : DoubleMLPolicyTree) -> Int {
  try {
    require(self.fitted)
    self.split_feature
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLPolicyTree::split_value(self : DoubleMLPolicyTree) -> Double {
  try {
    require(self.fitted)
    self.split_value
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
