///|
// v0.101.0+: joint-covariance tests for `DoubleMLQTE`.
//
// WHY THIS FILE EXISTS
// -------------------
// `sandwich_se_at(j, kind)` (v0.95.0) pins each quantile separately.
// The quantiles are estimated from the SAME observations, so their
// influence functions are correlated, and a report that gives only
// the marginal SEs cannot answer any question that treats two levels
// jointly. The off-diagonal terms are not small relative to the
// diagonal either -- measured on the v0.101.0 DGP they reach a
// correlation of -0.265, i.e. the sign of the dependence between two
// quantile estimates is a real, sign-bearing fact about the data,
// not a rounding artefact.
//
// Coverage:
//   #1  qte_joint_diagonal_is_the_se_variance -- the diagonal is
//       bit-identical to `sandwich_variance` on the same row, which
//       is the variance `ses[j]` is the square root of.
//   #2  qte_joint_offdiagonal_is_nonzero -- the new information is
//       actually there, and the matrix is symmetric.
//   #3  qte_joint_small_sample_kinds -- HC1/HC2/HC3 move the
//       diagonal by exactly `n / (n - 1)` and `(n / (n - 1))^2`,
//       leaving the correlation structure alone.
//   #4  qte_joint_differs_from_independent -- the matrix is NOT
//       diagonal, so a caller that assumed independence would get a
//       materially different answer.
//   #5  qte_cluster_joint_collapses_to_iid -- singleton clusters
//       reproduce the IID matrix exactly.
//   #6  qte_cluster_joint_pooled_differs -- pooled clusters change
//       the answer, including the SIGN of an off-diagonal term.
//   #7  qte_joint_after_memoize_cache_hit -- the matrix survives a
//       cache hit (driven from the fitted value, per the rule below).

///|
/// Relative closeness at 1e-12, the same helper the v0.091-v0.100
/// test files use. Reserved for comparisons that genuinely go through
/// a `sqrt`; the headline diagonal assertion does NOT use it.
fn expand_v101_close(x : Double, y : Double) -> Bool {
  let scale = if x.abs() > y.abs() { x.abs() } else { y.abs() }
  if scale == 0.0 {
    return (x - y).abs() < 1.0e-300
  }
  (x - y).abs() / scale < 1.0e-12
}

///|
/// The v0.95.0 shared QTE DGP, reproduced here so this file does not
/// depend on a private helper in another test file. `n` observations,
/// `p = 3` covariates, `u0` linear in X, Bernoulli treatment, an
/// additive quantile shift (so every requested level is identified),
/// and homoskedastic noise.
fn expand_v101_qte_data(n : Int, seed : Int) -> DoubleMLData {
  let p = 3
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let rng = chacha8_rng(seed)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double() * 2.0 - 1.0
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    let u0 = 0.5 * x_flat[i * p] +
      0.3 * x_flat[i * p + 1] -
      0.2 * x_flat[i * p + 2]
    y[i] = 1.0 + u0 + (rng.double() - 0.5) * 0.4
  }
  DoubleMLData::new(Matrix::from_array(x_flat, n, p), y, d)
}

///|
/// Three requested levels. Two would suffice to show a non-zero
/// off-diagonal, but three is where the structure stops looking like
/// a single "adjacent quantiles are correlated" story: the measured
/// correlations are +0.076, -0.265 and +0.124, so the middle
/// quantile is the outlier. Pinning three also rules out an
/// implementation that only ever fills a 2x2.
fn expand_v101_quantiles() -> Array[Double] {
  [0.25, 0.5, 0.75]
}

///|
/// All-singleton (`singleton[i] = i`) and pooled-in-blocks-of-5
/// (`pooled[i] = i / 5`) cluster ids for a sample of `n`.
fn expand_v101_cluster_ids(n : Int) -> (Array[Int], Array[Int]) {
  let singleton : Array[Int] = Array::make(n, 0)
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
    pooled[i] = i / 5
  }
  (singleton, pooled)
}

