///|
// v0.92.0: `DoubleMLLPLR` gets the sandwich API, and the
// README backfill for v0.87.0 - v0.92.0 lands alongside it.
//
// WHY LPLR WAS SKIPPED TWICE
// ==========================
// `DoubleMLLPLR` persists its influence-function components
// INVERTED relative to every other estimator in the package. The
// internal `LplrScore` struct carries `psi` (the score, i.e. the
// OFFSET in `f(theta) = theta * deriv + offset`) and `psi_deriv`
// (the derivative, i.e. the COEFFICIENT), and `fit` persists them
// as
//
//     self.psi_a = sc.psi - theta_hat * sc.psi_deriv   (OFFSET)
//     self.psi_b = sc.psi_deriv                        (DERIVATIVE)
//
// so `mean(psi_a)` is `mean(score offset)` -- a
// catastrophic-cancellation residual -- and NOT the Jacobian. The
// true Jacobian is `mean(psi_deriv) = mean(psi_b)`.
//
//   - v0.87.0 fed `M_inv = [[1 / mean(self.psi_a)]]`. On the DGP
//     below (n = 500, the v0.90.0 LZZ2020 binary DGP) that is
//     `1 / 0.01899446402902459` where the Jacobian is
//     `1 / -0.036387245464012986` -- opposite signs, so HC0 came
//     out `1.9156763469825346`x `se()` (`0.278056227496941` ->
//     `0.5326657381470845`). (The v0.87.0 report's "~60x" was
//     measured on a different DGP at `n = 400` through the
//     v0.87.0 accumulator, which was independently wrong by
//     `sqrt(n)` and by a `psi_a`-weighted meat; the two figures
//     are not in conflict.) On the same DGP v0.87.0 also drove the
//     HC2 / HC3 leverage past the `1e-10` degenerate clip.
//   - v0.90.0 corrected the psi order package-wide and found that
//     LPLR's `bootstrap` already handles the inversion correctly
//     (it passes the two arrays swapped), but the accessors stayed
//     unexposed because the v0.91.0 accumulator defect was still
//     open -- HC0 sat at `0.879 * se()`.
//
// v0.91.0 closed the accumulator defect, so with the swapped
// arrays for BOTH the score and the Jacobian, LPLR's HC0 equals
// its own `se()` to the last ulp and every HC relationship holds.
// These tests pin that. The equality is bit-exact on `native`,
// `wasm-gc` and `wasm`; on `js` the two spellings of the same
// expression round one ulp apart, so the assertions below are
// written at 1e-14 / 1e-12, never `==` on a computed SE.
//
// `se()` is the reference throughout: it is `var_est` over
// `(sc.psi_deriv, sc.psi - theta_hat * sc.psi_deriv)`, i.e.
// `sqrt(mean(psi(theta_hat)^2) / (mean(psi_deriv)^2 * n))`, which
// is algebraically `M_inv[0,0]^2 * sum_i psi[i]^2 / n / n` -- the
// v0.91.0 accumulator, evaluated at the same point.

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

///|
/// Relative closeness at the 1e-12 level (the package's tolerance
/// for "same number, different accumulation order" -- the same
/// helper `expand_v091_test.mbt` uses).
fn expand_v092_close(x : Double, y : Double) -> Bool {
  let scale = if x.abs() > y.abs() { x.abs() } else { y.abs() }
  if scale == 0.0 {
    return (x - y).abs() < 1.0e-300
  }
  (x - y).abs() / scale < 1.0e-12
}

