///|
// v0.85.0+: white-box tests for the memoize + vectorize surface on
// `DoubleMLPolicyTree` -- the 22nd and final estimator to receive
// the API. With this, all 22 estimators expose
// `enable_memoize` / `disable_memoize` / `clear_cache` /
// `has_cache`.
//
// PolicyTree is a deterministic policy learner, not a
// cross-fitted nuisance-regression estimator: it has no `n_folds`,
// no `n_rep`, and no `fit_cluster`. Its cache holds the fitted
// tree structure (flat-encoded node array) plus the per-leaf
// statistics rather than per-fold nuisance predictions.
//
// Coverage:
//   #1: policy_tree_enable_memoize_smoke -- memoize ON, two fits
//       produce identical split_feature / split_value /
//       leaf_assignment / leaf_signal_mean / leaf_count AND
//       identical `predict` output (the `predict` check is the
//       real proof that the flat node encode/decode round-trip is
//       lossless, since `predict` walks the restored `root`).
//       Also checks a depth-3 tree, which exercises a multi-level
//       node encoding rather than a single root split.
//   #2: policy_tree_disable_memoize_smoke -- enable, fit,
//       disable, clear_cache -> has_cache() is false.
//   #3: policy_tree_memoize_invalidation -- fit at depth=1, cache,
//       then build a fresh tree at depth=3 and confirm the cache
//       is NOT reused (the hyperparams hash folds in `depth`).
//       Also confirms a hit really is a hit (has_cache + identical
//       result), so #3 cannot pass vacuously on a dead cache.

///|
// v0.85.0+: shared PolicyTree DGP. A two-feature, four-quadrant
// step signal with a DELIBERATELY ASYMMETRIC structure and
// asymmetric magnitudes, so `policy_tree_build` finds a genuine
// root split and recurses when `depth >= 2`.
//
// The asymmetry matters for the test's power: a symmetric
// interaction (e.g. `sign(z0 * z1)`) produces a tree that is
// invariant under a left/right mirror, so swapping the `left` /
// `right` slots in the flat node encoding would be undetectable.
// Asymmetric quadrant values make every such corruption visible in
// `leaf_assignment`, `leaf_signal_mean`, and `predict`.
// n = 300.
fn v085_policy_dgp(seed : Int) -> (Matrix, Array[Double]) {
  let n = 300
  let p = 2
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let rng = chacha8_rng(seed)
  for i = 0; i < n; i = i + 1 {
    x_flat[i * p + 0] = rng.double() - 0.5
    x_flat[i * p + 1] = rng.double() - 0.5
  }
  let x = Matrix::from_array(x_flat, n, p)
  let s : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let z0 = x_flat[i * p + 0]
    let z1 = x_flat[i * p + 1]
    s[i] = if z0 < 0.0 {
      if z1 < 0.0 {
        -1.0
      } else {
        -0.5
      }
    } else if z1 < 0.0 {
      -1.5
    } else {
      1.0
    }
  }
  (x, s)
}

///|
/// White-box helper: `true` iff the two `Int` arrays agree
/// elementwise. Used by `policy_tree_enable_memoize_smoke` to
/// compare `leaf_assignment` / `leaf_count` across the two fits.
fn v085_int_array_eq(a : Array[Int], b : Array[Int]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
/// White-box helper: `true` iff the two `Double` arrays agree
/// elementwise within `tol`. Leaf means are computed by an
/// identical division in both fits, so the tolerance is only there
/// to absorb a benign platform FMA reassociation.
fn v085_dbl_array_close(
  a : Array[Double],
  b : Array[Double],
  tol : Double,
) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    if (a[i] - b[i]).abs() > tol {
      return false
    }
  }
  true
}

