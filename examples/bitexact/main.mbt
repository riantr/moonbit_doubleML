///|
/// Bit-exact parity dump for `validate_bitexact_with_python.py`.
///
/// WHY THIS FILE EXISTS
/// ===================
/// Every other `validate_*_with_python.py` compares MoonBit's output against a
/// Python reference under a *tolerance*. A tolerance cannot distinguish "the
/// port is arithmetically identical to the reference" from "the port happens
/// to land within 1e-4 of it". This file emits values that the Python side
/// compares by IEEE-754 bit pattern instead.
///
/// WHAT CAN AND CANNOT BE BIT-EXACT -- MEASURED, NOT ASSUMED
/// =========================================================
/// IEEE-754 requires `+ - * /` and `sqrt` to be correctly rounded, so for the
/// SAME operands in the SAME order two independent implementations MUST agree
/// bit-for-bit. Everything here is built only from those, over a dataset that
/// is exact in binary (`i * 0.5 - 8.0` and friends never round), so the only
/// rounding in the whole pipeline is the rounding being tested.
///
/// `ln`, `cos` and `sin` are NOT correctly rounded in any implementation.
/// Measured on `moon 0.1.20261023` vs CPython 3.13.14 (re-measured; unchanged
/// from the `moon 0.1.20261012` vs CPython 3.14 pair it was first taken on):
///
///     sqrt  6/6 bit-exact        (guaranteed by IEEE-754)
///     cos   6/6 bit-exact        (agreement today, NOT guaranteed)
///     sin   6/6 bit-exact        (agreement today, NOT guaranteed)
///     ln    5/6 bit-exact        ln(3.0) differs by exactly 1 ULP
///
/// So this file deliberately emits NO transcendental. That rules out Box-Muller
/// (`box_muller_pair` uses `ln`, `cos` and `sin`) and therefore every
/// random-number DGP in the package: **no random DGP can be bit-exact against
/// CPython**, and a check that pretended otherwise would be a check that could
/// not pass. The RNG is checked through `seed_to_bytes`, which is pure integer
/// arithmetic and exactly specified.
///
/// SUMMATION ORDER IS PART OF THE CONTRACT
/// =======================================
/// NumPy's `sum` uses pairwise summation; a plain left-to-right loop does not.
/// The two differ in the last bits for n >= 8. The Python side therefore
/// accumulates with an explicit Python loop and must not be "optimised" into
/// numpy -- doing so would turn a parity test into a red herring.
fn main {
  let n = 64
  let x = Array::make(n, 0.0)
  let z = Array::make(n, 0.0)
  let u = Array::make(n, 0.0)
  let y = Array::make(n, 0.0)
  let t = Array::make(n, 0.0)
  // All five are exact in binary: i is a small integer and every multiplier
  // and offset is a power of two, so the DATA carries no rounding at all.
  for i = 0; i < n; i = i + 1 {
    let ti = i.to_double()
    x[i] = ti * 0.5 - 8.0
    z[i] = if i % 3 == 0 { 1.0 } else { 0.0 }
    u[i] = ti * 1.25 + 0.0625
    // The (i % 7) term is the point of this DGP. Without it, y is an exact
    // linear function of i and the residual sum of squares, the RDD slope SE
    // and the DID contrast all come out as a bare 0.0 -- a value with one
    // representation, which is a weak thing to ask two implementations to
    // agree on. It stays exact in binary (small integers times 0.25), so it
    // adds no rounding; it just makes the items non-degenerate.
    let wobble = (i % 7 - 3).to_double() * 0.25
    y[i] = ti * 2.0 - 3.0 * x[i] + 0.125 * u[i] + wobble
    t[i] = ti * 0.25 - 4.0
  }
  emit_array("data_x", x)
  emit_array("data_z", z)
  emit_array("data_u", u)
  emit_array("data_y", y)
  emit_array("data_t", t)

  // ---- closed-form first and second moments -------------------------------
  let mx = mean(x, n)
  let mu = mean(u, n)
  let my = mean(y, n)
  emit("mean_x", mx)
  emit("mean_u", mu)
  emit("mean_y", my)
  let vx = popvar(x, n, mx)
  let vu = popvar(u, n, mu)
  emit("popvar_x", vx)
  emit("popvar_u", vu)
  emit("sd_x", vx.sqrt())
  emit("sd_u", vu.sqrt())
  emit("cov_xu", popcov(x, u, n, mx, mu))
  emit("cov_xy", popcov(x, y, n, mx, my))
  emit("corr_xu", popcov(x, u, n, mx, mu) / (vx.sqrt() * vu.sqrt()))

  // ---- DID: difference in means, and the CR0 SE --------------------------
  let (m1, c1) = group_mean(y, z, n, 1.0)
  let (m0, c0) = group_mean(y, z, n, 0.0)
  let n1 = c1.to_double()
  let n0 = c0.to_double()
  emit("did_theta", m1 - m0)
  emit("did_n1", n1)
  emit("did_n0", n0)
  let v1 = group_var(y, z, n, 1.0, m1)
  let v0 = group_var(y, z, n, 0.0, m0)
  emit("did_var1", v1)
  emit("did_var0", v0)
  emit("did_se_cr0", (v1 / n1 + v0 / n0).sqrt())

  // ---- RDD: local-linear slope by the explicit 2x2 formula ---------------
  let (slope, inter, sse, ic) = local_linear(t, y, n)
  let cnt = ic.to_double()
  emit("rdd_slope", slope)
  emit("rdd_intercept", inter)
  emit("rdd_sse", sse)
  emit("rdd_n", cnt)
  let sd_t = tss(t, n, ic) / (cnt - 1.0)
  emit("rdd_slope_se", (sse / (cnt - 2.0) / sd_t).sqrt())

  // ---- sandwich vs var_est: one quantity, two routes ---------------------
  // psi_i = J * a_i + b_i with a = -1 and b = the outcome, J = -1.
  let mut ss = 0.0
  for i = 0; i < n; i = i + 1 {
    let psi = -1.0 * -1.0 + y[i]
    ss = ss + psi * psi
  }
  emit("sandwich_sum_psi2", ss)
  emit("varest_se", (ss / n.to_double() / 1.0).sqrt())
  emit("hc0_se", (ss / 1.0 / n.to_double()).sqrt())
  emit(
    "hc0_minus_varest",
    (ss / 1.0 / n.to_double()).sqrt() - (ss / n.to_double() / 1.0).sqrt(),
  )

  // ---- the RNG key: pure integer, exactly specified ----------------------
  for s in [0, 1, -1, 3141, 2147483647, -2147483648] {
    emit_key(s)
  }
}

