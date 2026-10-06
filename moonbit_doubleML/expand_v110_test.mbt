// v0.110.0 -- the RDD kernel menu and the MSE-optimal bandwidth.
//
// # What was wrong before
//
// `rdd.mbt`'s header said: "The port uses a triangular kernel and a fixed
// bandwidth, which keeps the hot path pure MoonBit and deterministic."
// That reads as a design decision. It was an unported capability reported
// as one, and worse, the header's own phrasing was the only place it was
// recorded -- the two weight sites just computed `1 - |u|/h` inline.
//
// # What these tests are for
//
// The kernel identities are EXACT, so they carry zero Monte-Carlo error and
// can use `==`. `expand_v109_test.mbt` had a lesson worth repeating here: a
// comparison that cannot see the change cannot testify about it. The
// "different kernel, different estimate" test therefore uses a DGP where the
// kernel genuinely matters -- a genuinely nonlinear function of the running
// variable, so the bias a local-LINEAR fit carries depends on the weighting
// kernel. Under the strictly linear DGP the existing RDD tests use, every
// kernel would give nearly the same answer and the assertion would be a
// bet on floating-point noise.
//
// The bandwidth gate does not re-run the search and compare numbers. The
// criterion is PUBLIC (`bandwidth_mse`), so the returned bandwidth can be
// checked against the objective it claims to minimise -- which is what makes
// "optimal" a checkable claim instead of an assertion.
//
// `RDDKernel`'s variants are file-scoped, so every construction here goes
// through `RDDKernel::parse`, which also exercises the parser.

// ---------------------------------------------------------------------------
// DGP — private to this file (MoonBit `fn` is file-scoped)
// ---------------------------------------------------------------------------

///|
/// Sharp RDD with a jump of `theta` at 0, plus a deliberately NONLINEAR
/// term `0.4*u^2`.
///
/// The nonlinearity is the point. Under a strictly linear function every
/// kernel is unbiased and they agree, so "a different kernel gives a
/// different estimate" would be untestable. Here the `u^2` term is
/// misspecified by this port's local-LINEAR design matrix (`[1, u, x...]`),
/// and the size of that misspecification bias depends on the weighting
/// kernel -- which is also why the kernel is worth choosing at all.
fn v110_rdd_data(
  n : Int,
  theta : Double,
  y_scale? : Double = 1.0,
) -> DoubleMLRDDData {
  let x = Matrix::zeros(n, 1)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  let score = Array::make(n, 0.0)
  // Noise is drawn into a pool first, then applied.
  //
  // `y_scale` multiplies the WHOLE outcome, not just the noise. That
  // distinction is the entire content of the homogeneity test: scaling
  // only the noise leaves the signal terms fixed, so the residual is
  // `(signal - fitted signal) + 3*noise` and is NOT 3x the original.
  // Scaling all of `y` scales every fitted intercept and therefore
  // every residual by exactly `y_scale`, and a sum of squared residual
  // differences must then scale by its square.
  //
  // An earlier version hand-rolled a hash for the noise. It had to keep
  // every intermediate under 2^30 (MoonBit `Int` is 31-bit) and the
  // surviving small-constant mixes avalanche badly over the few hundred
  // indices a test uses, which correlates the noise with the running
  // variable -- exactly the confound a rejection test should not have.
  // The rng pool mixes properly and costs one array.
  let rng = chacha8_rng(31)
  let noise : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    noise[i] = rng.double()
  }
  for i = 0; i < n; i = i + 1 {
    let u = (i.to_double() + 0.5) / (n.to_double() / 2.0) - 1.0
    score[i] = u
    d[i] = if u >= 0.0 { 1.0 } else { 0.0 }
    y[i] = (
        theta +
        0.7 * u +
        0.4 * u * u +
        theta * d[i] +
        0.1 * (noise[i] - 0.5) * 2.0
      ) *
      y_scale
  }
  DoubleMLRDDData::new(x, y, d, score)
}

