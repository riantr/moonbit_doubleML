///|
// v0.96.0: `DoubleMLRDD::hac_se` / `cluster_hac_se` -- the
// local-regression HAC sandwich.
//
// WHY RDD GETS ITS OWN API AND NOT `sandwich_se`
// ================================================
//
// Every other estimator in this package grew
// `sandwich_se(kind) -> Double` on top of the shared
// `sandwich_variance` dispatch in `sandwich.mbt`. RDD did not,
// and the reason is algebraic, not bookkeeping. RDD's own HC0
// branch (`rdd_side`, taken when `cov_type == "HC0"`) computes
//
//     sum_k  w_k^2 * m_k^2 * e_k^2
//
// per side, with `m_k` the intercept row of a FULL `p1 x p1`
// WLS normal inverse and NO `1 / n^2` divisor. The shared
// helper computes a scalar-Jacobian MEAN-moment sandwich
// (`M_inv[0,0]^2 * sum_i psi[i]^2 / n^2` since v0.91.0), and its
// pre-v0.91.0 form accumulated `sum_i (psi_a[i] * psi[i])^2`.
// Substituting RDD's combined influence function
// `psi[k] = psi_a[k] * residuals[k]` -- exactly what
// `bootstrap(...)` hands to `did_bootstrap_t_stat` -- into that
// older accumulator gives
//
//     sum_k ( psi_a[k] * psi_a[k] * e_k )^2
//   = sum_k ( psi_a[k]^2 * e_k )^2
//   = sum_k psi_a[k]^4 * e_k^2,
//
// a FOURTH power, against RDD's second power `w_k^2 psi_a[k]^2
// e_k^2` (whose `M[0,:] . x_k` factor IS `psi_a[k]`). The gap is
// a data-dependent `psi_a[k]^2` per row and is of order 1e-2 on
// the DGP below, so the wrong answer looks entirely reasonable.
// v0.91.0 removed the `psi_a` factor because it was not part of
// the moment, which removes THAT error but leaves the scalar
// `M_inv` and the `1 / n^2`, both of which are also wrong here.
// The full argument, with line references, is in the section
// comment above `DoubleMLRDD::n_local_params` in `rdd.mbt`.
//
// So RDD exposes `hac_se` -- the name says what the number is --
// while reusing `SandwichKind`, which is only the package's
// vocabulary for the HC family and carries no algebra.
//
// THE ANCHOR, AND WHERE IT DOES NOT HOLD
// ======================================
//
// `hac_se(HC0) == se()` BIT-IDENTICALLY on a `cov_type = "HC0"`
// fit, because that is exactly the branch `fit` took. It is NOT
// claimed, and is pinned NOT to hold, on a
// `cov_type = "homoskedastic"` fit (whose `se()` is the
// homoskedastic form). `hac_se` refuses a non-OLS learner and
// refuses `fuzzy = true`; both refusals are pinned below.
//
// k (the local-regression parameter count) IS READ FROM THE
// CODE, NOT ASSUMED: `rdd_design` builds a local design of
// `data.x.cols() + 1` columns and `fit_weighted` adds an
// intercept, so each side estimates `p1 = data.x.cols() + 2`
// coefficients -- 3 on the one-covariate DGP below, exposed as
// `n_local_params()`. "2 (intercept + running variable)" is right
// only for a zero-covariate design. Note also that the leverage
// sums to the RANK of the local design, not to `p1`: a constant
// covariate column makes `(1, u, 0)` rank-deficient, which test 4
// pins explicitly.
//
// EVERY CHECK BELOW COMPARES TWO INDEPENDENTLY COMPUTED
// NUMBERS. `v096_side_wls` re-derives the local design, the
// kernel weights, `m_k`, `e_k` and the hat diagonal from their
// DEFINITIONS, using `inv_spd` (full inverse) where `rdd_side`
// uses `solve_spd` (single back-solve) and a different
// accumulation order. There are no finiteness-only assertions.

// ---------------------------------------------------------------------------
// Shared fixtures and independent recomputation
// ---------------------------------------------------------------------------

///|
/// The v0.96.0 DGP. `n = 600`, one covariate `x = 0.25 * z`, a
/// running variable uniform on `(-1, 1)`, a sharp treatment jump
/// of 3.0 at the cutoff, and HETEROSKEDASTIC noise
/// `(1 + 2|u|) * 0.4 * z` -- so the homoskedastic and HC0
/// standard errors genuinely differ and the test would notice if
/// `hac_se` silently returned the homoskedastic number. `z` is a
/// deterministic sawtooth in `i` (no RNG), so every number below
/// is reproducible byte-for-byte on every backend.
fn v096_dgp(n : Int) -> (Matrix, Array[Double], Array[Double], Array[Double]) {
  let xd = Array::make(n, 0.0)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let score = Array::make(n, 0.0)
  let half = n.to_double() / 2.0
  for i = 0; i < n; i = i + 1 {
    let u = (i.to_double() + 0.5) / half - 1.0
    let z = ((i * 13 % 17).to_double() - 8.0) / 8.0
    score[i] = u
    d[i] = if u >= 0.0 { 1.0 } else { 0.0 }
    y[i] = 2.0 + 1.5 * u + 3.0 * d[i] + (1.0 + 2.0 * u.abs()) * 0.4 * z
    xd[i] = 0.25 * z
  }
  (Matrix::from_array(xd, n, 1), y, d, score)
}