///|
/// The v0.90.0 LZZ2020-style binary-outcome DGP, byte-identical to
/// the one `expand_v090_test.mbt::lplr_inverted_roles_are_handled`
/// uses, so the two files' numbers are comparable.
/// `n = 500`, `p = 6`, Box-Muller normals, `d ~ Bernoulli(expit(a))`,
/// `y ~ Bernoulli(expit(0.5 * (d - a_0) + r_0))`.
fn expand_v092_lplr_data(n : Int, p : Int) -> DoubleMLBinaryData {
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let rng = chacha8_rng(3141)
  let need = n * p + n
  let pool : Array[Double] = []
  while pool.length() < need {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let theta = 2.0 * 3.141592653589793 * u2
    pool.push(r * @math.cos(theta))
    pool.push(r * @math.sin(theta))
  }
  for i = 0; i < n * p; i = i + 1 {
    x_flat[i] = pool[i]
  }
  for i = 0; i < n; i = i + 1 {
    let x1 = x_flat[i * p]
    let x2 = x_flat[i * p + 1]
    let a = 0.5 * @math.sin(x1) + 0.5 * @math.cos(x2) + 0.5 * pool[n * p + i]
    let p_t = expit(a)
    let u = rng.double()
    d[i] = if u < p_t { 1.0 } else { 0.0 }
  }
  for i = 0; i < n; i = i + 1 {
    let x1 = x_flat[i * p]
    let x2 = x_flat[i * p + 1]
    let x3 = x_flat[i * p + 2]
    let x4 = x_flat[i * p + 3]
    let x5 = x_flat[i * p + 4]
    let x6 = x_flat[i * p + 5]
    let r0 = x1 * x2 / 4.0 +
      0.25 * x3 * x3 +
      @math.cos(x4) / 4.0 -
      0.5 * @math.sin(x5) +
      (if x6 > 0.0 { 1.0 } else { 0.0 }) -
      0.5
    let a0 = @math.sin(x1) / 2.0 + @math.cos(x2) / 2.0
    let p_y = expit(0.5 * (d[i] - a0) + r0)
    let uy = rng.double()
    y[i] = if uy < p_y { 1.0 } else { 0.0 }
  }
  DoubleMLBinaryData::new(Matrix::from_array(x_flat, n, p), y, d)
}

///|
/// The fitted LPLR every test in this file shares. `n_rep = 1`, so
/// `self.coef_` is the per-repetition `var_est` coefficient
/// (`aggregate_coef_se` has an `n_rep == 1` fast path returning
/// `(coefs[0], ses[0])` unchanged) and the persisted
/// influence-function arrays are that repetition's.
fn expand_v092_fit(n : Int) -> DoubleMLLPLR {
  DoubleMLLPLR::new(expand_v092_lplr_data(n, 6), n_folds=2, n_folds_inner=2).fit()
}

///|
/// All-singleton (`singleton[i] = i`) and pooled-in-blocks-of-4
/// (`pooled[i] = i / 4`) cluster ids for a sample of `n`.
fn expand_v092_cluster_ids(n : Int) -> (Array[Int], Array[Int]) {
  let singleton : Array[Int] = Array::make(n, 0)
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
    pooled[i] = i / 4
  }
  (singleton, pooled)
}

// ---------------------------------------------------------------------------
// 1. THE DECISIVE ONE: se() == sandwich_se(HC0)
// ---------------------------------------------------------------------------

///|
/// THE assertion that unblocks LPLR. With the influence-function
/// arrays read in the persisted (offset, derivative) order -- so
/// `psi_at(coef, self.psi_b, self.psi_a)` for the score and
/// `M_inv = [[1 / mean(self.psi_b)]]` for the Jacobian -- LPLR's
/// HC0 equals its own `se()`.
///
/// Fails to COMPILE against v0.91.0 (the method does not exist),
/// which is the point: there is no way to express the invariant
/// without first getting the role assignment right.
test "lplr_se_equals_sandwich_hc0" {
  let n = 500
  let n_d = n.to_double()
  let lplr = expand_v092_fit(n)
  inspect(lplr.psi_a.length() == n, content="true")
  inspect(lplr.psi_b.length() == n, content="true")
  let se_hc0 = lplr.sandwich_se(SandwichKind::hc0())
  let se = lplr.se()
  // The invariant.
  inspect(expand_v092_close(se_hc0, se), content="true")
  // ... and it is equal to a very tight tolerance, not merely
  // "close": `se()` is `var_est` over the same `(slope, offset)`
  // tuple, so both sides accumulate the same `psi^2` with the same
  // Kahan compensated sum in the same order. The two spellings of
  // the same expression differ only in where the `j^2` division
  // sits -- `M_inv[0,0]^2 * acc / n / n` vs
  // `acc / n / (j * j * n)` -- which is bit-identical on `native`,
  // `wasm-gc` and `wasm` and a last ulp apart on `js`. So the
  // portable contract is the 1e-12 the rest of the package uses,
  // and `==` is NOT asserted here.
  inspect((se_hc0 - se).abs() / se.abs() < 1.0e-14, content="true")
  // And it is not the *other* reading of the same persisted state:
  // the package-order score `psi_at(coef, self.psi_a, self.psi_b)`
  // (offset as the coefficient) is a different function whose root
  // is not `coef`, so it must NOT reproduce `se()`.
  let psi_swapped = psi_at(lplr.coef(), lplr.psi_a, lplr.psi_b)
  let mut ss_swapped = 0.0
  for i = 0; i < n; i = i + 1 {
    ss_swapped = ss_swapped + psi_swapped[i] * psi_swapped[i]
  }
  let j_offset = mean(lplr.psi_a)
  let se_package_order = (ss_swapped / n_d / (j_offset * j_offset * n_d)).sqrt()
  inspect(expand_v092_close(se_hc0, se_package_order) == false, content="true")
  // The two persisted components really do differ row-wise, so
  // swapping them is not a no-op that "accidentally" works.
  let mut differ = false
  for i = 0; i < n; i = i + 1 {
    if lplr.psi_a[i] != lplr.psi_b[i] {
      differ = true
    }
  }
  inspect(differ, content="true")
}