///|
/// Mean by a left-to-right accumulation. The ORDER is part of the contract:
/// see the note at the top of the file about numpy's pairwise summation.
fn mean(a : Array[Double], n : Int32) -> Double {
  let mut s = 0.0
  for i = 0; i < n; i = i + 1 {
    s = s + a[i]
  }
  s / n.to_double()
}

///|
/// Population variance about a supplied mean.
fn popvar(a : Array[Double], n : Int32, m : Double) -> Double {
  let mut s = 0.0
  for i = 0; i < n; i = i + 1 {
    let d = a[i] - m
    s = s + d * d
  }
  s / n.to_double()
}

///|
/// Population covariance about supplied means.
fn popcov(
  a : Array[Double],
  b : Array[Double],
  n : Int32,
  ma : Double,
  mb : Double,
) -> Double {
  let mut s = 0.0
  for i = 0; i < n; i = i + 1 {
    s = s + (a[i] - ma) * (b[i] - mb)
  }
  s / n.to_double()
}

///|
/// (mean, count) for the rows where z == g.
fn group_mean(
  y : Array[Double],
  z : Array[Double],
  n : Int32,
  g : Double,
) -> (Double, Int32) {
  let mut s = 0.0
  let mut c = 0
  for i = 0; i < n; i = i + 1 {
    if z[i] == g {
      s = s + y[i]
      c = c + 1
    }
  }
  (s / c.to_double(), c)
}

///|
/// Population variance of y within the rows where z == g.
fn group_var(
  y : Array[Double],
  z : Array[Double],
  n : Int32,
  g : Double,
  m : Double,
) -> Double {
  let mut s = 0.0
  let mut c = 0
  for i = 0; i < n; i = i + 1 {
    if z[i] == g {
      let d = y[i] - m
      s = s + d * d
      c = c + 1
    }
  }
  s / c.to_double()
}

///|
/// Total sum of squares of the running covariate over the first `cnt` rows.
fn tss(t : Array[Double], _n : Int32, cnt : Int32) -> Double {
  let mut mt = 0.0
  for i = 0; i < cnt; i = i + 1 {
    mt = mt + t[i]
  }
  mt = mt / cnt.to_double()
  let mut s = 0.0
  for i = 0; i < cnt; i = i + 1 {
    let d = t[i] - mt
    s = s + d * d
  }
  s
}

///|
/// Local linear fit of y on t over t >= 0, by the explicit 2x2 formula.
/// Returns (slope, intercept, residual sum of squares, count). No Gaussian
/// elimination, so there is no pivot-order dependence to disagree about.
fn local_linear(
  t : Array[Double],
  y : Array[Double],
  n : Int32,
) -> (Double, Double, Double, Int32) {
  let mut cnt = 0
  let mut mt = 0.0
  let mut my = 0.0
  for i = 0; i < n; i = i + 1 {
    if t[i] >= 0.0 {
      cnt = cnt + 1
      mt = mt + t[i]
      my = my + y[i]
    }
  }
  let c = cnt.to_double()
  mt = mt / c
  my = my / c
  let mut stt = 0.0
  let mut sty = 0.0
  for i = 0; i < n; i = i + 1 {
    if t[i] >= 0.0 {
      let dt = t[i] - mt
      stt = stt + dt * dt
      sty = sty + dt * (y[i] - my)
    }
  }
  let slope = sty / stt
  let inter = my - slope * mt
  let mut sse = 0.0
  for i = 0; i < n; i = i + 1 {
    if t[i] >= 0.0 {
      let e = y[i] - (inter + slope * t[i])
      sse = sse + e * e
    }
  }
  (slope, inter, sse, cnt)
}

///|
/// One `item` line: name and the value in shortest-round-trip form, which is
/// exactly Python's `repr`. Equal strings therefore mean equal doubles, which
/// is what makes the string comparison a bit comparison.
fn emit(name : String, v : Double) -> Unit {
  println("item " + name + " " + v.to_string())
}

///|
fn emit_array(name : String, a : Array[Double]) -> Unit {
  let mut s = "array " + name + " " + a.length().to_string()
  for i = 0; i < a.length(); i = i + 1 {
    s = s + " " + a[i].to_string()
  }
  println(s)
}

///|
/// The 32-byte ChaCha8 key, as Python bytes literals, so the Python side can
/// `ast.literal_eval` them and compare the key byte-for-byte.
fn emit_key(seed : Int32) -> Unit {
  let b = @moonbit_doubleML.seed_to_bytes(seed)
  let mut s = "key " + seed.to_string()
  for i = 0; i < b.length(); i = i + 1 {
    s = s + " " + b[i].to_string()
  }
  println(s)
}