///|
/// A LOPSIDED running variable: `score = -0.95 + 1.9 t^2` with
/// `t = i / (n - 1)`, so the observations crowd toward the LEFT
/// of the cutoff. With `bandwidth = 0.5` this gives materially
/// different local sample sizes on the two sides, which is what
/// lets test 3 tell the per-side HC1 correction apart from the
/// pooled one (on a symmetric design the two coincide exactly,
/// since `2 n_s / (2 n_s - 2k) == n_s / (n_s - k)`).
///
/// The `0.2 * z2` term is LOAD-BEARING and its absence is a real
/// trap. The first version of this DGP had
/// `y = 1 + 0.8 u + 2.5 d + 0.3 z` with `x = 0.2 z`, so on the
/// LEFT side (`d == 0`, hence `y = 1 + 0.8 u + 1.5 x`) the local
/// design `(1, u, x)` SPANS THE OUTCOME EXACTLY: every residual
/// was zero up to rounding, the whole sandwich was
/// floating-point noise, and the reported `se` was 9.3e-12 instead
/// of 3.5e-2. The implementation was fine; the fixture was
/// degenerate. `z2` is a second sawtooth with a different period,
/// so the design cannot fit it and the residuals are real. This is
/// the same class of mistake as the v0.93 / v0.94 DGP defects, and
/// the reason `rdd_hac_se_dgp_sanity` below checks the scale of the
/// answer rather than only its sign.
fn v096_dgp_lopsided(
  n : Int,
) -> (Matrix, Array[Double], Array[Double], Array[Double]) {
  let xd = Array::make(n, 0.0)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let score = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let t = i.to_double() / (n.to_double() - 1.0)
    let u = -0.95 + 1.9 * t * t
    let z = ((i * 7 % 11).to_double() - 5.0) / 5.0
    let z2 = ((i * 5 % 7).to_double() - 3.0) / 3.0
    score[i] = u
    d[i] = if u >= 0.0 { 1.0 } else { 0.0 }
    y[i] = 1.0 + 0.8 * u + 2.5 * d[i] + 0.3 * z + 0.2 * z2
    xd[i] = 0.2 * z
  }
  (Matrix::from_array(xd, n, 1), y, d, score)
}

///|
/// Test-side INDEPENDENT recomputation of one side's local WLS.
/// Returns `(n_side, weights, hc0_m, hc0_e, leverage)`, each
/// written out from the definition of the quantity in `rdd.mbt`:
///
///   - the selection predicate is `rdd_design`'s (same
///     `u < 0.0` / `u >= 0.0` split, same `|u| <= h` test);
///   - the kernel weight is `1 - |u| / h`;
///   - the local design row is `xa_k = (1, u_k, x_k)`, i.e. the
///     intercept-augmented design `fit_weighted` uses;
///   - `hc0_m[k]` is the first ROW of the unweighted
///     `(X'X + ridge I)^{-1}` dotted with `xa_k`;
///   - `hc0_e[k]` is the FULL-design fitted residual
///     `y_k - xa_k . beta`, with `beta` the WLS solution -- NOT
///     the local-linear-only prediction that `residuals` holds;
///   - `leverage[k] = w_k * xa_k' (X'WX + ridge I)^{-1} xa_k`.
///
/// `inv_spd` (a full inverse) is used where the implementation
/// uses `solve_spd` (one back-solve for the intercept column), and
/// `X'WX` is accumulated in a different order, so agreement
/// between this and the implementation is evidence rather than a
/// tautology.
fn v096_side_wls(
  x : Matrix,
  y : Array[Double],
  score : Array[Double],
  cutoff : Double,
  h : Double,
  side : Double,
  ridge : Double,
) -> (Int, Array[Double], Array[Double], Array[Double], Array[Double]) {
  let idx : Array[Int] = []
  for i = 0; i < score.length(); i = i + 1 {
    let u = score[i] - cutoff
    if (side < 0.0 && u < 0.0) || (side > 0.0 && u >= 0.0) {
      if u.abs() <= h {
        idx.push(i)
      }
    }
  }
  let n = idx.length()
  if n == 0 {
    return (0, [], [], [], [])
  }
  let p1 = x.cols() + 2
  let w : Array[Double] = Array::make(n, 0.0)
  let xa = Matrix::zeros(n, p1)
  for k = 0; k < n; k = k + 1 {
    let i = idx[k]
    let u = score[i] - cutoff
    xa.set(k, 0, 1.0)
    xa.set(k, 1, u)
    for j = 0; j < x.cols(); j = j + 1 {
      xa.set(k, 2 + j, x.get(i, j))
    }
    w[k] = 1.0 - u.abs() / h
  }
  // X'WX, X'X and X'Wy over the augmented design.
  let xtwx = Matrix::zeros(p1, p1)
  let xtx = Matrix::zeros(p1, p1)
  let xtwy = Array::make(p1, 0.0)
  for k = 0; k < n; k = k + 1 {
    let yk = y[idx[k]]
    for a = 0; a < p1; a = a + 1 {
      xtwy[a] = xtwy[a] + xa.get(k, a) * w[k] * yk
      for b = 0; b < p1; b = b + 1 {
        let xa_xb = xa.get(k, a) * xa.get(k, b)
        xtwx.set(a, b, xtwx.get(a, b) + w[k] * xa_xb)
        xtx.set(a, b, xtx.get(a, b) + xa_xb)
      }
    }
  }
  let beta = solve_spd(add_ridge(xtwx, ridge), xtwy)
  let m_w = inv_spd(add_ridge(xtwx, ridge))
  let m_u = inv_spd(add_ridge(xtx, ridge))
  let hc0_m : Array[Double] = Array::make(n, 0.0)
  let hc0_e : Array[Double] = Array::make(n, 0.0)
  let lev : Array[Double] = Array::make(n, 0.0)
  for k = 0; k < n; k = k + 1 {
    let mut mj = 0.0
    for a = 0; a < p1; a = a + 1 {
      mj = mj + m_u.get(0, a) * xa.get(k, a)
    }
    hc0_m[k] = mj
    let mut pred = 0.0
    let mut quad = 0.0
    for a = 0; a < p1; a = a + 1 {
      pred = pred + xa.get(k, a) * beta[a]
      let mut mg = 0.0
      for b = 0; b < p1; b = b + 1 {
        mg = mg + m_w.get(a, b) * xa.get(k, b)
      }
      quad = quad + xa.get(k, a) * mg
    }
    hc0_e[k] = y[idx[k]] - pred
    lev[k] = w[k] * quad
  }
  (n, w, hc0_m, hc0_e, lev)
}

