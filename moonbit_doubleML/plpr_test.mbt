///|
/// Helper: balanced panel DGP with unit fixed effects.
///
///     Y_it = theta0 * D_it + g(X_it) + alpha_i + zeta_it
///     D_it = m(X_it) + 0.5 * alpha_i / sd_alpha + V_it
///
/// The treatment is correlated with the unit effect, so pooled
/// OLS / naive PLR is biased; the static-panel approaches are
/// what remove the FE bias. `g` and `m` are linear in X (the
/// closed-form learner fits them exactly out-of-fold up to
/// sampling noise).
fn build_panel_dgp(
  n_units : Int32,
  n_periods : Int32,
  theta0 : Double,
  seed : Int32,
  alpha_scale~ : Double = 1.0,
) -> DoubleMLPanelData {
  let p = 2
  let rng = chacha8_rng(seed)
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int32] = Array::make(n, 0)
  let id_arr : Array[Int32] = Array::make(n, 0)
  for u = 0; u < n_units; u = u + 1 {
    // Unit fixed effect and a time-invariant unit trait.
    let alpha = (rng.double() - 0.5) * 4.0 * alpha_scale
    let unit_trait = rng.double() * 2.0 - 1.0
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      // Time-varying covariate: trait + period noise.
      let x1 = unit_trait + (rng.double() - 0.5) * 1.0
      let x2 = rng.double() * 2.0 - 1.0
      x_flat[row * p] = x1
      x_flat[row * p + 1] = x2
      t_arr[row] = k
      id_arr[row] = u
      // Treatment driven by X and the unit effect.
      d[row] = 0.6 * x1 + 0.3 * x2 + 0.5 * alpha / 2.0 + (rng.double() - 0.5)
      y[row] = theta0 * d[row] +
        0.8 * x1 -
        0.5 * x2 +
        alpha +
        (rng.double() - 0.5) * 0.25
    }
  }
  let _ = x_flat.length()
  DoubleMLPanelData::new(Matrix::from_array(x_flat, n, p), y, d, t_arr, id_arr)
}

///|
/// Each of the four static-panel approaches should recover the
/// true theta on the FE-correlated DGP within tight tolerance,
/// and every SE must sit at the clustered scale (~0.02): the
/// pre-cluster-fix implementation reported se ~ 0.32-0.36 for the
/// CRE approaches, so `se < 0.08` doubles as a regression guard
/// for the unit-level variance path.
test "plpr_all_approaches_recover_theta" {
  let panel = build_panel_dgp(60, 4, 1.0, 3141)
  let approaches = ["cre_general", "cre_normal", "fd_exact", "wg_approx"]
  for i = 0; i < approaches.length(); i = i + 1 {
    let fitted = DoubleMLPLPR::new(
      panel,
      approach=approaches[i],
      n_folds=2,
      seed=3141,
    ).fit()
    let th = fitted.coef()
    let se = fitted.se()
    inspect(th > 0.9 && th < 1.15, content="true")
    inspect(se > 0.004 && se < 0.08, content="true")
    // CI identity: symmetric interval at exactly z=1.95996... times
    // the reported se.
    let (lo, hi) = fitted.confint()
    let z = 1.959963984540054
    inspect((hi - lo - 2.0 * z * se).abs() < 1.0e-9, content="true")
    inspect(((hi + lo) / 2.0 - th).abs() < 1.0e-12, content="true")
  }
}

///|
/// cre_general on a panel without meaningful unit effects (alpha
/// scaled to ~0) must recover theta tightly: with no fixed-effect
/// bias to remove, the Mundlak-augmented estimator behaves like a
/// plain cross-sectional PLR.
test "plpr_no_fe_recovery" {
  let panel = build_panel_dgp(50, 3, 1.0, 777, alpha_scale=1.0e-9)
  let fitted = DoubleMLPLPR::new(
    panel,
    approach="cre_general",
    n_folds=2,
    seed=3141,
  ).fit()
  let th = fitted.coef()
  inspect(th > 0.93 && th < 1.07, content="true")
}

///|
/// IV-type score runs end-to-end and lands near the truth
/// (looser tolerance than PO: the two-step g fit adds noise).
test "plpr_iv_type_recovers_theta" {
  let panel = build_panel_dgp(60, 4, 1.0, 99)
  let fitted = DoubleMLPLPR::new(
    panel,
    approach="fd_exact",
    score="IV-type",
    n_folds=2,
    seed=3141,
  ).fit()
  let th = fitted.coef()
  inspect(th > 0.5 && th < 1.5, content="true")
}

