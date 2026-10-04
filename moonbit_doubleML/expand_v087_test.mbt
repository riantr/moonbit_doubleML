///|
// v0.87.0+: white-box tests for the sandwich-variance expand
// (SSM / PLPR / DID cross-section / DID CS binary) on top of
// the shared `sandwich_variance(kind, ...)` dispatch added in
// v0.86.0.
//
// NOT covered here: `DoubleMLLPLR` (deliberately skipped, same
// call as `DoubleMLLPQ` in v0.86.0). LPLR persists its
// influence-function components in the OPPOSITE field order to
// every other estimator in the package -- `self.psi_a` is the
// score OFFSET at `theta_hat` (`sc.psi - theta_hat *
// sc.psi_deriv`) and `self.psi_b` is the slope
// (`sc.psi_deriv`, i.e. the actual `d/dtheta` term). The
// package-wide sandwich convention is
//
//     psi[i]   = psi_a[i] + coef * psi_b[i]
//     M_inv    = [[1 / mean(psi_a)]]
//     var(HC0) = M_inv[0,0]^2 * sum_i (psi_a[i] * psi[i])^2 / n
//
// which requires `psi_a` to carry the Jacobian row. For LPLR
// `mean(psi_a)` is a catastrophic-cancellation residual
// (`mean(score) - theta_hat * mean(deriv)`, two nearly equal
// terms), NOT the Jacobian: on the LZZ2020 DGP at
// `n = 400` it evaluates to `+0.0134` while the true Jacobian
// `mean(sc.psi_deriv)` is strictly negative. Feeding that into
// `M_inv` inflates HC0 by ~60x over LPLR's own analytic `se()`
// (and in v0.87.0 it also drove the HC2 / HC3 leverage past the
// `1.0e-10` clip, returning `6.4e10` / `6.4e10^2` instead of a
// variance). A wrong number
// is worse than a missing one, so LPLR is skipped pending a
// follow-up that either (a) swaps the persisted field order to
// match the package norm, or (b) gets an explicitly
// role-swapped sandwich that passes `self.psi_b` as the
// derivative row and `[[1 / mean(self.psi_b)]]` as `M_inv`.
//
// What these tests assert (and why it is not the vacuous
// "the number is finite" trap that the v0.85.0 worker
// flagged):
//   1. The returned HC0 SE reproduces, to 1e-12 relative, an
//      INDEPENDENTLY recomputed
//      `M_inv^2 * sum_i (psi_a[i] * psi[i])^2 / n` -- a
//      function returning a constant, or reusing the wrong
//      `psi` / the wrong `M_inv`, fails this.
//   2. `se(HC1) / se(HC0) == sqrt(n / (n - 1))` to 1e-12 --
//      the exact HC1 finite-sample identity, so a swapped
//      HC1 / HC2 arm fails.
//   3. `mean(psi_a) < 0` is asserted explicitly, then the
//      HC2 / HC3 leverage corrections are pinned BOTH against
//      an independent recomputation of the `(1 - h_ii)` and
//      `(1 - h_ii)^2` divisors AND against the direction the
//      corrections must move in. Since v0.88.0 the leverage is
//      the constant mean-regression diagonal `h_ii = 1 / n`,
//      so HC2 == HC1 and HC3 == HC1^2 / HC0 exactly and the
//      asserted ordering is `HC1 == HC2 > HC0` with
//      `HC3 > HC2` -- a monotonic widening, as
//      MacKinnon (2012) sec 5.4 requires. (v0.79.0 - v0.87.0
//      used the signed `h_ii = psi_a[i]^2 * M_inv`, negative
//      here, so the divisors exceeded 1 and the corrections
//      shrank: the old asserted ordering was
//      `HC1 > HC0 > HC2 > HC3`. For the three estimators
//      whose `psi_a` is the constant `-1` (SSM, both DID
//      variants) the divisors are now exactly `n / (n - 1)`
//      and `(n / (n - 1))^2`.)
//   4. `cluster_sandwich_se` with all-singleton clusters
//      equals `sandwich_se(HC0)` EXACTLY (singleton clusters
//      contribute their raw `(psi_a * psi)^2` with no
//      jackknife factor, algebraically the HC0 accumulation),
//      while a pooled cluster assignment gives a strictly
//      different finite value -- proving `cluster_ids` is
//      actually consumed and not ignored.
//   5. `bias_corrected_coef` equals
//      `coef + mean(psi_b - coef * psi_a)` to 1e-12, and for
//      SSM the closed-form reduction `2 * coef + mean(psi_b)`
//      (equivalently `3 * coef`, since SSM's
//      `theta_hat = mean(psi_b)`).

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

