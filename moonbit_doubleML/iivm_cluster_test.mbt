///|
/// IIVM cluster-robust tests. The `build_iv_clustered_dgp`
/// helper is imported from `pliv_cluster_test.mbt` (same
/// panel structure for the shared instrument case).
test "iivm_cluster_deterministic" {
  let rng = chacha8_rng(42)
  let (x, y, d, z, cluster) = build_iv_clustered_dgp(rng, 30, 4, 1.0, 0.7)
  let data_c = DoubleMLIIVMData::new(x, y, d, z, cluster_vars=cluster)
  let f1 = DoubleMLIIVM::new(data_c, n_folds=2, seed=7).fit()
  let f2 = DoubleMLIIVM::new(data_c, n_folds=2, seed=7).fit()
  inspect((f1.coef() - f2.coef()).abs() < 1.0e-15, content="true")
  inspect((f1.se() - f2.se()).abs() < 1.0e-15, content="true")
}

///|
/// Cluster SE is finite and bounded on the same weak-IV panel
/// where the row-level IRM path can produce large or unstable
/// SEs. We assert finite + positive + bounded rather than
/// `cluster_se > row_se`: for IIVM (and PLIV), a near-zero
/// `J = mean(psi_a)` in a row-level fold can inflate the
/// row-level SE by orders of magnitude. The cluster path's
/// fold-weighted ratio lands at a stable point.
test "iivm_cluster_se_finite_and_stable" {
  let rng = chacha8_rng(7)
  let (x, y, d, z, cluster) = build_iv_clustered_dgp(rng, 50, 4, 1.0, 0.7)
  let data_c = DoubleMLIIVMData::new(x, y, d, z, cluster_vars=cluster)
  let data_r = DoubleMLIIVMData::new(x, y, d, z)
  let clustered = DoubleMLIIVM::new(data_c, n_folds=2, seed=11).fit()
  let row = DoubleMLIIVM::new(data_r, n_folds=2, seed=11).fit()
  println(
    "iivm_cluster_se_finite: cluster_coef=" +
    clustered.coef().to_string() +
    " cluster_se=" +
    clustered.se().to_string() +
    " row_se=" +
    row.se().to_string(),
  )
  inspect(clustered.coef() == clustered.coef(), content="true")
  inspect(clustered.se() == clustered.se(), content="true")
  inspect(clustered.se() > 0.0, content="true")
  inspect(clustered.se() < 100.0, content="true")
}

///|
/// `is_cluster_data` semantics on DoubleMLIIVMData.
test "iivm_cluster_data_class" {
  let rng = chacha8_rng(1)
  let (x, y, d, z, cluster) = build_iv_clustered_dgp(rng, 20, 3, 0.5, 0.7)
  let data_c = DoubleMLIIVMData::new(x, y, d, z, cluster_vars=cluster)
  let data_r = DoubleMLIIVMData::new(x, y, d, z)
  inspect(data_c.is_cluster_data(), content="true")
  inspect(data_r.is_cluster_data(), content="false")
  inspect(data_c.n_cluster_vars() == data_c.n_obs(), content="true")
}
