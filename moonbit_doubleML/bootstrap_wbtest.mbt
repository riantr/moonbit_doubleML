///|
// Whitebox tests for bootstrap.mbt (v0.55.0 extraction).
//
// `bootstrap.mbt` lifts the per-cell multiplier-bootstrap
// t-statistic formula out of `DoubleMLDIDMulti::bootstrap` and
// `DoubleMLDIDCrossSection::bootstrap`. The two call sites share
// the same core:
//
//   boot_t_stat[b, k] = sum_i w[b, i] * psi_k[i] /
//                        (sqrt(n) * se_k)
//
// where `b` indexes bootstrap reps, `k` indexes thetas,
// `w` is the multiplier weight matrix, `psi_k` is the
// per-cell influence function, and `se_k` is the per-cell SE.
//
// These wbtests pin the formula. The full estimator-level
// regression coverage (DID-multi panel bootstrap, DID-CS
// cross-section bootstrap) is exercised by the existing
// `validate_*_with_python.py` cross-validators and by
// the `did_multi_test.mbt` / `did_cross_section_test.mbt`
// suites, which pass byte-equivalently after the refactor.

///|
test "bootstrap_wbtest_t_stat_n_thetas_1_manual" {
  // 1-theta case (matches DoubleMLDIDCrossSection usage).
  // Build by hand, compare to did_bootstrap_t_stat.
  let n_obs = 50
  let n_rep_boot = 5
  let psi : Array[Double] = Array::make(n_obs, 0.0)
  for i = 0; i < n_obs; i = i + 1 {
    psi[i] = (i.to_double() + 1.0) * 0.1
  }
  let se_psi = {
    let mut ss = 0.0
    for i = 0; i < n_obs; i = i + 1 {
      ss = ss + psi[i] * psi[i]
    }
    (ss / n_obs.to_double()).sqrt()
  }
  let weights : Array[Double] = Array::make(n_rep_boot * n_obs, 1.0)
  let se_flat : Array[Double] = [se_psi]
  let boot = did_bootstrap_t_stat(weights, psi, se_flat, n_rep_boot, n_obs, 1)
  inspect(boot.length(), content="5")
  // With w=1: boot_t_stat[b] = sum_i psi[i] / (sqrt(n) * se_psi)
  let expected_sum : Double = {
    let mut s = 0.0
    for i = 0; i < n_obs; i = i + 1 {
      s = s + psi[i]
    }
    s
  }
  let denom = n_obs.to_double().sqrt() * se_psi
  let expected = expected_sum / denom
  for b = 0; b < n_rep_boot; b = b + 1 {
    // Hand-computed expected equals helper output (constant per b
    // because weights are uniform).
    let diff = (boot[b] - expected).abs()
    inspect(diff < 1.0e-12, content="true")
  }
}

///|
test "bootstrap_wbtest_t_stat_n_thetas_3_known_weights" {
  // 3-thetas case (matches DoubleMLDIDMulti: psi_k[i] =
  // psi_matrix[(gi*n_periods + pi) * n_obs + i]). Build a small
  // panel with 3 group-time combinations and verify the helper
  // returns the expected matrix product.
  let n_obs = 20
  let n_rep_boot = 4
  let n_thetas = 3
  // psi = [theta0_row, theta1_row, theta2_row], each length n_obs.
  // Row k uses seed-dependent values: psi[k*n_obs + i] = (k+1) * i.
  let psi : Array[Double] = Array::make(n_thetas * n_obs, 0.0)
  for k = 0; k < n_thetas; k = k + 1 {
    for i = 0; i < n_obs; i = i + 1 {
      psi[k * n_obs + i] = (k + 1).to_double() * i.to_double()
    }
  }
  let se_flat : Array[Double] = [1.0, 2.0, 3.0]
  // Weights: w[b, i] = b+1 (all rows equal within a rep).
  let weights : Array[Double] = Array::make(n_rep_boot * n_obs, 0.0)
  for b = 0; b < n_rep_boot; b = b + 1 {
    for i = 0; i < n_obs; i = i + 1 {
      weights[b * n_obs + i] = (b + 1).to_double()
    }
  }
  let boot = did_bootstrap_t_stat(
    weights, psi, se_flat, n_rep_boot, n_obs, n_thetas,
  )
  inspect(boot.length(), content="12")
  let n_d = n_obs.to_double()
  let sqrt_n = n_d.sqrt()
  // Hand-compute expected: boot[b, k] = (b+1) * sum_i psi[k*n_obs+i] / (sqrt_n * se_flat[k])
  for b = 0; b < n_rep_boot; b = b + 1 {
    for k = 0; k < n_thetas; k = k + 1 {
      let mut s = 0.0
      for i = 0; i < n_obs; i = i + 1 {
        s = s + psi[k * n_obs + i]
      }
      let expected = (b + 1).to_double() * s / (sqrt_n * se_flat[k])
      let actual = boot[b * n_thetas + k]
      let diff = (actual - expected).abs()
      let rel = if expected == 0.0 { diff } else { diff / expected.abs() }
      inspect(rel < 1.0e-9, content="true")
    }
  }
}

