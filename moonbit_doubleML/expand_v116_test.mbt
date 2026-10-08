// v0.116.0 -- `vce = "nn"`: the nearest-neighbour variance, and with it
// CCT inference PROCEDURE (iii) rather than procedure (ii).
//
// # The round in one paragraph
//
// v0.115.0 shipped the CCT bias-corrected POINT estimate (`tau_bc`) and a
// standard error for it that was honestly labelled as not being
// `rdrobust`'s robust one. `rdrobust`'s default robust variance for the
// bias-corrected estimator is `vce = "nn"`: nearest-neighbour matched
// residuals, fed into a sandwich whose meat matrix is `Q` -- the p-order
// fit MINUS its estimated bias term -- and whose bread is the p-order Gram
// at `h` even though the estimate is a q-order quantity at `b`. Both
// halves are implemented here, and both are checked against the upstream
// Python port rather than against an internal identity.
//
// # Why an external oracle, and which one
//
// There is no R here and no `rdrobust` install, so the oracle is the
// Python port shipped in the upstream repository `rdpackages/rdrobust`
// (`Python/rdrobust/src/rdrobust/`), pinned under
// `_verify/_upstream_rdrobust_py/` and runnable via `_verify/_oracle/`.
// It is not a re-derivation: `_verify/gen_v116_oracle.py` calls
// `rdrobust.rdrobust.rdrobust(...)` and dumps `_v116_golden.json`, and
// every constant below is copied from that file.
//
// This matters concretely. See the v0.115.0 section at the bottom: the
// oracle found a real defect that the entire v0.115.0 suite could not,
// because the gate that "checked" it compared two internal routes to the
// same wrong number.
//
// # The fixture is generated, not transcribed
//
// `v116_dgp` reproduces the oracle's DGP from the index, with the same
// LCG and the same floating-point association, so MoonBit and Python see
// bit-identical inputs without sharing a data file. That is checked, not
// assumed: `v116_the_oracle_and_this_port_see_the_same_data`.
//
// `n = 240`, running variable on a jittered grid over [-1, 1], sharp
// jump 0.55, and DELIBERATELY ASYMMETRIC curvature (0.35 left / 0.95
// right). The asymmetry is load-bearing: with equal curvature the
// per-side polynomial-order bias cancels in `xi_r - xi_l`, so the
// fixture cannot tell order 1 from order 2 at all (the v0.115.0
// finding, `c*s^2` on a symmetric window has intercept bias exactly
// `-0.1*c*h^2` per side).
//
// # Every tolerance here was MEASURED, not chosen
//
// The numbers in the comments next to each tolerance are the observed
// gaps against the oracle on this fixture. Where a tolerance is loose it
// is because a DIFFERENT, older code path is in the expression, and the
// reason is named.

///|
/// The oracle's DGP generator. `Int64` suffixes are load-bearing:
/// `2147483648` does not fit an `Int32` literal, and the arithmetic has
/// to reproduce Python's exact integers, not wrap.
fn v116_lcg(i : Int, salt : Int) -> Double {
  let s = (1103515245L * (i + 1).to_int64() + salt.to_int64()) % 2147483648L
  s.to_double() / 2147483648.0
}

///|
fn v116_dgp() -> (Array[Double], Array[Double]) {
  let n = 240
  let x = Array::make(n, 0.0)
  let y = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let jitter = 0.004 * (v116_lcg(i, 12345) - 0.5)
    let xi = -1.0 + 2.0 * i.to_double() / 239.0 + jitter
    let eps = (v116_lcg(i, 777) - 0.5) * 1.2
    let curv = if xi < 0.0 { 0.35 } else { 0.95 }
    let step = if xi >= 0.0 { 0.55 } else { 0.0 }
    x[i] = xi
    y[i] = 0.30 + 0.70 * xi + curv * xi * xi + step + eps
  }
  (x, y)
}