///|
/// Independent HC0 meat of one side: `sum_k w_k^2 m_k^2 e_k^2`.
fn v096_meat(w : Array[Double], m : Array[Double], e : Array[Double]) -> Double {
  let mut acc = 0.0
  for k = 0; k < w.length(); k = k + 1 {
    let wi2 = w[k] * w[k]
    acc = acc + wi2 * m[k] * m[k] * e[k] * e[k]
  }
  acc
}

///|
/// Independent HC2 / HC3 meat of one side: the same sum with each
/// term divided by `(1 - h_k)` (HC2) or `(1 - h_k)^2` (HC3),
/// using the test's OWN leverage. No clipping: a leverage outside
/// `[0, 1)` would make the divisor non-positive and the test would
/// be measuring a garbage number, so the caller is expected to
/// have checked the range first (test 5 does).
fn v096_meat_leverage(
  w : Array[Double],
  m : Array[Double],
  e : Array[Double],
  lev : Array[Double],
  squared : Bool,
) -> Double {
  let mut acc = 0.0
  for k = 0; k < w.length(); k = k + 1 {
    let wi2 = w[k] * w[k]
    let base = wi2 * m[k] * m[k] * e[k] * e[k]
    let d = 1.0 - lev[k]
    let term = if squared { base / (d * d) } else { base / d }
    acc = acc + term
  }
  acc
}