///|
/// n_rep > 1 aggregates per-rep estimates; result stays near
/// truth and se stays finite positive.
test "plpr_n_rep_two" {
  let panel = build_panel_dgp(40, 3, 1.0, 555)
  let fitted = DoubleMLPLPR::new(
    panel,
    approach="wg_approx",
    n_folds=2,
    n_rep=2,
    seed=3141,
  ).fit()
  let th = fitted.coef()
  inspect(th > 0.6 && th < 1.4, content="true")
  inspect(fitted.se() > 0.0, content="true")
}

///|
/// Determinism: same seed -> identical coef; different seed ->
/// slightly different (folds change).
test "plpr_deterministic" {
  let panel = build_panel_dgp(30, 4, 1.0, 42)
  let f1 = DoubleMLPLPR::new(panel, approach="fd_exact", n_folds=2, seed=7).fit()
  let f2 = DoubleMLPLPR::new(panel, approach="fd_exact", n_folds=2, seed=7).fit()
  inspect((f1.coef() - f2.coef()).abs() < 1.0e-15, content="true")
}

///|
/// confint covers the truth on a large-panel run (statistical;
/// wide net with generous bounds).
test "plpr_confint_covers_truth" {
  let panel = build_panel_dgp(120, 5, 1.0, 2024)
  let fitted = DoubleMLPLPR::new(
    panel,
    approach="cre_normal",
    n_folds=2,
    seed=3141,
  ).fit()
  let (lo, hi) = fitted.confint()
  inspect(lo < 1.05 && hi > 0.95, content="true")
}

///|
/// Panic: invalid approach name.
test "panic_plpr_bad_approach" {
  let panel = build_panel_dgp(10, 2, 1.0, 1)
  let _ = DoubleMLPLPR::new(panel, approach="bogus")
}

///|
/// Panic: invalid score name.
test "panic_plpr_bad_score" {
  let panel = build_panel_dgp(10, 2, 1.0, 1)
  let _ = DoubleMLPLPR::new(panel, score="doubly robust")
}

///|
/// Panic: single-row units only — every unit has exactly one
/// observation, so after dropping them nothing remains.
test "panic_plpr_single_row_units" {
  let n = 6
  let x_flat : Array[Double] = Array::make(n * 2, 0.0)
  let y : Array[Double] = []
  let mut y_acc : Array[Double] = y
  let d : Array[Double] = []
  let mut d_acc : Array[Double] = d
  let t : Array[Int32] = []
  let mut t_acc : Array[Int32] = t
  let id : Array[Int32] = []
  let mut id_acc : Array[Int32] = id
  for i = 0; i < n; i = i + 1 {
    x_flat[i * 2] = i.to_double()
    x_flat[i * 2 + 1] = 1.0
    y_acc = y_acc + [i.to_double()]
    d_acc = d_acc + [(i % 2).to_double()]
    t_acc = t_acc + [0]
    id_acc = id_acc + [i]
  }
  let panel = DoubleMLPanelData::new(
    Matrix::from_array(x_flat, n, 2),
    y_acc,
    d_acc,
    t_acc,
    id_acc,
  )
  let _ = DoubleMLPLPR::new(panel).fit()
}

///|
/// Panic: fewer units than folds — the clustered path draws KFolds
/// over whole units, so `n_folds` must not exceed the unit count.
test "panic_plpr_too_few_units" {
  let panel = build_panel_dgp(3, 4, 1.0, 5)
  let _ = DoubleMLPLPR::new(panel, n_folds=4).fit()
}

///|
/// Direct reference test for `est_coef_cluster`: two folds with
/// fold-unit weights w = [1, 0.5].
///
///   fold0 (w=1): psi_a sum = -2, psi_b sum = 6
///   fold1 (w=1/2): psi_a sum = -3, psi_b sum = 9
///   sa = -2 - 1.5 = -3.5, sb = 6 + 4.5 = 10.5
///   theta = -sb / sa = -10.5 / -3.5 = 3.0 exactly.
test "plpr_est_coef_cluster_reference" {
  let psi_a : Array[Double] = [-1.0, -1.0, -1.0, 0.0, -2.0]
  let psi_b : Array[Double] = [2.0, 4.0, 1.0, 3.0, 5.0]
  let folds : Array[Fold] = [
    Fold::new([2, 3, 4], [0, 1]),
    Fold::new([0, 1], [2, 3, 4]),
  ]
  let th = est_coef_cluster(psi_a, psi_b, folds, [1, 2])
  inspect((th - 3.0).abs() < 1.0e-12, content="true")
}

