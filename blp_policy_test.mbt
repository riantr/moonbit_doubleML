///|
test "blp_recovers_linear_projection" {
  let n = 200
  let b = Matrix::zeros(n, 1)
  let s = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let x = (i.to_double() - 100.0) / 100.0
    b.set(i, 0, x)
    s[i] = 2.0 + 3.0 * x
  }
  let f = DoubleMLBLP::new(b, s).fit()
  let c = f.coef()
  inspect((c[0] - 2.0).abs() < 1.0e-6, content="true")
  inspect((c[1] - 3.0).abs() < 1.0e-6, content="true")
  inspect(f.se().length(), content="2")
}

///|
test "blp_per_coefficient_se_differ" {
  // Bug #5 regression: with noise added, the per-coefficient SEs
  // must NOT all be the same value. Pre-fix: all p+1 SEs equal
  // `sqrt(RSS / (n - p))`. Post-fix: the intercept SE differs from
  // the slope SE because (X'X)^{-1} scales them differently.
  let n = 200
  let b = Matrix::zeros(n, 1)
  let s = Array::make(n, 0.0)
  let rng = chacha8_rng(5151)
  for i = 0; i < n; i = i + 1 {
    let x = (i.to_double() - 100.0) / 100.0
    b.set(i, 0, x)
    let noise = 0.1 * (rng.double() - 0.5)
    s[i] = 2.0 + 3.0 * x + noise
  }
  let f = DoubleMLBLP::new(b, s).fit()
  let se = f.se()
  inspect(se.length(), content="2")
  // intercept SE and slope SE must differ
  inspect((se[0] - se[1]).abs() > 1.0e-6, content="true")
  // both must be positive
  inspect(se[0] > 0.0, content="true")
  inspect(se[1] > 0.0, content="true")
}

///|
test "policy_tree_finds_effect_sign_split" {
  let n = 200
  let x = Matrix::zeros(n, 1)
  let s = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let z = (i.to_double() - 100.0) / 100.0
    x.set(i, 0, z)
    s[i] = if z < 0.0 { -1.0 } else { 1.0 }
  }
  let f = DoubleMLPolicyTree::new(x, s).fit()
  let p = f.predict(Matrix::from_array([-0.5, 0.5], 2, 1))
  inspect(f.split_feature(), content="0")
  inspect(p[0], content="0")
  inspect(p[1], content="1")
}

///|
test "panic_policy_tree_rejects_depth_zero" {
  // Bug #8 precondition: `depth < 1` must abort. The `panic_`
  // prefix tells `moon test` this abort is expected.
  let x = Matrix::zeros(10, 1)
  let s = Array::make(10, 0.0)
  let _ = DoubleMLPolicyTree::new(x, s, depth=0)
  // unreachable: the constructor should have aborted
  inspect(false, content="unreachable: depth=0 should abort")
}

///|
test "policy_tree_depth_two_recurses" {
  // TODO #11c.3: with depth >= 2 the policy tree should actually
  // recurse. Construct a signal where the optimal split at depth 1
  // sends ~half the rows to each child, and the optimal split at
  // depth 2 depends on a second feature. Verify the tree is not a
  // single-level stump.
  let n = 400
  let x = Matrix::zeros(n, 2)
  let s = Array::make(n, 0.0)
  // signal depends on both x[0] and x[1]:
  //   x[0] < 0  -> +1
  //   x[0] >= 0, x[1] < 0 -> -1
  //   x[0] >= 0, x[1] >= 0 -> +1
  // The depth-1 stump only sees x[0]; if x[0] is split at mean ~ 0,
  // the right-half signal has mean ~0 (mixture of -1 / +1). The
  // depth-2 tree should split x[0] then x[1] on the right side.
  let rng = chacha8_rng(7171)
  for i = 0; i < n; i = i + 1 {
    let z0 = (rng.double() - 0.5) * 2.0
    let z1 = (rng.double() - 0.5) * 2.0
    x.set(i, 0, z0)
    x.set(i, 1, z1)
    s[i] = if z0 < 0.0 { 1.0 } else if z1 < 0.0 { -1.5 } else { 0.5 }
  }
  let f1 = DoubleMLPolicyTree::new(x, s, depth=1).fit()
  let f2 = DoubleMLPolicyTree::new(x, s, depth=2).fit()
  // Sanity: both depths should pick x[0] as the root split (it has
  // the strongest signal dependence).
  inspect(f1.split_feature(), content="0")
  inspect(f2.split_feature(), content="0")
  // Sanity: depth-2 must produce a different prediction at SOME point
  // than depth-1, otherwise the recursion is a no-op. Use a 4-by-2
  // grid covering the four quadrants; with the biased DGP above the
  // x[0] >= 0 right-half differs between depth-1 and depth-2.
  let grid = Matrix::from_array(
    [-0.5, -0.5, -0.5, 0.5, 0.5, -0.5, 0.5, 0.5],
    4,
    2,
  )
  let p1 = f1.predict(grid)
  let p2 = f2.predict(grid)
  let mut differ = false
  for k = 0; k < 4; k = k + 1 {
    if p1[k] != p2[k] {
      differ = true
    }
  }
  inspect(differ, content="true")
}