///|
/// Per-observation influence function `psi[i] = psi_a[i] +
/// coef * psi_b[i]`, recomputed in the test from the fitted
/// estimator's persisted IF components.
fn expand_v087_psi(
  psi_a : Array[Double],
  psi_b : Array[Double],
  coef : Double,
  n_obs : Int,
) -> Array[Double] {
  let psi : Array[Double] = Array::make(n_obs, 0.0)
  for i = 0; i < n_obs; i = i + 1 {
    psi[i] = psi_a[i] + coef * psi_b[i]
  }
  psi
}

///|
/// Independent recomputation of the HC0 variance
/// `m_val^2 * sum_i (psi_a[i] * psi[i])^2 / n_obs`, used as
/// the reference the estimator methods must match. Deliberately
/// NOT routed through `sandwich_variance_hc0` so a regression in
/// the shared helper cannot make both sides move together.
fn expand_v087_ref_hc0(
  psi_a : Array[Double],
  psi : Array[Double],
  m_val : Double,
  n_obs : Int,
) -> Double {
  let mut acc = 0.0
  for i = 0; i < n_obs; i = i + 1 {
    let prod = psi_a[i] * psi[i]
    acc = acc + prod * prod
  }
  let m2 = m_val * m_val
  m2 * acc / n_obs.to_double()
}

///|
/// Independent recomputation of the leverage-corrected HC2
/// (`power = 1`) and HC3 (`power = 2`) variances,
/// `m_val^2 * sum_i (psi_a[i] * psi[i])^2 / (1 - h_ii)^power / n`
/// with the mean-regression leverage `h_ii = 1 / n_obs` (the
/// projection-matrix diagonal of the intercept-only,
/// equally-weighted mean regression implicit in the moment
/// `E[psi_a * psi(theta)] = 0`) and the same `1.0e-10`
/// degenerate-input clip the package applies.
///
/// v0.87.0 used the signed `h_ii = psi_a[i] * M_inv *
/// psi_a[i]` here, which is negative under
/// `M_inv = [[1 / mean(psi_a)]]` and made HC2 / HC3 shrink;
/// see `sandwich.mbt` and `expand_v088_test.mbt`.
fn expand_v087_ref_leverage(
  psi_a : Array[Double],
  psi : Array[Double],
  m_val : Double,
  n_obs : Int,
  power : Int,
) -> Double {
  let eps : Double = 1.0e-10
  let mut acc = 0.0
  let h_ii = 1.0 / n_obs.to_double()
  for i = 0; i < n_obs; i = i + 1 {
    let pa = psi_a[i]
    let one_minus_h = if 1.0 - h_ii < eps { eps } else { 1.0 - h_ii }
    let mut denom = one_minus_h
    if power == 2 {
      denom = one_minus_h * one_minus_h
    }
    let prod = pa * psi[i]
    acc = acc + prod * prod / denom
  }
  let m2 = m_val * m_val
  m2 * acc / n_obs.to_double()
}

///|
/// Relative closeness of two non-zero values (guards against a
/// near-zero reference blowing up an absolute tolerance).
fn expand_v087_close(x : Double, y : Double) -> Bool {
  let scale = if x.abs() > y.abs() { x.abs() } else { y.abs() }
  if scale == 0.0 {
    return (x - y).abs() < 1.0e-300
  }
  (x - y).abs() / scale < 1.0e-12
}

