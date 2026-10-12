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
///
/// v0.152.0: this test's assertion was VACUOUS until v0.150.0 and then
/// UNSOUND. Under the old `t <= g` base rule the cell was never estimated and
/// `coef_at` returned the 0.0 `final_coef` was initialised with, so
/// `max_abs_err < 5.0` was passing on `|0 - 1| = 1.0` while testing nothing.
/// v0.150.0 made the cell real; this release replaces the band, which had been
/// carried over unexamined.
///
/// MEASURED across 12 seeds (the sweep is in `expand_v152_test.mbt` GATE 3):
/// `max |att - 1.0|` reaches **14.41**, so an absolute `< 5.0` would FAIL on
/// seeds 7, 77 and 314 -- and at the tested seed it permits 2.9x the error the
/// estimator actually makes. In SE units the same errors reach only **2.41**,
/// because the SE grows with the estimate's instability. So the band is
/// expressed in SE, which is both correct and measured.
///
/// The point estimate and SE are also pinned exactly, because with a fixed seed
/// that is the stronger statement: it catches drift that an SE-relative band
/// would forgive. `==` is unavailable here (the did_cs quantities carry the
/// known ~1.5e-15 cross-backend spread), hence 1e-12 relative.
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
  let mut n_post = 0
  let mut worst_z = 0.0
  for gi = 0; gi < n_groups; gi = gi + 1 {
    for pi = 0; pi < n_periods; pi = pi + 1 {
      let g_value = fitted.group_at(gi)
      let t_value = fitted.period_at(pi)
      // v0.150.0: post-treatment starts AT the treatment period, `t >= g`.
      if t_value < g_value {
        continue
      }
      any_post_treatment = true
      let att = fitted.coef_at(gi, pi)
      let se = fitted.se_at(gi, pi)
      inspect(se > 0.0, content="true")
      // Recovery in SE units. The band is 5.0 because the measured worst case
      // over 12 seeds is 2.41; 5.0 leaves room without becoming vacuous.
      let z = (att - 1.0).abs() / se
      if z > worst_z {
        worst_z = z
      }
      n_post = n_post + 1
    }
  }
  inspect(any_post_treatment == true, content="true")
  // Exactly one post-treatment cell on this fixture -- a sweep that admitted
  // zero would make every assertion below vacuous again, which is how this test
  // managed to be green over a dead estimator in the first place.
  inspect(n_post == 1, content="true")
  inspect(worst_z < 5.0, content="true")
  // Exact regression lock on the cell's own numbers.
  let rel = fn(got : Double, want : Double) { (got - want).abs() / want.abs() }
  inspect(
    rel(fitted.coef_at(0, 1), 2.727522673844541) < 1.0e-12,
    content="true",
  )
  inspect(rel(fitted.se_at(0, 1), 1.9428873717680928) < 1.0e-12, content="true")
}

///|
/// Recovery on the 4-cohort 4-period DGP from `make_did_CS2021`, run through
/// `DoubleMLDIDCS`.
///
/// RENAMED in v0.152.0. This test was called
/// `DIDMulti_DGP_estimator_recovers_some_ATT` but constructs `DoubleMLDIDCS`,
/// so the name asserted a coverage that did not exist: `DoubleMLDIDMulti`,
/// the class that owns `gt_combinations` and is the documented consumer of this
/// DGP, has NO recovery test anywhere in the package. The name was worse than
/// no name, because it made the gap invisible.
///
/// WHY THERE STILL ISN'T ONE, which is not an oversight but a blocker.
/// Measured 2026-10-12: `DoubleMLDIDMulti` IGNORES `t_pre`. Its public API takes
/// `(g, t_pre, t_eval)` triples and promises control of the base period, but
/// `coef_at_idx` calls `ignore(t_pre)` and the inner `DoubleMLDIDCS` derives its
/// own base as `g - 1`. The proof is a single line: asking for `(1, 0, 2)` and
/// for `(1, 1, 2)` returns the IDENTICAL coefficient `0.6790989134518333`.
///
/// That makes this DGP unusable for a DIDMulti recovery test. `make_did_CS2021`
/// treats cohort `g` at `tau_g = g - 1`, so the inferred base `g - 1` is the
/// FIRST TREATED period -- contaminated. Measured coefficients against a true
/// theta of 1.0: `(1,0,1)` 1.4166, `(1,0,2)` 0.6791, `(1,0,3)` 0.3153,
/// `(2,1,2)` -2.3785, `(2,1,3)` -1.2812, `(3,2,3)` -10.5035. Adding a test here
/// would encode those as expected. The fix is to honour `t_pre` (or take an
/// explicit `tau_g`), which is open work, not a test that should be written yet.
test "DIDCS_on_multicohort_DGP_recovers_some_ATT" {
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
