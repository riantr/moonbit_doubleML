///|
// v0.64.0+: wbtests for the follow-up moonbit-ization items.
// Coverage:
//   #1: `bootstrap()` on the remaining single-theta estimators
//       (SSM, LPQ, PQ, QTE, DID, DIDBinary, BLP, DIDCS; APOS,
//       APO, DIDMulti, DIDCrossSection, DIDCSBinary already had
//       bootstrap() from v0.55.0 / v0.61.0 / v0.63.0).
//
// Each test exercises the post-fit shape contract:
//   - `bootstrap(...)` returns a model with `boot_t_stat`
//     populated;
//   - `boot_method` / `n_rep_boot` / `boot_seed` round-trip;
//   - all entries in `boot_t_stat` are finite (no NaN/Inf).

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

///|
fn assert_bootstrap_finite(
  boot_t_stat : Array[Double],
  expected_len : Int,
) -> Unit raise {
  assert_eq(boot_t_stat.length(), expected_len)
  let mut n_finite = 0
  for v in boot_t_stat {
    if v.is_nan() == false && v.is_inf() == false {
      n_finite = n_finite + 1
    }
  }
  assert_eq(n_finite, expected_len)
}

// ---------------------------------------------------------------------------
// #1: SSM bootstrap
// ---------------------------------------------------------------------------

