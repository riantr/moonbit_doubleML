///|
/// MoonBit-side output for the ten `validate_*_with_python.py` scripts that
/// previously could not run MoonBit at all.
///
/// WHY THIS FILE EXISTS
/// ===================
/// Ten of the twenty-four Python cross-checks import no `subprocess`, spawn no
/// MoonBit process, and print a trailing `PASS` that CI greps for. They compute
/// a Python-only reference, so no change to the MoonBit code can turn them red.
/// They are not wrong about the maths; they simply cannot observe the port.
///
/// This emitter gives all ten something to observe. Its output format is
/// deliberately trivial to parse:
///
///     section <name>
///     val <label> <double>
///     data <name> <double> <double> ...
///
/// WHY THE DATA IS EMITTED
/// =======================
/// Some of these DGPs are drawn from `chacha8`, which CPython cannot reproduce
/// (it is a different cipher from `default_rng`, and `box_muller_pair` uses
/// `ln`/`cos`/`sin`, which are not correctly rounded -- see
/// `validate_bitexact_with_python.py` for that measurement). So where the DGP
/// is RNG-driven the data is emitted here and the Python side recomputes on the
/// IDENTICAL values. That turns "two different random datasets happen to land
/// near each other" into a real comparison.
///
/// Where the DGP is deterministic (`i % 2`, `i % 100`, `arange`) the Python side
/// regenerates it itself, which is the stronger test: two independent
/// constructions of the same data, not one copied from the other.
fn main {
  sec_quantile()
  sec_rdd()
  sec_cvar()
  sec_blp_policy()
  sec_did_binary()
  sec_did_cs()
  sec_bootstrap()
  sec_padjust()
  sec_cv_repeated()
  sec_gain_statistics()
}

// --------------------------------------------------------------------------- //
// 1. quantile -- PQ / LPQ / QTE on the deterministic alternating DGP
// --------------------------------------------------------------------------- //

///|
fn sec_quantile() -> Unit {
  let n = 400
  let x = @moonbit_doubleML.Matrix::zeros(n, 1)
  let d = Array::make(n, 0.0)
  let y = Array::make(n, 0.0)
  let z = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    d[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
    y[i] = d[i] + (i % 100).to_double() / 100.0
    z[i] = d[i]
  }
  let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)
  let pq = @moonbit_doubleML.DoubleMLPQ::new(
    data,
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=3141,
  ).fit()
  let lpq = @moonbit_doubleML.DoubleMLLPQ::new(
    @moonbit_doubleML.DoubleMLLPQData::new(x, y, d, z),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=3141,
  ).fit()
  section("quantile")
  val("pq_coef", pq.coef())
  val("pq_se", pq.se())
  val("pq_median_treated", median_of(d, y, n, 1.0))
  val("pq_median_control", median_of(d, y, n, 0.0))
  val("lpq_coef", lpq.coef())
  val("lpq_se", lpq.se())
  val("qte_coef", pq.coef() - median_of(d, y, n, 0.0))
  end()
}

// --------------------------------------------------------------------------- //
// 2. rdd -- sharp and fuzzy, deterministic running variable
// --------------------------------------------------------------------------- //