///|
/// Relative difference, for the "two independently computed
/// numbers" comparisons. Returns 0 for two exact zeros so a
/// genuinely-zero comparison does not produce NaN.
fn v096_rel_diff(a : Double, b : Double) -> Double {
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
/// fit, `se()` IS the HC0 standard error, so
/// `hac_se(HC0) == se()` must hold BIT-IDENTICALLY. `==` on
/// `Double` is exact equality, not a tolerance -- this test would
/// fail on a last-ulp difference, which is the point.
///
/// The second half checks the same number against the fully
/// independent recomputation in `v096_side_wls`, so the anchor is
/// not just self-consistent but also correct.
test "rdd_hac_se_hc0_equals_se_on_hc0_path" {
  let n = 600
  let (x, y, d, score) = v096_dgp(n)
  let f = DoubleMLRDD::new(
    DoubleMLRDDData::new(x, y, d, score),
    bandwidth=0.6,
    cov_type="HC0",
  ).fit()
  let se = f.se()
  let hac = f.hac_se(SandwichKind::hc0())
  // The anchor, exact.
  inspect(hac == se, content="true")
  // Not a coincidence of a degenerate zero.
  inspect(se > 0.01 && se < 0.02, content="true")
  // And it agrees with the independent recomputation, which uses
  // a different solver and a different accumulation order.
  let (_, wl, ml, el, _) = v096_side_wls(x, y, score, 0.0, 0.6, -1.0, 1.0e-10)
  let (_, wr, mr, er, _) = v096_side_wls(x, y, score, 0.0, 0.6, 1.0, 1.0e-10)
  let independent = (v096_meat(wl, ml, el) + v096_meat(wr, mr, er)).sqrt()
  inspect(v096_rel_diff(se, independent) < 1.0e-12, content="true")
}

// ---------------------------------------------------------------------------
// 2. THE ANCHOR DOES NOT HOLD ON THE HOMOSKEDASTIC PATH
// ---------------------------------------------------------------------------

///|
/// Without this test the anchor above is ambiguous: it would also
/// pass on a `homoskedastic` fit if `hac_se` were simply echoing
/// `se()` back. On a `cov_type = "homoskedastic"` fit `se()` is
/// the homoskedastic form, so `hac_se(HC0) != se()` -- by a factor
/// of about 2.4 on this DGP, which is far too large to be a
/// rounding difference.
///
/// The last assertion is the sharpest form of the whole file:
/// `hac_se` is a property of the DATA, not of `cov_type`, so two
/// independently fitted models (one per `cov_type`) must report
/// the SAME HC0 sandwich, while their `se()` values differ.
test "rdd_hac_se_hc0_differs_from_se_on_homoskedastic_path" {
  let n = 600
  let (x, y, d, score) = v096_dgp(n)
  let hom = DoubleMLRDD::new(
    DoubleMLRDDData::new(x, y, d, score),
    bandwidth=0.6,
    cov_type="homoskedastic",
  ).fit()
  let hc0 = DoubleMLRDD::new(
    DoubleMLRDDData::new(x, y, d, score),
    bandwidth=0.6,
    cov_type="HC0",
  ).fit()
  // The anchor must NOT hold here.
  inspect(hom.hac_se(SandwichKind::hc0()) != hom.se(), content="true")
  // By a factor, not by rounding.
  inspect(hom.hac_se(SandwichKind::hc0()) / hom.se() > 2.0, content="true")
  // `hac_se` depends only on the data, so it is bit-identical
  // across the two `cov_type` settings ...
  inspect(
    hom.hac_se(SandwichKind::hc0()) == hc0.hac_se(SandwichKind::hc0()),
    content="true",
  )
  // ... while `se()` and the point estimate are not.
  inspect(hom.se() != hc0.se(), content="true")
  inspect(hom.coef() == hc0.coef(), content="true")
}

// ---------------------------------------------------------------------------
// 3. HC1: THE PER-SIDE FINITE-SAMPLE CORRECTION
// ---------------------------------------------------------------------------

///|
/// HC1 must be the HC0 variance with each side's sum scaled by
/// `n_side / (n_side - k)`, `k = n_local_params()` read from the
/// code. This DGP is deliberately LOPSIDED so `n_left != n_right`
/// and the per-side convention is distinguishable from the pooled
/// `n_local / (n_local - 2k)`; the test asserts the pooled value
/// is a DIFFERENT number, so a pooled implementation would fail.
///
/// The expected value is built from the independent per-side
/// recomputation, not from `hac_se` itself.
test "rdd_hac_se_hc1_ratio" {
  let n = 400
  let (x, y, d, score) = v096_dgp_lopsided(n)
  let f = DoubleMLRDD::new(
    DoubleMLRDDData::new(x, y, d, score),
    bandwidth=0.5,
    cov_type="HC0",
  ).fit()
  let (nl, wl, ml, el, _) = v096_side_wls(x, y, score, 0.0, 0.5, -1.0, 1.0e-10)
  let (nr, wr, mr, er, _) = v096_side_wls(x, y, score, 0.0, 0.5, 1.0, 1.0e-10)
  let k = f.n_local_params()
  // Precondition of the test itself: the sides really are
  // lopsided, and `k` is the code-derived 3.
  inspect(nl != nr, content="true")
  inspect(k == 3, content="true")
  inspect(nl + nr == f.n_local(), content="true")
  let k_d = k.to_double()
  let v_l = v096_meat(wl, ml, el)
  let v_r = v096_meat(wr, mr, er)
  let s_l = nl.to_double() / (nl.to_double() - k_d)
  let s_r = nr.to_double() / (nr.to_double() - k_d)
  let expect = (v_l * s_l + v_r * s_r).sqrt()
  let got = f.hac_se(SandwichKind::hc1())
  inspect(v096_rel_diff(got, expect) < 1.0e-12, content="true")
  // The pooled convention is a different number on this design,
  // so an implementation that pooled would NOT match above.
  let pooled = (nl + nr).to_double() / ((nl + nr).to_double() - 2.0 * k_d)
  let pooled_expect = (v_l * pooled + v_r * pooled).sqrt()
  inspect(v096_rel_diff(pooled_expect, expect) > 1.0e-6, content="true")
  // HC1 is a pure variance scale, so the SE ratio is the square
  // root of it and HC1 > HC0 strictly.
  let ratio = got / f.hac_se(SandwichKind::hc0())
  inspect(ratio > 1.0, content="true")
  inspect(
    v096_rel_diff(ratio, ((v_l * s_l + v_r * s_r) / (v_l + v_r)).sqrt()) <
    1.0e-12,
    content="true",
  )
}

// ---------------------------------------------------------------------------
// 4. HC2 / HC3 AGAINST AN INDEPENDENT HAT DIAGONAL
// ---------------------------------------------------------------------------

///|
/// HC2 / HC3 against the independent per-row recomputation, on the
/// well-conditioned full-rank DGP of test 1. Each term of the meat
/// is divided by `(1 - h_k)` (HC2) or `(1 - h_k)^2` (HC3) using the
/// test's OWN leverage, so this checks the whole leverage-corrected
/// accumulation row by row, not just a summary factor.
///
/// It also pins the one identity from the shared DML helper that
/// does NOT carry over: the DML family has the CONSTANT
/// mean-regression leverage `h = 1 / n`, which is what makes
/// `sandwich_variance_hc2 == sandwich_variance_hc1` hold there.
/// RDD's leverage is a real WLS hat diagonal, so HC2 and HC3 must
/// NOT coincide with HC1, and they do not. Asserting the inequality
/// is the point: a future reader who "unifies" this with the DML
/// family will see the test break.
test "rdd_hac_se_hc2_hc3" {
  let n = 600
  let (x, y, d, score) = v096_dgp(n)
  let f = DoubleMLRDD::new(
    DoubleMLRDDData::new(x, y, d, score),
    bandwidth=0.6,
    cov_type="HC0",
  ).fit()
  let (_, wl, ml, el, levl) = v096_side_wls(
    x, y, score, 0.0, 0.6, -1.0, 1.0e-10,
  )
  let (_, wr, mr, er, levr) = v096_side_wls(x, y, score, 0.0, 0.6, 1.0, 1.0e-10)
  let v_l = v096_meat(wl, ml, el)
  let v_r = v096_meat(wr, mr, er)
  let m2 = v096_meat_leverage(wl, ml, el, levl, false) +
    v096_meat_leverage(wr, mr, er, levr, false)
  let m3 = v096_meat_leverage(wl, ml, el, levl, true) +
    v096_meat_leverage(wr, mr, er, levr, true)
  let hac0 = f.hac_se(SandwichKind::hc0())
  let hac1 = f.hac_se(SandwichKind::hc1())
  let hac2 = f.hac_se(SandwichKind::hc2())
  let hac3 = f.hac_se(SandwichKind::hc3())
  inspect(v096_rel_diff(hac2, m2.sqrt()) < 1.0e-12, content="true")
  inspect(v096_rel_diff(hac3, m3.sqrt()) < 1.0e-12, content="true")
  // HC0 itself carries no leverage correction, and all four are
  // ordered by how much they widen.
  inspect(v096_rel_diff(hac0, (v_l + v_r).sqrt()) < 1.0e-12, content="true")
  inspect(hac0 < hac2 && hac2 < hac3, content="true")
  // HC2 != HC1 here (the DML identity), and both are above HC0.
  inspect(v096_rel_diff(hac2, hac1) > 1.0e-3, content="true")
  inspect(hac1 > hac0, content="true")
}

///|
/// The constant-leverage case, where the per-observation
/// `(1 - h_k)` correction collapses to ONE common factor and the
/// closed forms are exact:
///
///     hac_se(HC2) / hac_se(HC0) == 1 / sqrt(1 - h)
///     hac_se(HC3) / hac_se(HC0) == 1 / (1 - h)
///
/// (Note this is NOT `hac_se(HC2) == hac_se(HC0)`: a leverage
/// strictly inside `(0, 1)` widens by `1 / sqrt(1 - h)`, so the
/// two are equal only in the degenerate `h = 0` limit.)
///
/// The fixture puts every local row at the same `|u| = 0.25` with
/// a CONSTANT covariate column, so within a side the design
/// `(1, u, 0)` has u constant and the local regression is rank 1 --
/// yet the leverage is exactly constant across all 200 rows
/// (`h = 1 / n_side = 0.01`), because a saturated fit of a
/// rank-deficient design has every row at the group leverage.
///
/// Two consequences, both asserted:
///
///   - the trace is the RANK, so 1 per side here: 2 in total, NOT
///     `2 * n_local_params() = 6`. This is the rank-vs-`k` point
///     the `leverage()` docs make, pinned on a number;
///   - the `1 / n_side` leverage is itself only accurate to about
///     1e-6 RELATIVE, because the local normal matrix is singular
///     and the `1e-10` ridge alone determines the inverse, so the
///     cancellation in the 2x2 determinant is amplified. The
///     closed-form identities are therefore checked against the
///     implementation's OWN `h` (where they are exact to rounding)
///     and the independent `h` is compared with a window that
///     admits this conditioning, not a tight one. A constant
///     full-rank design with constant leverage is not available
///     here: a regular simplex needs at least three covariates
///     (four equidistant points do not exist in a 2-dim centred
///     design), and a rank-deficient one is the only way to hold
///     `w_k` and `|u_k|` fixed.
test "rdd_hac_se_hc2_hc3_constant_leverage" {
  let n = 200
  let a = 0.25
  let xd = Array::make(n, 0.0)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let score = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let z = ((i * 5 % 9).to_double() - 4.0) / 4.0
    score[i] = if i < n / 2 { -a } else { a }
    d[i] = if i < n / 2 { 0.0 } else { 1.0 }
    y[i] = 1.5 + 0.7 * score[i] + 2.0 * d[i] + 0.25 * z
  }
  let x = Matrix::from_array(xd, n, 1)
  let f = DoubleMLRDD::new(
    DoubleMLRDDData::new(x, y, d, score),
    bandwidth=0.5,
    cov_type="HC0",
  ).fit()
  let (_, _, _, _, levl) = v096_side_wls(x, y, score, 0.0, 0.5, -1.0, 1.0e-10)
  let (_, _, _, _, levr) = v096_side_wls(x, y, score, 0.0, 0.5, 1.0, 1.0e-10)
  let lev = f.leverage()
  // Constant to the last bit, on the implementation's own numbers
  // and on the independent ones, across BOTH sides.
  let h = lev[0]
  let mut spread = 0.0
  for k = 0; k < lev.length(); k = k + 1 {
    let diff = (lev[k] - h).abs()
    if diff > spread {
      spread = diff
    }
  }
  inspect(spread == 0.0, content="true")
  let mut ind_spread = 0.0
  for k = 0; k < levl.length(); k = k + 1 {
    let diff = (levl[k] - levl[0]).abs()
    if diff > ind_spread {
      ind_spread = diff
    }
  }
  for k = 0; k < levr.length(); k = k + 1 {
    let diff = (levr[k] - levl[0]).abs()
    if diff > ind_spread {
      ind_spread = diff
    }
  }
  inspect(ind_spread == 0.0, content="true")
  // The independent value agrees to the conditioning of the
  // singular local normal matrix (about 1e-6 relative), NOT to
  // 1e-12 -- see the doc comment.
  inspect(v096_rel_diff(levl[0], h) < 1.0e-5, content="true")
  // The trace is the RANK: 1 per side, so 2, against
  // `2 * n_local_params() = 6`.
  let mut trace = 0.0
  for k = 0; k < lev.length(); k = k + 1 {
    trace = trace + lev[k]
  }
  inspect((trace - 2.0).abs() < 1.0e-5, content="true")
  // The closed forms, against the implementation's own h.
  let hac0 = f.hac_se(SandwichKind::hc0())
  let hac2 = f.hac_se(SandwichKind::hc2())
  let hac3 = f.hac_se(SandwichKind::hc3())
  inspect(
    v096_rel_diff(hac2 / hac0, 1.0 / (1.0 - h).sqrt()) < 1.0e-12,
    content="true",
  )
  inspect(v096_rel_diff(hac3 / hac0, 1.0 / (1.0 - h)) < 1.0e-12, content="true")
  // And HC2 != HC0: the correction widens rather than leaving the
  // number alone.
  inspect(hac2 > hac0, content="true")
}

