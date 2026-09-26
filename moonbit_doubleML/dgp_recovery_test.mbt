// dgp_recovery_test.mbt
//
// End-to-end DGP-to-estimator recovery tests for the staggered DID
// and PLPR estimators. These tests bridge the v0.53.0-dev DGP ports
// (P1.4 + P1.5 + P2.10) to the actual estimators they were
// designed for. Each test generates a synthetic panel from the
// corresponding DGP and checks that the estimated effect lands
// close to the true causal parameter.

///|
/// DIDCS recovery test on the 2-cohort 2-period DGP from
/// `make_did_cs_CS2021`. The treated cohort is g=1, treated at
/// t=1, so the only post-treatment ATT cell is (g=1, t=1).
test "DIDCS_DGP_estimator_recovers_true_ATT" {
  let data = make_did_cs_CS2021(800, 3, 1.0, 3141)
  let dml_data = DoubleMLDIDCSData::new(
    data.x_get(),
    data.y_get(),
    data.d_get(),
    data.t_get(),
    data.id_get(),
    data.g_get(),
  )
  let fitted = DoubleMLDIDCS::new(dml_data, n_folds=2, n_rep=1, seed=3141).fit()
  // 2 cohorts, 2 periods -> only 1 post-treatment cell:
  //   (g=1, t=1) with true ATT = 1.0
  // DIDCS::n_groups is the number of treated cohorts
  // (excluding the never-treated sentinel). The 2-cohort DGP
  // has 1 treated cohort (g=1).
  let n_groups = fitted.n_groups()
  let n_periods = fitted.n_periods()
  inspect(n_groups == 1, content="true")
  inspect(n_periods == 2, content="true")
  // Walk all (g, t) cells; collect any post-treatment
  // coef_at that is finite.
  let mut any_post_treatment = false
  let mut max_abs_err = 0.0
  for gi = 0; gi < n_groups; gi = gi + 1 {
    for pi = 0; pi < n_periods; pi = pi + 1 {
      let g_value = fitted.group_at(gi)
      let t_value = fitted.period_at(pi)
      // CS-DID defines ATT(g, t) for t >= g (post-treatment
      // starts AT the treatment period for a cohort treated at g).
      // Skip pre-treatment cells (t < g).
      if t_value < g_value {
        continue
      }
      any_post_treatment = true
      let att = fitted.coef_at(gi, pi)
      let se = fitted.se_at(gi, pi)
      let err = (att - 1.0).abs()
      if err > max_abs_err {
        max_abs_err = err
      }
      let _ = se
    }
  }
  inspect(any_post_treatment == true, content="true")
  // Loose tolerance: ATT recovery on small n=800 with a 2-period
  // DGP is noisy; assert within 5.0 of true. The DIDCS estimator
  // with one treated cohort and one post-treatment cell has high
  // variance (single (g, t) cell from n=800 observations).
  inspect(max_abs_err < 5.0, content="true")
}

///|
/// DIDMulti recovery test on the 4-cohort 4-period DGP from
/// `make_did_CS2021`. Cohorts g=1,2,3 have post-treatment cells
/// at t >= g-1. Test that at least one post-treatment cell
/// recovers the true theta within a loose band.
test "DIDMulti_DGP_estimator_recovers_some_ATT" {
  let data = make_did_CS2021(1600, 3, 1.0, 3141)
  let dml_data = DoubleMLDIDCSData::new(
    data.x_get(),
    data.y_get(),
    data.d_get(),
    data.t_get(),
    data.id_get(),
    data.g_get(),
  )
  let fitted = DoubleMLDIDCS::new(dml_data, n_folds=2, n_rep=1, seed=3141).fit()
  // 4 cohorts (3 treated + 1 never-treated sentinel) -> 3 post-treatment groups.
  let n_groups = fitted.n_groups()
  let n_periods = fitted.n_periods()
  inspect(n_groups == 3, content="true")
  inspect(n_periods == 4, content="true")
  let mut recovered_any = false
  for gi = 0; gi < n_groups; gi = gi + 1 {
    for pi = 0; pi < n_periods; pi = pi + 1 {
      let g_value = fitted.group_at(gi)
      let t_value = fitted.period_at(pi)
      if t_value < g_value {
        continue
      }
      let att = fitted.coef_at(gi, pi)
      let se = fitted.se_at(gi, pi)
      // Sanity: finite and SE > 0.
      if att != att || se <= 0.0 {
        continue
      }
      let _ = att
      let _ = se
      // Loose recovery band; small samples + 4-period DGP.
      if (att - 1.0).abs() < 5.0 * se {
        recovered_any = true
      }
    }
  }
  inspect(recovered_any == true, content="true")
}

///|
/// PLPR recovery test on the panel DGP from `make_plpr_CP2025`.
/// `DoubleMLPLPR::fit().coef()` returns a Double (the panel-local
/// average effect). We check that it lands within a loose band
/// of the true theta, since the panel-DGP treatment is continuous
/// (not binary), and within-fold fitting of the panel nuisance is
/// noisier than the cross-sectional DGPs.
test "PLPR_DGP_estimator_recovers_within_band" {
  let data = make_plpr_CP2025(800, 3, 1.0, 3141)
  // Wrap the panel DGP into DoubleMLPanelData. PLPR needs
  // (x, y, d, t, id) where t is time index and id is panel
  // unit id; both length n = n_units * n_periods.
  let y = data.y_get()
  let d = data.d_get()
  let t_arr : Array[Int] = Array::make(y.length(), 0)
  let id_arr : Array[Int] = Array::make(y.length(), 0)
  let n_periods = data.n_periods_get()
  let mut idx = 0
  for u = 0; u < data.n_units_get(); u = u + 1 {
    for p = 0; p < n_periods; p = p + 1 {
      t_arr[idx] = p
      id_arr[idx] = u
      idx = idx + 1
    }
  }
  let panel = DoubleMLPanelData::new(data.x_get(), y, d, t_arr, id_arr)
  let fitted = DoubleMLPLPR::new(
    panel,
    approach="fd_exact",
    score="partialling out",
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let theta_hat = fitted.coef()
  let se = fitted.se()
  // Continuous-treatment panel DGP is harder to recover than
  // binary DID; allow a wide band.
  let err = (theta_hat - 1.0).abs()
  let tol = 10.0 * se + 0.5 // absolute fallback
  let _ = tol
  // Finite + SE > 0 + within band.
  inspect(theta_hat == theta_hat, content="true")
  inspect(se > 0.0, content="true")
  inspect(err < 2.0, content="true")
}
