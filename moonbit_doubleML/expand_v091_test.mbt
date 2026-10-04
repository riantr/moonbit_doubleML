///|
// v0.91.0: the sandwich accumulator corrected, and the payoff
// invariant pinned.
//
// THE TWO DEFECTS
// ===============
// Through v0.90.0 every function in `sandwich.mbt` accumulated
//
//     prod_i = psi_a[i] * psi[i]
//
// and returned
//
//     M_inv[0,0]^2 * sum_i prod_i^2 / n
//
// which is wrong in two independent ways:
//
//   1. `psi_a[i]` is not part of the moment. The DML estimating
//      function is `f(theta) = E[theta * psi_a + psi_b]` -- a
//      MEAN moment, inverted as a regression on the constant 1
//      -- so the per-observation quadratic form is `psi[i]^2`.
//      For a constant `psi_a = c` the shipped `c^2` cancelled
//      against `M_inv^2 = 1 / c^2` (a no-op for IRM / APO /
//      SSM / CVAR / DID ATT), while for a non-constant `psi_a`
//      (PLR / PLPR / IIVM / PLIV) it inflated the answer by the
//      data-dependent `sum (psi_a psi)^2 / sum psi^2` -- 9.58x
//      on the PLR DGP below.
//
//   2. `M_inv^2 * sum / n` is the variance of
//      `sqrt(n) * (theta_hat - theta)`, not of
//      `(theta_hat - theta)`. `var_est.mbt` (the reference,
//      unchanged) returns `sigma2 = mean(psi^2) / (J^2 * n) =
//      M_inv^2 * sum psi^2 / n^2`, i.e. it divides by `n` a
//      SECOND time. So the shipped SE was `sqrt(n)` too large
//      for EVERY estimator.
//
// The shipped value was therefore `(psi_a-weighted?) * n` too
// large in the variance, and only the `n` part was visible in
// the v0.90.0 test, which pinned `se() == sandwich_se(HC0) /
// sqrt(n)` for a constant `psi_a` and could not see defect 1 at
// all.
//
// THE PAYOFF
// ==========
// v0.91.0 accumulates `sum_i psi[i]^2` and returns
// `M_inv^2 * acc / n / n`. The invariant this buys is much
// stronger than the `sqrt(n)` relation and is the reason the
// break is worth taking:
//
//     se() == sandwich_se(HC0)
//
// to floating-point tolerance for EVERY estimator, including
// the non-constant-`psi_a` ones where the old accumulator was
// off by a data-dependent factor on top of the `sqrt(n)`.
// `se()` itself is untouched and remains the reference.
//
// The cluster estimator carries the same missing `1 / n` in its
// meat, so it moves by the same factor and
// "all-singleton clusters == IID HC0 == se()" still holds.
//
// What does NOT change: `M_inv = [[1 / mean(psi_a)]]` is
// correct and stays; the v0.88.0 leverage `h_ii = 1 / n_obs` is
// correct and stays; the v0.90.0 `psi_at` helper is correct and
// stays. Every HC relationship is a pure RATIO of the
// accumulator, so all of them are scale-invariant and survive
// untouched -- except that `HC2 == HC1` is now only equal to
// 1e-12 rather than bit-exact (the two accumulation orders
// differ in the last ulp).

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

///|
/// Relative closeness at the 1e-12 level (the package's
/// tolerance for "same number, different accumulation order").
fn expand_v091_close(x : Double, y : Double) -> Bool {
  let scale = if x.abs() > y.abs() { x.abs() } else { y.abs() }
  if scale == 0.0 {
    return (x - y).abs() < 1.0e-300
  }
  (x - y).abs() / scale < 1.0e-12
}