///|
/// Simple MAR (selection-on-observed-unobservables) panel for
/// `DoubleMLSSM`: `d ~ Bernoulli(1/2)`,
/// `s = 1{d + 0.3 x_0 + v > 0}`, `y = d + 0.3 x . d + noise`,
/// with `y` only meaningful where `s = 1`. True ATT = 1.
fn expand_v087_ssm_data(n : Int, p : Int) -> DoubleMLSSMData {
  let rng = chacha8_rng(2222)
  let pool : Array[Double] = []
  while pool.length() < n * p + n {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let t = 2.0 * 3.141592653589793 * u2
    pool.push(r * @math.cos(t))
    pool.push(r * @math.sin(t))
  }
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  for i = 0; i < n * p; i = i + 1 {
    x_flat[i] = pool[i]
  }
  let v : Array[Double] = Array::make(n, 0.0)
  let mut idx = n * p
  for i = 0; i < n; i = i + 1 {
    v[i] = pool[idx]
    idx = idx + 1
  }
  let x = Matrix::from_array(x_flat, n, p)
  let d : Array[Double] = Array::make(n, 0.0)
  let s : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    let mut linear = d[i] + 0.3 * x.get(i, 0) + v[i]
    for j = 1; j < p; j = j + 1 {
      linear = linear + 0.05 * x.get(i, j)
    }
    s[i] = if linear > 0.0 { 1.0 } else { 0.0 }
    let mut y_part = 1.0 * d[i]
    for j = 0; j < p; j = j + 1 {
      y_part = y_part + 0.3 * x.get(i, j) * d[i]
    }
    y[i] = y_part + 0.3 * (rng.double() - 0.5)
  }
  DoubleMLSSMData::new(x, y, d, s)
}

///|
/// Two-cohort / THREE-period binary-treatment panel for
/// `DoubleMLDIDCSBinary` with a NOISY outcome (so `psi_b` is not
/// degenerate): unit-level time-invariant `x`, treated cohort
/// gets `d = 1` from period 1 on, true ATT(g=1, t=1) = 1.
///
/// Three periods on purpose: the estimator's panel subset keeps
/// only `t = t_value_pre` and `t = t_value_eval` rows, so the
/// post-subset sample (2 / 3 of the panel) is strictly smaller
/// than `n_obs_panel()`. That pins the fact that the sandwich
/// sample follows `psi_a.length()`, not the raw panel width.
fn expand_v087_cs_binary_data(n_per_cohort : Int, p : Int) -> DoubleMLDIDCSData {
  let n_units = n_per_cohort * 2
  let n_periods = 3
  let n_rows = n_units * n_periods
  let x_flat : Array[Double] = Array::make(n_rows * p, 0.0)
  let y : Array[Double] = Array::make(n_rows, 0.0)
  let d : Array[Double] = Array::make(n_rows, 0.0)
  let t_arr : Array[Int] = Array::make(n_rows, 0)
  let id_arr : Array[Int] = Array::make(n_rows, 0)
  let g_arr : Array[Int] = Array::make(n_rows, 0)
  let rng = chacha8_rng(7)
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
      let effect = if cohort > 0 && k >= cohort { 1.0 } else { 0.0 }
      y[row] = effect + 0.3 * xu[0] + 0.2 * xu[1] + 0.6 * (rng.double() - 0.5)
    }
  }
  DoubleMLDIDCSData::new(
    Matrix::from_array(x_flat, n_rows, p),
    y,
    d,
    t_arr,
    id_arr,
    g_arr,
  )
}

// ---------------------------------------------------------------------------
// Shared ordering (fixed synthetic input)
// ---------------------------------------------------------------------------

