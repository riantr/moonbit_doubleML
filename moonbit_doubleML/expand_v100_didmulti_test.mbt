///|
// v0.100.0: `DoubleMLDIDMulti` gets the per-cell sandwich API.
//
// WHERE DIDMULTI SITS IN THE FAMILY
// ===============================
// Nineteen estimators now carry `sandwich_se` /
// `cluster_sandwich_se` / `bias_corrected_coef`. `DoubleMLDIDCS`
// (added earlier today) got the per-cell one;
// `DoubleMLDIDMulti` is the layer ABOVE it, and the only remaining
// DID-shaped omission. It is the smallest job in the series:
//
// WHAT THIS WRAPPER ACTUALLY IS
// -----------------------------
// `DoubleMLDIDMulti` is a THIN WRAPPER. Its `fit` is:
//
//     let inner = ...self.inner.fit(ml_g~, ml_m~)
//     { ..self, inner, ml_g, ml_m, fitted: true }
//
// and it persists NO per-cell score state of its own -- only
// `group_sizes` (aggregation weights) and `boot_t_stat` (bootstrap
// t-statistics). Every number it reports is the inner's. So the three
// new accessors are pure FORWARDS, and the design rule that follows
// is "add no state": the three index-forwarding methods below are
// `require` + triple -> `(gi, pi)` -> one inner call, with no
// arithmetic in between. That is what makes
//
//     sandwich_se_at_idx(idx, kind)
//       == inner.sandwich_se_at(gi, pi, kind)
//
// bit for bit rather than close, and it is why
// `sandwich_se_at_idx(idx, HC0) == se_at_idx(idx)` inherits the
// inner's measured bit-identity without this layer touching it.
//
// THE INDEX IS THE COMBINATION INDEX
// ---------------------------------
// The DID family's own estimators expose a JOINT, multi-column
// `sandwich_se`, because they estimate a vector. This wrapper
// estimates no vector: it selects a SET of per-cell ATTs. So the
// natural index is the one it already exposes -- the row-major
// `gt_combinations` index used by `coef_at_idx` / `se_at_idx` -- and
// the methods are named `_at_idx` to match. `idx` resolves to the
// inner cell by the same linear scan those two accessors use: read
// `(g, t_pre, t_eval)`, find `g` among `inner.group_at(i)` and
// `t_eval` among `inner.period_at(i)`. `t_pre` is ignored, as it is
// in `coef_at_idx` and `se_at_idx`: the inner is keyed by
// `(g, t_eval)` only, and every keyword expansion fixes `t_pre = g`.
//
// NO REFACTOR OF SHARED CODE
// -------------------------
// The mapping is factored into a NEW private helper
// (`did_multi_inner_cell_at_idx`) used by the three new methods
// only. `coef_at_idx` and `se_at_idx` keep their own inline scans,
// byte for byte. A regression in either of those is then
// impossible to attribute to this change, and the duplicated scan is
// a smaller risk than refactoring a working accessor that other
// suites already pin. The cost is the scan appearing in three
// places instead of one; the benefit is that a change here cannot
// move a number anyone else depends on.
//
// THE KEYWORD DECIDES WHETHER A COMBINATION IS DEAD
// =================================================
// This is the one thing the wrapper adds that the inner does not
// have: `gt_combinations` can NAME a cell the CS-DID fit never
// estimated. `"standard"` emits only `t > g`, so all 3 of its
// combinations are live. `"all"` / `"universal"` also emit the
// pre-treatment placebos `(g, t_pre = g, t_eval < g)`, and the fit
// estimates only `t_eval > g`, so on the shared DGP `"all"` gives
// 9 combinations of which exactly 3 are live and 6 are dead.
//
// The accessors are NOT uniform over that split, and the difference
// is deliberate on both sides:
//   - `sandwich_se_at_idx` and `cluster_sandwich_se_at_idx` ABORT
//     on a dead index. That is the inner's own refusal (it rejects
//     an unestimated cell rather than echo a misleading `0.0` off an
//     empty score row), forwarded rather than smoothed over. A
//     caller sweeping the full range must skip the dead
//     combinations itself.
//   - `bias_corrected_coef_at_idx` does NOT abort, because its
//     answer is the identity on `coef_at_idx` and `coef_at_idx`
//     legitimately reports `0.0` for an unestimated cell.
// So `se_at_idx` also returns `0.0` where the sandwich pair aborts,
// and the three accessors are not interchangeable across a sweep.
//
// A NOTE ON THE ABORT TESTS
// -------------------------
// MEASURED: `abort()` inside a MoonBit test kills the whole test
// executable, and `moon test` then prints
//
//     Error: failed to run test for target Native
//     exit code: 0xc0000409
//
// with NO `Total tests:` summary. So "assert this call aborts" is
// unexpressible -- if the guard fires the run dies, and if it does
// not fire the test passes having proved nothing. Four such tests
// had to be deleted from `expand_v100_didcs_test.mbt` today. This
// file therefore has NONE: the guards are covered by asserting the
// STATE they read (`n_combinations()`, that every combination maps
// to a valid inner `(gi, pi)`, and that a dead combination's
// persisted score row is empty while a live one is not), which is
// the falsifiable part.

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

