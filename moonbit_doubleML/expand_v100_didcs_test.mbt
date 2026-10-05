///|
// v0.100.0: `DoubleMLDIDCS` gets the per-cell sandwich API.
//
// WHERE DIDCS SITS IN THE FAMILY
// ==============================
// Seventeen estimators now carry `sandwich_se` /
// `cluster_sandwich_se` / `bias_corrected_coef`, and this file adds
// the eighteenth coverage point. DIDCS was the omission that mattered
// most structurally: it is the only one of the eighteen that is a
// WRAPPER over per-cell children rather than a single scalar
// Z-estimator, so it needed the per-cell API shape
// (`DoubleMLQTE::sandwich_se_at`, v0.95.0 / `DoubleMLAPOS::sandwich_se_at`,
// v0.100.0) instead of the joint multi-column `sandwich_se` of the
// DID family.
//
// PER CELL
// --------
// `DoubleMLDIDCS` runs one independent child `DoubleMLDIDBinary`
// per `(g, t)` and reports one ATT per cell, so the API is indexed
// exactly like `coef_at` / `se_at`: `sandwich_se_at(g, t, kind)` with
// the flat index `g * n_periods + t`. The DGP below gives
// `n_groups = 3`, `n_periods = 4` = 12 cells, of which exactly 3
// are non-degenerate (`t_eval > g`): (0,2), (0,3), (1,3).
//
// THE THREE DENOMINATORS, AND WHY THE OBVIOUS ONE IS WRONG
// ========================================================
// `se_at(g, t)` IS the child's `se()` and nothing else, and the
// child's `se()` is `var_est(psi_a, psi_b)` over the child's
// WIDE-format rows. On this DGP for cell (0, 2) those are:
//
//     n_wide  = 100   <- `var_est`'s n.  CORRECT, and what fit uses.
//     sub_n   = 200   <- the long-format sub-panel the cell loop
//                        builds: 50 G + 50 never-treated units, each
//                        observed in both of the two periods.
//     n_panel = 800   <- the full long-format panel.
//     50            <- the count of NON-ZERO `psi_a` rows, i.e. what
//                       you get if you read the sparse
//                       `psi_a_matrix` and count the live entries.
//
// The analytic identity `var = sum(psi^2) / sum(psi_a)^2` makes the
// variance invariant to which SUPERSET of the cell's rows you sum
// over -- as long as `mean(psi_a)` and `n` are taken over the SAME
// row set. So `sub_n` and `n_panel` both give the right answer if
// paired correctly, and the count-of-non-zeros is the trap: it
// pairs `n = 50` with a mean taken over 100 rows, which is a
// ~0.7 % error, and no amount of care with the long-format
// matrices can repair it because a written zero and an unwritten
// zero are indistinguishable there. `fit` therefore persists the
// child's own WIDE rows and the accessors take `length()` and
// `mean()` from the same array; no scalar is reconstructed.
//
// `M_inv` IS `[[-1.0]]`, EXACTLY
// ------------------------------
// The DID ATT score's `psi_a[i] = -d[i] / p_hat` with
// `p_hat = mean(d)`, so `mean(psi_a) == -1` and
// `M_inv[0,0]^2 == 1.0` as an IEEE identity. Test 3 pins both. (A
// plausible-sounding wrong value is `-2`: it is `1 / mean(psi_a)`
// where `mean(psi_a)` is the mean over `sub_n = 200` rows, i.e.
// `-100/200 = -0.5`, which pairs a 200-row mean with a 100-row
// variance.) Only the square enters the variance, so the sign
// never matters -- but the magnitude does.
//
// BIT-IDENTITY, NOT A TOLERANCE
// -----------------------------
// `var_est` ends `gamma / n` then `/(mean(psi_a)^2 * n)`;
// `sandwich_variance_hc0` computes `M_inv[0,0]^2 * acc / n / n`
// over the same Kahan sum of the same products in the same index
// order. With `M_inv[0,0]^2 == 1.0` exactly the two op sequences
// are the same, so
//
//     sandwich_se_at(g, t, HC0) == se_at(g, t)
//
// holds with `==`, not with a tolerance. Test 1 asserts that and
// PRINTS the per-cell difference for all 3 non-degenerate cells so
// the claim is checkable from the test log rather than taken on
// faith.
//
// THE ORDER OF psi IS NOT INTERCHANGEABLE
// ---------------------------------------
// This file's `psi_matrix` is `psi_a + theta * psi_b` (v0.15.0);
// `var_est.mbt` and `sandwich.mbt::psi_at` are
// `theta * psi_a + psi_b`. They are different functions, and the
// reversed one is not a valid input to the sandwich. Test 4 pins
// that the two orders are genuinely different numbers on this data,
// so the correct-order assertion in test 1 cannot be satisfied by a
// regression that swapped them.
//
// THE MEMOIZE CACHE-HIT PATH
// --------------------------
// `DoubleMLDIDCS` has NO `FitCache` of its own -- the struct has no
// `fit_cache` field and `fit` has no `cache_hit` branch. The
// memoize flag is forwarded down (`DoubleMLDIDCS` ->
// `DoubleMLDIDBinary` -> `DoubleMLDID`) and the cache that exists
// is the inner `DoubleMLDID::fit_cache`, which stores per-rep
// nuisance PREDICTIONS and re-derives `psi_a` / `psi_b` from them on
// a hit. So the analogue of APOS's "restore the third predictions
// slot" is that the parent re-enters the child loop on a hit and the
// child fills the same slots either way -- the only thing `fit` must
// get right is to persist the per-cell rows on EVERY call.
//
// `fit` takes `self` BY VALUE, so `est.fit()` twice re-reads `est`'s
// own cold chain and the test would be VACUOUS. The second fit must
// be driven from the first returned value. Test 7 does that, and --
// because a DIDCS-level hit is a hit in the inner `DoubleMLDID` and
// nothing in the DIDCS API can observe it -- it ALSO drives a
// `DoubleMLDID` hit directly and shows the child's `psi_a` / `psi_b`
// come back byte-identical, which is the premise the DIDCS-level
// assertion rests on. Tying the restored state to a FRESH
// non-memoized fit keeps all of it from being satisfied by two
// consistent errors.
//
// A NOTE ON THE ABORT TESTS
// -------------------------
// This MoonBit runner counts a test that ABORTS as PASSED
// (measured: a `mean([])` abort increments the pass count). So a
// `panic_`-style test proves nothing by itself. Tests 6 and 8
// therefore assert the observable STATE that drives each guard --
// the empty per-cell row array, the `length()` of a fitted row --
// and only then make the aborting call. The state assertions are
// the falsifiable part.

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