///|
test "v110_kernel_identities_hold_exactly" {
  let h = 0.8
  let tri = RDDKernel::parse("triangular")
  let nrm = RDDKernel::parse("normal")
  let uni = RDDKernel::parse("uniform")
  let epa = RDDKernel::parse("epanechnikov")
  let quad = RDDKernel::parse("quadratic")
  // Peaks. Four of the five peak at exactly 1.0 at the cutoff...
  assert_true(tri.weight(0.0, h) == 1.0)
  assert_true(nrm.weight(0.0, h) == 1.0)
  assert_true(uni.weight(0.0, h) == 1.0)
  assert_true(quad.weight(0.0, h) == 1.0)
  // ...and Epanechnikov peaks at exactly 0.75, NOT 1.0. That 0.75 is the
  // normalisation constant that makes `K` integrate to 1 over its
  // support, and it is the one kernel here whose maximum is not 1.
  // The first version of this test asserted 1.0 and failed; the
  // formula `0.75 * (1 - t^2)` is `rdrobust`'s, and the constant is
  // part of the kernel, not a scale factor the caller supplies.
  assert_true(epa.weight(0.0, h) == 0.75)
  // compactly-supported variants vanish exactly at |u| = h
  assert_true(tri.weight(h, h) == 0.0)
  assert_true(tri.weight(-h, h) == 0.0)
  assert_true(epa.weight(h, h) == 0.0)
  assert_true(epa.weight(-h, h) == 0.0)
  assert_true(quad.weight(h, h) == 0.0)
  assert_true(quad.weight(-h, h) == 0.0)
  // uniform is 1.0 across its WHOLE support, edge included
  assert_true(uni.weight(h * 0.5, h) == 1.0)
  assert_true(uni.weight(h, h) == 1.0)
  // normal does NOT vanish at the edge: it is exactly exp(-1/2) there,
  // which is the property that distinguishes it from the other four
  assert_true(nrm.weight(h, h) == @math.exp(-0.5))
  // exact half-support values. h*0.5/h is exactly 0.5 in IEEE double
  // (halving is exact), so these are equality checks, not tolerances.
  assert_true(tri.weight(h * 0.5, h) == 0.5)
  assert_true(quad.weight(h * 0.5, h) == 0.75)
  assert_true(epa.weight(h * 0.5, h) == 0.5625)
}

///|
/// At `|u| = h/2` the five weights are strictly ordered
/// `normal > quadratic > epanechnikov > triangular`
/// (exp(-1/8) ~ 0.8825 > 0.75 > 0.5625 > 0.5). This is what makes "a
/// different kernel is a different function" a check rather than a hope,
/// and it fails if any variant silently collapses onto another.
test "v110_kernels_are_strictly_ordered_at_half_support" {
  let h = 0.8
  let u = h * 0.5
  let w_tri = RDDKernel::parse("triangular").weight(u, h)
  let w_epa = RDDKernel::parse("epanechnikov").weight(u, h)
  let w_quad = RDDKernel::parse("quadratic").weight(u, h)
  let w_nrm = RDDKernel::parse("normal").weight(u, h)
  assert_true(w_nrm > w_quad)
  assert_true(w_quad > w_epa)
  assert_true(w_epa > w_tri)
}

///|
/// The kernel must reach the point estimate. This is the test that fails if
/// the `kernel` argument is threaded to `rdd_design` but ignored there, and
/// the nonlinear DGP is what makes it bite.
test "v110_different_kernel_changes_the_estimate" {
  let data = v110_rdd_data(600, 2.0)
  let tri = DoubleMLRDD::new(
    data,
    bandwidth=0.8,
    kernel=RDDKernel::parse("triangular"),
  ).fit()
  let quad = DoubleMLRDD::new(
    data,
    bandwidth=0.8,
    kernel=RDDKernel::parse("quadratic"),
  ).fit()
  let nrm = DoubleMLRDD::new(
    data,
    bandwidth=0.8,
    kernel=RDDKernel::parse("normal"),
  ).fit()
  assert_true(tri.coef() != quad.coef())
  assert_true(tri.coef() != nrm.coef())
  // and the configured kernel reads back from the model.
  //
  // Compared through `tag()` rather than `==`: `RDDKernel` does not
  // implement `Eq`. `derive(Eq)` trips `implicit_impl_as_method`, and an
  // explicit `impl Eq` trips `unused_value` in the non-test build (nothing
  // in the library itself compares two kernels). Both are `--deny-warn`
  // build failures, and paying a `moon.pkg` warning suppression for a
  // cosmetic comparison operator is the wrong trade.
  assert_true(quad.kernel().tag() == RDDKernel::parse("quadratic").tag())
}