///|
/// The covariate `z` is NOT the running variable. An earlier revision of this
/// file passed `u` as both `score` and `x`, which made the local-linear design
/// `[1, u, u]` -- rank 2, not rank 3. The ridge (`1e-10`) then did the work
/// instead of the data, the condition number was ~3e12, and the "sharp"
/// coefficient came back as 2.0000000000080016 rather than 2. With `z` on a
/// period of 17 the design is full rank, the estimator is exact, and CPython
/// can reproduce it.
fn sec_rdd() -> Unit {
  let n = 600
  let u = Array::make(n, 0.0)
  let z = Array::make(n, 0.0)
  let ys = Array::make(n, 0.0)
  let ds = Array::make(n, 0.0)
  let yf = Array::make(n, 0.0)
  let df = Array::make(n, 0.0)
  let sc = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let uu = (i.to_double() + 0.5) / 300.0 - 1.0
    let zz = (i % 17).to_double() / 8.0 - 1.0
    u[i] = uu
    z[i] = zz
    sc[i] = uu
    ds[i] = if uu >= 0.0 { 1.0 } else { 0.0 }
    ys[i] = 2.0 + uu + 0.5 * zz + 2.0 * ds[i]
    df[i] = if uu >= 0.0 { 0.7 } else { 0.5 }
    yf[i] = uu + 0.5 * zz + 0.6 * df[i]
  }
  let ux = @moonbit_doubleML.Matrix::from_array(z, n, 1)
  let sharp = @moonbit_doubleML.DoubleMLRDD::new(
    @moonbit_doubleML.DoubleMLRDDData::new(ux, ys, ds, sc),
    bandwidth=0.5,
  ).fit()
  // `fuzzy=true` is load-bearing: without it `fit` takes the sharp branch and
  // returns the outcome JUMP (0.12), not the Wald RATIO (0.6).
  let fuzzy = @moonbit_doubleML.DoubleMLRDD::new(
    @moonbit_doubleML.DoubleMLRDDData::new(ux, yf, df, sc),
    bandwidth=0.5,
    fuzzy=true,
  ).fit()
  section("rdd")
  val("sharp_coef", sharp.coef())
  val("sharp_se", sharp.se())
  val("fuzzy_coef", fuzzy.coef())
  val("fuzzy_se", fuzzy.se())
  val("n_local", sharp.n_local().to_double())
  val("fuzzy_n_local", fuzzy.n_local().to_double())
  // The data is deterministic, so Python regenerates it; emitted anyway so a
  // Python-side bug shows up as a DATA mismatch rather than a mystery.
  data_out("u", u)
  data_out("z", z)
  data_out("y_sharp", ys)
  data_out("d_sharp", ds)
  data_out("y_fuzzy", yf)
  data_out("d_fuzzy", df)
  end()
}

// --------------------------------------------------------------------------- //
// 3. cvar -- Conditional Value at Risk on the same alternating DGP
// --------------------------------------------------------------------------- //

///|
fn sec_cvar() -> Unit {
  let n = 400
  let x = @moonbit_doubleML.Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    d[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
    y[i] = d[i] + (i % 100).to_double() / 100.0
  }
  let cvar = @moonbit_doubleML.DoubleMLCVAR::new(
    @moonbit_doubleML.DoubleMLData::new(x, y, d),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  section("cvar")
  val("cvar_coef", cvar.coef())
  val("cvar_se", cvar.se())
  // CVaR at q=0.5 of the treated upper half, computed here directly so the
  // Python side has a MoonBit-side population target, not just a fit.
  val("cvar_empirical_treated", cvar_upper_half_mean(d, y, n, 1.0))
  data_out("y", y)
  data_out("d", d)
  end()
}

// --------------------------------------------------------------------------- //
// 4. blp_policy -- BLP precision matrix + the policy tree value
// --------------------------------------------------------------------------- //

///|
/// `DoubleMLBLP::fit` is plain OLS of `s` on `[1, x]`. An earlier revision of
/// this file built `a` on period 32 and `b` on period 48 -- `lcm(32, 48) = 96`
/// does not divide n = 300, so the two columns were collinear over the sample
/// and the emitted 1.6057 / 0.9668 were nothing like the DGP's 1.5 / 1.0.
/// The port was right; the DGP was unfalsifiable. Both periods are now larger
/// than n and mutually prime-ish, so the OLS solution is well conditioned and
/// the population coefficients are actually recoverable.
fn sec_blp_policy() -> Unit {
  let n = 300
  let x_flat = Array::make(n * 2, 0.0)
  let s = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let a = (i * 7919 % 1000).to_double() / 500.0 - 1.0
    let b = (i * 6271 % 997).to_double() / 498.5 - 1.0
    x_flat[i * 2] = a
    x_flat[i * 2 + 1] = b
    s[i] = 1.5 * a + 1.0 * b + 0.25 * a * b
  }
  let x = @moonbit_doubleML.Matrix::from_array(x_flat, n, 2)
  let blp = @moonbit_doubleML.DoubleMLBLP::new(x, s).fit()
  let pt = @moonbit_doubleML.DoubleMLPolicyTree::new(x, s).fit()
  let bc = blp.coef()
  let bs = blp.se()
  section("blp_policy")
  // coef() is [intercept, x0, x1]; s has no intercept by construction, so
  // coef()[0] is the diagnostic for that, not a treatment coefficient.
  val("blp_intercept", bc[0])
  val("blp_coef_x0", bc[1])
  val("blp_coef_x1", bc[2])
  val("blp_se_x0", bs[1])
  val("pt_split_feature", pt.split_feature().to_double())
  val("pt_split_value", pt.split_value())
  data_out("x0", col(x_flat, n, 2, 0))
  data_out("x1", col(x_flat, n, 2, 1))
  data_out("s", s)
  end()
}

