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
/// Where the DGP is deterministic (`i % 2`, `i % 100`, a linear index ramp)
/// the Python side regenerates it itself, which is the stronger test: two
/// independent constructions of the same data, not one copied from the other.
fn main {
  sec_quantile()
  sec_rdd()
  sec_cvar()
  sec_blp_policy()
  sec_did_binary()
  sec_did_cs()
  sec_did_pyexample()
  sec_did_pyexample_cs2021()
  sec_did_cs_binary()
  sec_did_binary_upstream()
  sec_pyexample_suite()
  sec_bootstrap()
  sec_padjust()
  sec_cv_repeated()
  sec_gain_statistics()
  sec_lplr_upstream()
  sec_lplr_smalln()
  sec_pq_qte()
  sec_policytree_upstream()
  sec_rdd_var()
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
  // The `cov_type` arms. `DoubleMLRDD`'s default is HOMOSKEDASTIC --
  // `(X'WX)^-1_00 * sum_k w_k e_k^2 / n^2` -- while `rdrobust`, which upstream
  // wraps, reports a heteroskedasticity-robust variance and bias-corrects the
  // point estimate by default. Which of these arms the divergence lives in is
  // a measurement, so both are emitted rather than argued.
  let sharp_hc0 = @moonbit_doubleML.DoubleMLRDD::new(
    @moonbit_doubleML.DoubleMLRDDData::new(ux, ys, ds, sc),
    bandwidth=0.5,
    cov_type="HC0",
  ).fit()
  val("sharp_coef_hc0", sharp_hc0.coef())
  val("sharp_se_hc0", sharp_hc0.se())
  let fuzzy_hc0 = @moonbit_doubleML.DoubleMLRDD::new(
    @moonbit_doubleML.DoubleMLRDDData::new(ux, yf, df, sc),
    bandwidth=0.5,
    fuzzy=true,
    cov_type="HC0",
  ).fit()
  val("fuzzy_coef_hc0", fuzzy_hc0.coef())
  val("fuzzy_se_hc0", fuzzy_hc0.se())
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
// 6b. did_pyexample -- the port run on PYTHON-GENERATED data
// --------------------------------------------------------------------------- //

///|
/// The one section that runs on data Python generated, rather than data this
/// package made up. `pyexample_data.mbt` is written by `pyexample_did.py`
/// from the real upstream example
///
///     np.random.seed(42)
///     data = make_did_SZ2020(n_obs=500, return_type="DataFrame")
///     obj  = dml.DoubleMLDIDData(data, "y", "d")
///     dml.DoubleMLDID(obj, ml_g, ml_m, n_folds=2, n_rep=1).fit()
///
/// -- lifted from the `DoubleMLDID` docstring -- and restored to a committed
/// placeholder afterwards.
///
/// WHY THIS IS A DIFFERENT KIND OF CHECK
/// =====================================
/// Every other section answers "is the port self-consistent with a second
/// implementation of the same idea". This one answers "does the port agree
/// with upstream, on upstream's dataset". Nothing here is ours.
///
/// The CS2021 half (`sec_did_pyexample_cs2021`, below) covers upstream's
/// MULTI-COHORT estimator. An earlier revision of this file carried a note
/// saying no such comparison was possible, on two grounds. Both were measured
/// and both were FALSE -- see `sec_did_pyexample_cs2021` and
/// `pyexample_did_cs2021.py` for the measurements.
///
/// SAMPLE SPLITTING IS THE KNOWN CONFOUNDER
/// =========================================
/// Upstream draws folds from numpy's global RNG; this port draws its own from
/// `seed=`. Different partitions of the same rows, so the numbers cannot be
/// bit-equal. `pyexample_did.py` measures that band rather than guessing it:
/// on the SHIPPED fixture (n_obs 2000, dgp seed 7) upstream's coefficient
/// varies with sd 0.01128 across 10 fold seeds and its standard error with sd
/// 0.000865, and the port lands 0.03 sd and 0.89 sd from upstream on the two
/// -- inside the noise on both, and both are hard 3-sd gates.
///
/// The 500-observation, seed-42 fixture that upstream's own docstring uses is
/// NOT the one measured here, and the earlier revision of this note was wrong
/// to quote its numbers as if it were: `_verify/_seed_sweep_1660.py` found
/// that fixture's coefficient is 0.063 against a fold sd of 0.04150, i.e. 1.5x
/// noise, and permuting the treatment column moves it by 0.0007. A gate on
/// that fixture would pass whether the estimator is correct or hard-codes
/// zero.
fn sec_did_pyexample() -> Unit {
  section("did_pyexample")
  // Emitted first, and it gates everything below. The first version fitted
  // unconditionally and panicked at `require(n_folds <= data.n_obs())`
  // (`did.mbt:276`) on the 3-row stub -- n_folds=2 on three observations. An
  // emitter that crashes takes the other ten sections' output with it, so a
  // clean "not generated" is strictly better than a stack trace.
  let generated = pyexample_generated() != 0
  val("sz_generated", if generated { 1.0 } else { 0.0 })
  if !generated {
    end()
    return
  }

  let n_sz = sz2020_n_obs()
  let p_sz = sz2020_n_feat()
  // `DoubleMLDIDData::new` is declared `raise DIDDataError` (it rejects a
  // non-binary `d`), so it may only be called from a raising function or
  // inside try/catch. `main` is not one.
  let fitted_sz = @moonbit_doubleML.DoubleMLDID::new(
    @moonbit_doubleML.DoubleMLDIDData::new(
      @moonbit_doubleML.Matrix::from_array(sz2020_x(), n_sz, p_sz),
      sz2020_y(),
      sz2020_d(),
    ),
    n_folds=2,
    n_rep=1,
    seed=42,
    // CONFIGURED TO MATCH UPSTREAM, and both of these were measured.
    //
    // Taking the port's own defaults made the SE come out 8% above upstream,
    // which looked like a port defect. It is not -- it is this fixture
    // misconfiguring the port. Upstream's `DoubleMLDID` defaults to
    // `in_sample_normalization=True` and REFUSES an `ml_m` without
    // `.predict_proba()`, i.e. it requires a classifier; the port defaults to
    // `false` and a linear regression. Measured on the generated dataset:
    //
    //   ml_m=reg  norm=False -> se 0.0756218   <- the defaults; the "8% defect"
    //   ml_m=reg  norm=True  -> se 0.0742462
    //   ml_m=cls  norm=False -> se 0.0720907
    //   ml_m=cls  norm=True  -> se 0.0708030   <- upstream's configuration
    //   upstream              -> se 0.0700322
    //
    // The fixture accounted for 86% of the gap, not for all of it. The total
    // gap is 0.0055896 (0.0756218 - 0.0700322); the fixture's part of it is
    // 0.0048188 (0.0756218 - 0.0708030); 0.0007708 -- 14% -- remains. What
    // remains is 0.89 fold-sd, inside the noise, and the coefficient tightens
    // from -0.167398 to -0.149834 against upstream's -0.150185.
    //
    // The two rows the gap is made of are re-derived on every run, not
    // remembered: this fit emits `sz_se` (upstream's configuration) and
    // `sz_se_defaults` (the port's own defaults, fitted again below), and
    // `pyexample_did.py` checks the split against the numbers quoted above.
    // The middle two rows are a one-off measurement, not re-measured.
    ml_m=@moonbit_doubleML.LearnerDispatch::logistic_regression(
      @moonbit_doubleML.LogisticRegression::new(),
    ),
    in_sample_normalization=true,
  ).fit() catch {
    _ =>
      abort(
        "did_pyexample: DoubleMLDIDData::new rejected the generated SZ2020 " +
        "fixture (d must be binary 0/1)",
      )
  }
  val("sz_coef", fitted_sz.coef())
  val("sz_se", fitted_sz.se())
  val("sz_n_obs", fitted_sz.data.n_obs().to_double())
  // The data travels with the estimate so the validator can confirm the port
  // fitted the rows it was handed, not some other panel.
  data_out("sz_y", sz2020_y())
  data_out("sz_d", sz2020_d())
  // THE SAME FIT UNDER THE PORT'S OWN DEFAULTS, so the "ml_m=reg norm=False"
  // row of the table above is measured rather than remembered. The two
  // arguments are OMITTED ON PURPOSE: `ml_m` defaults to a linear regression
  // and `in_sample_normalization` defaults to `false`, and that pair IS the
  // default configuration. Naming them explicitly would pin the numbers to
  // today's defaults instead of tracking them, so a default that ever changes
  // would leave this row silently describing the past.
  let fitted_sz_defaults = @moonbit_doubleML.DoubleMLDID::new(
    @moonbit_doubleML.DoubleMLDIDData::new(
      @moonbit_doubleML.Matrix::from_array(sz2020_x(), n_sz, p_sz),
      sz2020_y(),
      sz2020_d(),
    ),
    n_folds=2,
    n_rep=1,
    seed=42,
  ).fit() catch {
    _ =>
      abort(
        "did_pyexample: the default-configuration refit hit the same " +
        "DoubleMLDIDData::new rejection as the fit above",
      )
  }
  val("sz_se_defaults", fitted_sz_defaults.se())
  end()
}

// --------------------------------------------------------------------------- //
// 6c. did_pyexample_cs2021 -- the MULTI-COHORT port on PYTHON-GENERATED data
// --------------------------------------------------------------------------- //

///|
/// Upstream's `DoubleMLDIDMulti` on `make_did_CS2021`, which is where this
/// port's DID-CS machinery actually lives (`sec_did_pyexample` covers the
/// single-cohort `DoubleMLDID`).
///
/// THE "NO CS2021 COMPARISON IS POSSIBLE" NOTE WAS WRONG. Twice.
///
/// The first claim was that upstream ships the CS2021 DGP but no CS2021
/// estimator. It ships `DoubleMLDIDMulti`, and its own docstring example is
/// built on this DGP. The second was that the never-treated conventions
/// disagree, so the port would treat a cohort as its own control. They agree
/// for INTEGER `g`: `_get_never_treated_value` returns `0` for integer dtype
/// and `inf` only for floating dtype, and `0` is precisely this port's rule
/// (`discover_groups_times`, `did_cs.mbt:84-95`). The `inf` that broke the
/// earlier attempt came from `time_type="float"`; `pyexample_did_cs2021.py`
/// recodes to integer and the conventions reconcile.
///
/// WHY 6 CELLS, NOT 12
/// ===================
/// Upstream's `"standard"` yields 12 `(g, t_pre, t_eval)` triples; this port
/// can express 6. The split is structural and measured, not chosen:
///
///   * this port fixes its base period at `g_value - 1` (`did_cs.mbt:1565`)
///     and restricts the panel to `(g == g_value) U (g == never_treated)`
///     (`did_cs.mbt:1591`);
///   * upstream picks `t_pre = t_values[t_values < g][-1]`, then
///     `min(t_values[i], t_pre)`;
///   * the two therefore agree EXACTLY on the cells where upstream landed on
///     `t_pre == g - 1`, and cannot be asked about the rest.
///
/// Those 6 are every post-treatment cell of every cohort. They are passed
/// explicitly as `gt_combinations` rather than via the `"standard"` keyword,
/// because the keyword yields only 3 of the 6 -- asking explicitly is the
/// stronger comparison.
///
/// `DoubleMLDIDMulti`'s `ignore(t_pre)` (`did_multi.mbt:326`) is a real
/// divergence from upstream, and it is NOT fixed here. It is unreachable on
/// these cells, and that is the reason the gate is sound rather than lucky: the
/// requested `t_pre` is the period the inner estimator picks anyway. The other
/// 6 cells stay outside the comparison and are counted in the output.
///
/// `cs2021_never_treated` is emitted as a real read of `data.groups`, not a
/// hard-coded 0, so the assertion that the two conventions coincide is checked
/// against what the port actually inferred.
fn sec_did_pyexample_cs2021() -> Unit {
  section("did_pyexample_cs2021")
  // Its OWN sentinel, not `pyexample_generated()`: the two gates share one
  // fixture file and splice disjoint halves, so a shared sentinel would let the
  // SZ2020 writer's value decide whether this half runs.
  let generated = cs2021_generated() != 0
  val("cs_generated", if generated { 1.0 } else { 0.0 })
  if !generated {
    end()
    return
  }

  let n_cs = cs2021_n_obs()
  let p_cs = cs2021_n_feat()
  let x_cs = @moonbit_doubleML.Matrix::from_array(cs2021_x(), n_cs, p_cs)
  let y_cs = cs2021_y()
  let d_cs = cs2021_d()
  let t_cs = cs2021_t()
  let id_cs = cs2021_id()
  let g_cs = cs2021_g()

  // `DoubleMLDIDCSData::new` does not declare `raise DIDDataError` on this
  // build -- it `abort`s instead (its own `catch` turns the precondition into
  // an abort, `did_cs.mbt:69-72`), so a `catch` here would be an `unused_try`.
  let cs_data = @moonbit_doubleML.DoubleMLDIDCSData::new(
    x_cs, y_cs, d_cs, t_cs, id_cs, g_cs,
  )

  // `discover_groups_times` DROPS the never-treated sentinel (the minimum `g`)
  // from `groups`, so `groups` starts at the SECOND-smallest label. Emitting
  // it is the non-circular half of the convention check: if the port had
  // picked any cohort other than 0 as its control, `groups` would begin
  // somewhere else and this row would move. The circular half -- "min(g) is the
  // control" -- is a rule, not a measurement, so it is deliberately NOT what
  // this row asserts; the ATT rows are what actually detect a wrong control,
  // because a treated cohort used as its own control returns ~0 or a sign
  // flip (measured on this DGP before the recode: ATT(g=2, t=4) came back
  // -12.96 against a realised truth of +2.96).
  let groups = cs_data.groups
  val(
    "cs_min_group_excluded",
    if groups.length() > 0 {
      groups[0].to_double()
    } else {
      -1.0
    },
  )
  val("cs_n_groups", groups.length().to_double())
  val("cs_n_periods", cs_data.times.length().to_double())

  // The 6 comparable cells, in the order `pyexample_did_cs2021.py` emits them.
  let n_cells = cs2021_n_cells()
  let combos : Array[(Int32, Int32, Int32)] = []
  for i = 0; i < n_cells; i = i + 1 {
    combos.push((cs2021_cell_g(i), cs2021_cell_t_pre(i), cs2021_cell_t_eval(i)))
  }

  let fitted_cs = @moonbit_doubleML.DoubleMLDIDMulti::new(
    cs_data,
    gt_combinations=combos,
    control_group="never_treated",
    n_folds=2,
    n_rep=1,
    seed=42,
    // MATCHED TO UPSTREAM, and this was measured rather than assumed -- the
    // same two settings the SZ2020 section needs, for the same two reasons
    // (upstream defaults `in_sample_normalization=True` and requires an `ml_m`
    // with `.predict_proba()`; this port defaults the opposite).
    ml_g=@moonbit_doubleML.LearnerDispatch::linear_regression(),
    ml_m=@moonbit_doubleML.LearnerDispatch::logistic_regression(
      @moonbit_doubleML.LogisticRegression::new(),
    ),
    in_sample_normalization=true,
  ).fit()
  val("cs_n_cells", fitted_cs.n_combinations().to_double())
  for i = 0; i < n_cells; i = i + 1 {
    val("cs_coef_" + i.to_string(), fitted_cs.coef_at_idx(i))
    val("cs_se_" + i.to_string(), fitted_cs.se_at_idx(i))
  }
  // The panel travels with the estimate so the validator can confirm the port
  // fitted the rows it was handed, not some other panel.
  data_out("cs_y", y_cs)
  data_out("cs_d", d_cs)
  let g_dbl = Array::make(n_cs, 0.0)
  let t_dbl = Array::make(n_cs, 0.0)
  for i = 0; i < n_cs; i = i + 1 {
    g_dbl[i] = g_cs[i].to_double()
    t_dbl[i] = t_cs[i].to_double()
  }
  data_out("cs_g", g_dbl)
  data_out("cs_t", t_dbl)
  end()
}

// --------------------------------------------------------------------------- //
// 6b. pyexample_suite -- the core estimator family, port vs upstream
// --------------------------------------------------------------------------- //

///|
/// Six estimators that both sides can express, on THREE datasets, because they
/// do not share a treatment domain: `d` is binary on A, CONTINUOUS on B
/// (PLIV), and binary-with-a-binary-instrument on C (IIVM / LATE).
///
/// Every learner is spelled out rather than left to a default. Two of these
/// constructors default to something upstream rejects outright --
/// `DoubleMLPLR::new` defaults BOTH learners to a REGRESSOR, and
/// `DoubleMLIIVM::new` defaults `ml_r` to a regressor where upstream's must be
/// a classifier (`iivm.py:164`, `_check_learner(..., classifier=True)`). A port
/// default that would turn this gate red for the wrong reason is a trap for
/// whoever has to read the failure, so nothing here leans on one.
///
/// `DoubleMLSSM::new` has no `ml_pi` slot, while upstream takes the selection
/// propensity `P(S = 1 | D, X)` as a THIRD learner. The port's `fit` does take
/// it (`ml_pi~ : LearnerDispatch = self.ml_m,`, `ssm.mbt:694`), defaulting
/// to `ml_m`, so it is passed explicitly here.
/// Relying on that default happens to match today and would silently stop
/// matching the day it changed -- and nothing in the output would say why.
///
/// `DoubleMLPLIV::new` likewise takes ONE `learner` for all three of upstream's
/// slots. Upstream's are all `LinearRegression` on this DGP, so a single linear
/// learner is a faithful stand-in rather than a shortcut.
///
/// Upstream's BLP regresses the orth signal on a ONE-COLUMN basis (x1), so the
/// basis here is that single column and not the full design. Passing all p
/// columns would still fit -- it is a valid BLP -- but it would no longer be
/// the estimator the reference measured.
///
/// DID is absent on purpose: `pyexample_did.py` and `pyexample_did_cs2021.py`
/// already gate it upstream-side, and a third copy would add runtime without
/// adding coverage.
///
/// `DoubleMLPolicyTree` is absent too, for a different reason. It is the one
/// estimator here whose port defaults genuinely diverge from upstream's
/// (`depth=1, min_leaf_n=5` against `depth=2, min_samples_leaf=8,
/// ccp_alpha=0.01`), and upstream's exposes no `coef`/`se` at all -- only a root
/// split. Reconciling that is a reported-behaviour decision, not a gate
/// detail. `suite_a_sig` is still generated, so enabling it later is a one-line
/// change here rather than another fixture rewrite.
fn sec_pyexample_suite() -> Unit {
  section("pyexample_suite")
  // Its OWN sentinel. `pyexample_generated()` would be true whenever the DID
  // fixture is installed, which says nothing about whether THIS file is the
  // real one or the committed 3-row placeholder.
  let generated = suite_generated() != 0
  val("suite_generated", if generated { 1.0 } else { 0.0 })
  if !generated {
    end()
    return
  }
  let n = suite_n()
  let p = suite_p()

  let xa = @moonbit_doubleML.Matrix::from_array(suite_a_x(), n, p)
  let ya = suite_a_y()
  let da = suite_a_d()
  let sa = suite_a_s()

  let xb = @moonbit_doubleML.Matrix::from_array(suite_b_x(), n, p)
  let yb = suite_b_y()
  let db = suite_b_d()
  let zb = suite_b_z()

  let xc = @moonbit_doubleML.Matrix::from_array(suite_c_x(), n, p)
  let yc = suite_c_y()
  let dc = suite_c_d()
  let zc = suite_c_z()

  let lin = @moonbit_doubleML.LearnerDispatch::linear_regression()
  let logi = @moonbit_doubleML.LearnerDispatch::logistic_regression(
    @moonbit_doubleML.LogisticRegression::new(),
  )

  // -- dataset A: binary d, MAR selection -------------------------------- //
  let plr = @moonbit_doubleML.DoubleMLPLR::new(
    @moonbit_doubleML.DoubleMLData::new(xa, ya, da),
    learner_l=lin,
    learner_m=logi,
    n_folds=2,
    n_rep=1,
    seed=42,
  ).fit()
  let irm = @moonbit_doubleML.DoubleMLIRM::new(
    @moonbit_doubleML.DoubleMLData::new(xa, ya, da),
    n_folds=2,
    n_rep=1,
    seed=42,
    ml_g=lin,
    ml_m=logi,
  ).fit()
  let ssm = @moonbit_doubleML.DoubleMLSSM::new(
    @moonbit_doubleML.DoubleMLSSMData::new(xa, ya, da, sa),
    n_folds=2,
    n_rep=1,
    seed=42,
    ml_g=lin,
    ml_m=logi,
  ).fit(ml_pi=logi)
  // BLP gets a BARE one-column basis `x0`, while the Python side hands upstream
  // `[1, x0]`. That asymmetry is the whole alignment, and getting it backwards
  // is measurable rather than subtle.
  //
  // Upstream is `sm.OLS(orth_signal, basis)` with no `add_constant` and no
  // `has_constant` (`blp.py:239`): it is origin-forced on whatever basis it is
  // given, and `_all_coef[:, i] = blp_model.params` stores exactly
  // `basis.shape[1]` numbers. The port's `LinearRegression::fit` ALWAYS
  // prepends an intercept (`augment_with_intercept`, `linear.mbt:102`) and
  // `DoubleMLBLP::fit` stores
  // that whole augmented vector, so the port's `coef` is `basis.cols() + 1`
  // long with the intercept at index 0 -- a convention `predictions` itself
  // relies on (`self.coef[0]`, `blp_policy.mbt:677`) and `n_params()`
  // documents.
  //
  // So each side is given the raw column and each side's own convention adds
  // the constant: upstream's basis is `[1, x0]`, the port's is `x0`, both
  // solve the identical design `[1, x0]`, and both return `[intercept, slope]`
  // in that order. Measured agreement: coef[0] 6.8e-14, se[0] 1.4e-15.
  //
  // Passing `[1, x0]` to the PORT as well does NOT work, and the failure is
  // worth recording: `LinearRegression::fit` prepends a second constant column
  // regardless, the design `[1, 1, x0]` is rank-deficient, and the 1e-10 ridge
  // splits the intercept between the two constant columns. Measured on this
  // DGP: coef[0] 0.33253 and coef[1] 0.33222, which sum to 0.66475 -- the
  // true intercept -- with the slope pushed to an unemitted index 2. Both
  // numbers are individually plausible and jointly obviously wrong.
  let basis_a = @moonbit_doubleML.Matrix::from_array(
    col(suite_a_x(), n, p, 0),
    n,
    1,
  )
  let blp = @moonbit_doubleML.DoubleMLBLP::new(
    basis_a,
    sa,
    cov_type="HC0",
    ml_g=lin,
  ).fit()

  // -- dataset B: continuous d, continuous z ---------------------------- //
  let pliv = @moonbit_doubleML.DoubleMLPLIV::new(
    @moonbit_doubleML.DoubleMLPLIVData::new(xb, yb, db, zb),
    n_folds=2,
    n_rep=1,
    seed=42,
    learner=lin,
  ).fit()

  // -- dataset C: binary d, binary z (LATE) ----------------------------- //
  let iivm = @moonbit_doubleML.DoubleMLIIVM::new(
    @moonbit_doubleML.DoubleMLIIVMData::new(xc, yc, dc, zc),
    n_folds=2,
    n_rep=1,
    seed=42,
    ml_g=lin,
    ml_m=logi,
    ml_r=logi,
  ).fit()

  // -- policy and risk estimators, also on dataset A --------------------- //
  // APO (policy value at one level), APOS (across levels) and CVAR
  // (conditional value at risk) are cross-sectional, so dataset A serves all
  // three and this section stays a generalisation rather than a fourth
  // dataset.
  //
  // `ml_m` is a CLASSIFIER in all three and is spelled out rather than left to
  // a default. For CVAR that is not cosmetic: upstream REJECTS a regressor
  // there -- "Invalid learner provided for ml_m: LinearRegression() has no
  // method .predict_proba()" -- and the port's `DoubleMLCVAR::new` defaults
  // `ml_m` to exactly that regressor. The default is left alone (changing a
  // published default is a behaviour change) but it is never relied on here.
  //
  // `normalize_ipw` is pinned rather than inherited for the same reason, and
  // the values ARE upstream's: APO and APOS default to `false`, CVAR to
  // `true`. A future change to either default would otherwise silently move
  // three gated numbers.
  let apo = @moonbit_doubleML.DoubleMLAPO::new(
    @moonbit_doubleML.DoubleMLData::new(xa, ya, da),
    treatment_level=1.0,
    n_folds=2,
    n_rep=1,
    seed=42,
    normalize_ipw=false,
    ml_g=lin,
    ml_m=logi,
  ).fit()
  let apos = @moonbit_doubleML.DoubleMLAPOS::new(
    @moonbit_doubleML.DoubleMLData::new(xa, ya, da),
    [0.0, 1.0],
    n_folds=2,
    n_rep=1,
    seed=42,
    normalize_ipw=false,
    ml_g=lin,
    ml_m=logi,
  ).fit()
  let cvar = @moonbit_doubleML.DoubleMLCVAR::new(
    @moonbit_doubleML.DoubleMLData::new(xa, ya, da),
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    n_rep=1,
    seed=42,
    normalize_ipw=true,
    ml_g=lin,
    ml_m=logi,
  ).fit()

  val("plr_coef", plr.coef())
  val("plr_se", plr.se())
  val("irm_coef", irm.coef())
  val("irm_se", irm.se())
  val("ssm_coef", ssm.coef())
  val("ssm_se", ssm.se())
  val("blp_coef_0", blp.coef()[0])
  val("blp_coef_1", blp.coef()[1])
  val("blp_se_0", blp.se()[0])
  val("blp_se_1", blp.se()[1])
  val("pliv_coef", pliv.coef())
  val("pliv_se", pliv.se())
  val("iivm_coef", iivm.coef())
  val("iivm_se", iivm.se())
  val("apo_coef", apo.coef())
  val("apo_se", apo.se())
  // APOS returns one coefficient PER treatment level, so it is emitted per
  // index. Collapsing to a scalar would compare one level and silently ignore
  // the other, which is how a two-level policy check becomes a one-level one
  // without anything failing.
  let apos_coefs = apos.coefs()
  let apos_ses = apos.ses()
  val("apos_n", apos_coefs.length().to_double())
  for i = 0; i < apos_coefs.length(); i = i + 1 {
    val("apos_coef_" + i.to_string(), apos_coefs[i])
    val("apos_se_" + i.to_string(), apos_ses[i])
  }
  val("cvar_coef", cvar.coef())
  val("cvar_se", cvar.se())
  val("n_estimators", 9.0)
  val("n", n.to_double())
  val("p", p.to_double())
  // A fingerprint of the rows the port actually fitted, so a stale build that
  // ran the 3-row PLACEHOLDER reads as a number mismatch instead of a
  // mystery. Sums, not the full columns: 3 x 1000 doubles is an unreadable
  // dump, and a sum still moves if any single element differs.
  val("sum_a_y", wsum(ya))
  val("sum_a_d", wsum(da))
  val("sum_a_s", wsum(sa))
  // `suite_a_sig` is the SIGNED (+/-1) orth signal `DoubleMLPolicyTree` wants
  // (`bin_signal = (sign(orth_signal) + 1) / 2`), not the 0/1 `s` above. The
  // tree itself is deferred, but the column still has to round-trip: a
  // placeholder that emitted `s` here would compile just as well and would
  // only fail the day someone enabled the estimator.
  val("sum_a_sig", wsum(suite_a_sig()))
  val("sum_b_y", wsum(yb))
  val("sum_b_d", wsum(db))
  val("sum_b_z", wsum(zb))
  val("sum_c_y", wsum(yc))
  val("sum_c_d", wsum(dc))
  val("sum_c_z", wsum(zc))
  end()
}

// --------------------------------------------------------------------------- //
// 6c. did_cs_binary -- upstream's DoubleMLDIDCSBinary, cell by cell
// --------------------------------------------------------------------------- //

///|
/// The one DID variant whose two sides are structurally IDENTICAL:
///
///     upstream  (obj_dml_data, g_value, t_value_pre, t_value_eval, ml_g, ...)
///     port      (data,        g_value, t_value_pre, t_value_eval, ..., ml_g)
///
/// Same four leading arguments, same names, same order. Both are TOLD which
/// cell to estimate, so there is no grid-derivation question at all -- the
/// thing that limited the CS2021 gate to 6 of upstream's 12 standard cells.
/// `in_sample_normalization` is the only default that differs (upstream
/// `True`, port `False`), so it is pinned explicitly in both directions.
///
/// `DoubleMLDIDCS` itself is deliberately NOT gated against. Upstream's is
/// deprecated -- "will be removed with version 0.12.0" -- and it refuses
/// `DoubleMLPanelData` outright. `DoubleMLDIDCSBinary` is the successor.
///
/// The CS2021 sentinel is shared ON PURPOSE: this section reads the same
/// `cs2021_*` block, including the cell list, from the same fixture. A
/// separate sentinel would be a lie in the other direction -- there is no
/// separate data, and `pyexample_did_cs_binary.py` writes exactly the block
/// `pyexample_did_cs2021.py` writes.
fn sec_did_cs_binary() -> Unit {
  section("did_cs_binary")
  let generated = cs2021_generated() != 0
  val("csb_generated", if generated { 1.0 } else { 0.0 })
  if !generated {
    end()
    return
  }
  let n_cs = cs2021_n_obs()
  let p_cs = cs2021_n_feat()
  let x_cs = @moonbit_doubleML.Matrix::from_array(cs2021_x(), n_cs, p_cs)
  let cs_data = @moonbit_doubleML.DoubleMLDIDCSData::new(
    x_cs,
    cs2021_y(),
    cs2021_d(),
    cs2021_t(),
    cs2021_id(),
    cs2021_g(),
  )
  let n_cells = cs2021_n_cells()
  val("csb_n_cells", n_cells.to_double())
  for i = 0; i < n_cells; i = i + 1 {
    let gv = cs2021_cell_g(i)
    let tp = cs2021_cell_t_pre(i)
    let te = cs2021_cell_t_eval(i)
    // One fit per cell, and the cell is REQUESTED rather than inferred -- so
    // this row is evidence that the port estimates the cell it was told to,
    // not that its internal derivation happens to land there.
    let fitted = @moonbit_doubleML.DoubleMLDIDCSBinary::new(
      cs_data,
      gv,
      tp,
      te,
      control_group="never_treated",
      n_folds=2,
      n_rep=1,
      seed=42,
      in_sample_normalization=true,
      ml_g=@moonbit_doubleML.LearnerDispatch::linear_regression(),
      ml_m=@moonbit_doubleML.LearnerDispatch::logistic_regression(
        @moonbit_doubleML.LogisticRegression::new(),
      ),
    ).fit()
    val("csb_coef_" + i.to_string(), fitted.coef())
    val("csb_se_" + i.to_string(), fitted.se())
  }
  end()
}

// --------------------------------------------------------------------------- //
// 6d. did_binary_upstream -- DoubleMLDIDBinary against upstream on CS2021
// --------------------------------------------------------------------------- //

///|
/// The CS2021 panel, one `DoubleMLDIDBinary` per cell, REQUESTED explicitly on
/// both sides. All six cells, none excluded -- unlike the CS2021 gate above,
/// which could only compare the two `(g, t)` pairs each estimator derives.
///
/// `n_folds = 2`, and that is a hard port limitation rather than a choice:
/// `DoubleMLDIDBinary::new` builds a FOUR-ROW dummy inner model
/// (`DoubleMLDIDData::new(Matrix::zeros(4, ...), ...)`, `did_binary.mbt:440-441`)
/// so that construction does not trip `require(n_folds <= data.n_obs())`,
/// which caps `n_folds` at 4 for this type no matter how many rows the real
/// wide subset holds.
///
/// This section exists because that ceiling was misdiagnosed. An earlier
/// version passed upstream's default `n_folds = 5`, aborted at `did.mbt:276`,
/// and was recorded as a row-count defect -- "the eligible subset is too
/// small". The subset is NOT small. Measured here directly: for ATT(2,1,2)
/// `preprocess_did_binary` emits 515 wide rows out of a 5000-row panel, and
/// `n_folds` of 2, 3 and 4 all construct AND fit, giving coef 1.1448 / 1.1461
/// / 1.1187 against upstream's 1.1386. `n_folds = 5` aborts during
/// CONSTRUCTION -- before `preprocess_did_binary` is ever reached -- so the
/// offending `DoubleMLDID::new` is the dummy, not the real one. The dummy and
/// the real model raise at the SAME line and print the SAME message, which is
/// why the call site could not be identified from the panic text alone.
/// See `_verify/DID_BINARY_PANIC_1680.md`.
///
/// So the ceiling is a property of the CONSTRUCTOR, not of the data, and the
/// port is free to be compared against upstream at any fold count the
/// constructor accepts.
fn sec_did_binary_upstream() -> Unit {
  section("did_binary_upstream")
  // Shared sentinel, same reason as `sec_did_cs_binary`: same fixture file,
  // same `cs2021_*` block, no separate data.
  let generated = cs2021_generated() != 0
  val("db_generated", if generated { 1.0 } else { 0.0 })
  if !generated {
    end()
    return
  }
  let n_cs = cs2021_n_obs()
  let p_cs = cs2021_n_feat()
  let panel = @moonbit_doubleML.DoubleMLDIDBinaryData::new(
    @moonbit_doubleML.Matrix::from_array(cs2021_x(), n_cs, p_cs),
    cs2021_y(),
    cs2021_d(),
    cs2021_t(),
    cs2021_g(),
    cs2021_id(),
  )
  let n_cells = cs2021_n_cells()
  val("db_n_cells", n_cells.to_double())
  for i = 0; i < n_cells; i = i + 1 {
    // `ml_m` is a CLASSIFIER on upstream's side (`P[D=1|X]`), and the port
    // DEFAULTS IT TO A REGRESSOR (`did_binary.mbt:376`). Left at the default
    // this gate would be red for a reason that has nothing to do with parity,
    // so both learners are spelled out. Same trap as `sec_cvar`.
    let fitted = @moonbit_doubleML.DoubleMLDIDBinary::new(
      panel,
      cs2021_cell_g(i),
      cs2021_cell_t_pre(i),
      cs2021_cell_t_eval(i),
      control_group="never_treated",
      n_folds=2,
      n_rep=1,
      seed=42,
      in_sample_normalization=true,
      ml_g=@moonbit_doubleML.LearnerDispatch::linear_regression(),
      ml_m=@moonbit_doubleML.LearnerDispatch::logistic_regression(
        @moonbit_doubleML.LogisticRegression::new(),
      ),
    ).fit()
    val("db_coef_" + i.to_string(), fitted.coef())
    val("db_se_" + i.to_string(), fitted.se())
  }
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
  section("padjust")
  // Vector `a` spans three orders of magnitude and crosses BH's rejection
  // threshold, so `bh` is not trivially the identity and the monotone
  // step-down structure is actually exercised.
  emit_padjust("a", [0.001, 0.008, 0.02, 0.04, 0.2, 0.5, 0.9])
  // Vector `b` exists for ONE measured reason, not for coverage.
  //
  // `tsbh_p_adjust` applies the BH step-up factor as a division,
  // `p / ((k+1)/n)`, because that is what statsmodels does. The
  // algebraically equal `p * n / (k+1)` is a different sequence of
  // roundings and can differ in the last bit. Vector `a` does NOT
  // expose that difference anywhere in the final output (measured: 0
  // of 7 cells), so with only vector `a` the validator's 0.0
  // tolerance cannot tell the two forms apart and the bit-exactness
  // claim would be ungated -- mutation M4 in
  // `_verify/_tsbh_mutation_1660.py` survives without it.
  //
  // Vector `b` is the smallest vector found that does expose it: cell 5
  // differs by 1.11e-16 (0.6183333333333334 vs 0.61833333333333329).
  emit_padjust("b", [0.07, 0.11, 0.19, 0.23, 0.41, 0.53, 0.71])
  end()
}

///|
fn emit_padjust(tag : String, p : Array[Double]) -> Unit {
  for m in ["holm", "bonferroni", "bh", "by", "tsbh"] {
    let adj = @moonbit_doubleML.p_adjust(m, p)
    for i = 0; i < p.length(); i = i + 1 {
      val(m + tag + "_" + i.to_string(), adj[i])
    }
  }
  data_out("unadjusted_p" + tag, p)
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
// 15. lplr_upstream -- LPLR against upstream on the EXAMPLE's own data
// --------------------------------------------------------------------------- //

///|
/// WHY THIS SECTION EXISTS, and what it replaces
/// ============================================
/// `examples/lplr` is one of the twenty e2e-checked examples, and
/// `validate_lplr_with_python.py` does compare it against upstream
/// `doubleml.plm.DoubleMLLPLR`. That comparison cannot see the estimator.
/// Measured (see `_verify/LPLR_GATE_BLINDNESS_1680.md`):
///
///   * it fits upstream on `build_simplified_lzz2020` -- a numpy DGP -- and
///     compares that against the example's `chacha8_rng` numbers. Two
///     different datasets, so a gap is guaranteed before the estimator is
///     even in question;
///   * it then attributes the gap to "upstream's own run-to-run spread"
///     (theta sd 0.198 over 7 refits) and widens the band to
///     `3 * max(se)` with a 0.10 floor, i.e. ~0.81 here.
///     Measured on FIXED data with the partition pinned per seed, the same
///     fold draw moves theta by sd 0.308 (min 0.154, max 1.155 around a
///     true alpha of 0.5). So the width is legitimate -- it is demanded by
///     the fold draw -- but it is spent on noise that can be REMOVED
///     instead of absorbed.
///
/// Upstream accepts an externally supplied partition. Measured: writing
/// `_smpls` / `_smpls_inner` and refitting gives bit-identical output
/// (|dcoef| = 0.000e+00), because LPLR draws a DOUBLE split
/// (`_double_sample_splitting = True`) and 0.11.3 exposes no public setter
/// for it. `fit` draws its outer partition as `kfold(n, n_folds, seed + r)`
/// (`lplr.mbt:781`), so the port's partition is reproducible here and is
/// emitted rather than assumed.
///
/// The data is emitted for the reason given at the top of this file: the
/// DGP is `chacha8`-driven and CPython cannot reproduce it. Emitting it
/// turns "two different random datasets landed near each other" into a
/// comparison on identical rows.
///
/// REMAINING MISMATCH, stated rather than hidden: the port's INNER split is
/// still drawn from `self.seed + r * 1000 + 7`. `set_sample_splitting`
/// (`lplr.mbt:2022`) covers the outer partition only; the OUTER partition is
/// replaced and the INNER one is not. `fit` is therefore
/// re-run across five seeds -- with the outer partition HELD FIXED, so the
/// only thing that moves is the inner draw -- and those are emitted as
/// `lplr_ns_seed*`. The band the Python side uses is built from that
/// measured spread, not from an assumption about it.
fn sec_lplr_smalln() -> Unit {
  // The small-n regime, where the port and upstream disagree -- but NOT
  // always in the same direction.
  //
  // The `lplr_upstream` section is n = 500 and there the two agree to 0.007.
  // Off that design point they do not agree at all. On IDENTICAL rows and the
  // IDENTICAL outer partition, measured:
  //
  //     n=60    port -0.0491291    upstream  3.53962    ratio 0.014
  //     n=100   port 14.431        upstream -0.558127   ratio 25.9
  //     n=160   port  0.580578     upstream  0.749398   ratio 0.77
  //
  // v0.163.4: this block previously read -3.319646e+06 and -1.119798e+06 for
  // the port at n=60 and n=100. Those were PRE-D4 and no longer describe this
  // code. Upstream's three numbers were and are unchanged; only the port's
  // moved, because D4 (v0.163.0) made the point estimate `theta` itself
  // instead of a re-derivation of it. Section 12 showed a reported -3.3e6 is
  // arithmetically unreachable by `theta` -- the Newton step is clamped to
  // 0.25 over 50 iterations and the start `sum(d*t_pred)/sum(d^2)` is bounded
  // by `|t_pred| <= 37` -- so that 1e6 was never in the root at all.
  //
  // THE DIRECTION REVERSES, which is the part a summary hides. At n=60 the
  // port is the well-conditioned one (`se` 0.762) and upstream is the
  // pathological one (`se` 20.2, coef 3.54 against a true effect near 0.5).
  // At n=100 it is exactly reversed: the port is the broken one (`se` 751657,
  // one warning) and upstream returns `se` 0.83. At n=160 both are finite and
  // well-conditioned and sit 29% apart. So there is no single "the port
  // diverges at small n" story to match -- do not read the n=60 row as the
  // port misbehaving.
  //
  // Upstream is non-finite on its own at these sizes (section 20: 7 of 25
  // draws at n=60, 2 of 25 at n=100 and n=160, 0 of 25 at n=500), which is
  // why this port keeps its damped Newton. That rate is an AGGREGATE, and it
  // does not license reading any individual row above as the port's fault.
  // Over the same 200-design family as at the time of the D4 work, upstream's
  // worst |coef| was 1.01e4 and the port's 1.03e11 -- those are PRE-D4
  // figures and are kept only as the record of what the family looked like
  // before the point estimate was fixed. They are not re-measured here.
  //
  // This section exists so `pyexample_lplr.py` re-measures all of it on every
  // run. It REPORTS the numbers; it does not gate them. Gating a known
  // divergence would be a permanently-red gate, which is worse than none --
  // the finding is recorded in `_verify/LPLR_GATE_BLINDNESS_1680.md` sections
  // 11, 20, 21 and 22, and the numbers belong next to the ones that ARE
  // gated, where nobody has to remember to look.
  let cases = [(60, 9001), (100, 9002), (160, 9003)]
  for c in cases {
    let (n, seed) = c
    let p = 6
    let alpha = 0.5
    section("lplr_smalln_" + n.to_string())
    let x_flat = Array::make(n * p, 0.0)
    let y = Array::make(n, 0.0)
    let d = Array::make(n, 0.0)
    let rng = @moonbit_doubleML.chacha8_rng(seed)
    let pool : Array[Double] = []
    while pool.length() < n * p + n {
      let u1 = rng.double()
      let u2 = rng.double()
      let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
      let r = (-2.0 * @math.ln(safe)).sqrt()
      let th = 2.0 * 3.141592653589793 * u2
      pool.push(r * @math.cos(th))
      pool.push(r * @math.sin(th))
    }
    for i = 0; i < n * p; i = i + 1 {
      x_flat[i] = pool[i]
    }
    for i = 0; i < n; i = i + 1 {
      let x1 = x_flat[i * p]
      let x2 = x_flat[i * p + 1]
      let a = 0.5 * @math.sin(x1) + 0.5 * @math.cos(x2) + 0.5 * pool[n * p + i]
      let p_t = @moonbit_doubleML.expit(a)
      let u = rng.double()
      d[i] = if u < p_t { 1.0 } else { 0.0 }
    }
    for i = 0; i < n; i = i + 1 {
      let x1 = x_flat[i * p]
      let x2 = x_flat[i * p + 1]
      let x3 = x_flat[i * p + 2]
      let x4 = x_flat[i * p + 3]
      let x5 = x_flat[i * p + 4]
      let x6 = x_flat[i * p + 5]
      let r = 0.25 * x1 * x2 +
        0.25 * x3 * x3 +
        0.25 * @math.cos(x4) -
        0.5 * @math.sin(x5) +
        (if x6 > 0.0 { 1.0 } else { 0.0 }) -
        0.5
      let prob = @moonbit_doubleML.expit(alpha * d[i] + r)
      let u = rng.double()
      y[i] = if u < prob { 1.0 } else { 0.0 }
    }
    data_out("x", x_flat)
    data_out("y", y)
    data_out("d", d)
    val("n", n.to_double())
    val("p", p.to_double())
    let outer = @moonbit_doubleML.kfold(n, 2, seed)
    let fold_id = Array::make(n, 0.0)
    for f = 0; f < outer.length(); f = f + 1 {
      let te = outer[f].test_idx
      for j = 0; j < te.length(); j = j + 1 {
        fold_id[te[j]] = f.to_double()
      }
    }
    data_out("fold", fold_id)
    let data = @moonbit_doubleML.DoubleMLBinaryData::new(
      @moonbit_doubleML.Matrix::from_array(x_flat, n, p),
      y,
      d,
    )
    let m = @moonbit_doubleML.DoubleMLLPLR::new(
        data,
        score="nuisance_space",
        n_folds=2,
        n_folds_inner=2,
        seed~,
      )
      .set_sample_splitting([outer])
      .fit()
    val("port_coef", m.coef())
    val("port_se", m.se())
    val("port_n_warn", m.warnings().length().to_double())
    end()
  }
}

///|
fn sec_lplr_upstream() -> Unit {
  section("lplr_upstream")
  let n = 500
  let p = 6
  let alpha = 0.5
  let seed = 3141
  // Identical to `examples/lplr/main.mbt::build_dgp`. If the replication
  // ever drifts, `lplr_ns_theta` stops matching the example's own printed
  // `theta_hat = 0.464110` -- which is the check, not an assumption.
  let x_flat = Array::make(n * p, 0.0)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  // `build_dgp` draws from ONE rng handle threaded through the Box-Muller
  // pool and both Bernoulli loops, so the three share a stream. Drawing the
  // pool from a separate handle would shift every later value.
  let rng = @moonbit_doubleML.chacha8_rng(seed)
  let pool : Array[Double] = []
  while pool.length() < n * p + n {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let th = 2.0 * 3.141592653589793 * u2
    pool.push(r * @math.cos(th))
    pool.push(r * @math.sin(th))
  }
  for i = 0; i < n * p; i = i + 1 {
    x_flat[i] = pool[i]
  }
  for i = 0; i < n; i = i + 1 {
    let x1 = x_flat[i * p]
    let x2 = x_flat[i * p + 1]
    let a = 0.5 * @math.sin(x1) + 0.5 * @math.cos(x2) + 0.5 * pool[n * p + i]
    let p_t = @moonbit_doubleML.expit(a)
    let u = rng.double()
    d[i] = if u < p_t { 1.0 } else { 0.0 }
  }
  for i = 0; i < n; i = i + 1 {
    let x1 = x_flat[i * p]
    let x2 = x_flat[i * p + 1]
    let x3 = x_flat[i * p + 2]
    let x4 = x_flat[i * p + 3]
    let x5 = x_flat[i * p + 4]
    let x6 = x_flat[i * p + 5]
    let r = 0.25 * x1 * x2 +
      0.25 * x3 * x3 +
      0.25 * @math.cos(x4) -
      0.5 * @math.sin(x5) +
      (if x6 > 0.0 { 1.0 } else { 0.0 }) -
      0.5
    let prob = @moonbit_doubleML.expit(alpha * d[i] + r)
    let u = rng.double()
    y[i] = if u < prob { 1.0 } else { 0.0 }
  }
  data_out("lplr_x", x_flat)
  data_out("lplr_y", y)
  data_out("lplr_d", d)
  val("lplr_n", n.to_double())
  val("lplr_p", p.to_double())
  // The outer partition `fit` would draw anyway (`kfold(n, 2, seed + 0)`),
  // emitted row-by-fold so the Python side can install the SAME one.
  let outer = @moonbit_doubleML.kfold(n, 2, seed)
  let fold_id = Array::make(n, 0.0)
  for f = 0; f < outer.length(); f = f + 1 {
    let te = outer[f].test_idx
    for j = 0; j < te.length(); j = j + 1 {
      fold_id[te[j]] = f.to_double()
    }
  }
  data_out("lplr_fold", fold_id)
  let data = @moonbit_doubleML.DoubleMLBinaryData::new(
    @moonbit_doubleML.Matrix::from_array(x_flat, n, p),
    y,
    d,
  )
  let ns = @moonbit_doubleML.DoubleMLLPLR::new(
      data,
      score="nuisance_space",
      n_folds=2,
      n_folds_inner=2,
      seed~,
    )
    .set_sample_splitting([outer])
    .fit()
  val("lplr_ns_theta", ns.coef())
  val("lplr_ns_se", ns.se())
  let inst = @moonbit_doubleML.DoubleMLLPLR::new(
      data,
      score="instrument",
      n_folds=2,
      n_folds_inner=2,
      seed~,
    )
    .set_sample_splitting([outer])
    .fit()
  val("lplr_in_theta", inst.coef())
  val("lplr_in_se", inst.se())
  // Outer partition HELD FIXED across these seeds, so the only thing that
  // varies is the inner draw. This is the port-side spread the band needs.
  let probe = [3141, 3142, 3143, 3144, 3145]
  for i = 0; i < probe.length(); i = i + 1 {
    let f2 = @moonbit_doubleML.DoubleMLLPLR::new(
        data,
        score="nuisance_space",
        n_folds=2,
        n_folds_inner=2,
        seed=probe[i],
      )
      .set_sample_splitting([outer])
      .fit()
    val("lplr_ns_seed" + probe[i].to_string(), f2.coef())
  }
  // MATCHED-LEARNER configuration -- the one upstream can actually mirror.
  //
  // The port's DEFAULTS are `linear_regression()` for BOTH slots, so `ml_M`
  // (which needs a probability) is fitted by OLS here. Upstream cannot
  // reproduce that at all: `_check_learner(ml_M, regressor=False,
  // classifier=True)` rejects a regressor outright. Comparing the default
  // configuration against upstream would therefore measure the LEARNER
  // CHOICE, not the estimator -- so the gate fits the port with
  // `ml_g`=OLS / `ml_m`=logistic, which is upstream's own
  // `LinearRegression` / `LogisticRegression` pairing, and compares THAT.
  //
  // The default configuration is still emitted above, so the size of the
  // learner-choice effect is visible rather than assumed.
  let mlog = @moonbit_doubleML.LearnerDispatch::logistic_regression(
    @moonbit_doubleML.LogisticRegression::new(),
  )
  let mols = @moonbit_doubleML.LearnerDispatch::linear_regression()
  let match_ns = @moonbit_doubleML.DoubleMLLPLR::new(
      data,
      score="nuisance_space",
      n_folds=2,
      n_folds_inner=2,
      seed~,
      ml_g=mols,
      ml_m=mlog,
    )
    .set_sample_splitting([outer])
    .fit()
  val("lplr_match_ns_theta", match_ns.coef())
  val("lplr_match_ns_se", match_ns.se())
  let match_in = @moonbit_doubleML.DoubleMLLPLR::new(
      data,
      score="instrument",
      n_folds=2,
      n_folds_inner=2,
      seed~,
      ml_g=mols,
      ml_m=mlog,
    )
    .set_sample_splitting([outer])
    .fit()
  val("lplr_match_in_theta", match_in.coef())
  val("lplr_match_in_se", match_in.se())
  for i = 0; i < probe.length(); i = i + 1 {
    let f3 = @moonbit_doubleML.DoubleMLLPLR::new(
        data,
        score="nuisance_space",
        n_folds=2,
        n_folds_inner=2,
        seed=probe[i],
        ml_g=mols,
        ml_m=mlog,
      )
      .set_sample_splitting([outer])
      .fit()
    val("lplr_match_seed" + probe[i].to_string(), f3.coef())
    let f4 = @moonbit_doubleML.DoubleMLLPLR::new(
        data,
        score="instrument",
        n_folds=2,
        n_folds_inner=2,
        seed=probe[i],
        ml_g=mols,
        ml_m=mlog,
      )
      .set_sample_splitting([outer])
      .fit()
    val("lplr_match_in_seed" + probe[i].to_string(), f4.coef())
  }
  end()
}

// --------------------------------------------------------------------------- //
// 16. pq_qte -- the quantile family against upstream, on an integer-only DGP
// --------------------------------------------------------------------------- //

///|
/// WHY THIS SECTION, and why it needs no data emission
/// ===================================================
/// RDD, PQ, QTE, LPQ and PolicyTree are five estimator slots on
/// `examples/main` that carried an ANALYTIC oracle only -- no upstream gate
/// at all. This covers the two quantile estimators. LPQ, RDD and PolicyTree
/// are still open.
///
/// Unlike the LPLR section above, NOTHING is emitted and no partition is
/// pinned, because the DGP is integer arithmetic only and CPython
/// rebuilds it independently from the same formulas. Per the header of
/// this file that is the STRONGER shape: two independent constructions of
/// the same numbers, not one copied from the other.
///
/// Every draw is a modulo, so there is no RNG library and no cross-language
/// stream mismatch to align. The formulas were settled in
/// `_verify/PQ_QTE_GATE_DESIGN_1680.md`, together with two DGP facts that
/// had to be measured rather than assumed:
///
///   * `1.0 * d` in `y` is LOAD-BEARING. Without it the true effect is zero,
///     `DoubleMLQTE` correctly returns ~0, and that reads as "broken".
///   * the first uniform draw, `(i * 48271) % 2147483647`, never wraps for
///     i < 1000 and is correlated with the `x` columns, so a fold held a
///     single class and every upstream fit raised. The replacement below
///     gives 447 treated / 553 control.
///
/// The propensities are deliberately confined to [0.15, 0.85]: in that
/// regime the port-vs-upstream `normalize_ipw` gap was measured at 3.8e-13,
/// so the gate tests the ESTIMATOR rather than the known flag gap.
///
/// BOTH learners are set to a classifier on both sides. Upstream's
/// `pq.py:174-175` checks BOTH `ml_g` and `ml_m` with `classifier=True`,
/// and the argument NAMES are inherited from the PLR family where `ml_g` is
/// the outcome learner -- in the quantile estimators the roles are swapped
/// and the names did not follow. The port's `ml_l` defaults to a REGRESSOR,
/// so leaving it alone would not even fit the same problem.
fn sec_pq_qte() -> Unit {
  section("pq_qte")
  let n = 1000
  let p = 2
  let x_flat = Array::make(n * p, 0.0)
  let d = Array::make(n, 0.0)
  let y = Array::make(n, 0.0)
  let mut treated = 0
  for i = 0; i < n; i = i + 1 {
    let ii = i.to_int64()
    let x1 = (ii * 7919 % 1000).to_double() / 500.0 - 1.0
    let x2 = (ii * 6271 % 997).to_double() / 498.5 - 1.0
    let ps = 0.5 + 0.20 * x1 + 0.15 * x2
    let u = (ii * 104729 + 12345) % 999983
    let ut = u.to_double() / 999983.0
    let di = if ut < ps { 1.0 } else { 0.0 }
    let e = (ii * 130363 + 777) % 262139
    x_flat[i * p] = x1
    x_flat[i * p + 1] = x2
    d[i] = di
    if di == 1.0 {
      treated = treated + 1
    }
    y[i] = 1.0 * di +
      0.5 * x1 +
      0.3 * x2 +
      0.25 * (e.to_double() / 131069.5 - 1.0)
  }
  val("pq_treated", treated.to_double())
  val("pq_n", n.to_double())
  val("pq_p", p.to_double())
  // A DATA FINGERPRINT, not just a class count. A battery arm that changed
  // the `x2` divisor left `pq_treated` at 447 -- the check passed, the gate
  // compared the port's correct rows against upstream's perturbed rows, and
  // the coefficient difference stayed inside the band. A count only says
  // "roughly the right number of treated"; sums over every column say the
  // rows are the rows. Exact to machine precision on both sides, because
  // both build the arrays from the same integer formulas.
  let mut sx1 = 0.0
  let mut sx2 = 0.0
  let mut sy = 0.0
  for i = 0; i < n; i = i + 1 {
    sx1 = sx1 + x_flat[i * p]
    sx2 = sx2 + x_flat[i * p + 1]
    sy = sy + y[i]
  }
  val("pq_sum_x1", sx1)
  val("pq_sum_x2", sx2)
  // `sum(d)` is the TREATED count, not the control one. The first version
  // emitted `d.length() - treated` and the gate refused to compare -- which
  // is the fingerprint working, catching a real slip on its first run.
  val("pq_sum_d", treated.to_double())
  val("pq_sum_y", sy)
  let data = @moonbit_doubleML.DoubleMLData::new(
    @moonbit_doubleML.Matrix::from_array(x_flat, n, p),
    y,
    d,
  )
  let clog = @moonbit_doubleML.LearnerDispatch::logistic_regression(
    @moonbit_doubleML.LogisticRegression::new(),
  )
  // ----- LPQ: the instrument-valued member of the quantile family -------
  //
  // A SEPARATE design, not a reuse of the PQ rows. LPQ needs a BINARY
  // instrument: `_check_data` (lpq.py:814) rejects a continuous one with
  // "exactly one binary variable with values 0 and 1 needs to be specified
  // as instrumental variable". The RDD-shaped running variable that suits
  // the RDD gate is not accepted here.
  //
  // Upstream demands `ml_g` and `ml_m` as classifiers; the port's
  // `DoubleMLLPQ::new` exposes NO learner parameters at all. The two agree
  // to ~7e-4 on the coefficient regardless, so the port's internal
  // learners are close enough for the comparison to mean something -- but
  // that is a measurement, not an assumption.
  let n2 = 1000
  let x2_flat = Array::make(n2 * 2, 0.0)
  let y2 = Array::make(n2, 0.0)
  let d2 = Array::make(n2, 0.0)
  let z2 = Array::make(n2, 0.0)
  let mut treated2 = 0
  let mut sz = 0.0
  let mut sy2 = 0.0
  for i = 0; i < n2; i = i + 1 {
    let ii = i.to_int64()
    let a1 = (ii * 7919 % 1000).to_double() / 500.0 - 1.0
    let a2 = (ii * 6271 % 997).to_double() / 498.5 - 1.0
    let zi = if ii * 3571 % 1009 < 505 { 1.0 } else { 0.0 }
    let ps2 = 0.5 + 0.25 * zi
    let u2 = (ii * 104729 + 12345) % 999983
    let di = if u2.to_double() / 999983.0 < ps2 { 1.0 } else { 0.0 }
    let e2 = (ii * 130363 + 777) % 262139
    x2_flat[i * 2] = a1
    x2_flat[i * 2 + 1] = a2
    z2[i] = zi
    d2[i] = di
    y2[i] = 1.0 * di + 0.5 * zi + 0.25 * (e2.to_double() / 131069.5 - 1.0)
    sz = sz + zi
    sy2 = sy2 + y2[i]
    if di == 1.0 {
      treated2 = treated2 + 1
    }
  }
  val("lpq_treated", treated2.to_double())
  val("lpq_sum_z", sz)
  val("lpq_sum_y", sy2)
  let lpq_data = @moonbit_doubleML.DoubleMLLPQData::new(
    @moonbit_doubleML.Matrix::from_array(x2_flat, n2, 2),
    y2,
    d2,
    z2,
  )
  // Re-seeded across a spread of values so the PORT side's spread is
  // measured here rather than assumed. Upstream is seeded with
  // `np.random.seed` on the other side of the gate.
  // Twelve seeds, not five. A band built from a 5-sample sd is a poor
  // estimate of the spread itself, and at five seeds `qte[0]_coef` landed
  // at 92% of its band -- which is a coin flip dressed as a gate. Twelve
  // matches the spread measured in `_verify/PQ_QTE_GATE_DESIGN_1680.md`.
  let seeds = [
    3141, 3142, 3143, 3144, 3145, 3146, 3147, 3148, 3149, 3150, 3151, 3152,
  ]
  for i = 0; i < seeds.length(); i = i + 1 {
    let sd = seeds[i]
    let pq = @moonbit_doubleML.DoubleMLPQ::new(
      data,
      treatment=1.0,
      quantile=0.5,
      n_folds=2,
      seed=sd,
      ml_l=clog,
      ml_m=clog,
    ).fit()
    val("pq_coef_s" + sd.to_string(), pq.coef())
    val("pq_se_s" + sd.to_string(), pq.se())
    let qte = @moonbit_doubleML.DoubleMLQTE::new(
      data,
      quantiles=[0.25, 0.5, 0.75],
      n_folds=2,
      seed=sd,
      ml_l=clog,
      ml_m=clog,
    ).fit()
    let coefs = qte.coefs()
    let ses = qte.ses()
    for k = 0; k < coefs.length(); k = k + 1 {
      val("qte_coef_s" + sd.to_string() + "_" + k.to_string(), coefs[k])
      val("qte_se_s" + sd.to_string() + "_" + k.to_string(), ses[k])
    }
    let lpq = @moonbit_doubleML.DoubleMLLPQ::new(
      lpq_data,
      treatment=1.0,
      quantile=0.5,
      n_folds=2,
      seed=sd,
    ).fit()
    val("lpq_coef_s" + sd.to_string(), lpq.coef)
    val("lpq_se_s" + sd.to_string(), lpq.se)
  }
  end()
}

// --------------------------------------------------------------------------- //
// 17. policytree -- the tree's decision rule against upstream, label for label
// --------------------------------------------------------------------------- //

///|
/// WHY THIS SECTION, and why the comparison is LABELS rather than structure
/// ==========================================================================
/// PolicyTree is the last of the five estimator slots on `examples/main` that
/// carried an ANALYTIC oracle only. PQ/QTE/LPQ are gated above, and RDD is
/// gated too -- on the bias-corrected arm, after the divergence recorded in
/// `_verify/RDD_PARITY_1680.md` turned out to have been measured on a
/// noiseless design. This closes PolicyTree.
///
/// Upstream is `doubleml.utils.policytree.DoubleMLPolicyTree`, which wraps a
/// `sklearn.tree.DecisionTreeClassifier`:
/// `bin_signal = (sign(s) + 1) / 2`, `sample_weight = abs(s)`,
/// `max_depth=depth`, `ccp_alpha=0.01`, `min_samples_leaf=8`. Two call-shape
/// traps: the argument order is REVERSED relative to the port
/// (`orth_signal` FIRST), and upstream's default `depth` is 2 while the port's
/// is 1 -- so depth is pinned on both sides rather than left to defaults.
///
/// The two builders are DIFFERENT ALGORITHMS, so the structure cannot be
/// compared directly:
///
///   * the port's `policy_tree_build` splits at the column MEAN; sklearn's
///     threshold is a MIDPOINT between two consecutive sorted values;
///   * the port's criterion is variance reduction on the RAW signal; upstream
///     is gini on the binarised signal weighted by `abs(s)`;
///   * the port's leaf label is the sign of the mean raw signal; upstream's is
///     `argmax` of the weighted class counts.
///
/// On a two-column design those differences put 10 of 300 rows in different
/// leaves (measured -- `_verify/POLICYTREE_PARITY_1680.md`). So the gate
/// compares what both algorithms DO rather than how they are built: the full
/// LABEL VECTOR over all rows. That is invariant to the threshold convention,
/// to the criterion, and even to the port splitting a zero-gain pure node at
/// depth 2 -- a structural difference with no effect on any prediction.
///
/// The design is `examples/main`'s own: one column on a symmetric grid,
/// `signal = sign(z)`. That is deliberate. It is the configuration the
/// repository SHIPS, and on it the two conventions coincide exactly (the grid
/// mean and the straddling midpoint are the same number), so this gate tests
/// the thing that runs rather than a matched configuration built to suit it.
///
/// `policy_value()` is deliberately NOT compared: it requires `honest = true`
/// and its own docstring proves it is identically the sample mean of the
/// signal, so agreeing on it would mean nothing.
fn sec_policytree_upstream() -> Unit {
  section("policytree")
  let n = 500
  let half = n / 2
  let x_flat = Array::make(n, 0.0)
  let s = Array::make(n, 0.0)
  let mut neg = 0
  let mut sz = 0.0
  let mut sz2 = 0.0
  for i = 0; i < n; i = i + 1 {
    let z = (i.to_double() - half.to_double()) / half.to_double()
    x_flat[i] = z
    let si = if z < 0.0 { -1.0 } else { 1.0 }
    s[i] = si
    sz = sz + si
    sz2 = sz2 + z * z
    if si < 0.0 {
      neg = neg + 1
    }
  }
  // A fingerprint, not a class count. `pt_neg` alone would survive a
  // permutation that reshuffles every row; `pt_sum_x2` is the second moment,
  // so it moves the moment any row is perturbed.
  val("pt_n", n.to_double())
  val("pt_sum_x", wsum(x_flat))
  val("pt_sum_x2", sz2)
  val("pt_sum_s", sz)
  val("pt_neg", neg.to_double())
  let x = @moonbit_doubleML.Matrix::from_array(x_flat, n, 1)
  let pt1 = @moonbit_doubleML.DoubleMLPolicyTree::new(x, s, depth=1).fit()
  val("pt1_split_feature", pt1.split_feature().to_double())
  val("pt1_split_value", pt1.split_value())
  let p1 = pt1.predict(x)
  let lab1 = Array::make(n, 0.0)
  let mut ones1 = 0
  for i = 0; i < n; i = i + 1 {
    lab1[i] = p1[i].to_double()
    if p1[i] == 1 {
      ones1 = ones1 + 1
    }
  }
  val("pt1_ones", ones1.to_double())
  data_out("pt1_labels", lab1)
  let probe = @moonbit_doubleML.Matrix::from_array([-0.5, 0.5], 2, 1)
  let pp1 = pt1.predict(probe)
  data_out("pt1_probe", [pp1[0].to_double(), pp1[1].to_double()])
  // Depth 2 is upstream's DEFAULT and the port's non-default. Both are fitted
  // and compared, so the gate covers the depth the upstream class actually
  // chooses unless told otherwise.
  let pt2 = @moonbit_doubleML.DoubleMLPolicyTree::new(x, s, depth=2).fit()
  val("pt2_split_feature", pt2.split_feature().to_double())
  val("pt2_split_value", pt2.split_value())
  let p2 = pt2.predict(x)
  let lab2 = Array::make(n, 0.0)
  let mut ones2 = 0
  for i = 0; i < n; i = i + 1 {
    lab2[i] = p2[i].to_double()
    if p2[i] == 1 {
      ones2 = ones2 + 1
    }
  }
  val("pt2_ones", ones2.to_double())
  data_out("pt2_labels", lab2)
  let pp2 = pt2.predict(probe)
  data_out("pt2_probe", [pp2[0].to_double(), pp2[1].to_double()])
  end()
}

// --------------------------------------------------------------------------- //
// 17b. rdd_var -- the variance arms, on a design whose residuals are NON-ZERO
// --------------------------------------------------------------------------- //

///|
/// WHY A SEPARATE SECTION, and why `sec_rdd` cannot answer the question
/// ==================================================================
/// `sec_rdd`'s design is EXACT: `y = 2 + u + 0.5*z + 2*d` with no noise, so
/// the local linear fit reproduces it to the last bit and every residual is
/// zero. Measured consequence, which is the whole reason this section exists:
///
///     sharp_se_hc0 = 0.000000000
///     fuzzy_se_hc0 = nan
///
/// A variance formula cannot be compared on a design where the variance is
/// identically zero. That is not a small detail -- it means the existing
/// section would have "agreed" with any formula, including a wrong one.
///
/// `DoubleMLRDD`'s default is HOMOSKEDASTIC --
/// `(X'WX)^-1_00 * sum_k w_k e_k^2 / n^2` -- while `rdrobust`, which upstream
/// wraps, reports a robust variance and bias-corrects the point estimate by
/// default. Which arm the divergence lives in has to be measured, and this
/// section adds noise so there is something to measure.
///
/// Integer-only DGP, like `sec_pq_qte`: CPython rebuilds the rows from the
/// same modulo formulas, so there is nothing to emit and nothing to drift.
/// The noise is what the upstream side needs -- without it `se` is 0 or NaN.
///
/// # v0.163.0 correction: the FIRST version of this DGP added NO noise
///
/// The noise term was `(i*130363 + 777) / 131069.5 - 1`, which is an exact
/// LINEAR function of `i` -- and `u` is also linear in `i`. So the "noise"
/// was collinear with the running variable, the local linear fit absorbed
/// it exactly, and the section reproduced `sec_rdd`'s zero-residual
/// degeneracy. Measured: `0.5 * noise` ranges over `[-0.497, 396.85]`
/// (a ramp, not a bounded shock), and regressing it on `(1, u)` leaves a
/// residual ss-sum of `6.9e-24`. The residuals were `1.7e-23`, so
/// `homo_se` was `3.15e-15` -- not `0.003535`, and not non-zero.
///
/// The replacement uses a multiplicative hash modulo a prime, which is not
/// a linear function of the index, so it is genuine non-collinear noise.
/// Residuals are now `~1.67e+01` per side.
fn sec_rdd_var() -> Unit {
  section("rdd_var")
  let n = 800
  let u = Array::make(n, 0.0)
  let z = Array::make(n, 0.0)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let ii = i.to_int64()
    let uu = (i.to_double() + 0.5) / 400.0 - 1.0
    let zi = (ii * 6271 % 997).to_double() / 498.5 - 1.0
    // Multiplicative hash mod a prime: NOT linear in `i`, hence not
    // collinear with `uu`. The first version of this line used
    // `(ii * 130363 + 777) / 131069.5 - 1`, which WAS linear in `i` --
    // see the section comment above.
    let ei = (ii * 2654435761 % 1000003).to_double() / 500001.5 - 1.0
    let di = if uu >= 0.0 { 1.0 } else { 0.0 }
    u[i] = uu
    z[i] = zi
    d[i] = di
    y[i] = 2.0 + uu + 0.5 * zi + 2.0 * di + 0.5 * ei
  }
  let ux = @moonbit_doubleML.Matrix::from_array(z, n, 1)
  let data = @moonbit_doubleML.DoubleMLRDDData::new(ux, y, d, u)
  val("n", n.to_double())
  val("sum_y", wsum(y))
  val("sum_d", wsum(d))
  val("sum_u", wsum(u))
  let homo = @moonbit_doubleML.DoubleMLRDD::new(data, bandwidth=0.5).fit()
  val("homo_coef", homo.coef())
  val("homo_se", homo.se())
  val("homo_n_local", homo.n_local().to_double())
  let hc0 = @moonbit_doubleML.DoubleMLRDD::new(
    data,
    bandwidth=0.5,
    cov_type="HC0",
  ).fit()
  val("hc0_coef", hc0.coef())
  val("hc0_se", hc0.se())
  // rdrobust's bias-corrected point estimate and its procedure-(iii)
  // robust SE. `tau_bc` defaults to `b = h / rho` with `rho = 1`, i.e.
  // `b == h`, and `p = 1, q = 2` -- rdrobust's own defaults. Emitted so
  // the comparison is against what a caller actually gets from
  // `DoubleMLRDD`, not a hand-rolled equivalent computed elsewhere.
  val("tau_bc", homo.tau_bc())
  val("tau_bc_se_rb", homo.tau_bc_se_rb())
  val("tau_bc_collapsed", homo.tau_bc_collapsed())
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
