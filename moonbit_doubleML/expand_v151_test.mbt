// expand_v151_test.mbt
//
// v0.151.0 -- the `alpha_i` unit-intercept ramp in `make_did_CS2021`, the one
// v0.148.0 missed.
//
// v0.148.0 removed `alpha_i = 0.5 * unit_in_cohort` from `make_did_cs_CS2021`
// and did NOT apply the fix to the 4-cohort sibling `make_did_CS2021`. Measured
// on make_did_CS2021(1600, 3, 1.0, 3141) BEFORE this release:
//
//   var(y)                                    206.75   (SD 14.38)
//   corr(id, y)                                0.975
//   r^2 X_0 / X_1 / X_2 vs y       1.0e-5 / 2.6e-3 / 9.2e-3
//   share of var(y) that is time-invariant     99.65 %
//   var(within unit)                            1.11
//
// `0.25 * var(0..99) = 208.3` against a total of 206.75: the ramp WAS the
// variance. Covariates carried under 1% of it, so E[Y|D,T,X] held essentially
// no covariate signal -- exactly the condition v0.148.0 called out as making
// the did_cs sensitivity migration untestable.
//
// AFTER: var(y) 11.06, corr(id,y) -0.108, r^2 0.423 / 0.647 / 0.560.
//
// `var(within unit)` is BIT-IDENTICAL across the change (1.1087561532787724 ->
// 1.1087561532787722), which is the evidence that the fix touched only the unit
// intercept: the new draw is taken AFTER the noise stream, so X and eps are
// unchanged and the r^2 columns moved only through alpha's own contribution.
//
// A per-unit N(0,1) draw rather than deleting the term: unobserved unit
// heterogeneity IS the hidden confounding `nu2` prices, so removing it outright
// would leave the fixture unable to represent what it is for.
//
// NOTE ON WHAT THESE GATES CAN AND CANNOT SEE. For v0.146.0-v0.150.0 a gate
// reading the FIXTURE was declared non-discriminating, because the fixture did
// not change and only code did. That reasoning INVERTS here: this release
// changes the DGP, so the fixture IS the thing under test and a fixture-derived
// gate discriminates properly. GATE 5 below still guards the boundary -- it
// asserts the treatment structure did NOT move, which is what would make the
// r^2 improvement meaningless (e.g. if the ramp were "fixed" by shrinking theta).

///|
fn v1510_dot(a : Array[Double], b : Array[Double]) -> Double {
  let mut s = 0.0
  for i = 0; i < a.length(); i = i + 1 {
    s = s + a[i] * b[i]
  }
  s
}

///|
fn v1510_center(a : Array[Double]) -> Array[Double] {
  let m = v1510_mean(a)
  let out = Array::make(a.length(), 0.0)
  for i = 0; i < a.length(); i = i + 1 {
    out[i] = a[i] - m
  }
  out
}

///|
/// Residual of `y` after projecting it onto `cols` (modified Gram-Schmidt).
///
/// WHY THIS EXISTS, and it is a correction rather than an addition: the first
/// four gates all read either `corr(id, y)` or a variance band, and the mutation
/// run showed they cannot see the unit intercept being REMOVED. M1
/// (`alpha_i = 0.0`) and M4 (`alpha * 0.15`) both SURVIVED all four. The reason
/// is that X is itself UNIT-LEVEL and time-invariant in this DGP, so it supplies
/// the time-invariant share and the variance floor on its own -- the
/// heterogeneity is masked by the very thing the gates were reading instead.
///
/// What X cannot supply is the part of the outcome that is INDEPENDENT of it.
/// `alpha` is drawn separately from X, so projecting X out of the unit-level
/// outcome leaves `alpha` (plus `eps` averaged over 4 periods, var 0.25) behind.
/// Deleting or shrinking alpha collapses that residual to ~0; coarsening it to
/// one value per cohort leaves it intact in total but constant WITHIN a cohort.
///
/// This is the gate that should have existed from the start: GATE 4's presence
/// check was written by reasoning and had never failed, which is exactly the
/// condition under which a gate proves nothing.
fn v1510_resid_after(
  y : Array[Double],
  cols : Array[Array[Double]],
) -> Array[Double] {
  let n = y.length()
  let r = v1510_center(y)
  let k = cols.length()
  let basis : Array[Array[Double]] = []
  let mut basis_acc = basis
  // `nb` is basis_acc.length(). A degenerate column is SKIPPED rather than
  // appended, so nb can lag `j` -- indexing basis_acc[j] would then run off the
  // end, which is exactly the out-of-bounds this loop first shipped with.
  let mut nb = 0
  for j = 0; j < k; j = j + 1 {
    let v_acc = v1510_center(cols[j])
    // Orthogonalise against everything already built.
    for b in 0..<nb {
      let d = v1510_dot(v_acc, basis_acc[b])
      for i = 0; i < n; i = i + 1 {
        v_acc[i] = v_acc[i] - d * basis_acc[b][i]
      }
    }
    let nv = v1510_dot(v_acc, v_acc).sqrt()
    if nv > 1.0e-12 {
      let unit = v_acc
      for i = 0; i < n; i = i + 1 {
        unit[i] = unit[i] / nv
      }
      basis_acc = basis_acc + [unit]
      let d = v1510_dot(r, basis_acc[nb])
      for i = 0; i < n; i = i + 1 {
        r[i] = r[i] - d * basis_acc[nb][i]
      }
      nb = nb + 1
    }
  }
  r
}

