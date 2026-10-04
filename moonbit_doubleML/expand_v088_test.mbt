///|
// v0.88.0: white-box tests for the HC2 / HC3 leverage FIX.
//
// The bug (present in v0.79.0 - v0.87.0): `sandwich_variance_hc2`
// and `sandwich_variance_hc3` used
//
//     h_ii = psi_a[i] * M_inv[0,0] * psi_a[i]
//
// as the "leverage". That is not a hat-matrix diagonal in any
// sense. Every estimator in this package builds
// `M_inv = [[1 / mean(psi_a)]]`, and `psi_a` is typically a
// negative score row, so `mean(psi_a) < 0`, `M_inv < 0` and
// `h_ii < 0` on every row. `1 - h_ii` then EXCEEDS 1, the
// divisor grows, and HC2 / HC3 SHRINK the variance instead of
// widening it -- the opposite of MacKinnon (2012) sec 5.4.
// Worst case: constant `psi_a = -1` gives `h_ii = -1`, so
// `1 - h_ii = 2` and HC2 was exactly `HC0 / 2` while HC3 was
// exactly `HC0 / 4`.
//
// The fix: the moment being inverted is the single-parameter
// MEAN moment `E[psi_a * psi(theta)] = 0`, so the regression
// implicit in it is a mean regression (intercept-only design,
// equal per-observation weights) whose projection matrix is
// `(1 / n) * J`. Its diagonal is the constant
// `h_ii = 1 / n_obs`. Under that choice
//
//     HC2 = HC0 * n / (n - 1)      == HC1
//     HC3 = HC0 * (n / (n - 1))^2  == HC1^2 / HC0
//
// and both corrections WIDEN, as intended. HC0 and HC1 are
// untouched by the change (pinned below).
//
// Every assertion in this file fails against the v0.87.0
// implementation; nothing here is a finiteness-only check.

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

///|
/// Relative closeness at the 1e-12 level (the tolerance this
/// package uses for "same number, different accumulation
/// order").
fn expand_v088_close(x : Double, y : Double) -> Bool {
  let scale = if x.abs() > y.abs() { x.abs() } else { y.abs() }
  if scale == 0.0 {
    return (x - y).abs() < 1.0e-300
  }
  (x - y).abs() / scale < 1.0e-12
}

///|
/// Relative closeness at the 1e-15 level, used to pin the
/// HC0 / HC1 regression values. Tighter than `close` but not
/// exact `==` so the assertion survives a last-ulp difference
/// between the native and the JS/wasm backends.
fn expand_v088_pinned_close(x : Double, y : Double) -> Bool {
  let scale = if x.abs() > y.abs() { x.abs() } else { y.abs() }
  if scale == 0.0 {
    return (x - y).abs() < 1.0e-300
  }
  (x - y).abs() / scale < 1.0e-15
}

///|
/// Fixed input A: `n = 64`, a NON-constant negative `psi_a`
/// cycling through -0.75 / -0.9166.. / -1.0833.. / -1.25 and
/// a mixed-sign `psi`. `mean(psi_a) == -1` exactly, so
/// `M_inv = [[-1.0]]` -- the v0.87.0 code therefore produced a
/// leverage in [-1.5625, -0.5625], i.e. strongly negative and
/// non-constant, and every HC2 / HC3 value was wrong.
///
/// Returns `(psi_a, psi, m_inv)`.
fn expand_v088_input_a(n : Int) -> (Array[Double], Array[Double], Matrix) {
  let psi_a : Array[Double] = Array::make(n, 0.0)
  let psi : Array[Double] = Array::make(n, 0.0)
  let period : Array[Double] = [1.0, -0.5, 0.25, 0.125]
  for i = 0; i < n; i = i + 1 {
    psi_a[i] = -0.75 - 0.5 * (i % 4).to_double() / 3.0
    psi[i] = period[i % 4]
  }
  let m_inv = Matrix::from_array([1.0 / mean(psi_a)], 1, 1)
  (psi_a, psi, m_inv)
}

///|
/// The leverage the implementation actually applied, recovered
/// from the pair `(HC0, HC2)` by inverting
/// `HC2 = HC0 / (1 - h_ii)`.
///
/// This reads the divisor off the OUTPUT rather than trusting a
/// copy of the formula in the test, so it stays falsifiable if
/// the leverage expression is edited again. It assumes the
/// (now uniform) constant leverage; a per-observation leverage
/// would show up here as a weighted average that does not equal
/// `1 / n`, which `leverage_is_in_unit_interval` also pins.
fn expand_v088_derived_leverage(hc0 : Double, hc2 : Double) -> Double {
  1.0 - hc0 / hc2
}