// ---------------------------------------------------------------------------
// 5. THE LEVERAGE IS IN [0, 1) AND ITS TRACE IS THE RANK
// ---------------------------------------------------------------------------

///|
/// Every leverage is in `[0, 1)`, and the entries sum to the rank
/// of the local design. This is a genuine independent check: the
/// implementation computes `h_k` with `weighted_xtx_transpose` +
/// `inv_spd` and the test recomputes it with its own accumulation
/// order, so `max_diff < 1.0e-12` is evidence, and the trace is a
/// property neither path could fake by construction.
///
/// The design here is FULL RANK (the covariate varies), so the
/// trace is `2 * p1 = 6`. The trace is not exactly 6 because
/// `M = (X'WX + ridge I)^{-1}` is not an exact inverse: the
/// identity is `tr(M (X'WX)) = p1 - ridge * tr(M)`, so the sum
/// sits `ridge`-order BELOW the rank. Measured on this DGP:
/// 5.999999999787386, i.e. 2.1e-10 low -- hence the 1e-6 window.
test "rdd_leverage_is_in_unit_interval" {
  let n = 600
  let (x, y, d, score) = v096_dgp(n)
  let f = DoubleMLRDD::new(
    DoubleMLRDDData::new(x, y, d, score),
    bandwidth=0.6,
    cov_type="HC0",
  ).fit()
  let lev = f.leverage()
  let (nl, _, _, _, levl) = v096_side_wls(x, y, score, 0.0, 0.6, -1.0, 1.0e-10)
  let (nr, _, _, _, levr) = v096_side_wls(x, y, score, 0.0, 0.6, 1.0, 1.0e-10)
  inspect(lev.length() == nl + nr, content="true")
  let mut lo = 1.0e300
  let mut hi = -1.0e300
  let mut trace = 0.0
  let mut max_diff = 0.0
  let mut in_range = true
  for k = 0; k < lev.length(); k = k + 1 {
    let v = lev[k]
    if v < lo {
      lo = v
    }
    if v > hi {
      hi = v
    }
    trace = trace + v
    let own = if k < nl { levl[k] } else { levr[k - nl] }
    let diff = (v - own).abs()
    if diff > max_diff {
      max_diff = diff
    }
    if !(v >= 0.0 && v < 1.0) {
      in_range = false
    }
  }
  // Unit interval, and not a trivial one: a leverage pinned at 0
  // or at 1 would pass a bounds check and mean nothing.
  inspect(in_range, content="true")
  inspect(lo > 0.0, content="true")
  inspect(hi < 0.1, content="true")
  // Elementwise agreement with the independent computation.
  inspect(max_diff < 1.0e-12, content="true")
  // Trace == rank == 2 * p1 for a full-rank local design.
  let p1 = f.n_local_params()
  inspect(p1 == 3, content="true")
  inspect((trace - 2.0 * p1.to_double()).abs() < 1.0e-6, content="true")
}