///|
/// GATE 6. THE UNIT INTERCEPT IS PRESENT, measured on the only quantity that can
/// see it: the part of the unit-level outcome that X does NOT explain.
///
/// Written after the mutation run showed GATE 4 blind. Measured on
/// `make_did_CS2021(1600, 3, 1.0, 3141)`: residual variance ~1.25, which is
/// `var(alpha) = 1` plus `var(eps)/4 = 0.25` as predicted.
///
/// Kills M1 (`alpha_i = 0.0` -> residual ~0) and M4 (`alpha * 0.15` -> residual
/// ~0.02). Both SURVIVED all four earlier gates.
test "v1510_unit_intercept_survives_projection_on_x" {
  let d = make_did_CS2021(1600, 3, 1.0, 3141)
  let y = d.y_get()
  let x = d.x_get()
  let n_units = y.length() / 4
  let unit_means : Array[Double] = Array::make(n_units, 0.0)
  let cols : Array[Array[Double]] = []
  let mut cols_acc = cols
  for j = 0; j < 3; j = j + 1 {
    let col = Array::make(n_units, 0.0)
    for u = 0; u < n_units; u = u + 1 {
      col[u] = x.get(u * 4, j)
    }
    cols_acc = cols_acc + [col]
  }
  for u = 0; u < n_units; u = u + 1 {
    let mut s = 0.0
    for k = 0; k < 4; k = k + 1 {
      s = s + y[u * 4 + k]
    }
    unit_means[u] = s / 4.0
  }
  let r = v1510_resid_after(unit_means, cols_acc)
  let v = v1510_var(r)
  println(
    "[v1510] residual variance of unit means after removing X = " +
    v.to_string(),
  )
  assert_true(v > 0.5 && v < 3.0)
}

///|
/// GATE 7. The intercept is per-UNIT, not per-cohort.
///
/// GATE 6 cannot see M5 (`alpha[u / 100]`, one intercept per cohort): the total
/// heterogeneity is unchanged, so the residual variance is still ~1.25. What
/// changes is that all 100 units of a cohort share ONE value, so the residual is
/// constant WITHIN a cohort. Two independent units of the same cohort therefore
/// have equal intercepts under M5 and differ by ~sqrt(2) under the real DGP.
///
/// CHECKED AS A RATIO, not an absolute threshold, and the first attempt at this
/// gate SURVIVED M5. It asserted `within_cohort_var > 0.2` on the reasoning that
/// a constant-per-cohort intercept would drive it to zero. It does not: the
/// residual also carries `eps` averaged over 4 periods (var 0.25) plus whatever
/// the X projection leaves, so its floor is ~0.27 -- comfortably above 0.2, and
/// the mutant walked straight through.
///
/// The scale-free statement is the real one: under a PER-UNIT intercept the
/// within-cohort spread is the SAME as the overall spread, because units within a
/// cohort are exchangeable. Under a per-cohort intercept the within-cohort part
/// collapses while the overall part does not. Measured: ratio 1.009 / 1.279 =
/// 0.79 on the real DGP, against ~0.27 / 1.279 = 0.21 under M5.
test "v1510_unit_intercept_varies_within_a_cohort" {
  let d = make_did_CS2021(1600, 3, 1.0, 3141)
  let y = d.y_get()
  let x = d.x_get()
  let g = d.g_get()
  let n_units = y.length() / 4
  let unit_means : Array[Double] = Array::make(n_units, 0.0)
  let cols : Array[Array[Double]] = []
  let mut cols_acc = cols
  for j = 0; j < 3; j = j + 1 {
    let col = Array::make(n_units, 0.0)
    for u = 0; u < n_units; u = u + 1 {
      col[u] = x.get(u * 4, j)
    }
    cols_acc = cols_acc + [col]
  }
  for u = 0; u < n_units; u = u + 1 {
    let mut s = 0.0
    for k = 0; k < 4; k = k + 1 {
      s = s + y[u * 4 + k]
    }
    unit_means[u] = s / 4.0
  }
  let r = v1510_resid_after(unit_means, cols_acc)
  // Take cohort 1 (treated), whose units are indices 100..200.
  let within : Array[Double] = []
  let mut within_acc = within
  for u = 100; u < 200; u = u + 1 {
    if g[u * 4] == 1 {
      within_acc = within_acc + [r[u]]
    }
  }
  assert_true(within_acc.length() == 100)
  let v = v1510_var(within_acc)
  let overall = v1510_var(r)
  let ratio = v / overall
  println(
    "[v1510] within-cohort residual variance (cohort 1) = " +
    v.to_string() +
    "  overall = " +
    overall.to_string() +
    "  ratio = " +
    ratio.to_string(),
  )
  assert_true(ratio > 0.5)
}

