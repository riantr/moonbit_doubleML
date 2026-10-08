// Demo entry point: `DoubleMLAPO`, the ATE AT ONE treatment level.
//
// # Why this example exists
//
// `examples/apos/` already demos `DoubleMLAPOS`. APO is the estimator
// UNDERNEATH it -- `DoubleMLAPOS` builds one `DoubleMLAPO` child per
// treatment level -- and the two answer different questions:
//
//   APO(t)  -> E[Y(t)]         the potential outcome AT level t
//   APOS    -> E[Y(t)] per level, PLUS pairwise CONTRASTS between them
//
// The number people most often want and cannot get from a contrast is the
// first one. A contrast is a DIFFERENCE: `E[Y(2)] - E[Y(1)]`. If you
// need "what happens to the average outcome at level 2", that is
// `E[Y(2)]`, and a contrast against another level is not a substitute for
// it -- it is off by that other level's whole potential outcome.
//
// This DGP makes the gap impossible to miss. Levels 1 and 2 have effects
// of 1.0 and 2.5, so:
//
//   E[Y(1)]      = 1.0        <- APO(1)
//   E[Y(2)]      = 2.5        <- APO(2)     <- the level
//   contrast 2-1 = 1.5        <- APOS       <- the difference
//
// and 2.5 != 1.5. Both are printed below so the difference is visible
// rather than asserted in a comment.
//
// # The DGP
//
//   X      ~ N(0, I_3)
//   D      in {0, 1, 2}, P(D=1) = 1/3 + 0.15*tanh(X0)   (confounded)
//                     P(D=2) = 1/3 - 0.15*tanh(X0)
//   Y      = 0.4 * X0 + 0.3 * X1
//            + 1.0 * 1{D == 1} + 2.5 * 1{D == 2} + eps,  eps ~ N(0, 1)
//
// `D` depends on `X0` and `Y` depends on `X0`, so a naive treated-minus-
// control comparison is CONFOUNDED here and lands visibly away from
// 1.0 / 2.5. That is the point of running DML rather than arithmetic: the
// estimator has to earn these numbers, and the naive means are printed
// first so there is something to be better than.
//
// Since `E[X] = 0`, the baseline contributes nothing to the mean, so the
// ground truth is exactly the two treatment effects. The nuisance `g` is
// fit on the treated subset only and `m` on the full fold (the upstream
// asymmetry), which is what lets a partially-treated level be identified
// without observing anyone at it.
//
// # `propensity_clip` IS PART OF THE LESSON
//
// The default is `1e-6`, and this example passes `0.01` explicitly. That
// is not cosmetic, and the reason is worth reading.
//
// The TRUE propensity here is bounded in `(0.18, 0.48)` -- there is no
// near-zero-propensity region in the DGP at all. But `ml_m` defaults to
// `LinearRegression`, and a linear fit to a `tanh` propensity EXTRAPOLATES
// past zero in the tails of `X0`. Measured on this same DGP at `n = 800`,
// the fitted propensity hit the `1e-6` floor on 14 of 800 rows, and the
// AIPW term `treated * (y - g) / m` turned those into ~1e6-scaled
// contributions. A handful of rows then dominate the mean: `APO(1)`
// returned **-2662** with `se = 2661` -- an error of one standard error,
// technically, and a completely useless number.
//
// Clipping at `0.01` bounds that term, and the same fit returns 1.02.
// The general lesson is the one the literature draws from trimming: an
// AIPW estimate is only as stable as the SMALLEST denominator it is
// allowed to use, and the clip is the only thing standing between a
// misspecified nuisance model and a meaningless coefficient. If you switch
// `ml_m` to something that cannot extrapolate, you have less to worry
// about; with the default linear learner, set the clip yourself.
//
// The example also prints the fitted propensity's range via
// `predictions_m()`, because that range is the diagnostic you want when a
// DML estimate looks wrong.

