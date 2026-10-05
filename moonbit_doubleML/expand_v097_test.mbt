///|
/// v0.97.0: the BLP HAC sandwich (`hac_se` / `cluster_hac_se`).
///
/// Structural template: `expand_v096_test.mbt` (RDD's v0.96.0
/// `hac_se`). The algebra differs -- BLP is a projection of `p1`
/// coefficients, not a scalar discontinuity contrast -- so the
/// assertions are elementwise over a length-`p1` vector throughout,
/// and the DGP carries two basis columns so a scalar bug and a vector
/// bug are distinguishable (with `p1 == 1` they are not).
///
/// The numbers pinned in test 7 and reported in the comments below
/// were MEASURED on v0.96.0 (commit a24ab06), before any source
/// change to `blp_policy.mbt`.

///|
/// The v0.97.0 DGP. `n = 400`, TWO basis columns, so `p1 =
/// basis.cols() + 1 = 3` coefficients and the vector shape is
/// exercised.
///
/// `x0` runs linearly over `(-1, 1)`; `z1` is a deterministic
/// sawtooth (`(7 i) mod 23`) and `eps` a second one with a different
/// period (`(11 i) mod 29`), so there is no RNG and every number below
/// is reproducible on every backend. The noise is
/// `(0.4 + 0.9 |x0|) * eps` -- HETEROSKEDASTIC, growing toward the
/// ends of `x0` -- so the homoskedastic and HC0 standard errors
/// genuinely differ and a `hac_se` that silently returned the
/// homoskedastic number would be caught.
fn v097_dgp(n : Int) -> (Matrix, Array[Double]) {
  let p_basis = 2
  let basis = Matrix::zeros(n, p_basis)
  let orth = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let half = (n.to_double() - 1.0) / 2.0
    let x0 = (i.to_double() - half) / half
    let z1 = (i * 7 % 23).to_double() / 23.0 - 0.5
    let eps = (i * 11 % 29).to_double() / 29.0 - 0.5
    basis.set(i, 0, x0)
    basis.set(i, 1, 1.5 * z1)
    orth[i] = 1.5 + 0.8 * x0 - 0.6 * z1 + (0.4 + 0.9 * x0.abs()) * eps
  }
  (basis, orth)
}

///|
/// The DEGENERATE basis: two ZERO columns. The augmented design is
/// `X = [1, 0, 0]`, so `X'X + ridge I` is `diag(n + ridge, ridge,
/// ridge)` and EVERY row carries the same leverage
/// `h = 1 / (n + ridge)` -- an exactly known value, which is what lets
/// test 5 state the `HC2 / HC0` and `HC3 / HC0` ratios in closed form.
fn v097_dgp_constant_leverage(n : Int) -> (Matrix, Array[Double]) {
  let basis = Matrix::zeros(n, 2)
  let orth = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    orth[i] = (i * 11 % 29).to_double() / 29.0 - 0.5
  }
  (basis, orth)
}

///|
/// Test-side INDEPENDENT reference for the BLP sandwich. Every
/// quantity is computed by the route the implementation does NOT
/// use:
///
///   - the residuals come from `beta = inv_spd(...) @ (X' y)`, a full
///     inverse times a matrix-vector, where `LinearRegression::fit`
///     uses one `solve_spd` back-solve;
///   - the meat's `M[j, :]` rows are read off that full inverse,
///     where `LinearRegression::sandwich_se` back-solves
///     `M[j, :] (X'X + ridge I) = e_j` per coefficient;
///   - the leverage is `h_i = xa_i . z_i` from a per-ROW back-solve
///     `(X'X + ridge I) z_i = xa_i`, where the implementation forms
///     the full inverse once and walks the double loop
///     `xa_i' M xa_i`.
///
/// The design `X` is built here by hand (column 0 is ones) rather
/// than by calling `augment_with_intercept`, and `ridge = 1e-10` is
/// the `LinearRegression::new()` default `fit` and
/// `sandwich_se` both use.
fn v097_reference(
  basis : Matrix,
  orth : Array[Double],
) -> (Array[Double], Matrix, Array[Double]) {
  let n = basis.rows()
  let p_basis = basis.cols()
  let p1 = p_basis + 1
  // Hand-built augmented design, row-major.
  let xa = Matrix::zeros(n, p1)
  for i = 0; i < n; i = i + 1 {
    xa.set(i, 0, 1.0)
    for j = 0; j < p_basis; j = j + 1 {
      xa.set(i, j + 1, basis.get(i, j))
    }
  }
  // X'X and X'X + ridge I, accumulated row-major.
  let xtx = Matrix::zeros(p1, p1)
  for a = 0; a < p1; a = a + 1 {
    for b = 0; b < p1; b = b + 1 {
      let mut acc = 0.0
      for i = 0; i < n; i = i + 1 {
        acc = acc + xa.get(i, a) * xa.get(i, b)
      }
      xtx.set(a, b, acc)
    }
  }
  let m = inv_spd(add_ridge(xtx, 1.0e-10))
  let xtx_aug = add_ridge(xtx, 1.0e-10)
  // beta = M (X' y), the full-inverse route.
  let xty = Array::make(p1, 0.0)
  for a = 0; a < p1; a = a + 1 {
    let mut acc = 0.0
    for i = 0; i < n; i = i + 1 {
      acc = acc + xa.get(i, a) * orth[i]
    }
    xty[a] = acc
  }
  let beta = matvec(m, xty)
  // Residuals.
  let resid = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let mut acc = 0.0
    for a = 0; a < p1; a = a + 1 {
      acc = acc + xa.get(i, a) * beta[a]
    }
    resid[i] = orth[i] - acc
  }
  // Leverage by per-row back-solve, NOT by the full inverse.
  let hat = Array::make(n, 0.0)
  let xi = Array::make(p1, 0.0)
  for i = 0; i < n; i = i + 1 {
    for a = 0; a < p1; a = a + 1 {
      xi[a] = xa.get(i, a)
    }
    let z = solve_spd(xtx_aug, xi)
    let mut acc = 0.0
    for a = 0; a < p1; a = a + 1 {
      acc = acc + xa.get(i, a) * z[a]
    }
    hat[i] = acc
  }
  (resid, m, hat)
}