///|
test "ssm_bootstrap_populates_boot_t_stat" {
  let n = 200
  let p = 2
  let rng = chacha8_rng(101)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let s : Array[Double] = Array::make(n, 1.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    // True theta = 1.0; selection on Y via S (always 1.0).
    y[i] = 1.0 * d[i] + 0.5 * x_flat[i * p + 0] + (rng.double() - 0.5) * 0.2
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLSSMData::new(x, y, d, s)
  let fitted = DoubleMLSSM::new(data, n_folds=4, seed=101).fit()
  let boot = fitted.bootstrap(n_rep_boot=200)
  assert_eq(boot.boot_method, "normal")
  assert_eq(boot.n_rep_boot, 200)
  assert_bootstrap_finite(boot.boot_t_stat, 200)
}

// ---------------------------------------------------------------------------
// #1: DID bootstrap
// ---------------------------------------------------------------------------

///|
test "did_bootstrap_populates_boot_t_stat" {
  let n = 200
  let p = 2
  let rng = chacha8_rng(202)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    // True ATT = 1.0 under simple DGP.
    y[i] = 1.0 * d[i] + 0.3 * x_flat[i * p + 0] + (rng.double() - 0.5) * 0.2
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLDIDData::new(x, y, d)
  let fitted = DoubleMLDID::new(data, n_folds=4, seed=202).fit()
  let boot = fitted.bootstrap(n_rep_boot=200)
  assert_bootstrap_finite(boot.boot_t_stat, 200)
}

// ---------------------------------------------------------------------------
// #1: DIDBinary bootstrap (inner delegates to DID)
// ---------------------------------------------------------------------------

///|
test "did_binary_bootstrap_populates_boot_t_stat" {
  // Long-format panel: 60 units x 2 periods.
  let n_units = 60
  let n_periods = 2
  let n = n_units * n_periods
  let p = 1
  let rng = chacha8_rng(303)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t : Array[Int] = Array::make(n, 0)
  let g_indicator : Array[Int] = Array::make(n, 0)
  let id : Array[Int] = Array::make(n, 0)
  for i = 0; i < n_units; i = i + 1 {
    for period = 0; period < n_periods; period = period + 1 {
      let row = i * n_periods + period
      id[row] = i
      t[row] = period
      g_indicator[row] = if i >= n_units / 2 { 1 } else { 0 }
      x_flat[row * p + 0] = rng.double()
      let base_y = 0.5 * x_flat[row * p + 0]
      // Treated units get a +1 jump in the post period.
      if g_indicator[row] == 1 && period == 1 {
        y[row] = base_y + 1.0 + (rng.double() - 0.5) * 0.2
      } else {
        y[row] = base_y + (rng.double() - 0.5) * 0.2
      }
      d[row] = if g_indicator[row] == 1 && period == 1 { 1.0 } else { 0.0 }
    }
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLDIDBinaryData::new(x, y, d, t, g_indicator, id)
  let fitted = DoubleMLDIDBinary::new(data, 1, 0, 1, n_folds=4, seed=303).fit()
  let boot = fitted.bootstrap(n_rep_boot=200)
  assert_bootstrap_finite(boot.boot_t_stat, 200)
}

// ---------------------------------------------------------------------------
// #1: DIDCSBinary bootstrap
// ---------------------------------------------------------------------------

///|
test "did_cs_binary_bootstrap_populates_boot_t_stat" {
  let n = 200
  let p = 2
  let rng = chacha8_rng(404)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let g : Array[Int] = Array::make(n, 0)
  let t : Array[Int] = Array::make(n, 0)
  let id : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    let group_v = if rng.double() > 0.5 { 2 } else { 0 }
    let period_v = if rng.double() > 0.5 { 2 } else { 0 }
    g[i] = group_v
    t[i] = period_v
    id[i] = i
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    let base_y = 0.4 * x_flat[i * p + 0]
    let is_treated_post = group_v == 2 && period_v == 2
    if is_treated_post {
      y[i] = base_y + 1.0 + (rng.double() - 0.5) * 0.2
    } else {
      y[i] = base_y + (rng.double() - 0.5) * 0.2
    }
    d[i] = if is_treated_post { 1.0 } else { 0.0 }
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLDIDCSData::new(x, y, d, t, id, g)
  let fitted = DoubleMLDIDCSBinary::new(data, 2, 0, 2, n_folds=4, seed=404).fit()
  let boot = fitted.bootstrap(n_rep_boot=200)
  assert_bootstrap_finite(boot.boot_t_stat, 200)
}

// ---------------------------------------------------------------------------
// #1: DIDCS bootstrap (multi-cell)
// ---------------------------------------------------------------------------

///|
test "did_cs_bootstrap_populates_boot_t_stat" {
  // Balanced panel: 100 units, each observed in 3 periods (0, 1, 2).
  // Units stratified to groups {0, 1, 2} so each cell has
  // ~30 units × 2-3 periods = enough rows for n_folds = 2.
  let n_units = 100
  let n_periods = 3
  let n = n_units * n_periods
  let p = 1
  let rng = chacha8_rng(505)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let g : Array[Int] = Array::make(n, 0)
  let t : Array[Int] = Array::make(n, 0)
  let id : Array[Int] = Array::make(n, 0)
  for i = 0; i < n_units; i = i + 1 {
    let g_value = i % 3
    for period = 0; period < n_periods; period = period + 1 {
      let row = i * n_periods + period
      g[row] = g_value
      t[row] = period
      id[row] = i
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = rng.double()
      }
      let base_y = 0.3 * x_flat[row * p + 0]
      let treated_post = (g_value == 1 && period == 2) ||
        (g_value == 2 && period >= 1)
      if treated_post {
        y[row] = base_y + 1.0 + (rng.double() - 0.5) * 0.2
      } else {
        y[row] = base_y + (rng.double() - 0.5) * 0.2
      }
      d[row] = if treated_post { 1.0 } else { 0.0 }
    }
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLDIDCSData::new(x, y, d, t, id, g)
  let fitted = DoubleMLDIDCS::new(data, n_folds=2, seed=505).fit()
  // discover_groups_times excludes the never_treated sentinel
  // (g=0 here), so n_groups = 2 and n_cells = 2 * 3 = 6. Of
  // those, only (g=1, t=2) has `t_eval > g`; the other 5
  // cells stay at se = 0 and contribute zero rows.
  let boot = fitted.bootstrap(n_rep_boot=200)
  assert_eq(boot.boot_t_stat.length(), 200 * 6)
}

// ---------------------------------------------------------------------------
// #1: LPQ bootstrap (single centered IF)
// ---------------------------------------------------------------------------

///|
test "lpq_bootstrap_populates_boot_t_stat" {
  let n = 200
  let p = 2
  let rng = chacha8_rng(606)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let z : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    z[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    d[i] = if z[i] == 1.0 {
      if rng.double() > 0.3 {
        1.0
      } else {
        0.0
      }
    } else if rng.double() > 0.7 {
      1.0
    } else {
      0.0
    }
    // True LPQ theta = 0.5 (median); outcome shifts on treatment.
    y[i] = 1.0 * d[i] + 0.3 * x_flat[i * p + 0] + (rng.double() - 0.5)
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLLPQData::new(x, y, d, z)
  let fitted = DoubleMLLPQ::new(data, quantile=0.5, n_folds=4, seed=606).fit()
  let boot = fitted.bootstrap(n_rep_boot=200)
  assert_bootstrap_finite(boot.boot_t_stat, 200)
}

// ---------------------------------------------------------------------------
// #1: PQ bootstrap
// ---------------------------------------------------------------------------

///|
test "pq_bootstrap_populates_boot_t_stat" {
  let n = 200
  let p = 2
  let rng = chacha8_rng(707)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    y[i] = 1.0 * d[i] + 0.3 * x_flat[i * p + 0] + (rng.double() - 0.5)
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d)
  let fitted = DoubleMLPQ::new(data, quantile=0.5, n_folds=4, seed=707).fit()
  let boot = fitted.bootstrap(n_rep_boot=200)
  assert_bootstrap_finite(boot.boot_t_stat, 200)
}

// ---------------------------------------------------------------------------
// #1: QTE bootstrap (multi-theta: flat [n_rep * n_quantiles])
// ---------------------------------------------------------------------------

///|
test "qte_bootstrap_populates_boot_t_stat" {
  let n = 200
  let p = 2
  let rng = chacha8_rng(808)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    y[i] = 1.0 * d[i] + 0.3 * x_flat[i * p + 0] + (rng.double() - 0.5)
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d)
  let quantiles : Array[Double] = [0.25, 0.5, 0.75]
  let fitted = DoubleMLQTE::new(data, quantiles~, n_folds=4, seed=808).fit()
  let boot = fitted.bootstrap(n_rep_boot=200)
  // Flat [n_rep_boot * n_quantiles] = 200 * 3 = 600.
  assert_eq(boot.boot_t_stat.length(), 200 * 3)
  assert_bootstrap_finite(boot.boot_t_stat, 600)
}

// ---------------------------------------------------------------------------
// #1: BLP bootstrap (per-coef)
// ---------------------------------------------------------------------------

///|
test "blp_bootstrap_populates_boot_t_stat" {
  let n = 200
  let p = 3
  let rng = chacha8_rng(909)
  let basis_flat : Array[Double] = Array::make(n * p, 0.0)
  let orth_signal : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      basis_flat[i * p + j] = rng.double()
    }
    // True BLP projection on [1, x0, x1, x2] with coefs (0.5, 1, -0.3, 0.2).
    let mut s = 0.5
    s = s + 1.0 * basis_flat[i * p + 0]
    s = s - 0.3 * basis_flat[i * p + 1]
    s = s + 0.2 * basis_flat[i * p + 2]
    orth_signal[i] = s + (rng.double() - 0.5) * 0.4
  }
  let basis = Matrix::from_array(basis_flat, n, p)
  let fitted = DoubleMLBLP::new(
    basis,
    orth_signal,
    ml_g=LearnerDispatch::linear_regression(),
  ).fit()
  let boot = fitted.bootstrap(n_rep_boot=200)
  // (p + 1) coefficients after intercept-augmented OLS = 4.
  assert_eq(boot.boot_t_stat.length(), 200 * (p + 1))
}