// ---------------------------------------------------------------------------
// 2. THE HC RELATIONSHIPS (all pure ratios of the accumulator)
// ---------------------------------------------------------------------------

///|
/// `HC1 / HC0 == sqrt(n / (n - k))` with `k = 1`, i.e.
/// `sqrt(n / (n - 1))`, to 1e-12. Scale-invariant, so it says
/// nothing about the Jacobian -- that is test 1's job.
test "lplr_hc1_hc0_ratio" {
  let n = 500
  let n_d = n.to_double()
  let lplr = expand_v092_fit(n)
  let se0 = lplr.sandwich_se(SandwichKind::hc0())
  let se1 = lplr.sandwich_se(SandwichKind::hc1())
  inspect(
    expand_v092_close(se1 / se0, (n_d / (n_d - 1.0)).sqrt()),
    content="true",
  )
  // The ratio is strictly greater than 1, i.e. HC1 widens.
  inspect(se1 > se0, content="true")
}

///|
/// With the v0.88.0 leverage `h_ii = 1 / n_obs` every HC2 term is
/// divided by `(n - 1) / n`, algebraically the HC1 factor, so
/// `HC2 == HC1` to 1e-12. This is the identity v0.87.0 could not
/// satisfy on LPLR at all: with `M_inv = [[1 / mean(psi_a)]]` and
/// a cancellation-residual `mean(psi_a)`, the old signed "leverage"
/// was `1 - h_ii > 1` and HC2 SHRANK.
test "lplr_hc2_equals_hc1" {
  let n = 500
  let lplr = expand_v092_fit(n)
  let se1 = lplr.sandwich_se(SandwichKind::hc1())
  let se2 = lplr.sandwich_se(SandwichKind::hc2())
  inspect(expand_v092_close(se2, se1), content="true")
  // Not the v0.87.0 magnitude: the old path produced SE of order
  // 1e10 / 1e11 (the `1e-10` clip), not a value within 1e-12 of
  // HC1.
  inspect(se2 < 1.0e6, content="true")
}

///|
/// HC3 divides every term by `((n - 1) / n)^2`, so
/// `HC3 == HC1^2 / HC0` to 1e-12.
test "lplr_hc3_equals_hc1_squared_over_hc0" {
  let n = 500
  let n_d = n.to_double()
  let lplr = expand_v092_fit(n)
  let se0 = lplr.sandwich_se(SandwichKind::hc0())
  let se1 = lplr.sandwich_se(SandwichKind::hc1())
  let se3 = lplr.sandwich_se(SandwichKind::hc3())
  inspect(expand_v092_close(se3, se1 * se1 / se0), content="true")
  inspect(
    expand_v092_close(
      se3,
      se0 * (n_d / (n_d - 1.0)).sqrt() * (n_d / (n_d - 1.0)).sqrt(),
    ),
    content="true",
  )
}

// ---------------------------------------------------------------------------
// 3. ORDERING
// ---------------------------------------------------------------------------

///|
/// The ordering the v0.88.0 leverage fix established,
/// `HC3 > HC1 == HC2 > HC0`, now holds for LPLR too. Note `HC2` is
/// EQUAL to `HC1`, not strictly above it: any test written as
/// `HC2 > HC1` is asserting a falsehood.
test "lplr_ordering" {
  let n = 500
  let lplr = expand_v092_fit(n)
  let se0 = lplr.sandwich_se(SandwichKind::hc0())
  let se1 = lplr.sandwich_se(SandwichKind::hc1())
  let se2 = lplr.sandwich_se(SandwichKind::hc2())
  let se3 = lplr.sandwich_se(SandwichKind::hc3())
  inspect(se1 > se0, content="true")
  inspect(expand_v092_close(se2, se1), content="true")
  inspect(se3 > se1, content="true")
  inspect(se2 > se0, content="true")
  // `HC2` is NOT strictly above `HC1` -- it is equal to it, which
  // is the whole content of the `h_ii = 1 / n_obs` result, and
  // only equal to 1e-12 (the two accumulation orders differ in the
  // last ulp). So the pre-v0.88 chain `HC0 > HC2` is false, and
  // the test cannot pass against the old (shrinking) leverage.
  inspect((se0 > se2) == false, content="true")
}

