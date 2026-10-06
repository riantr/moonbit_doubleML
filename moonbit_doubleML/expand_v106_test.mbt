///|
/// v0.106.0: the cluster-robust standard errors, checked at the
/// package level rather than only in the Python cross-check.
///
/// `validate_cluster_plr_with_python.py` and
/// `validate_cluster_iv_with_python.py` gained MoonBit-side checks in
/// v0.106.0, but those only run in the cross-check CI job. These four
/// tests carry the same facts into `moon test`, which runs on all
/// four backends.
///
/// Why these facts and not others
/// =============================
/// The v0.28.0 cross-check compared `cluster SE / row SE`. That ratio
/// cannot see a variance which has lost its `1/n`: both sides of the
/// ratio are then wrong by the same factor and the comparison still
/// reads ~1.7. Measured under exactly that mutation, the old ratio
/// check reported 229.17 and passed.
///
/// So there are two shapes of check here, and the order matters:
///
///   1. ALGEBRA, no sampling content. With one cluster per
///      observation, `sum_c S_c^2` collapses to `sum_i psi[i]^2` and
///      `cluster_sandwich_se(singletons)` must reproduce `se()`.
///      Asserted at a relative 1e-14 -- there is no Monte-Carlo error
///      to tune around, only the last-ulp difference between the
///      plain mean in `var_est` and the Kahan-compensated loop in
///      `cluster_sandwich_variance`. This is the sharpest statement
///      available and it caught both mutations: dropping the `1/n^2`
///      moves the relative gap to 199 (n=200) and 799 (n=800), and
///      ignoring `cluster_ids` moves it to exactly 1.0.
///
///   2. STATISTICS. Each SE must fall by ~1/sqrt(4) when the unit
///      count goes 50 -> 200. The band is (0.40, 0.65) against
///      measurements of 0.4875 / 0.5237 / 0.5110, and it is set to
///      rule out a flat SE (~1.0) rather than to certify a rate.
///
/// What is deliberately NOT asserted is in the tests' own comments:
/// see `v106_pliv_cluster_not_always_conservative`.

///|
/// Panel DGP, same construction as `examples/cluster/main.mbt` and
/// `plr_cluster_test.mbt::build_clustered_dgp`.
///
/// MoonBit scopes a private `fn` to its own file, so this is a third
/// copy rather than a call into either of them -- the same
/// duplication `plr_cluster_test.mbt` already accepts between
/// `build_clustered_dgp` and `build_row_dgp`.
///
/// Returns a ROW-LEVEL data set (no `cluster_vars`) so a single fit
/// yields both `se()` and `cluster_sandwich_se(unit_ids)`, plus the
/// clustered twin built from the same arrays.
fn v106_build_panel(
  rng : @random.Rand,
  n_units : Int,
  n_periods : Int,
  theta0 : Double,
) -> (DoubleMLData, DoubleMLData, Array[Int]) {
  let p = 3
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let cluster : Array[Int] = Array::make(n, 0)
  for u = 0; u < n_units; u = u + 1 {
    let alpha = (rng.double() - 0.5) * 4.0
    let unit_trait = rng.double() * 2.0 - 1.0
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      let x1 = unit_trait + (rng.double() - 0.5)
      let x2 = rng.double() * 2.0 - 1.0
      x_flat[row * p] = x1
      x_flat[row * p + 1] = x2
      x_flat[row * p + 2] = unit_trait
      cluster[row] = u
      d[row] = 0.6 * x1 + 0.3 * x2 + 0.5 * alpha / 2.0 + (rng.double() - 0.5)
      y[row] = theta0 * d[row] +
        0.8 * x1 -
        0.5 * x2 +
        alpha +
        (rng.double() - 0.5) * 0.25
    }
  }
  let x = Matrix::from_array(x_flat, n, p)
  (
    DoubleMLData::new(x, y, d),
    DoubleMLData::new(x, y, d, cluster_vars=cluster),
    cluster,
  )
}

///|
fn v106_singletons(n : Int) -> Array[Int] {
  let ids = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    ids[i] = i
  }
  ids
}