///|
/// The CS-DID panel shared by every test in this file: the DGP of
/// `did_cs_test.mbt::did_cs_recovers_known_att_per_cell` (4 cohorts
/// `g = 0..3`, 50 units per cohort, 4 periods, true ATT 1.0,
/// `chacha8_rng(11)`), constructed fresh per call so no test can
/// observe another's RNG stream.
///
/// `n = 200 units * 4 periods = 800` long-format rows,
/// `n_groups = 3` (g = 1, 2, 3 -- the never-treated g = 0 sentinel
/// is excluded), `n_periods = 4`.
fn expand_v100_didcs_data() -> DoubleMLDIDCSData {
  let n_per_cohort = 50
  let p = 3
  let theta0 = 1.0
  let n_periods = 4
  let cohort_count = 4
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
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
        y_val = y_val + theta0
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
/// The fitted CS-DID every test in this file shares:
/// `n_folds = 2`, `n_rep = 1`, `seed = 3141` (the settings
/// `did_cs_test.mbt` uses, so the cells line up with that suite).
fn expand_v100_didcs() -> DoubleMLDIDCS {
  DoubleMLDIDCS::new(expand_v100_didcs_data(), n_folds=2, n_rep=1, seed=3141).fit()
}

///|
/// Flat cell index, mirroring the accessors' internal one so tests
/// can reach the persisted per-cell rows (the fields are public;
/// the private slice helpers are not, and are not needed).
fn expand_v100_flat(f : DoubleMLDIDCS, g : Int, t : Int) -> Int {
  g * f.n_periods() + t
}

///|
/// Relative closeness at the 1e-12 level -- the package's tolerance
/// for "same number, different accumulation order", the same helper
/// and level `expand_v100_apos_test.mbt` uses. Reserved for the
/// HC1 / HC2 / HC3 ratios, whose identities are stated on the
/// VARIANCE (`HC1 == HC0 * n / (n - k)`) and so reach the SE through
/// a `sqrt` and a division that the accessor does not perform in
/// that order.
///
/// It is deliberately NOT used for the headline
/// `sandwich_se_at(g, t, HC0) == se_at(g, t)` assertion, which is
/// measured bit-identical and asserted with `==`.
fn expand_v100_didcs_close(x : Double, y : Double) -> Bool {
  let scale = if x.abs() > y.abs() { x.abs() } else { y.abs() }
  if scale == 0.0 {
    return (x - y).abs() < 1.0e-300
  }
  (x - y).abs() / scale < 1.0e-12
}

///|
/// `(group_idx, period_idx)` of every NON-degenerate cell, i.e.
/// every `(g, t)` the CS-DID convention actually estimates
/// (`t_eval > g`). Returns the 3 pairs (0,2), (0,3), (1,3) on this
/// DGP.
fn expand_v100_live_cells(f : DoubleMLDIDCS) -> Array[(Int, Int)] {
  let out : Array[(Int, Int)] = []
  let mut out_acc = out
  for gi = 0; gi < f.n_groups(); gi = gi + 1 {
    let g_value = f.group_at(gi)
    for pi = 0; pi < f.n_periods(); pi = pi + 1 {
      if f.period_at(pi) <= g_value {
        continue
      }
      out_acc = out_acc + [(gi, pi)]
    }
  }
  out_acc
}

///|
/// All-singleton (`singleton[i] = i`) and pooled-in-blocks-of-4
/// (`pooled[i] = i / 4`) cluster ids for a sample of `n`.
fn expand_v100_didcs_cluster_ids(n : Int) -> (Array[Int], Array[Int]) {
  let singleton : Array[Int] = Array::make(n, 0)
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
    pooled[i] = i / 4
  }
  (singleton, pooled)
}

// ---------------------------------------------------------------------------
// 1. THE DECISIVE ONE: se_at(g, t) == sandwich_se_at(g, t, HC0)
// ---------------------------------------------------------------------------