///|
/// Quantile row `j` of `psi_flat`, built independently of the
/// production slice helper so the field layout itself is pinned.
fn expand_v101_row(m : DoubleMLQTE, j : Int, n : Int) -> Array[Double] {
  let row : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    row[i] = m.psi_flat[j * n + i]
  }
  row
}

///|
// 1. THE DECISIVE ONE: the diagonal is the per-quantile VARIANCE
// ---------------------------------------------------------------------------

///|
/// `joint_covariance(HC0).get(j, j)` must be bit-identical to
/// `sandwich_variance(HC0, ...)` computed on quantile `j`'s own row.
///
/// It is deliberately NOT asserted as `== ses[j] * ses[j]`. Squaring a
/// `sqrt` is not an exact inverse in IEEE-754, so that comparison
/// differs in the last ulp for some quantiles (measured: 2 of 3
/// match bit-for-bit, one differs by 2e-19 on a value of 1.1e-3).
/// Asserting `==` there would be asserting a property of the
/// arithmetic rather than of this code, and it would fail for a
/// reason that has nothing to do with the joint covariance.
///
/// MEASURED on seed 1010, n = 500, levels [0.25, 0.5, 0.75]:
///
///     diag(0) = 0.0011482355177426264   ses^2 = 0.0011482355177426262
///     diag(1) = 0.001037568449400064    ses^2 = 0.001037568449400064
///     diag(2) = 0.0012099212109392232   ses^2 = 0.001209921210939223
///
/// so two of the three differ in the last ulp and one matches.
test "qte_joint_diagonal_is_the_se_variance" {
  let n = 500
  let n_q = 3
  let m = DoubleMLQTE::new(
    expand_v101_qte_data(n, 1010),
    quantiles=expand_v101_quantiles(),
    n_folds=2,
    seed=1010,
  ).fit()
  let sig = m.joint_covariance(SandwichKind::hc0())
  inspect(sig.rows(), content="3")
  inspect(sig.cols(), content="3")
  let ones : Array[Double] = Array::make(n, 1.0)
  let m_inv = Matrix::from_array([1.0], 1, 1)
  for j = 0; j < n_q; j = j + 1 {
    let row = expand_v101_row(m, j, n)
    let reference = sandwich_variance(
      SandwichKind::hc0(),
      ones,
      row,
      m_inv,
      n,
      1,
    )
    // The load-bearing assertion: bit-identical, not close.
    inspect(sig.get(j, j) == reference, content="true")
    // And the honest statement about the reported SE: same number,
    // to the last representable bit of the product.
    inspect(
      expand_v101_close(sig.get(j, j), m.ses()[j] * m.ses()[j]),
      content="true",
    )
    // The per-quantile accessor is still the square root of the same
    // variance -- unchanged by this release.
    inspect(
      m.sandwich_se_at(j, SandwichKind::hc0()) == m.ses()[j],
      content="true",
    )
  }
}

///|
// 2. THE NEW INFORMATION IS THERE
// ---------------------------------------------------------------------------