///|
/// Entry `a` of the hand-augmented row `i` of `basis`: `a == 0` is
/// the intercept column `LinearRegression::fit` adds, `a >= 1` is
/// `basis.get(i, a - 1)`.
fn v097_xa(basis : Matrix, i : Int, a : Int) -> Double {
  if a == 0 {
    1.0
  } else {
    basis.get(i, a - 1)
  }
}

///|
/// Test-side independent per-coefficient sandwich SE, reading
/// coefficient `j`'s row off the full inverse. `pow` selects the
/// variant: 0 is HC0 / HC1 (no leverage division at all, not even a
/// division by 1.0), 1 is HC2 and 2 is HC3.
fn v097_hc_se(
  m : Matrix,
  basis : Matrix,
  resid : Array[Double],
  hat : Array[Double],
  j : Int,
  pow : Int,
) -> Double {
  let n = resid.length()
  let p1 = m.cols()
  let mut acc = 0.0
  for i = 0; i < n; i = i + 1 {
    let mut mjx = 0.0
    for a = 0; a < p1; a = a + 1 {
      mjx = mjx + m.get(j, a) * v097_xa(basis, i, a)
    }
    let ei = resid[i]
    let base = mjx * mjx * ei * ei
    let term = if pow == 0 {
      base
    } else {
      let one_minus_h = 1.0 - hat[i]
      if pow == 1 {
        base / one_minus_h
      } else {
        base / (one_minus_h * one_minus_h)
      }
    }
    acc = acc + term
  }
  acc.sqrt()
}

///|
/// HC0 convenience wrapper.
fn v097_hc0_se(
  m : Matrix,
  basis : Matrix,
  resid : Array[Double],
  j : Int,
) -> Double {
  v097_hc_se(m, basis, resid, [], j, 0)
}

///|
/// Relative difference, `(a - b) / ((|a| + |b|) / 2)`. Same shape as
/// `v096_rel_diff`, redefined here so the v0.97.0 file stands on its
/// own.
fn v097_rel_diff(a : Double, b : Double) -> Double {
  let scale = (a.abs() + b.abs()) / 2.0
  if scale == 0.0 {
    0.0
  } else {
    (a - b).abs() / scale
  }
}

// ---------------------------------------------------------------------------
// 1. THE ANCHOR
// ---------------------------------------------------------------------------

///|
/// The invariant that proves the wiring: on a `cov_type = "HC0"`
/// fit, `se` IS the HC0 standard error, so `hac_se(HC0) == se` must
/// hold BIT-IDENTICALLY, ELEMENTWISE. `==` on `Double` is exact
/// equality, not a tolerance -- this test would fail on a last-ulp
/// difference, which is the point.
///
/// The comparison is ELEMENTWISE over the length-`p1` vector, and the
/// DGP has `p1 = 3 > 1`, so a scalar implementation that returned
/// one number would not pass.
///
/// The second half checks the same number against `v097_reference`,
/// which uses a different solver route for every ingredient.
test "blp_hac_se_hc0_equals_se_on_hc0_path" {
  let n = 400
  let (basis, orth) = v097_dgp(n)
  let f = DoubleMLBLP::new(basis, orth, cov_type="HC0").fit()
  // Precondition of the test itself: the shape is a VECTOR.
  inspect(f.basis().cols() == 2, content="true")
  inspect(f.n_params() == 3, content="true")
  inspect(f.coef().length() == 3, content="true")
  inspect(f.se().length() == 3, content="true")
  let se = f.se()
  let hac = f.hac_se(SandwichKind::hc0())
  inspect(hac.length() == 3, content="true")
  // The anchor, exact, per coefficient.
  for j = 0; j < se.length(); j = j + 1 {
    inspect(hac[j] == se[j], content="true")
  }
  // Not a coincidence of a degenerate zero, and the three SEs are
  // genuinely different numbers (a single echoed value would fail).
  inspect(se[0] > 0.01 && se[0] < 0.02, content="true")
  inspect(v097_rel_diff(se[0], se[1]) > 0.5, content="true")
  inspect(v097_rel_diff(se[1], se[2]) > 0.01, content="true")
  // And it agrees with the independent recomputation.
  let (resid, m, hat) = v097_reference(basis, orth)
  inspect(resid.length() == n, content="true")
  inspect(m.rows() == 3, content="true")
  inspect(hat.length() == n, content="true")
  for j = 0; j < 3; j = j + 1 {
    let expect = v097_hc0_se(m, basis, resid, j)
    inspect(v097_rel_diff(se[j], expect) < 1.0e-12, content="true")
  }
}

// ---------------------------------------------------------------------------
// 2. THE ANCHOR DOES NOT HOLD ON THE NONROBUST PATH
// ---------------------------------------------------------------------------

///|
/// Without this test the anchor above would be ambiguous: it would
/// also pass if `hac_se` were simply echoing `se` back. On a
/// `cov_type = "nonrobust"` fit `se` is the homoskedastic
/// `sqrt(sigma^2 (X'X)^-1_jj)`, so `hac_se(HC0) != se` -- by a
/// factor of 0.75 on coefficient 1, which is far too large to be a
/// rounding difference.
///
/// The last two assertions are the sharpest form of the point:
/// `hac_se` is a property of the DATA, not of `cov_type`, so two
/// independently fitted models must report the SAME HC0 sandwich
/// (bit-identically), while their `se` values differ. The point
/// estimate is shared because `cov_type` only selects a variance.
test "blp_hac_se_hc0_differs_from_se_on_nonrobust_path" {
  let n = 400
  let (basis, orth) = v097_dgp(n)
  let nonrobust = DoubleMLBLP::new(basis, orth, cov_type="nonrobust").fit()
  let hc0 = DoubleMLBLP::new(basis, orth, cov_type="HC0").fit()
  // The anchor must NOT hold on the homoskedastic path.
  for j = 0; j < 3; j = j + 1 {
    inspect(
      nonrobust.hac_se(SandwichKind::hc0())[j] != nonrobust.se()[j],
      content="true",
    )
  }
  // By a factor, not by rounding: the heteroskedastic noise grows
  // toward the ends of `x0`, so the HC0 SE must exceed the
  // homoskedastic one on the slope coefficients.
  inspect(
    nonrobust.hac_se(SandwichKind::hc0())[1] > nonrobust.se()[1] * 1.2,
    content="true",
  )
  // `hac_se` depends only on the data, so it is bit-identical across
  // the two `cov_type` settings ...
  for j = 0; j < 3; j = j + 1 {
    inspect(
      nonrobust.hac_se(SandwichKind::hc0())[j] ==
      hc0.hac_se(SandwichKind::hc0())[j],
      content="true",
    )
  }
  // ... while `se` and the leverage are not. (`leverage` is data-only
  // too, so it must also agree; `se` is where `cov_type` bites.)
  inspect(nonrobust.se() != hc0.se(), content="true")
  for j = 0; j < 3; j = j + 1 {
    inspect(nonrobust.leverage()[j] == hc0.leverage()[j], content="true")
  }
}