///|
/// No covariate column, on purpose: upstream's `R_p` / `R_q` are built from
/// the running variable alone (rdrobust.py:828-831) and the covariates
/// enter only through `D`, so a design with covariates is not the same
/// object upstream is computing and would be comparing two conventions.
fn v116_data() -> DoubleMLRDDData {
  let (x, y) = v116_dgp()
  let n = x.length()
  let d = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    d[i] = if x[i] >= 0.0 { 1.0 } else { 0.0 }
  }
  DoubleMLRDDData::new(Matrix::zeros(n, 0), y, d, x)
}

///|
/// The left `|x| <= 0.42` window of the DGP, ascending -- the exact slice
/// `gen_v116_oracle.py:nn_probe` hands to `_nn_residuals_jit`.
fn v116_left_window() -> (Array[Double], Array[Double]) {
  let (x, y) = v116_dgp()
  let uu : Array[Double] = []
  let yy : Array[Double] = []
  for i = 0; i < x.length(); i = i + 1 {
    if x[i] < 0.0 && x[i] >= -0.42 {
      uu.push(x[i])
      yy.push(y[i])
    }
  }
  (uu, yy)
}

///|
/// The mass-point slice: runs of 2, 1, 3, 1, 1, 1, 1 equal-`x`
/// observations. Small enough to read, and it forces the neighbourhood
/// walk to jump whole blocks instead of stepping through them.
fn v116_masspoint_x() -> Array[Double] {
  [0.01, 0.01, 0.02, 0.05, 0.05, 0.05, 0.09, 0.11, 0.20, 0.30]
}

///|
fn v116_masspoint_y() -> Array[Double] {
  [1.0, 1.4, 2.0, 3.0, 3.3, 3.9, 4.1, 4.4, 5.0, 6.0]
}

///|
/// Relative gap, used by every oracle comparison below.
fn v116_rel(a : Double, b : Double) -> Double {
  (a - b).abs() / b.abs()
}

///|
/// Assert every entry of a computed array equals the oracle entry BYTE
/// FOR BYTE. Used only where the port is a line-by-line transliteration
/// and the oracle's arithmetic is the same arithmetic, so anything short
/// of `==` would mean a real difference and not a rounding artefact.
fn v116_assert_exact(
  got : Array[Double],
  want : Array[Double],
  label : String,
) -> Unit raise Error {
  assert_true(got.length() == want.length())
  for i = 0; i < want.length(); i = i + 1 {
    if got[i] != want[i] {
      abort(
        label +
        " differs at " +
        i.to_string() +
        ": got " +
        got[i].to_string() +
        " want " +
        want[i].to_string(),
      )
    }
  }
}

// ---------------------------------------------------------------------------
// Oracle goldens -- copied from _verify/_v116_golden.json
// ---------------------------------------------------------------------------

///|
fn v116_oracle_nn_left_n1() -> Array[Double] {
  [
    -0.4390771806321389, 0.41059414196361094, -1.1791994210162268e-05, -0.41057371763051637,
    0.41052015077005116, -0.4105201507700511, 0.41046658390958585, -0.41046658390958585,
    0.4104130170491207, -0.4104130170491207, 0.4103594501886554, -0.4103594501886554,
    0.4103058833281902, -0.4103058833281902, 0.410252316467725, -0.410252316467725,
    0.4101987496072597, -0.4101987496072597, 0.41014518274679457, -0.41014518274679457,
    0.41009161588632925, -0.41009161588632925, 0.41003804902586416, -0.41003804902586416,
    0.4099844821653989, -0.4099844821653989, 0.4099309153049336, -0.4099309153049336,
    0.40987734844446844, -0.40987734844446844, 0.4098237815840032, -0.4098237815840032,
    0.40977021472353786, -0.40977021472353786, 0.40971664786307277, -0.40971664786307277,
    0.40966308100260745, -1.17919942101736e-05, -0.40964265666951294, 0.40958908980904774,
    -0.40958908980904774, 0.4095355229485825, -0.4095355229485825, 0.40948195608811716,
    -0.40948195608811716, 0.40942838922765196, -0.40942838922765196, 0.4093748223671868,
    -0.4093748223671868, 0.44114269112111154,
  ]
}

