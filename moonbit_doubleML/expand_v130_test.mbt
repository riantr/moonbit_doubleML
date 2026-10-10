// v0.130.0 -- `DoubleMLDIDCSBinary::sensitivity_analysis` built its residuals
// from the WRONG ROWS and the WRONG VARIABLE. This file pins the fix.
//
// Upstream oracle (vendored `doubleml-0.11.4`):
//
//   did_cs_binary.py:179-180  self._y_data_subset / _g_data_subset
//   did_cs_binary.py:846-848  y = _y_data_subset; d = _g_data_subset; t = _t_data_subset
//   did_cs_binary.py:856-867  the 4-way (d,t) cell mixture and
//                             sigma2_score_element = (y - g_hat)^2
//
// What the port did before this release:
//
//     let d = self.data.d                                  # the TREATMENT
//     residuals[i] = self.data.y[i]                        # the FULL panel
//                   - g00[i] - (g10[i] - g00[i]) * d[i]    # at SUBSET positions
//
// which is wrong twice. `self.data.d` is the per-period treatment, but every
// other "d" in this estimator -- the propensity, the conditional-g split,
// `psi_a` -- is G (`did_cs_binary.py:472`). And `self.data` is the full panel,
// indexed with subset positions: MEASURED, 240 of the 720 rows read had
// `t == 1`, a period the subset never contains and the period in which `y`
// carries the treatment effect.
//
// The fixture is duplicated from `expand_v128_test.mbt` rather than imported:
// a top-level `fn` without `pub` is FILE-PRIVATE, so these two files cannot
// share one.

// ---------------------------------------------------------------------------
// Staggered-adoption fixture: 3 cohorts x 3 periods. Cohort 0 is
// never-treated; cohorts 1-2 are treated from period 1 onward, with the
// assignment probability driven through a SATURATED score
// (`pi = clamp(0.5 + 1.4*x0, 0.02, 0.98)`).
// ---------------------------------------------------------------------------

///|
fn v130_cs_data(n_per_cohort : Int, p : Int, seed : Int) -> DoubleMLDIDCSData {
  let cohort_count = 3
  let n_periods = 3
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  let rng = chacha8_rng(seed)
  for u = 0; u < n_units; u = u + 1 {
    let cohort = u / n_per_cohort
    let xu : Array[Double] = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      xu[j] = rng.double() * 2.0 - 1.0
    }
    let raw = 0.5 + 1.4 * xu[0]
    let pi = if raw < 0.02 { 0.02 } else if raw > 0.98 { 0.98 } else { raw }
    let is_treated = if cohort > 0 {
      if rng.double() < pi {
        1
      } else {
        0
      }
    } else {
      0
    }
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = xu[j]
      }
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = is_treated
      d[row] = if is_treated == 1 && k >= 1 { 1.0 } else { 0.0 }
      let mut yv = xu[0] + 0.4 * xu[1] + 0.15 * (rng.double() - 0.5)
      if is_treated == 1 && k >= 1 {
        yv = yv + 1.0
      }
      y[row] = yv
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
fn v130_fit(data : DoubleMLDIDCSData) -> DoubleMLDIDCSBinary {
  DoubleMLDIDCSBinary::new(data, 1, 0, 2, n_folds=2, seed=3141).fit()
}

///|
/// GATE 1 -- THE ALIGNMENT INVARIANT, and it is the discriminating one.
///
/// `irm_style_sensitivity` requires `residuals` to be element-wise aligned
/// with `psi_a`. The old code satisfied its length check while being
/// completely misaligned, which is precisely why the bug survived: both arrays
/// were length 720, so `require(n == psi_a.length())` passed.
///
/// This gate attacks it directly. Take the SAME panel and corrupt `y` at every
/// position the old code would have read but the subset does NOT contain --
/// the `t == 1` rows among the first 720. If the residual really is built from
/// the subset's own rows, the sensitivity output must not move by one bit. If
/// it is reading the full panel, it moves immediately.
///
/// MEASURED: 240 rows corrupted, and
/// `sigma2`, `nu2`, `rv` and `max_bias` all come back bit-identical.
/// Under the pre-v0.130.0 code this gate fails with `sigma2` moving by
/// several orders of magnitude.
test "v130_cs_binary_sensitivity_ignores_rows_outside_the_subset" {
  let data = v130_cs_data(120, 2, 5)
  let n_full = data.y.length()
  let base = v130_fit(data)
  let n_sub = base.n_obs()
  assert_true(n_full == 1080)
  assert_true(n_sub == 720)
  // Corrupt exactly the rows the old code read and the subset does not have.
  let y2 : Array[Double] = Array::make(n_full, 0.0)
  let mut corrupted = 0
  for i = 0; i < n_full; i = i + 1 {
    y2[i] = if i < n_sub && data.t[i] == 1 {
      data.y[i] + 1000.0
    } else {
      data.y[i]
    }
    if i < n_sub && data.t[i] == 1 {
      corrupted = corrupted + 1
    }
  }
  assert_true(corrupted == 240)
  let scrambled = DoubleMLDIDCSData::new(
    data.x,
    y2,
    data.d,
    data.t,
    data.id,
    data.g,
  )
  let other = v130_fit(scrambled)
  let a = base.sensitivity_analysis()
  let b = other.sensitivity_analysis()
  // The perturbation is real to the subset itself...
  assert_true(corrupted > 0)
  // ... and invisible to the sensitivity elements, because those rows are not
  // in the subset. This is the assertion the old code could not survive.
  assert_true(a.sigma2 == b.sigma2)
  assert_true(a.nu2 == b.nu2)
  assert_true(a.rv == b.rv)
  assert_true(a.max_bias == b.max_bias)
}