// ---------------------------------------------------------------------------
// 3. HC1: THE FINITE-SAMPLE CORRECTION
// ---------------------------------------------------------------------------

///|
/// HC1 must be the HC0 variance with the sum scaled by
/// `n / (n - k)`, with `k = n_params()` READ FROM THE CODE. Note
/// `k` is `basis.cols() + 1`, NOT `basis.cols()`: the projection
/// estimates the intercept too. The test pins both numbers
/// explicitly so the distinction cannot be lost, and computes the
/// expected value from `v097_reference` rather than from `hac_se`.
///
/// The SE ratio is therefore `sqrt(n / (n - k)) =
/// sqrt(400 / 397) = 1.0037723...`, which is 0.38% -- small, but
/// assertable to 1e-12 relative, and a pooled-vs-per-coefficient
/// error in the `k` would show up as a different ratio.
test "blp_hac_se_hc1_ratio" {
  let n = 400
  let (basis, orth) = v097_dgp(n)
  let f = DoubleMLBLP::new(basis, orth, cov_type="HC0").fit()
  // `k` is the intercept-augmented parameter count, and it is one
  // more than the basis width. Both are pinned: an implementation
  // that used `basis.cols()` here would be wrong.
  let k = f.n_params()
  inspect(basis.cols() == 2, content="true")
  inspect(k == 3, content="true")
  inspect(k == f.coef().length(), content="true")
  let n_d = n.to_double()
  let k_d = k.to_double()
  let scale = n_d / (n_d - k_d)
  inspect(k_d == 3.0, content="true")
  let expect_ratio = scale.sqrt()
  let hac0 = f.hac_se(SandwichKind::hc0())
  let hac1 = f.hac_se(SandwichKind::hc1())
  for j = 0; j < k; j = j + 1 {
    // Elementwise: every coefficient gets the SAME correction.
    inspect(
      v097_rel_diff(hac1[j] / hac0[j], expect_ratio) < 1.0e-12,
      content="true",
    )
    // HC1 strictly widens.
    inspect(hac1[j] > hac0[j], content="true")
  }
  // And against the independent reference, which also confirms the
  // correction is applied to the VARIANCE (so the SE ratio is its
  // square root) and not to the SE directly.
  let (resid, m, _hat) = v097_reference(basis, orth)
  for j = 0; j < k; j = j + 1 {
    let expect = v097_hc0_se(m, basis, resid, j) * expect_ratio
    inspect(v097_rel_diff(hac1[j], expect) < 1.0e-12, content="true")
  }
}

// ---------------------------------------------------------------------------
// 4. THE LEVERAGE: TRACE == RANK, AND `[0, 1)`
// ---------------------------------------------------------------------------

///|
/// The independent check on the leverage HC2 / HC3 divide by: the
/// trace of a hat matrix is its RANK, so `sum_i h_i` must equal the
/// rank of the augmented design, which is `n_params() = 3` for a
/// full-rank `basis`.
///
/// MEASURED, and written down rather than hidden: on the v0.97.0 DGP
/// (`n = 400`, `p1 = 3`) `leverage()` sums to
/// `2.999999999997666`, i.e. LOW by `2.334e-12` (relative
/// `7.8e-13`) against rank 3. The shortfall is the `1e-10` ridge:
/// `X^a (X'X + ridge I)^-1 X^{a'}` is a projection MINUS a
/// rank-`p1` correction, so its trace is the rank less
/// `ridge * trace((X'X + ridge I)^-2)`. This is the same effect the
/// v0.96.0 RDD worker measured (`5.999999999787386` against rank 6,
/// low by `2.1e-10`); BLP's design is better conditioned so its
/// shortfall is 100x smaller, but the sign and the cause are the
/// same. The tolerance admits the ridge term with room to spare and
/// would NOT admit a genuinely wrong trace.
///
/// Also pinned: every `h_i` strictly inside `[0, 1)`, strictly
/// positive, with a range far from either endpoint (a leverage pinned
/// at 0 or at 1 would pass a bounds check and mean nothing), and
/// elementwise agreement with the independent per-row back-solve.
test "blp_leverage_trace_equals_rank" {
  let n = 400
  let (basis, orth) = v097_dgp(n)
  let f = DoubleMLBLP::new(basis, orth, cov_type="HC0").fit()
  let lev = f.leverage()
  inspect(lev.length() == n, content="true")
  let (_resid, _m, hat) = v097_reference(basis, orth)
  let mut trace = 0.0
  let mut lo = 1.0e300
  let mut hi = -1.0e300
  let mut max_diff = 0.0
  let mut in_range = true
  for i = 0; i < n; i = i + 1 {
    let v = lev[i]
    trace = trace + v
    if v < lo {
      lo = v
    }
    if v > hi {
      hi = v
    }
    if !(v >= 0.0 && v < 1.0) {
      in_range = false
    }
    let d = (v - hat[i]).abs()
    if d > max_diff {
      max_diff = d
    }
  }
  inspect(in_range, content="true")
  inspect(lo > 0.0, content="true")
  inspect(hi < 0.1, content="true")
  // Elementwise agreement with the independent per-row back-solve.
  inspect(max_diff < 1.0e-12, content="true")
  // The absolute calibration: a REGULAR simplex design has every
  // leverage equal, so the mean must be `p1 / n` on any full-rank
  // design. Here `3 / 400 = 0.0075`, and the measured mean is
  // `0.007499999999994165`.
  let mean = trace / n.to_double()
  inspect(v097_rel_diff(mean, 0.0075) < 1.0e-9, content="true")
  // Trace == rank == n_params(), up to the ridge term. The measured
  // trace is 2.999999999997666 against rank 3 (low by 2.334e-12).
  let p1 = f.n_params()
  inspect(p1 == 3, content="true")
  inspect((trace - 3.0).abs() < 1.0e-9, content="true")
  // The reference trace agrees too, so the shortfall is the ridge and
  // not a disagreement between the two routes.
  let mut ref_trace = 0.0
  for h in hat {
    ref_trace = ref_trace + h
  }
  inspect(v097_rel_diff(trace, ref_trace) < 1.0e-12, content="true")
}