// --------------------------------------------------------------------------- //
// 5. did_binary -- two-period, never-treated control. RNG DGP: data is emitted.
// --------------------------------------------------------------------------- //

///|
fn sec_did_binary() -> Unit {
  let p = 3
  let theta0 = 1.0
  let n_per_cohort = 120
  let n_units = n_per_cohort
  let n = n_units * 2
  let x_flat = Array::make(n * p, 0.0)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let t_arr = Array::make(n, 0)
  let g_arr = Array::make(n, 0)
  let id_arr = Array::make(n, 0)
  let rng = @moonbit_doubleML.chacha8_rng(7)
  for u = 0; u < n_units; u = u + 1 {
    let xu = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      xu[j] = rng.double() * 2.0 - 1.0
    }
    let treated = if u % 2 == 0 { 1 } else { 0 }
    for k = 0; k < 2; k = k + 1 {
      let row = 2 * u + k
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = xu[j]
      }
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = treated
      d[row] = if treated == 1 && k == 1 { 1.0 } else { 0.0 }
      let mut yv = 0.0
      for j = 0; j < p; j = j + 1 {
        yv = yv + xu[j]
      }
      if treated == 1 && k == 1 {
        yv = yv + theta0
      }
      y[row] = yv + 0.05 * (rng.double() - 0.5)
    }
  }
  let fitted = @moonbit_doubleML.DoubleMLDIDBinary::new(
    @moonbit_doubleML.DoubleMLDIDBinaryData::new(
      @moonbit_doubleML.Matrix::from_array(x_flat, n, p),
      y,
      d,
      t_arr,
      g_arr,
      id_arr,
    ),
    1,
    0,
    1,
  ).fit()
  section("did_binary")
  val("att", fitted.coef())
  val("att_se", fitted.se())
  val("n_obs_subset", fitted.n_obs_subset().to_double())
  data_out("did_binary_y", y)
  data_out("did_binary_d", d)
  end()
}

// --------------------------------------------------------------------------- //
// 6. did_cs -- staggered adoption. RNG DGP: data is emitted.
// --------------------------------------------------------------------------- //

