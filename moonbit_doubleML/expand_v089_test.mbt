///|
// v0.89.0: white-box tests for the sandwich-variance expand
// (APO family + binary-DID wrapper) on top of the shared
// `sandwich_variance(kind, ...)` dispatch added in v0.86.0 and
// the HC2 / HC3 leverage fix in v0.88.0.
//
// What this release covers:
//   - `DoubleMLAPO`: clean add. `psi_a` (the constant -1) and
//     `psi_b` (the IPW-centred potential-outcome score) are both
//     persisted struct fields, and APO has no transformed /
//     subset domain -- `psi_a.length() == n_obs() == n`, on both
//     the IID and the v0.65.0 `fit_cluster` path.
//   - `DoubleMLDIDBinary`: pure forwarder. The wrapper holds the
//     whole fitted inner `DoubleMLDID` (`inner : DoubleMLDID`),
//     which already implements the v0.86.0 API, so the three
//     methods delegate instead of recomputing. The inner owns the
//     IF components, so the sandwich sample is the POST-SUBSET
//     wide-format width `n_obs_subset()` (300 of a 600-row
//     long-format panel in the DGP below) and NOT the long-panel
//     width and NOT `psi_a_long().length()`.
//
// What this release deliberately does NOT cover, and why:
//   - `DoubleMLAPOS`: a SEPARATE struct, not a field on APO. It
//     persists only `(coefs, ses)` per treatment level; the child
//     `DoubleMLAPO`s are constructed inside `fit(...)`, their
//     `psi_a` / `psi_b` are dropped, and it holds no inner
//     estimator to forward to. A sandwich SE here would need
//     either a new persisted child-score field (score-field
//     design work) or a silent full re-cross-fit on every call
//     (a `bootstrap(...)` -style cost, not a cheap accessor).
//   - `DoubleMLDIDCS`: multi-cell. It owns no scalar `coef` /
//     `se` (only `coef_matrix` / `se_matrix` per (g, t) cell) and
//     its per-cell `psi_a_matrix` is stored on the LONG panel
//     with out-of-cell rows zero-filled, so the per-cell subset
//     width that the HC1 identity needs is not recoverable from
//     the persisted state (a cell's genuine `psi_a` is itself 0 on
//     untreated rows, so counting non-zeros is not the subset
//     size either). Per-cell persistence is needed first.
//   - `DoubleMLDIDMulti`: a pure wrapper around `inner :
//     DoubleMLDIDCS` with no own scores and no scalar coefficient
//     (`coef_at_idx` / `se_at_idx` only), and its inner has no
//     sandwich API to forward to. Same blocker as DIDCS.
//
// Assertions here are falsifiable, never "finite and > 0": each
// estimator's HC0 SE is checked against an INDEPENDENTLY
// recomputed `M_inv^2 * sum_i (psi_a[i] * psi[i])^2 / n_obs`, the
// HC1 / HC2 / HC3 relationships are pinned against closed-form
// `n / (n - 1)` factors, the cluster path is proved to consume
// `cluster_ids` (all-singleton clusters == IID HC0, pooled
// clusters != it), and `bias_corrected_coef` is checked against
// `coef + mean(psi_b - coef * psi_a)`. The HC2 / HC3 leverage is
// the v0.88.0 constant mean-regression diagonal `h_ii = 1 / n`,
// so the asserted ordering is `HC1 == HC2 > HC0` and `HC3 > HC2`
// -- a monotonic widening (MacKinnon 2012 sec 5.4). The pre-v0.88
// ordering was `HC1 > HC0 > HC2 > HC3` and every HC2 / HC3
// assertion below fails against it.

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

///|
/// Relative closeness at the 1e-12 level (the tolerance this
/// package uses for "same number, different accumulation order").
fn expand_v089_close(x : Double, y : Double) -> Bool {
  let scale = if x.abs() > y.abs() { x.abs() } else { y.abs() }
  if scale == 0.0 {
    return (x - y).abs() < 1.0e-300
  }
  (x - y).abs() / scale < 1.0e-12
}