///|
fn v116_oracle_nn_left_n2() -> Array[Double] {
  [
    -0.26994601847560057, 0.49055796682336156, -1.1791994210162268e-05, -0.49061549460419057,
    0.49058456776288134, -0.4906347526908215, 0.4906038258495122, -0.4906540107774524,
    0.4906230839361432, -0.49067326886408347, 0.49064234202277424, -0.4906925269507143,
    0.49066160010940507, -0.49071178503734525, 0.490680858196036, -0.49073104312397614,
    0.4907001162826669, -0.4907503012106072, 0.49071937436929797, -0.49076955929723814,
    0.49073863245592886, -0.49078881738386904, 0.4907578905425598, -0.4908080754705,
    0.49077714862919086, -0.49082733355713093, 0.4907964067158217, -0.4908465916437619,
    0.4908156648024527, -0.49086584973039277, 0.49083492288908354, -0.4908851078170237,
    0.49085418097571437, -0.49090436590365466, 0.49087343906234543, -0.49092362399028566,
    0.49089269714897643, -1.17919942101736e-05, -0.49095022492980545, 0.4909192980884962,
    -0.4909694830164364, 0.49093855617512716, -0.49098874110306734, 0.4909578142617581,
    -0.4910079991896982, 0.49097707234838894, -0.4910272572763292, 0.49099633043501995,
    -0.49104651536296023, 0.2730350390464688,
  ]
}

///|
fn v116_oracle_nn_left_n3() -> Array[Double] {
  [
    -0.03489279372999775, 0.6821172397690562, -5.08854869239412e-05, -0.6821579180529871,
    0.2686598073819548, -0.2687761482904285, 0.26867035547041684, -0.2687866963788906,
    0.26868090355887914, -0.2687972444673528, 0.2686914516473412, -0.268807792555815,
    0.2687019997358034, -0.26881834064427707, 0.2687125478242655, -0.2688288887327393,
    0.26872309591272764, -0.26883943682120137, 0.2687336440011899, -0.2688499849096636,
    0.26874419208965195, -0.2688605329981258, 0.26875474017811424, -0.2688710810865879,
    0.2687652882665763, -0.2688816291750501, 0.2687758363550385, -0.2688921772635122,
    0.26878638444350067, -0.2689027253519743, 0.26879693253196274, -0.2689132734404365,
    0.26880748062042487, -0.2689238215288986, 0.2688180287088871, -0.2689343696173608,
    0.6815937217608727, -5.0885486923928795e-05, -0.6816344000448036, 0.26884314673197507,
    -0.26895948764044875, 0.26885369482043725, -0.26897003572891104, 0.2688642429088994,
    -0.26898058381737305, 0.26887479099736145, -0.2689911319058353, 0.26888533908582374,
    -0.33428862888356303, 0.3860943691197239,
  ]
}

///|
fn v116_oracle_nn_left_n5() -> Array[Double] {
  [
    0.05443800230973299, 0.734653445624925, 0.09856373607476936, -0.5374943322346132,
    0.18533438743728659, -0.31806009001491997, 0.31787350015936827, -0.3180185973032218,
    0.3178320074476702, -0.31797710459152384, 0.3177905147359721, -0.3179356118798257,
    0.317749022024274, -0.31789411916812754, 0.31770752931257595, -0.31785262645642953,
    0.31766603660087783, -0.3178111337447314, 0.31762454388917977, -0.3177696410330334,
    0.31758305117748165, -0.3177281483213353, 0.31754155846578364, -0.3176866556096371,
    0.3175000657540855, -0.31764516289793915, 0.3174585730423874, -0.31760367018624097,
    0.3174170803306894, -0.31756217747454296, 0.31737558761899115, -0.3175206847628449,
    0.31733409490729303, -0.31747919205114666, 0.31729260219559513, -0.18564083901293865,
    0.5368021674224979, -9.360713854778112e-05, -0.5369228314678002, 0.18546090360840786,
    -0.3173388932956659, 0.31715230344011425, -0.3172974005839679, 0.3171108107284162,
    -0.31725590787226965, 0.317069318016718, -0.3172144151605717, 0.3415677804845186,
    -0.29263296726937493, 0.39078235113590004,
  ]
}