// ---------------------------------------------------------------------------
// 5. HC2 / HC3 AGAINST AN INDEPENDENT HAT DIAGONAL
// ---------------------------------------------------------------------------

///|
/// HC2 / HC3 against `v097_reference`'s OWN leverage (per-row
/// back-solve, not the implementation's full inverse), row by row,
/// for every coefficient. This checks the whole leverage-corrected
/// accumulation, not a summary factor.
///
/// It also pins the one identity from the shared DML helper that does
/// NOT carry over: the DML family has the CONSTANT mean-regression
/// leverage `h = 1 / n`, which is what makes
/// `sandwich_variance_hc2 == sandwich_variance_hc1` hold there. BLP's
/// leverage is a real OLS hat diagonal that varies per row, so HC2
/// and HC3 must NOT coincide with HC1. Asserting the inequality is
/// the point: a future reader who "unifies" this with the DML family
/// will see the test break.
test "blp_hac_se_hc2_hc3" {
  let n = 400
  let (basis, orth) = v097_dgp(n)
  let f = DoubleMLBLP::new(basis, orth, cov_type="HC0").fit()
  let (resid, m, hat) = v097_reference(basis, orth)
  let hac0 = f.hac_se(SandwichKind::hc0())
  let hac1 = f.hac_se(SandwichKind::hc1())
  let hac2 = f.hac_se(SandwichKind::hc2())
  let hac3 = f.hac_se(SandwichKind::hc3())
  for j = 0; j < f.n_params(); j = j + 1 {
    let expect2 = v097_hc_se(m, basis, resid, hat, j, 1)
    let expect3 = v097_hc_se(m, basis, resid, hat, j, 2)
    inspect(v097_rel_diff(hac2[j], expect2) < 1.0e-12, content="true")
    inspect(v097_rel_diff(hac3[j], expect3) < 1.0e-12, content="true")
    // Ordered by how much each widens.
    inspect(hac0[j] < hac1[j], content="true")
    inspect(hac1[j] < hac2[j], content="true")
    inspect(hac2[j] < hac3[j], content="true")
    // HC2 != HC1 (the DML identity), and by more than rounding.
    inspect(v097_rel_diff(hac2[j], hac1[j]) > 1.0e-4, content="true")
  }
}

///|
/// The constant-leverage case, where the per-observation
/// `(1 - h_i)` correction collapses to ONE common factor and the
/// closed forms are EXACT:
///
///     hac_se(HC2)[j] / hac_se(HC0)[j] == 1 / sqrt(1 - h)
///     hac_se(HC3)[j] / hac_se(HC0)[j] == 1 / (1 - h)
///
/// (This is NOT `hac_se(HC2) == hac_se(HC0)`: a leverage strictly
/// inside `(0, 1)` widens, so the two are equal only in the
/// degenerate `h = 0` limit.)
///
/// The fixture is a ZERO basis, so `X = [1, 0, 0]` and every one of
/// the `n` rows carries the same leverage `h = 1 / (n + ridge)`.
/// MEASURED on `n = 400`: `h = 0.0024999999999993743` (identical to
/// the last bit across all 400 rows), `HC2 / HC0 =
/// 1.0012523486435174` against the analytic `1.0012523486435174`,
/// and `HC3 / HC0 = 1.002506265664161` against the analytic
/// `1.0025062656641597` (off by 1.3e-15 relative).
///
/// The closed forms are asserted on the INTERCEPT only. On this
/// fixture the two zero columns have an exactly-zero row in
/// `(X'X + ridge I)^-1`, so their variance is exactly 0 and the ratio
/// would be `0 / 0`; that is pinned too, because "a constant column
/// contributes no variance" is a statement worth having. All three
/// coefficients are covered on a full-rank design by
/// `blp_hac_se_hc2_hc3`.
///
/// Agreement is to 1.0e-12 relative, NOT bit-exact, for two
/// documented reasons: this path divides each term by the common
/// factor inside the accumulator while `hac_se(HC0)` multiplies the
/// finished sum, and `1 - h` is evaluated from the ridge-regularised
/// `h`. This test is also what ties the two accumulation paths
/// together -- `hac_se(HC2)`'s per-term loop is only known to reduce
/// to `hac_se(HC0)` because it does so here.
test "blp_hac_se_hc2_hc3_constant_leverage" {
  let n = 400
  let (basis, orth) = v097_dgp_constant_leverage(n)
  let f = DoubleMLBLP::new(basis, orth, cov_type="HC0").fit()
  inspect(f.n_params() == 3, content="true")
  // The leverage really is constant, and known.
  let lev = f.leverage()
  let mut lo = 1.0e300
  let mut hi = -1.0e300
  for v in lev {
    if v < lo {
      lo = v
    }
    if v > hi {
      hi = v
    }
  }
  inspect(v097_rel_diff(lo, hi) < 1.0e-12, content="true")
  inspect(v097_rel_diff(lo, 1.0 / (400.0 + 1.0e-10)) < 1.0e-9, content="true")
  let one_minus_h = 1.0 - lo
  let expect2 = 1.0 / one_minus_h.sqrt()
  let expect3 = 1.0 / one_minus_h
  let hac0 = f.hac_se(SandwichKind::hc0())
  let hac2 = f.hac_se(SandwichKind::hc2())
  let hac3 = f.hac_se(SandwichKind::hc3())
  // The anchor still holds on this fixture, for every coefficient.
  for j = 0; j < 3; j = j + 1 {
    inspect(hac0[j] == f.se()[j], content="true")
  }
  // The closed-form ratios, on the intercept. MEASURED: the HC2 ratio
  // is exact to the last bit of the double and the HC3 ratio is off
  // by 1.3e-15 relative (both far inside the 1.0e-12 window).
  inspect(v097_rel_diff(hac2[0] / hac0[0], expect2) < 1.0e-12, content="true")
  inspect(v097_rel_diff(hac3[0] / hac0[0], expect3) < 1.0e-12, content="true")
  // The two zero columns carry NO variance at all, exactly: their row
  // of `(X'X + ridge I)^-1` is the pure-ridge block, so every
  // `M[j,:] . xa_i` is 0 and the meat is an exact 0. So the RATIO is
  // 0 / 0 for those two, and the closed form has nothing to say
  // about them -- which is why the ratio is asserted on the
  // intercept only. The all-three-coefficients check lives in
  // `blp_hac_se_hc2_hc3` against the independent reference, on a
  // full-rank design.
  for j = 1; j < 3; j = j + 1 {
    inspect(hac0[j] == 0.0, content="true")
    inspect(hac2[j] == 0.0, content="true")
    inspect(hac3[j] == 0.0, content="true")
  }
}

