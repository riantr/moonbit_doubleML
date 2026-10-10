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

///|
/// v0.131.7 fixture for the IRM / APO `nu2` family. `ml_m` is a CLASSIFIER on
/// purpose: the port's default is `LearnerDispatch::linear_regression()`, which
/// returns values outside [0,1] and makes `1/m_hat` explode (measured:
/// coef=-225 on a DGP whose true ATE is 1.5, nu2 ~ 5e9). Upstream requires a
/// classifier with `predict_proba` for the same reason.
/// `irm/irm.py:419-423` / `irm/apo.py:378-382`, with `weights == weights_bar
/// == 1` and `normalize_ipw == False`.
fn v1317_data(n : Int, p : Int, seed : Int) -> DoubleMLData {
  let rng = chacha8_rng(seed)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let mut lin = 0.0
    for j = 0; j < p; j = j + 1 {
      let v = rng.double() * 2.0 - 1.0
      x_flat[i * p + j] = v
      lin = lin + (0.6 - 0.2 * j.to_double()) * v
    }
    let u = rng.double()
    let raw = 0.45 + lin
    let pi = if raw < 0.02 { 0.02 } else if raw > 0.98 { 0.98 } else { raw }
    let di = if u < pi { 1.0 } else { 0.0 }
    d[i] = di
    y[i] = lin + 0.25 * (rng.double() - 0.5) + di * 1.5
  }
  DoubleMLData::new(Matrix::from_array(x_flat, n, p), y, d)
}

///|
fn v1317_irm(data : DoubleMLData) -> DoubleMLIRM {
  DoubleMLIRM::new(
    data,
    n_folds=2,
    n_rep=1,
    seed=3141,
    ml_m=LearnerDispatch::logistic_regression(LogisticRegression::new()),
  ).fit()
}

///|
fn v1317_apo(data : DoubleMLData) -> DoubleMLAPO {
  DoubleMLAPO::new(
    data,
    treatment_level=1.0,
    n_folds=2,
    n_rep=1,
    seed=3141,
    ml_m=LearnerDispatch::logistic_regression(LogisticRegression::new()),
  ).fit()
}

///|
/// GATE -- IRM `nu2` is upstream's primary formula, not `mean(psi_a^2) == 1`.
///
/// `irm/irm.py:419-423` with `weights = weights_bar = 1` and
/// `m_hat_adj = m_hat` (upstream's `normalize_ipw` default is False,
/// `irm.py:138`):
/// ```text
///   m_alpha = 1/m + 1/(1-m)
///   rr      = d/m - (1-d)/(1-m)
///   nu2     = mean(2*m_alpha - rr^2)
/// ```
/// The old path returned EXACTLY 1 on this fixture, because `psi_a` is the
/// constant -1 (`irm.py:392`) and `mean((-1)^2) == 1`. That made
/// `max_bias = sqrt(sigma2 * 1)` and `rv` ~23x too optimistic.
/// `coef` and `sigma2` are untouched by this migration and are pinned too.
test "v1317_irm_nu2_is_upstreams_primary_formula_not_a_constant_one" {
  let est = v1317_irm(v1317_data(800, 3, 31))
  let r = est.sensitivity_analysis()
  let d = est.data.d
  let m = est.predictions_m()
  let n = d.length()
  let n_d = n.to_double()
  let mut acc = 0.0
  for i = 0; i < n; i = i + 1 {
    let mi = m[i]
    let inv_m = 1.0 / mi
    let inv_d0 = 1.0 / (1.0 - mi)
    let m_alpha = inv_m + inv_d0
    let rr = d[i] * inv_m - (1.0 - d[i]) * inv_d0
    acc = acc + 2.0 * m_alpha - rr * rr
  }
  let primary = acc / n_d
  // MEASURED: the primary comes out NEGATIVE on this fixture
  // (-488.8297898618956), because for a d == 0 row with m near 1 the
  // `rr^2 = 1/(1-m)^2` term dominates `2*m_alpha = 2/m + 2/(1-m)`.
  // Upstream therefore takes its documented fallback branch
  // (`double_ml.py:1634-1641`) and reports `mean(rr^2)`. That is NOT a
  // degenerate path here -- it is the NORMAL one, and is precisely why
  // upstream has the branch at all.
  assert_true(primary < 0.0)
  let (_, rr) = est.sensitivity_nu2_elements()
  let mut acc_rr = 0.0
  for i = 0; i < n; i = i + 1 {
    acc_rr = acc_rr + rr[i] * rr[i]
  }
  let fallback = acc_rr / n_d
  assert_true((r.nu2 - fallback).abs() <= 1.0e-9 * fallback.abs())
  assert_true(r.nu2 == 540.5547419191752)
  // The degenerate fallback this replaces: mean((-1)^2) == 1 exactly.
  assert_true((r.nu2 - 1.0).abs() > 1.0)
  // Untouched by the migration.
  assert_true(est.coef == 1.4426392091401607)
  assert_true(r.sigma2 == 0.005430941714793165)
}