///|
fn main {
  let n = 2000
  let p = 3
  let tau1 = 1.0
  let tau2 = 2.5
  let rng = @moonbit_doubleML.chacha8_rng(2718)

  // ---- Build X (n, p) via CLT on chacha8 uniforms ----
  // 12 uniforms sum to variance 12/12 = 1, so this is N(0, 1) to the
  // accuracy of the CLT -- the same construction every sibling example
  // uses, so the numbers are comparable across the examples directory.
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  for k = 0; k < n * p; k = k + 1 {
    let mut acc = 0.0
    for _j = 0; _j < 12; _j = _j + 1 {
      acc = acc + rng.double()
    }
    x_flat[k] = acc - 6.0
  }
  let x = @moonbit_doubleML.Matrix::from_array(x_flat, n, p)

  // ---- Build D in {0, 1, 2}, confounding through X[:, 0] ----
  // p1 and p2 move in opposite directions with X0, so the marginal
  // treatment probabilities stay well inside (0.15, 0.50) and every level
  // keeps plenty of observations.
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let x0 = x_flat[i * p]
    let shift = 0.15 * @math.tanh(x0)
    let p1 = 1.0 / 3.0 + shift
    let p2 = 1.0 / 3.0 - shift
    let u = rng.double()
    if u < p1 {
      d[i] = 1.0
    } else if u < p1 + p2 {
      d[i] = 2.0
    } else {
      d[i] = 0.0
    }
  }

  // ---- Build Y ----
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let x0 = x_flat[i * p]
    let x1 = x_flat[i * p + 1]
    let mut acc = 0.0
    for _j = 0; _j < 12; _j = _j + 1 {
      acc = acc + rng.double()
    }
    let eps = acc - 6.0
    y[i] = 0.4 * x0 +
      0.3 * x1 +
      tau1 * (if d[i] == 1.0 { 1.0 } else { 0.0 }) +
      tau2 * (if d[i] == 2.0 { 1.0 } else { 0.0 }) +
      eps
  }

  let data = @moonbit_doubleML.DoubleMLData::new(x, y, d)

  // ---- The naive comparison this DGP punishes ----
  // Printed first so the DML numbers below have something to be better
  // than. With D confounded through X0 both of these are biased.
  let mut sum_d1 = 0.0
  let mut c1 = 0
  let mut sum_d2 = 0.0
  let mut c2 = 0
  let mut sum_d0 = 0.0
  let mut c0 = 0
  for i = 0; i < n; i = i + 1 {
    if d[i] == 1.0 {
      sum_d1 = sum_d1 + y[i]
      c1 = c1 + 1
    } else if d[i] == 2.0 {
      sum_d2 = sum_d2 + y[i]
      c2 = c2 + 1
    } else {
      sum_d0 = sum_d0 + y[i]
      c0 = c0 + 1
    }
  }
  let m1 = sum_d1 / c1.to_double()
  let m2 = sum_d2 / c2.to_double()
  let m0 = sum_d0 / c0.to_double()
  println("=== Naive subgroup means (confounded through X0) ===")
  println(
    "mean Y | D=1 = " +
    m1.to_string() +
    "   (true E[Y(1)] = " +
    tau1.to_string() +
    ")",
  )
  println(
    "mean Y | D=2 = " +
    m2.to_string() +
    "   (true E[Y(2)] = " +
    tau2.to_string() +
    ")",
  )
  println("mean Y | D=0 = " + m0.to_string())
  println(
    "naive 2 minus 1 = " +
    (m2 - m1).to_string() +
    "   (true contrast = " +
    (tau2 - tau1).to_string() +
    ")",
  )

  // ---- APO: the level, one fit each ----
  println("")
  println("=== MoonBit DML APO (the level itself) ===")
  let apo1 = @moonbit_doubleML.DoubleMLAPO::new(
    data,
    treatment_level=1.0,
    n_folds=2,
    n_rep=2,
    seed=5771,
    propensity_clip=0.01,
  ).fit()
  let apo2 = @moonbit_doubleML.DoubleMLAPO::new(
    data,
    treatment_level=2.0,
    n_folds=2,
    n_rep=2,
    seed=5771,
    propensity_clip=0.01,
  ).fit()
  println(
    "  APO(1): coef=" +
    apo1.coef().to_string() +
    ", se=" +
    apo1.se().to_string() +
    ", err=" +
    (apo1.coef() - tau1).to_string(),
  )
  println(
    "  APO(2): coef=" +
    apo2.coef().to_string() +
    ", se=" +
    apo2.se().to_string() +
    ", err=" +
    (apo2.coef() - tau2).to_string(),
  )

  // ---- The propensity diagnostic ----
  // The diagnostic to look at when a DML estimate looks wrong. These are
  // the cross-fitted `m` values, i.e. what actually divided the AIPW
  // term; the true propensity is in (0.18, 0.48) by construction, so a
  // fitted minimum sitting AT the clip means the linear nuisance model
  // extrapolated off the end of its support.
  println("")
  println("=== Cross-fitted propensity range (the stability diagnostic) ===")
  for pair in [[1.0, apo1.coef()], [2.0, apo2.coef()]] {
    let mhat = if pair[0] == 1.0 {
      apo1.predictions_m()
    } else {
      apo2.predictions_m()
    }
    let mut lo = 1.0e18
    let mut hi = -1.0e18
    let mut at_clip = 0
    for i = 0; i < n; i = i + 1 {
      let v = mhat[i]
      if v < lo {
        lo = v
      }
      if v > hi {
        hi = v
      }
      if v <= 0.01 {
        at_clip = at_clip + 1
      }
    }
    println(
      "  level " +
      pair[0].to_string() +
      ": m in [" +
      lo.to_string() +
      ", " +
      hi.to_string() +
      "], rows at the clip = " +
      at_clip.to_string(),
    )
  }

  // ---- APOS: the same levels, built from APO children, plus contrasts ----
  println("")
  println("=== MoonBit DML APOS (levels + contrasts) ===")
  let apos = @moonbit_doubleML.DoubleMLAPOS::new(
    data,
    [1.0, 2.0],
    n_folds=2,
    n_rep=1,
    seed=3141,
  ).fit()
  let coefs = apos.coefs()
  let ses = apos.ses()
  println(
    "  level 1.0: coef=" + coefs[0].to_string() + ", se=" + ses[0].to_string(),
  )
  println(
    "  level 2.0: coef=" + coefs[1].to_string() + ", se=" + ses[1].to_string(),
  )

  // ---- The point of the example ----
  // `causal_contrast([1.0])` returns, per reference level, a slot layout
  // of `[0.0, delta, se, delta, se, ...]` -- the reference slot is a bare
  // 0.0 because its contrast with itself is trivially zero.
  let contrasts = apos.causal_contrast([1.0])
  let delta_2_vs_1 = contrasts[0][1]
  let se_2_vs_1 = contrasts[0][2]
  println(
    "  contrast (2 - 1): delta=" +
    delta_2_vs_1.to_string() +
    ", se=" +
    se_2_vs_1.to_string(),
  )
  println("")
  println("=== The difference that matters ===")
  println(
    "  E[Y(2)]      = " + tau2.to_string() + "   <- the LEVEL (what APO gives)",
  )
  println(
    "  contrast 2-1 = " +
    (tau2 - tau1).to_string() +
    "   <- the DIFFERENCE (what APOS gives)",
  )
  println(
    "  gap          = " +
    (tau2 - (tau2 - tau1)).to_string() +
    "   <- exactly level 1's own effect",
  )
  println(
    "  Reading the contrast as 'the effect of level 2' would be wrong by that gap.",
  )

  // ---- Inference on the APO coefficient ----
  // `se()` is the estimator's own influence-function SE, which conditions
  // on the fitted nuisances and therefore UNDERSTATES total uncertainty;
  // the MC noise from cross-fitting is not in it. `sandwich_se(HC0)`
  // rebuilds the same variance from `psi_a` / `psi_b` by a second, shared
  // code path (`sandwich.mbt`), so the two agreeing is a real cross-check
  // rather than a tautology. HC1..HC3 add the usual finite-sample
  // corrections and are printed to show the monotone widening.
  println("")
  println("=== Inference on APO(2) ===")
  let (lo, hi) = apo2.confint()
  println("  95% CI = [" + lo.to_string() + ", " + hi.to_string() + "]")
  println(
    "  t = " +
    (apo2.coef() / apo2.se()).to_string() +
    "   se=" +
    apo2.se().to_string(),
  )
  let hc0 = apo2.sandwich_se(@moonbit_doubleML.SandwichKind::hc0())
  println(
    "  sandwich_se(HC0) = " +
    hc0.to_string() +
    "  (matches se(): " +
    (if (hc0 - apo2.se()).abs() <= 1.0e-9 * apo2.se().abs() {
      "yes"
    } else {
      "NO"
    }) +
    ")",
  )
  println(
    "  sandwich_se(HC1) = " +
    apo2.sandwich_se(@moonbit_doubleML.SandwichKind::hc1()).to_string() +
    ",  HC2 = " +
    apo2.sandwich_se(@moonbit_doubleML.SandwichKind::hc2()).to_string() +
    ",  HC3 = " +
    apo2.sandwich_se(@moonbit_doubleML.SandwichKind::hc3()).to_string(),
  )
  println("  bias_corrected_coef = " + apo2.bias_corrected_coef().to_string())
}