// ---------------------------------------------------------------------------
// 6. CLUSTER-ROBUST: SINGLETON CLUSTERS == IID, POOLED CLUSTERS DIFFER
// ---------------------------------------------------------------------------

///|
/// With all-singleton clusters the cluster meat collapses to
/// `sum_k s_k^2`, i.e. the IID HC0 sandwich; pooled clusters
/// differ. The pooled value is additionally reproduced from the
/// test's own per-row scores `s_k = w_k m_k e_k` and cluster sums,
/// so the cluster formula is checked against an independent
/// computation rather than against a re-run of the same code.
///
/// Agreement with the IID value is to 1.0e-12, NOT bit-exact: this
/// path squares `s_k` as `s_k * s_k` where `hac_se` forms the
/// term as `w^2 m^2 e^2`, and it uses a Kahan-compensated
/// accumulator where `hac_se` uses a plain running sum.
test "rdd_singleton_cluster_hac_equals_iid" {
  let n = 600
  let (x, y, d, score) = v096_dgp(n)
  let f = DoubleMLRDD::new(
    DoubleMLRDDData::new(x, y, d, score),
    bandwidth=0.6,
    cov_type="HC0",
  ).fit()
  let n_local = f.n_local()
  let iid = f.hac_se(SandwichKind::hc0())
  let singleton = Array::makei(n_local, fn(i) { i })
  let cl = f.cluster_hac_se(singleton)
  inspect(v096_rel_diff(cl, iid) < 1.0e-12, content="true")
  // Pooled clusters really do differ, and by more than rounding.
  let pooled = Array::makei(n_local, fn(i) { i % 5 })
  let cl_pooled = f.cluster_hac_se(pooled)
  inspect(v096_rel_diff(cl_pooled, iid) > 1.0e-3, content="true")
  // Independent recomputation of the pooled cluster variance from
  // the test's own per-row scores.
  let (_, wl, ml, el, _) = v096_side_wls(x, y, score, 0.0, 0.6, -1.0, 1.0e-10)
  let (_, wr, mr, er, _) = v096_side_wls(x, y, score, 0.0, 0.6, 1.0, 1.0e-10)
  let s : Array[Double] = Array::make(n_local, 0.0)
  for k = 0; k < wl.length(); k = k + 1 {
    s[k] = wl[k] * ml[k] * el[k]
  }
  for k = 0; k < wr.length(); k = k + 1 {
    s[wl.length() + k] = wr[k] * mr[k] * er[k]
  }
  let n_clusters = 5
  let sums = Array::make(n_clusters, 0.0)
  let sizes = Array::make(n_clusters, 0)
  for k = 0; k < n_local; k = k + 1 {
    let c = pooled[k]
    sums[c] = sums[c] + s[k]
    sizes[c] = sizes[c] + 1
  }
  let mut var_ind = 0.0
  for c = 0; c < n_clusters; c = c + 1 {
    let nc = sizes[c]
    let scale = if nc <= 1 {
      1.0
    } else {
      nc.to_double() / (nc.to_double() - 1.0)
    }
    var_ind = var_ind + sums[c] * sums[c] * scale
  }
  inspect(v096_rel_diff(cl_pooled, var_ind.sqrt()) < 1.0e-12, content="true")
}

// ---------------------------------------------------------------------------
// 7. DGP SANITY
// ---------------------------------------------------------------------------

///|
/// Before trusting any HAC number, check that the fit is the fit we
/// think it is. Four independent cross-checks on the v0.96.0 DGP:
///
///   1. `n_local()` equals the test's own count of running-variable
///      values inside the bandwidth (not merely "> 0", which is
///      what the older `rdd_sharp_local_linear` fixture asserts);
///   2. the recovered jump is near the true 3.0, so the bandwidth
///      and the kernel are doing something sensible;
///   3. the relative standard error is in a plausible band -- this
///      is the check that catches a variance built on the wrong
///      moment (the v0.93 / v0.94 lesson: a wrong formula is
///      usually plausible, and implausibility is the cheapest
///      smoke alarm there is);
///   4. the HC0 SE matches the independent per-side
///      recomputation.
test "rdd_hac_se_dgp_sanity" {
  let n = 600
  let (x, y, d, score) = v096_dgp(n)
  let f = DoubleMLRDD::new(
    DoubleMLRDDData::new(x, y, d, score),
    bandwidth=0.6,
    cov_type="HC0",
  ).fit()
  // 1. Bandwidth-restricted sample size, counted independently.
  let mut expect_local = 0
  for i = 0; i < n; i = i + 1 {
    if score[i].abs() <= 0.6 {
      expect_local = expect_local + 1
    }
  }
  inspect(f.n_local() == expect_local, content="true")
  // Plausible, i.e. about 60% of the sample for bandwidth 0.6 on
  // a `(-1, 1)` running variable, and not the whole sample.
  inspect(f.n_local() > n / 2 && f.n_local() < n * 3 / 4, content="true")
  // 2. The recovered jump is the true one.
  inspect(v096_rel_diff(f.coef(), 3.0) < 0.01, content="true")
  // 3. The relative standard error is O(1) in the sense that
  // matters: small enough to be a credible SE on a jump of 3.0,
  // large enough that it is not a degenerate one.
  let rel = f.se() / f.coef().abs()
  inspect(rel > 1.0e-4 && rel < 0.5, content="true")
  // 4. And the number is the independently recomputed one.
  let (_, wl, ml, el, _) = v096_side_wls(x, y, score, 0.0, 0.6, -1.0, 1.0e-10)
  let (_, wr, mr, er, _) = v096_side_wls(x, y, score, 0.0, 0.6, 1.0, 1.0e-10)
  let independent = (v096_meat(wl, ml, el) + v096_meat(wr, mr, er)).sqrt()
  inspect(
    v096_rel_diff(f.hac_se(SandwichKind::hc0()), independent) < 1.0e-12,
    content="true",
  )
}

