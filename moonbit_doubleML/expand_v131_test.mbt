//| v0.131.6 gates -- the DID ATT score's `nu2` is upstream's PRIMARY formula.
//
//| Context. `DoubleMLDID` (and `DoubleMLDIDBinary`, which delegates into it)
//| used to route through the shared `irm_style_sensitivity` helper, which
//| computes `nu2 = mean(psi_a^2)`. That is upstream's documented FALLBACK
//| (`double_ml.py:1634-1641`) -- used only when the primary comes out
//| non-positive -- applied unconditionally and to the wrong variable.
//| v0.131.6 routes both DID entry points through
//| `DoubleMLDID::sensitivity_nu2_elements` instead, transcribing upstream
//| `did/did.py:332-353`.
//
//| `_verify/_oracle_1316.py` proves the transcription against real upstream
//| 0.11.4 on the port's own fixture: relative difference `0.000e+00` for all
//| three (score, in_sample_normalization) configurations, plus a control that
//| reproduces the MoonBit values to ~1e-16.

///|
fn v1316_did_data(n : Int, p : Int, seed : Int) -> DoubleMLDIDData raise {
  let rng = chacha8_rng(seed)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let mut lin = 0.0
    for j = 0; j < p; j = j + 1 {
      let v = rng.double() * 2.0 - 1.0
      x_flat[i * p + j] = v
      lin = lin + (0.5 - 0.15 * j.to_double()) * v
    }
    let u = rng.double()
    let raw = 0.4 + lin
    let pi = if raw < 0.02 { 0.02 } else if raw > 0.98 { 0.98 } else { raw }
    let di = if u < pi { 1.0 } else { 0.0 }
    d[i] = di
    y[i] = lin + 0.3 * (rng.double() - 0.5) + di * 1.0
  }
  DoubleMLDIDData::new(Matrix::from_array(x_flat, n, p), y, d)
}

///|
fn v1316_did_fit(
  data : DoubleMLDIDData,
  score : String,
  isn : Bool,
) -> DoubleMLDID {
  DoubleMLDID::new(
    data,
    n_folds=2,
    n_rep=1,
    seed=3141,
    score~,
    in_sample_normalization=isn,
  ).fit()
}

///|
/// GATE 1 -- `nu2` equals the transcription recomputed from `(d, m_hat)`.
///
/// Written out longhand rather than calling the production method, so the gate
/// pins the FORMULA and would fail if someone edited the helper. This is the
/// `observational`, `in_sample_normalization = false` branch -- the one the
/// port's default arguments select, i.e. the one that was wrong.
/// `did/did.py:344-345`:
/// ```text
///   m_alpha = (d / p^2) * (1 + pw);   pw = m_hat / (1 - m_hat)
///   rr      = d / p - ((1 - d) / p) * pw
///   nu2     = mean(2 * m_alpha - rr^2)
/// ```
test "v1316_did_nu2_is_upstreams_primary_formula_not_mean_psi_a_squared" {
  let est = v1316_did_fit(v1316_did_data(600, 3, 11), "observational", false)
  let r = est.sensitivity_analysis()
  let d = est.data.d
  let m = est.predictions_m()
  let n = d.length()
  let n_d = n.to_double()
  let mut sum_d = 0.0
  for i = 0; i < n; i = i + 1 {
    sum_d = sum_d + d[i]
  }
  let p_hat = sum_d / n_d
  let mut acc = 0.0
  for i = 0; i < n; i = i + 1 {
    let di = d[i]
    let pw = if 1.0 - m[i] > 1.0e-12 { m[i] / (1.0 - m[i]) } else { 0.0 }
    let m_alpha = di / (p_hat * p_hat) * (1.0 + pw)
    let rr = di / p_hat - (1.0 - di) / p_hat * pw
    acc = acc + 2.0 * m_alpha - rr * rr
  }
  let expected = acc / n_d
  // Tolerance, not equality: `acc` is a 600-term sequential sum of differently
  // scaled quantities, so it is not the same floating-point sequence the
  // implementation builds. Exact equality is only asserted where the
  // computation IS a single expression.
  let tol = 1.0e-9 * expected.abs()
  assert_true((r.nu2 - expected).abs() <= tol)
  assert_true(r.nu2 == 47.70752003810404)
  // The old convention, `mean(psi_a^2)`, gave 2.3715415019762798 on this
  // fixture. If this ever equals that again, the fallback is back.
  assert_true((r.nu2 - 2.3715415019762798).abs() > 1.0)
}

///|
/// GATE 2 -- `in_sample_normalization` actually reaches `nu2`.
///
/// This is the discriminating gate for the bug. Under `mean(psi_a^2)` the
/// flag was completely inert: the old implementation returned
/// `nu2 = 2.3715415019762798` for BOTH settings. Requiring the two branches to
/// differ kills any reintroduction of a flag-blind path.
/// `did/did.py:339-342`:
/// ```text
///   w_d0    = (1 - d) * pw
///   m_alpha = (d / p) * (1/p + pw / mean(w_d0))
///   rr      = d / p - w_d0 / mean(w_d0)
/// ```
test "v1316_did_in_sample_normalization_reaches_nu2" {
  let data = v1316_did_data(600, 3, 11)
  let off = v1316_did_fit(data, "observational", false).sensitivity_analysis()
  let on = v1316_did_fit(data, "observational", true).sensitivity_analysis()
  assert_true(off.nu2 != on.nu2)
  assert_true(off.nu2 == 47.70752003810404)
  assert_true(on.nu2 == 54.452951164428164)
  // The flag must not disturb anything the nu2 path does not own.
  let a = v1316_did_fit(data, "observational", false)
  let b = v1316_did_fit(data, "observational", true)
  assert_true(
    a.sensitivity_analysis().sigma2 == b.sensitivity_analysis().sigma2,
  )
}

///|
/// GATE 3 -- the `experimental` score ignores `m_hat` entirely.
///
/// `did/did.py:349-350` uses only `p_hat`; there is no propensity weight in
/// that branch. Upstream also warns that `ml_m` is ignored there
/// (`did.py:123`). Asserting `nu2` depends on `d` alone pins the branch
/// structure: a refactor that routed `experimental` through the propensity
/// weight would break it.
/// ```text
///   m_alpha = 1/p + 1/(1-p)
///   rr      = d/p - (1-d)/(1-p)
/// ```
test "v1316_did_experimental_score_nu2_ignores_the_propensity" {
  let est = v1316_did_fit(v1316_did_data(600, 3, 11), "experimental", false)
  let r = est.sensitivity_analysis()
  let d = est.data.d
  let n = d.length()
  let n_d = n.to_double()
  let mut sum_d = 0.0
  for i = 0; i < n; i = i + 1 {
    sum_d = sum_d + d[i]
  }
  let p_hat = sum_d / n_d
  let inv_p = 1.0 / p_hat
  let inv_d0 = 1.0 / (1.0 - p_hat)
  let m_alpha = inv_p + inv_d0
  let mut acc = 0.0
  for i = 0; i < n; i = i + 1 {
    let rr = d[i] / p_hat - (1.0 - d[i]) * inv_d0
    acc = acc + 2.0 * m_alpha - rr * rr
  }
  let expected = acc / n_d
  let tol = 1.0e-9 * expected.abs()
  assert_true((r.nu2 - expected).abs() <= tol)
  assert_true(r.nu2 == 4.1006481302183575)
  // The old convention returned exactly 1 here (mean of a constant psi_a^2).
  assert_true((r.nu2 - 1.0).abs() > 1.0)
}
