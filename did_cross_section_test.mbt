///|
/// Helper: build a hand-rolled DGP for the
/// cross-section DID. n units, each with one
/// observation, treatment d, post-period t, and
/// outcome y. The true ATT is `att` (constant),
/// and the data-generating process is:
///   x_i ~ U(-1, 1)^p
///   d_i ~ Bernoulli(0.5)
///   t_i ~ Bernoulli(0.5)
///   y_i = d_i * t_i * att + x_i[0] + 0.5 * x_i[1] + noise
/// so the true ATT = att. Returns the data container.
fn build_cross_section_dgp(
  n : Int,
  p : Int,
  att : Double,
) -> DoubleMLDIDCrossSectionData {
  // Use a fixed-seed chacha8 RNG for reproducibility.
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
      // U(-1, 1) — fine for our purposes; we just
      // need a non-degenerate covariate distribution.
      x.set(i, j, rng.double() * 2.0 - 1.0)
    }
    // Bernoulli(0.5) for d, t.
    d_acc = d_acc + [if rng.double() < 0.5 { 1.0 } else { 0.0 }]
    t_acc = t_acc + [if rng.double() < 0.5 { 1 } else { 0 }]
    // y = d * t * att + x[0] + 0.5 * x[1] + noise.
    let di = d_acc[i]
    let ti = t_acc[i].to_double()
    let noise = (rng.double() - 0.5) * 0.5
    let yi = di * ti * att + x.get(i, 0) + 0.5 * x.get(i, 1) + noise
    y_acc = y_acc + [yi]
  }
  DoubleMLDIDCrossSectionData::new(x, y_acc, d_acc, t_acc)
}

///|
/// `DoubleMLDIDCrossSectionData` validates that
/// `d` and `t` are binary {0, 1}.
test "panic_did_cross_section_rejects_non_binary_d" {
  let x = Matrix::zeros(5, 1)
  let _ = DoubleMLDIDCrossSectionData::new(
    x,
    [0.0, 0.0, 0.0, 0.0, 0.0],
    [0.0, 0.5, 1.0, 0.0, 1.0],
    [0, 0, 1, 1, 1],
  )
}

///|
/// `DoubleMLDIDCrossSectionData` requires `t` to have
/// both 0 and 1 (a 1-period cross-section is
/// degenerate).
test "panic_did_cross_section_rejects_t_all_zero" {
  let x = Matrix::zeros(5, 1)
  let _ = DoubleMLDIDCrossSectionData::new(
    x,
    [0.0, 0.0, 0.0, 0.0, 0.0],
    [0.0, 0.0, 1.0, 1.0, 1.0],
    [0, 0, 0, 0, 0],
  )
}

///|
/// `DoubleMLDIDCrossSectionData::n_obs` and
/// `n_features` accessors.
test "did_cross_section_data_accessors" {
  let data = build_cross_section_dgp(50, 3, 1.0)
  inspect(data.n_obs(), content="50")
  inspect(data.n_features(), content="3")
}

///|
/// v0.20.0+: end-to-end. Build a 500-unit DGP with
/// true ATT = 1.0, fit the cross-section DID, and
/// check that the ATT estimate is within 0.5 of the
/// true value (loose because n=500 with the
/// closed-form linear learner).
test "did_cross_section_recovers_known_att" {
  let data = build_cross_section_dgp(500, 3, 1.0)
  let fitted = DoubleMLDIDCrossSection::new(
    data,
    n_folds=2,
    n_rep=1,
    seed=3141,
    score="observational",
    in_sample_normalization=false,
  ).fit()
  let att = fitted.coef()
  let se = fitted.se()
  // ATT estimate should be in [0.5, 1.5].
  inspect(att > 0.5 && att < 1.5, content="true")
  // SE should be positive and finite.
  inspect(se > 0.0 && se < 5.0, content="true")
  // 95% CI should contain the true ATT.
  let (lo, hi) = fitted.confint()
  inspect(lo <= 1.0 && 1.0 <= hi, content="true")
}

///|
/// v0.20.0+: experimental score (A/B-test setting).
/// The propensity `m` is not used in the score; the
/// ATT estimate should still be valid (and is
/// typically closer to the true ATT in the
/// randomized-treatment regime).
test "did_cross_section_experimental_score" {
  let data = build_cross_section_dgp(500, 3, 1.0)
  let fitted = DoubleMLDIDCrossSection::new(
    data,
    n_folds=2,
    n_rep=1,
    seed=3141,
    score="experimental",
    in_sample_normalization=false,
  ).fit()
  let att = fitted.coef()
  // ATT estimate should be in [0.5, 1.5] for the
  // randomized-treatment DGP.
  inspect(att > 0.5 && att < 1.5, content="true")
}