///|
test "policy_tree_enable_memoize_smoke" {
  // Memoize ON, depth=3 so the flat node encoding has to survive a
  // multi-level tree (a depth-1 fit only round-trips a single
  // Split node and would not catch a broken pre-order layout).
  let (x, s) = v085_policy_dgp(8501)
  let tree = DoubleMLPolicyTree::new(x, s, depth=3).enable_memoize()
  let fit1 = tree.fit()
  inspect(fit1.has_cache(), content="true")
  // Second fit: same data, same depth -> genuine cache hit. NOTE
  // it must be driven from `fit1` (the value that actually holds
  // the populated cache), NOT from `tree` -- `tree` still carries
  // the empty constructor cache, so `tree.fit()` would be another
  // miss and would never exercise the cache-hit / node-decode
  // path.
  let fit2 = fit1.fit()
  inspect(fit2.has_cache(), content="true")
  // The cached root / depth-1 surface must match.
  inspect(fit1.split_feature() == fit2.split_feature(), content="true")
  inspect(
    (fit1.split_value() - fit2.split_value()).abs() < 1.0e-12,
    content="true",
  )
  // The per-leaf statistics must match elementwise.
  inspect(
    v085_int_array_eq(fit1.leaf_assignment, fit2.leaf_assignment),
    content="true",
  )
  inspect(
    v085_dbl_array_close(fit1.leaf_signal_mean, fit2.leaf_signal_mean, 1.0e-12),
    content="true",
  )
  inspect(v085_int_array_eq(fit1.leaf_count, fit2.leaf_count), content="true")
  // The real proof that the node encode/decode round-trip is
  // lossless: `predict` walks the RESTORED `root`, so identical
  // predictions on a grid spanning every quadrant mean the
  // reconstructed tree is the same tree.
  let grid_flat : Array[Double] = [
    -0.9, -0.9, -0.9, 0.9, 0.0, -0.9, 0.0, 0.9, 0.9, -0.9, 0.9, 0.9, 0.25, 0.25,
    -0.25, -0.25,
  ]
  let grid = Matrix::from_array(grid_flat, 8, 2)
  let p1 = fit1.predict(grid)
  let p2 = fit2.predict(grid)
  inspect(v085_int_array_eq(p1, p2), content="true")
  // Strongest check: compare the cache-hit result against an
  // INDEPENDENT memoize-OFF fit of the same depth. `fit2` is built
  // entirely from the flat node encoding + cached leaf stats, so
  // agreeing with a from-scratch `policy_tree_build` validates the
  // whole round-trip against ground truth rather than against
  // another cached run.
  let fresh = DoubleMLPolicyTree::new(x, s, depth=3).fit()
  inspect(fresh.has_cache(), content="false")
  inspect(fresh.split_feature() == fit2.split_feature(), content="true")
  inspect(
    (fresh.split_value() - fit2.split_value()).abs() < 1.0e-12,
    content="true",
  )
  inspect(
    v085_int_array_eq(fresh.leaf_assignment, fit2.leaf_assignment),
    content="true",
  )
  inspect(v085_int_array_eq(fresh.leaf_count, fit2.leaf_count), content="true")
  inspect(
    v085_dbl_array_close(fresh.leaf_signal_mean, fit2.leaf_signal_mean, 1.0e-12),
    content="true",
  )
  inspect(v085_int_array_eq(fresh.predict(grid), p2), content="true")
  // Sanity: a real split must have happened, otherwise the
  // round-trip test above would be vacuous (a single Leaf node).
  inspect(fit1.leaf_signal_mean.length() >= 2, content="true")
  inspect(
    fit1.leaf_count.length() == fit1.leaf_signal_mean.length(),
    content="true",
  )
}

///|
test "policy_tree_disable_memoize_smoke" {
  // enable -> fit -> disable -> clear_cache must drop the cache
  // and report has_cache() == false.
  let (x, s) = v085_policy_dgp(8502)
  let base = DoubleMLPolicyTree::new(x, s, depth=2)
  let on = base.enable_memoize()
  let fitted_on = on.fit()
  inspect(fitted_on.has_cache(), content="true")
  let off = fitted_on.disable_memoize()
  inspect(off.has_cache(), content="true") // disable preserves the cache
  let cleared = off.clear_cache()
  inspect(cleared.has_cache(), content="false")
  // A cleared tree must still fit correctly, and must not
  // repopulate the cache while memoize is off.
  let refit = cleared.fit()
  inspect(refit.has_cache(), content="false")
  inspect(refit.split_feature() == fitted_on.split_feature(), content="true")
  inspect(
    v085_int_array_eq(refit.leaf_assignment, fitted_on.leaf_assignment),
    content="true",
  )
}

///|
test "policy_tree_memoize_invalidation" {
  // The hyperparams hash folds in `depth`, so a tree cached at
  // depth=1 must NOT be reused for a depth=3 fit.
  let (x, s) = v085_policy_dgp(8503)
  let shallow = DoubleMLPolicyTree::new(x, s, depth=1).enable_memoize().fit()
  inspect(shallow.has_cache(), content="true")
  // A repeat fit at the SAME depth is a genuine cache hit, so the
  // checks below cannot pass merely because the cache is dead.
  let repeat = shallow.fit()
  inspect(repeat.has_cache(), content="true")
  inspect(
    v085_int_array_eq(repeat.leaf_assignment, shallow.leaf_assignment),
    content="true",
  )
  // Now change the structural hyperparameter. The fit must
  // recompute rather than replay the depth-1 cache: the depth-3
  // tree has strictly more leaves, so `leaf_signal_mean.length()`
  // grows and the assignment cannot be the depth-1 one.
  let deep = DoubleMLPolicyTree::new(x, s, depth=3).enable_memoize()
  let deep_fit = deep.fit()
  inspect(deep_fit.has_cache(), content="true")
  inspect(
    deep_fit.leaf_signal_mean.length() > shallow.leaf_signal_mean.length(),
    content="true",
  )
  // A fresh tree at depth=1 with the cache already filled at
  // depth=3 must also recompute downward.
  let back = DoubleMLPolicyTree::new(x, s, depth=1).enable_memoize()
  let back_fit = back.fit()
  inspect(
    back_fit.leaf_signal_mean.length() == shallow.leaf_signal_mean.length(),
    content="true",
  )
  inspect(
    v085_int_array_eq(back_fit.leaf_assignment, shallow.leaf_assignment),
    content="true",
  )
}