///|
test "sandwich_expand_v087_ordering" {
  // Fixed synthetic input, no estimator involved: a constant
  // `psi_a = -1` row (the IRM / SSM / DID ATT leverage case) with
  // a deliberately non-symmetric `psi`. This pins the ordering
  // on the shared dispatch so the four new estimator methods can
  // only agree with it:
  //   HC1 = HC0 * sqrt(n / (n - 1))          (widen)
  //   HC2 = HC0 * n / (n - 1) = HC1          (h_ii = 1 / n)
  //   HC3 = HC0 * (n / (n - 1))^2 = HC1^2/HC0
  // i.e. HC1 == HC2 > HC0 and HC3 > HC2.
  let n = 64
  let psi_a : Array[Double] = Array::make(n, -1.0)
  let psi : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    psi[i] = if i % 3 == 0 { 1.0 } else if i % 3 == 1 { -0.5 } else { 0.25 }
  }
  let m_inv = Matrix::from_array([-1.0], 1, 1)
  let v0 = sandwich_variance(SandwichKind::hc0(), psi_a, psi, m_inv, n, 1)
  let v1 = sandwich_variance(SandwichKind::hc1(), psi_a, psi, m_inv, n, 1)
  let v2 = sandwich_variance(SandwichKind::hc2(), psi_a, psi, m_inv, n, 1)
  let v3 = sandwich_variance(SandwichKind::hc3(), psi_a, psi, m_inv, n, 1)
  inspect(v0 > 0.0, content="true")
  // HC1 finite-sample identity.
  let expected_scale = n.to_double() / (n.to_double() - 1.0)
  inspect(expand_v087_close(v1, v0 * expected_scale), content="true")
  // Mean-regression leverage h_ii = 1 / n -> divisors
  // (n - 1) / n and ((n - 1) / n)^2.
  inspect(expand_v087_close(v2, v0 * expected_scale), content="true")
  inspect(
    expand_v087_close(v3, v0 * expected_scale * expected_scale),
    content="true",
  )
  inspect(v1 > v0, content="true")
  inspect(v2 > v0, content="true")
  inspect(v3 > v2, content="true")
  inspect(v2 == v1, content="true")
  inspect(expand_v087_close(v3, v1 * v1 / v0), content="true")
  // Independent recomputation must agree with the dispatch.
  inspect(
    expand_v087_close(v0, expand_v087_ref_hc0(psi_a, psi, -1.0, n)),
    content="true",
  )
  inspect(
    expand_v087_close(v2, expand_v087_ref_leverage(psi_a, psi, -1.0, n, 1)),
    content="true",
  )
  inspect(
    expand_v087_close(v3, expand_v087_ref_leverage(psi_a, psi, -1.0, n, 2)),
    content="true",
  )
  // Singleton clusters are algebraically the HC0 accumulation;
  // pooled clusters are strictly larger (cross terms).
  let singleton : Array[Int] = Array::make(n, 0)
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
    pooled[i] = i / 8
  }
  let cl_single = cluster_sandwich_variance(psi_a, psi, m_inv, singleton, 1)
  let cl_pooled = cluster_sandwich_variance(psi_a, psi, m_inv, pooled, 1)
  inspect(expand_v087_close(cl_single, v0), content="true")
  inspect(expand_v087_close(cl_pooled, v0) == false, content="true")
  inspect(cl_pooled > 0.0, content="true")
}

// ---------------------------------------------------------------------------
// DoubleMLSSM
// ---------------------------------------------------------------------------

///|
test "ssm_sandwich_se_smoke" {
  let n = 400
  let fitted = DoubleMLSSM::new(
    expand_v087_ssm_data(n, 3),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  inspect(fitted.psi_a.length() == n, content="true")
  inspect(fitted.psi_b.length() == n, content="true")
  // SSM's MAR score has psi_a = -1 exactly, so mean(psi_a) = -1
  // and M_inv = -1: the negative-leverage shrink case.
  let m_val = 1.0 / mean(fitted.psi_a)
  inspect(expand_v087_close(m_val, -1.0), content="true")
  inspect(mean(fitted.psi_a) < 0.0, content="true")
  let psi = expand_v087_psi(fitted.psi_a, fitted.psi_b, fitted.coef(), n)
  let se_hc0 = fitted.sandwich_se(SandwichKind::hc0())
  inspect(
    expand_v087_close(
      se_hc0,
      expand_v087_ref_hc0(fitted.psi_a, psi, m_val, n).sqrt(),
    ),
    content="true",
  )
  inspect(se_hc0 > 0.0, content="true")
  inspect(se_hc0.is_nan() == false, content="true")
  inspect(se_hc0.is_inf() == false, content="true")
  let se_hc1 = fitted.sandwich_se(SandwichKind::hc1())
  let expected_scale = (n.to_double() / (n.to_double() - 1.0)).sqrt()
  inspect(expand_v087_close(se_hc1, se_hc0 * expected_scale), content="true")
  inspect(se_hc1 > se_hc0, content="true")
  let se_hc2 = fitted.sandwich_se(SandwichKind::hc2())
  let se_hc3 = fitted.sandwich_se(SandwichKind::hc3())
  inspect(
    expand_v087_close(
      se_hc2,
      expand_v087_ref_leverage(fitted.psi_a, psi, m_val, n, 1).sqrt(),
    ),
    content="true",
  )
  inspect(
    expand_v087_close(
      se_hc3,
      expand_v087_ref_leverage(fitted.psi_a, psi, m_val, n, 2).sqrt(),
    ),
    content="true",
  )
  // Constant psi_a = -1, so since v0.88.0 the leverage is the
  // constant mean-regression diagonal h_ii = 1 / n and the
  // divisors are n / (n - 1) and (n / (n - 1))^2 -- HC2 is
  // exactly HC1. (v0.87.0 used the negative leverage -1, i.e.
  // divisors 2 and 4, so HC2 was HC0 / 2.)
  inspect(expand_v087_close(se_hc2, se_hc0 * expected_scale), content="true")
  inspect(
    expand_v087_close(se_hc3, se_hc0 * expected_scale * expected_scale),
    content="true",
  )
  inspect(se_hc2 > se_hc0, content="true")
  inspect(se_hc3 > se_hc2, content="true")
  inspect(expand_v087_close(se_hc2, se_hc1), content="true")
  let singleton : Array[Int] = Array::make(n, 0)
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
    pooled[i] = i / 4
  }
  let se_singleton = fitted.cluster_sandwich_se(singleton)
  inspect(expand_v087_close(se_singleton, se_hc0), content="true")
  let se_pooled = fitted.cluster_sandwich_se(pooled)
  inspect(se_pooled.is_nan() == false, content="true")
  inspect(se_pooled > 0.0, content="true")
  inspect(expand_v087_close(se_pooled, se_hc0) == false, content="true")
  // psi_a = -1 constant collapses the bias correction to
  // 2 * coef + mean(psi_b); and since SSM's theta_hat =
  // mean(psi_b), that is exactly 3 * coef.
  let bc = fitted.bias_corrected_coef()
  inspect(
    expand_v087_close(bc, 2.0 * fitted.coef() + mean(fitted.psi_b)),
    content="true",
  )
  inspect(expand_v087_close(bc, 3.0 * fitted.coef()), content="true")
  let bias : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    bias[i] = fitted.psi_b[i] - fitted.coef() * fitted.psi_a[i]
  }
  inspect(expand_v087_close(bc, fitted.coef() + mean(bias)), content="true")
}

