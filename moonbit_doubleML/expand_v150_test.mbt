// expand_v150_test.mbt
//
// v0.150.0 -- THE ESTIMAND FIX: base period `g - 1`, so `ATT(g, g)` exists.
//
// What was wrong, in one sentence: `DoubleMLDIDCS::fit` used the cohort's OWN
// treatment period as the pre-treatment baseline and then required
// `eval_period > pre_period`, so it could only ever reach `t > g`. `ATT(g, g)`
// -- the ATT in the FIRST treated period -- was therefore never estimated, on
// any panel, ever.
//
// Why that was not merely a missing feature. On the canonical fixture
// `make_did_cs_CS2021(800, 3, 1.0, 3141)` the panel is groups=[1], times=[0,1],
// so `t > g` admits NOTHING at all. `final_coef` is zero-initialised
// (`did_cs.mbt:1581`), so `coef_at(0, 1)` returned the 0.0 it was created with,
// and `dgp_recovery_test`'s `max_abs_err < 5.0` passed on `|0 - 1| = 1.0` while
// claiming to recover an ATT of 1.0. That test had been asserting against a
// hardcoded zero since it was written. The fixture's own DGP treats cohort 1
// from `k >= cohort`, and `dgp_recovery_test` documents CS's convention as
// `ATT(g, t)` for `t >= g` -- so the ESTIMATOR was the only thing in the package
// that disagreed with both its own fixture and its own documentation.
//
// The CS convention (Callaway & Sant'Anna): a cohort treated AT period `g` is
// untreated in `g - 1`, and post-treatment begins AT `g`. Hence base = `g - 1`
// and the live boundary is `t >= g`.
//
// Two sites changed, and they had to move TOGETHER: the fit loop that estimates
// cells, and the reassembly pass that copies `coef_values_acc` into `final_coef`
// through a `coef_idx` CURSOR. A predicate that disagreed by even one cell
// would shift every later cell's coefficient.

///|
/// The deterministic fixture used by GATE 3. It is rebuilt here rather than
/// imported because MoonBit blackbox test files are separate packages, and
/// duplicating it is a virtue: a gate that depends on another test file's
/// helper cannot tell a fixture change from a code change.
///
/// Crucially this fixture satisfies DIDCS's convention -- cohort `g` is treated
/// from `k >= g`, so `g` IS the treatment period, and the effect appears from
/// `k > g`. That makes each cell's true ATT exactly known.
fn v1500_conforming_data() -> DoubleMLDIDCSData {
  let n_per_cohort = 50
  let p = 3
  let theta = 1.0
  let n_periods = 4
  let cohort_count = 4
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int32] = Array::make(n, 0)
  let g_arr : Array[Int32] = Array::make(n, 0)
  let id_arr : Array[Int32] = Array::make(n, 0)
  let rng = chacha8_rng(11)
  for u = 0; u < n_units; u = u + 1 {
    let cohort = u / n_per_cohort
    let xu : Array[Double] = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      xu[j] = rng.double() * 2.0 - 1.0
    }
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = xu[j]
      }
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = cohort
      d[row] = if cohort > 0 && k >= cohort { 1.0 } else { 0.0 }
      let mut y_val = 0.0
      for j = 0; j < p; j = j + 1 {
        y_val = y_val + xu[j]
      }
      if cohort > 0 && k > cohort {
        y_val = y_val + theta
      }
      y_val = y_val + 0.05 * (rng.double() - 0.5)
      y[row] = y_val
    }
  }
  DoubleMLDIDCSData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
}

///|
fn v1500_conforming() -> DoubleMLDIDCS {
  DoubleMLDIDCS::new(v1500_conforming_data(), n_folds=2, n_rep=1, seed=3141).fit()
}