// ---------------------------------------------------------------------------
// 6. CLUSTER-ROBUST: SINGLETON CLUSTERS == IID, POOLED CLUSTERS DIFFER
// ---------------------------------------------------------------------------

///|
/// With all-singleton clusters the cluster meat collapses to
/// `sum_i s_ij^2`, i.e. the IID HC0 sandwich; pooled clusters differ.
/// The pooled value is additionally reproduced from the test's own
/// per-row scores `s_ij = m_j(xa_i) * e_i` and cluster sums, so the
/// cluster formula is checked against an independent computation
/// rather than against a re-run of the same code.
///
/// Agreement with the IID value is to 1.0e-12, NOT bit-exact: this
/// path squares `s_ij` as `s * s` where `hac_se` forms the term as
/// `m^2 e^2`, and it uses a Kahan-compensated accumulator where
/// `hac_se` uses a plain running sum.
test "blp_singleton_cluster_hac_equals_iid" {
  let n = 400
  let (basis, orth) = v097_dgp(n)
  let f = DoubleMLBLP::new(basis, orth, cov_type="HC0").fit()
  let iid = f.hac_se(SandwichKind::hc0())
  let singleton = Array::makei(n, fn(i) { i })
  let cl = f.cluster_hac_se(singleton)
  inspect(cl.length() == f.n_params(), content="true")
  for j = 0; j < f.n_params(); j = j + 1 {
    inspect(v097_rel_diff(cl[j], iid[j]) < 1.0e-12, content="true")
  }
  // Pooled clusters really do differ, and by more than rounding.
  let n_clusters = 5
  let pooled = Array::makei(n, fn(i) { i % n_clusters })
  let cl_pooled = f.cluster_hac_se(pooled)
  let mut any_differs = false
  for j = 0; j < f.n_params(); j = j + 1 {
    if v097_rel_diff(cl_pooled[j], iid[j]) > 1.0e-6 {
      any_differs = true
    }
  }
  inspect(any_differs, content="true")
  // Independent recomputation of the pooled cluster variance, from
  // the test's own per-row scores.
  let (resid, m, _hat) = v097_reference(basis, orth)
  let p1 = f.n_params()
  let sums : Array[Array[Double]] = Array::make(n_clusters, [])
  for c = 0; c < n_clusters; c = c + 1 {
    sums[c] = Array::make(p1, 0.0)
  }
  let sizes = Array::make(n_clusters, 0)
  for i = 0; i < n; i = i + 1 {
    let c = pooled[i]
    sizes[c] = sizes[c] + 1
    for j = 0; j < p1; j = j + 1 {
      let mut mjx = 0.0
      for a = 0; a < p1; a = a + 1 {
        mjx = mjx + m.get(j, a) * v097_xa(basis, i, a)
      }
      sums[c][j] = sums[c][j] + mjx * resid[i]
    }
  }
  for j = 0; j < p1; j = j + 1 {
    let mut var_ind = 0.0
    for c = 0; c < n_clusters; c = c + 1 {
      let nc = sizes[c]
      let scale = if nc <= 1 {
        1.0
      } else {
        nc.to_double() / (nc.to_double() - 1.0)
      }
      var_ind = var_ind + sums[c][j] * sums[c][j] * scale
    }
    inspect(
      v097_rel_diff(cl_pooled[j], var_ind.sqrt()) < 1.0e-12,
      content="true",
    )
  }
}

// ---------------------------------------------------------------------------
// 7. DGP SANITY
// ---------------------------------------------------------------------------

///|
/// Before trusting any HAC number, check that the fit is the fit we
/// think it is. Four independent cross-checks on the v0.97.0 DGP:
///
///   1. the design is well enough conditioned that every leverage is
///      STRICTLY below 1 with room to spare (the minimum `1 - h_i` is
///      0.9832131014798532, so the HC2 / HC3 divisor is never close to
///      zero). This is the check that makes the near-singular
///      failure mode -- which makes HC2 explode -- impossible here;
///   2. the residuals are real, i.e. O(1) and finite, not rounding
///      noise. The v0.96.0 DGP had a defect of exactly this kind (the
///      local design spanned the outcome, every residual was zero, and
///      the reported `se` was 9.3e-12); the check is the remedy;
///   3. the relative standard error is O(1) -- the cheapest smoke
///      alarm there is against a variance built on the wrong moment
///      (the v0.93 / v0.94 lesson: a wrong formula is usually
///      plausible, and implausibility is what catches it);
///   4. the HC0 SE matches the independent recomputation.
test "blp_hac_se_dgp_sanity" {
  let n = 400
  let (basis, orth) = v097_dgp(n)
  let f = DoubleMLBLP::new(basis, orth, cov_type="HC0").fit()
  inspect(f.n_obs() == n, content="true")
  // 1. Leverage strictly inside [0, 1) with room to spare.
  let lev = f.leverage()
  let mut min_one_minus_h = 1.0e300
  for v in lev {
    if v >= 0.0 && v < 1.0 {
      let omh = 1.0 - v
      if omh < min_one_minus_h {
        min_one_minus_h = omh
      }
    }
  }
  // Measured 0.9832131014798532 (the row at the end of `x0`).
  inspect(min_one_minus_h > 0.9, content="true")
  inspect(
    v097_rel_diff(min_one_minus_h, 0.9832131014798532) < 1.0e-9,
    content="true",
  )
  // 2. The residuals are real. `rss` is the OLS sum of squares over
  // 400 rows; a spanned design would report ~1e-20 here.
  inspect(f.rss() > 1.0, content="true")
  inspect(f.rss() < 1.0e3, content="true")
  // 3. Relative SE on the slopes is O(1) / small-but-credible.
  for j = 0; j < f.n_params(); j = j + 1 {
    let rel = f.se()[j] / f.coef()[j].abs()
    inspect(rel > 1.0e-3 && rel < 0.5, content="true")
  }
  // 4. And the number is the independently recomputed one.
  let (resid, m, _hat) = v097_reference(basis, orth)
  for j = 0; j < f.n_params(); j = j + 1 {
    inspect(
      v097_rel_diff(
        f.hac_se(SandwichKind::hc0())[j],
        v097_hc0_se(m, basis, resid, j),
      ) <
      1.0e-12,
      content="true",
    )
  }
}