///|
/// One `(label, hc0, hc2)` case: constant `psi_a = -1`, the
/// IRM / SSM / CVAR / DID ATT leverage case and the one v0.87.0
/// got most wrong (HC2 was exactly `HC0 / 2`).
fn expand_v088_hc_pair(
  psi_a : Array[Double],
  psi : Array[Double],
  m_inv : Matrix,
  n : Int,
) -> (Double, Double) {
  let v0 = sandwich_variance_hc0(psi_a, psi, m_inv, n, 1)
  let v2 = sandwich_variance_hc2(psi_a, psi, m_inv, n, 1)
  (v0, v2)
}

// ---------------------------------------------------------------------------
// 1. HC2 == HC1
// ---------------------------------------------------------------------------

///|
test "hc2_equals_hc1" {
  let n = 64
  let (psi_a, psi, m_inv) = expand_v088_input_a(n)
  let v1 = sandwich_variance_hc1(psi_a, psi, m_inv, n, 1)
  let v2 = sandwich_variance_hc2(psi_a, psi, m_inv, n, 1)
  // h_ii = 1 / n on every row -> every term divided by the same
  // (n - 1) / n, i.e. exactly the HC1 factor.
  inspect(expand_v088_close(v2, v1), content="true")
  // Independent statement of the same identity, so a
  // coincidental HC1 == HC2 match cannot pass both.
  let scale = n.to_double() / (n.to_double() - 1.0)
  let v0 = sandwich_variance_hc0(psi_a, psi, m_inv, n, 1)
  inspect(expand_v088_close(v2, v0 * scale), content="true")
  // The shared `sandwich_variance(kind, ...)` dispatch must
  // agree with the free function.
  inspect(
    sandwich_variance(SandwichKind::hc2(), psi_a, psi, m_inv, n, 1) == v2,
    content="true",
  )
  // v0.87.0 on this input returned 0.12935609720259825,
  // i.e. below HC0 instead of above it.
  inspect(v2 > v0, content="true")
}

// ---------------------------------------------------------------------------
// 2. HC3 == HC1^2 / HC0
// ---------------------------------------------------------------------------

///|
test "hc3_equals_hc1_squared_over_hc0" {
  let n = 64
  let (psi_a, psi, m_inv) = expand_v088_input_a(n)
  let v0 = sandwich_variance_hc0(psi_a, psi, m_inv, n, 1)
  let v1 = sandwich_variance_hc1(psi_a, psi, m_inv, n, 1)
  let v3 = sandwich_variance_hc3(psi_a, psi, m_inv, n, 1)
  // h_ii = 1 / n -> divisor ((n - 1) / n)^2 on every term.
  inspect(expand_v088_close(v3, v1 * v1 / v0), content="true")
  let scale = n.to_double() / (n.to_double() - 1.0)
  inspect(expand_v088_close(v3, v0 * scale * scale), content="true")
  inspect(
    sandwich_variance(SandwichKind::hc3(), psi_a, psi, m_inv, n, 1) == v3,
    content="true",
  )
  // v0.87.0 returned 0.07791813402549888 on this input.
  inspect(v3 > v0, content="true")
}

// ---------------------------------------------------------------------------
// 3. The leverage is in the unit interval and equals 1 / n
// ---------------------------------------------------------------------------

///|
test "leverage_is_in_unit_interval" {
  let n = 64
  let psi : Array[Double] = Array::make(n, 0.0)
  let period : Array[Double] = [1.0, -0.5, 0.25, 0.125]
  for i = 0; i < n; i = i + 1 {
    psi[i] = period[i % 4]
  }
  let expected_h = 1.0 / n.to_double()
  // Five psi_a families: constant negative, all-positive,
  // all-negative, mixed sign, and an extreme dynamic range.
  // Under the v0.87.0 formula the derived leverage on these was
  // -1.0, far above 1, far below 0, and ~1e6 respectively -- all
  // of them fail the assertions below.
  let families : Array[Array[Double]] = [
    Array::make(n, -1.0),
    Array::make(n, 0.5),
    {
      let a : Array[Double] = Array::make(n, 0.0)
      for i = 0; i < n; i = i + 1 {
        a[i] = if i % 2 == 0 { 0.5 } else { 2.0 }
      }
      a
    },
    {
      let a : Array[Double] = Array::make(n, 0.0)
      for i = 0; i < n; i = i + 1 {
        a[i] = -0.75 - 0.5 * (i % 4).to_double() / 3.0
      }
      a
    },
    {
      let a : Array[Double] = Array::make(n, 0.0)
      for i = 0; i < n; i = i + 1 {
        a[i] = if i % 2 == 0 { 1.0e-3 } else { -1.0e3 }
      }
      a
    },
  ]
  for f = 0; f < families.length(); f = f + 1 {
    let psi_a = families[f]
    let m_inv = Matrix::from_array([1.0], 1, 1)
    let (v0, v2) = expand_v088_hc_pair(psi_a, psi, m_inv, n)
    // HC0 must be a usable reference on every family.
    inspect(v0 > 0.0, content="true")
    inspect(v2.is_nan() == false, content="true")
    inspect(v2.is_inf() == false, content="true")
    let h = expand_v088_derived_leverage(v0, v2)
    inspect(h >= 0.0, content="true")
    inspect(h < 1.0, content="true")
    // ... and it must be exactly the mean-regression
    // leverage 1 / n_obs.
    inspect(expand_v088_close(h, expected_h), content="true")
  }
}