///|
/// The kernel must ALSO reach the cluster / sensitivity path. Before
/// v0.110.0 that path computed `1 - |u|/h` inline while `rdd_design` used
/// whatever the estimator was configured with -- so with a non-triangular
/// kernel, `coef` and `cluster_hac_se` would have been computed from two
/// different sets of weights. Two paths, one setting.
///
/// `cluster_hac_se` takes one cluster id per BANDWIDTH-RESTRICTED LOCAL
/// ROW, not per observation (`rdd.mbt:1409-1412`), so the id array has to
/// be sized from `n_local()` after fitting. Sizing it to the full sample
/// aborts, which is the guard working.
test "v110_cluster_path_uses_the_same_kernel" {
  let data = v110_rdd_data(600, 2.0)
  let tri = DoubleMLRDD::new(
    data,
    bandwidth=0.8,
    kernel=RDDKernel::parse("triangular"),
  ).fit()
  let epa = DoubleMLRDD::new(
    data,
    bandwidth=0.8,
    kernel=RDDKernel::parse("epanechnikov"),
  ).fit()
  let n_local = tri.n_local()
  assert_true(n_local > 0)
  let cluster = Array::make(n_local, 0)
  for i = 0; i < n_local; i = i + 1 {
    cluster[i] = i / 40
  }
  let se_tri = tri.cluster_hac_se(cluster)
  let se_epa = epa.cluster_hac_se(cluster)
  assert_true(se_tri > 0.0)
  assert_true(se_epa > 0.0)
  assert_true(se_tri != se_epa)
  // Comparing the two SE values ALONE is not enough, and the first
  // version of this test was killed by that: `cluster_hac_se` mixes the
  // rebuilt weights with `hc0_m` / `hc0_e` stored by `fit`, and those are
  // already kernel-dependent, so the SE differs even when the rebuilt
  // weights reverted to a hardcoded triangular kernel. Reading the
  // weights is what makes the SECOND path observable.
  let w_tri = tri.kernel_weights(0.8)
  let w_epa = epa.kernel_weights(0.8)
  assert_true(w_tri.length() > 0)
  assert_true(w_tri.length() == w_epa.length())
  let mut differ = false
  for i = 0; i < w_tri.length(); i = i + 1 {
    if w_tri[i] != w_epa[i] {
      differ = true
    }
  }
  assert_true(differ)
}

///|
/// `Sigma^4` must actually be doing NEAREST-NEIGHBOUR MATCHING.
///
/// This is the assertion that distinguishes the v0.113.0 implementation
/// from the v0.110.0-v0.112.0 pooled sum of squares: `nnmatch = 1` and
/// `nnmatch = 3` pair each left residual with a different number of
/// right neighbours, so they MUST disagree. A pooled sum, or an
/// implementation that ignores `nnmatch` entirely, returns the same
/// number for both and fails here.
///
/// That matters because `rdrobust`'s default is `vce = "nn"` with
/// `nnmatch = 3`, and pooling was not the same estimator wearing the
/// same name.
test "v110_sigma4_responds_to_nnmatch" {
  let data = v110_rdd_data(600, 2.0)
  let m = DoubleMLRDD::new(
    data,
    bandwidth=0.8,
    kernel=RDDKernel::parse("triangular"),
  )
  // MoonBit optional parameters are passed BY NAME, not positionally.
  let s1 = m.bandwidth_sigma4(nnmatch=1)
  let s3 = m.bandwidth_sigma4(nnmatch=3)
  let s9 = m.bandwidth_sigma4(nnmatch=9)
  assert_true(s1 > 0.0)
  assert_true(s3 > 0.0)
  // 1 and 3 must differ, or the matching is not happening
  assert_true(s1 != s3)
  // and a wider neighbour set is a different number again
  assert_true(s3 != s9)
}

///|
/// `Sigma^4` is a sum of SQUARED residual differences, so scaling the
/// outcome noise by `k` must scale it by exactly `k^2`. This is a
/// homogeneity property with no sampling in it: the same fitted
/// design, the same folds, the same matching, only the residual scale
/// differs.
///
/// Not asserted as `==`: the WLS solve under a doubled outcome can
/// differ from the original in the last bit or two, so the ratio is
/// checked at 1e-9 relative rather than exactly. The margin is still
/// four to six orders of magnitude tighter than anything statistical,
/// and it pins the two things a mutation here could break: that the
/// differences are SQUARED, and that no normalisation sneaks in.
test "v110_sigma4_scales_with_the_square_of_the_outcome_noise" {
  let base = v110_rdd_data(600, 2.0)
  // scale the WHOLE outcome by 3, so every residual scales by 3
  let loud = v110_rdd_data(600, 2.0, y_scale=3.0)
  let quiet = DoubleMLRDD::new(
    base,
    bandwidth=0.8,
    kernel=RDDKernel::parse("triangular"),
  )
  let loud_m = DoubleMLRDD::new(
    loud,
    bandwidth=0.8,
    kernel=RDDKernel::parse("triangular"),
  )
  let s_quiet = quiet.bandwidth_sigma4()
  let s_loud = loud_m.bandwidth_sigma4()
  assert_true(s_quiet > 0.0)
  assert_true(s_loud > 0.0)
  let ratio = s_loud / s_quiet
  assert_true((ratio - 9.0).abs() < 1.0e-9)
}