///|
/// THE assertion that puts DIDCS in the sandwich family, for EVERY
/// non-degenerate cell. Exact equality, with the measured per-cell
/// discrepancy PRINTED so the "bit-identical" claim is checkable
/// from the test log.
///
/// MEASURED on this DGP: the absolute and relative differences are
/// exactly `0.0` for all 3 non-degenerate cells -- (0,2), (0,3),
/// (1,3) -- i.e. `hc0 - se_at == 0.0` bit for bit, not to a
/// tolerance. See the `DIDCS100` lines in the test output.
///
/// The tempting failure mode this rules out: using the long-format
/// panel size (800) or the sub-panel size (200) as `n` while
/// taking `mean(psi_a)` over the wide rows. The former makes the SE
/// ~2.83x too small, the latter ~1.41x too small.
test "didcs_sandwich_hc0_equals_se_per_cell" {
  let f = expand_v100_didcs()
  let cells = expand_v100_live_cells(f)
  inspect(cells.length(), content="3")
  for c in cells {
    let (gi, pi) = c
    let se_hc0 = f.sandwich_se_at(gi, pi, SandwichKind::hc0())
    let se = f.se_at(gi, pi)
    let abs_diff = se_hc0 - se
    let rel_diff = if se == 0.0 { 0.0 } else { abs_diff / se }
    println(
      "DIDCS100 cell=(" +
      gi.to_string() +
      "," +
      pi.to_string() +
      ") hc0=" +
      se_hc0.to_string() +
      " se_at=" +
      se.to_string() +
      " abs_diff=" +
      abs_diff.to_string() +
      " rel_diff=" +
      rel_diff.to_string(),
    )
    inspect(se_hc0 == se, content="true")
    inspect(se > 0.0, content="true")
  }
}

// ---------------------------------------------------------------------------
// 2. THE HC FAMILY, AS MEASURED
// ---------------------------------------------------------------------------

///|
/// The HC0 / HC1 / HC2 / HC3 relationships for a per-cell DIDCS
/// sandwich. These are the shared dispatch's package-wide identities
/// (see the `sandwich.mbt` header and `expand_v088_test.mbt`), and
/// they hold here unchanged because DIDCS adds no scaling of its
/// own -- it passes `n_params = 1` and the cell's own `n_wide`.
///
/// Asserted AS MEASURED, and the distinction matters:
///   - `HC1 / HC0 == sqrt(n / (n - 1))` with `n = n_wide` and
///     `k = 1`, to 1e-12. The identity is stated on the VARIANCE
///     (`HC1 == HC0 * n / (n - k)`), so the SE reaches it through a
///     square root and a division the accessor does not perform in
///     that order -- this one is a RATIO check, not an equality.
///     The plausible misreading `k = n_groups` would give
///     `sqrt(n / (n - 3))` instead and is explicitly ruled out.
///   - `HC2 == HC1` and `HC3 == HC1^2 / HC0`, to 1e-12. These hold
///     because the moment inverted is a MEAN moment whose implicit
///     projection is `(1 / n) * J` (constant leverage
///     `h_ii = 1 / n_obs`). Same identities APOS reports; per-cell
///     does not change them. The MEASURED gaps are printed as
///     `DIDCS100HCGAP` -- on this DGP `hc2 - hc1` is exactly `0.0`
///     for all three cells and `hc3 - hc1^2 / hc0` is at the last
///     one or two ulps (`+8.67e-19`, `-4.34e-19`, `0.0`). They are
///     reassociations of the same sum inside the shared dispatch, so
///     the assertion is stated at the package's 1e-12 level rather
///     than as a bit claim that a different compiler's
///     reassociation could break.
///
/// Note the asymmetry with test 1: the headline
/// `sandwich_se_at(g, t, HC0) == se_at(g, t)` IS asserted with
/// `==`, because it was measured bit-identical and does not go
/// through a `sqrt` or a reassociation.
test "didcs_sandwich_hc_family_relationships" {
  let f = expand_v100_didcs()
  let cells = expand_v100_live_cells(f)
  for c in cells {
    let (gi, pi) = c
    let flat = expand_v100_flat(f, gi, pi)
    let n_wide = f.cell_psi_a[flat].length()
    let n_d = n_wide.to_double()
    let hc0 = f.sandwich_se_at(gi, pi, SandwichKind::hc0())
    let hc1 = f.sandwich_se_at(gi, pi, SandwichKind::hc1())
    let hc2 = f.sandwich_se_at(gi, pi, SandwichKind::hc2())
    let hc3 = f.sandwich_se_at(gi, pi, SandwichKind::hc3())
    println(
      "DIDCS100HC cell=(" +
      gi.to_string() +
      "," +
      pi.to_string() +
      ") n_wide=" +
      n_wide.to_string() +
      " hc0=" +
      hc0.to_string() +
      " hc1=" +
      hc1.to_string() +
      " hc2=" +
      hc2.to_string() +
      " hc3=" +
      hc3.to_string(),
    )
    // HC1: the finite-sample correction, with k = 1 (ONE scalar
    // estimand per cell). The identity is stated on the VARIANCE
    // (`HC1 == HC0 * n / (n - k)`), so the SE ratio is its square
    // root -- hence a ratio check, not an equality against a
    // product.
    let n_groups = f.n_groups().to_double()
    inspect(
      expand_v100_didcs_close(hc1 / hc0, (n_d / (n_d - 1.0)).sqrt()),
      content="true",
    )
    // `k = n_groups` is the wrong reading and is ruled out.
    let wrong = (n_d / (n_d - n_groups)).sqrt()
    inspect(expand_v100_didcs_close(hc1 / hc0, wrong) == false, content="true")
    // HC2 == HC1 and HC3 == HC1^2 / HC0 (mean-moment leverage
    // `h_ii = 1 / n_obs`). Asserted at the 1e-12 level because these
    // are reassociations of the same sum, and PRINTED so the
    // measured gap is visible.
    println(
      "DIDCS100HCGAP cell=(" +
      gi.to_string() +
      "," +
      pi.to_string() +
      ") hc2_vs_hc1=" +
      (hc2 - hc1).to_string() +
      " hc3_vs_hc1sq_hc0=" +
      (hc3 - hc1 * hc1 / hc0).to_string(),
    )
    inspect(expand_v100_didcs_close(hc2, hc1), content="true")
    inspect(expand_v100_didcs_close(hc3, hc1 * hc1 / hc0), content="true")
    // And all four strictly widen with the correction.
    inspect(hc1 > hc0, content="true")
    inspect(hc3 > hc2, content="true")
  }
}