///|
/// The off-diagonal terms are non-zero and the matrix is symmetric.
///
/// MEASURED on seed 1010:
///
///     off(0,1) =  0.0000831188886999179   corr = +0.076
///     off(0,2) = -0.0003123459141433044   corr = -0.265
///     off(1,2) =  0.0001389538078765003   corr = +0.124
///
/// The magnitudes are the point. For a contrast of two levels the
/// variance carries a `- 2 * Sigma[j, k]` term, and here
/// `corr(0, 2) = -0.265` makes the joint variance of
/// `theta_0.75 - theta_0.25` 1.265x the one an independence
/// assumption predicts (measured, see
/// `qte_joint_differs_from_independent`). Symmetry is asserted
/// exactly, because the accumulator is walked in the same index
/// order for `(j, k)` and `(k, j)`.
test "qte_joint_offdiagonal_is_nonzero" {
  let n = 500
  let n_q = 3
  let m = DoubleMLQTE::new(
    expand_v101_qte_data(n, 1010),
    quantiles=expand_v101_quantiles(),
    n_folds=2,
    seed=1010,
  ).fit()
  let sig = m.joint_covariance(SandwichKind::hc0())
  let mut n_off = 0
  for j = 0; j < n_q; j = j + 1 {
    for k = 0; k < n_q; k = k + 1 {
      inspect(sig.get(j, k) == sig.get(k, j), content="true")
      if j != k {
        inspect(sig.get(j, k) != 0.0, content="true")
        // Every correlation is strictly inside (-1, 1): a valid
        // correlation matrix needs |corr| < 1, and a value pinned at
        // or beyond the boundary would mean the scores are
        // collinear and the joint covariance is singular.
        let c = sig.get(j, k) / (m.ses()[j] * m.ses()[k])
        inspect(c > -1.0 && c < 1.0, content="true")
        println(
          "QTE101 off(" +
          j.to_string() +
          "," +
          k.to_string() +
          ")=" +
          sig.get(j, k).to_string() +
          " corr=" +
          c.to_string(),
        )
        n_off = n_off + 1
      }
    }
  }
  inspect(n_off, content="6")
}

///|
// 3. SMALL-SAMPLE KINDS ARE A MATRIX-WIDE SCALAR
// ---------------------------------------------------------------------------

///|
/// HC1, HC2 and HC3 must move the WHOLE matrix, not just the
/// diagonal, and the diagonal must stay bit-identical to the
/// per-quantile `sandwich_variance(kind, ...)` for every kind.
///
/// The correction is deliberately applied in the same shape the
/// single-estimand path uses -- HC2/HC3 divide inside the
/// compensated accumulator, HC1 multiplies the finished sum -- so
/// the bit-identity below holds. Had the implementation used a
/// matrix-wide scalar instead (algebraically the same number for
/// this intercept-only design), HC2 and HC3 would have differed in
/// the last ulp and this test would have caught it.
test "qte_joint_small_sample_kinds" {
  let n = 500
  let n_q = 3
  let m = DoubleMLQTE::new(
    expand_v101_qte_data(n, 1010),
    quantiles=expand_v101_quantiles(),
    n_folds=2,
    seed=1010,
  ).fit()
  let base = m.joint_covariance(SandwichKind::hc0())
  let n_d = n.to_double()
  let s1 = n_d / (n_d - 1.0)
  let ones : Array[Double] = Array::make(n, 1.0)
  let m_inv = Matrix::from_array([1.0], 1, 1)
  for kd in 0..<4 {
    let kind = if kd == 0 {
      SandwichKind::hc0()
    } else if kd == 1 {
      SandwichKind::hc1()
    } else if kd == 2 {
      SandwichKind::hc2()
    } else {
      SandwichKind::hc3()
    }
    let got = m.joint_covariance(kind)
    // The relation to HC0, to rounding only. HC2 is `n / (n - 1)`
    // and HC3 its square for this design.
    let want = if kd == 0 { 1.0 } else if kd == 3 { s1 * s1 } else { s1 }
    for j = 0; j < n_q; j = j + 1 {
      for k = 0; k < n_q; k = k + 1 {
        // Every entry moves, off-diagonal included: a correction
        // that only touched the diagonal would be a per-quantile
        // correction wearing a Matrix's type.
        inspect(
          expand_v101_close(got.get(j, k), want * base.get(j, k)),
          content="true",
        )
      }
      // ... and the diagonal is the same quantity the per-quantile
      // accessor reports, bit for bit, for every kind.
      let row = expand_v101_row(m, j, n)
      let reference = sandwich_variance(kind, ones, row, m_inv, n, 1)
      inspect(got.get(j, j) == reference, content="true")
    }
  }
}

///|
// 4. THIS IS NOT A DIAGONAL MATRIX
// ---------------------------------------------------------------------------

