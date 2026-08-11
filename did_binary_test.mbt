///|
/// End-to-end preprocessing: with 4 units × 2 periods where 3 are
/// treated (`g = 1`) and 1 is never-treated (`g = 0`), the
/// wide-format subset should contain 4 rows (one per unit) with
/// `d = 1` for the 3 treated units and `d = 0` for the
/// never-treated unit.
test "did_binary_preprocess_keeps_both_periods" {
  let n = 8 // 4 units × 2 periods
  let p = 1
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = [0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0]
  let d : Array[Double] = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0]
  let t : Array[Int] = [0, 1, 0, 1, 0, 1, 0, 1]
  // g[unit]: units 0,1,2 are treated (g=1); unit 3 never-treated (g=0)
  let g : Array[Int] = [1, 1, 1, 1, 1, 1, 0, 0]
  // id: 0,1,2,3 each with both periods
  let id : Array[Int] = [0, 0, 1, 1, 2, 2, 3, 3]
  let data = DoubleMLDIDBinaryData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t,
    g,
    id,
  )
  // Drive preprocessing via the public fit interface, then inspect
  // the resulting wide-format subset through the public accessor
  // `n_obs_subset`.
  let fitted = DoubleMLDIDBinary::new(data, 1, 0, 1).fit()
  inspect(fitted.n_obs_subset(), content="4")
  // d (G_indicator): units 0,1,2 are treated (d=1); unit 3 is control (d=0)
  let d_wide = fitted.inner.data.d
  inspect(d_wide[0], content="1")
  inspect(d_wide[1], content="1")
  inspect(d_wide[2], content="1")
  inspect(d_wide[3], content="0")
  // y = y_post - y_pre = 1 - 0 = 1 for all units
  let y_wide = fitted.inner.data.y
  for i = 0; i < 4; i = i + 1 {
    inspect(y_wide[i], content="1")
  }
}

///|
/// End-to-end: the binary DID estimator should recover a known
/// ATT on a synthetic panel DGP. The pre-period outcome is
/// `y_pre = x @ 1`, the post-period is `y_post = x @ 1 + theta *
/// d_post + noise`, with `theta = 1.0`. After preprocessing
/// (`y_diff = y_post - y_pre`), the wide-format outcome is
/// approximately `theta * d` (the `x @ 1` terms cancel in the
/// difference) plus noise. With enough observations the estimator
/// should recover `theta ≈ 1.0` within a few SE.
test "did_binary_recovers_known_att" {
  let n_units = 400
  let p = 3
  let n = n_units * 2 // 2 periods
  let theta0 = 1.0
  // Build panel: each unit has 2 rows (t=0, t=1).
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  let t : Array[Int] = Array::make(n, 0)
  let g : Array[Int] = Array::make(n, 0)
  let id : Array[Int] = Array::make(n, 0)
  let bytes = seed_to_bytes(7)
  let rng = @random.Rand::chacha8(seed=Bytes::from_array(bytes))
  for u = 0; u < n_units; u = u + 1 {
    // Each unit's x is drawn once (time-invariant covariates).
    let xu : Array[Double] = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      xu[j] = rng.double() * 2.0 - 1.0
    }
    let pre = 2 * u
    let post = 2 * u + 1
    // Half the units are treated (`g = 1`), the other half are
    // never-treated (`g = 0`). Treatment changes `d` in the post
    // period for treated units.
    let is_treated = if u % 2 == 0 { 1 } else { 0 }
    for k = 0; k < 2; k = k + 1 {
      let row = if k == 0 { pre } else { post }
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = xu[j]
      }
      t[row] = k
      id[row] = u
      g[row] = is_treated
      if is_treated == 1 && k == 1 {
        d[row] = 1.0
      } else {
        d[row] = 0.0
      }
      let mut y_val = 0.0
      for j = 0; j < p; j = j + 1 {
        y_val = y_val + xu[j]
      }
      if k == 1 && is_treated == 1 {
        y_val = y_val + theta0
      }
      // Small noise.
      y_val = y_val + 0.05 * (rng.double() - 0.5)
      y[row] = y_val
    }
  }
  let data = DoubleMLDIDBinaryData::new(
    Matrix::from_array(x_flat, n, p),
    y,
    d,
    t,
    g,
    id,
  )
  let fitted = DoubleMLDIDBinary::new(
    data,
    1,
    0,
    1,
    control_group="never_treated",
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let coef = fitted.coef()
  let se = fitted.se()
  // The wide-format subset has n_units rows.
  inspect(fitted.n_obs_subset() > 0, content="true")
  // ATT should be within 0.2 of true theta = 1.0
  inspect((coef - theta0).abs() < 0.2, content="true")
  inspect(se > 0.0, content="true")
  // The 95% CI should contain theta0.
  let (lo, hi) = fitted.confint()
  inspect(lo < theta0, content="true")
  inspect(hi > theta0, content="true")
}