///|
/// The criterion must be checkable from OUTSIDE, not merely
/// self-consistent. At `h = h_pilot` the bias term
/// `(xi(h) - xi_pilot)^2` is identically zero BY CONSTRUCTION, so the
/// whole criterion collapses to its variance term:
///
///     bandwidth_mse(h_pilot) == bandwidth_sigma4() / n      (exactly)
///
/// That identity is what pins the `b^4 * sigma4 / n` term. Deleting it
/// leaves the search still minimising its own criterion, so every other
/// assertion in this file stays green -- which is precisely why
/// `bandwidth_sigma4` had to be made public.
test "v110_bandwidth_mse_at_pilot_equals_the_variance_term" {
  let data = v110_rdd_data(600, 2.0)
  let m = DoubleMLRDD::new(
    data,
    bandwidth=0.8,
    kernel=RDDKernel::parse("triangular"),
  )
  let h_pilot = m.pilot_bandwidth()
  let sigma4 = m.bandwidth_sigma4()
  let n = m.n_obs()
  assert_true(sigma4 > 0.0)
  // exact equality, not a tolerance: both sides are the same
  // floating-point expression over the same `sigma4`.
  assert_true(m.bandwidth_mse(h_pilot) == sigma4 / n.to_double())
  // and the b^4 scaling is real: doubling the multiplier multiplies
  // the variance term by 16, so the criterion at 2*h_pilot must be
  // strictly larger than at h_pilot (the bias term cannot pull it
  // back below, because it is added to a positive variance floor).
  assert_true(m.bandwidth_mse(2.0 * h_pilot) > m.bandwidth_mse(h_pilot))
}

///|
/// The MSE-optimal bandwidth must actually MINIMISE the criterion, and the
/// criterion is public so this can be checked without re-running the
/// search. Sampling the grid is enough to kill an argmin that was
/// accidentally written as an argmax.
///
/// The sampled points MUST lie ON the search grid. The first version
/// sampled `b` in `{0.5, 0.75, 1.0, 1.5, 2.0}`, and only the two
/// endpoints are grid points: the grid is `0.5 + 1.5*g/49`, so
/// `b = 0.75` needs `g = 8.1667`, `b = 1.0` needs `g = 16.3333`, and
/// `b = 1.5` needs `g = 21.7778` -- none integral. Off-grid points can
/// have a HIGHER criterion than the grid maximum, so the assertions
/// held and mutation M3 (argmin written as argmax) passed the whole
/// suite. The sampled grid indices below are integers by construction,
/// so every sampled point is a point the search actually visited.
test "v110_optimal_bandwidth_minimises_its_criterion" {
  let data = v110_rdd_data(600, 2.0)
  let m = DoubleMLRDD::new(
    data,
    bandwidth=0.8,
    kernel=RDDKernel::parse("triangular"),
  )
  let h_star = m.optimal_bandwidth()
  let h_pilot = m.pilot_bandwidth()
  assert_true(h_star > 0.0)
  // it must live inside the searched band, scaled by the pilot
  assert_true(h_star >= 0.5 * h_pilot)
  assert_true(h_star <= 2.0 * h_pilot)
  let mse_star = m.bandwidth_mse(h_star)
  // grid indices: both ends, the pilot, and two interiors -- all integer,
  // so every sampled bandwidth is one the search evaluated.
  for g in [0, 10, 24, 38, 49] {
    let b = 0.5 + 1.5 * g.to_double() / 49.0
    assert_true(m.bandwidth_mse(b * h_pilot) >= mse_star)
  }
}

///|
/// The returned bandwidth has to be usable: feed it straight back into
/// `new` and the estimator must fit and produce a finite coefficient.
test "v110_optimal_bandwidth_feeds_back_into_fit" {
  let data = v110_rdd_data(600, 2.0)
  let m = DoubleMLRDD::new(
    data,
    bandwidth=0.8,
    kernel=RDDKernel::parse("quadratic"),
  )
  let h_star = m.optimal_bandwidth()
  let fitted = DoubleMLRDD::new(
    data,
    bandwidth=h_star,
    kernel=RDDKernel::parse("quadratic"),
  ).fit()
  assert_true(fitted.n_local() > 0)
  assert_true(fitted.coef().is_nan() == false)
  assert_true(fitted.se() > 0.0)
}