///|
/// `discover_groups_times` (`did_cs.mbt`:77-78) says the `groups` array is
/// "the sorted list of unique `g` values EXCLUDING the never-treated sentinel
/// (THE MINIMUM OF `g`)". So the control group is whichever cohort label is
/// smallest, and it is assumed to be genuinely untreated.
///
/// Two earlier revisions of this DGP got that wrong, in opposite directions,
/// and both produced a `coef_at(0, 1)` of opposite sign:
///   * `never = cohort >= n_periods - 1` put the control at cohort 3, so the
///     port used cohort 0 -- which that DGP TREATED from t = 1 -- as its
///     control group;
///   * shifting adoption to `k >= cohort + 1` did not help, because cohort 0
///     was still the (treated) minimum label.
///
/// The control is now cohort 0 and it is untreated throughout, and adoption
/// is at `k >= cohort` -- which is the convention the port encodes, with
/// `pre_period = g_value - 1` and post-treatment starting AT `g_value`.
fn sec_did_cs() -> Unit {
  let p = 3
  let n_per_cohort = 20
  let n_periods = 4
  let cohort_count = 4
  let n_units = n_per_cohort * cohort_count
  let n = n_units * n_periods
  let x_flat = Array::make(n * p, 0.0)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let t_arr = Array::make(n, 0)
  let g_arr = Array::make(n, 0)
  let id_arr = Array::make(n, 0)
  let rng = @moonbit_doubleML.chacha8_rng(11)
  for u = 0; u < n_units; u = u + 1 {
    let cohort = u / n_per_cohort
    let xu = Array::make(p, 0.0)
    for j = 0; j < p; j = j + 1 {
      xu[j] = rng.double() * 2.0 - 1.0
    }
    for k = 0; k < n_periods; k = k + 1 {
      let row = u * n_periods + k
      for j = 0; j < p; j = j + 1 {
        x_flat[row * p + j] = xu[j]
      }
      t_arr[row] = k
      id_arr[row] = u
      g_arr[row] = cohort
      let never = cohort == 0
      let treated = if never || k < cohort { 0 } else { 1 }
      d[row] = treated.to_double()
      let mut yv = 0.0
      for j = 0; j < p; j = j + 1 {
        yv = yv + 0.5 * xu[j]
      }
      yv = yv + 0.1 * cohort.to_double()
      if treated == 1 {
        yv = yv + 1.5
      }
      y[row] = yv + 0.05 * (rng.double() - 0.5)
    }
  }
  let fitted = @moonbit_doubleML.DoubleMLDIDCS::new(
    @moonbit_doubleML.DoubleMLDIDCSData::new(
      @moonbit_doubleML.Matrix::from_array(x_flat, n, p),
      y,
      d,
      t_arr,
      id_arr,
      g_arr,
    ),
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  section("did_cs")
  // The WHOLE (g, t) matrix, not just one cell. A single cell cannot tell a
  // sign error apart from an indexing shift -- on this DGP `coef_at(0, 1)`
  // reads -1.493 where the independent estimate is +1.496, and only the rest
  // of the matrix says whether the port is wrong or this file is asking for
  // the wrong cell.
  for gi = 0; gi < 3; gi = gi + 1 {
    for ti = 0; ti < 4; ti = ti + 1 {
      val(
        "att_g" + gi.to_string() + "_t" + ti.to_string(),
        fitted.coef_at(gi, ti),
      )
    }
  }
  val("att_g0_t1", fitted.coef_at(0, 1))
  val("att_se_g0_t1", fitted.se_at(0, 1))
  val("n_groups", fitted.n_groups().to_double())
  val("n_periods", fitted.n_periods().to_double())
  data_out("did_cs_y", y)
  data_out("did_cs_d", d)
  // The panel structure travels with the data, so CPython checks the structure
  // rather than re-deriving it from a rule it has no way to verify.
  let g_d = Array::make(n, 0.0)
  let t_d = Array::make(n, 0.0)
  let id_d = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    g_d[i] = g_arr[i].to_double()
    t_d[i] = t_arr[i].to_double()
    id_d[i] = id_arr[i].to_double()
  }
  data_out("did_cs_g", g_d)
  data_out("did_cs_t", t_d)
  data_out("did_cs_id", id_d)
  end()
}

// --------------------------------------------------------------------------- //
// 7. bootstrap -- the weight draw, which is pure chacha8 arithmetic
// --------------------------------------------------------------------------- //