///|
/// The exact-algebra claim, for PLR, at both sizes.
///
/// Measured: 3.1e-16 relative at n=200 (two ulps) and bit-identical
/// at n=800.
test "v106_plr_singleton_clusters_reproduce_row_se" {
  for n_units in [50, 200] {
    let (row_data, _, cluster) = v106_build_panel(
      chacha8_rng(7),
      n_units,
      4,
      1.0,
    )
    let fit = DoubleMLPLR::new(row_data, n_folds=2, seed=11).fit()
    let row_se = fit.se()
    let singleton_se = fit.cluster_sandwich_se(v106_singletons(n_units * 4))
    assert_true(row_se > 0.0)
    let rel = (singleton_se - row_se).abs() / row_se
    assert_true(rel < 1.0e-14)
    // The argument must be doing something: unit-level ids give a
    // materially different answer, or the whole accessor is a no-op.
    let cluster_se = fit.cluster_sandwich_se(cluster)
    assert_true((cluster_se - row_se).abs() / row_se > 0.5)
  }
}

///|
/// The same claim for PLIV. Measured bit-identical at both sizes, so
/// the tolerance here only covers summation order, never a real gap.
test "v106_pliv_singleton_clusters_reproduce_row_se" {
  for n_obs in [200, 800] {
    let cd = make_pliv_multiway_cluster(n_obs, 5, 1.0, 2718)
    let data = DoubleMLPLIVData::new(
      cd.x_get(),
      cd.y_get(),
      cd.d_get(),
      cd.z_get(),
    )
    let fit = DoubleMLPLIV::new(data, n_folds=2, seed=3141).fit()
    let row_se = fit.se()
    let singleton_se = fit.cluster_sandwich_se(v106_singletons(n_obs))
    assert_true(row_se > 0.0)
    let rel = (singleton_se - row_se).abs() / row_se
    assert_true(rel < 1.0e-14)
  }
}

///|
/// Every PLR standard error must fall by ~1/sqrt(4) when the UNIT
/// count goes 50 -> 200. `n_periods` is held at 4, so n quadruples
/// and the unit count -- the effective sample size for a clustered
/// DGP -- quadruples with it.
///
/// Three separate code paths are covered: `var_est` (row),
/// `var_est_cluster` (the `cluster_vars` fit), and
/// `cluster_sandwich_variance`. Measured ratios 0.4875 / 0.5237 /
/// 0.5110.
test "v106_plr_cluster_ses_scale_like_inverse_sqrt_n" {
  let (row_base, cluster_base_data, cluster_base) = v106_build_panel(
    chacha8_rng(7),
    50,
    4,
    1.0,
  )
  let (row_big, cluster_big_data, cluster_big) = v106_build_panel(
    chacha8_rng(7),
    200,
    4,
    1.0,
  )
  let base_row = DoubleMLPLR::new(row_base, n_folds=2, seed=11).fit()
  let big_row = DoubleMLPLR::new(row_big, n_folds=2, seed=11).fit()
  let base_clu = DoubleMLPLR::new(cluster_base_data, n_folds=2, seed=11).fit()
  let big_clu = DoubleMLPLR::new(cluster_big_data, n_folds=2, seed=11).fit()
  let pairs = [
    (base_row.se(), big_row.se()),
    (base_clu.se(), big_clu.se()),
    (
      base_row.cluster_sandwich_se(cluster_base),
      big_row.cluster_sandwich_se(cluster_big),
    ),
  ]
  for (b, g) in pairs {
    assert_true(b > 0.0 && g > 0.0)
    let ratio = g / b
    // 1/sqrt(4) = 0.5. A variance with its 1/n cancelled reads ~1.0;
    // one missing a 1/n^2 reads ~2.0 (measured: 2.044 under that
    // mutation).
    assert_true(ratio > 0.40 && ratio < 0.65)
  }
  // Clustering must inflate the SE on this DGP at both sizes: the unit
  // random effect enters both D and Y, so the row SE is too small.
  assert_true(
    base_clu.se() / base_row.se() > 1.2 && big_clu.se() / big_row.se() > 1.2,
  )
  assert_true(base_row.cluster_sandwich_se(cluster_base) / base_row.se() > 1.2)
  assert_true(big_row.cluster_sandwich_se(cluster_big) / big_row.se() > 1.2)
}