// ---------------------------------------------------------------------------
// DoubleMLPLPR
// ---------------------------------------------------------------------------

///|
test "plpr_sandwich_se_smoke" {
  // Balanced panel with unit fixed effects (reuses the package's
  // shared `build_panel_dgp`), fitted with the `fd_exact`
  // approach.
  let fitted = DoubleMLPLPR::new(
    build_panel_dgp(60, 4, 1.0, 3141),
    approach="fd_exact",
    n_folds=2,
    seed=3141,
  ).fit()
  // PLPR's psi_a / psi_b live on the TRANSFORMED domain, so the
  // sandwich sample is `psi_a.length()` (180 rows here for a
  // 60 x 4 = 240-row panel), not the raw panel width. The
  // methods must follow psi_a, and the cluster_ids must match.
  let n = fitted.psi_a.length()
  inspect(n == fitted.psi_b.length(), content="true")
  inspect(n > 0, content="true")
  inspect(n != 240, content="true")
  // PO psi_a = -v_hat^2 <= 0, so mean(psi_a) < 0 and
  // M_inv < 0. Since v0.88.0 that sign no longer enters the
  // leverage: HC2 / HC3 use the constant mean-regression
  // diagonal h_ii = 1 / n.
  let m_val = 1.0 / mean(fitted.psi_a)
  inspect(m_val < 0.0, content="true")
  inspect(mean(fitted.psi_a) < 0.0, content="true")
  let psi = expand_v087_psi(fitted.psi_a, fitted.psi_b, fitted.coef(), n)
  let se_hc0 = fitted.sandwich_se(SandwichKind::hc0())
  inspect(
    expand_v087_close(
      se_hc0,
      expand_v087_ref_hc0(fitted.psi_a, psi, m_val, n).sqrt(),
    ),
    content="true",
  )
  inspect(se_hc0 > 0.0, content="true")
  inspect(se_hc0.is_nan() == false, content="true")
  inspect(se_hc0.is_inf() == false, content="true")
  let se_hc1 = fitted.sandwich_se(SandwichKind::hc1())
  let expected_scale = (n.to_double() / (n.to_double() - 1.0)).sqrt()
  inspect(expand_v087_close(se_hc1, se_hc0 * expected_scale), content="true")
  inspect(se_hc1 > se_hc0, content="true")
  let se_hc2 = fitted.sandwich_se(SandwichKind::hc2())
  let se_hc3 = fitted.sandwich_se(SandwichKind::hc3())
  inspect(
    expand_v087_close(
      se_hc2,
      expand_v087_ref_leverage(fitted.psi_a, psi, m_val, n, 1).sqrt(),
    ),
    content="true",
  )
  inspect(
    expand_v087_close(
      se_hc3,
      expand_v087_ref_leverage(fitted.psi_a, psi, m_val, n, 2).sqrt(),
    ),
    content="true",
  )
  // Non-constant psi_a, but the leverage is the constant
  // mean-regression diagonal h_ii = 1 / n, so HC2 == HC1 and
  // both corrections widen.
  inspect(se_hc2 > se_hc0, content="true")
  inspect(se_hc3 > se_hc2, content="true")
  inspect(expand_v087_close(se_hc2, se_hc1), content="true")
  inspect(expand_v087_close(se_hc3, se_hc1 * se_hc1 / se_hc0), content="true")
  let singleton : Array[Int] = Array::make(n, 0)
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
    pooled[i] = i / 4
  }
  let se_singleton = fitted.cluster_sandwich_se(singleton)
  inspect(expand_v087_close(se_singleton, se_hc0), content="true")
  let se_pooled = fitted.cluster_sandwich_se(pooled)
  inspect(se_pooled.is_nan() == false, content="true")
  inspect(se_pooled > 0.0, content="true")
  inspect(expand_v087_close(se_pooled, se_hc0) == false, content="true")
  let bc = fitted.bias_corrected_coef()
  let bias : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    bias[i] = fitted.psi_b[i] - fitted.coef() * fitted.psi_a[i]
  }
  inspect(expand_v087_close(bc, fitted.coef() + mean(bias)), content="true")
  inspect(bc.is_nan() == false, content="true")
}

