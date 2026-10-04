///|
// v0.86.0+: white-box tests for the sandwich-variance expand
// (IIVM / PLIV / DID / CVAR) plus the shared
// `sandwich_variance(kind, ...)` dispatch added to
// `sandwich.mbt`.
//
// NOT covered here: `DoubleMLLPQ`. LPQ's `fit()` computes
// the moment Jacobian (`deriv`, the KDE-weighted
// `d/dtheta mean(psi_ipw)`) as a local and never persists it
// on the struct, and the stored `psi` is already the
// *centered* score at the bisection root with no
// `coef * psi_a + psi_b` decomposition (theta is a ROOT of
// the check function, not a ratio of two means). So neither
// `M_inv` nor `psi_a` is cleanly recoverable post-fit. Per
// the v0.86.0 scope decision ("a wrong sandwich variance is
// worse than a missing one") LPQ is deliberately skipped and
// queued for a follow-up that persists the Jacobian.
//
// What these tests assert (and why it is not the vacuous
// "the number is finite" trap):
//   1. The returned HC0 SE reproduces, to 1e-12 relative,
//      an INDEPENDENTLY recomputed
//      `M_inv^2 * sum_i psi[i]^2 / n^2` -- a function
//      returning a constant, or reusing the wrong `psi`,
//      fails this. (v0.91.0: the reference dropped the
//      `psi_a[i]` factor and the second `1 / n`; through
//      v0.90.0 both were wrong.)
//   2. `se(HC1) / se(HC0) == sqrt(n / (n - 1))` to 1e-12 --
//      the exact HC1 finite-sample identity, so a swapped
//      HC1 / HC2 arm fails.
//   3. The HC2 / HC3 leverage corrections are actually
//      applied (`!=`) AND WIDEN the variance, as
//      MacKinnon (2012) sec 5.4 requires. Since v0.88.0 the
//      leverage is the projection-matrix diagonal of the
//      mean regression implicit in the DML moment,
//      i.e. the constant `h_ii = 1 / n_obs`, so HC2 is
//      exactly HC1 and HC3 is exactly `HC1^2 / HC0`; the
//      asserted ordering is `HC1 == HC2 > HC0` and
//      `HC3 > HC2`. (v0.79.0 - v0.87.0 used the signed
//      `h_ii = psi_a[i]^2 / mean(psi_a)`, which is negative
//      here and made the corrections SHRINK -- see the
//      note in `sandwich.mbt` and `expand_v088_test.mbt`.)
//   4. `cluster_sandwich_se` with all-singleton clusters
//      equals `sandwich_se(HC0)` EXACTLY (singleton clusters
//      contribute their raw `psi[i]^2` with no jackknife
//      factor, which is algebraically the HC0
//      accumulation), while a pooled cluster assignment
//      gives a strictly different value -- proving
//      `cluster_ids` is actually consumed and not ignored.
//   5. `bias_corrected_coef` returns `coef` unchanged
//      (v0.91.0: a documented no-op -- the DML score is
//      orthogonal at the estimate, so there is no
//      score-based bias to correct; through v0.90.0 it
//      returned `coef + mean(psi_b - coef * psi_a)`, which
//      is `3 * coef` for a constant `psi_a = -1` and is
//      not a bias estimate).

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

///|
/// Per-observation influence function `psi[i] = coef * psi_a[i]
/// + psi_b[i]`, recomputed in the test from the fitted
/// estimator's persisted IF components.
///
/// v0.90.0: the score order was `psi_a[i] + coef * psi_b[i]`
/// through v0.89.0; see `expand_v090_test.mbt` for the evidence.
/// Deliberately NOT routed through the production `psi_at`
/// helper, so a regression in `psi_at` cannot move this
/// reference and the estimator's own value together.
fn expand_v086_psi(
  psi_a : Array[Double],
  psi_b : Array[Double],
  coef : Double,
  n_obs : Int,
) -> Array[Double] {
  let psi : Array[Double] = Array::make(n_obs, 0.0)
  for i = 0; i < n_obs; i = i + 1 {
    psi[i] = coef * psi_a[i] + psi_b[i]
  }
  psi
}