///|
/// A negative control, and the reason the PLIV checks in
/// `validate_cluster_iv_with_python.py` are shaped differently from
/// the PLR ones.
///
/// Two claims that hold for PLR and are FALSE for PLIV on the CKMS
/// two-way cluster DGP:
///
///   - `row_se` does not scale like 1/sqrt(n). Measured 0.7475 at a
///     4x step, not 0.5. At n=200 the PLIV estimate reads 1.459
///     against a true 1.0 -- 0.76 row SEs out -- and is still
///     settling when n quadruples. Asserting 1/sqrt(n) here would be
///     asserting the estimator is already in its asymptotic regime,
///     which it measurably is not.
///   - `cluster_dml_se > row_se` stops holding. It is true at n=200
///     (0.844 vs 0.603) and false at n=800 (0.440 vs 0.450).
///     `make_pliv_multiway_cluster` hard-codes 50 clusters per
///     direction, so the cluster SE cannot fall below roughly
///     1/sqrt(50) while the row SE keeps shrinking with n.
///     Clustering is not always conservative, and on a DGP with mild
///     within-cluster correlation it stops being so as n grows.
///
/// What DOES hold, and is asserted: the coefficient converges, and
/// the two cluster-robust implementations agree. Recording the two
/// negative controls here means a future attempt to "fix" the PLIV
/// checks by copying the PLR ones runs into this test.
test "v106_pliv_cluster_not_always_conservative" {
  let cd_base = make_pliv_multiway_cluster(200, 5, 1.0, 2718)
  let cd_big = make_pliv_multiway_cluster(800, 5, 1.0, 2718)
  let base_row_data = DoubleMLPLIVData::new(
    cd_base.x_get(),
    cd_base.y_get(),
    cd_base.d_get(),
    cd_base.z_get(),
  )
  let base_clu_data = DoubleMLPLIVData::new(
    cd_base.x_get(),
    cd_base.y_get(),
    cd_base.d_get(),
    cd_base.z_get(),
    cluster_vars=cd_base.cluster_a_get(),
  )
  let big_row_data = DoubleMLPLIVData::new(
    cd_big.x_get(),
    cd_big.y_get(),
    cd_big.d_get(),
    cd_big.z_get(),
  )
  let big_clu_data = DoubleMLPLIVData::new(
    cd_big.x_get(),
    cd_big.y_get(),
    cd_big.d_get(),
    cd_big.z_get(),
    cluster_vars=cd_big.cluster_a_get(),
  )
  let base_row = DoubleMLPLIV::new(base_row_data, n_folds=2, seed=3141).fit()
  let base_clu = DoubleMLPLIV::new(base_clu_data, n_folds=2, seed=3141).fit()
  let big_row = DoubleMLPLIV::new(big_row_data, n_folds=2, seed=3141).fit()
  let big_clu = DoubleMLPLIV::new(big_clu_data, n_folds=2, seed=3141).fit()

  // Holds, and is asserted: convergence to the true 1.0.
  assert_true((base_clu.coef() - 1.0).abs() > (big_clu.coef() - 1.0).abs())
  assert_true((big_clu.coef() - 1.0).abs() < 0.20)

  // Holds, and is asserted: the cluster-side SEs still carry their
  // 1/sqrt(n). Measured 0.5208 (var_est_cluster) and 0.5721
  // (cluster_sandwich_variance).
  for
    (b, g) in [
      (base_clu.se(), big_clu.se()),
      (
        base_row.cluster_sandwich_se(cd_base.cluster_a_get()),
        big_row.cluster_sandwich_se(cd_big.cluster_a_get()),
      ),
    ] {
    let ratio = g / b
    assert_true(ratio > 0.40 && ratio < 0.75)
  }

  // Holds, and is asserted: two independent implementations of the
  // cluster-robust variance agree. Measured 0.9424 and 1.0352.
  for
    (a, c) in [
      (base_row.cluster_sandwich_se(cd_base.cluster_a_get()), base_clu.se()),
      (big_row.cluster_sandwich_se(cd_big.cluster_a_get()), big_clu.se()),
    ] {
    let r = a / c
    assert_true(r > 1.0 / 1.5 && r < 1.5)
  }

  // The two negative controls, asserted so they cannot silently
  // change. If a future DGP or a future fix breaks either of these,
  // this test fails and the PLIV assertions in the cross-check have to
  // be re-derived rather than inherited.
  let row_ratio = big_row.se() / base_row.se()
  assert_true(row_ratio > 0.65)
  assert_true(row_ratio < 0.85)
  assert_true(base_clu.se() / base_row.se() > 1.2)
  assert_true(big_clu.se() < big_row.se())
}