///|
/// The `DoubleMLData` DGP shared by the IRM / PLR tests:
/// `d = 1{x_0 + 0.3 u > 0}` (monotone in `x_0`, so a linear
/// propensity learner stays inside `(0, 1)` away from the clip),
/// `y = 1.0 + 0.4 x_0 + 0.1 * sum_{j>0} x_j + 2.0 d + noise`.
/// True ATE = 2.0. Identical to `expand_v090_data` (it must be:
/// these two files bracket the same release and the numbers are
/// comparable).
fn expand_v091_data(n : Int, p : Int) -> DoubleMLData {
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  for i = 0; i < n * p; i = i + 1 {
    x_flat[i] = chacha8_rng(11 + i).double()
  }
  let rng = chacha8_rng(7)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u = rng.double() * 2.0 - 1.0
    let x0 = x_flat[i * p]
    d[i] = if x0 + 0.3 * u > 0.0 { 1.0 } else { 0.0 }
    let mut lin = 1.0 + 0.4 * x0
    for j = 1; j < p; j = j + 1 {
      lin = lin + 0.1 * x_flat[i * p + j]
    }
    y[i] = lin + 2.0 * d[i] + 0.4 * (rng.double() - 0.5)
  }
  DoubleMLData::new(Matrix::from_array(x_flat, n, p), y, d)
}

///|
/// IIVM LATE DGP with a valid exclusion restriction:
/// `x, v, eps ~ N(0, 1)`, `z ~ Bernoulli(1/2)`,
/// `d = 1{0.5 z + v > 0}`, `y = 1.0 * d + x @ 1 + eps`.
/// A second non-constant-`psi_a` estimator, independent of the
/// PLR learner path. True LATE = 1.0.
fn expand_v091_iivm_data(n : Int, p : Int) -> DoubleMLIIVMData {
  let rng = chacha8_rng(1111)
  let pool : Array[Double] = []
  while pool.length() < n * p + 2 * n {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let theta = 2.0 * 3.141592653589793 * u2
    pool.push(r * @math.cos(theta))
    pool.push(r * @math.sin(theta))
  }
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  for i = 0; i < n * p; i = i + 1 {
    x_flat[i] = pool[i]
  }
  let mut idx = n * p
  let v : Array[Double] = Array::make(n, 0.0)
  let eps : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    v[i] = pool[idx]
    idx = idx + 1
  }
  for i = 0; i < n; i = i + 1 {
    eps[i] = pool[idx]
    idx = idx + 1
  }
  let x = Matrix::from_array(x_flat, n, p)
  let z : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u = rng.double()
    z[i] = if u > 0.5 { 1.0 } else { 0.0 }
    d[i] = if 0.5 * z[i] + v[i] > 0.0 { 1.0 } else { 0.0 }
    let mut s = eps[i]
    for j = 0; j < p; j = j + 1 {
      s = s + x.get(i, j)
    }
    y[i] = 1.0 * d[i] + s
  }
  DoubleMLIIVMData::new(x, y, d, z)
}

///|
/// All-singleton (`singleton[i] = i`) and pooled-in-blocks-of-4
/// (`pooled[i] = i / 4`) cluster ids for a sample of `n`.
fn expand_v091_cluster_ids(n : Int) -> (Array[Int], Array[Int]) {
  let singleton : Array[Int] = Array::make(n, 0)
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
    pooled[i] = i / 4
  }
  (singleton, pooled)
}

///|
/// The v0.90.0 accumulator, recomputed INDEPENDENTLY (not via
/// `sandwich_variance_hc0`), so the test can state exactly what
/// the shipped code used to return and show that the new value is
/// neither it nor a scalar multiple of it by accident.
///
///     old = M_inv^2 * sum_i (psi_a[i] * psi[i])^2 / n
fn expand_v091_old_accumulator(
  psi_a : Array[Double],
  psi : Array[Double],
  m_val : Double,
  n_obs : Int,
) -> Double {
  let mut acc = 0.0
  for i = 0; i < n_obs; i = i + 1 {
    let prod = psi_a[i] * psi[i]
    acc = acc + prod * prod
  }
  let m2 = m_val * m_val
  m2 * acc / n_obs.to_double()
}

// ---------------------------------------------------------------------------
// 1. THE PAYOFF: se() == sandwich_se(HC0), non-constant psi_a
// ---------------------------------------------------------------------------