///|
fn v116_oracle_nn_masspoint() -> Array[Double] {
  [
    -1.570137998181476, -1.1319599521773431, -0.474692883171144, -0.057735026918962755,
    0.2886751345948122, 0.9814954576223633, 0.4024922359499619, 0.7379024325749312,
    0.14433756729740668, 1.299038105676658,
  ]
}

//   h_eq_b.nn.bias_l     0.0353079885751747
//   h_eq_b.nn.bias_r     0.194209383689528
//   h_eq_b.nn.se_bc      0.1620182509134781
//   h_eq_b.nn.se_conv    0.1620182509134781
//   h_eq_b.nn.se_rb      0.2500639588200331
//   h_eq_b.nn.se_rb_from_V 0.2500639588200331
//   h_eq_b.nn.tau_bc     0.5275565264106074
//   h_eq_b.nn.tau_conv   0.6864579215249607
//   h_eq_b.nn.tau_rob    0.5275565264106074
//   h_eq_b.nn.xi_bc_l    0.09748073181851724
//   h_eq_b.nn.xi_bc_r    0.6250372582291246
//   h_eq_b.nn.xi_cl_l    0.13278872039369194
//   h_eq_b.nn.xi_cl_r    0.8192466419186526
//   h_ne_b.nn.bias_l     0.07660028868520008
//   h_ne_b.nn.bias_r     0.053826823401084134
//   h_ne_b.nn.se_bc      0.16200718188145724
//   h_ne_b.nn.se_conv    0.16200718188145724
//   h_ne_b.nn.se_rb      0.2027007785282574
//   h_ne_b.nn.se_rb_from_V 0.2027007785282574
//   h_ne_b.nn.tau_bc     0.7092313868090766
//   h_ne_b.nn.tau_conv   0.6864579215249607
//   h_ne_b.nn.tau_rob    0.7092313868090766
//   h_ne_b.nn.xi_bc_l    0.05618843170849186
//   h_ne_b.nn.xi_bc_r    0.7654198185175685
//   h_ne_b.nn.xi_cl_l    0.13278872039369194
//   h_ne_b.nn.xi_cl_r    0.8192466419186526
//   h_eq_b.hc0.bias_l     0.0353079885751747
//   h_eq_b.hc0.bias_r     0.194209383689528
//   h_eq_b.hc0.se_bc      0.16459523521248934
//   h_eq_b.hc0.se_conv    0.16459523521248934
//   h_eq_b.hc0.se_rb      0.23295178398182198
//   h_eq_b.hc0.se_rb_from_V 0.23295178398182198
//   h_eq_b.hc0.tau_bc     0.5275565264106074
//   h_eq_b.hc0.tau_conv   0.6864579215249607
//   h_eq_b.hc0.tau_rob    0.5275565264106074
//   h_eq_b.hc0.xi_bc_l    0.09748073181851724
//   h_eq_b.hc0.xi_bc_r    0.6250372582291246
//   h_eq_b.hc0.xi_cl_l    0.13278872039369194
//   h_eq_b.hc0.xi_cl_r    0.8192466419186526
//   h_ne_b.hc0.bias_l     0.07660028868520008
//   h_ne_b.hc0.bias_r     0.053826823401084134
//   h_ne_b.hc0.se_bc      0.16459523521248934
//   h_ne_b.hc0.se_conv    0.16459523521248934
//   h_ne_b.hc0.se_rb      0.20467879820096238
//   h_ne_b.hc0.se_rb_from_V 0.20467879820096238
//   h_ne_b.hc0.tau_bc     0.7092313868090766
//   h_ne_b.hc0.tau_conv   0.6864579215249607
//   h_ne_b.hc0.tau_rob    0.7092313868090766
//   h_ne_b.hc0.xi_bc_l    0.05618843170849186
//   h_ne_b.hc0.xi_bc_r    0.7654198185175685
//   h_ne_b.hc0.xi_cl_l    0.13278872039369194
//   h_ne_b.hc0.xi_cl_r    0.8192466419186526