///|
/// The panel shared by every test in this file: the DGP of
/// `did_cs_test.mbt::did_cs_recovers_known_att_per_cell` (4 cohorts
/// `g = 0..3`, `n_per_cohort = 50`, 4 periods, `p = 3`, true ATT 1.0
/// on treated units with `k > cohort`, `chacha8_rng(11)`),
/// constructed fresh per call so no test can observe another's RNG
/// stream.
///
/// 200 units x 4 periods = 800 long-format rows. The inner has
/// `n_groups = 3` (g = 1, 2, 3 -- the never-treated g = 0 sentinel is
/// excluded) and `n_periods = 4`, so 12 cells of which 3 are live.
fn expand_v100_didmulti_data() -> DoubleMLDIDCSData {
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
/// The fitted `DoubleMLDIDMulti` for a given `gt_combinations`
/// keyword: `n_folds = 2`, `n_rep = 1`, `seed = 3141`, the same
/// settings `did_cs_test.mbt` and
/// `expand_v100_didcs_test.mbt` use, so the inner cells line up with
/// those suites.
///
/// `keyword` is `"all"` (9 combinations: 3 live, 6 dead) or
/// `"standard"` (3 combinations, all live).
fn expand_v100_didmulti(keyword : String) -> DoubleMLDIDMulti {
  DoubleMLDIDMulti::new(
    expand_v100_didmulti_data(),
    gt_combinations_keyword=keyword,
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
}

///|
/// The inner `(group_idx, period_idx)` that `gt_combinations[idx]`
/// names, recomputed INDEPENDENTLY of the production helper (which is
/// private and so not callable from another file's `test`).
///
/// This is the test's own copy of the mapping rule, not a second
/// implementation of the accessor: it exists so test 4 can assert
/// that what the accessor returns is the inner's value at the cell
/// the test independently believes `idx` names. A production mapping
/// that scanned the wrong axis, or matched on `t_pre` instead of
/// `t_eval`, would fail that assertion rather than pass it.
fn expand_v100_didmulti_cell(m : DoubleMLDIDMulti, idx : Int) -> (Int, Int) {
  let (g, _t_pre, t_eval) = m.gt_combinations[idx]
  let mut gi = -1
  let mut pi = -1
  for i = 0; i < m.inner.n_groups(); i = i + 1 {
    if m.inner.group_at(i) == g {
      gi = i
    }
  }
  for i = 0; i < m.inner.n_periods(); i = i + 1 {
    if m.inner.period_at(i) == t_eval {
      pi = i
    }
  }
  (gi, pi)
}

///|
/// Combination indices whose `(g, t_eval)` is a cell the inner
/// actually estimated (`t_eval > g`). Returns 3 indices -- 1, 2, 5 --
/// under the `"all"` keyword.
fn expand_v100_didmulti_live_idx(m : DoubleMLDIDMulti) -> Array[Int] {
  let out : Array[Int] = []
  let mut out_acc = out
  for i = 0; i < m.n_combinations(); i = i + 1 {
    let (g, _t_pre, t_eval) = m.gt_combinations[i]
    if t_eval > g {
      out_acc = out_acc + [i]
    }
  }
  out_acc
}

///|
/// All-singleton (`singleton[i] = i`) and pooled-in-blocks-of-4
/// (`pooled[i] = i / 4`) cluster ids for a cell of `n` rows. The
/// length is the cell's own `n_wide`, NOT the long-format panel
/// length -- the inner requires `cluster_ids.length() == n_wide`.
fn expand_v100_didmulti_cluster_ids(n : Int) -> (Array[Int], Array[Int]) {
  let singleton : Array[Int] = Array::make(n, 0)
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
    pooled[i] = i / 4
  }
  (singleton, pooled)
}

// ---------------------------------------------------------------------------
// 1. THE DECISIVE ONE: se_at_idx(idx) == sandwich_se_at_idx(idx, HC0)
// ---------------------------------------------------------------------------

///|
/// The assertion that puts `DoubleMLDIDMulti` in the sandwich
/// family, for EVERY live combination. Exact equality, with the
/// measured per-index discrepancy PRINTED so the "bit-identical"
/// claim is checkable from the test log rather than taken on faith.
///
/// MEASURED on this DGP under the `"all"` keyword: the absolute and
/// relative differences are exactly `0.0` for all 3 live
/// combinations (indices 1, 2, 5) -- see the `DIDMULTI100` lines.
///
/// Why `==` and not a tolerance is the right claim here, stated
/// carefully: it is not that this wrapper is clever. There is NO
/// arithmetic between the two calls -- the accessor returns
/// `inner.sandwich_se_at(gi, pi, kind)` unchanged -- so
/// `sandwich_se_at_idx == se_at_idx` is exactly the inner's
/// `sandwich_se_at(gi, pi, HC0) == se_at(gi, pi)`, which was
/// MEASURED bit-identical (abs_diff `0.0`) on every non-degenerate
/// cell of this DGP. `var_est` and `sandwich_variance_hc0` run the
/// same op sequence over the same Kahan sum of the same products in
/// the same index order, and `M_inv[0, 0]^2 == 1.0` exactly because
/// the DID score's `psi_a[i] = -d[i] / p_hat` with `p_hat = mean(d)`
/// makes `mean(psi_a) == -1`.
test "didmulti_sandwich_hc0_equals_se_per_combination" {
  let m = expand_v100_didmulti("all")
  let live = expand_v100_didmulti_live_idx(m)
  inspect(live.length(), content="3")
  for i in live {
    let (gi, pi) = expand_v100_didmulti_cell(m, i)
    let se_hc0 = m.sandwich_se_at_idx(i, SandwichKind::hc0())
    let se = m.se_at_idx(i)
    let abs_diff = se_hc0 - se
    let rel_diff = if se == 0.0 { 0.0 } else { abs_diff / se }
    println(
      "DIDMULTI100 idx=" +
      i.to_string() +
      " inner=(" +
      gi.to_string() +
      "," +
      pi.to_string() +
      ")" +
      " hc0=" +
      se_hc0.to_string() +
      " se_at_idx=" +
      se.to_string() +
      " abs_diff=" +
      abs_diff.to_string() +
      " rel_diff=" +
      rel_diff.to_string(),
    )
    // Exact equality, bit for bit.
    inspect(se_hc0 == se, content="true")
    // And the surface is not all zeros: an SE of 0.0 would make the
    // equality above true for the wrong reason.
    inspect(se > 0.0, content="true")
    // The wrapper added nothing, including no scaling.
    inspect(
      se_hc0 == m.inner.sandwich_se_at(gi, pi, SandwichKind::hc0()),
      content="true",
    )
  }
}

// ---------------------------------------------------------------------------
// 2. THE INDEX IS LOAD-BEARING
// ---------------------------------------------------------------------------

///|
/// ANTI-VACUITY. A forward that ignored `idx`, or that hardcoded
/// index 0, would satisfy test 1 on any DGP whose cells all had the
/// same SE. Three independent facts rule that out:
///
///  1. Three different live indices give three DIFFERENT SEs
///     (checked for all three unordered pairs), so "always index 0"
///     and "ignore `idx`" both fail here.
///  2. Index 0 is DEAD under the `"all"` keyword, so a
///     hardcoded-index-0 implementation would not merely return the
///     wrong number, it would abort inside the inner. The live
///     indices are 1, 2, 5 -- pinned here.
///  3. Each live index's value equals the inner's value at the cell
///     this test INDEPENDENTLY maps it to (`expand_v100_didmulti_cell`
///     is a separate copy of the mapping rule, since the production
///     helper is private). A mapping that scanned the wrong axis, or
///     matched on `t_pre` rather than `t_eval`, breaks this -- and
///     would still pass test 1 on a single cell.
///
/// The explicit (idx, gi, pi) triples are printed so the mapping is
/// visible in the log: 1 -> (0, 2), 2 -> (0, 3), 5 -> (1, 3), which
/// are the inner's 3 live cells (g = 1, t = 2), (g = 1, t = 3),
/// (g = 2, t = 3).
test "didmulti_combination_index_is_not_interchangeable" {
  let m = expand_v100_didmulti("all")
  let live = expand_v100_didmulti_live_idx(m)
  inspect(live.length(), content="3")
  // (2) The live indices, pinned: index 0 is NOT among them.
  inspect(live[0], content="1")
  inspect(live[1], content="2")
  inspect(live[2], content="5")
  // The dead head of the range, so "always index 0" is visibly wrong.
  let (g0, _tp0, t0) = m.gt_combinations[0]
  inspect(g0, content="1")
  inspect(t0, content="0")
  // (3) The mapping, per live index, against the independently
  // computed cell.
  let (g1, p1) = expand_v100_didmulti_cell(m, 1)
  inspect(g1, content="0")
  inspect(p1, content="2")
  let (g2, p2) = expand_v100_didmulti_cell(m, 2)
  inspect(g2, content="0")
  inspect(p2, content="3")
  let (g5, p5) = expand_v100_didmulti_cell(m, 5)
  inspect(g5, content="1")
  inspect(p5, content="3")
  // Build the per-index values, then (1) require all three distinct.
  let vals : Array[Double] = []
  let mut vals_acc = vals
  for i in live {
    let (gi, pi) = expand_v100_didmulti_cell(m, i)
    let v = m.sandwich_se_at_idx(i, SandwichKind::hc0())
    // The wrapper value is the inner's value at the cell `idx`
    // names -- a wrong mapping cannot produce this.
    inspect(
      v == m.inner.sandwich_se_at(gi, pi, SandwichKind::hc0()),
      content="true",
    )
    vals_acc = vals_acc + [v]
  }
  inspect(vals_acc[0] != vals_acc[1], content="true")
  inspect(vals_acc[0] != vals_acc[2], content="true")
  inspect(vals_acc[1] != vals_acc[2], content="true")
  // And the same for `se_at_idx`, so test 1's equality is a pairing
  // of two index-respecting accessors rather than one index-respecting
  // accessor and a constant.
  inspect(m.se_at_idx(live[0]) != m.se_at_idx(live[1]), content="true")
  inspect(m.se_at_idx(live[1]) != m.se_at_idx(live[2]), content="true")
  // `coef_at_idx` agrees with the bias accessor index-wise too, and
  // the coefficients are non-zero (the DGP's true ATT is 1.0), so the
  // identity asserted in test 3 is not 0.0 == 0.0.
  inspect(m.coef_at_idx(live[0]) != m.coef_at_idx(live[1]), content="true")
  inspect(m.coef_at_idx(live[0]) != 0.0, content="true")
}

// ---------------------------------------------------------------------------
// 3. bias_corrected_coef_at_idx
// ---------------------------------------------------------------------------

///|
/// `bias_corrected_coef_at_idx(idx) == coef_at_idx(idx)`: a
/// documented no-op, not a bias correction. The child's ATT is the
/// root of the DML moment `f(theta) = E[theta * psi_a + psi_b]`, so
/// `mean(f(coef))` is identically zero -- the estimating function is
/// orthogonal by construction, and that orthogonality is what makes
/// the estimator consistent. Nothing computable from the fitted
/// scores is a bias estimate for this class of estimator.
///
/// The pre-v0.91.0 form `coef + mean(psi_b - coef * psi_a)` is that
/// score at `-coef`, not at `coef`; with `coef = -mean_b / mean_a`
/// its mean is `-2 * coef * mean(psi_a)`, and `mean(psi_a) == -1` for
/// every cell of this score, so the old accessor returned exactly
/// `3 * coef`. These coefficients are ~1.0 and non-zero, so that is
/// distinguishable here and is asserted below -- a regression to the
/// old form fails rather than passing on a zero.
///
/// Asserted for ALL 9 combinations, not just the live ones: unlike
/// the sandwich pair, this accessor does NOT abort on a dead
/// combination, and the reason it need not is that `0.0` IS the
/// consistent answer there (`coef_at_idx` reports `0.0` for an
/// unestimated cell, and the accessor is the identity on it).
test "didmulti_bias_corrected_coef_is_the_identity" {
  let m = expand_v100_didmulti("all")
  let live = expand_v100_didmulti_live_idx(m)
  inspect(m.n_combinations(), content="9")
  for i in live {
    let coef = m.coef_at_idx(i)
    inspect(m.bias_corrected_coef_at_idx(i) == coef, content="true")
    inspect(coef != 0.0, content="true")
    // Not the old, wrong `3 * coef`.
    inspect(m.bias_corrected_coef_at_idx(i) != 3.0 * coef, content="true")
    // And not the old expression evaluated on this cell's own rows.
    let (gi, pi) = expand_v100_didmulti_cell(m, i)
    let flat = gi * m.inner.n_periods() + pi
    let psi_a = m.inner.cell_psi_a[flat]
    let psi_b = m.inner.cell_psi_b[flat]
    let old = coef + (mean(psi_b) - coef * mean(psi_a))
    inspect(m.bias_corrected_coef_at_idx(i) != old, content="true")
  }
  // A dead combination returns the identity's answer, 0.0 -- the same
  // 0.0 `coef_at_idx` reports, and NOT an abort. This is the
  // asymmetry with the sandwich pair, and it is why this accessor is
  // the one that is safe across a full sweep.
  for i in 0..<m.n_combinations() {
    inspect(m.bias_corrected_coef_at_idx(i) == m.coef_at_idx(i), content="true")
  }
  inspect(m.coef_at_idx(0), content="0")
  inspect(m.bias_corrected_coef_at_idx(0), content="0")
}

// ---------------------------------------------------------------------------
// 4. THE CLUSTER PATH
// ---------------------------------------------------------------------------

///|
/// `cluster_sandwich_se_at_idx` routes through the shared
/// `cluster_sandwich_variance` with the same `psi_a` / `psi` /
/// `M_inv` and the same per-cell `n_wide` rows as the IID path -- the
/// wrapper forwards the call and adds nothing.
///
/// Two things are pinned, and the first is the one that proves the
/// cluster method is wired to the same score rather than to a second,
/// independently derived one:
///
///  1. With ALL-SINGLETON clusters the meat degenerates to
///     `sum_i psi[i]^2` and every jackknife factor is 1, so the
///     cluster SE collapses to `sandwich_se_at_idx(idx, HC0)`
///     EXACTLY -- and hence also to `se_at_idx(idx)`.
///  2. With real (pooled) clusters it does NOT equal the IID HC0,
///     and the reason is the MEAT, not the denominator.
///     `cluster_sandwich_variance` divides by the array length, which
///     here is the cell's own `n_wide` -- the SAME divisor HC0 uses --
///     while summing `S_c = (sum_{i in c} psi[i])^2` per cluster, so
///     the within-cluster cross terms enter and each cluster carries a
///     `n_c / (n_c - 1)` jackknife factor. A brief that describes the
///     cluster denominator as `n_units` is describing a clustered
///     FIT's `se`, not this row-level helper. The pooled value is
///     finite, positive, strictly wider than the singleton value on
///     this data, and different from it.
///
/// The ids are PER CELL ROW: length `n_wide` (100 on this DGP), not
/// the long-format panel length (800). The length is taken from the
/// cell's own persisted row rather than hardcoded, so the assertion
/// also pins that the wrapper is passing the inner's `n_wide` and not
/// a panel-sized array.
test "didmulti_cluster_sandwich_se_at_idx" {
  let m = expand_v100_didmulti("all")
  let live = expand_v100_didmulti_live_idx(m)
  inspect(live.length(), content="3")
  for i in live {
    let (gi, pi) = expand_v100_didmulti_cell(m, i)
    let flat = gi * m.inner.n_periods() + pi
    let n_wide = m.inner.cell_psi_a[flat].length()
    // The cell's own wide row, not the 800-row long-format panel.
    inspect(n_wide, content="100")
    let (singleton, pooled) = expand_v100_didmulti_cluster_ids(n_wide)
    let hc0 = m.sandwich_se_at_idx(i, SandwichKind::hc0())
    let se_single = m.cluster_sandwich_se_at_idx(i, singleton)
    let se_pooled = m.cluster_sandwich_se_at_idx(i, pooled)
    println(
      "DIDMULTI100CL idx=" +
      i.to_string() +
      " n_wide=" +
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
    inspect(se_single == m.se_at_idx(i), content="true")
    // (2) Real clusters: finite, positive, and NOT the IID number.
    inspect(!se_pooled.is_nan(), content="true")
    inspect(!se_pooled.is_inf(), content="true")
    inspect(se_pooled > 0.0, content="true")
    inspect(se_pooled != hc0, content="true")
    // Pooling blocks of 4 leaves fewer, fatter clusters, so the
    // meat is strictly larger and the SE strictly wider.
    inspect(se_pooled > se_single, content="true")
    // Index-respecting: two live indices cluster differently.
    inspect(
      m.cluster_sandwich_se_at_idx(live[0], pooled) !=
      m.cluster_sandwich_se_at_idx(live[1], pooled),
      content="true",
    )
  }
}

// ---------------------------------------------------------------------------
// 5. THE "standard" KEYWORD: EVERY COMBINATION IS LIVE
// ---------------------------------------------------------------------------

///|
/// The default keyword is the one a caller gets for free, and it has
/// the opposite dead/live split from `"all"`: `"standard"` emits only
/// `t > g`, so ALL of its combinations map to estimated inner cells
/// and every one of the three new accessors works on all of them.
/// This is the configuration in which a sweep over the full
/// `0..<n_combinations()` range is safe.
///
/// 3 combinations, `(g, t_pre, t_eval)` = (1, 1, 2), (1, 1, 3),
/// (2, 2, 3), mapping to the inner's live cells (0, 2), (0, 3),
/// (1, 3) -- the same 3 cells `"all"` reaches, reached by
/// combination indices 0, 1, 2 here instead of 1, 2, 5. That the
/// inner cells are the same while the indices shift is the point: the
/// index is a position in `gt_combinations`, NOT a cell id.
test "didmulti_standard_keyword_all_combinations_live" {
  let m = expand_v100_didmulti("standard")
  inspect(m.n_combinations(), content="3")
  // Nothing is dead under "standard".
  let live = expand_v100_didmulti_live_idx(m)
  inspect(live.length(), content="3")
  inspect(live[0], content="0")
  inspect(live[1], content="1")
  inspect(live[2], content="2")
  let (sa, sb) = expand_v100_didmulti_cell(m, 0)
  inspect(sa, content="0")
  inspect(sb, content="2")
  let (sc, sd) = expand_v100_didmulti_cell(m, 1)
  inspect(sc, content="0")
  inspect(sd, content="3")
  let (se_, sf) = expand_v100_didmulti_cell(m, 2)
  inspect(se_, content="1")
  inspect(sf, content="3")
  for i in live {
    let (gi, pi) = expand_v100_didmulti_cell(m, i)
    let hc0 = m.sandwich_se_at_idx(i, SandwichKind::hc0())
    inspect(hc0 == m.se_at_idx(i), content="true")
    inspect(hc0 > 0.0, content="true")
    let n_wide = m.inner.cell_psi_a[gi * m.inner.n_periods() + pi].length()
    let (singleton, pooled) = expand_v100_didmulti_cluster_ids(n_wide)
    inspect(m.cluster_sandwich_se_at_idx(i, singleton) == hc0, content="true")
    inspect(m.cluster_sandwich_se_at_idx(i, pooled) > 0.0, content="true")
    inspect(m.bias_corrected_coef_at_idx(i) == m.coef_at_idx(i), content="true")
  }
  // Same inner numbers as the "all" build: the wrapper reads the
  // inner, and the inner does not know about the keyword.
  let a = expand_v100_didmulti("all")
  for i in live {
    let j = expand_v100_didmulti_live_idx(a)[i]
    inspect(
      m.sandwich_se_at_idx(i, SandwichKind::hc0()) ==
      a.sandwich_se_at_idx(j, SandwichKind::hc0()),
      content="true",
    )
  }
}

// ---------------------------------------------------------------------------
// 6. THE GUARDS, AS STATE ASSERTIONS
// ---------------------------------------------------------------------------

///|
/// The guards are real; what is assertable is the STATE they read.
/// Per the note at the top of this file, a test whose only assertion
/// is "this call aborts" cannot fail usefully -- `abort()` kills the
/// test executable, so `moon test` dies with exit code `0xc0000409`
/// and prints no summary. So this file asserts what the guards read:
///
///   - the RANGE guard's bound: `n_combinations()` and the length of
///     the very array being indexed;
///   - the MAPPING guard's precondition: EVERY one of the 9
///     combinations resolves to a valid inner `(gi, pi)` -- the
///     `require(gi >= 0 && pi >= 0)` in the production helper -- so
///     a combination naming a `g` or a `t_eval` outside the inner's
///     grid would fail here rather than being masked by the
///     degenerate-cell abort;
///   - the DEGENERATE guard's precondition: a dead combination's
///     persisted inner score row is EMPTY (length 0). That empty row
///     is exactly the condition the inner's
///     `cell_psi_a_row_at` rejects, and `mean([])` on it is what
///     would abort -- so the row length is the falsifiable state,
///     asserted rather than triggered;
///   - the accept side: a live combination's row is populated
///     (length 100) and its SE is positive, so the assertions above
///     are not describing an all-empty surface.
test "didmulti_guard_state_not_abort_shape" {
  let m = expand_v100_didmulti("all")
  // The range guard's bound, and the array it bounds.
  inspect(m.n_combinations(), content="9")
  inspect(m.gt_combinations.length(), content="9")
  let live = expand_v100_didmulti_live_idx(m)
  inspect(live.length(), content="3")
  let mut n_dead = 0
  let mut n_populated = 0
  let n_comb = m.n_combinations()
  for i in 0..<n_comb {
    // The mapping guard: every combination names a real inner cell.
    let (gi, pi) = expand_v100_didmulti_cell(m, i)
    inspect(gi >= 0, content="true")
    inspect(pi >= 0, content="true")
    inspect(gi < m.inner.n_groups(), content="true")
    inspect(pi < m.inner.n_periods(), content="true")
    let flat = gi * m.inner.n_periods() + pi
    // The degenerate guard's precondition: the row it refuses on.
    if m.inner.cell_psi_a[flat].length() == 0 {
      inspect(m.inner.cell_psi_b[flat].length(), content="0")
      // And the two accessors that answer instead of aborting
      // report the empty cell consistently.
      inspect(m.coef_at_idx(i), content="0")
      inspect(m.se_at_idx(i), content="0")
      inspect(m.bias_corrected_coef_at_idx(i), content="0")
      n_dead = n_dead + 1
    } else {
      // The accept side.
      inspect(m.inner.cell_psi_a[flat].length() > 0, content="true")
      inspect(m.se_at_idx(i) > 0.0, content="true")
      n_populated = n_populated + 1
    }
  }
  // 9 combinations: 3 live, 6 dead. The dead ones are what make this
  // a non-vacuous surface to reason about -- with all 9 live, the
  // degenerate-cell contract above would be untested.
  inspect(n_populated, content="3")
  inspect(n_dead, content="6")
  inspect(n_populated == live.length(), content="true")
  // The state exists before `fit` too: the wrapper's `fitted` flag is
  // the guard the accessors check first, and an un-fit wrapper is
  // distinguishable rather than silently answering.
  let unfitted = DoubleMLDIDMulti::new(
    expand_v100_didmulti_data(),
    gt_combinations_keyword="all",
    n_folds=2,
    n_rep=1,
    seed=3141,
  )
  inspect(unfitted.fitted, content="false")
  inspect(unfitted.n_combinations(), content="9")
}