///|
/// Per-observation influence function `psi[i] = psi_a[i] +
/// coef * psi_b[i]`, recomputed in the test from the fitted
/// estimator's persisted IF components.
fn expand_v089_psi(
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
/// `m_val^2 * sum_i (psi_a[i] * psi[i])^2 / n_obs`. Deliberately
/// NOT routed through `sandwich_variance_hc0`, so a regression in
/// the shared helper cannot move both sides together.
fn expand_v089_ref_hc0(
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
/// with the v0.88.0 mean-regression leverage `h_ii = 1 / n_obs`
/// (the projection-matrix diagonal of the intercept-only,
/// equally-weighted mean regression implicit in the moment
/// `E[psi_a * psi(theta)] = 0`) and the same `1.0e-10`
/// degenerate-input clip the package applies.
fn expand_v089_ref_leverage(
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
/// Independent recomputation of the cluster-robust variance
/// `m_val^2 * sum_c S_c^2 * n_c / (n_c - 1) / n` with the
/// singleton-cluster clip (`scale == 1` when `n_c <= 1`). Not
/// routed through `cluster_sandwich_variance` on purpose.
fn expand_v089_ref_cluster(
  psi_a : Array[Double],
  psi : Array[Double],
  m_val : Double,
  cluster_ids : Array[Int],
) -> Double {
  let n = psi_a.length()
  let mut max_cid = -1
  for i = 0; i < n; i = i + 1 {
    if cluster_ids[i] > max_cid {
      max_cid = cluster_ids[i]
    }
  }
  let n_clusters = max_cid + 1
  let csum : Array[Double] = Array::make(n_clusters, 0.0)
  let csize : Array[Int] = Array::make(n_clusters, 0)
  for i = 0; i < n; i = i + 1 {
    let c = cluster_ids[i]
    csum[c] = csum[c] + psi_a[i] * psi[i]
    csize[c] = csize[c] + 1
  }
  let mut acc = 0.0
  for c = 0; c < n_clusters; c = c + 1 {
    let nc = csize[c]
    if nc == 0 {
      continue
    }
    let scale = if nc <= 1 {
      1.0
    } else {
      nc.to_double() / (nc.to_double() - 1.0)
    }
    acc = acc + csum[c] * csum[c] * scale
  }
  let m2 = m_val * m_val
  m2 * acc / n.to_double()
}

///|
/// Two-period DID-binary panel with a NOISY outcome (so `psi_b` is
/// not degenerate): unit-level time-invariant `x`, half the units
/// are treated (`g = 1`) and get `d = 1` in the post period only,
/// true ATT = 1.5.
///
/// Two periods on purpose: the wrapper's preprocessing keeps only
/// `t = t_value_pre` and `t = t_value_eval`, so the post-subset
/// wide-format sample (`n_obs_subset()`) is exactly half the
/// long-format panel. That pins the fact that the sandwich sample
/// follows the inner DID's `psi_a`, not the raw panel width.
fn expand_v089_did_binary_data(n_units : Int, p : Int) -> DoubleMLDIDBinaryData {
  let n = n_units * 2
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t_arr : Array[Int] = Array::make(n, 0)
  let g_arr : Array[Int] = Array::make(n, 0)
  let id_arr : Array[Int] = Array::make(n, 0)
  let rng = chacha8_rng(4242)
  for u = 0; u < n_units; u = u + 1 {
    let xu : Array[Double] = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      xu[j] = rng.double() * 2.0 - 1.0
    }
    let is_treated = if u % 2 == 0 { 1 } else { 0 }
    for k = 0; k < 2; k = k + 1 {
      let row = u * 2 + k
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = xu[j]
      }
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = is_treated
      let effect = if is_treated == 1 && k == 1 { 1.5 } else { 0.0 }
      d[row] = if effect > 0.0 { 1.0 } else { 0.0 }
      y[row] = effect +
        0.3 * xu[0] +
        0.2 * xu[1] +
        0.05 * (if p > 2 { xu[2] } else { 0.0 }) +
        0.6 * (rng.double() - 0.5)
    }
  }
  DoubleMLDIDBinaryData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t_arr,
    g_arr,
    id_arr,
  )
}

///|
/// `DoubleMLAPO` DGP: `d = 1{x_0 + 0.3 u > 0}` (so the propensity
/// is monotone in `x_0` and the linear propensity learner stays
/// inside `(0, 1)` away from the clip), `y = 1.0 + 0.4 x_0 +
/// 0.2 x_1 + 2.0 d + noise`. The `treatment_level = 1` potential
/// outcome is therefore around 3.0.
fn expand_v089_apo_data(n : Int, p : Int) -> DoubleMLData {
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  for i = 0; i < n * p; i = i + 1 {
    x_flat[i] = chacha8_rng(11 + i).double()
  }
  let rng = chacha8_rng(99)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u = rng.double() * 2.0 - 1.0
    let x0 = x_flat[i * p]
    d[i] = if x0 + 0.3 * u > 0.0 { 1.0 } else { 0.0 }
    let mut lin = 1.0 + 0.4 * x0
    for j = 1; j < p; j = j + 1 {
      lin = lin + 0.1 * x_flat[i * p + j]
    }
    y[i] = lin + 2.0 * d[i] + 0.4 * (rng.double() - 0.5)
  }
  DoubleMLData::new(Matrix::from_array(x_flat, n, p), y, d)
}