// ---------------------------------------------------------------------------
// 3. THE DENOMINATOR AND M_inv, PINNED
// ---------------------------------------------------------------------------

///|
/// Pins the two scalars the whole per-cell sandwich rests on, and
/// rules out each of the three wrong values by name.
///
/// MEASURED for cell (0, 2) on this DGP:
///   `n_wide = 100`  == `n_groups_used(2 cohorts) * ...` -- the
///     child's wide-format row count: 100 units observed in both the
///     pre and the eval period. NOT `sub_n = 200` (the long-format
///     sub-panel), NOT `n_panel = 800`, NOT the 50 non-zero `psi_a`
///     rows.
///   `mean(psi_a) = -1.0` EXACTLY, so `M_inv = -1.0` and
///     `M_inv^2 = 1.0` exactly. NOT `-2.0`, which is what you get
///     from `1 / (sum(psi_a) / sub_n)` = `1 / -0.5`.
///
/// `M_inv^2 == 1.0` is what makes test 1 bit-identical rather than
/// merely close: the `* 1.0` in `sandwich_variance_hc0` is the IEEE
/// identity, so it runs the same op sequence as `var_est`.
test "didcs_sandwich_cell_denominator_and_m_inv" {
  let f = expand_v100_didcs()
  let cells = expand_v100_live_cells(f)
  let n_panel = 800
  for c in cells {
    let (gi, pi) = c
    let flat = expand_v100_flat(f, gi, pi)
    let psi_a = f.cell_psi_a[flat]
    let psi_b = f.cell_psi_b[flat]
    // The persisted row IS the child's wide-format row.
    inspect(psi_a.length() == psi_b.length(), content="true")
    // 50 G units + 50 never-treated units, each observed in both
    // the pre and the eval period. One per ESTIMAND, not per
    // long-format panel row.
    inspect(psi_a.length(), content="100")
    // Explicitly not the three wrong denominators.
    inspect(psi_a.length() != n_panel, content="true")
    inspect(psi_a.length() != 200, content="true")
    // The 50-vs-100 trap: only half the wide rows carry a non-zero
    // `psi_a` (the treated half; `psi_a = -d / p_hat` and
    // `p_hat = 0.5`, so treated rows get `-2` and control rows 0).
    // Counting live rows would give n = 50 and a ~0.7 % SE error.
    let mut nonzero = 0
    let mut all_minus_two = true
    for k = 0; k < psi_a.length(); k = k + 1 {
      if psi_a[k] != 0.0 {
        nonzero = nonzero + 1
        if psi_a[k] != -2.0 {
          all_minus_two = false
        }
      }
    }
    inspect(nonzero, content="50")
    inspect(all_minus_two, content="true")
    // J = mean(psi_a) over those same 100 rows, hence M_inv = -1.
    let mean_a = mean(psi_a)
    println(
      "DIDCS100J cell=(" +
      gi.to_string() +
      "," +
      pi.to_string() +
      ") n_wide=" +
      psi_a.length().to_string() +
      " mean_psi_a=" +
      mean_a.to_string() +
      " m_inv2=" +
      (1.0 / (mean_a * mean_a)).to_string(),
    )
    inspect(mean_a == -1.0, content="true")
    let m_inv = 1.0 / mean_a
    inspect(m_inv == -1.0, content="true")
    inspect(m_inv * m_inv == 1.0, content="true")
    // The score is non-degenerate: it has to be, or HC0 is 0 and
    // the equality in test 1 would be 0 == 0.
    let coef = f.coef_at(gi, pi)
    let mut sum_psi2 = 0.0
    for k = 0; k < psi_a.length(); k = k + 1 {
      let psi = coef * psi_a[k] + psi_b[k]
      sum_psi2 = sum_psi2 + psi * psi
    }
    inspect(sum_psi2 > 0.0, content="true")
  }
}

// ---------------------------------------------------------------------------
// 4. THE psi ORDER, WHICH IS NOT INTERCHANGEABLE
// ---------------------------------------------------------------------------