// ---------------------------------------------------------------------------
// 8. REGRESSION PIN: `se` / `coef` ARE UNCHANGED BY v0.97.0
// ---------------------------------------------------------------------------

///|
/// Every number below was MEASURED ON v0.96.0 (commit a24ab06),
/// BEFORE any source change to `blp_policy.mbt`, with the identical
/// `v097_dgp` helper. v0.97.0 adds two public methods and two
/// read-only accessors and touches NOTHING in `fit` -- the
/// `cov_type` dispatch, the memoize `cov_clip` proxy, and the
/// variance block are all unchanged. This test is the pin that the
/// additive change did not perturb `fit`.
///
/// The comparisons are EXACT equality on `Double`, so this also pins
/// that the literals round-trip.
test "blp_existing_se_and_coef_unchanged" {
  let n = 400
  let (basis, orth) = v097_dgp(n)
  // cov_type = "HC0" (the default).
  let hc0 = DoubleMLBLP::new(basis, orth, cov_type="HC0").fit()
  let c = hc0.coef()
  let s = hc0.se()
  inspect(c.length() == 3, content="true")
  inspect(c[0] == 1.4847259384235596, content="true")
  inspect(c[1] == 0.8061945198942466, content="true")
  inspect(c[2] == -0.40436578065676815, content="true")
  inspect(s[0] == 0.012922353161859051, content="true")
  inspect(s[1] == 0.027318801608422746, content="true")
  inspect(s[2] == 0.029809503914903463, content="true")
  // cov_type = "nonrobust".
  let nr = DoubleMLBLP::new(basis, orth, cov_type="nonrobust").fit()
  let c2 = nr.coef()
  let s2 = nr.se()
  inspect(c2[0] == 1.4847259384235596, content="true")
  inspect(c2[1] == 0.8061945198942466, content="true")
  inspect(c2[2] == -0.40436578065676815, content="true")
  inspect(s2[0] == 0.012960403632469565, content="true")
  inspect(s2[1] == 0.022323620409447763, content="true")
  inspect(s2[2] == 0.02985414476201186, content="true")
  // The default `cov_type` is "HC0" and matches it exactly.
  let dflt = DoubleMLBLP::new(basis, orth).fit()
  inspect(dflt.se() == hc0.se(), content="true")
  inspect(dflt.coef() == hc0.coef(), content="true")
  // The derived scalars are unchanged too.
  inspect(hc0.rss() == nr.rss(), content="true")
  inspect(hc0.n_obs() == 400, content="true")
}

// ---------------------------------------------------------------------------
// 9. THE NEAR-SINGULAR / DEGENERATE DESIGNS
// ---------------------------------------------------------------------------