///|
/// v0.20.0+: in-sample normalization variant.
/// Same DGP, with `in_sample_normalization = true`.
test "did_cross_section_in_sample_normalization" {
  let data = build_cross_section_dgp(500, 3, 1.0)
  let fitted = DoubleMLDIDCrossSection::new(
    data,
    n_folds=2,
    n_rep=1,
    seed=3141,
    score="observational",
    in_sample_normalization=true,
  ).fit()
  let att = fitted.coef()
  // ATT estimate should be in [0.5, 1.5] for the
  // randomized-treatment DGP.
  inspect(att > 0.5 && att < 1.5, content="true")
}

///|
/// v0.20.0+: psi_a is accessible post-fit, length
/// `n_obs`, and is the negative of the
/// treatment-weighted indicator.
test "did_cross_section_psi_a_basic" {
  let data = build_cross_section_dgp(100, 2, 1.0)
  let fitted = DoubleMLDIDCrossSection::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let psi_a = fitted.psi_a()
  inspect(psi_a.length(), content="100")
  // `psi_a[i] = -d[i] / p_hat` for observational,
  // so for treated units psi_a < 0 and for
  // untreated units psi_a = 0.
  let mut any_nonzero = false
  for i = 0; i < psi_a.length(); i = i + 1 {
    if psi_a[i] < -1.0e-12 {
      any_nonzero = true
    }
  }
  inspect(any_nonzero, content="true")
}

///|
/// v0.20.0+: psi_b is accessible post-fit, length
/// `n_obs`, and the sum of (psi_a + theta * psi_b)
/// is approximately zero (the orthogonalization
/// property).
test "did_cross_section_orthogonalization" {
  let data = build_cross_section_dgp(200, 2, 1.0)
  let fitted = DoubleMLDIDCrossSection::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let psi_a = fitted.psi_a()
  let psi_b = fitted.psi_b()
  let theta = fitted.coef()
  let n = psi_a.length().to_double()
  let mut sum_psi = 0.0
  for i = 0; i < psi_a.length(); i = i + 1 {
    sum_psi = sum_psi + psi_a[i] + theta * psi_b[i]
  }
  // The mean of the influence function should be
  // approximately zero (the sample analogue of
  // E[psi] = 0). The variance is the SE; for n=200
  // the mean should be O(SE / sqrt(n)) ~ O(0.1).
  inspect((sum_psi / n).abs() < 1.0, content="true")
}

///|
/// v0.20.0+: nuisance prediction accessors are
/// populated post-fit.
test "did_cross_section_predictions" {
  let data = build_cross_section_dgp(100, 2, 1.0)
  let fitted = DoubleMLDIDCrossSection::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  inspect(fitted.predictions_g_d0_t0().length(), content="100")
  inspect(fitted.predictions_g_d0_t1().length(), content="100")
  inspect(fitted.predictions_g_d1_t0().length(), content="100")
  inspect(fitted.predictions_g_d1_t1().length(), content="100")
  inspect(fitted.predictions_m().length(), content="100")
}

///|
/// v0.20.0+: confint returns a 95% interval
/// centered on the ATT estimate.
test "did_cross_section_confint_centered" {
  let data = build_cross_section_dgp(200, 2, 1.0)
  let fitted = DoubleMLDIDCrossSection::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let theta = fitted.coef()
  let se = fitted.se()
  let (lo, hi) = fitted.confint()
  let z = 1.959963984540054
  inspect((lo - (theta - z * se)).abs() < 1.0e-12, content="true")
  inspect((hi - (theta + z * se)).abs() < 1.0e-12, content="true")
}

///|
/// v0.20.0+: ATT is unchanged across re-fits with
/// the same seed (deterministic).
test "did_cross_section_deterministic" {
  let data = build_cross_section_dgp(200, 2, 1.0)
  let f1 = DoubleMLDIDCrossSection::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let f2 = DoubleMLDIDCrossSection::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  inspect((f1.coef() - f2.coef()).abs() < 1.0e-15, content="true")
  inspect((f1.se() - f2.se()).abs() < 1.0e-15, content="true")
}