///|
test "bootstrap_wbtest_t_stat_skips_zero_se_rows" {
  // When se[k] = 0 (pre-treatment / empty cell), the helper
  // should leave boot_t_stat[b, k] = 0 for all b. The DIDMulti
  // convention matches this: empty cells contribute no bootstrap
  // variation.
  let n_obs = 10
  let n_rep_boot = 3
  let n_thetas = 2
  let psi : Array[Double] = Array::make(n_thetas * n_obs, 1.0) // all 1's
  let se_flat : Array[Double] = [1.0, 0.0] // theta 1 has se=0
  let weights : Array[Double] = Array::make(n_rep_boot * n_obs, 2.0) // all 2's
  let boot = did_bootstrap_t_stat(
    weights, psi, se_flat, n_rep_boot, n_obs, n_thetas,
  )
  // theta 0 (se=1) rows should be non-zero; theta 1 (se=0) rows should be 0.
  for b = 0; b < n_rep_boot; b = b + 1 {
    let actual_zero_row = boot[b * n_thetas + 1]
    inspect(actual_zero_row, content="0")
    // For se=1: boot = 2 * sum(1's) / (sqrt(10) * 1) = 2*10 / sqrt(10) = 20/sqrt(10)
    let expected_nonzero = 2.0 * 10.0 / n_obs.to_double().sqrt()
    let actual_nonzero_row = boot[b * n_thetas + 0]
    let diff = (actual_nonzero_row - expected_nonzero).abs()
    inspect(diff < 1.0e-9, content="true")
  }
}

///|
test "bootstrap_wbtest_t_stat_negative_weights" {
  // Multiplier bootstrap weights can be negative (Bayes method,
  // centred Rademacher for wild bootstrap). Verify the helper
  // handles negative weights correctly (no abs() / sign flip).
  let n_obs = 4
  let n_rep_boot = 2
  let n_thetas = 1
  let psi : Array[Double] = [1.0, 2.0, 3.0, 4.0]
  let se_flat : Array[Double] = [1.0]
  // Weights: rep 0 = [+1, -1, +1, -1], rep 1 = [+2, -2, +2, -2].
  let weights : Array[Double] = [1.0, -1.0, 1.0, -1.0, 2.0, -2.0, 2.0, -2.0]
  let boot = did_bootstrap_t_stat(
    weights, psi, se_flat, n_rep_boot, n_obs, n_thetas,
  )
  let sqrt_n = 2.0 // sqrt(4)
  // rep 0: (+1)*1 + (-1)*2 + (+1)*3 + (-1)*4 = 1-2+3-4 = -2
  // rep 1: 2*(-2) = -4
  let expected_0 = -2.0 / (sqrt_n * 1.0)
  let expected_1 = -4.0 / (sqrt_n * 1.0)
  let diff_0 = (boot[0] - expected_0).abs()
  let diff_1 = (boot[1] - expected_1).abs()
  inspect(diff_0 < 1.0e-12, content="true")
  inspect(diff_1 < 1.0e-12, content="true")
}

///|
test "bootstrap_wbtest_t_stat_zero_psi_no_op" {
  // Edge case: all psi = 0 (degenerate DGP, e.g. all-zero
  // outcome variance). The helper should produce all-zero
  // boot_t_stat regardless of weights.
  let n_obs = 5
  let n_rep_boot = 3
  let n_thetas = 2
  let psi : Array[Double] = Array::make(n_thetas * n_obs, 0.0)
  let se_flat : Array[Double] = [1.0, 1.0]
  let weights : Array[Double] = Array::make(n_rep_boot * n_obs, 5.0) // all 5's
  let boot = did_bootstrap_t_stat(
    weights, psi, se_flat, n_rep_boot, n_obs, n_thetas,
  )
  for i = 0; i < boot.length(); i = i + 1 {
    inspect(boot[i], content="0")
  }
}

///|
test "bootstrap_wbtest_t_stat_determinism" {
  // Same (weights, psi, se) inputs -> same outputs.
  // Pins that the helper has no hidden RNG state / mutation.
  let n_obs = 30
  let n_rep_boot = 5
  let n_thetas = 3
  let psi : Array[Double] = Array::make(n_thetas * n_obs, 0.0)
  let se_flat : Array[Double] = [1.5, 0.7, 2.1]
  let weights : Array[Double] = Array::make(n_rep_boot * n_obs, 0.0)
  for k = 0; k < n_thetas; k = k + 1 {
    for i = 0; i < n_obs; i = i + 1 {
      psi[k * n_obs + i] = (k * n_obs + i).to_double() * 0.13
    }
  }
  for b = 0; b < n_rep_boot; b = b + 1 {
    for i = 0; i < n_obs; i = i + 1 {
      weights[b * n_obs + i] = ((b + 1) * (i + 1)).to_double() * 0.07
    }
  }
  let boot_a = did_bootstrap_t_stat(
    weights, psi, se_flat, n_rep_boot, n_obs, n_thetas,
  )
  let boot_b = did_bootstrap_t_stat(
    weights, psi, se_flat, n_rep_boot, n_obs, n_thetas,
  )
  inspect(boot_a.length(), content="15")
  inspect(boot_b.length(), content="15")
  for i = 0; i < boot_a.length(); i = i + 1 {
    let diff = (boot_a[i] - boot_b[i]).abs()
    inspect(diff, content="0")
  }
}