// ---------------------------------------------------------------------------
// DoubleMLDIDCrossSection
// ---------------------------------------------------------------------------

///|
test "did_cross_section_sandwich_se_smoke" {
  let n = 400
  let fitted = DoubleMLDIDCrossSection::new(
    build_cross_section_dgp(n, 3, 1.0),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let psi_a = fitted.psi_a()
  let psi_b = fitted.psi_b()
  inspect(psi_a.length() == n, content="true")
  inspect(psi_b.length() == n, content="true")
  // psi_a = -d / (m * l) is a non-positive ATT weight, so
  // mean(psi_a) < 0 (here -1 to 1e-12 on this DGP).
  let m_val = 1.0 / mean(psi_a)
  inspect(m_val < 0.0, content="true")
  inspect(mean(psi_a) < 0.0, content="true")
  let psi = expand_v087_psi(psi_a, psi_b, fitted.coef(), n)
  let se_hc0 = fitted.sandwich_se(SandwichKind::hc0())
  inspect(
    expand_v087_close(se_hc0, expand_v087_ref_hc0(psi_a, psi, m_val, n).sqrt()),
    content="true",
  )
  inspect(se_hc0 > 0.0, content="true")
  inspect(se_hc0.is_nan() == false, content="true")
  inspect(se_hc0.is_inf() == false, content="true")
  let se_hc1 = fitted.sandwich_se(SandwichKind::hc1())
  let expected_scale = (n.to_double() / (n.to_double() - 1.0)).sqrt()
  inspect(expand_v087_close(se_hc1, se_hc0 * expected_scale), content="true")
  inspect(se_hc1 > se_hc0, content="true")
  let se_hc2 = fitted.sandwich_se(SandwichKind::hc2())
  let se_hc3 = fitted.sandwich_se(SandwichKind::hc3())
  inspect(
    expand_v087_close(
      se_hc2,
      expand_v087_ref_leverage(psi_a, psi, m_val, n, 1).sqrt(),
    ),
    content="true",
  )
  inspect(
    expand_v087_close(
      se_hc3,
      expand_v087_ref_leverage(psi_a, psi, m_val, n, 2).sqrt(),
    ),
    content="true",
  )
  inspect(se_hc2 > se_hc0, content="true")
  inspect(se_hc3 > se_hc2, content="true")
  inspect(expand_v087_close(se_hc2, se_hc1), content="true")
  inspect(expand_v087_close(se_hc3, se_hc1 * se_hc1 / se_hc0), content="true")
  let singleton : Array[Int] = Array::make(n, 0)
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
    pooled[i] = i / 4
  }
  let se_singleton = fitted.cluster_sandwich_se(singleton)
  inspect(expand_v087_close(se_singleton, se_hc0), content="true")
  let se_pooled = fitted.cluster_sandwich_se(pooled)
  inspect(se_pooled.is_nan() == false, content="true")
  inspect(se_pooled > 0.0, content="true")
  inspect(expand_v087_close(se_pooled, se_hc0) == false, content="true")
  let bc = fitted.bias_corrected_coef()
  let bias : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    bias[i] = psi_b[i] - fitted.coef() * psi_a[i]
  }
  inspect(expand_v087_close(bc, fitted.coef() + mean(bias)), content="true")
  inspect(bc.is_nan() == false, content="true")
}