///|
/// Mean and variance are NOT enough to tell these three apart. All three of
/// `normal`, `Bayes` and `wild` have E[w] = 0 and Var[w] = 1, so a validator
/// that only checked those two moments would pass even if
/// `draw_bootstrap_weights` returned N(0,1) for every method name. The third
/// and fourth central moments are what separate them:
///
///     normal   m3 = 0    m4 = 3
///     Bayes    m3 = 2    m4 = 9      (w = Exp(1) - 1)
///     wild     m3 = 1    m4 = 6      (w = x/sqrt(2) + (y^2 - 1)/2)
///
/// so `m3` separates Bayes from the other two and `m4` separates all three.
///
/// 500 x 200 = 100_000 draws, not 200 x 50. Bayes draws are `Exp(1) - 1`,
/// whose 4th central moment has standard error ~sqrt(8!/n) = 2.0 at n = 10_000
/// -- wider than the 3-unit gap between Bayes's m4 and wild's. At 100_000 the
/// error is 0.63, which is what makes the comparison discriminating rather
/// than merely suggestive. See `validate_bootstrap_with_python.py` for the
/// measured bands this produced.
fn sec_bootstrap() -> Unit {
  let n_rep = 500
  let n_obs = 200
  section("bootstrap")
  for m in ["normal", "Bayes", "wild"] {
    // `draw_bootstrap_weights` is declared `raise`, and a function that can
    // raise may only be called inside one that can raise. `try`/`catch` is the
    // way to contain it here: an unsupported method must print NaN and let the
    // Python side fail on the comparison, not abort the whole emitter.
    let got = Some(
      @moonbit_doubleML.draw_bootstrap_weights(m, n_rep, n_obs, 3141),
    ) catch {
      _ => None
    }
    match got {
      Some(w) => {
        val(m + "_mean", wsum(w) / w.length().to_double())
        val(m + "_var", wvar(w))
        val(m + "_m3", wmoment(w, 3))
        val(m + "_m4", wmoment(w, 4))
        val(m + "_first", w[0])
      }
      None => {
        val(m + "_mean", 0.0)
        val(m + "_var", 0.0)
        val(m + "_m3", 0.0)
        val(m + "_m4", 0.0)
        val(m + "_first", 0.0)
        println("err " + m + " unsupported")
      }
    }
  }
  val("n_rep", n_rep.to_double())
  val("n_obs", n_obs.to_double())
  val("n_draws", (n_rep * n_obs).to_double())
  end()
}

// --------------------------------------------------------------------------- //
// 8. padjust -- Romano-Wolf / Holm / BH on a FIXED p-value vector
// --------------------------------------------------------------------------- //

///|
fn sec_padjust() -> Unit {
  let p = [0.001, 0.008, 0.02, 0.04, 0.2, 0.5, 0.9]
  section("padjust")
  for m in ["holm", "bonferroni", "bh", "by", "tsbh"] {
    let adj = @moonbit_doubleML.p_adjust(m, p)
    for i = 0; i < p.length(); i = i + 1 {
      val(m + "_" + i.to_string(), adj[i])
    }
  }
  data_out("unadjusted_p", p)
  end()
}

// --------------------------------------------------------------------------- //
// 9. cv_repeated -- repeated cross-validation changes the SE, not the point
// --------------------------------------------------------------------------- //