///|
/// Independent recomputation of the HC0 variance
/// `m_val^2 * sum_i psi[i]^2 / n_obs^2`, used as
/// the reference the estimator methods must match.
///
/// v0.91.0: the moment is a MEAN moment, so the
/// per-observation quadratic form is `psi[i]^2` with no
/// `psi_a[i]` factor, and the returned quantity is the
/// variance of `theta_hat` (two factors of `n_obs`, not
/// one). `psi_a` is kept in the signature -- and ignored
/// -- so the call sites stay comparable with v0.86.0.
fn expand_v086_ref_hc0(
  psi_a : Array[Double],
  psi : Array[Double],
  m_val : Double,
  n_obs : Int,
) -> Double {
  let _ = psi_a
  let mut acc = 0.0
  for i = 0; i < n_obs; i = i + 1 {
    let v = psi[i]
    acc = acc + v * v
  }
  let m2 = m_val * m_val
  let n_d = n_obs.to_double()
  m2 * acc / n_d / n_d
}

///|
/// Relative closeness of two non-zero values (guards against
/// a near-zero reference blowing up an absolute tolerance).
fn expand_v086_close(x : Double, y : Double) -> Bool {
  let scale = if x.abs() > y.abs() { x.abs() } else { y.abs() }
  if scale == 0.0 {
    return (x - y).abs() < 1.0e-300
  }
  (x - y).abs() / scale < 1.0e-12
}

// ---------------------------------------------------------------------------
// Shared dispatch
// ---------------------------------------------------------------------------

///|
test "sandwich_kind_dispatch_matches_direct_calls" {
  // The v0.86.0 shared `sandwich_variance(kind, ...)` must be
  // byte-identical to calling the matching
  // `sandwich_variance_hc*` free function directly, for all
  // four kinds. This is what lets the per-estimator
  // `sandwich_se(kind)` methods share one dispatch without
  // changing any number.
  let n = 12
  let psi_a : Array[Double] = [
    1.0, 0.5, 1.0, 0.5, 1.0, 0.5, 1.0, 0.5, 1.0, 0.5, 1.0, 0.5,
  ]
  let psi : Array[Double] = [
    0.3, -0.7, 0.2, -0.1, 0.5, -0.4, 0.9, -0.6, 0.1, -0.2, 0.8, -0.9,
  ]
  let m_inv = Matrix::from_array([2.0], 1, 1)
  let d_hc0 = sandwich_variance_hc0(psi_a, psi, m_inv, n, 1)
  let d_hc1 = sandwich_variance_hc1(psi_a, psi, m_inv, n, 1)
  let d_hc2 = sandwich_variance_hc2(psi_a, psi, m_inv, n, 1)
  let d_hc3 = sandwich_variance_hc3(psi_a, psi, m_inv, n, 1)
  inspect(
    sandwich_variance(SandwichKind::hc0(), psi_a, psi, m_inv, n, 1) == d_hc0,
    content="true",
  )
  inspect(
    sandwich_variance(SandwichKind::hc1(), psi_a, psi, m_inv, n, 1) == d_hc1,
    content="true",
  )
  inspect(
    sandwich_variance(SandwichKind::hc2(), psi_a, psi, m_inv, n, 1) == d_hc2,
    content="true",
  )
  inspect(
    sandwich_variance(SandwichKind::hc3(), psi_a, psi, m_inv, n, 1) == d_hc3,
    content="true",
  )
  // The four arms must also be genuinely DISTINCT (a
  // dispatch that collapsed to one arm would still pass the
  // equality checks above only if the free functions agreed,
  // so pin the spread explicitly).
  inspect(d_hc0 > 0.0, content="true")
  inspect(d_hc1 > d_hc0, content="true")
  // psi_a = [1, 0.5, ...] with M_inv = 2 and n = 12. Since
  // v0.88.0 the leverage is the constant `h_ii = 1 / 12`
  // (the mean-regression projection diagonal), so the HC2 /
  // HC3 divisors are 12 / 11 and (12 / 11)^2 and every
  // correction widens. HC2 == HC1 exactly.
  let d_hc1b = sandwich_variance_hc1(psi_a, psi, m_inv, n, 1)
  inspect(expand_v086_close(d_hc2, d_hc1b), content="true")
  inspect(d_hc2 > d_hc0, content="true")
  inspect(d_hc3 > d_hc2, content="true")
}