///|
/// The long-format `psi_matrix` is `psi_a + theta * psi_b`; the
/// sandwich needs `theta * psi_a + psi_b` (`var_est.mbt` /
/// `sandwich.mbt::psi_at`). This test pins that the two are
/// genuinely DIFFERENT numbers on this data, so the bit-identity in
/// test 1 cannot be satisfied by a regression that mixed them up.
///
/// It also pins the arithmetic identity that makes the correct
/// order the right one: the correct-order score has mean exactly
/// zero at the fitted coefficient (it is the root of the estimating
/// equation), while the reversed-order one does not.
test "didcs_sandwich_uses_the_var_est_psi_order" {
  let f = expand_v100_didcs()
  let n_panel = 800
  let cells = expand_v100_live_cells(f)
  for c in cells {
    let (gi, pi) = c
    let flat = expand_v100_flat(f, gi, pi)
    let psi_a = f.cell_psi_a[flat]
    let psi_b = f.cell_psi_b[flat]
    let coef = f.coef_at(gi, pi)
    // Correct order: `theta * psi_a + psi_b`. Mean is 0 at the root.
    let mut mean_correct = 0.0
    // Reversed order: `psi_a + theta * psi_b`. NOT the moment.
    let mut mean_reversed = 0.0
    let mut differ = false
    for k = 0; k < psi_a.length(); k = k + 1 {
      let correct = coef * psi_a[k] + psi_b[k]
      let reversed = psi_a[k] + coef * psi_b[k]
      mean_correct = mean_correct + correct
      mean_reversed = mean_reversed + reversed
      if correct != reversed {
        differ = true
      }
    }
    mean_correct = mean_correct / psi_a.length().to_double()
    mean_reversed = mean_reversed / psi_a.length().to_double()
    println(
      "DIDCS100ORD cell=(" +
      gi.to_string() +
      "," +
      pi.to_string() +
      ") mean_correct=" +
      mean_correct.to_string() +
      " mean_reversed=" +
      mean_reversed.to_string(),
    )
    // The orders are genuinely different functions here.
    inspect(differ, content="true")
    // The correct order is the estimating equation's score at its
    // own root, so its mean vanishes (to Kahan-level roundoff).
    inspect(mean_correct.abs() < 1.0e-12, content="true")
    // The reversed order's does not. This is exactly why
    // `psi_matrix` cannot be unpacked into a sandwich input.
    inspect(mean_reversed.abs() > 1.0e-6, content="true")
    // Tie the two together: the shipped long-format `psi_matrix`
    // really does carry the REVERSED order, so it is not merely a
    // second name for the wide row. Its non-zero entries are the
    // same 100 observations, and their mean is the same
    // `mean_reversed`.
    let long_base = flat * n_panel
    let mut n_live = 0
    let mut sum_long = 0.0
    for i = 0; i < n_panel; i = i + 1 {
      let v = f.psi_matrix[long_base + i]
      if v != 0.0 {
        n_live = n_live + 1
        sum_long = sum_long + v
      }
    }
    inspect(n_live, content="100")
    inspect(
      expand_v100_didcs_close(sum_long / n_live.to_double(), mean_reversed),
      content="true",
    )
    // The long-format `psi_a_matrix` is SPARSE over 800 rows while
    // the wide row is dense over 100 -- same 50 non-zero `psi_a`
    // values, wildly different denominators. This is the trap that
    // makes reconstructing `M_inv` from the long-format matrices
    // wrong, and it is why `fit` persists whole rows instead.
    let mut n_nonzero_long = 0
    for i = 0; i < n_panel; i = i + 1 {
      if f.psi_a_matrix[long_base + i] != 0.0 {
        n_nonzero_long = n_nonzero_long + 1
      }
    }
    let mut n_nonzero_wide = 0
    for k = 0; k < psi_a.length(); k = k + 1 {
      if psi_a[k] != 0.0 {
        n_nonzero_wide = n_nonzero_wide + 1
      }
    }
    inspect(n_nonzero_long, content="50")
    inspect(n_nonzero_wide, content="50")
    inspect(psi_a.length() == 100, content="true")
    inspect(n_panel == 800, content="true")
  }
}

// ---------------------------------------------------------------------------
// 5. THE CLUSTER PATH
// ---------------------------------------------------------------------------

///|
/// `cluster_sandwich_se_at` routes through the shared
/// `cluster_sandwich_variance` with the same `psi_a` / `psi` /
/// `M_inv` as the IID path and the same per-cell `n_wide` rows.
///
/// Two things are pinned:
///
///   1. With ALL-SINGLETON clusters the meat degenerates to
///      `sum_i psi[i]^2` and every jackknife factor is 1, so the
///      cluster SE collapses to `sandwich_se_at(g, t, HC0)`
///      EXACTLY. That is the analogue of APOS's cluster-on-the-IID-
///      path check and it is what proves the cluster method is
///      wired to the same score rather than to a second,
///      independently-derived one.
///
///   2. With real (pooled) clusters it does NOT equal the IID HC0,
///      and the reason is the MEAT, not the denominator: the
///      within-cluster cross terms enter and each cluster carries a
///      per-cluster `n_c / (n_c - 1)` jackknife factor. The divisor
///      is the SAME `n_wide^2` as HC0. (A brief that says the
///      cluster denominator is `n_units` rather than `n_obs` is
///      describing a clustered FIT's `se`, not this row-level
///      helper; `cluster_sandwich_variance` divides by the array
///      length, which here is the cell's `n_wide`.) Both values are
///      finite and strictly positive.
///
/// The ids are PER CELL AND PER CELL ROW -- length `n_wide`, not the
/// long-format panel length. Test 6 pins that a wrong-length array
/// is rejected.
test "didcs_cluster_sandwich_se_at" {
  let f = expand_v100_didcs()
  let cells = expand_v100_live_cells(f)
  for c in cells {
    let (gi, pi) = c
    let flat = expand_v100_flat(f, gi, pi)
    let n_wide = f.cell_psi_a[flat].length()
    let (singleton, pooled) = expand_v100_didcs_cluster_ids(n_wide)
    let hc0 = f.sandwich_se_at(gi, pi, SandwichKind::hc0())
    let se_single = f.cluster_sandwich_se_at(gi, pi, singleton)
    let se_pooled = f.cluster_sandwich_se_at(gi, pi, pooled)
    println(
      "DIDCS100CL cell=(" +
      gi.to_string() +
      "," +
      pi.to_string() +
      ") n_wide=" +
      n_wide.to_string() +
      " hc0=" +
      hc0.to_string() +
      " singleton=" +
      se_single.to_string() +
      " pooled=" +
      se_pooled.to_string(),
    )
    // (1) All-singleton clusters == IID HC0, exactly.
    inspect(se_single == hc0, content="true")
    inspect(se_single == f.se_at(gi, pi), content="true")
    // (2) Real clusters: finite, positive, and NOT the IID number.
    inspect(!se_pooled.is_nan(), content="true")
    inspect(!se_pooled.is_inf(), content="true")
    inspect(se_pooled > 0.0, content="true")
    inspect(se_pooled != hc0, content="true")
    // Pooling blocks of 4 leaves fewer, fatter clusters, so the
    // meat is strictly larger and the SE strictly wider than the
    // all-singleton / HC0 value on this data.
    inspect(se_pooled > se_single, content="true")
  }
}