// ---------------------------------------------------------------------------
// 0. The fixture really is shared
// ---------------------------------------------------------------------------

///|
/// Before any numeric claim: MoonBit and the oracle must be looking at the
/// SAME data. `coef()` goes through the port's own weighted-fit path, so
/// it is not bit-identical to the oracle's Cholesky solve -- measured gap
/// 1.0e-10 -- but a wrong DGP would move it by percent, not by 1e-10.
///
/// If this ever fails, every other gate in this file is measuring a
/// different fixture and its tolerance means nothing.
test "v116_the_oracle_and_this_port_see_the_same_data" {
  let data = v116_data()
  let est = DoubleMLRDD::new(data, bandwidth=0.30).fit()
  // oracle h_eq_b.nn.tau_conv
  assert_true(v116_rel(est.coef(), 0.6864579215249607) < 1.0e-9)
}

// ---------------------------------------------------------------------------
// 1. `nn_residual` -- the fit-free neighbour residual
// ---------------------------------------------------------------------------

///|
/// The headline primitive, checked BYTE FOR BYTE against
/// `_nn_residuals_jit` at four different `nnmatch` values on the real DGP
/// window. `==`, not a tolerance: this is a transliteration of a
/// transliteration and there is no room for "close enough" to hide a
/// mis-transcribed branch.
///
/// Four values rather than one, because `nnmatch` is what drives the
/// expansion loop and a single value only pins one exit from it.
test "v116_nn_residual_matches_the_oracle_byte_for_byte" {
  let (uu, yy) = v116_left_window()
  assert_eq(uu.length(), 50)
  v116_assert_exact(
    nn_residual(uu, yy, nnmatch=1),
    v116_oracle_nn_left_n1(),
    "nnmatch=1",
  )
  v116_assert_exact(
    nn_residual(uu, yy, nnmatch=2),
    v116_oracle_nn_left_n2(),
    "nnmatch=2",
  )
  v116_assert_exact(
    nn_residual(uu, yy, nnmatch=3),
    v116_oracle_nn_left_n3(),
    "nnmatch=3",
  )
  v116_assert_exact(
    nn_residual(uu, yy, nnmatch=5),
    v116_oracle_nn_left_n5(),
    "nnmatch=5",
  )
}

///|
/// The mass-point path, byte for byte. Separate from the DGP window
/// because the window has NO duplicated `x` at all -- without this, every
/// assertion above would be pinning the all-distinct branch and the
/// block-walking code would be untested.
test "v116_nn_residual_matches_the_oracle_on_mass_points" {
  v116_assert_exact(
    nn_residual(v116_masspoint_x(), v116_masspoint_y()),
    v116_oracle_nn_masspoint(),
    "masspoints",
  )
}

///|
/// The defining property of the nn residual: it is fit-free, so a
/// CONSTANT `y` has no residual anywhere. Every kernel there would give
/// zero for a linear `y` with symmetric neighbourhoods, but a constant
/// kills the scale factor too, and it is the cheapest way to catch a
/// `Ji` computed as 0 (which would divide by zero) or a neighbourhood
/// that never closes.
test "v116_nn_residual_vanishes_on_a_constant_outcome" {
  let xs = [0.1, 0.2, 0.4, 0.8, 1.6, 3.2]
  let ys = [2.5, 2.5, 2.5, 2.5, 2.5, 2.5]
  let r = nn_residual(xs, ys)
  for i = 0; i < r.length(); i = i + 1 {
    assert_eq(r[i], 0.0)
  }
}

///|
/// `cap = min(nnmatch, n - 1)`, so asking for more neighbours than exist
/// must not read out of bounds and must not divide by zero. Pinned on a
/// 3-element slice with `nnmatch = 10`; the oracle's `cap` line is the
/// thing under test.
test "v116_nn_residual_caps_the_neighbourhood_at_the_sample_size" {
  let xs = [0.1, 0.4, 0.9]
  let ys = [1.0, 2.0, 4.0]
  let r = nn_residual(xs, ys, nnmatch=10)
  assert_eq(r.length(), 3)
  for i = 0; i < r.length(); i = i + 1 {
    assert_true(r[i] == r[i])
  }
}

