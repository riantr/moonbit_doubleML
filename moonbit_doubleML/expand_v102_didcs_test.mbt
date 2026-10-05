///|
/// v0.102.0 tests for `DoubleMLDIDCrossSection`'s score
/// convention.
///
/// Through v0.101.0 this estimator was a projection
/// (`argmin_theta`) fit on `psi = psi_a + theta * psi_b`
/// with a hand-rolled `se = sqrt(sum(psi^2) / inner_bb)`,
/// and its `M_inv` carried a comment saying it was "not
/// `1 / mean(psi_a)` in any principled sense". `fit` is
/// now on the shared `var_est` path -- score
/// `psi = theta * psi_a + psi_b`, `d psi / d theta =
/// psi_a`, `M_inv = 1 / mean(psi_a)` -- which is what
/// upstream `DoubleMLDIDCS` does (a `LinearScoreMixin`
/// subclass: `_est_coef` -> `-np.mean(psi_b) /
/// np.mean(psi_a)`, `_compute_score_deriv` -> `psi_a`).
///
/// Two measured consequences, both pinned below:
///   - the SE now falls like 1 / sqrt(n). The old one had
///     no `1 / n` in it at all: `sum(psi^2) / inner_bb` is
///     `mean(psi^2) / mean(psi_b^2)`, in which `n`
///     cancels, so it read 0.3654 / 0.3708 / 0.3613 at
///     n = 300 / 600 / 2400.
///   - the point estimate is no longer persistently
///     biased: 0.8339 / 0.8301 / 0.8503 against a true ATT
///     of 1.0, i.e. stuck at -15% and not converging.
fn expand_v102_cs_dgp(
  n : Int,
  p : Int,
  att : Double,
) -> DoubleMLDIDCrossSectionData {
  let rng = chacha8_rng(42)
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = []
  let d : Array[Double] = []
  let t : Array[Int] = []
  let mut y_acc = y
  let mut d_acc = d
  let mut t_acc = t
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x.set(i, j, rng.double() * 2.0 - 1.0)
    }
    d_acc = d_acc + [if rng.double() < 0.5 { 1.0 } else { 0.0 }]
    t_acc = t_acc + [if rng.double() < 0.5 { 1 } else { 0 }]
    let di = d_acc[i]
    let ti = t_acc[i].to_double()
    let noise = (rng.double() - 0.5) * 0.5
    let yi = di * ti * att + x.get(i, 0) + 0.5 * x.get(i, 1) + noise
    y_acc = y_acc + [yi]
  }
  DoubleMLDIDCrossSectionData::new(x, y_acc, d_acc, t_acc)
}