///|
/// GATE 2 -- the residual uses G, not the treatment column.
///
/// Same invariant as GATE 1 but on the variable axis: nothing in the
/// sensitivity path may read `data.d` (the per-period treatment), because
/// upstream reads `d = self._g_data_subset` (`did_cs_binary.py:847`) and every
/// other use of "d" in this estimator is G.
///
/// MEASURED: inverting the treatment column on all 1080 rows changes nothing.
test "v130_cs_binary_sensitivity_never_reads_the_treatment_column" {
  let data = v130_cs_data(120, 2, 5)
  let n_full = data.y.length()
  let d2 : Array[Double] = Array::make(n_full, 0.0)
  for i = 0; i < n_full; i = i + 1 {
    d2[i] = 1.0 - data.d[i]
  }
  let other = DoubleMLDIDCSData::new(
    data.x,
    data.y,
    d2,
    data.t,
    data.id,
    data.g,
  )
  let a = v130_fit(data).sensitivity_analysis()
  let b = v130_fit(other).sensitivity_analysis()
  assert_true(a.sigma2 == b.sigma2)
  assert_true(a.nu2 == b.nu2)
  assert_true(a.rv == b.rv)
  assert_true(a.max_bias == b.max_bias)
}

///|
/// GATE 3 -- the pinned output, and the 4-way cell mixture is load-bearing.
///
/// `sigma2 = mean((y - g_hat)^2)` with `g_hat` the cell mixture over
/// `(G, T_indicator)`. The old 2-way form always used the `T = 0` cell, i.e.
/// `E[y | G, T=0]`, even for `T = 1` rows -- and `T = 1` is the post-treatment
/// period. So the mixture is not a refactor; it is the fix.
///
/// MEASURED on the staggered fixture (720 subset rows):
///     sigma2   1.14726368007027   (old: full-panel rows at subset positions)
///               0.0019663436427471525  (new)   -> a factor of 583.5
///     rv       0.509088766725795 -> 12.296893946098622
///     max_bias 1.9465681983148717 -> 0.0805875050863701
///     nu2      3.30275229357797   -> unchanged, and it MUST be unchanged,
///               because `nu2 = mean(psi_a^2)` does not involve the residual.
///               If `nu2` ever moves here, `psi_a` changed, not the fix.
///
/// CROSS-CHECKED against the vendored upstream 0.11.4 fitted on this same
/// fixture: its own `sigma2` is 0.001944928671712235, within 1.1% of the port
/// (fold assignment differs, so equality is not expected) while the old
/// expression was 590x out. Recomputing upstream's formula literally on the
/// port's own inputs reproduces 0.0019663436427471525 bit for bit
/// (`_verify/_oracle_1300.py`).
test "v130_cs_binary_sensitivity_matches_the_upstream_cell_mixture" {
  let base = v130_fit(v130_cs_data(120, 2, 5))
  let r = base.sensitivity_analysis()
  assert_true(r.sigma2 == 0.0019663436427471525)
  assert_true(r.nu2 == 3.30275229357797)
  assert_true(r.rv == 12.296893946098622)
  assert_true(r.max_bias == 0.0805875050863701)
  // and the 2-way form it replaced is NOT the same number -- if these ever
  // agree, the mixture has stopped discriminating.
  let g00 = base.predictions_g_d0_t0()
  let g10 = base.predictions_g_d1_t0()
  let gsub = base.subset_g
  let ysub = base.subset_y
  let n = g00.length()
  let mut two_way = 0.0
  let mut four_way = 0.0
  for i = 0; i < n; i = i + 1 {
    let two = ysub[i] - g00[i] - (g10[i] - g00[i]) * gsub[i]
    let a00 = base.predictions_g_d0_t0()[i]
    let a01 = base.predictions_g_d0_t1()[i]
    let a10 = base.predictions_g_d1_t0()[i]
    let a11 = base.predictions_g_d1_t1()[i]
    let di = gsub[i]
    let ti = base.subset_t[i]
    let mix = (1.0 - di) * (1.0 - ti) * a00 +
      (1.0 - di) * ti * a01 +
      di * (1.0 - ti) * a10 +
      di * ti * a11
    let four = ysub[i] - mix
    two_way = two_way + two * two
    four_way = four_way + four * four
  }
  let n_d = n.to_double()
  let s2_two = two_way / n_d
  let s2_four = four_way / n_d
  // the reported sigma2 is the 4-way one ...
  assert_true(r.sigma2 == s2_four)
  // ... and the 2-way form is a different, much larger number
  assert_true(s2_two != s2_four)
  // MEASURED decomposition of the 583.5x total error, which separates the
  // two bugs this release fixed:
  //
  //   1.14726368007027      old: full-panel rows at subset positions,
  //                              the treatment column, and the 2-way form
  //   0.15150335799261383   fix the rows and the variable, keep the 2-way
  //                              form -> isolates the cell-mixture bug alone
  //   0.0019663436427471525 the fix: correct rows, correct variable, 4-way
  //
  // so the cell mixture alone is worth ~77x, and the wrong-rows/wrong-variable
  // bug the remaining ~7.6x. Neither was cosmetic.
  assert_true(s2_two == 0.15150335799261383)
  assert_true(s2_two > 70.0 * r.sigma2)
}