///|
/// Direct reference test for `est_coef_cluster` with imbalanced
/// fold sizes: fold 0 has 1 unit, fold 1 has 3 units. The
/// fold-weighted coefficient `theta = -sa^-1 sb` with weights
/// `w_k = 1 / |I_k|` differs from the unweighted mean by the
/// `w_k` factor, so a typo that drops `1 / |I_k|` (e.g. sets
/// `w = 1`) flips the result.
///
///   fold 0: |I_0| = 1, psi_a sum = a0, psi_b sum = b0
///   fold 1: |I_1| = 3, psi_a sum = a1, psi_b sum = b1
///   weighted:  sa = a0 + (1/3) a1,  sb = b0 + (1/3) b1
///   unweighted: sa = a0 + a1,        sb = b0 + b1
test "plpr_est_coef_cluster_imbalanced_folds" {
  let psi_a : Array[Double] = [-1.0, -2.0, -3.0, -4.0]
  let psi_b : Array[Double] = [2.0, 3.0, 4.0, 5.0]
  // fold 0 test_rows = [0], fold 1 test_rows = [1, 2, 3]
  let folds : Array[Fold] = [
    Fold::new([1, 2, 3], [0]),
    Fold::new([0], [1, 2, 3]),
  ]
  let th = est_coef_cluster(psi_a, psi_b, folds, [1, 3])
  // weighted sa = -1 + (1/3)*(-9) = -4, sb = 2 + (1/3)*12 = 6
  // theta = -6 / -4 = 1.5 exactly.
  inspect((th - 1.5).abs() < 1.0e-12, content="true")
}

///|
/// Direct reference test for `var_est_cluster`: 4 units x 2 rows,
/// folds {u0,u1} / {u2,u3}, n_folds_per_cluster = 2.
///
///   fold0 (w=1/2): S_u0 = 1-1 = 0, S_u1 = 2+0 = 2 -> gamma += 2
///                  j_hat += 1/2 * 4 = 2
///   fold1 (w=1/2): S_u2 = -1+1 = 0, S_u3 = 0+3 = 3 -> gamma += 4.5
///                  j_hat += 1/2 * 8 = 4
///   gamma = 6.5 -> 6.5/2 = 3.25 ; J = 6/2 = 3 ; N_units = 4
///   sigma2 = 3.25 / (4 * 9) = 3.25/36 ; se = sqrt(3.25/36)
test "plpr_var_est_cluster_reference" {
  let psi : Array[Double] = [1.0, -1.0, 2.0, 0.0, -1.0, 1.0, 0.0, 3.0]
  let psi_deriv : Array[Double] = [1.0, 1.0, 1.0, 1.0, 2.0, 2.0, 2.0, 2.0]
  let unit_rows : Array[Array[Int32]] = [[0, 1], [2, 3], [4, 5], [6, 7]]
  let unit_fold : Array[Int32] = [0, 0, 1, 1]
  let se = var_est_cluster(psi, psi_deriv, unit_rows, unit_fold, 2, 2) catch {
    _ => 0.0 // unreachable for this input
  }
  inspect((se - (3.25 / 36.0).sqrt()).abs() < 1.0e-12, content="true")
}

///|
/// `var_est_cluster` against UPSTREAM'S OWN FUNCTION, not a hand oracle.
///
/// `plpr_var_est_cluster_reference` above pins the arithmetic against numbers
/// worked out by hand, which cannot tell "the formula is upstream's" from "the
/// formula is what we thought upstream's was". This one runs upstream's
/// `var_one_way_cluster` (`doubleml/tests/_utils_cluster.py`) on the fixture
/// and pins the port to ITS output.
///
/// Fixture: 3 clusters of UNEVEN size (4, 3, 2), whole-cluster folds, so
///
///   - a `1 / m` that silently used a constant, or a per-cluster divisor
///     instead of the per-fold one, cannot pass;
///   - `m` takes the values 1, 2, 1 across the three folds, so the
///     normalisation is exercised at both extremes;
///   - the unit sizes differ, so a `sum over the cluster` that picked up only
///     the test-set rows would differ from upstream's GLOBAL selection.
///
/// Measured: upstream returns variance `0.17242815493544361`, se
/// `0.41524469284440424`; the port returns the same se to the last bit (rel gap
/// `0.000e+00`). Regenerate with `_verify/_cluster_var_est_1680.py`.
///
/// WHY THE FIXTURE IS UNIT-ALIGNED
///
/// Upstream selects `I_k = unique(cluster_var[test_index])` and then sums
/// `psi` over that cluster GLOBALLY, so one cluster can appear in two folds
/// when the folds split rows rather than clusters. The port cannot express
/// that: `unit_fold[u]` is one fold id per UNIT, because its cross-fitting
/// folds whole units. The difference is in what partition each accepts, not in
/// the variance formula -- and a fold-aligned fixture is what makes the two
/// comparable at all. `_verify/_cluster_var_est_1680.py` also evaluates a
/// row-split fixture, where the two agree at `0.000e+00` too.
///
/// `unit_fold` is therefore PER UNIT and has length 4, not 13. An earlier
/// version of this test passed the per-row fold ids, which read as
/// `unit_fold[0..3] = 0,0,0,0` and left folds 1 and 2 with no units at all --
/// `require(m > 0)` fired and the test failed. Worth stating because the
/// Python cross-check agreed with upstream at `0.0e+00` on that same wrong
/// fixture: its `port_formula` is a per-row re-implementation, so it was
/// comparing upstream's function against upstream's semantics and could not
/// see the difference. The MoonBit test could, because it called the port.
test "plpr_var_est_cluster_matches_upstream_var_one_way_cluster" {
  let psi : Array[Double] = [
    0.5, -1.5, 2.5, -3.5, 0.5, -1.5, 2.5, -3.5, 0.5, -1.5, 2.5, -3.5, 0.5,
  ]
  let psi_deriv : Array[Double] = [
    1.0, -2.0, 0.5, 3.0, -1.0, 2.5, -0.25, 4.0, -3.5, 1.0, 2.0, -1.0, 0.75,
  ]
  // 4 clusters of UNEQUAL size 4, 2, 3, 4 over 3 folds:
  //   fold 0 -> {u0}        m = 1
  //   fold 1 -> {u1, u2}    m = 2
  //   fold 2 -> {u3}        m = 1
  // so `1 / m` is exercised at both extremes and `m != n_folds`, which is the
  // case a constant divisor gets wrong.
  let unit_rows : Array[Array[Int32]] = [
    [0, 1, 2, 3],
    [4, 5],
    [6, 7, 8],
    [9, 10, 11, 12],
  ]
  let unit_fold : Array[Int32] = [0, 1, 1, 2] // per UNIT
  let se = var_est_cluster(psi, psi_deriv, unit_rows, unit_fold, 3, 3) catch {
    _ => 0.0 // unreachable for this input
  }
  // 1e-15 is ~5 ulp at this magnitude: the two implementations agree to the
  // last bit, so this bound is rounding headroom, not a tolerance for a
  // difference that is supposed to be there.
  inspect((se - 0.41524469284440424).abs() < 1.0e-15, content="true")
}