///|
test "sandwich_kind_dispatch_hc1_identity" {
  // HC1 is defined as HC0 * n / (n - k). On a fixed input
  // that identity must hold to 1e-12 relative for both the
  // direct call and the shared dispatch.
  let n = 20
  let k = 1
  let psi_a : Array[Double] = Array::make(n, 0.8)
  let psi : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    psi[i] = if i % 3 == 0 { 1.0 } else { -0.5 }
  }
  let m_inv = Matrix::from_array([-1.5], 1, 1)
  let v0 = sandwich_variance(SandwichKind::hc0(), psi_a, psi, m_inv, n, k)
  let v1 = sandwich_variance(SandwichKind::hc1(), psi_a, psi, m_inv, n, k)
  let expected_scale = n.to_double() / (n.to_double() - k.to_double())
  inspect(expand_v086_close(v1, v0 * expected_scale), content="true")
  // All four kinds finite and non-negative.
  let v2 = sandwich_variance(SandwichKind::hc2(), psi_a, psi, m_inv, n, k)
  let v3 = sandwich_variance(SandwichKind::hc3(), psi_a, psi, m_inv, n, k)
  inspect(v0 > 0.0, content="true")
  inspect(v2 > 0.0, content="true")
  inspect(v3 > 0.0, content="true")
  inspect(v0.is_nan() == false, content="true")
  inspect(v1.is_nan() == false, content="true")
  inspect(v2.is_nan() == false, content="true")
  inspect(v3.is_nan() == false, content="true")
}

// ---------------------------------------------------------------------------
// DoubleMLIIVM
// ---------------------------------------------------------------------------

