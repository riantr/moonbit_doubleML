// Demo: cluster-robust standard errors, at TWO sample sizes.
//
// WHY TWO SIZES, AND WHY THIS EXAMPLE EXISTS
// ==========================================
// `validate_cluster_plr_with_python.py` and
// `validate_cluster_iv_with_python.py` compared `cluster SE / row SE`
// on a single sample and reported the result. That ratio is the right
// thing to look at for a wrong cluster MEAT, and the wrong thing to
// look at for a wrong cluster SCALE: both the numerator and the
// denominator are off by the same factor, so a variance that lost
// its `1/n` entirely still passes `cluster SE / row SE > 1.2`.
//
// So the check that actually matters is absolute: does each SE fall
// like `1 / sqrt(n)` when n grows? This example therefore reports
// every SE at `n_obs` and again at 4x the units, so a validator can
// take the ratio. The DIDCS cross-check in v0.102.0 found a real
// -15% bias and a flat SE exactly this way, and the LZZ2020 DGP in
// `examples/lplr` shows the other failure mode: on a noisy DGP the
// SE does not shrink cleanly at small n, so the band has to be
// chosen from measurement rather than from theory.
//
// The three SEs are three different code paths and all three must
// shrink together:
//
//   row_se        `se()` on a fit with no cluster_vars -> `var_est`
//   cluster_dml_se `se()` on a fit whose data carries
//                 `cluster_vars` -> `var_est_cluster`, which folds
//                 over whole units and carries a `1 / n_units`
//   sandwich_se   `cluster_sandwich_se(unit_ids)` on the ROW-level
//                 fit -> `cluster_sandwich_variance`, whose variance
//                 is `M_inv^2 * sum_c S_c^2 * n_c/(n_c-1) / n^2`
//
// and `singleton_se` is the exact control: with every observation in
// its own cluster, the sum over clusters collapses to the sum over
// observations, so `cluster_sandwich_se(singletons)` must reproduce
// `se()`. That one is an algebraic identity, not a statistical
// claim, and it is the sharpest assertion available here.

///|
/// Panel DGP, mirroring `plr_cluster_test.mbt::build_clustered_dgp`.
///
/// Returns a ROW-LEVEL `DoubleMLData` (no `cluster_vars`) plus the
/// unit id vector, so a single fit yields both `se()` and
/// `cluster_sandwich_se(unit_ids)`. The clustered twin is built by
/// the caller from the same arrays, which keeps the two fits on
/// byte-identical data.
fn build_panel(
  rng : @random.Rand,
  n_units : Int,
  n_periods : Int,
  theta0 : Double,
) -> (
  @moonbit_doubleML.DoubleMLData,
  @moonbit_doubleML.DoubleMLData,
  Array[Int],
) {
  let p = 3
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let cluster : Array[Int] = Array::make(n, 0)
  for u = 0; u < n_units; u = u + 1 {
    // Unit-level random effects: D and Y are correlated WITHIN a
    // unit, which is exactly why the row-level SE is too small.
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
  let x = @moonbit_doubleML.Matrix::from_array(x_flat, n, p)
  let row_data = @moonbit_doubleML.DoubleMLData::new(x, y, d)
  let cluster_data = @moonbit_doubleML.DoubleMLData::new(
    x,
    y,
    d,
    cluster_vars=cluster,
  )
  (row_data, cluster_data, cluster)
}

///|
/// All-singleton cluster ids: one cluster per observation.
fn singleton_ids(n : Int) -> Array[Int] {
  let ids = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    ids[i] = i
  }
  ids
}

///|
/// The three PLR SEs (plus the singleton control) at one size.
fn plr_line(
  tag : String,
  n_units : Int,
  n_periods : Int,
  seed : Int,
  fit_seed : Int,
) -> String {
  let (row_data, cluster_data, cluster) = build_panel(
    @moonbit_doubleML.chacha8_rng(seed),
    n_units,
    n_periods,
    1.0,
  )
  let row_fit = @moonbit_doubleML.DoubleMLPLR::new(
    row_data,
    n_folds=2,
    seed=fit_seed,
  ).fit()
  let cluster_fit = @moonbit_doubleML.DoubleMLPLR::new(
    cluster_data,
    n_folds=2,
    seed=fit_seed,
  ).fit()
  let n_obs = n_units * n_periods
  let row_se = row_fit.se()
  let cluster_dml_se = cluster_fit.se()
  let sandwich_se = row_fit.cluster_sandwich_se(cluster)
  let singleton_se = row_fit.cluster_sandwich_se(singleton_ids(n_obs))
  "plr \{tag} n=\{n_obs} theta=\{row_fit.coef()} row_se=\{row_se} cluster_dml_se=\{cluster_dml_se} sandwich_se=\{sandwich_se} singleton_se=\{singleton_se}"
}

///|
/// The same three SEs for PLIV on the CKMS 2021 two-way cluster DGP.
///
/// `make_pliv_multiway_cluster` hard-codes 50 clusters in each
/// direction, so this is NOT a clean 4x in effective sample size the
/// way the PLR panel is: the cluster count stays fixed and only the
/// per-cluster counts grow. Both SEs still have to move, and their
/// RATIO has to stay put, which is what the validator checks. Using
/// `cluster_a` as the one-way id is the right comparison because
/// `cluster_sandwich_se` takes a single id vector -- there is no
/// two-way accessor in this package.
fn pliv_line(
  tag : String,
  n_obs : Int,
  dim_x : Int,
  seed : Int,
  fit_seed : Int,
) -> String {
  let cd = @moonbit_doubleML.make_pliv_multiway_cluster(n_obs, dim_x, 1.0, seed)
  let x = cd.x_get()
  let y = cd.y_get()
  let d = cd.d_get()
  let z = cd.z_get()
  let ca = cd.cluster_a_get()
  let row_data = @moonbit_doubleML.DoubleMLPLIVData::new(x, y, d, z)
  let cluster_data = @moonbit_doubleML.DoubleMLPLIVData::new(
    x,
    y,
    d,
    z,
    cluster_vars=ca,
  )
  let row_fit = @moonbit_doubleML.DoubleMLPLIV::new(
    row_data,
    n_folds=2,
    seed=fit_seed,
  ).fit()
  let cluster_fit = @moonbit_doubleML.DoubleMLPLIV::new(
    cluster_data,
    n_folds=2,
    seed=fit_seed,
  ).fit()
  let row_se = row_fit.se()
  let cluster_dml_se = cluster_fit.se()
  let sandwich_se = row_fit.cluster_sandwich_se(ca)
  let singleton_se = row_fit.cluster_sandwich_se(singleton_ids(n_obs))
  "pliv \{tag} n=\{n_obs} theta=\{row_fit.coef()} row_se=\{row_se} cluster_dml_se=\{cluster_dml_se} sandwich_se=\{sandwich_se} singleton_se=\{singleton_se}"
}

///|
fn main {
  println("=== MoonBit DML demo: cluster-robust standard errors ===")
  println("true theta = 1.0 (PLR panel and PLIV CKMS2021 two-way cluster)")
  println("")
  // n_periods is held at 4 and the UNIT count is what grows, so the
  // 4x step is 4x the units and 4x the observations. For a clustered
  // DGP the unit count is the effective sample size, so this is the
  // axis on which every one of these SEs is required to shrink.
  println(plr_line("base", 50, 4, 7, 11))
  println(plr_line("big", 200, 4, 7, 11))
  println(pliv_line("base", 200, 5, 2718, 3141))
  println(pliv_line("big", 800, 5, 2718, 3141))
  println("cluster example done")
}