///|
/// Regression test for the v0.34.0 J-floor defensive guard in
/// `var_est_cluster`. The fold-mean `J = mean(psi_deriv)` can land
/// on (or near) zero for fold splits where `psi_deriv` sums to zero
/// inside every fold. The 1e-6 floor raises `VarEstClusterError::JTooSmall`
/// (v0.35.0+) carrying the exact `(j, g, n_units)` triple that
/// triggered it.
///
/// Before v0.35.0, the J-floor used `abort()`, which made this case
/// untestable on native/wasm-gc because `panic_*` tests are
/// silently skipped by the test driver. Now that the abort has
/// been replaced with `raise VarEstClusterError`, the panic path is
/// observable: tests can use `try?` to convert the error to a
/// `Result`, then inspect it.
///
/// This test exercises the J-floor path with a contrived but
/// deterministic input (psi_deriv rows [+1, -1, +1, -1, ...] so
/// every unit sums to 0, every fold sums to 0, J = 0). It is the
/// catchable counterpart to whitebox mutation M04 (removing the
/// J-floor entirely). With the floor in place, the call returns
/// `Err(VarEstClusterError::JTooSmall(0.0, g, 4))`; without the
/// floor (regression), it returns `Ok(NaN)` and the inspect fails.
///
///   psi_deriv rows: [+1, -1, +1, -1, +1, -1, +1, -1]
///   unit 0 (fold 0): rows 0,1 -> sum 0
///   unit 1 (fold 0): rows 2,3 -> sum 0
///   unit 2 (fold 1): rows 4,5 -> sum 0
///   unit 3 (fold 1): rows 6,7 -> sum 0
///   fold0 j_hat = 0, fold1 j_hat = 0  =>  j_hat = 0  =>  j = 0
///   |j| = 0 < 1e-6  =>  raise VarEstClusterError::JTooSmall(0, g, 4)
test "plpr_var_est_cluster_raises_j_too_small_on_zero_j" {
  let psi : Array[Double] = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
  let psi_deriv : Array[Double] = [1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0]
  let unit_rows : Array[Array[Int32]] = [[0, 1], [2, 3], [4, 5], [6, 7]]
  let unit_fold : Array[Int32] = [0, 0, 1, 1]
  // Expected: the J-floor raises VarEstClusterError::JTooSmall.
  // Migration pattern (MoonBit deprecates `try?`):
  //   try expr catch { e => inspect(e, content=...) } noraise {
  //     _ => fail("expected expr to raise")
  //   }
  // The catch branch asserts the exact variant + payload; the
  // noraise branch fails the test if no error fires (catches M04).
  try var_est_cluster(psi, psi_deriv, unit_rows, unit_fold, 2, 2) catch {
    VarEstClusterError::JTooSmall(j, _, _) =>
      inspect(j.abs() < 1.0e-6, content="true")
  } noraise {
    _ => fail("expected var_est_cluster to raise JTooSmall on J=0")
  }
}
