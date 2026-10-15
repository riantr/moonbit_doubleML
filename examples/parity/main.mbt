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
/// upstream's coefficient varies with sd 0.0347 across 20 fold seeds, and the
/// port lands 0.75 sd from upstream's mean -- inside the noise. Its standard
/// error does NOT: the port's `se` is ~0.0022 below anything upstream
/// produced, which is recorded as an open defect rather than folded into the
/// tolerance.
fn sec_did_pyexample() -> Unit {
  section("did_pyexample")
  // Emitted first, and it gates everything below. The first version fitted
  // unconditionally and panicked at `did_cs.mbt:1263` on the 3-row stub --
  // n_folds=2 on three observations. An emitter that crashes takes the other
  // ten sections' output with it, so a clean "not generated" is strictly
  // better than a stack trace.
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
    // 94% of the gap was the fixture. What remains (0.00077) is 0.89 fold-sd,
    // inside the noise, and the coefficient tightens from -0.167398 to
    // -0.149834 against upstream's -0.150185.
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
/// (`discover_groups_times`, `did_cs.mbt:89-95`). The `inf` that broke the
/// earlier attempt came from `time_type="float"`; `pyexample_did_cs2021.py`
/// recodes to integer and the conventions reconcile.
///
/// WHY 6 CELLS, NOT 12
/// ===================
/// Upstream's `"standard"` yields 12 `(g, t_pre, t_eval)` triples; this port
/// can express 6. The split is structural and measured, not chosen:
///
///   * this port fixes its base period at `g_value - 1` (`did_cs.mbt:1563`)
///     and restricts the panel to `(g == g_value) U (g == never_treated)`
///     (`did_cs.mbt:1589`);
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