///|
/// THE ANSWER TO "what does `hac_se(HC2/HC3)` do on a near-singular
/// design", on three fixtures, each a different kind of degenerate.
///
/// FIXTURE A -- one extreme row (`basis[n-1, 0] = 1e8`, everything
/// else `O(1)`). This is the worst case for HC2: the leverage of that
/// row goes to 1, and MEASURED `h_max = 0.9999999999999863`, so
/// `1 - h = 1.3655743202889425e-14` -- four orders of magnitude
/// BELOW the `1e-10` ridge that produced it, so the divisor really is
/// a regularizer artifact.
///
/// The inflation is REAL and it is UNBOUND, and it is confined to
/// exactly the coefficient whose column carries the singular row.
/// MEASURED on `n = 400`:
///
///   HC0      = [0.02063110943723901,
///               2.0801434736970338e-10,
///               0.0715284191225321]
///   HC2/HC0  = [1.0025364388264777,
///               276.73848187957105,
///               1.0035030500182698]
///   HC3/HC0  = [1.0067352776561909,
///               2368149052.6520414,
///               1.0074030044105038]
///
/// So the intercept and the second column -- neither of which sees
/// the singular row -- widen by well under 1%, while coefficient 1
/// widens by 277x under HC2 and 2.4e9 under HC3. Coefficient 1's HC0
/// is itself degenerate (2.08e-10, eight orders below its
/// neighbours: the projection INTERPOLATES that column), and the
/// correction is the honest answer about a near-collinear
/// coefficient whose standard error is genuinely unidentified. For
/// OLS the deleted residual is `e_i / (1 - h_i)` exactly, which is
/// what HC2 squares -- so this number is the leave-one-out
/// leverage-corrected variance, not a corrupted one. It is also
/// LOUD: a nine-order change in a reported SE cannot be mistaken for
/// a healthy fit.
///
/// CONSEQUENCE FOR THE GUARDS: there is deliberately NO `1 - h` floor.
/// A floor would have to be an arbitrary threshold, and it would
/// abort on a case where the answer is well defined, correct, and
/// informative -- and it would abort the two coefficients that are
/// perfectly healthy along with the one that is not. What the guards
/// do instead is refuse the genuinely UNIDENTIFIED case: the
/// degrees-of-freedom check (`n <= p1`, fixture C) and the `[0, 1)`
/// range check, which fires only where dividing would be
/// unconditionally wrong (`h >= 1` or `NaN`). Fixture A passes both
/// and is reported with its full spread, which is the right outcome.
///
/// FIXTURE B -- a duplicated column (`basis[:, 1] == basis[:, 0]`).
/// Rank-deficient with `n = 400 >> p1 = 3`, so the df guard cannot
/// see it. The regularised hat matrix reports the RANK, not the
/// parameter count: MEASURED trace 2.000116225484817 (rank 2, not 3)
/// and `h_max = 0.009963035583496094`. Because EVERY leverage is
/// bounded by `h_max`, the inflation is bounded too, and the bound
/// is the one the leverage implies rather than a magic number:
/// `HC2 / HC0 <= 1 / sqrt(1 - h_max)` and
/// `HC3 / HC0 <= 1 / (1 - h_max)`. Both are asserted.
///
/// FIXTURE C -- `n == p1 == 3` rows, which the df guard refuses for
/// HC1 / HC2 / HC3. Here the leverage is `h_0 =
/// 0.833333333258889`, INSIDE `[0, 1)`, so a range check alone would
/// sail past -- and the fit's own `se` is `[8.498667959259792e-13,
/// 1.4142435368001974e-13, 2.828488117278953e-13]`, i.e. rounding
/// noise. This is exactly RDD's v0.96.0 failure mode reproduced for
/// BLP, and it is why `blp_hac_require_df` has to run BEFORE the
/// range check. HC0 is exempt and still works: the anchor does not
/// depend on the fit being well conditioned.
test "blp_hac_se_near_singular_design" {
  let n = 400
  // FIXTURE A: one extreme row.
  let ab = Matrix::zeros(n, 2)
  let ao = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let t = (i.to_double() - 199.5) / 199.5
    ab.set(i, 0, t)
    ab.set(i, 1, (i * 7 % 23).to_double() / 23.0 - 0.5)
    ao[i] = 1.0 + 0.5 * t + (i * 11 % 29).to_double() / 29.0
  }
  ab.set(n - 1, 0, 1.0e8)
  let af = DoubleMLBLP::new(ab, ao, cov_type="HC0").fit()
  let al = af.leverage()
  let mut a_hi = -1.0e300
  let mut a_lo = 1.0e300
  for v in al {
    if v > a_hi {
      a_hi = v
    }
    if v < a_lo {
      a_lo = v
    }
  }
  // The leverage really did go to 1, and the divisor really is below
  // the ridge that produced it.
  inspect(a_hi < 1.0, content="true")
  inspect(v097_rel_diff(a_hi, 0.9999999999999863) < 1.0e-12, content="true")
  inspect(1.0 - a_hi < 1.0e-13, content="true")
  inspect(a_lo > 0.0, content="true")
  let a0 = af.hac_se(SandwichKind::hc0())
  let a2 = af.hac_se(SandwichKind::hc2())
  let a3 = af.hac_se(SandwichKind::hc3())
  // The two coefficients that do NOT see the singular row are
  // untouched (< 1% widening).
  inspect(
    v097_rel_diff(a2[0] / a0[0], 1.0025364388264777) < 1.0e-12,
    content="true",
  )
  inspect(a2[0] / a0[0] < 1.01, content="true")
  inspect(a2[2] / a0[2] < 1.01, content="true")
  inspect(a3[0] / a0[0] < 1.01, content="true")
  // The coefficient whose column DOES see it is inflated, hugely, and
  // that is the honest leave-one-out answer rather than a corrupted
  // one. Pinned, not merely bounded.
  inspect(
    v097_rel_diff(a2[1] / a0[1], 276.73848187957105) < 1.0e-12,
    content="true",
  )
  inspect(
    v097_rel_diff(a3[1] / a0[1], 2368149052.6520414) < 1.0e-9,
    content="true",
  )
  // And its HC0 is itself degenerate: the projection interpolates
  // that column, so the HC0 SE is eight orders below its neighbours
  // (2.08e-10 against 2.06e-2).
  inspect(a0[1] < a0[0] * 1.0e-7, content="true")
  // All of them stay finite and positive.
  for j = 0; j < af.n_params(); j = j + 1 {
    inspect(a2[j] > 0.0 && a2[j] < 1.0e3, content="true")
    inspect(a3[j] >= a2[j], content="true")
  }
  // FIXTURE B: duplicated column, rank-deficient with n >> p1.
  let bb = Matrix::zeros(n, 2)
  let bo = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let t = (i.to_double() - 199.5) / 199.5
    bb.set(i, 0, t)
    bb.set(i, 1, t)
    bo[i] = 1.0 + 0.5 * t + (i * 11 % 29).to_double() / 29.0
  }
  let bf = DoubleMLBLP::new(bb, bo, cov_type="HC0").fit()
  let bl = bf.leverage()
  let mut b_trace = 0.0
  let mut b_hi = -1.0e300
  for v in bl {
    b_trace = b_trace + v
    if v > b_hi {
      b_hi = v
    }
  }
  // The trace is the RANK (2), not the parameter count (3): the
  // regularised hat matrix reports the true projection.
  inspect((b_trace - 2.0).abs() < 1.0e-3, content="true")
  inspect(v097_rel_diff(b_trace, 2.000116225484817) < 1.0e-12, content="true")
  inspect(b_hi < 0.1, content="true")
  // Every leverage is bounded by `b_hi`, so the inflation is bounded
  // by what the leverage implies -- the bound is derived, not chosen.
  let bound2 = 1.0 / (1.0 - b_hi).sqrt()
  let bound3 = 1.0 / (1.0 - b_hi)
  let b0 = bf.hac_se(SandwichKind::hc0())
  let b2 = bf.hac_se(SandwichKind::hc2())
  let b3 = bf.hac_se(SandwichKind::hc3())
  for j = 0; j < bf.n_params(); j = j + 1 {
    inspect(b2[j] / b0[j] <= bound2, content="true")
    inspect(b3[j] / b0[j] <= bound3, content="true")
    inspect(b2[j] / b0[j] > 1.0, content="true")
  }
  inspect(
    v097_rel_diff(b2[0] / b0[0], 1.0025175586184212) < 1.0e-12,
    content="true",
  )
  // FIXTURE C: n == p1, refused by the df guard. Its leverage is
  // INSIDE [0, 1), so only the df check can catch it.
  let db = Matrix::zeros(3, 2)
  let dobj = Array::make(3, 0.0)
  for i = 0; i < 3; i = i + 1 {
    db.set(i, 0, i.to_double())
    db.set(i, 1, (i * 2).to_double())
    dobj[i] = 0.1 * i.to_double()
  }
  let cf = DoubleMLBLP::new(db, dobj, cov_type="HC0").fit()
  inspect(cf.n_params() == 3, content="true")
  inspect(cf.leverage()[0] > 0.8, content="true")
  inspect(cf.leverage()[0] < 1.0, content="true")
  // HC0 is exempt, and still the anchor.
  let c0 = cf.hac_se(SandwichKind::hc0())
  for j = 0; j < 3; j = j + 1 {
    inspect(c0[j] == cf.se()[j], content="true")
  }
  // HC1 / HC2 / HC3 abort here -- see the `panic_` tests below.
}

