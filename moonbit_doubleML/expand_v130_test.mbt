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
  // sigma2 is what this gate is about and v0.131.0 did not touch it.
  // `nu2`, `rv` and `max_bias` were REPINNED by v0.131.0 when the `nu2`
  // convention was corrected; see `v131_...` below and the changelog.
  assert_true(r.sigma2 == 0.0019663436427471525)
  assert_true(r.nu2 == 26.718919562055802)
  assert_true(r.rv == 4.323385709026423)
  assert_true(r.max_bias == 0.22921295256141525)
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
  // `sigma2` is the real invariant: the cluster helper takes cluster sums of
  // the SQUARED residuals, which for singleton clusters collapses to
  // `mean(residuals^2)` -- the IID definition. Both entry points share one
  // residual builder, so this equality is the thing that proves it.
  assert_true(cl.sigma2 == iid.sigma2)
  // `nu2` is NOT equal to the IID value, and until v0.131.0 this gate asserted
  // that it was. It held only because both sides computed the same quantity.
  // The cluster helper's own convention is "cluster sums of the per-observation
  // scalar, squared", so with singleton clusters it is `mean(elem^2)` where the
  // IID path is `mean(elem)`. For the residuals the two coincide (the
  // per-observation scalar is `residuals[i]` and the IID path squares it too);
  // for `nu2` the per-observation scalar is already the nu2 SCORE ELEMENT, so
  // they legitimately differ. Upstream has no cluster sensitivity path at all,
  // so this is the port's own definition, now pinned rather than papered over.
  assert_true(cl.nu2 == 10491.077140831747)
  assert_true(cl.nu2 != iid.nu2)
  assert_true(cl.rv == 0.21818424578653337)
  assert_true(cl.max_bias == 4.5419228132415395)
  // one cluster is a different computation again, and it is pinned so a
  // regression in the cluster path cannot hide behind the IID gate
  let one_cluster = Array::make(n, 0)
  let c1 = base.sensitivity_analysis_cluster(one_cluster)
  assert_true(c1.sigma2 == 0.03206982758951298)
  assert_true(c1.nu2 == 370086103.4729745)
  assert_true(c1.sigma2 != iid.sigma2)
}

///|
/// GATE 6 (v0.131.0) -- the `nu2` CONVENTION, pinned from the outside.
///
/// v0.130.0 fixed the residual. It did not fix `nu2`, which was still
/// `mean(psi_a^2)` -- upstream's *fallback* formula (`double_ml.py:1634-1641`
/// uses it only when the primary `nu2 <= 0`), and applied to the wrong object
/// besides: upstream's primary is
///
///     nu2 = mean( 2 * m_alpha - rr^2 )      (did_cs_binary.py:932)
///
/// with `rr` the RIESZ REPRESENTER, while this port's `psi_a` is the score's
/// base element. Upstream keeps those apart on purpose: `_score_elements`
/// returns `psi_a`/`psi_b`, `_sensitivity_element_est` returns `riesz_rep`.
///
/// This gate recomputes `m_alpha` and `rr` from the PUBLIC accessors using
/// upstream's `in_sample_normalization = false` branch -- which is the branch
/// this estimator's default selects (`did_cs_binary.mbt:712`) -- and asserts
/// the reported `nu2` is exactly their mean.
///
/// MEASURED, staggered fixture (720 subset rows):
///     nu2       3.30275229357797    -> 26.718919562055802     (8.1x)
///     max_bias  0.0805875050863701  -> 0.22921295256141525
///     rv        12.296893946098622  -> 4.323385709026423
///
/// and against the vendored upstream 0.11.4 fitted on the same fixture with
/// the SAME flag, nu2 = 23.179137007778895 -- 15% away, versus 7x away before.
test "v131_cs_binary_nu2_is_upstreams_score_element_not_mean_psi_a_squared" {
  let base = v130_fit(v130_cs_data(120, 2, 5))
  let r = base.sensitivity_analysis()
  let d = base.subset_g
  let t = base.subset_t
  let m = base.predictions_m()
  let n = base.n_obs()
  let n_d = n.to_double()
  assert_true(d.length() == n)
  assert_true(t.length() == n)
  assert_true(m.length() == n)
  // Pass 1: the means upstream divides by.
  let mut sum_d = 0.0
  let mut sum_t = 0.0
  for i = 0; i < n; i = i + 1 {
    sum_d = sum_d + d[i]
    sum_t = sum_t + t[i]
  }
  let p_hat = sum_d / n_d
  let lambda_hat = sum_t / n_d
  assert_true(p_hat == 0.30277777777777776)
  assert_true(lambda_hat == 0.5)
  // Pass 2: the in_sample_normalization = false branch
  // (did_cs_binary.py:896-902).
  let m_alpha_1 = 1.0 / lambda_hat + 1.0 / (1.0 - lambda_hat)
  let mut sum_elem = 0.0
  let mut sum_elem_sq = 0.0
  let mut sum_psi_a_sq = 0.0
  for i = 0; i < n; i = i + 1 {
    let di = d[i]
    let ti = t[i]
    let one_minus_m = 1.0 - m[i]
    let pw = if one_minus_m > 1.0e-12 { m[i] / one_minus_m } else { 0.0 }
    let m_alpha = di / (p_hat * p_hat) * (m_alpha_1 * (1.0 + pw))
    let rr_1 = ti / (p_hat * lambda_hat) +
      (1.0 - ti) / (p_hat * (1.0 - lambda_hat))
    let rr = rr_1 * (di + (1.0 - di) * pw)
    let elem = 2.0 * m_alpha - rr * rr
    sum_elem = sum_elem + elem
    sum_elem_sq = sum_elem_sq + elem * elem
    sum_psi_a_sq = sum_psi_a_sq + base.psi_a[i] * base.psi_a[i]
  }
  let nu2_expected = sum_elem / n_d
  assert_true(r.nu2 == nu2_expected)
  assert_true(r.nu2 == 26.718919562055802)
  // ... and it is emphatically NOT either of the two things it replaced:
  // not `mean(psi_a^2)` (upstream's fallback, applied to the wrong object),
  // not `mean(elem^2)` (the cluster path's convention).
  assert_true(r.nu2 != sum_psi_a_sq / n_d)
  assert_true(r.nu2 != sum_elem_sq / n_d)
  assert_true(sum_psi_a_sq / n_d == 3.30275229357797)
  // the reported robustness value follows from sigma2 and nu2 alone:
  // rv = |theta| / sqrt(sigma2 * nu2).
  //
  // NOT bit-equal, and the reason is worth writing down: the helper
  // broadcasts the scalar to a length-n array and then averages it
  // (`mb_sum / n`), and summing n copies of a scalar back up is not exactly
  // that scalar in IEEE754. MEASURED relative difference here: 6e-15. The
  // first version of this gate asserted bit equality and failed -- correctly.
  let max_bias_from_parts = (r.sigma2 * r.nu2).sqrt()
  let rel_bias = (r.max_bias - max_bias_from_parts).abs() / max_bias_from_parts
  assert_true(rel_bias < 1.0e-12)
  let rv_from_parts = base.coef().abs() / max_bias_from_parts
  let rel_rv = (rv_from_parts - r.rv).abs() / r.rv
  assert_true(rel_rv < 1.0e-12)
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