// ---------------------------------------------------------------------------
// 2. Procedure (iii) -- the variance
// ---------------------------------------------------------------------------

///|
/// The headline gate. `tau_bc_se_rb(vce = "nn")` against the upstream
/// `se.rb` at BOTH `b == h` and `b != h`.
///
/// The `b != h` case is the one that carries the information. At `b == h`
/// the union window collapses to `h` and a fault in the `max(h, b)`
/// handling, or in the `W_h` support mask, or in the `Ls` normalisation,
/// has a real chance of cancelling. At `b != h` all of those are live.
///
/// MEASURED gaps: 1.1e-14 (`b == h`), 4.0e-15 (`b != h`). The 1e-12
/// bound is two orders above the worst observed.
test "v116_robust_se_matches_the_oracle_at_both_bandwidth_relations" {
  let data = v116_data()
  let at_h = DoubleMLRDD::new(data, bandwidth=0.30).fit()
  // oracle h_eq_b.nn.se_rb
  assert_true(
    v116_rel(at_h.tau_bc_se_rb(b=0.30, vce="nn"), 0.2500639588200331) < 1.0e-12,
  )
  let apart = DoubleMLRDD::new(data, bandwidth=0.30).fit()
  // oracle h_ne_b.nn.se_rb
  assert_true(
    v116_rel(apart.tau_bc_se_rb(b=0.42, vce="nn"), 0.2027007785282574) < 1.0e-12,
  )
}

///|
/// The same `Q`, the same bread, the same window -- only the residual
/// changes to the q-order plug-in residual. It is here as a CONTROL for
/// the gate above: a fault in `Q`, `m`, `Ls` or `invG_p` has to reproduce
/// itself identically in both to survive, which is a much stronger
/// requirement than surviving one of them.
///
/// MEASURED gaps: 4.4e-15 (`b == h`), 8.3e-16 (`b != h`).
test "v116_hc0_se_matches_the_oracle_at_both_bandwidth_relations" {
  let data = v116_data()
  let at_h = DoubleMLRDD::new(data, bandwidth=0.30).fit()
  assert_true(
    v116_rel(at_h.tau_bc_se_rb(b=0.30, vce="hc0"), 0.232951783981822) < 1.0e-12,
  )
  let apart = DoubleMLRDD::new(data, bandwidth=0.30).fit()
  assert_true(
    v116_rel(apart.tau_bc_se_rb(b=0.42, vce="hc0"), 0.2046787982009624) <
    1.0e-12,
  )
}

///|
/// The two residuals must give two DIFFERENT variances. If a mutation
/// routed the `vce` string nowhere, both branches would return the same
/// number and the two oracle gates above would both still be within
/// tolerance of... no, they would not: each is pinned to a different
/// constant. But this says so directly, and it is the property that
/// makes `vce` a parameter rather than a constant.
test "v116_the_two_vce_estimators_are_different_numbers" {
  let data = v116_data()
  let est = DoubleMLRDD::new(data, bandwidth=0.30).fit()
  let nn = est.tau_bc_se_rb(b=0.30, vce="nn")
  let hc0 = est.tau_bc_se_rb(b=0.30, vce="hc0")
  assert_true(nn != hc0)
  // and the gap is not a rounding-level one: measured 7.3% at b == h
  assert_true((nn - hc0).abs() / nn > 0.05)
}