///|
fn v1510_mean(a : Array[Double]) -> Double {
  let n = a.length().to_double()
  let mut s = 0.0
  for i = 0; i < a.length(); i = i + 1 {
    s = s + a[i]
  }
  s / n
}

///|
fn v1510_var(a : Array[Double]) -> Double {
  let n = a.length().to_double()
  let m = v1510_mean(a)
  let mut ss = 0.0
  for i = 0; i < a.length(); i = i + 1 {
    let d = a[i] - m
    ss = ss + d * d
  }
  ss / (n - 1.0)
}

///|
fn v1510_corr(a : Array[Double], b : Array[Double]) -> Double {
  let ma = v1510_mean(a)
  let mb = v1510_mean(b)
  let mut sab = 0.0
  let mut saa = 0.0
  let mut sbb = 0.0
  for i = 0; i < a.length(); i = i + 1 {
    let da = a[i] - ma
    let db = b[i] - mb
    sab = sab + da * db
    saa = saa + da * da
    sbb = sbb + db * db
  }
  sab / (saa * sbb).sqrt()
}

///|
/// GATE 0 (self-check on the measuring instrument). Every correlation gate below
/// is worthless if `v1510_corr` is itself broken -- a routine returning 0 would
/// make "corr is small" pass no matter what. Assert it on a variable against
/// ITSELF first: that must be 1.0 to the last digit.
test "v1510_correlation_helper_is_sane" {
  let d = make_did_CS2021(1600, 3, 1.0, 3141)
  let id_raw = d.id_get()
  let n = id_raw.length()
  let id : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    id[i] = id_raw[i].to_double()
  }
  let r = v1510_corr(id, id)
  assert_true(r > 0.999999 && r <= 1.0 + 1.0e-12)
}

///|
/// GATE 1. The covariates carry real signal. This is the property the whole
/// release exists to restore: before it, every X column explained under 1% of
/// the outcome. Measured after: 0.423 / 0.647 / 0.560.
test "v1510_covariates_explain_the_outcome" {
  let d = make_did_CS2021(1600, 3, 1.0, 3141)
  let y = d.y_get()
  let x = d.x_get()
  let n = y.length()
  for j = 0; j < 3; j = j + 1 {
    let col : Array[Double] = Array::make(n, 0.0)
    let col_acc = col
    for i = 0; i < n; i = i + 1 {
      col_acc[i] = x.get(i, j)
    }
    let r = v1510_corr(col_acc, y)
    let r2 = r * r
    assert_true(r2 > 0.35)
  }
}

///|
/// GATE 2. Unit identity no longer determines the outcome. Measured
/// `corr(id, y)`: 0.975 before, -0.108 after. The ramp made y almost a function
/// of a unit's position in its cohort.
test "v1510_unit_id_does_not_determine_the_outcome" {
  let d = make_did_CS2021(1600, 3, 1.0, 3141)
  let y = d.y_get()
  let id_raw = d.id_get()
  let n = y.length()
  let id : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    id[i] = id_raw[i].to_double()
  }
  let r = v1510_corr(id, y)
  assert_true(r.abs() < 0.25)
}