// ---------------------------------------------------------------------------
// 10. THE GUARDS
// ---------------------------------------------------------------------------

///|
/// HC1 must abort when the projection has no more rows than the
/// augmented design has parameters: the `n / (n - k)` divisor would
/// be zero or negative. Fixture: `n = 3`, `p1 = 3`.
test "panic_blp_hac_se_hc1_too_few_rows" {
  let db = Matrix::zeros(3, 2)
  let dobj = Array::make(3, 0.0)
  for i = 0; i < 3; i = i + 1 {
    db.set(i, 0, i.to_double())
    db.set(i, 1, (i * 2).to_double())
    dobj[i] = 0.1 * i.to_double()
  }
  let f = DoubleMLBLP::new(db, dobj, cov_type="HC0").fit()
  let _ = f.hac_se(SandwichKind::hc1())
}

///|
/// HC2 must abort on the same fixture, and the reason is the sharp one:
/// the leverage there is `0.833333333258889`, comfortably INSIDE
/// `[0, 1)`, so a range check alone would NOT fire and HC2 would go on
/// to divide the meat by a regularizer artifact.
test "panic_blp_hac_se_hc2_too_few_rows" {
  let db = Matrix::zeros(3, 2)
  let dobj = Array::make(3, 0.0)
  for i = 0; i < 3; i = i + 1 {
    db.set(i, 0, i.to_double())
    db.set(i, 1, (i * 2).to_double())
    dobj[i] = 0.1 * i.to_double()
  }
  let f = DoubleMLBLP::new(db, dobj, cov_type="HC0").fit()
  let _ = f.hac_se(SandwichKind::hc2())
}

///|
/// HC3 refuses the same fixture as HC2 -- the guard is shared.
test "panic_blp_hac_se_hc3_too_few_rows" {
  let db = Matrix::zeros(3, 2)
  let dobj = Array::make(3, 0.0)
  for i = 0; i < 3; i = i + 1 {
    db.set(i, 0, i.to_double())
    db.set(i, 1, (i * 2).to_double())
    dobj[i] = 0.1 * i.to_double()
  }
  let f = DoubleMLBLP::new(db, dobj, cov_type="HC0").fit()
  let _ = f.hac_se(SandwichKind::hc3())
}

///|
/// `leverage` must abort on an un-fit model, like every other fitted
/// accessor.
test "panic_blp_leverage_before_fit" {
  let n = 8
  let basis = Matrix::zeros(n, 2)
  let model = DoubleMLBLP::new(basis, Array::make(n, 1.0))
  let _ = model.leverage()
}

///|
/// `cluster_hac_se` must abort on an un-fit model, like every other
/// BLP accessor.
test "panic_blp_cluster_hac_se_before_fit" {
  let n = 8
  let basis = Matrix::zeros(n, 2)
  let model = DoubleMLBLP::new(basis, Array::make(n, 1.0))
  let _ = model.cluster_hac_se(Array::makei(n, fn(i) { i }))
}

///|
/// `cluster_hac_se` must abort on a cluster vector of the wrong
/// length: BLP's rows are `basis` rows, so a mis-sized `cluster_ids`
/// is a caller bug that would otherwise read past the end.
test "panic_blp_cluster_hac_se_wrong_length" {
  let n = 400
  let (basis, orth) = v097_dgp(n)
  let f = DoubleMLBLP::new(basis, orth, cov_type="HC0").fit()
  let _ = f.cluster_hac_se(Array::makei(n / 2, fn(i) { i }))
}

// ---------------------------------------------------------------------------
// 11. THE MEMOIZE CACHE-HIT PATH
// ---------------------------------------------------------------------------

///|
/// v0.97.0 persists NOTHING new, so the cache plumbing is untouched
/// by construction -- but that is exactly the kind of claim that
/// rots, because `fit` on a cache HIT skips the whole variance block.
/// So: the anchor and the leverage must still hold on a cached fit,
/// and must be bit-identical to the fresh one. This mirrors
/// `rdd_hac_se_after_memoize_cache_hit` (v0.96.0).
test "blp_hac_se_after_memoize_cache_hit" {
  let n = 400
  let (basis, orth) = v097_dgp(n)
  let fresh = DoubleMLBLP::new(basis, orth, cov_type="HC0").fit()
  let cached = DoubleMLBLP::new(basis, orth, cov_type="HC0")
    .enable_memoize()
    .fit()
  inspect(cached.has_cache(), content="true")
  let again = DoubleMLBLP::new(basis, orth, cov_type="HC0")
    .enable_memoize()
    .fit()
  inspect(again.coef() == cached.coef(), content="true")
  inspect(again.se() == cached.se(), content="true")
  // The anchor still holds on the cached fit, and the HC0 sandwich is
  // bit-identical to the uncached one.
  for j = 0; j < cached.n_params(); j = j + 1 {
    inspect(
      cached.hac_se(SandwichKind::hc0())[j] == cached.se()[j],
      content="true",
    )
    inspect(
      cached.hac_se(SandwichKind::hc0())[j] ==
      fresh.hac_se(SandwichKind::hc0())[j],
      content="true",
    )
  }
  // The leverage is recomputed from the persisted `basis` and matches.
  inspect(cached.leverage().length() == n, content="true")
  let mut trace_c = 0.0
  for v in cached.leverage() {
    trace_c = trace_c + v
  }
  let mut trace_f = 0.0
  for v in fresh.leverage() {
    trace_f = trace_f + v
  }
  inspect(trace_c == trace_f, content="true")
  // And the HC2 / HC3 paths agree too.
  for j = 0; j < cached.n_params(); j = j + 1 {
    inspect(
      cached.hac_se(SandwichKind::hc2())[j] ==
      fresh.hac_se(SandwichKind::hc2())[j],
      content="true",
    )
    inspect(
      cached.hac_se(SandwichKind::hc3())[j] ==
      fresh.hac_se(SandwichKind::hc3())[j],
      content="true",
    )
  }
}