///|
fn v1500_canonical() -> DoubleMLDIDCS {
  let d = make_did_cs_CS2021(800, 3, 1.0, 3141)
  DoubleMLDIDCS::new(
    DoubleMLDIDCSData::new(
      d.x_get(),
      d.y_get(),
      d.d_get(),
      d.t_get(),
      d.id_get(),
      d.g_get(),
    ),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
}

///|
/// GATE 1. THE GATE THAT WAS MISSING, and the whole reason this release
/// exists. On the canonical 2-period panel, the single post-treatment cell
/// (g=1, t=1) must now carry an ACTUAL ESTIMATE, not the zero sentinel.
///
/// The structural witness is the populated per-cell IF row, not `coef != 0.0`:
/// a coefficient could be non-zero by accident. `cell_psi_a` is empty for a
/// cell the fit loop never visited and length-`n_wide` for one it did, which is
/// the property the old bug actually violated.
///
/// DECLARED DISCRIMINATING, and the mutation run is why: M1 (base back to `g`)
/// and M2 (boundary back to `<=`) both empty this row, M3 (mirror site out of
/// step) misaligns the cursor so this reads another cell's row.
test "didcs_att_g_g_is_actually_estimated" {
  let f = v1500_canonical()
  assert_true(f.n_groups() == 1)
  assert_true(f.n_periods() == 2)
  // The per-cell arrays are GRID-sized, not sized by the number of cells that
  // happened to be estimated. Asserted first, because everything below indexes
  // them by the flat (gi, pi) cursor -- if this ever failed, the failures after
  // it would be out-of-bounds aborts rather than readable assertion failures.
  // `Array::length`, not `.length`: `cell_psi_a` is an abstract `Array`, so
  // method syntax does not resolve on it here.
  assert_true(Array::length(f.cell_psi_a) == f.n_groups() * f.n_periods)
  assert_true(Array::length(f.cell_psi_b) == f.n_groups() * f.n_periods)
  // (g=1, t=1) is the post-treatment cell. flat = gi * n_periods + pi = 1.
  assert_true(f.cell_psi_a[1].length() > 0)
  assert_true(f.cell_psi_b[1].length() > 0)
  // And it is not the sentinel the old rule left behind.
  assert_true(f.coef_at(0, 1) != 0.0)
}

///|
/// GATE 2. THE BOUNDARY ITSELF, as a partition rather than one cell. `t < g` is
/// pre-treatment: no estimate, empty row, `se_at` legitimately 0.0. `t >= g` is
/// post-treatment: populated row, real SE. A regression that moved the boundary
/// in EITHER direction breaks one side of this.
test "didcs_live_boundary_is_t_at_least_g" {
  let f = v1500_conforming()
  let n_periods = f.n_periods()
  for gi = 0; gi < f.n_groups(); gi = gi + 1 {
    let g_value = f.group_at(gi)
    for pi = 0; pi < n_periods; pi = pi + 1 {
      let flat = gi * n_periods + pi
      if f.period_at(pi) < g_value {
        assert_true(f.cell_psi_a[flat].length() == 0)
        assert_true(f.cell_psi_b[flat].length() == 0)
        assert_true(f.se_at(gi, pi) == 0.0)
        assert_true(f.coef_at(gi, pi) == 0.0)
      } else {
        assert_true(f.cell_psi_a[flat].length() > 0)
        assert_true(f.se_at(gi, pi) > 0.0)
      }
    }
  }
}

///|
/// GATE 3. THE PAYOFF: does the fixed estimator actually RECOVER the ATT?
///
/// Every other gate here can be satisfied by a change that merely makes the
/// cells non-empty. This one pins the estimator to the truth, on the fixture
/// where `g` really is the treatment period. True ATT is 1.0 wherever the
/// effect has appeared (`k > g`) and exactly 0.0 at `k == g` -- the treatment
/// period itself carries no effect yet in this DGP, so the newly-live cells
/// should read ~0 and the later ones ~1.
///
/// Measured 2026-10-12 on this fixture:
///   (g=1,t=1) -> 0.0000 vs true 0.0
///   (g=1,t=2) -> 0.9965 vs true 1.0      (g=1,t=3) -> 0.9982 vs true 1.0
///   (g=2,t=2) -> -0.0052 vs true 0.0     (g=2,t=3) -> 1.0042 vs true 1.0
///   (g=3,t=3) ->  0.0094 vs true 0.0
/// Every non-degenerate cell is within 0.5% of the truth. That is the
/// measurement that justifies calling `g - 1` the right base period rather than
/// merely a defensible one.
test "didcs_recovers_true_att_on_a_convention_conforming_panel" {
  let f = v1500_conforming()
  // (g, t) -> true ATT: the effect switches on at k = g + 1.
  let truth : Array[(Int32, Int32, Double)] = [
    (0, 1, 0.0),
    (0, 2, 1.0),
    (0, 3, 1.0),
    (1, 2, 0.0),
    (1, 3, 1.0),
    (2, 3, 0.0),
  ]
  assert_true(truth.length() == 6)
  for entry in truth {
    let (gi, pi, want) = entry
    assert_true(f.cell_psi_a[gi * f.n_periods() + pi].length() > 0)
    let got = f.coef_at(gi, pi)
    // Within 0.5% of the truth, or within 0.02 absolute where the truth is 0.
    let err = (got - want).abs()
    let tol = if want == 0.0 { 0.02 } else { 0.005 * want.abs() }
    assert_true(err < tol)
  }
}

///|
/// GATE 4. EXACT REGRESSION LOCK on the canonical panel. This quantity is the
/// headline number users saw change, so it is pinned exactly rather than to a
/// tolerance. `mean(m_hat)` in the v0.146.0 gate is bit-identical across all
/// four backends; these ATTs are not (they inherit the ~1.5e-15 did_cs spread),
/// which is why GATE 4 is stated at 1e-12 relative and the exactness is claimed
/// only where it was measured.
test "didcs_canonical_att_is_pinned" {
  let f = v1500_canonical()
  let coef = f.coef_at(0, 1)
  let se = f.se_at(0, 1)
  let rel = fn(got : Double, want : Double) { (got - want).abs() / want.abs() }
  assert_true(rel(coef, 2.727522673844541) < 1.0e-12)
  assert_true(rel(se, 1.9428873717680928) < 1.0e-12)
}

///|
/// GATE 5. NO BASE PERIOD => THE COHORT IS DROPPED, silently and correctly.
///
/// `v068_wbtest.mbt`'s fixture has periods 1, 2, 3 -- no period 0. Cohort
/// `g = 1` therefore has no observable `g - 1`, and cannot have `ATT(1, 1)`
/// estimated at all. The right behaviour is to skip the cohort, not to fall
/// back to some other base period and publish a number with no meaning.
///
/// This is the sharp edge the estimand fix introduces, and it is worth a gate:
/// the tempting "fix" for an unestimable cohort is to quietly substitute
/// `t = g` -- which is exactly the bug this release removes.
test "didcs_drops_a_cohort_whose_base_period_is_unobserved" {
  let f = v1500_no_base_period()
  // 2 cohorts (g=1, g=2) x 3 periods (t=1,2,3) = 6 cells.
  assert_true(f.n_groups() == 2)
  assert_true(f.n_periods() == 3)
  let n_periods = f.n_periods()
  // Cohort g=1: base would be t=0, never observed -> every cell stays empty.
  for pi in 0..<n_periods {
    assert_true(f.cell_psi_a[0 * n_periods + pi].length() == 0)
    assert_true(f.se_at(0, pi) == 0.0)
  }
  // Cohort g=2: base t=1 is observed -> cells at t=2, t=3 are estimated, and
  // t=1 (its own treatment period) is NOT, because it is the base.
  assert_true(f.cell_psi_a[1 * n_periods + 0].length() == 0)
  assert_true(f.cell_psi_a[1 * n_periods + 1].length() > 0)
  assert_true(f.cell_psi_a[1 * n_periods + 2].length() > 0)
}

///|
/// The `v068_wbtest.mbt` shape: periods 1..3, cohorts 1 and 2, no period 0.
fn v1500_no_base_period() -> DoubleMLDIDCS {
  let n_per_cohort = 60
  let p = 2
  let n_periods = 3
  let cohort_count = 3
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int32] = Array::make(n, 1)
  let g_arr : Array[Int32] = Array::make(n, 0)
  let id_arr : Array[Int32] = Array::make(n, 0)
  let rng = chacha8_rng(3141)
  for u = 0; u < n_units; u = u + 1 {
    let cohort = u / n_per_cohort
    let xu : Array[Double] = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      xu[j] = rng.double() * 2.0 - 1.0
    }
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = xu[j]
      }
      // periods 1, 2, 3 -- deliberately NOT 0, 1, 2
      t_arr[row] = k + 1
      id_arr[row] = u
      g_arr[row] = cohort
      d[row] = if cohort > 0 && k + 1 >= cohort { 1.0 } else { 0.0 }
      let mut y_val = 0.4 * xu[0] + 0.2 * xu[1]
      if cohort > 0 && k + 1 > cohort {
        y_val = y_val + 1.5
      }
      y_val = y_val + (rng.double() - 0.5) * 0.3
      y[row] = y_val
    }
  }
  DoubleMLDIDCS::new(
    DoubleMLDIDCSData::new(
      Matrix::from_array(x_flat, n, p),
      y,
      d,
      t_arr,
      id_arr,
      g_arr,
    ),
    n_folds=4,
    seed=1,
  ).fit()
}