///|
/// GATE 4 -- the two entry points cannot drift apart again.
///
/// They used to duplicate the residual line, which is why the bug had to be
/// fixed twice by hand. Now both call the same builder, and this gate pins
/// the consequence: with all-distinct cluster ids the cluster helper's
/// per-observation centering collapses to the IID form, so the two results
/// must be bit-identical.
///
/// MEASURED: singleton clusters reproduce the IID `sigma2`, `nu2`, `rv` and
/// `max_bias` exactly. One big cluster does NOT, and is pinned separately --
/// `irm_style_sensitivity_cluster` then sums the raw residuals within the
/// cluster, so `sigma2 = n * mean(residual^2)` for a single cluster.
test "v130_cs_binary_sensitivity_cluster_shares_the_residual_vector" {
  let base = v130_fit(v130_cs_data(120, 2, 5))
  let iid = base.sensitivity_analysis()
  let n = base.n_obs()
  let singletons = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singletons[i] = i
  }
  let cl = base.sensitivity_analysis_cluster(singletons)
  assert_true(cl.sigma2 == iid.sigma2)
  assert_true(cl.nu2 == iid.nu2)
  assert_true(cl.rv == iid.rv)
  assert_true(cl.max_bias == iid.max_bias)
  // one cluster is a different computation, and it is pinned so a regression
  // in the cluster path cannot hide behind the IID gate
  let one_cluster = Array::make(n, 0)
  let c1 = base.sensitivity_analysis_cluster(one_cluster)
  assert_true(c1.sigma2 == 0.03206982758951298)
  assert_true(c1.sigma2 != iid.sigma2)
}

///|
/// GATE 5 -- the subset arrays the fix depends on are populated and aligned.
///
/// `cs_bin_sensitivity_residuals` requires all seven arrays to be the same
/// length; if `fit` ever stopped storing one of them the estimator would raise
/// rather than quietly mis-index. This gate pins the contract from the outside.
test "v130_cs_binary_subset_arrays_are_populated_and_aligned" {
  let unfitted = DoubleMLDIDCSBinary::new(
    v130_cs_data(120, 2, 5),
    1,
    0,
    2,
    n_folds=2,
    seed=3141,
  )
  assert_true(unfitted.subset_y.length() == 0)
  assert_true(unfitted.subset_g.length() == 0)
  assert_true(unfitted.subset_t.length() == 0)
  let base = unfitted.fit()
  let n = base.n_obs()
  assert_true(base.subset_y.length() == n)
  assert_true(base.subset_g.length() == n)
  assert_true(base.subset_t.length() == n)
  assert_true(base.psi_a.length() == n)
  assert_true(base.predictions_g_d0_t0().length() == n)
  assert_true(base.predictions_g_d0_t1().length() == n)
  assert_true(base.predictions_g_d1_t0().length() == n)
  assert_true(base.predictions_g_d1_t1().length() == n)
  // G and T_indicator are the subset's own 0/1 indicators
  let mut ones_g = 0
  let mut ones_t = 0
  for i = 0; i < n; i = i + 1 {
    assert_true(base.subset_g[i] == 0.0 || base.subset_g[i] == 1.0)
    assert_true(base.subset_t[i] == 0.0 || base.subset_t[i] == 1.0)
    if base.subset_g[i] == 1.0 {
      ones_g = ones_g + 1
    }
    if base.subset_t[i] == 1.0 {
      ones_t = ones_t + 1
    }
  }
  assert_true(ones_g == 218)
  assert_true(ones_t == 360)
  // the subset survived the rebuild, and the memoize toggles
  assert_true(base.enable_memoize().subset_y.length() == n)
  assert_true(base.disable_memoize().subset_y.length() == n)
}