///|
/// PLR's `psi_a[i] = -v_hat[i]^2` genuinely varies across rows, so
/// this is the case where the v0.90.0 accumulator was wrong by a
/// DATA-DEPENDENT factor (9.58x on this DGP) on top of the
/// `sqrt(n)`. It is the assertion that v0.90.0 could not make.
///
/// Fails against v0.90.0 by ~192x (= 9.58 * sqrt(400)).
test "se_equals_sandwich_hc0_nonconstant" {
  let n = 400
  let n_d = n.to_double()
  let plr = DoubleMLPLR::new(
    expand_v091_data(n, 3),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  inspect(plr.psi_a.length() == n, content="true")
  // Precondition: `psi_a` really is non-constant, and negative
  // (so `M_inv` is negative, as `mean(psi_a) < 0` requires).
  let mut varies = false
  for i = 1; i < n; i = i + 1 {
    if plr.psi_a[i] != plr.psi_a[0] {
      varies = true
    }
  }
  inspect(varies, content="true")
  inspect(mean(plr.psi_a) < 0.0, content="true")
  // The invariant.
  let se_hc0 = plr.sandwich_se(SandwichKind::hc0())
  inspect(expand_v091_close(se_hc0, plr.se()), content="true")
  // The same score also pins the SE to `var_est`'s formula
  // recomputed from the persisted IF components, so the claim is
  // not "two accessors of the same struct field agree".
  let psi = psi_at(plr.coef(), plr.psi_a, plr.psi_b)
  let mut ss = 0.0
  for i = 0; i < n; i = i + 1 {
    ss = ss + psi[i] * psi[i]
  }
  let j = mean(plr.psi_a)
  let se_ref = (ss / n_d / (j * j * n_d)).sqrt()
  inspect(expand_v091_close(se_hc0, se_ref), content="true")
  // And it is NOT the old accumulator, nor `sqrt(n) * se()` --
  // so the test cannot be passed by an unrelated scaling.
  let m_val = 1.0 / j
  let old = expand_v091_old_accumulator(plr.psi_a, psi, m_val, n).sqrt()
  inspect(expand_v091_close(se_hc0, old) == false, content="true")
  inspect(
    expand_v091_close(se_hc0, n_d.sqrt() * plr.se()) == false,
    content="true",
  )
  // The `psi_a` weight was NOT a uniform rescaling on this DGP:
  // it re-weighted the meat by `sum (psi_a psi)^2 / sum psi^2`
  // = 0.229 (measured), i.e. the two defects multiplied to the
  // 91.7x variance ratio behind the 9.58x SE ratio above. Both
  // directions are excluded so the test cannot pass by accident.
  let mut ss_weighted = 0.0
  for i = 0; i < n; i = i + 1 {
    ss_weighted = ss_weighted + plr.psi_a[i] * psi[i] * (plr.psi_a[i] * psi[i])
  }
  inspect(ss_weighted > ss * 0.1 && ss_weighted < ss * 0.4, content="true")
  // The two defects compose multiplicatively: the v0.90.0 SE was
  // `sqrt(n) * sqrt(ss_weighted / ss) * se_ref`.
  inspect(
    expand_v091_close(old, n_d.sqrt() * (ss_weighted / ss).sqrt() * se_ref),
    content="true",
  )
  // Second non-constant-`psi_a` estimator, different score and
  // different learner path.
  let n2 = 1000
  let iivm = DoubleMLIIVM::new(
    expand_v091_iivm_data(n2, 5),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let mut varies2 = false
  for i = 1; i < n2; i = i + 1 {
    if iivm.psi_a[i] != iivm.psi_a[0] {
      varies2 = true
    }
  }
  inspect(varies2, content="true")
  inspect(
    expand_v091_close(iivm.sandwich_se(SandwichKind::hc0()), iivm.se()),
    content="true",
  )
}

// ---------------------------------------------------------------------------
// 2. THE PAYOFF: se() == sandwich_se(HC0), constant psi_a
// ---------------------------------------------------------------------------

///|
/// IRM's `psi_a = -1` on every row. The v0.90.0 accumulator
/// returned `mean(psi^2)` here while `se()` returned
/// `mean(psi^2) / n`, i.e. `sandwich_se(HC0) == sqrt(n) *
/// se() == 20 * se()`. The corrected value IS `se()`.
test "se_equals_sandwich_hc0_constant" {
  let n = 400
  let n_d = n.to_double()
  let irm = DoubleMLIRM::new(
    expand_v091_data(n, 3),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  inspect(expand_v091_close(mean(irm.psi_a), -1.0), content="true")
  let se = irm.se()
  let se_hc0 = irm.sandwich_se(SandwichKind::hc0())
  inspect(expand_v091_close(se_hc0, se), content="true")
  // Explicitly not the v0.90.0 value.
  inspect(expand_v091_close(se_hc0, n_d.sqrt() * se) == false, content="true")
  // ... and not the value it replaced, `mean(psi^2)`, either.
  let psi = psi_at(irm.coef(), irm.psi_a, irm.psi_b)
  let mut ss = 0.0
  for i = 0; i < n; i = i + 1 {
    ss = ss + psi[i] * psi[i]
  }
  inspect(expand_v091_close(se_hc0, (ss / n_d).sqrt()) == false, content="true")
  // A second constant-`psi_a` estimator (APO), to show the
  // invariant does not depend on the estimator.
  let apo = DoubleMLAPO::new(
    expand_v091_data(n, 3),
    treatment_level=1.0,
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  inspect(expand_v091_close(mean(apo.psi_a), -1.0), content="true")
  inspect(
    expand_v091_close(apo.sandwich_se(SandwichKind::hc0()), apo.se()),
    content="true",
  )
}

// ---------------------------------------------------------------------------
// 3-5. THE HC RELATIONSHIPS (all pure ratios of the accumulator)
// ---------------------------------------------------------------------------

///|
/// `se(HC1) / se(HC0) == sqrt(n / (n - k))` with `k = 1`, i.e.
/// `sqrt(n / (n - 1))`. Scale-invariant, so v0.91.0 must not
/// move it.
test "hc1_hc0_ratio" {
  let n = 400
  let n_d = n.to_double()
  let irm = DoubleMLIRM::new(
    expand_v091_data(n, 3),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let se0 = irm.sandwich_se(SandwichKind::hc0())
  let se1 = irm.sandwich_se(SandwichKind::hc1())
  inspect(
    expand_v091_close(se1 / se0, (n_d / (n_d - 1.0)).sqrt()),
    content="true",
  )
  // Same on the non-constant-`psi_a` estimator.
  let plr = DoubleMLPLR::new(
    expand_v091_data(n, 3),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let p0 = plr.sandwich_se(SandwichKind::hc0())
  let p1 = plr.sandwich_se(SandwichKind::hc1())
  inspect(
    expand_v091_close(p1 / p0, (n_d / (n_d - 1.0)).sqrt()),
    content="true",
  )
  // And on the shared dispatch with a non-unit `psi_a` /
  // `M_inv`, so the ratio cannot be an artefact of `psi_a = -1`.
  let psi_a : Array[Double] = Array::make(64, 0.8)
  let psi : Array[Double] = Array::make(64, 0.0)
  for i = 0; i < 64; i = i + 1 {
    psi[i] = if i % 3 == 0 { 1.0 } else { -0.5 }
  }
  let m_inv = Matrix::from_array([-1.5], 1, 1)
  let d0 = sandwich_variance(SandwichKind::hc0(), psi_a, psi, m_inv, 64, 1)
  let d1 = sandwich_variance(SandwichKind::hc1(), psi_a, psi, m_inv, 64, 1)
  inspect(
    expand_v091_close(d1.sqrt() / d0.sqrt(), (64.0 / 63.0).sqrt()),
    content="true",
  )
}

///|
/// With the v0.88.0 leverage `h_ii = 1 / n` every HC2 term is
/// divided by `(n - 1) / n`, algebraically the HC1 factor, so
/// HC2 == HC1.
///
/// (Named `..._v091` because `expand_v088_test.mbt` already owns
/// the plain `hc2_equals_hc1` name.)
test "hc2_equals_hc1_v091" {
  let n = 400
  let irm = DoubleMLIRM::new(
    expand_v091_data(n, 3),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let se1 = irm.sandwich_se(SandwichKind::hc1())
  let se2 = irm.sandwich_se(SandwichKind::hc2())
  inspect(expand_v091_close(se2, se1), content="true")
  let plr = DoubleMLPLR::new(
    expand_v091_data(n, 3),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let p1 = plr.sandwich_se(SandwichKind::hc1())
  let p2 = plr.sandwich_se(SandwichKind::hc2())
  inspect(expand_v091_close(p2, p1), content="true")
}

///|
/// HC3 divides every term by `((n - 1) / n)^2`, so
/// `HC3 == HC1^2 / HC0`.
///
/// (Named `..._v091` because `expand_v088_test.mbt` already owns
/// the plain `hc3_equals_hc1_squared_over_hc0` name.)
test "hc3_equals_hc1_squared_over_hc0_v091" {
  let n = 400
  let n_d = n.to_double()
  let irm = DoubleMLIRM::new(
    expand_v091_data(n, 3),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let se0 = irm.sandwich_se(SandwichKind::hc0())
  let se1 = irm.sandwich_se(SandwichKind::hc1())
  let se3 = irm.sandwich_se(SandwichKind::hc3())
  inspect(expand_v091_close(se3, se1 * se1 / se0), content="true")
  inspect(
    expand_v091_close(
      se3,
      se0 * (n_d / (n_d - 1.0)).sqrt() * (n_d / (n_d - 1.0)).sqrt(),
    ),
    content="true",
  )
  let plr = DoubleMLPLR::new(
    expand_v091_data(n, 3),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let p0 = plr.sandwich_se(SandwichKind::hc0())
  let p1 = plr.sandwich_se(SandwichKind::hc1())
  let p3 = plr.sandwich_se(SandwichKind::hc3())
  inspect(expand_v091_close(p3, p1 * p1 / p0), content="true")
}

///|
/// The ordering: `HC3 > HC1 == HC2 > HC0`. Monotonic widening, as
/// MacKinnon (2012) sec 5.4 requires. `HC2` is NOT strictly above
/// `HC1` -- it is equal to it, which is the whole content of the
/// `h_ii = 1 / n` result. Any test written as `HC2 > HC1` is
/// asserting a falsehood and had to be relaxed to `==` in
/// v0.91.0 (at 1e-12: the two accumulation orders differ in the
/// last ulp).
test "ordering_hc3_ge_hc1_ge_hc0" {
  let n = 400
  let irm = DoubleMLIRM::new(
    expand_v091_data(n, 3),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let se0 = irm.sandwich_se(SandwichKind::hc0())
  let se1 = irm.sandwich_se(SandwichKind::hc1())
  let se2 = irm.sandwich_se(SandwichKind::hc2())
  let se3 = irm.sandwich_se(SandwichKind::hc3())
  inspect(se1 > se0, content="true")
  inspect(se2 > se0, content="true")
  inspect(se3 > se2, content="true")
  inspect(expand_v091_close(se2, se1), content="true")
  let plr = DoubleMLPLR::new(
    expand_v091_data(n, 3),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let p0 = plr.sandwich_se(SandwichKind::hc0())
  let p1 = plr.sandwich_se(SandwichKind::hc1())
  let p2 = plr.sandwich_se(SandwichKind::hc2())
  let p3 = plr.sandwich_se(SandwichKind::hc3())
  inspect(p1 > p0, content="true")
  inspect(expand_v091_close(p2, p1), content="true")
  inspect(p3 > p2, content="true")
}

// ---------------------------------------------------------------------------
// 6. THE CLUSTER PATH
// ---------------------------------------------------------------------------

///|
/// With all-singleton clusters the meat degenerates to
/// `sum_i psi[i]^2` and the cluster formula collapses to the
/// IID HC0, hence to `se()`. Pooled clusters pick up the
/// within-cluster cross terms and differ -- which also proves
/// `cluster_ids` is consumed rather than ignored.
///
/// The cluster meat carries the same missing `1 / n` the IID
/// accumulator had, so the cluster SE also moved by `sqrt(n)` in
/// v0.91.0 and the singleton identity SURVIVED the fix.
test "singleton_cluster_equals_se" {
  let n = 400
  let (singleton, pooled) = expand_v091_cluster_ids(n)
  let irm = DoubleMLIRM::new(
    expand_v091_data(n, 3),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let se = irm.se()
  let cl_single = irm.cluster_sandwich_se(singleton)
  let cl_pooled = irm.cluster_sandwich_se(pooled)
  inspect(expand_v091_close(cl_single, se), content="true")
  inspect(
    expand_v091_close(cl_single, irm.sandwich_se(SandwichKind::hc0())),
    content="true",
  )
  inspect(expand_v091_close(cl_pooled, se) == false, content="true")
  inspect(cl_pooled > 0.0, content="true")
  // Non-constant `psi_a`: the singleton identity must survive
  // the psi_a removal too, i.e. it is a property of the formula
  // and not of a constant regressor.
  let plr = DoubleMLPLR::new(
    expand_v091_data(n, 3),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let p_single = plr.cluster_sandwich_se(singleton)
  let p_pooled = plr.cluster_sandwich_se(pooled)
  inspect(expand_v091_close(p_single, plr.se()), content="true")
  inspect(expand_v091_close(p_pooled, plr.se()) == false, content="true")
}

// ---------------------------------------------------------------------------
// 7. bias_corrected_coef: the v0.91.0 design
// ---------------------------------------------------------------------------

///|
/// DESIGN (B) -- documented no-op. `bias_corrected_coef` returns
/// `coef` EXACTLY, on every estimator, because under `var_est`'s
/// convention the estimating function is ORTHOGONAL at the root:
/// `mean(coef * psi_a + psi_b) == 0` identically, so a
/// correction built from the score at the estimate is a
/// guaranteed no-op by construction.
///
/// v0.79.0 - v0.90.0 returned `coef + mean(psi_b - coef *
/// psi_a)`, which is the score at `-coef` rather than at `coef`
/// and collapsed to `3 * coef` on a constant-`psi_a` score. That
/// number is not a bias estimate; this test pins both the new
/// exact identity and the old arithmetic it replaced, so the
/// removal is auditable rather than silent.
test "bias_corrected_coef_returns_coef" {
  let n = 400
  let data = expand_v091_data(n, 3)
  // Constant `psi_a` (IRM) and non-constant (PLR): the no-op
  // holds for both, and neither returns the old `3 * coef`
  // shape.
  let irm = DoubleMLIRM::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let irm_bc = irm.bias_corrected_coef()
  inspect(irm_bc == irm.coef(), content="true")
  // The removed expression, recomputed, is `3 * coef` here.
  let bias : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    bias[i] = irm.psi_b[i] - irm.coef() * irm.psi_a[i]
  }
  let irm_old = irm.coef() + mean(bias)
  // Deliberate REGRESSION PIN of the removed expression.
  inspect(expand_v091_close(irm_old, 3.0 * irm.coef()), content="true")
  inspect(irm_old != irm_bc, content="true")
  // Non-constant `psi_a`: `coef * (1 - 2 * mean(psi_a))`, still
  // not `coef`.
  let plr = DoubleMLPLR::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let plr_bc = plr.bias_corrected_coef()
  inspect(plr_bc == plr.coef(), content="true")
  let p_bias : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    p_bias[i] = plr.psi_b[i] - plr.coef() * plr.psi_a[i]
  }
  let plr_old = plr.coef() + mean(p_bias)
  inspect(
    expand_v091_close(plr_old, plr.coef() * (1.0 - 2.0 * mean(plr.psi_a))),
    content="true",
  )
  inspect(plr_old != plr_bc, content="true")
  // Third estimator, and the free helper is unchanged: it is
  // still `theta + mean(bias)` for an EXTERNAL bias vector, it
  // just no longer gets a DML score passed to it.
  let apo = DoubleMLAPO::new(
    data,
    treatment_level=1.0,
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  inspect(apo.bias_corrected_coef() == apo.coef(), content="true")
  let ext : Array[Double] = Array::make(n, 0.1)
  inspect(
    expand_v091_close(bias_corrected_theta(apo.coef(), ext), apo.coef() + 0.1),
    content="true",
  )
}