///|
/// The anti-vacuity assertion. A covariance matrix whose off-diagonal
/// is zero is the matrix an implementation that ignored the joint
/// structure would return, and it would satisfy every diagonal test
/// above. So: build the variance a two-level contrast gets under the
/// joint covariance, compare it against the one independence
/// predicts, and require a gap large enough to change a decision.
///
/// A contrast `theta_k - theta_j` has variance
///
///     Sigma[k, k] + Sigma[j, j] - 2 * Sigma[j, k]
///
/// under the joint covariance, and the first two terms alone if the
/// levels are treated as independent. Note the SIGN: the
/// dependence measured on this DGP is negative for the (0.25, 0.75)
/// pair, so `- 2 * Sigma[j, k]` ADDS, and the joint variance is
/// LARGER than the independent one. Assuming independence therefore
/// UNDERSTATES the variance of a wide-quantile contrast -- the
/// opposite of the intuition that correlated estimates are
/// "conservative".
test "qte_joint_differs_from_independent" {
  let n = 500
  let n_q = 3
  let m = DoubleMLQTE::new(
    expand_v101_qte_data(n, 1010),
    quantiles=expand_v101_quantiles(),
    n_folds=2,
    seed=1010,
  ).fit()
  let sig = m.joint_covariance(SandwichKind::hc0())
  let joint_var = sig.get(2, 2) + sig.get(0, 0) - 2.0 * sig.get(0, 2)
  let indep_var = sig.get(2, 2) + sig.get(0, 0)
  inspect(joint_var > 0.0, content="true")
  // Negative dependence => the joint variance is the larger one.
  inspect(sig.get(0, 2) < 0.0, content="true")
  inspect(joint_var > indep_var, content="true")
  let ratio = joint_var / indep_var
  println("QTE101 joint_var/indep_var = " + ratio.to_string())
  // Measured 1.2649 on this DGP; require a gap big enough to change
  // a decision, not a rounding-level one.
  inspect(ratio > 1.2, content="true")
  // The gap is not an artefact of one pair: at least two of the three
  // unordered pairs must disagree with independence.
  let mut n_disagree = 0
  for j = 0; j < n_q; j = j + 1 {
    for k = j + 1; k < n_q; k = k + 1 {
      let jv = sig.get(k, k) + sig.get(j, j) - 2.0 * sig.get(j, k)
      if jv != sig.get(k, k) + sig.get(j, j) {
        n_disagree = n_disagree + 1
      }
    }
  }
  inspect(n_disagree, content="3")
}

///|
// 5-6. CLUSTER PATH
// ---------------------------------------------------------------------------

///|
/// With all-singleton clusters the cluster path must reproduce the IID
/// matrix EXACTLY, not approximately: `S_c[j] = psi_flat[j, i]` and
/// `scale_c = 1`, so every term of the sum is the same product the IID
/// path accumulates, in the same order. Asserted with `==` on every
/// entry.
test "qte_cluster_joint_collapses_to_iid" {
  let n = 500
  let n_q = 3
  let m = DoubleMLQTE::new(
    expand_v101_qte_data(n, 1010),
    quantiles=expand_v101_quantiles(),
    n_folds=2,
    seed=1010,
  ).fit()
  let (singleton, _) = expand_v101_cluster_ids(n)
  let iid = m.joint_covariance(SandwichKind::hc0())
  let cl = m.cluster_joint_covariance(singleton)
  for j = 0; j < n_q; j = j + 1 {
    for k = 0; k < n_q; k = k + 1 {
      inspect(cl.get(j, k) == iid.get(j, k), content="true")
    }
  }
}