// ---------------------------------------------------------------------------
// Shared ordering (fixed synthetic input, no estimator involved)
// ---------------------------------------------------------------------------

///|
test "sandwich_expand_v089_ordering" {
  // Constant `psi_a = -1` (the APO / DID ATT leverage case) with a
  // deliberately non-symmetric `psi`. Pins the ordering on the
  // shared dispatch so the estimator methods can only agree with
  // it:
  //   HC1 = HC0 * sqrt(n / (n - 1))          (widen)
  //   HC2 = HC0 * n / (n - 1) = HC1          (h_ii = 1 / n)
  //   HC3 = HC0 * (n / (n - 1))^2 = HC1^2/HC0
  // i.e. HC1 == HC2 > HC0 and HC3 > HC2. Pre-v0.88 this ordering
  // was HC1 > HC0 > HC2 > HC3.
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
  let expected_scale = n.to_double() / (n.to_double() - 1.0)
  inspect(expand_v089_close(v1, v0 * expected_scale), content="true")
  inspect(expand_v089_close(v2, v0 * expected_scale), content="true")
  inspect(
    expand_v089_close(v3, v0 * expected_scale * expected_scale),
    content="true",
  )
  inspect(v1 > v0, content="true")
  inspect(v2 > v0, content="true")
  inspect(v3 > v2, content="true")
  inspect(v2 == v1, content="true")
  inspect(expand_v089_close(v3, v1 * v1 / v0), content="true")
  // Independent recomputations must agree with the dispatch.
  inspect(
    expand_v089_close(v0, expand_v089_ref_hc0(psi_a, psi, -1.0, n)),
    content="true",
  )
  inspect(
    expand_v089_close(v2, expand_v089_ref_leverage(psi_a, psi, -1.0, n, 1)),
    content="true",
  )
  inspect(
    expand_v089_close(v3, expand_v089_ref_leverage(psi_a, psi, -1.0, n, 2)),
    content="true",
  )
  // Singleton clusters are algebraically the HC0 accumulation;
  // pooled clusters pick up the cross terms and differ.
  let singleton : Array[Int] = Array::make(n, 0)
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
    pooled[i] = i / 8
  }
  let cl_single = cluster_sandwich_variance(psi_a, psi, m_inv, singleton, 1)
  let cl_pooled = cluster_sandwich_variance(psi_a, psi, m_inv, pooled, 1)
  inspect(expand_v089_close(cl_single, v0), content="true")
  inspect(expand_v089_close(cl_pooled, v0) == false, content="true")
  inspect(cl_pooled > v0, content="true")
  inspect(
    expand_v089_close(
      cl_single,
      expand_v089_ref_cluster(psi_a, psi, -1.0, singleton),
    ),
    content="true",
  )
  inspect(
    expand_v089_close(
      cl_pooled,
      expand_v089_ref_cluster(psi_a, psi, -1.0, pooled),
    ),
    content="true",
  )
}

// ---------------------------------------------------------------------------
// DoubleMLAPO
// ---------------------------------------------------------------------------