///|
/// GATE 3. THE RAMP'S ABSENCE, stated on the quantity the ramp actually keyed
/// on. `id` IS `unit_in_cohort`, so under the ramp the unit-level mean of `y`
/// would be monotone in `id`; measured, that correlation was 0.975. Now the
/// unit intercepts are an independent draw and the correlation is noise.
///
/// This is a different statement from GATE 2: GATE 2 mixes the ramp's level
/// into a panel-level correlation, GATE 3 looks at the time-invariant component
/// directly, which is exactly what `alpha_i` was.
test "v1510_unit_intercepts_are_not_a_ramp_in_position" {
  let d = make_did_CS2021(1600, 3, 1.0, 3141)
  let y = d.y_get()
  let id_raw = d.id_get()
  let n = y.length()
  let n_units = n / 4
  let unit_means : Array[Double] = Array::make(n_units, 0.0)
  let unit_id0 : Array[Double] = Array::make(n_units, 0.0)
  for u = 0; u < n_units; u = u + 1 {
    let mut s = 0.0
    for k = 0; k < 4; k = k + 1 {
      s = s + y[u * 4 + k]
    }
    unit_means[u] = s / 4.0
    // First period's id is the unit's position within its cohort.
    unit_id0[u] = id_raw[u * 4].to_double()
  }
  let r = v1510_corr(unit_id0, unit_means)
  assert_true(r.abs() < 0.25)
}

///|
/// GATE 4. The outcome scale itself. `var(y)` was 206.75 because the ramp ran
/// to 49.5; after, it is 11.06 with `mean(y)` 0.68. The floor matters as much as
/// the ceiling: a "fix" that deleted the unit intercept outright would collapse
/// `var(y)` toward the within-unit 1.11, which this gate also rejects.
test "v1510_outcome_scale_is_a_minority_not_a_majority" {
  let d = make_did_CS2021(1600, 3, 1.0, 3141)
  let y = d.y_get()
  let var_y = v1510_var(y)
  assert_true(var_y > 5.0 && var_y < 30.0)
  // And the unit intercept is still PRESENT, not deleted: the time-invariant
  // share must remain substantial, because unobserved unit heterogeneity is the
  // hidden confounding `nu2` prices.
  let n_units = y.length() / 4
  let unit_means : Array[Double] = Array::make(n_units, 0.0)
  for u = 0; u < n_units; u = u + 1 {
    let mut s = 0.0
    for k = 0; k < 4; k = k + 1 {
      s = s + y[u * 4 + k]
    }
    unit_means[u] = s / 4.0
  }
  let share = v1510_var(unit_means) / var_y
  assert_true(share > 0.5)
}

///|
/// GATE 5. The fix touched `y` AND NOTHING ELSE. Without it, the r^2 improvement
/// above would not mean "covariates now carry signal" -- it could equally mean
/// the treatment effect had been shrunk. Treatment status, cohort sizes and
/// theta are all pinned to what they were before this release.
///
/// Occupancy is the (g, t) row count and the number treated, exactly as
/// `expand_v148_test.mbt` GATE 5 pins for the sibling DGP.
test "v1510_fix_touched_y_and_nothing_else" {
  let d = make_did_CS2021(1600, 3, 1.0, 3141)
  assert_true(d.theta_get() == 1.0)
  assert_true(d.n_groups_get() == 4)
  assert_true(d.n_periods_get() == 4)
  assert_true(d.y_get().length() == 1600)
  // tau_g = g - 1, so cohort 0 is never treated and cohort 1 is treated at t=0.
  let y_len = d.y_get().length()
  let d_arr = d.d_get()
  let g_arr = d.g_get()
  let t_arr = d.t_get()
  // Per (cohort, period): rows, treated.
  for cohort = 0; cohort < 4; cohort = cohort + 1 {
    for period = 0; period < 4; period = period + 1 {
      let mut rows = 0
      let mut treated = 0
      for i = 0; i < y_len; i = i + 1 {
        if g_arr[i] == cohort && t_arr[i] == period {
          rows = rows + 1
          if d_arr[i] > 0.5 {
            treated = treated + 1
          }
        }
      }
      assert_true(rows == 100)
      // tau_g = cohort - 1 for cohort >= 1; cohort 0 never treated.
      let expected = if cohort == 0 {
        0
      } else if period >= cohort - 1 {
        100
      } else {
        0
      }
      assert_true(treated == expected)
    }
  }
}