///|
fn expand_v102_fit(n : Int, att : Double) -> DoubleMLDIDCrossSection {
  DoubleMLDIDCrossSection::new(
    expand_v102_cs_dgp(n, 2, att),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
}

///|
/// The score convention itself: `coef` is the closed-form
/// root of the moment condition, `-mean(psi_b) /
/// mean(psi_a)`, bit for bit (both sides go through the
/// same `mean` and the same division order `var_est`
/// uses). This is the assertion the old argmin fit could
/// not pass: at n = 600 it reported 0.8301487873802966
/// against 0.9917909151155246.
test "didcs102_coef_is_the_moment_root" {
  let f = expand_v102_fit(600, 1.0)
  let mean_a = mean(f.psi_a())
  let mean_b = mean(f.psi_b())
  let expected = -mean_b / mean_a
  inspect(f.coef() == expected, content="true")
}

///|
/// `HC0 == se()` to the bit -- the invariant the other 19
/// `sandwich_se` estimators already satisfy, and the one the
/// v0.91.0 - v0.101.0 comment on this method said could not
/// hold because its `M_inv` was "not `1 / mean(psi_a)` in
/// any principled sense". Measured on the old code:
/// `sandwich_se(hc0) / se() = 0.062367882616389564`.
test "didcs102_hc0_equals_se_bitwise" {
  let f = expand_v102_fit(600, 1.0)
  inspect(f.sandwich_se(SandwichKind::hc0()) == f.se(), content="true")
}

///|
/// Regression guard for the missing `1 / n`. The reported SE
/// must fall roughly like 1 / sqrt(n); measured ratio
/// se(2400) / se(600) = 0.4726. The old (argmin) SE gave
/// 0.9744 for the same two fits.
test "didcs102_se_shrinks_with_sample_size" {
  let se600 = expand_v102_fit(600, 1.0).se()
  let se2400 = expand_v102_fit(2400, 1.0).se()
  let ratio = se2400 / se600
  inspect(ratio > 0.35 && ratio < 0.70, content="true")
}

///|
/// The point estimate converges to the true ATT. DGP ATT is
/// 1.0; measured `coef` = 1.0041 / 0.9918 / 0.9934 at
/// n = 300 / 600 / 2400. The old argmin fit read 0.8503 at
/// n = 2400, i.e. outside this bound.
test "didcs102_coef_recovers_true_att" {
  let f = expand_v102_fit(2400, 1.0)
  inspect((f.coef() - 1.0).abs() < 0.05, content="true")
}

///|
/// The three small-sample corrections, against their
/// defining algebra with one parameter (`k = 1`) and the
/// intercept-only leverage `h_ii = 1 / n`:
///   var(HC1) = var(HC0) * n / (n - 1)
///   var(HC2) = var(HC0) / (1 - 1/n)   = var(HC1)
///   var(HC3) = var(HC0) / (1 - 1/n)^2 = var(HC1)^2 / var(HC0)
/// These are VARIANCE identities and `sandwich_se`
/// returns `sqrt(variance)`, so the scale enters the SE
/// ratios as its square root -- asserting the variance
/// factor against an SE ratio is off by 0.0008, which
/// looks like a plausible tolerance slip and is not.
/// HC2 and HC3 accumulate the scaled terms inside their
/// Kahan accumulators while HC1 multiplies after HC0 has
/// finished, so they agree to rounding rather than to the
/// bit; the 1.0e-9 bounds are for that, not for slack.
test "didcs102_small_sample_correction_algebra" {
  let f = expand_v102_fit(600, 1.0)
  let n = f.psi_a().length().to_double()
  let hc0 = f.sandwich_se(SandwichKind::hc0())
  let hc1 = f.sandwich_se(SandwichKind::hc1())
  let hc2 = f.sandwich_se(SandwichKind::hc2())
  let hc3 = f.sandwich_se(SandwichKind::hc3())
  let scale = (n / (n - 1.0)).sqrt()
  inspect((hc1 / hc0 - scale).abs() < 1.0e-12, content="true")
  inspect(hc1 > hc0, content="true")
  inspect((hc2 / hc1 - 1.0).abs() < 1.0e-9, content="true")
  inspect((hc3 * hc0 / (hc1 * hc1) - 1.0).abs() < 1.0e-9, content="true")
}

///|
/// The cluster path sees the same score and the same
/// `M_inv` as the IID path -- it differs only in how the
/// cross products are summed. `cluster_ids` here are
/// 20 blocks of 30 observations.
test "didcs102_cluster_sandwich_differs_from_iid" {
  let f = expand_v102_fit(600, 1.0)
  let n = f.psi_a().length()
  let cluster_ids : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    cluster_ids[i] = i / 30
  }
  let iid = f.sandwich_se(SandwichKind::hc0())
  let clus = f.cluster_sandwich_se(cluster_ids)
  inspect(clus > 0.0, content="true")
  inspect(clus.is_nan() == false, content="true")
  inspect((clus / iid - 1.0).abs() > 1.0e-6, content="true")
}

///|
/// The multiplier bootstrap builds its influence function
/// from the same score order (`theta * psi_a + psi_b`), and
/// the joint interval reads it. It is not directly
/// observable, so what is pinned is that the joint path
/// still yields a finite, positively-wide interval around
/// the now-unbiased point estimate -- it aborts if
/// `boot_t_stat` is empty, and it divides by `se`.
test "didcs102_bootstrap_runs_on_the_new_score" {
  let f = expand_v102_fit(600, 1.0).bootstrap(n_rep_boot=64)
  let (lo, hi) = f.confint(joint=true)
  inspect(hi - lo > 0.0, content="true")
  inspect(lo.is_nan() == false, content="true")
  inspect(hi.is_nan() == false, content="true")
  inspect(lo < f.coef() && f.coef() < hi, content="true")
}