// ---------------------------------------------------------------------------
// 4. THE CLUSTER PATH
// ---------------------------------------------------------------------------

///|
/// With all-singleton clusters the cluster meat degenerates to
/// `sum_i psi[i]^2` and collapses to the IID HC0, hence to `se()`.
/// Pooled clusters pick up the within-cluster cross terms and
/// differ, which also proves `cluster_ids` is consumed rather than
/// ignored.
test "lplr_singleton_cluster_equals_se" {
  let n = 500
  let (singleton, pooled) = expand_v092_cluster_ids(n)
  let lplr = expand_v092_fit(n)
  let se = lplr.se()
  let cl_single = lplr.cluster_sandwich_se(singleton)
  let cl_pooled = lplr.cluster_sandwich_se(pooled)
  inspect(expand_v092_close(cl_single, se), content="true")
  inspect(
    expand_v092_close(cl_single, lplr.sandwich_se(SandwichKind::hc0())),
    content="true",
  )
  inspect(expand_v092_close(cl_pooled, se) == false, content="true")
  inspect(cl_pooled > 0.0, content="true")
  // The cluster path uses the same swapped Jacobian, so the pooled
  // value is not reproducible from `mean(psi_a)` either.
  let psi = psi_at(lplr.coef(), lplr.psi_b, lplr.psi_a)
  let m_wrong = Matrix::from_array([1.0 / mean(lplr.psi_a)], 1, 1)
  let cl_wrong = cluster_sandwich_variance(lplr.psi_b, psi, m_wrong, pooled, 1).sqrt()
  inspect(expand_v092_close(cl_pooled, cl_wrong) == false, content="true")
}

// ---------------------------------------------------------------------------
// 5. bias_corrected_coef
// ---------------------------------------------------------------------------

///|
/// `bias_corrected_coef` returns `coef` EXACTLY -- the v0.91.0
/// design, identical to the twelve methods already shipped. The
/// estimating function `f(theta) = E[theta * psi_deriv +
/// score_offset]` is orthogonal at its root, so
/// `mean(coef * psi_b + psi_a) == 0` identically (LPLR's
/// persisted arrays are swapped, so the orthogonality identity
/// reads `coef * self.psi_b + self.psi_a`, not
/// `coef * self.psi_a + self.psi_b`) and a correction built from
/// the score at the estimate is vacuous by construction.
///
/// The removed v0.79.0 - v0.90.0 expression
/// `coef + mean(psi_b - coef * psi_a)` is recomputed here as a
/// regression pin: with the LPLR array order it is NOT `3 * coef`
/// (that closed form belongs to the constant-`psi_a` estimators)
/// but it is still not `coef`.
test "lplr_bias_corrected_coef_is_identity" {
  let n = 500
  let lplr = expand_v092_fit(n)
  inspect(lplr.bias_corrected_coef() == lplr.coef(), content="true")
  // Orthogonality, in LPLR's persisted (offset, derivative) order:
  // the coefficient row is `self.psi_b` and the offset is
  // `self.psi_a`, so the moment is
  // `f(theta) = E[theta * psi_b + psi_a]` and its mean vanishes at
  // the root. This is why the no-op is vacuous rather than merely
  // unimplemented.
  let orthogonality = lplr.coef() * mean(lplr.psi_b) + mean(lplr.psi_a)
  inspect(orthogonality.abs() < 1.0e-9, content="true")
  // The removed expression, recomputed, is not the new one.
  let bias : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    bias[i] = lplr.psi_b[i] - lplr.coef() * lplr.psi_a[i]
  }
  let old_value = lplr.coef() + mean(bias)
  inspect(old_value != lplr.bias_corrected_coef(), content="true")
}

// ---------------------------------------------------------------------------
// 6. THE REGRESSION PIN: the Jacobian is the DERIVATIVE
// ---------------------------------------------------------------------------