///|
test "apo_sandwich_se_smoke" {
  let n = 400
  let fitted = DoubleMLAPO::new(
    expand_v089_apo_data(n, 3),
    treatment_level=1.0,
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  // APO persists its IF components on the FULL sample domain (both
  // the IID path and the v0.65.0 `fit_cluster` path build
  // length-`n_obs` arrays), so the sandwich sample is
  // `psi_a.length() == n_obs()`, NOT a transformed or post-subset
  // width. Contrast PLPR (180 of 240) and DID CS binary (400 of
  // 600).
  inspect(fitted.psi_a.length() == n, content="true")
  inspect(fitted.psi_b.length() == n, content="true")
  inspect(fitted.psi_a.length() == fitted.n_obs(), content="true")
  // APO's score has `psi_a = -1` exactly, so `mean(psi_a) == -1`
  // and `M_inv = [[-1.0]]`; only `M_inv[0,0]^2` enters anyway.
  let m_val = 1.0 / mean(fitted.psi_a)
  inspect(expand_v089_close(m_val, -1.0), content="true")
  let psi = expand_v089_psi(fitted.psi_a, fitted.psi_b, fitted.coef(), n)
  let se_hc0 = fitted.sandwich_se(SandwichKind::hc0())
  inspect(
    expand_v089_close(
      se_hc0,
      expand_v089_ref_hc0(fitted.psi_a, psi, m_val, n).sqrt(),
    ),
    content="true",
  )
  inspect(se_hc0 > 0.0, content="true")
  inspect(se_hc0.is_nan() == false, content="true")
  inspect(se_hc0.is_inf() == false, content="true")
  let se_hc1 = fitted.sandwich_se(SandwichKind::hc1())
  let expected_scale = (n.to_double() / (n.to_double() - 1.0)).sqrt()
  inspect(expand_v089_close(se_hc1, se_hc0 * expected_scale), content="true")
  inspect(se_hc1 > se_hc0, content="true")
  let se_hc2 = fitted.sandwich_se(SandwichKind::hc2())
  let se_hc3 = fitted.sandwich_se(SandwichKind::hc3())
  inspect(
    expand_v089_close(
      se_hc2,
      expand_v089_ref_leverage(fitted.psi_a, psi, m_val, n, 1).sqrt(),
    ),
    content="true",
  )
  inspect(
    expand_v089_close(
      se_hc3,
      expand_v089_ref_leverage(fitted.psi_a, psi, m_val, n, 2).sqrt(),
    ),
    content="true",
  )
  // v0.88.0 leverage identities: `h_ii = 1 / n` on every row, so
  // HC2 == HC1 and HC3 == HC1^2 / HC0, and both corrections WIDEN.
  // (Pre-v0.88 the leverage was the signed `psi_a^2 * M_inv = -1`,
  // so HC2 was exactly HC0 / 2 here.)
  inspect(expand_v089_close(se_hc2, se_hc1), content="true")
  inspect(expand_v089_close(se_hc3, se_hc1 * se_hc1 / se_hc0), content="true")
  inspect(se_hc2 > se_hc0, content="true")
  inspect(se_hc3 > se_hc2, content="true")
  // Cluster path: all-singleton clusters == IID HC0 (the
  // singleton jackknife clip makes it the same accumulation);
  // pooled clusters must differ, which is what proves
  // `cluster_ids` is consumed.
  let singleton : Array[Int] = Array::make(n, 0)
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
    pooled[i] = i / 4
  }
  let se_singleton = fitted.cluster_sandwich_se(singleton)
  inspect(expand_v089_close(se_singleton, se_hc0), content="true")
  let se_pooled = fitted.cluster_sandwich_se(pooled)
  inspect(se_pooled > 0.0, content="true")
  inspect(se_pooled.is_nan() == false, content="true")
  inspect(expand_v089_close(se_pooled, se_hc0) == false, content="true")
  inspect(se_pooled > se_hc0, content="true")
  inspect(
    expand_v089_close(
      se_pooled,
      expand_v089_ref_cluster(fitted.psi_a, psi, m_val, pooled).sqrt(),
    ),
    content="true",
  )
}

///|
test "apo_bias_corrected_coef" {
  let n = 400
  let fitted = DoubleMLAPO::new(
    expand_v089_apo_data(n, 3),
    treatment_level=1.0,
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let bc = fitted.bias_corrected_coef()
  // General identity: `coef + mean(psi_b - coef * psi_a)`.
  let bias : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    bias[i] = fitted.psi_b[i] - fitted.coef() * fitted.psi_a[i]
  }
  inspect(expand_v089_close(bc, fitted.coef() + mean(bias)), content="true")
  // APO's closed form: `psi_a = -1` collapses the per-observation
  // bias to `psi_b[i] + coef`, so the mean is `mean(psi_b) + coef`
  // and the correction is `2 * coef + mean(psi_b)`.
  inspect(
    expand_v089_close(bc, 2.0 * fitted.coef() + mean(fitted.psi_b)),
    content="true",
  )
  // And APO's `var_est` point estimate is `theta_hat = mean(psi_b)`
  // (since `mean(psi_a) == -1`), so the closed form is exactly
  // `3 * coef`. This is a real number equality, not a bound.
  inspect(expand_v089_close(fitted.coef(), mean(fitted.psi_b)), content="true")
  inspect(expand_v089_close(bc, 3.0 * fitted.coef()), content="true")
  inspect(bc.is_nan() == false, content="true")
  inspect(bc != fitted.coef(), content="true")
}