// ---------------------------------------------------------------------------
// DoubleMLDIDCSBinary
// ---------------------------------------------------------------------------

///|
test "did_cs_binary_sandwich_se_smoke" {
  let fitted = DoubleMLDIDCSBinary::new(
    expand_v087_cs_binary_data(100, 3),
    1,
    0,
    1,
    control_group="never_treated",
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let psi_a = fitted.psi_a()
  let psi_b = fitted.psi_b()
  // psi_a / psi_b live on the POST-SUBSET panel, so the
  // sandwich sample is `psi_a.length() == n_obs()` and NOT the
  // pre-subset `n_obs_panel()`.
  let n = psi_a.length()
  inspect(n == fitted.n_obs(), content="true")
  inspect(n == psi_b.length(), content="true")
  inspect(n != fitted.n_obs_panel(), content="true")
  inspect(mean(psi_a) < 0.0, content="true")
  let m_val = 1.0 / mean(psi_a)
  inspect(m_val < 0.0, content="true")
  let psi = expand_v087_psi(psi_a, psi_b, fitted.coef(), n)
  let se_hc0 = fitted.sandwich_se(SandwichKind::hc0())
  inspect(
    expand_v087_close(se_hc0, expand_v087_ref_hc0(psi_a, psi, m_val, n).sqrt()),
    content="true",
  )
  inspect(se_hc0 > 0.0, content="true")
  inspect(se_hc0.is_nan() == false, content="true")
  inspect(se_hc0.is_inf() == false, content="true")
  let se_hc1 = fitted.sandwich_se(SandwichKind::hc1())
  let expected_scale = (n.to_double() / (n.to_double() - 1.0)).sqrt()
  inspect(expand_v087_close(se_hc1, se_hc0 * expected_scale), content="true")
  inspect(se_hc1 > se_hc0, content="true")
  let se_hc2 = fitted.sandwich_se(SandwichKind::hc2())
  let se_hc3 = fitted.sandwich_se(SandwichKind::hc3())
  inspect(
    expand_v087_close(
      se_hc2,
      expand_v087_ref_leverage(psi_a, psi, m_val, n, 1).sqrt(),
    ),
    content="true",
  )
  inspect(
    expand_v087_close(
      se_hc3,
      expand_v087_ref_leverage(psi_a, psi, m_val, n, 2).sqrt(),
    ),
    content="true",
  )
  inspect(se_hc2 > se_hc0, content="true")
  inspect(se_hc3 > se_hc2, content="true")
  inspect(expand_v087_close(se_hc2, se_hc1), content="true")
  inspect(expand_v087_close(se_hc3, se_hc1 * se_hc1 / se_hc0), content="true")
  let singleton : Array[Int] = Array::make(n, 0)
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
    pooled[i] = i / 4
  }
  let se_singleton = fitted.cluster_sandwich_se(singleton)
  inspect(expand_v087_close(se_singleton, se_hc0), content="true")
  let se_pooled = fitted.cluster_sandwich_se(pooled)
  inspect(se_pooled.is_nan() == false, content="true")
  inspect(se_pooled > 0.0, content="true")
  inspect(expand_v087_close(se_pooled, se_hc0) == false, content="true")
  let bc = fitted.bias_corrected_coef()
  let bias : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    bias[i] = psi_b[i] - fitted.coef() * psi_a[i]
  }
  inspect(expand_v087_close(bc, fitted.coef() + mean(bias)), content="true")
  inspect(bc.is_nan() == false, content="true")
}
