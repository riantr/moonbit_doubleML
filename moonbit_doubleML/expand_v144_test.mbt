// v0.144.0 -- GATES for the DoubleMLPLR sensitivity nu2/sigma2 correction.
//
// WHAT THESE ASSERT, AND WHY THE OLD GATE WAS BLIND. The pre-existing gate
// (`v066_wbtest.mbt:44 plr_sensitivity_returns_finite_result`) asserts only
// `!is_nan` on all four returned fields. A gate written on finiteness cannot
// see a value being wrong by a factor of 60, so the defect it was supposed to
// cover was invisible to it -- the v0.138.0 lesson (a gate whose inputs do not
// read the thing under test is decoration) in its purest form.
//
// Every gate below reads the fitted object and recomputes the formula
// INDEPENDENTLY, then compares to what the API returned. They are written to
// fail on the pre-fix code; `mut_v1440_plr.ps1` proves that by re-applying the
// old formula and requiring every one of them to go red.
//
// THE FIXTURE is the one the measurement used (n = 500, seed 20261), because a
// gate that only passes on the day it was written has not been checked against
// anything. Two seeds are used so the assertions are not tied to one draw.

///|
/// Confounded PLR design. Seeded; `n = 500, seed 20261` reproduces the
/// v0.144.0 measurement exactly.
fn v1440_plr_fixture(
  n : Int32,
  seed : Int32,
  p : Int32,
) -> (Matrix, Array[Double], Array[Double]) {
  let rng = chacha8_rng(seed)
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let mut acc = 0.0
    for j = 0; j < p; j = j + 1 {
      let xj = rng.double() * 2.0 - 1.0
      x.set(i, j, xj)
      acc = acc + xj
    }
    let x0 = x.get(i, 0)
    let pi = 0.5 + 0.3 * x0
    let di = if rng.double() < pi { 1.0 } else { 0.0 }
    d[i] = di
    y[i] = 0.5 + 1.0 * x0 + 1.5 * di + 0.5 * acc + (rng.double() - 0.5) * 2.0
  }
  (x, y, d)
}

///|
fn v1440_plr_fit(n : Int32, seed : Int32, data_seed : Int32) -> DoubleMLPLR {
  let (x, y, d) = v1440_plr_fixture(n, data_seed, 2)
  let data = DoubleMLData::new(x, y, d)
  DoubleMLPLR::new(data, n_folds=4, seed~).fit()
}

///|
/// GATE 1. `nu2` is `1 / mean((d - m_hat)^2)` -- upstream `plr.py:291` --
/// and is NOT the fourth moment `mean((d - m_hat)^4)` the legacy helper
/// produced by squaring the score element `psi_a = -(d - m_hat)^2`.
///
/// Exact equality, not a tolerance: the defect was not a small drift, and a
/// tolerance wide enough to be safe against float noise would be far too wide
/// to notice a 60x error.
test "plr_sensitivity_nu2_is_the_reciprocal_second_moment" {
  let fitted = v1440_plr_fit(500, 5, 20261)
  let r = fitted.sensitivity_analysis()
  let m_hat = fitted.predictions_m()
  let d = fitted.data.d
  let n = m_hat.length()
  let mut ss_v2 = 0.0
  let mut ss_v4 = 0.0
  for i = 0; i < n; i = i + 1 {
    let v2 = (d[i] - m_hat[i]) * (d[i] - m_hat[i])
    ss_v2 = ss_v2 + v2
    ss_v4 = ss_v4 + v2 * v2
  }
  let n_d = n.to_double()
  let nu2_upstream = 1.0 / (ss_v2 / n_d)
  let nu2_old = ss_v4 / n_d
  // The quantity the old code actually returned.
  assert_true(r.nu2 == nu2_upstream)
  // And it is not that, on this fixture, by a wide margin.
  assert_true(r.nu2 != nu2_old)
}

///|
/// GATE 2. `sigma2` is `mean((y - l_hat - theta*(d - m_hat))^2)` -- upstream
/// `plr.py:281` -- not `mean((y - l_hat)^2)`. The `theta * v` centring is what
/// removes the explained signal; without it the "residual variance" still
/// contains the coefficient's own contribution.
test "plr_sensitivity_sigma2_is_centred_by_theta_times_v" {
  let fitted = v1440_plr_fit(500, 5, 20261)
  let r = fitted.sensitivity_analysis()
  let l_hat = fitted.predictions_l()
  let m_hat = fitted.predictions_m()
  let d = fitted.data.d
  let y = fitted.data.y
  let theta = fitted.coef()
  let n = l_hat.length()
  let mut ss_centred = 0.0
  let mut ss_uncentred = 0.0
  for i = 0; i < n; i = i + 1 {
    let u = y[i] - l_hat[i]
    ss_uncentred = ss_uncentred + u * u
    let w = u - theta * (d[i] - m_hat[i])
    ss_centred = ss_centred + w * w
  }
  let n_d = n.to_double()
  assert_true(r.sigma2 == ss_centred / n_d)
  assert_true(r.sigma2 != ss_uncentred / n_d)
}