///|
test "iivm_sandwich_se_smoke" {
  // IIVM LATE DGP: z ~ Bernoulli(0.5), d = 1{alpha*z + v > 0},
  // y = theta * d + x @ 1 + eps.
  let n = 400
  let p = 3
  let alpha = 0.5
  let rng = chacha8_rng(1111)
  let pool : Array[Double] = []
  while pool.length() < n * p + 2 * n {
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
  let mut noise_idx = n * p
  let v : Array[Double] = Array::make(n, 0.0)
  let eps : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    v[i] = pool[noise_idx]
    noise_idx = noise_idx + 1
  }
  for i = 0; i < n; i = i + 1 {
    eps[i] = pool[noise_idx]
    noise_idx = noise_idx + 1
  }
  let x = Matrix::from_array(x_flat, n, p)
  let z : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    z[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    d[i] = if alpha * z[i] + v[i] > 0.0 { 1.0 } else { 0.0 }
    let mut s = eps[i]
    for j = 0; j < p; j = j + 1 {
      s = s + x.get(i, j)
    }
    y[i] = 1.0 * d[i] + s
  }
  let data = DoubleMLIIVMData::new(x, y, d, z)
  let fitted = DoubleMLIIVM::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  // The IF components must be populated (length n_obs);
  // otherwise every downstream assertion is vacuous.
  inspect(fitted.psi_a.length() == n, content="true")
  inspect(fitted.psi_b.length() == n, content="true")
  let m_val = 1.0 / mean(fitted.psi_a)
  inspect(m_val.abs() > 0.0, content="true")
  let psi = expand_v086_psi(fitted.psi_a, fitted.psi_b, fitted.coef(), n)
  // (1) HC0 SE reproduces the independently recomputed
  // `M_inv^2 * sum psi[i]^2 / n^2`.
  let se_hc0 = fitted.sandwich_se(SandwichKind::hc0())
  let ref_hc0 = expand_v086_ref_hc0(fitted.psi_a, psi, m_val, n).sqrt()
  inspect(expand_v086_close(se_hc0, ref_hc0), content="true")
  inspect(se_hc0 > 0.0, content="true")
  inspect(se_hc0.is_nan() == false, content="true")
  inspect(se_hc0.is_inf() == false, content="true")
  // (2) HC1 identity: se(HC1) = se(HC0) * sqrt(n / (n - 1)).
  let se_hc1 = fitted.sandwich_se(SandwichKind::hc1())
  let expected_scale = (n.to_double() / (n.to_double() - 1.0)).sqrt()
  inspect(expand_v086_close(se_hc1, se_hc0 * expected_scale), content="true")
  // (3) leverage-driven ordering. IIVM's mean(psi_a) is
  // negative (roughly -comp, the negative first-stage gap).
  // v0.88.0 uses the constant mean-regression leverage
  // h_ii = 1 / n, so HC2 == HC1 and both corrections widen;
  // v0.87.0 used the signed `h_ii = psi_a^2 / mean(psi_a)`
  // and both shrank.
  let se_hc2 = fitted.sandwich_se(SandwichKind::hc2())
  let se_hc3 = fitted.sandwich_se(SandwichKind::hc3())
  inspect(mean(fitted.psi_a) < 0.0, content="true")
  inspect(se_hc1 > se_hc0, content="true")
  inspect(se_hc2 > se_hc0, content="true")
  inspect(se_hc3 > se_hc2, content="true")
  inspect(expand_v086_close(se_hc2, se_hc1), content="true")
  inspect(expand_v086_close(se_hc3, se_hc1 * se_hc1 / se_hc0), content="true")
  // (4) singleton clusters reproduce the IID HC0 exactly;
  // pooled clusters do not.
  let singleton : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
  }
  let se_singleton = fitted.cluster_sandwich_se(singleton)
  inspect(expand_v086_close(se_singleton, se_hc0), content="true")
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    pooled[i] = i / 4
  }
  let se_pooled = fitted.cluster_sandwich_se(pooled)
  inspect(se_pooled.is_nan() == false, content="true")
  inspect(expand_v086_close(se_pooled, se_hc0) == false, content="true")
  // (5) bias correction reproduces
  // `coef + mean(psi_b - coef * psi_a)`.
  // v0.91.0: `bias_corrected_coef` is a documented no-op and
  // returns `coef` unchanged -- the DML score is
  // orthogonal at the estimate, so there is nothing to
  // correct. Through v0.90.0 it returned
  // `coef + mean(psi_b - coef * psi_a)` (the score at
  // `-coef`), i.e. `coef * (1 - 2 * mean(psi_a))`, which
  // is not a bias estimate.
  let bc = fitted.bias_corrected_coef()
  inspect(bc == fitted.coef(), content="true")
}

// ---------------------------------------------------------------------------
// DoubleMLPLIV
// ---------------------------------------------------------------------------