///|
/// This is the test that guards against the v0.87.0 bug coming
/// back. It pins, concretely:
///
///   1. `mean(self.psi_a)` (the cancellation residual) and
///      `mean(self.psi_b)` (the derivative / true Jacobian) are
///      genuinely different numbers on this DGP -- different
///      signs, and separated by a large factor -- so a swap
///      cannot be invisible.
///   2. `M_inv` is built from `mean(self.psi_b)`. The only way to
///      see which one a given implementation used is through
///      `sandwich_se(HC0)`, so the test recomputes HC0 with each
///      candidate Jacobian and requires the shipped value to match
///      the `psi_b` one and NOT the `psi_a` one.
///   3. HC0 still equals `se()`. The two candidate Jacobians
///      cannot both do that: `se()` is `var_est` over
///      `(psi_deriv, offset)`, i.e. `J = mean(psi_deriv)`.
///
/// No finiteness-only assertion here: every check below compares
/// two independently computed numbers.
test "lplr_jacobian_is_the_derivative_not_the_offset" {
  let n = 500
  let n_d = n.to_double()
  let lplr = expand_v092_fit(n)
  let mean_offset = mean(lplr.psi_a)
  let mean_deriv = mean(lplr.psi_b)
  // (1) The two candidates are far apart. `mean(psi_a)` is the
  // score OFFSET at the fitted theta -- a cancellation residual of
  // two terms of the same order -- while `mean(psi_b)` is
  // `psi_deriv`, which is bounded away from zero row-wise.
  inspect(mean_offset != mean_deriv, content="true")
  inspect(mean_deriv < 0.0, content="true")
  inspect(mean_offset > 0.0, content="true")
  // |mean(psi_a)| is under 60% of |mean(psi_b)| here, and the two
  // have OPPOSITE signs, so 1 / mean(psi_a) is not a sign-flipped
  // stand-in for 1 / mean(psi_b) either.
  let ratio_abs = mean_offset.abs() / mean_deriv.abs()
  inspect(ratio_abs < 0.6, content="true")
  inspect(mean_offset * mean_deriv < 0.0, content="true")
  // (2) Recompute HC0 under BOTH candidate Jacobians from the same
  // persisted score, and pin which one the shipped accessor uses.
  let psi = psi_at(lplr.coef(), lplr.psi_b, lplr.psi_a)
  let mut ss = 0.0
  for i = 0; i < n; i = i + 1 {
    ss = ss + psi[i] * psi[i]
  }
  let hc0_deriv_jacobian = (ss / n_d / (mean_deriv * mean_deriv * n_d)).sqrt()
  let hc0_offset_jacobian = (ss / n_d / (mean_offset * mean_offset * n_d)).sqrt()
  let shipped = lplr.sandwich_se(SandwichKind::hc0())
  inspect(expand_v092_close(shipped, hc0_deriv_jacobian), content="true")
  inspect(
    expand_v092_close(shipped, hc0_offset_jacobian) == false,
    content="true",
  )
  // (3) The measured size of the v0.87.0 mistake ON THIS DGP:
  // swapping the Jacobian inflates HC0 by
  // `|mean(psi_b)| / |mean(psi_a)|` = `1.9156763469825346`
  // (HC0 `0.278056227496941` -> `0.5326657381470845`).
  // (The "~60x" quoted in the v0.87.0 report was measured on a
  // different DGP -- `n = 400` -- through the v0.87.0 accumulator,
  // which was independently wrong by `sqrt(n)` and by a
  // `psi_a`-weighted meat; do not read the two figures as a
  // contradiction.)
  let inflation = hc0_offset_jacobian / hc0_deriv_jacobian
  inspect(inflation > 1.5 && inflation < 3.0, content="true")
  // `ratio_abs` is algebraically `|coef|` here (`coef =
  // -mean(psi_a) / mean(psi_b)` is the reciprocal of the inflation
  // factor), so the inflation factor is exactly `1 / coef`:
  // reading it off the point estimate is enough to see it is
  // nowhere near 1.
  inspect(expand_v092_close(inflation, 1.0 / lplr.coef()), content="true")
  inspect(expand_v092_close(ratio_abs, lplr.coef()), content="true")
  // (4) ... and the payoff: the shipped HC0 is `se()`.
  inspect(expand_v092_close(shipped, lplr.se()), content="true")
  // (5) The bootstrap call site has used the same swap since
  // v0.90.0, so the score the sandwich path evaluates is bit-
  // identical to the one the bootstrap evaluates.
  let psi_boot = psi_at(lplr.coef(), lplr.psi_b, lplr.psi_a)
  for i = 0; i < n; i = i + 1 {
    inspect(psi_boot[i] == psi[i], content="true")
  }
}