// ---------------------------------------------------------------------------
// 8. THE DEGENERATE LOCAL REGRESSION
// ---------------------------------------------------------------------------

///|
/// One local row per side with a 3-parameter design: the local
/// regression is rank-deficient, `fit` still returns a number
/// (`se = 1.78e-10`), and the reported leverage is
/// `h = 0.999999999825377` -- INSIDE `[0, 1)`, because the `1e-10`
/// ridge holds it just below 1. A pure "is `1 - h > 0`" check would
/// therefore pass and HC2 would divide the meat by `1.7e-10`,
/// reporting an SE inflated by `1 / sqrt(1.7e-10) ~ 1e5`.
///
/// So the guard is a DEGREES-OF-FREEDOM check (`n_side > p1`),
/// which must run before the leverage-range check. This test pins
/// the fixture: the design really is degenerate, HC0 still works
/// (it must, for the anchor to hold even here), and HC1 / HC2 /
/// HC3 abort.
test "rdd_hac_se_degenerate_local_regression_fixture" {
  let n = 4
  let xd = Array::make(n, 0.0)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let score = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    xd[i] = 0.1 * i.to_double()
    y[i] = 1.0 + 0.5 * i.to_double()
    d[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
  }
  score[0] = -0.005
  score[1] = 0.005
  score[2] = 0.02
  score[3] = 0.03
  let f = DoubleMLRDD::new(
    DoubleMLRDDData::new(Matrix::from_array(xd, n, 1), y, d, score),
    bandwidth=0.01,
    cov_type="HC0",
  ).fit()
  // The fixture is what we think: 1 row per side, 3 parameters.
  inspect(f.n_local() == 2, content="true")
  inspect(f.n_local_params() == 3, content="true")
  // The leverage is inside [0, 1) yet the design is rank-deficient
  // -- which is exactly why the range check is not sufficient.
  let lev = f.leverage()
  inspect(lev[0] > 0.999, content="true")
  inspect(lev[0] < 1.0, content="true")
  // HC0 still works (and still equals `se()`): the anchor does not
  // depend on the fit being well conditioned.
  inspect(f.hac_se(SandwichKind::hc0()) == f.se(), content="true")
}

///|
/// HC1 must abort when a side has no more rows than the design has
/// parameters: the `n / (n - k)` divisor would be zero or
/// negative.
test "panic_rdd_hac_se_hc1_rank_deficient_local_regression" {
  let n = 4
  let xd = Array::make(n, 0.0)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let score = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    xd[i] = 0.1 * i.to_double()
    y[i] = 1.0 + 0.5 * i.to_double()
    d[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
  }
  score[0] = -0.005
  score[1] = 0.005
  score[2] = 0.02
  score[3] = 0.03
  let f = DoubleMLRDD::new(
    DoubleMLRDDData::new(Matrix::from_array(xd, n, 1), y, d, score),
    bandwidth=0.01,
    cov_type="HC0",
  ).fit()
  let _ = f.hac_se(SandwichKind::hc1())
}

///|
/// HC2 must abort on the same fixture. Without the
/// degrees-of-freedom guard this would NOT abort: the leverage
/// `0.99999999983` is in `[0, 1)`, so `1 - h = 1.7e-10 > 0`
/// passes a range check and the reported SE would be inflated by
/// `~1e5` instead.
test "panic_rdd_hac_se_hc2_rank_deficient_local_regression" {
  let n = 4
  let xd = Array::make(n, 0.0)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let score = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    xd[i] = 0.1 * i.to_double()
    y[i] = 1.0 + 0.5 * i.to_double()
    d[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
  }
  score[0] = -0.005
  score[1] = 0.005
  score[2] = 0.02
  score[3] = 0.03
  let f = DoubleMLRDD::new(
    DoubleMLRDDData::new(Matrix::from_array(xd, n, 1), y, d, score),
    bandwidth=0.01,
    cov_type="HC0",
  ).fit()
  let _ = f.hac_se(SandwichKind::hc2())
}

///|
/// `hac_se` must ABORT, not return a homoskedastic number, when the
/// injected learner is not `LinearRegression`. `rdd_side` drops
/// the kernel weights on that path, so the HC0 state is all zeros
/// and a "polite" fallback would report a plausible-looking
/// homoskedastic SE under an HC0 name.
test "panic_rdd_hac_se_non_ols_learner" {
  let n = 600
  let (x, y, d, score) = v096_dgp(n)
  let f = DoubleMLRDD::new(
    DoubleMLRDDData::new(x, y, d, score),
    bandwidth=0.6,
    cov_type="HC0",
    ml_g=LearnerDispatch::constant(0.0),
  ).fit()
  let _ = f.hac_se(SandwichKind::hc0())
}

///|
/// `hac_se` must ABORT on a fuzzy fit. A fuzzy `se()` is the
/// delta-method variance of the RATIO `c = raw / jump`, which mixes
/// the Y-side and D-side local fits and a `1 / n_side^2`-scaled
/// cross-moment; no HC0/HC1/HC2/HC3 correction on the outcome-side
/// rows reproduces it, and making it reproduce would mean rewriting
/// `fit`'s fuzzy variance, which v0.96.0 does not do.
test "panic_rdd_hac_se_fuzzy_fit" {
  let n = 600
  let (x, y, d, score) = v096_dgp(n)
  let f = DoubleMLRDD::new(
    DoubleMLRDDData::new(x, y, d, score),
    bandwidth=0.6,
    fuzzy=true,
    cov_type="HC0",
  ).fit()
  let _ = f.hac_se(SandwichKind::hc0())
}