///|
/// The empirical signature of CCT, and the reason procedure (iii) exists
/// at all: correcting the bias costs VARIANCE. The oracle reports
/// `se_conv = 0.16202` against `se_rb = 0.25006` -- a factor of 1.54.
///
/// Without this, a "robust" variance that came out SMALLER than the
/// conventional one would sail through both oracle gates if the fixture
/// happened to put the two within 1e-12 of each other, and the whole
/// point of the estimator -- that the extra spread is what buys nominal
/// coverage -- would be untested.
test "v116_the_robust_se_exceeds_the_conventional_se" {
  let data = v116_data()
  let est = DoubleMLRDD::new(data, bandwidth=0.30).fit()
  let rb = est.tau_bc_se_rb(b=0.30, vce="nn")
  // (a) Against the ORACLE's own conventional standard error under
  // `vce = "nn"` (0.16202): a factor of 1.54. This is the comparison that
  // carries the CCT signature, because both numbers come from the same
  // estimator family.
  //
  // NOTE the port's `se()` is NOT that number -- it is the homoskedastic
  // convention and measures 0.0229 here. Comparing `rb` against `se()`
  // alone would therefore be comparing against a different estimator's
  // variance, not a stricter version of the same one. Both are checked
  // below, and the labels say which is which.
  assert_true(rb / 0.1620182509134781 > 1.5)
  assert_true(rb / 0.1620182509134781 < 1.6)
  // (b) Against the port's own conventional `se()`.
  let conv = est.se()
  assert_true(rb > conv)
  assert_true(rb != conv)
}

///|
/// `nnmatch` has to reach the variance. If it were accepted and ignored,
/// every other gate here would still pass, because they all use the
/// default.
///
/// MEASURED: 0.31886 (1), 0.32513 (2), 0.25006 (3), 0.26083 (5).
test "v116_nnmatch_reaches_the_robust_variance" {
  let data = v116_data()
  let est = DoubleMLRDD::new(data, bandwidth=0.30).fit()
  let s1 = est.tau_bc_se_rb(b=0.30, vce="nn", nnmatch=1)
  let s2 = est.tau_bc_se_rb(b=0.30, vce="nn", nnmatch=2)
  let s3 = est.tau_bc_se_rb(b=0.30, vce="nn", nnmatch=3)
  let s5 = est.tau_bc_se_rb(b=0.30, vce="nn", nnmatch=5)
  assert_true(s1 != s3)
  assert_true(s2 != s3)
  assert_true(s5 != s3)
  assert_true(s1 != s2)
}

// ---------------------------------------------------------------------------
// 3. The v0.115.0 defect the oracle found
// ---------------------------------------------------------------------------

///|
/// The gate that v0.115.0 needed and did not have.
///
/// v0.115.0 defined `bias = xi_p(h) - xi_q(b)` and `tau_bc = tau_cl -
/// (bias_r - bias_l)`, which telescopes algebraically to
/// `xi_q(b)_r - xi_q(b)_l` -- the port's own order-`q` fit. Upstream's
/// bias-corrected limit is a DIFFERENT quantity, and they agree only at
/// `b == h`.
///
/// At `h = 0.30`, `b = 0.42` upstream reports 0.7092313868090766 and
/// v0.115.0 returned 0.6910832334. MEASURED gap after the fix: 2.3e-15.
test "v116_tau_bc_matches_the_oracle_at_a_separate_bias_bandwidth" {
  let data = v116_data()
  let est = DoubleMLRDD::new(data, bandwidth=0.30).fit()
  // oracle h_ne_b.nn.tau_bc
  assert_true(v116_rel(est.tau_bc(b=0.42), 0.7092313868090766) < 1.0e-12)
  // and NOT the collapsed order-q form v0.115.0 shipped
  let collapsed = est.tau_bc_collapsed(b=0.42)
  assert_true(v116_rel(collapsed, 0.6910832333519114) < 1.0e-9)
  assert_true(est.tau_bc(b=0.42) != collapsed)
  assert_true(v116_rel(est.tau_bc(b=0.42), collapsed) > 0.01)
}

///|
/// The same gate on the `b == h` side: v0.116.0 must NOT have broken the
/// default path. Measured gap against the oracle: 5.3e-15.
test "v116_tau_bc_matches_the_oracle_when_b_equals_h" {
  let data = v116_data()
  let est = DoubleMLRDD::new(data, bandwidth=0.30).fit()
  // oracle h_eq_b.nn.tau_bc
  assert_true(v116_rel(est.tau_bc(b=0.30), 0.5275565264106074) < 1.0e-12)
}