///|
test "pliv_sandwich_se_smoke" {
  // PLIV partialling-out DGP: z = x_0 + xi,
  // d = 0.5 * x_0 + 0.5 * z + u, y = alpha * d + x @ 1 + eps.
  let n = 400
  let p = 3
  let alpha0 = 1.0
  let rng = chacha8_rng(1111)
  let pool : Array[Double] = []
  while pool.length() < n * p + 3 * n {
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
  let mut noise_idx = n * p
  let eps : Array[Double] = Array::make(n, 0.0)
  let u : Array[Double] = Array::make(n, 0.0)
  let xi : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    eps[i] = pool[noise_idx]
    noise_idx = noise_idx + 1
  }
  for i = 0; i < n; i = i + 1 {
    u[i] = pool[noise_idx]
    noise_idx = noise_idx + 1
  }
  for i = 0; i < n; i = i + 1 {
    xi[i] = pool[noise_idx]
    noise_idx = noise_idx + 1
  }
  let x = Matrix::from_array(x_flat, n, p)
  let z : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    z[i] = x.get(i, 0) + xi[i]
    let mut d_part = 0.5 * x.get(i, 0) + 0.5 * z[i] + u[i]
    for j = 1; j < p; j = j + 1 {
      d_part = d_part + 0.1 * x.get(i, j)
    }
    d[i] = d_part
    let mut y_part = eps[i]
    for j = 0; j < p; j = j + 1 {
      y_part = y_part + x.get(i, j)
    }
    y[i] = alpha0 * d[i] + y_part
  }
  let data = DoubleMLPLIVData::new(x, y, d, z)
  let fitted = DoubleMLPLIV::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  inspect(fitted.psi_a.length() == n, content="true")
  inspect(fitted.psi_b.length() == n, content="true")
  // PLIV's psi_a = -w_hat * v_hat, so mean(psi_a) is the
  // negative first-stage covariance and is strictly negative.
  let m_val = 1.0 / mean(fitted.psi_a)
  inspect(m_val < 0.0, content="true")
  let psi = expand_v086_psi(fitted.psi_a, fitted.psi_b, fitted.coef(), n)
  let se_hc0 = fitted.sandwich_se(SandwichKind::hc0())
  let ref_hc0 = expand_v086_ref_hc0(fitted.psi_a, psi, m_val, n).sqrt()
  inspect(expand_v086_close(se_hc0, ref_hc0), content="true")
  inspect(se_hc0 > 0.0, content="true")
  inspect(se_hc0.is_nan() == false, content="true")
  inspect(se_hc0.is_inf() == false, content="true")
  let se_hc1 = fitted.sandwich_se(SandwichKind::hc1())
  let expected_scale = (n.to_double() / (n.to_double() - 1.0)).sqrt()
  inspect(expand_v086_close(se_hc1, se_hc0 * expected_scale), content="true")
  let se_hc2 = fitted.sandwich_se(SandwichKind::hc2())
  let se_hc3 = fitted.sandwich_se(SandwichKind::hc3())
  inspect(se_hc1 > se_hc0, content="true")
  inspect(se_hc2 > se_hc0, content="true")
  inspect(se_hc3 > se_hc2, content="true")
  inspect(expand_v086_close(se_hc2, se_hc1), content="true")
  inspect(expand_v086_close(se_hc3, se_hc1 * se_hc1 / se_hc0), content="true")
  let singleton : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
  }
  let se_singleton = fitted.cluster_sandwich_se(singleton)
  inspect(expand_v086_close(se_singleton, se_hc0), content="true")
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    pooled[i] = i / 4
  }
  let se_pooled = fitted.cluster_sandwich_se(pooled)
  inspect(se_pooled.is_nan() == false, content="true")
  inspect(expand_v086_close(se_pooled, se_hc0) == false, content="true")
  // v0.91.0: `bias_corrected_coef` is a documented no-op and
  // returns `coef` unchanged -- the DML score is
  // orthogonal at the estimate, so there is nothing to
  // correct. Through v0.90.0 it returned
  // `coef + mean(psi_b - coef * psi_a)` (the score at
  // `-coef`), i.e. `coef * (1 - 2 * mean(psi_a))`, which
  // is not a bias estimate.
  let bc = fitted.bias_corrected_coef()
  inspect(bc == fitted.coef(), content="true")
}

// ---------------------------------------------------------------------------
// DoubleMLDID
// ---------------------------------------------------------------------------