///|
/// GATE 3. The returned `max_bias` and `rv` follow from `sigma2` and `nu2`
/// alone -- `sqrt(sigma2*nu2)` and `|theta| / sqrt(sigma2*nu2)`. This is the
/// reason the rest of the result changed when the baselines were corrected,
/// and it is the assertion that pins THAT rather than pinning a magic constant.
///
/// WHY A RELATIVE TOLERANCE HERE AND NOT EXACT EQUALITY. `max_bias` is
/// produced by summing `n` copies of the same constant and dividing by `n`
/// (`sensitivity.mbt`), which is not bit-reversible, so exact equality is not
/// available -- and a first draft of this gate asserted it and failed. The
/// fix is to weaken the ASSERTION, not the code: the quantity is mathematically
/// the constant, and 1e-12 relative is far tighter than any error this gate
/// needs to detect (the defect being guarded was a factor of 60).
///
/// GATES 1, 2 and 5 DO assert exact equality, because those compare a single
/// accumulation against another, with no reduction step in between.
test "plr_sensitivity_rv_and_max_bias_follow_from_the_two_baselines" {
  let fitted = v1440_plr_fit(500, 5, 20261)
  let r = fitted.sensitivity_analysis()
  let m = (r.sigma2 * r.nu2).sqrt()
  let rel = fn(a : Double, b : Double) { (a - b).abs() / m }
  assert_true(rel(r.max_bias, m) < 1.0e-12)
  assert_true(rel(r.rv, fitted.coef().abs() / m) < 1.0e-12)
}

///|
/// GATE 4. NOT a single-draw assertion. The correction is re-checked on a
/// second seed, because v0.139.0's lesson was a verdict drawn from too few
/// probes: one fixture can agree with a wrong formula by luck.
test "plr_sensitivity_nu2_formula_holds_on_a_second_seed" {
  let fitted = v1440_plr_fit(400, 9, 777)
  let r = fitted.sensitivity_analysis()
  let m_hat = fitted.predictions_m()
  let d = fitted.data.d
  let n = m_hat.length()
  let mut ss_v2 = 0.0
  for i = 0; i < n; i = i + 1 {
    let v = d[i] - m_hat[i]
    ss_v2 = ss_v2 + v * v
  }
  assert_true(r.nu2 == 1.0 / (ss_v2 / n.to_double()))
}

///|
/// GATE 5. A regression guard on the cluster path. Upstream's core package has
/// no cluster sensitivity method at all, so there is no upstream number to
/// match -- the assertion is instead that the cluster baseline is the
/// reciprocal of the cluster second-moment baseline (the analogue of the IID
/// rule), and that it is NOT the legacy cluster sum of the squared score
/// element. Without this the cluster path could silently keep the old shape.
test "plr_sensitivity_cluster_nu2_is_reciprocal_cluster_second_moment" {
  let (x, y, d) = v1440_plr_fixture(400, 4242, 2)
  // 10 clusters of 40.
  let cluster_ids : Array[Int32] = Array::make(400, 0)
  for i = 0; i < 400; i = i + 1 {
    cluster_ids[i] = i / 40
  }
  let data = DoubleMLData::new(x, y, d, cluster_vars=cluster_ids)
  let fitted = DoubleMLPLR::new(data, n_folds=4, seed=3).fit()
  let r = fitted.sensitivity_analysis_cluster()
  let m_hat = fitted.predictions_m()
  let n = m_hat.length()
  let n_clusters = 10
  let cl_v : Array[Double] = Array::make(n_clusters, 0.0)
  for i = 0; i < n; i = i + 1 {
    let cid = i / 40
    cl_v[cid] = cl_v[cid] + (d[i] - m_hat[i])
  }
  let mut ss = 0.0
  for c = 0; c < n_clusters; c = c + 1 {
    ss = ss + cl_v[c] * cl_v[c]
  }
  let nu2_expected = 1.0 / (ss / n_clusters.to_double())
  assert_true(r.nu2 == nu2_expected)
}

///|
/// GATE 6. A sanity gate on the DIRECTION of the centring correction.
/// Removing `theta * v` from the residual must leave strictly LESS variance
/// than leaving it in -- if the centring were dropped, or signed wrong, this
/// flips. The margin assertion is what stops it from passing on float noise:
/// on this fixture the gap is a large fraction of the quantity, and a centring
/// that were numerically negligible could not be distinguished from a correct
/// one by a gate this coarse.
test "plr_sensitivity_uncorrected_baseline_would_exceed_corrected_one" {
  let fitted = v1440_plr_fit(500, 5, 20261)
  let r = fitted.sensitivity_analysis()
  let l_hat = fitted.predictions_l()
  let y = fitted.data.y
  let n = l_hat.length()
  let mut ss_un = 0.0
  for i = 0; i < n; i = i + 1 {
    let u = y[i] - l_hat[i]
    ss_un = ss_un + u * u
  }
  let sigma2_uncentred = ss_un / n.to_double()
  assert_true(sigma2_uncentred > r.sigma2)
  // Not a rounding artefact: the gap is a real fraction of the quantity.
  assert_true((sigma2_uncentred - r.sigma2) / sigma2_uncentred > 0.1)
}