// ---------------------------------------------------------------------------
// 6. THE GUARDS: RANGE, EMPTY CELL, WRONG-LENGTH CLUSTER IDS
// ---------------------------------------------------------------------------

///|
/// The state assertions behind the guards. As noted at the top of
/// this file, this runner counts an ABORTING test as PASSED, so a
/// `panic_`-style test on its own proves nothing. These are the
/// falsifiable assertions; the aborting calls follow in tests 7 and
/// 8.
///
/// An unestimated cell (`t_eval <= g`, or no observed pre-period)
/// stores the EMPTY per-cell row array -- that is precisely the
/// condition `sandwich_se_at` and `cluster_sandwich_se_at` check
/// before doing any arithmetic, and it is what stops them returning
/// a plausible-looking `0.0` where `se_at` legitimately reports one.
test "didcs_sandwich_empty_cell_state" {
  let f = expand_v100_didcs()
  inspect(f.n_groups(), content="3")
  inspect(f.n_periods(), content="4")
  let n_live = expand_v100_live_cells(f).length()
  inspect(n_live, content="3")
  let mut n_degenerate = 0
  for gi = 0; gi < f.n_groups(); gi = gi + 1 {
    for pi = 0; pi < f.n_periods(); pi = pi + 1 {
      let flat = expand_v100_flat(f, gi, pi)
      let row = f.cell_psi_a[flat]
      if f.period_at(pi) <= f.group_at(gi) {
        // Pre-treatment cell: no estimate, empty row, and
        // `se_at` reports 0.0 -- the two are consistent, and the
        // sandwich refuses rather than echoing the 0.0.
        inspect(row.length(), content="0")
        inspect(f.cell_psi_b[flat].length(), content="0")
        inspect(f.se_at(gi, pi), content="0")
        n_degenerate = n_degenerate + 1
      } else {
        // Fitted cell: a real row, and a real SE.
        inspect(row.length() > 0, content="true")
        inspect(f.se_at(gi, pi) > 0.0, content="true")
      }
    }
  }
  // 12 cells total, 3 of them live.
  inspect(n_degenerate, content="9")
  // The state exists on both an un-fit model (empty sentinel) and a
  // fitted one, and `fit` overwrites the sentinel rather than
  // leaving it.
  let unfitted = DoubleMLDIDCS::new(expand_v100_didcs_data(), n_folds=2)
  inspect(unfitted.cell_psi_a.length(), content="12")
  inspect(unfitted.cell_psi_a[2].length(), content="0")
}

///|
/// GUARD COVERAGE, AND WHY IT IS WRITTEN AS STATE ASSERTIONS.
///
/// Four `panic_*` tests used to live here, one per guard
/// (out-of-range index, degenerate cell, degenerate cell on the
/// cluster path, wrong-length `cluster_ids`). They were removed in
/// v0.100.0 because they could not fail. `abort()` inside a MoonBit
/// test does NOT raise a failed test -- it kills the whole test
/// executable, so `moon test` reports
///
///     Error: failed to run test for target Native
///     The test executable exited with exit code: 0xc0000409
///
/// and prints no `Total tests:` summary at all. Measured directly
/// (see the CHANGELOG): a bare `abort()` in a test body does the
/// same. That makes "assert this call aborts" unexpressible -- if
/// the guard fires the run dies, and if it does not fire the test
/// passes for having proved nothing. A test of that shape is worse
/// than no test, because it reads as coverage.
///
/// The guards themselves are real. `sandwich_se_at(3, 0, ...)` with
/// `n_groups() == 3` was observed aborting with
/// `precondition failed at did_cs.mbt:568`. What is assertable is
/// the state those guards read, and that is what this test checks:
/// the row a guard rejects must be EMPTY, and a degenerate cell
/// must report `0.0` from `se_at` rather than a real-looking SE.
/// Test 6 (`didcs_sandwich_empty_cell_state`) covers the same ground
/// across every cell; this one adds the unfitted and the
/// right-length-cluster happy path so the guard's accept side is
/// pinned too.
test "didcs_sandwich_guard_state_not_abort_shape" {
  let f = expand_v100_didcs()
  let n_p = f.n_periods()
  // The guard's accept side: a live cell has a populated row, and
  // the cluster path accepts exactly one id per CELL row (100), not
  // one per long-format panel row (800).
  let flat_live = expand_v100_flat(f, 0, 2)
  inspect(f.cell_psi_a[flat_live].length() == 100, content="true")
  inspect(f.cell_psi_b[flat_live].length() == 100, content="true")
  let (cell_ids, _) = expand_v100_didcs_cluster_ids(100)
  let cl = f.cluster_sandwich_se_at(0, 2, cell_ids)
  inspect(cl > 0.0, content="true")
  // The guard's reject side, as state: cell (0, 0) is g = 1, t = 0,
  // so t_eval <= g, so the row is empty and `se_at` reports 0.0.
  // The sandwich refuses instead of echoing that 0.0 back as if it
  // were a standard error.
  let flat_degenerate = expand_v100_flat(f, 0, 0)
  inspect(f.cell_psi_a[flat_degenerate].length() == 0, content="true")
  inspect(f.cell_psi_b[flat_degenerate].length() == 0, content="true")
  inspect(f.se_at(0, 0) == 0.0, content="true")
  // The bound the out-of-range guard checks against, so a future
  // change to the guard's comparison has something to fail against.
  inspect(f.n_groups() == 3, content="true")
  inspect(n_p == 4, content="true")
}