///|
/// `x` is two real deterministic columns, not zeros. An all-zero covariate
/// matrix is rank-deficient, and then the estimate is whatever the ridge
/// decides rather than what the data says -- which would make the CPython
/// side's independent OLS reference untestable. The noise is a closed form
/// too, so CPython rebuilds the whole dataset rather than trusting the copy.
fn sec_cv_repeated() -> Unit {
  let n = 300
  let x_flat = Array::make(n * 2, 0.0)
  let d = Array::make(n, 0.0)
  let y = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let c0 = (i * 7919 % 1000).to_double() / 500.0 - 1.0
    let c1 = (i * 6271 % 997).to_double() / 498.5 - 1.0
    let noise = (i * 37 % 101).to_double() / 101.0 - 0.5
    x_flat[i * 2] = c0
    x_flat[i * 2 + 1] = c1
    d[i] = if i % 3 == 0 { 1.0 } else { 0.0 }
    y[i] = d[i] * 2.0 + 0.8 * c0 - 0.5 * c1 + 0.2 * noise
  }
  let x = @moonbit_doubleML.Matrix::from_array(x_flat, n, 2)
  let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)
  let one = @moonbit_doubleML.DoubleMLIRM::new(
    data,
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let many = @moonbit_doubleML.DoubleMLIRM::new(
    data,
    n_folds=2,
    n_rep=8,
    seed=3141,
  ).fit()
  section("cv_repeated")
  val("n_rep1_coef", one.coef())
  val("n_rep1_se", one.se())
  val("n_rep8_coef", many.coef())
  val("n_rep8_se", many.se())
  data_out("cv_c0", col(x_flat, n, 2, 0))
  data_out("cv_c1", col(x_flat, n, 2, 1))
  data_out("cv_y", y)
  data_out("cv_d", d)
  end()
}

// --------------------------------------------------------------------------- //
// 10. gain_statistics -- every branch of the algorithm, on chosen inputs
// --------------------------------------------------------------------------- //

///|
/// `gain_statistics` has six places where a branch can be taken, and the old
/// validator only ever saw the happy path because its inputs were `rng.uniform`.
/// The four coefficient blocks below are hand-picked so that, between them:
/// `cf_y` is clipped LOW (c1), interior (c2) and clipped HIGH (c0); `cf_d` is
/// interior (c0, c1) and clipped HIGH (c2, c3); and `rho` takes the interior
/// ratio (c0), the `sqrt` of a negative product -> NaN -> 1.0 (c1), the clip
/// at 1.0 (c2), and the `denom == 0` -> 1.0 path (c3).
///
/// There is no RNG anywhere in here, so CPython recomputes all sixteen outputs
/// exactly -- this is a branch test, not a tolerance test.
fn sec_gain_statistics() -> Unit {
  let var_y = 1.0
  // Row-major (n_coef, n_rep) = (4, 3).
  let var_res_long = [
    0.10, 0.11, 0.09, //
     0.50, 0.52, 0.51, //
     0.20, 0.21, 0.19, //
     0.30, 0.31, 0.29, //
  ]
  let var_res_short = [
    0.70, 0.71, 0.69, //
     0.20, 0.21, 0.19, //
     0.30, 0.31, 0.29, //
     0.30, 0.31, 0.29, //
  ]
  let nu2_long = [
    0.50, 0.51, 0.49, //
     0.45, 0.46, 0.44, //
     0.55, 0.56, 0.54, //
     0.60, 0.61, 0.59, //
  ]
  let nu2_short = [
    0.40, 0.41, 0.39, //
     0.30, 0.31, 0.29, //
     0.20, 0.21, 0.19, //
     0.25, 0.26, 0.24, //
  ]
  let coef_long = [
    1.00, 1.01, 0.99, //
     2.00, 2.01, 1.99, //
     3.00, 3.01, 2.99, //
     4.00, 4.01, 3.99, //
  ]
  let coef_short = [
    1.10, 1.11, 1.09, //
     1.50, 1.51, 1.49, //
     2.50, 2.51, 2.49, //
     4.50, 4.51, 4.49, //
  ]
  let res = @moonbit_doubleML.gain_statistics(
    @moonbit_doubleML.GainStatsSource::new(
      var_res_long, nu2_long, coef_long, 3, var_y,
    ),
    @moonbit_doubleML.GainStatsSource::new(
      var_res_short, nu2_short, coef_short, 3, var_y,
    ),
  )
  section("gain_statistics")
  for c = 0; c < res.cf_y.length(); c = c + 1 {
    val("cf_y_" + c.to_string(), res.cf_y[c])
    val("cf_d_" + c.to_string(), res.cf_d[c])
    val("rho_" + c.to_string(), res.rho[c])
    val("delta_theta_" + c.to_string(), res.delta_theta[c])
  }
  // The inputs, so a disagreement is legible as "the data differs" rather than
  // "some number differs".
  data_out("var_res_long", var_res_long)
  data_out("var_res_short", var_res_short)
  data_out("nu2_long", nu2_long)
  data_out("nu2_short", nu2_short)
  data_out("coef_long", coef_long)
  data_out("coef_short", coef_short)
  val("n_coef", res.cf_y.length().to_double())
  end()
}