///|
/// The package has TWO variance paths over the same persisted
/// `psi_a` / `psi_b`, and they use DIFFERENT score orders:
///
///   - `var_est` (and therefore `se()`) evaluates the score as
///     `coef * psi_a + psi_b`, giving
///     `se = sqrt(mean(psi^2)) / (|mean(psi_a)| * sqrt(n))`.
///   - the sandwich family (and `bootstrap`, and the `psi_a` /
///     `psi_b` field docs) evaluates it as
///     `psi_a + coef * psi_b`.
///
/// For APO the two are different functions of the same inputs
/// (`psi_a = -1`, so one is `-coef + psi_b` and the other is
/// `-1 + coef * psi_b`), and the resulting SEs differ by more than
/// three orders of magnitude on the DGP below: `se()` is `0.0083`
/// and `sandwich_se(HC0)` is `9.92`.
///
/// This is a pre-existing, package-wide split -- `DoubleMLIRM` and
/// every other estimator that exposes both paths do the same -- and
/// v0.89.0 does not change either one. The test exists so that a
/// future change to either order is a deliberate decision (this
/// test fails) rather than an accident (nothing fails).

///|
test "apo_var_est_se_order_split" {
  let n = 400
  let fitted = DoubleMLAPO::new(
    expand_v089_apo_data(n, 3),
    treatment_level=1.0,
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  // Independent recomputation in `var_est`'s order
  // (`coef * psi_a + psi_b`).
  let mut ss_var = 0.0
  let mut ss_sand = 0.0
  for i = 0; i < n; i = i + 1 {
    let p_var = fitted.coef() * fitted.psi_a[i] + fitted.psi_b[i]
    ss_var = ss_var + p_var * p_var
    let p_sand = fitted.psi_a[i] + fitted.coef() * fitted.psi_b[i]
    ss_sand = ss_sand + p_sand * p_sand
  }
  let n_d = n.to_double()
  let j = mean(fitted.psi_a)
  let se_var = (ss_var / n_d / (j * j * n_d)).sqrt()
  let se_sand = (ss_sand / n_d / (j * j)).sqrt()
  // `se()` follows the `var_est` order.
  inspect(expand_v089_close(fitted.se(), se_var), content="true")
  // `sandwich_se(HC0)` follows the sandwich order (`M_inv^2 *
  // sum (psi_a * psi)^2 / n` == `sum(psi^2) / (j^2 n)` for
  // `psi_a = -1`).
  inspect(expand_v089_close(se_sand, se_var) == false, content="true")
  inspect(
    expand_v089_close(fitted.sandwich_se(SandwichKind::hc0()), se_sand),
    content="true",
  )
  // The two orders disagree by a large margin here, which is the
  // concrete reason `se()` and `sandwich_se(HC0)` are NOT
  // interchangeable in this package.
  inspect(se_sand > 100.0 * se_var, content="true")
}

// ---------------------------------------------------------------------------
// DoubleMLDIDBinary (forwarder over the inner DoubleMLDID)
// ---------------------------------------------------------------------------

///|
test "did_binary_sandwich_se_smoke" {
  let n_units = 300
  let fitted = DoubleMLDIDBinary::new(
    expand_v089_did_binary_data(n_units, 3),
    1,
    0,
    1,
    control_group="never_treated",
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  // The wrapper is a pure forwarder: the sample is the inner
  // DID's POST-SUBSET wide-format width (one row per retained
  // unit), NOT the long-format panel width and NOT the length of
  // the zero-filled `psi_a_long()`.
  let n = fitted.n_obs_subset()
  inspect(n == n_units, content="true")
  inspect(n == fitted.inner_psi_a().length(), content="true")
  inspect(n == fitted.inner_psi_b().length(), content="true")
  inspect(n != fitted.data.n_obs(), content="true")
  inspect(n != fitted.psi_a_long().length(), content="true")
  // Observational-score ATT weight `psi_a = -d / p_hat`: zero on
  // controls, so `mean(psi_a) == -1` up to rounding and
  // `M_inv == -1`.
  let psi_a = fitted.inner_psi_a()
  let psi_b = fitted.inner_psi_b()
  let m_val = 1.0 / mean(psi_a)
  inspect(mean(psi_a) < 0.0, content="true")
  inspect(expand_v089_close(m_val, -1.0), content="true")
  let psi = expand_v089_psi(psi_a, psi_b, fitted.coef(), n)
  let se_hc0 = fitted.sandwich_se(SandwichKind::hc0())
  inspect(
    expand_v089_close(se_hc0, expand_v089_ref_hc0(psi_a, psi, m_val, n).sqrt()),
    content="true",
  )
  inspect(se_hc0 > 0.0, content="true")
  inspect(se_hc0.is_nan() == false, content="true")
  inspect(se_hc0.is_inf() == false, content="true")
  let se_hc1 = fitted.sandwich_se(SandwichKind::hc1())
  let expected_scale = (n.to_double() / (n.to_double() - 1.0)).sqrt()
  inspect(expand_v089_close(se_hc1, se_hc0 * expected_scale), content="true")
  inspect(se_hc1 > se_hc0, content="true")
  let se_hc2 = fitted.sandwich_se(SandwichKind::hc2())
  let se_hc3 = fitted.sandwich_se(SandwichKind::hc3())
  inspect(
    expand_v089_close(
      se_hc2,
      expand_v089_ref_leverage(psi_a, psi, m_val, n, 1).sqrt(),
    ),
    content="true",
  )
  inspect(
    expand_v089_close(
      se_hc3,
      expand_v089_ref_leverage(psi_a, psi, m_val, n, 2).sqrt(),
    ),
    content="true",
  )
  // v0.88.0 identities: HC2 == HC1, HC3 == HC1^2 / HC0, and the
  // corrections widen.
  inspect(expand_v089_close(se_hc2, se_hc1), content="true")
  inspect(expand_v089_close(se_hc3, se_hc1 * se_hc1 / se_hc0), content="true")
  inspect(se_hc2 > se_hc0, content="true")
  inspect(se_hc3 > se_hc2, content="true")
  // Forwarding, not recomputation: bit-identical to the inner
  // estimator's own v0.86.0 methods for every kind. A
  // recomputing wrapper would have to reproduce these bit for
  // bit, which the differing accumulation paths make
  // implausible; equality here is the contract.
  inspect(
    se_hc0 == fitted.inner.sandwich_se(SandwichKind::hc0()),
    content="true",
  )
  inspect(
    se_hc1 == fitted.inner.sandwich_se(SandwichKind::hc1()),
    content="true",
  )
  inspect(
    se_hc2 == fitted.inner.sandwich_se(SandwichKind::hc2()),
    content="true",
  )
  inspect(
    se_hc3 == fitted.inner.sandwich_se(SandwichKind::hc3()),
    content="true",
  )
  // Cluster path on the post-subset indexing.
  let singleton : Array[Int] = Array::make(n, 0)
  let pooled : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    singleton[i] = i
    pooled[i] = i / 4
  }
  let se_singleton = fitted.cluster_sandwich_se(singleton)
  inspect(expand_v089_close(se_singleton, se_hc0), content="true")
  let se_pooled = fitted.cluster_sandwich_se(pooled)
  inspect(se_pooled > 0.0, content="true")
  inspect(se_pooled.is_nan() == false, content="true")
  inspect(expand_v089_close(se_pooled, se_hc0) == false, content="true")
  inspect(se_pooled > se_hc0, content="true")
  inspect(
    expand_v089_close(
      se_pooled,
      expand_v089_ref_cluster(psi_a, psi, m_val, pooled).sqrt(),
    ),
    content="true",
  )
  inspect(se_pooled == fitted.inner.cluster_sandwich_se(pooled), content="true")
}

///|
test "did_binary_bias_corrected_coef" {
  let n_units = 300
  let fitted = DoubleMLDIDBinary::new(
    expand_v089_did_binary_data(n_units, 3),
    1,
    0,
    1,
    control_group="never_treated",
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let n = fitted.n_obs_subset()
  let psi_a = fitted.inner_psi_a()
  let psi_b = fitted.inner_psi_b()
  let bc = fitted.bias_corrected_coef()
  let bias : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    bias[i] = psi_b[i] - fitted.coef() * psi_a[i]
  }
  inspect(expand_v089_close(bc, fitted.coef() + mean(bias)), content="true")
  inspect(bc == fitted.inner.bias_corrected_coef(), content="true")
  inspect(bc.is_nan() == false, content="true")
  // The DID score at `theta_hat` is the ATT residual, so the
  // correction is a genuine shift, not the identity: it must
  // differ from `coef` on this noisy DGP.
  inspect(bc != fitted.coef(), content="true")
}