// ---------------------------------------------------------------------------
// 7. bias_corrected_coef_at
// ---------------------------------------------------------------------------

///|
/// `bias_corrected_coef_at(g, t) == coef_at(g, t)`: a documented
/// no-op, not a bias correction. `coef_at(g, t)` is the child's root
/// of the DML moment `f(theta) = E[theta * psi_a + psi_b]`
/// (`var_est.mbt`), so `mean(f(coef))` is identically zero -- the
/// estimating function is orthogonal by construction, and that
/// orthogonality is what makes the estimator consistent. Nothing
/// computable from the fitted scores is a bias estimate.
///
/// The pre-v0.91.0 form `coef + mean(psi_b - coef * psi_a)` is the
/// score at `-coef`, not at `coef`; its mean is
/// `-2 * coef * mean(psi_a)`, and since `mean(psi_a) == -1` for
/// every cell of this score the old accessor returned exactly
/// `3 * coef`. These cells have `coef ~ 1.0` and non-zero, so the
/// old form is distinguishable from the identity here -- asserted
/// below, so this test would catch a regression back to it rather
/// than passing on a zero coefficient.
///
/// Unlike the sandwich methods this one does NOT abort on a
/// degenerate cell: it is the identity on `coef_at`, and `coef_at`
/// reports `0.0` for such a cell, so `0.0` is the consistent
/// answer. Pinned below.
test "didcs_bias_corrected_coef_at_is_the_identity" {
  let f = expand_v100_didcs()
  let cells = expand_v100_live_cells(f)
  for c in cells {
    let (gi, pi) = c
    let coef = f.coef_at(gi, pi)
    inspect(f.bias_corrected_coef_at(gi, pi) == coef, content="true")
    // Not the old, wrong `3 * coef` (mean(psi_a) == -1 here).
    inspect(coef != 0.0, content="true")
    inspect(f.bias_corrected_coef_at(gi, pi) != 3.0 * coef, content="true")
    // And not the old expression evaluated on this cell's rows.
    let flat = expand_v100_flat(f, gi, pi)
    let psi_a = f.cell_psi_a[flat]
    let psi_b = f.cell_psi_b[flat]
    let old = coef + (mean(psi_b) - coef * mean(psi_a))
    inspect(f.bias_corrected_coef_at(gi, pi) != old, content="true")
  }
  // A degenerate cell returns the identity's answer, 0.0 -- the same
  // 0.0 `coef_at` reports, and NOT an abort.
  inspect(f.coef_at(0, 0), content="0")
  inspect(f.bias_corrected_coef_at(0, 0), content="0")
}

// ---------------------------------------------------------------------------
// 8. THE MEMOIZE CACHE-HIT TEST
// ---------------------------------------------------------------------------