///|
/// `cluster_hac_se` must abort on an un-fit model, like every other
/// RDD accessor.
test "panic_rdd_cluster_hac_se_before_fit" {
  let n = 8
  let x = Matrix::from_array(Array::make(n, 0.0), n, 1)
  let data = DoubleMLRDDData::new(
    x,
    Array::make(n, 1.0),
    Array::make(n, 0.0),
    Array::make(n, 0.0),
  )
  let model = DoubleMLRDD::new(data, bandwidth=0.5)
  let _ = model.cluster_hac_se(Array::makei(4, fn(i) { i }))
}

// ---------------------------------------------------------------------------
// 9. THE MEMOIZE CACHE-HIT PATH
// ---------------------------------------------------------------------------

///|
/// The three arrays v0.96.0 added ride the memoize cache. On a
/// cache HIT `fit` returns without running any `rdd_side` call, so
/// if they were not written and restored the sandwich state would
/// be empty and `hac_se` would fail (or, worse, silently compute
/// from zeros). This mirrors `lpq_sandwich_after_memoize_cache_hit`
/// (v0.93.0) and the PQ / QTE equivalents.
test "rdd_hac_se_after_memoize_cache_hit" {
  let n = 600
  let (x, y, d, score) = v096_dgp(n)
  let data = DoubleMLRDDData::new(x, y, d, score)
  let fresh = DoubleMLRDD::new(data, bandwidth=0.6, cov_type="HC0").fit()
  let cached = DoubleMLRDD::new(data, bandwidth=0.6, cov_type="HC0")
    .enable_memoize()
    .fit()
  // First `fit` populated the cache; this one is served from it.
  inspect(cached.has_cache(), content="true")
  let again = DoubleMLRDD::new(data, bandwidth=0.6, cov_type="HC0")
    .enable_memoize()
    .fit()
  inspect(again.coef() == cached.coef(), content="true")
  inspect(again.se() == cached.se(), content="true")
  // The restored state is complete, so the anchor still holds and
  // the leverage is still there.
  inspect(cached.hac_se(SandwichKind::hc0()) == cached.se(), content="true")
  inspect(
    cached.hac_se(SandwichKind::hc0()) == fresh.hac_se(SandwichKind::hc0()),
    content="true",
  )
  inspect(cached.leverage().length() == cached.n_local(), content="true")
  let mut trace_a = 0.0
  for v in cached.leverage() {
    trace_a = trace_a + v
  }
  let mut trace_b = 0.0
  for v in fresh.leverage() {
    trace_b = trace_b + v
  }
  inspect(trace_a == trace_b, content="true")
}

// ---------------------------------------------------------------------------
// 10. REGRESSION PIN: `se()` / `coef()` ARE UNCHANGED BY v0.96.0
// ---------------------------------------------------------------------------

///|
/// Every number below was MEASURED ON v0.95.0 (commit bc33920),
/// BEFORE any source change, with the identical DGP helpers in
/// this file. `fit` now persists three extra per-observation
/// arrays and threads them through the `FitCache`; this test is the
/// pin that the persistence change did not perturb `fit`.
///
/// The comparisons are EXACT equality on `Double`, so this also
/// pins that the literals round-trip.
test "rdd_existing_se_unchanged" {
  let n = 600
  let (x, y, d, score) = v096_dgp(n)
  let data = DoubleMLRDDData::new(x, y, d, score)
  // cov_type = "homoskedastic", bandwidth 0.6.
  let hom = DoubleMLRDD::new(data, bandwidth=0.6, cov_type="homoskedastic").fit()
  inspect(hom.coef() == 3.0026661084381923, content="true")
  inspect(hom.se() == 0.004761198512179294, content="true")
  inspect(hom.n_local() == 360, content="true")
  // cov_type = "HC0", bandwidth 0.6.
  let hc0 = DoubleMLRDD::new(data, bandwidth=0.6, cov_type="HC0").fit()
  inspect(hc0.coef() == 3.0026661084381923, content="true")
  inspect(hc0.se() == 0.01138890815996386, content="true")
  // The same two fits with fuzzy = true (the delta-method path,
  // which `hac_se` refuses but `fit` must not change).
  let fz_hom = DoubleMLRDD::new(
    data,
    bandwidth=0.6,
    fuzzy=true,
    cov_type="homoskedastic",
  ).fit()
  inspect(fz_hom.coef() == 3.002666108448202, content="true")
  inspect(fz_hom.se() == 0.0047611985121969415, content="true")
  let fz_hc0 = DoubleMLRDD::new(data, bandwidth=0.6, fuzzy=true, cov_type="HC0").fit()
  inspect(fz_hc0.coef() == 3.002666108448202, content="true")
  inspect(fz_hc0.se() == 0.01138890816000257, content="true")
  // A TWO-covariate design, so `p1 = 4` and the local design is
  // full rank in a way the one-covariate fixture is not.
  let x2d = Array::make(n * 2, 0.0)
  let y2 = Array::make(n, 0.0)
  let d2 = Array::make(n, 0.0)
  let s2 = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u = (i.to_double() + 0.5) / 300.0 - 1.0
    let z = ((i * 13 % 17).to_double() - 8.0) / 8.0
    s2[i] = u
    d2[i] = if u >= 0.0 { 1.0 } else { 0.0 }
    y2[i] = 2.0 + 1.5 * u + 3.0 * d2[i] + (1.0 + 2.0 * u.abs()) * 0.4 * z
    x2d[i * 2] = 0.25 * z
    x2d[i * 2 + 1] = 0.1 * u
  }
  let two = DoubleMLRDD::new(
    DoubleMLRDDData::new(Matrix::from_array(x2d, n, 2), y2, d2, s2),
    bandwidth=0.6,
    cov_type="HC0",
  ).fit()
  inspect(two.n_local_params() == 4, content="true")
  inspect(two.coef() == 3.002666108437863, content="true")
  inspect(two.se() == 0.011388908159965516, content="true")
  // The anchor holds on the two-covariate design too, which is the
  // case where `hc0_e` (the full-design residual) genuinely differs
  // from `residuals` (the local-linear-only one).
  inspect(two.hac_se(SandwichKind::hc0()) == two.se(), content="true")
}