// --------------------------------------------------------------------------- //
// helpers
// --------------------------------------------------------------------------- //

///|
fn section(name : String) -> Unit {
  println("section " + name)
}

///|
fn end() -> Unit {
  println("end")
}

///|
fn val(label : String, v : Double) -> Unit {
  println("val " + label + " " + v.to_string())
}

///|
fn data_out(name : String, a : Array[Double]) -> Unit {
  let mut s = "data " + name + " " + a.length().to_string()
  for i = 0; i < a.length(); i = i + 1 {
    s = s + " " + a[i].to_string()
  }
  println(s)
}

///|
fn wsum(a : Array[Double]) -> Double {
  let mut s = 0.0
  for i = 0; i < a.length(); i = i + 1 {
    s = s + a[i]
  }
  s
}

///|
fn wvar(a : Array[Double]) -> Double {
  let n = a.length()
  let m = wsum(a) / n.to_double()
  let mut s = 0.0
  for i = 0; i < n; i = i + 1 {
    let d = a[i] - m
    s = s + d * d
  }
  s / n.to_double()
}

///|
/// The `k`-th central moment of `a`, about the sample mean.
fn wmoment(a : Array[Double], k : Int32) -> Double {
  let n = a.length()
  let m = wsum(a) / n.to_double()
  let mut s = 0.0
  for i = 0; i < n; i = i + 1 {
    let d = a[i] - m
    let mut p = 1.0
    for j = 0; j < k; j = j + 1 {
      p = p * d
    }
    s = s + p
  }
  s / n.to_double()
}

///|
fn col(
  flat : Array[Double],
  rows : Int32,
  stride : Int32,
  k : Int32,
) -> Array[Double] {
  let out = Array::make(rows, 0.0)
  for i = 0; i < rows; i = i + 1 {
    out[i] = flat[i * stride + k]
  }
  out
}

///|
/// The rows where d == g, as a properly-typed Array (not an ArrayView, which
/// has no `sort`). Needed twice below, once for the median and once for the
/// upper-half mean.
fn rows_where(
  d : Array[Double],
  y : Array[Double],
  n : Int32,
  g : Double,
) -> Array[Double] {
  let vs = Array::make(n, 0.0)
  let mut c = 0
  for i = 0; i < n; i = i + 1 {
    if d[i] == g {
      vs[c] = y[i]
      c = c + 1
    }
  }
  let out = Array::make(c, 0.0)
  for i = 0; i < c; i = i + 1 {
    out[i] = vs[i]
  }
  out.sort()
  out
}

///|
/// Empirical median of y among the rows where d == g.
fn median_of(
  d : Array[Double],
  y : Array[Double],
  n : Int32,
  g : Double,
) -> Double {
  let sl = rows_where(d, y, n, g)
  let c = sl.length()
  let mid = c / 2
  if c % 2 == 1 {
    sl[mid]
  } else {
    (sl[mid - 1] + sl[mid]) / 2.0
  }
}

///|
/// Mean of the upper half of y among the rows where d == g -- the empirical
/// CVaR at q = 0.5.
fn cvar_upper_half_mean(
  d : Array[Double],
  y : Array[Double],
  n : Int32,
  g : Double,
) -> Double {
  let sl = rows_where(d, y, n, g)
  let c = sl.length()
  let lo = c / 2
  let mut s = 0.0
  for i = lo; i < c; i = i + 1 {
    s = s + sl[i]
  }
  s / (c - lo).to_double()
}
