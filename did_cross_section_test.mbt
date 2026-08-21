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

// ---------------------------------------------------------------------------
// v0.21.0+ bootstrap / joint CI tests
// ---------------------------------------------------------------------------

///|
/// v0.21.0+: `bootstrap` populates `boot_t_stat` with
/// `n_rep_boot` t-statistics, one per replication.
test "did_cross_section_bootstrap_basic" {
  let data = build_cross_section_dgp(200, 2, 1.0)
  let fitted = DoubleMLDIDCrossSection::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let booted = fitted.bootstrap(method_name="normal", n_rep_boot=500, seed=2024)
  inspect(booted.boot_t_stat.length(), content="500")
  inspect(booted.boot_method, content="normal")
  inspect(booted.n_rep_boot, content="500")
  inspect(booted.boot_seed, content="2024")
}

///|
/// v0.21.0+: `bootstrap` is reproducible given a
/// fixed seed.
test "did_cross_section_bootstrap_deterministic" {
  let data = build_cross_section_dgp(200, 2, 1.0)
  let f1 = DoubleMLDIDCrossSection::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let f2 = DoubleMLDIDCrossSection::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let b1 = f1.bootstrap(method_name="normal", n_rep_boot=100, seed=2024)
  let b2 = f2.bootstrap(method_name="normal", n_rep_boot=100, seed=2024)
  let mut all_match = true
  for i = 0; i < b1.boot_t_stat.length(); i = i + 1 {
    if (b1.boot_t_stat[i] - b2.boot_t_stat[i]).abs() > 1.0e-15 {
      all_match = false
    }
  }
  inspect(all_match, content="true")
}

///|
/// v0.21.0+: `boot_t_stat` has approximately mean 0
/// and standard deviation 1 under the null (since
/// it's a bootstrap of a t-statistic).
test "did_cross_section_bootstrap_moments" {
  let data = build_cross_section_dgp(500, 2, 1.0)
  let fitted = DoubleMLDIDCrossSection::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let booted = fitted.bootstrap(
    method_name="normal",
    n_rep_boot=1000,
    seed=2024,
  )
  let n_boot = booted.boot_t_stat.length()
  let n_d = n_boot.to_double()
  let mut mean = 0.0
  for i = 0; i < n_boot; i = i + 1 {
    mean = mean + booted.boot_t_stat[i]
  }
  mean = mean / n_d
  let mut ss = 0.0
  for i = 0; i < n_boot; i = i + 1 {
    let d = booted.boot_t_stat[i] - mean
    ss = ss + d * d
  }
  let sd = (ss / n_d).sqrt()
  // Mean should be ~0 (within ~0.1), SD should be ~1
  // (within ~0.1). The Monte-Carlo error is O(1/sqrt(n_boot))
  // ≈ 0.03.
  inspect(mean.abs() < 0.15, content="true")
  inspect((sd - 1.0).abs() < 0.15, content="true")
}

///|
/// v0.21.0+: `bootstrap` with `method_name = "Bayes"`
/// produces a different `boot_t_stat` (mean still ~0,
/// SD still ~1) but a different draw.
test "did_cross_section_bootstrap_bayes" {
  let data = build_cross_section_dgp(200, 2, 1.0)
  let fitted = DoubleMLDIDCrossSection::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let booted_normal = fitted.bootstrap(
    method_name="normal",
    n_rep_boot=500,
    seed=2024,
  )
  let booted_bayes = fitted.bootstrap(
    method_name="Bayes",
    n_rep_boot=500,
    seed=2024,
  )
  // The two draws should differ.
  let mut differ = false
  for i = 0; i < 10; i = i + 1 {
    if (booted_normal.boot_t_stat[i] - booted_bayes.boot_t_stat[i]).abs() > 0.1 {
      differ = true
    }
  }
  inspect(differ, content="true")
  inspect(booted_bayes.boot_method, content="Bayes")
}

///|
/// v0.21.0+: `bootstrap` with `method_name = "wild"`.
test "did_cross_section_bootstrap_wild" {
  let data = build_cross_section_dgp(200, 2, 1.0)
  let fitted = DoubleMLDIDCrossSection::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let booted = fitted.bootstrap(method_name="wild", n_rep_boot=500, seed=2024)
  inspect(booted.boot_t_stat.length(), content="500")
  inspect(booted.boot_method, content="wild")
}

///|
/// v0.21.0+: `confint(joint = true)` requires
/// `bootstrap` to be called first; without bootstrap
/// the call aborts.
test "panic_did_cross_section_joint_confint_without_bootstrap" {
  let data = build_cross_section_dgp(200, 2, 1.0)
  let fitted = DoubleMLDIDCrossSection::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let _ = fitted.confint(joint=true)
}

///|
/// v0.21.0+: `confint(joint = true)` returns a wider
/// interval than `confint(joint = false)` when the
/// empirical bootstrap quantile exceeds the normal
/// critical value.
test "did_cross_section_joint_confint_wider" {
  let data = build_cross_section_dgp(200, 2, 1.0)
  let fitted = DoubleMLDIDCrossSection::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let booted = fitted.bootstrap(
    method_name="normal",
    n_rep_boot=1000,
    seed=2024,
  )
  let (lo_pw, hi_pw) = booted.confint(joint=false)
  let (lo_jt, hi_jt) = booted.confint(joint=true)
  // Joint CI half-width should be >= pointwise
  // (the joint critical value is the empirical
  // (1+level)/2 quantile of |boot_t_stat|, which
  // is at least the median of |boot_t_stat| ≈
  // 0.67 by symmetry, but typically close to 1.96).
  let hw_pw = (hi_pw - lo_pw) / 2.0
  let hw_jt = (hi_jt - lo_jt) / 2.0
  inspect(hw_jt >= hw_pw - 1.0e-12, content="true")
}

///|
/// v0.21.0+: `confint(level = 0.99)` produces a
/// wider interval than the default 95%.
test "did_cross_section_confint_custom_level" {
  let data = build_cross_section_dgp(200, 2, 1.0)
  let fitted = DoubleMLDIDCrossSection::new(data, n_folds=2, n_rep=1, seed=3141).fit()
  let (lo_95, hi_95) = fitted.confint()
  let (lo_99, hi_99) = fitted.confint(level=0.99)
  let hw_95 = (hi_95 - lo_95) / 2.0
  let hw_99 = (hi_99 - lo_99) / 2.0
  inspect(hw_99 > hw_95, content="true")
}

///|
/// v0.21.0+: `norm_cdf` and `norm_ppf` are inverses
/// of each other (within tolerance).
test "did_cross_section_norm_cdf_ppf_inverse" {
  // For a few representative quantiles, Phi(z) and
  // ppf(Phi(z)) should agree within ~1e-4.
  let test_vals : Array[Double] = [0.1, 0.25, 0.5, 0.75, 0.9, 0.95, 0.99]
  let mut all_match = true
  for i = 0; i < test_vals.length(); i = i + 1 {
    let p = test_vals[i]
    let z = norm_ppf(p)
    let p_recovered = norm_cdf(z)
    if (p_recovered - p).abs() > 1.0e-4 {
      all_match = false
    }
  }
  inspect(all_match, content="true")
}

///|
/// v0.21.0+: `norm_ppf(0.975) ≈ 1.96` (within the
/// 1.3e-6 accuracy of the bisection-based formula).
test "did_cross_section_norm_ppf_975" {
  let z = norm_ppf(0.975)
  inspect((z - 1.959963984540054).abs() < 1.0e-5, content="true")
}