///|
/// GATE -- APO `nu2` uses ITS OWN formula, which is NOT the IRM one.
///
/// `irm/apo.py:378-379`: APO's `m_alpha` is `1/m` only -- there is no
/// `+ 1/(1-m)` term -- and `rr` uses `treated`, not the treatment contrast.
/// Asserting the two estimators' `nu2` differ on the same data is what stops
/// one family being "migrated" with the other's formula.
/// ```text
///   m_alpha = 1/m ;  rr = treated/m ;  nu2 = mean(2*m_alpha - rr^2)
/// ```
test "v1317_apo_nu2_uses_its_own_formula_not_the_irm_one" {
  let data = v1317_data(800, 3, 31)
  let apo = v1317_apo(data)
  let r = apo.sensitivity_analysis()
  let m = apo.predictions_m()
  let d = apo.data.d
  let n = m.length()
  let n_d = n.to_double()
  let mut acc = 0.0
  for i = 0; i < n; i = i + 1 {
    let treated = if d[i] == apo.treatment_level { 1.0 } else { 0.0 }
    let inv_m = 1.0 / m[i]
    let m_alpha = inv_m
    let rr = treated * inv_m
    acc = acc + 2.0 * m_alpha - rr * rr
  }
  let primary = acc / n_d
  let (_, rr) = apo.sensitivity_nu2_elements()
  let mut acc_rr = 0.0
  for i = 0; i < n; i = i + 1 {
    acc_rr = acc_rr + rr[i] * rr[i]
  }
  let fallback = acc_rr / n_d
  // The helper takes the primary branch when `mean(2*m_alpha - rr^2)` is
  // positive and upstream's documented fallback (`double_ml.py:1634-1641`,
  // `mean(rr^2)`) otherwise. Pin whichever branch this fixture exercises so
  // the gate states the real contract rather than assuming the primary.
  let reported = if primary > 0.0 { primary } else { fallback }
  assert_true((r.nu2 - reported).abs() <= 1.0e-9 * reported.abs())
  assert_true(r.nu2 == 290.2904525219809)
  assert_true((r.nu2 - 1.0).abs() > 1.0)
  assert_true(apo.coef == 1.4915213017646698)
  assert_true(r.sigma2 == 1.2762786303947393)
  // Same data, different family => different nu2.
  let irm_nu2 = v1317_irm(data).sensitivity_analysis().nu2
  assert_true(irm_nu2 != r.nu2)
}

///|
/// GATE -- `rv` moved off its inflated value in the OPTIMISTIC direction.
///
/// `rv = |coef| / max_bias` and `max_bias = sqrt(sigma2 * nu2)`, so a `nu2`
/// collapsed to 1 shrinks `max_bias` and inflates `rv`. Measured on this
/// fixture: IRM 19.575828907299147 -> 0.8419771777915093, APO
/// 1.320251627397268 -> 0.0774890497743649. Pinning the corrected values makes
/// a silent re-inflation of the robustness diagnostic a test failure rather
/// than a silent change in what users are told about estimator fragility.
test "v1317_irm_and_apo_rv_are_no_longer_inflated_by_the_degenerate_nu2" {
  let data = v1317_data(800, 3, 31)
  let irm = v1317_irm(data).sensitivity_analysis()
  let apo = v1317_apo(data).sensitivity_analysis()
  assert_true(irm.rv == 0.8419771777915093)
  assert_true(apo.rv == 0.0774890497743649)
  // Both were far above 1 before, i.e. the estimator claimed to be robust.
  assert_true(irm.rv < 1.0)
  assert_true(apo.rv < 1.0)
}