///|
/// Pooled clusters must change the answer -- and the interesting part
/// is that they change the SIGN of an off-diagonal term, not merely
/// its size.
///
/// MEASURED on seed 1010:
///
///     IID     off(0,1) = +0.0000831188886999179
///     pooled  off(0,1) = -0.00007010688883157336
///
/// So the cluster path is not a diagonal rescale of the IID matrix. A
/// caller who clustered the marginal SEs but left the levels
/// independent would get the right variances and the wrong signs,
/// which is the specific failure mode this API exists to prevent.
test "qte_cluster_joint_pooled_differs" {
  let n = 500
  let n_q = 3
  let m = DoubleMLQTE::new(
    expand_v101_qte_data(n, 1010),
    quantiles=expand_v101_quantiles(),
    n_folds=2,
    seed=1010,
  ).fit()
  let (_, pooled) = expand_v101_cluster_ids(n)
  let iid = m.joint_covariance(SandwichKind::hc0())
  let cl = m.cluster_joint_covariance(pooled)
  let mut n_differ = 0
  for j = 0; j < n_q; j = j + 1 {
    for k = 0; k < n_q; k = k + 1 {
      if cl.get(j, k) != iid.get(j, k) {
        n_differ = n_differ + 1
      }
    }
  }
  // A dead cluster path (one that silently returned the IID matrix,
  // or an all-zero one) would leave n_differ at 0.
  inspect(n_differ, content="9")
  // The diagonal must still be a variance: positive and finite.
  for j = 0; j < n_q; j = j + 1 {
    inspect(cl.get(j, j) > 0.0, content="true")
    inspect(cl.get(j, j) == cl.get(j, j), content="true")
  }
  // The sign flip on (0, 1), asserted by sign rather than by the
  // exact value so the test states the structural claim.
  inspect(iid.get(0, 1) > 0.0, content="true")
  inspect(cl.get(0, 1) < 0.0, content="true")
  println(
    "QTE101 pooled off(0,1) = " +
    cl.get(0, 1).to_string() +
    " (iid " +
    iid.get(0, 1).to_string() +
    ")",
  )
}

///|
// 7. THE CACHE PATH
// ---------------------------------------------------------------------------

///|
/// The matrix must survive a memoize cache hit, driven from the
/// FITTED value: `fit` takes `self` by value and returns a NEW
/// estimator, so `est.fit()` twice never hits the cache and such a
/// test is vacuous. That mistake shipped in v0.80-v0.85 here.
///
/// `psi_flat` is written outside the `cache_hit` branch in `fit`, so
/// the hit path restores it from the same single binding as `coefs`
/// and `ses`. A regression that returned the `new()` all-zero sentinel
/// on the hit path would yield an all-zero matrix, which the
/// positivity check below catches.
test "qte_joint_after_memoize_cache_hit" {
  let n = 500
  let n_q = 3
  let est = DoubleMLQTE::new(
    expand_v101_qte_data(n, 1010),
    quantiles=expand_v101_quantiles(),
    n_folds=2,
    seed=1010,
  ).enable_memoize()
  let f1 = est.fit()
  let f2 = f1.fit()
  inspect(f1.has_cache(), content="true")
  inspect(f2.has_cache(), content="true")
  let a = f1.joint_covariance(SandwichKind::hc0())
  let b = f2.joint_covariance(SandwichKind::hc0())
  for j = 0; j < n_q; j = j + 1 {
    for k = 0; k < n_q; k = k + 1 {
      inspect(b.get(j, k) == a.get(j, k), content="true")
      inspect(b.get(j, k) == b.get(k, j), content="true")
    }
  }
  // A memoize-OFF fit of the same data must agree: the cache is a
  // performance layer, not a second estimator.
  let fresh = DoubleMLQTE::new(
    expand_v101_qte_data(n, 1010),
    quantiles=expand_v101_quantiles(),
    n_folds=2,
    seed=1010,
  ).fit()
  let c = fresh.joint_covariance(SandwichKind::hc0())
  for j = 0; j < n_q; j = j + 1 {
    for k = 0; k < n_q; k = k + 1 {
      inspect(c.get(j, k) == a.get(j, k), content="true")
    }
  }
  // The off-diagonal must survive too, not just the diagonal.
  inspect(b.get(0, 2) != 0.0, content="true")
}