///|
test "did_sandwich_se_smoke" {
  // DID DGP on first differences: y = theta * d + noise with
  // a linear-in-x propensity.
  let n = 400
  let p = 3
  let theta0 = 1.0
  let rng = chacha8_rng(1111)
  let pool : Array[Double] = []
  while pool.length() < n * p + 2 * n {
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
  let mut noise_idx = n * p
  let u_pre : Array[Double] = Array::make(n, 0.0)
  let u_post : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    u_pre[i] = pool[noise_idx]
    noise_idx = noise_idx + 1
  }
  for i = 0; i < n; i = i + 1 {
    u_post[i] = pool[noise_idx]
    noise_idx = noise_idx + 1
  }
  let x = Matrix::from_array(x_flat, n, p)
  let d : Array[Double] = Array::make(n, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let p_x = 0.3 + 0.2 * x.get(i, 0)
    let p_x_ = if p_x < 0.05 { 0.05 } else if p_x > 0.95 { 0.95 } else { p_x }
    d[i] = if rng.double() < p_x_ { 1.0 } else { 0.0 }
    y[i] = theta0 * d[i] + (u_post[i] - u_pre[i])
  }
  let data = DoubleMLDIDData::new(x, y, d)
  let fitted = DoubleMLDID::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  inspect(fitted.psi_a.length() == n, content="true")
  inspect(fitted.psi_b.length() == n, content="true")
  // The observational ATT score has psi_a = -d / p_hat, so
  // mean(psi_a) = -1 and M_inv = -1 exactly.
  let m_val = 1.0 / mean(fitted.psi_a)
  inspect(expand_v086_close(m_val, -1.0), content="true")
  let psi = expand_v086_psi(fitted.psi_a, fitted.psi_b, fitted.coef(), n)
  let se_hc0 = fitted.sandwich_se(SandwichKind::hc0())
  let ref_hc0 = expand_v086_ref_hc0(fitted.psi_a, psi, m_val, n).sqrt()
  inspect(expand_v086_close(se_hc0, ref_hc0), content="true")
  inspect(se_hc0 > 0.0, content="true")
  inspect(se_hc0.is_nan() == false, content="true")
  inspect(se_hc0.is_inf() == false, content="true")
  let se_hc1 = fitted.sandwich_se(SandwichKind::hc1())
  let expected_scale = (n.to_double() / (n.to_double() - 1.0)).sqrt()
  inspect(expand_v086_close(se_hc1, se_hc0 * expected_scale), content="true")
  let se_hc2 = fitted.sandwich_se(SandwichKind::hc2())
  let se_hc3 = fitted.sandwich_se(SandwichKind::hc3())
  inspect(se_hc1 > se_hc0, content="true")
  inspect(se_hc2 > se_hc0, content="true")
  inspect(se_hc3 > se_hc2, content="true")
  inspect(expand_v086_close(se_hc2, se_hc1), content="true")
  inspect(expand_v086_close(se_hc3, se_hc1 * se_hc1 / se_hc0), content="true")
  let singleton : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
  }
  let se_singleton = fitted.cluster_sandwich_se(singleton)
  inspect(expand_v086_close(se_singleton, se_hc0), content="true")
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    pooled[i] = i / 4
  }
  let se_pooled = fitted.cluster_sandwich_se(pooled)
  inspect(se_pooled.is_nan() == false, content="true")
  inspect(expand_v086_close(se_pooled, se_hc0) == false, content="true")
  // v0.91.0: `bias_corrected_coef` is a documented no-op and
  // returns `coef` unchanged -- the DML score is
  // orthogonal at the estimate, so there is nothing to
  // correct. Through v0.90.0 it returned
  // `coef + mean(psi_b - coef * psi_a)` (the score at
  // `-coef`), i.e. `coef * (1 - 2 * mean(psi_a))`, which
  // is not a bias estimate.
  let bc = fitted.bias_corrected_coef()
  inspect(bc == fitted.coef(), content="true")
}