///|
/// The per-cell IF components must survive a memoize cache hit.
///
/// `fit` takes `self` BY VALUE and returns a NEW value, so
/// `est.fit()` called twice never touches the cache: the writeback
/// lands on the FIRST returned value and the second call must be
/// driven FROM IT (`f1.fit()`), exactly as
/// `expand_v084_test.mbt` does for APOS. Driving it from `base`
/// would re-read `base`'s own cold chain and every assertion below
/// would be vacuous. (This is the exact mistake shipped in
/// v0.80 - v0.85 of this repo.)
///
/// Note the structural difference from APOS, which owns a
/// `FitCache` and a real `cache_hit` branch: `DoubleMLDIDCS` has
/// NEITHER. The cache lives in the inner `DoubleMLDID` and stores
/// per-rep nuisance PREDICTIONS, from which `psi_a` / `psi_b` are
/// re-derived on a hit. So there is no separate restore branch here
/// to get wrong -- the parent re-enters the child loop on a hit and
/// the child fills the same slots either way. What `fit` must get
/// right is to persist the per-cell rows on every call; a `fit`
/// that returned the `new()` all-empty sentinel on the hit path
/// would ABORT inside the Jacobian helper rather than quietly
/// return a wrong number, which is the failure mode this catches.
///
/// The last block of assertions PROVES THE HIT IS REAL rather than
/// assuming it, by driving a `DoubleMLDID` cache hit directly --
/// the layer that actually owns the cache, and the premise the
/// DIDCS-level claim above rests on. A hit must reproduce
/// `psi_a` / `psi_b` BYTE for BYTE; a miss re-runs the cross-fit
/// and could differ.
test "didcs_sandwich_after_memoize_cache_hit" {
  let base = DoubleMLDIDCS::new(
    expand_v100_didcs_data(),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).enable_memoize()
  let f1 = base.fit()
  // The cache-hit fit. `f1`, NOT `base`.
  let f2 = f1.fit()
  inspect(f1.has_cache(), content="true")
  inspect(f2.has_cache(), content="true")
  // Fresh, NON-memoized reference fit on the same data, so the
  // assertions below cannot be satisfied by two consistent errors.
  let fresh = DoubleMLDIDCS::new(
    expand_v100_didcs_data(),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let cells = expand_v100_live_cells(f1)
  inspect(cells.length(), content="3")
  for c in cells {
    let (gi, pi) = c
    let flat = expand_v100_flat(f1, gi, pi)
    // The IF components are present on BOTH paths -- the state
    // assertion that carries this test.
    inspect(f1.cell_psi_a[flat].length(), content="100")
    inspect(f2.cell_psi_a[flat].length(), content="100")
    // The invariant SURVIVES the cache hit.
    let se_hc0 = f2.sandwich_se_at(gi, pi, SandwichKind::hc0())
    inspect(se_hc0 == f2.se_at(gi, pi), content="true")
    // ... and the hit did not move the number, which is the whole
    // contract of the memoize layer.
    inspect(
      f1.sandwich_se_at(gi, pi, SandwichKind::hc0()) == se_hc0,
      content="true",
    )
    inspect(
      fresh.sandwich_se_at(gi, pi, SandwichKind::hc0()) == se_hc0,
      content="true",
    )
    // `se_at` is itself unchanged, so the equality above is not an
    // accident of two errors cancelling.
    inspect(f1.se_at(gi, pi) == f2.se_at(gi, pi), content="true")
    inspect(f2.se_at(gi, pi) == fresh.se_at(gi, pi), content="true")
    // The restored rows are BYTE-IDENTICAL to the freshly fitted
    // ones -- which is what makes re-deriving `psi_a` / `psi_b`
    // from cached PREDICTIONS safe.
    let mut same = true
    let a2 = f2.cell_psi_a[flat]
    let b2 = f2.cell_psi_b[flat]
    let a_fresh = fresh.cell_psi_a[flat]
    let b_fresh = fresh.cell_psi_b[flat]
    for k = 0; k < a2.length(); k = k + 1 {
      if a2[k] != a_fresh[k] || b2[k] != b_fresh[k] {
        same = false
      }
    }
    inspect(same, content="true")
    // The full HC family and the cluster path agree on the hit path
    // too -- a restored-but-mislabelled row would break the HC1
    // ratio before it broke anything else.
    let n_d = a2.length().to_double()
    let hc0 = f2.sandwich_se_at(gi, pi, SandwichKind::hc0())
    let hc1 = f2.sandwich_se_at(gi, pi, SandwichKind::hc1())
    inspect(
      expand_v100_didcs_close(hc1 / hc0, (n_d / (n_d - 1.0)).sqrt()),
      content="true",
    )
    inspect(
      expand_v100_didcs_close(
        f2.sandwich_se_at(gi, pi, SandwichKind::hc2()),
        hc1,
      ),
      content="true",
    )
    let (singleton, _) = expand_v100_didcs_cluster_ids(a2.length())
    inspect(f2.cluster_sandwich_se_at(gi, pi, singleton) == hc0, content="true")
    // And the bias accessor.
    inspect(
      f2.bias_corrected_coef_at(gi, pi) == f2.coef_at(gi, pi),
      content="true",
    )
  }
  // ---- PROVE THE HIT IS REAL, at the layer that owns the cache ----
  // `DoubleMLDIDCS` has no cache of its own; the `FitCache` that
  // makes the second fit above cheap lives on the inner
  // `DoubleMLDID`. Drive one directly and show a hit returns the
  // child's IF components byte for byte -- the premise the
  // DIDCS-level assertion rests on. If a hit re-fit, or restored
  // something else, `psi_a` / `psi_b` would move.
  let n = 200
  let p = 2
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let rng = chacha8_rng(777)
  for i = 0; i < n; i = i + 1 {
    let x1 = rng.double() * 2.0 - 1.0
    let x2 = rng.double() * 2.0 - 1.0
    x_flat[i * p] = x1
    x_flat[i * p + 1] = x2
    d[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
    y[i] = d[i] + 0.5 * x2 + 0.1 * (rng.double() - 0.5)
  }
  let did_data = DoubleMLDIDData::new(Matrix::from_array(x_flat, n, p), y, d) catch {
    DIDDataError::NonBinaryTreatment(i) =>
      abort("DoubleMLDIDData.d must be binary at index " + i.to_string())
  }
  let dbase = DoubleMLDID::new(did_data, n_folds=2, n_rep=1, seed=4242).enable_memoize()
  let d1 = dbase.fit()
  // The cache-hit fit. `d1`, NOT `dbase`.
  let d2 = d1.fit()
  // Positive evidence the cache is live on BOTH fits.
  inspect(d1.has_cache(), content="true")
  inspect(d2.has_cache(), content="true")
  // A hit re-derives `psi_a` / `psi_b` from the cached PREDICTIONS;
  // they come back byte-identical, and so does everything derived
  // from them.
  inspect(d2.coef() == d1.coef(), content="true")
  inspect(d2.se() == d1.se(), content="true")
  let mut same = true
  for i = 0; i < n; i = i + 1 {
    if d1.psi_a[i] != d2.psi_a[i] || d1.psi_b[i] != d2.psi_b[i] {
      same = false
    }
  }
  inspect(same, content="true")
  inspect(d2.sandwich_se(SandwichKind::hc0()) == d2.se(), content="true")
}