///|
/// The per-side bias, against the oracle. LOOSE at 1e-7 relative because
/// this expression runs `xi_p(h)` through `rdd_limit` -> `fit_weighted`,
/// which solves a different normal-equation system than `rdd_rb_side`
/// does; measured gap 2.8e-9.
///
/// `tau_bc` itself is not in that situation -- it differences the two
/// `xi_bc` values and never touches `rdd_limit` -- which is why the two
/// gates above are three orders tighter.
test "v116_bias_matches_the_oracle" {
  let data = v116_data()
  let est = DoubleMLRDD::new(data, bandwidth=0.30).fit()
  let (bias_l, bias_r) = est.bias(b=0.42)
  // oracle h_ne_b.nn.bias_l / bias_r
  assert_true(v116_rel(bias_l, 0.07660028868520008) < 1.0e-7)
  assert_true(v116_rel(bias_r, 0.053826823401084134) < 1.0e-7)
  // and it stays two-sided and asymmetric, which is what makes it a bias
  assert_true(bias_l != bias_r)
}

///|
/// The structural statement behind the fix: `tau_bc` and
/// `tau_bc_collapsed` are the same number at `b == h` and different
/// numbers otherwise. Asserting only the first half lets the v0.115.0
/// bug back in; asserting only the second does not say where the boundary
/// is.
///
/// MEASURED at `b == h`: 6.7e-8 relative. That gap is `xi_q(b)`'s, not
/// `tau_bc`'s -- it is the difference between the port's
/// `rdd_limit`/`fit_weighted` Vandermonde solve and `rdd_rb_side`'s
/// Kahan-compensated Cholesky, both fitting the same `[1, u, u^2]`.
test "v116_tau_bc_equals_the_collapsed_form_only_when_b_equals_h" {
  let data = v116_data()
  let est = DoubleMLRDD::new(data, bandwidth=0.30).fit()
  let at_h = est.tau_bc(b=0.30)
  let collapsed_at_h = est.tau_bc_collapsed(b=0.30)
  assert_true(v116_rel(at_h, collapsed_at_h) < 1.0e-6)
  let apart = est.tau_bc(b=0.42)
  assert_true(v116_rel(apart, est.tau_bc_collapsed(b=0.42)) > 0.01)
}

// ---------------------------------------------------------------------------
// 4. Guards
// ---------------------------------------------------------------------------

///|
/// `rho` has to reach the new variance: `b = h / rho` is the whole reason
/// `rho` exists, and the `b != h` oracle gate above pins `b` explicitly
/// rather than through `rho`.
test "v116_rho_reaches_the_robust_variance" {
  let data = v116_data()
  let est = DoubleMLRDD::new(data, bandwidth=0.30).fit()
  let at_1 = est.tau_bc_se_rb(b=0.0, rho=1.0, vce="nn")
  let at_2 = est.tau_bc_se_rb(b=0.0, rho=2.0, vce="nn")
  assert_true(at_1 != at_2)
  // rho = 2 means b = h/2 = 0.15, which is the h == 0.30, b == 0.15 case
  let explicit = est.tau_bc_se_rb(b=0.15, vce="nn")
  assert_true(at_2 == explicit)
}

///|
/// An unrecognised `vce` aborts with the accepted set rather than falling
/// back to one of them. A silent fallback here would mean a typo in a
/// config file produced a plausible standard error under an estimator the
/// caller did not ask for -- the same reasoning `RDDKernel::parse` gives.
///
/// The `panic_` prefix is what tells `moon test` the abort is expected.
test "panic_v116_unknown_vce_aborts_with_the_accepted_set" {
  let data = v116_data()
  let est = DoubleMLRDD::new(data, bandwidth=0.30).fit()
  // Upper case on purpose: `"HC0"` is not `"hc0"`, and a case-insensitive
  // fallback is the thing being ruled out.
  let _ = est.tau_bc_se_rb(b=0.30, vce="HC0")
  inspect(false, content="unreachable: vce=\"HC0\" must abort")
}