// ---------------------------------------------------------------------------
// DoubleMLCVAR
// ---------------------------------------------------------------------------

///|
test "cvar_sandwich_se_smoke" {
  // Canonical CVaR DGP (reuses the package's shared
  // `quantile_test_data()` helper: alternating treatment,
  // y = d + (i % 100) / 100).
  let data = quantile_test_data()
  let n = data.n_obs()
  let fitted = DoubleMLCVAR::new(data, treatment=1.0, quantile=0.5).fit()
  inspect(fitted.psi_a.length() == n, content="true")
  inspect(fitted.psi_b.length() == n, content="true")
  // CVAR's psi_a is the constant -1, so mean(psi_a) = -1 and
  // M_inv = -1. Since v0.88.0 the leverage used by HC2 / HC3
  // is the constant mean-regression diagonal h_ii = 1 / n,
  // independent of the (negative) score sign; v0.87.0 used the
  // signed `h_ii = psi_a^2 * M_inv = -1`.
  let m_val = 1.0 / mean(fitted.psi_a)
  inspect(expand_v086_close(m_val, -1.0), content="true")
  let psi = expand_v086_psi(fitted.psi_a, fitted.psi_b, fitted.coef(), n)
  let se_hc0 = fitted.sandwich_se(SandwichKind::hc0())
  let ref_hc0 = expand_v086_ref_hc0(fitted.psi_a, psi, m_val, n).sqrt()
  inspect(expand_v086_close(se_hc0, ref_hc0), content="true")
  inspect(se_hc0 > 0.0, content="true")
  inspect(se_hc0.is_nan() == false, content="true")
  inspect(se_hc0.is_inf() == false, content="true")
  let se_hc1 = fitted.sandwich_se(SandwichKind::hc1())
  let expected_scale = (n.to_double() / (n.to_double() - 1.0)).sqrt()
  inspect(expand_v086_close(se_hc1, se_hc0 * expected_scale), content="true")
  let se_hc2 = fitted.sandwich_se(SandwichKind::hc2())
  let se_hc3 = fitted.sandwich_se(SandwichKind::hc3())
  inspect(se_hc1 > se_hc0, content="true")
  // CVAR's psi_a is the constant -1, so mean(psi_a) = -1 and
  // M_inv = -1. Since v0.88.0 the leverage is the constant
  // mean-regression diagonal `h_ii = 1 / n`, so the HC2 / HC3
  // variance divisors are `n / (n - 1)` and `(n / (n - 1))^2`
  // and HC2 is exactly HC1. (v0.79.0 - v0.87.0 used the
  // negative leverage -1 here, i.e. divisors 2 and 4, so HC2
  // was HC0 / 2 and HC3 was HC0 / 4.)
  inspect(se_hc2 > se_hc0, content="true")
  inspect(se_hc3 > se_hc2, content="true")
  inspect(expand_v086_close(se_hc2, se_hc1), content="true")
  inspect(expand_v086_close(se_hc3, se_hc1 * se_hc1 / se_hc0), content="true")
  let singleton : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
  }
  let se_singleton = fitted.cluster_sandwich_se(singleton)
  inspect(expand_v086_close(se_singleton, se_hc0), content="true")
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    pooled[i] = i / 4
  }
  let se_pooled = fitted.cluster_sandwich_se(pooled)
  inspect(se_pooled.is_nan() == false, content="true")
  inspect(expand_v086_close(se_pooled, se_hc0) == false, content="true")
  // v0.91.0: documented no-op, returns `coef` unchanged.
  // Through v0.90.0 CVAR returned `2 * coef + mean(psi_b)`
  // (i.e. exactly `3 * coef`, since `coef == mean(psi_b)`
  // for the constant-`psi_a` score), which is not a bias
  // estimate.
  let bc = fitted.bias_corrected_coef()
  inspect(bc == fitted.coef(), content="true")
}