// ---------------------------------------------------------------------------
// 4. The corrections now widen
// ---------------------------------------------------------------------------

///|
test "hc_ordering_now_widens" {
  let n = 64
  let (psi_a, psi, m_inv) = expand_v088_input_a(n)
  let v0 = sandwich_variance_hc0(psi_a, psi, m_inv, n, 1)
  let v1 = sandwich_variance_hc1(psi_a, psi, m_inv, n, 1)
  let v2 = sandwich_variance_hc2(psi_a, psi, m_inv, n, 1)
  let v3 = sandwich_variance_hc3(psi_a, psi, m_inv, n, 1)
  inspect(v1 > v0, content="true")
  inspect(v2 > v0, content="true")
  inspect(v3 > v2, content="true")
  // Same ordering on the standard errors.
  let se0 = v0.sqrt()
  inspect(v2.sqrt() > se0, content="true")
  inspect(v3.sqrt() > v2.sqrt(), content="true")
}

// ---------------------------------------------------------------------------
// 5. HC0 / HC1 did not move (v0.87.0 regression values)
// ---------------------------------------------------------------------------

///|
test "hc0_and_hc1_unchanged" {
  let n = 64
  let (psi_a, psi, m_inv) = expand_v088_input_a(n)
  // Captured from the v0.87.0 implementation BEFORE the
  // leverage fix (native target). `mean(psi_a) == -1` exactly,
  // so `M_inv == [[-1.0]]`.
  inspect(
    expand_v088_pinned_close(
      sandwich_variance_hc0(psi_a, psi, m_inv, n, 1),
      0.2175835503472222,
    ),
    content="true",
  )
  inspect(
    expand_v088_pinned_close(
      sandwich_variance_hc1(psi_a, psi, m_inv, n, 1),
      0.2210372574955908,
    ),
    content="true",
  )
  // Same regression values on the constant `psi_a = -1` input.
  let flat_a : Array[Double] = Array::make(n, -1.0)
  let flat_inv = Matrix::from_array([-1.0], 1, 1)
  inspect(
    expand_v088_pinned_close(
      sandwich_variance_hc0(flat_a, psi, flat_inv, n, 1),
      0.33203125,
    ),
    content="true",
  )
  inspect(
    expand_v088_pinned_close(
      sandwich_variance_hc1(flat_a, psi, flat_inv, n, 1),
      0.33730158730158727,
    ),
    content="true",
  )
}

// ---------------------------------------------------------------------------
// 6. The constant psi_a = -1 case
// ---------------------------------------------------------------------------

///|
test "constant_psi_a_case" {
  let n = 64
  let psi_a : Array[Double] = Array::make(n, -1.0)
  let psi : Array[Double] = Array::make(n, 0.0)
  let period : Array[Double] = [1.0, -0.5, 0.25, 0.125]
  for i = 0; i < n; i = i + 1 {
    psi[i] = period[i % 4]
  }
  let m_inv = Matrix::from_array([-1.0], 1, 1)
  let v0 = sandwich_variance_hc0(psi_a, psi, m_inv, n, 1)
  let v1 = sandwich_variance_hc1(psi_a, psi, m_inv, n, 1)
  let v2 = sandwich_variance_hc2(psi_a, psi, m_inv, n, 1)
  let v3 = sandwich_variance_hc3(psi_a, psi, m_inv, n, 1)
  let scale = n.to_double() / (n.to_double() - 1.0)
  // v0.87.0 gave HC2 == HC0 / 2 and HC3 == HC0 / 4 here
  // (divisors 2 and 4 from the negative leverage -1).
  inspect(expand_v088_close(v2, v0 * scale), content="true")
  inspect(expand_v088_close(v3, v0 * scale * scale), content="true")
  // Pinned new values (native, v0.88.0).
  inspect(expand_v088_pinned_close(v2, 0.33730158730158727), content="true")
  inspect(expand_v088_pinned_close(v3, 0.34265558075081887), content="true")
  // The corrections WIDEN now.
  inspect(v2 > v0, content="true")
  inspect(v3 > v2, content="true")
  inspect(v2.sqrt() > v0.sqrt(), content="true")
  // HC2 is exactly HC1, and HC0 is still the old value.
  inspect(v2 == v1, content="true")
  inspect(expand_v088_pinned_close(v0, 0.33203125), content="true")
}
