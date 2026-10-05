///|
pub struct DoubleMLLPQData {
  x : Matrix
  y : Array[Double]
  d : Array[Double]
  z : Array[Double]
} derive(Debug)

///|
pub extend DoubleMLLPQData with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLLPQData::new(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  z : Array[Double],
) -> DoubleMLLPQData {
  try {
    require(x.rows() == y.length())
    require(x.rows() == d.length())
    require(x.rows() == z.length())
    { x, y, d, z, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Compute the LPQ score. Bug #4 fix: the upstream `doubleml.irm.lpq`
/// reference uses `sign = 2 * treatment - 1` to flip the score sign
/// depending on which treatment level is the "treated" level (so that
/// the bisection can find a `theta` that brackets the complier
/// quantile regardless of which level is being scored).
fn lpq_score(
  data : DoubleMLLPQData,
  treated : Array[Double],
  m : Array[Double],
  g0 : Array[Double],
  g1 : Array[Double],
  comp : Double,
  theta : Double,
  q : Double,
  sign : Double,
) -> Array[Double] {
  let out = Array::make(data.y.length(), 0.0)
  for i = 0; i < out.length(); i = i + 1 {
    let iy = if data.y[i] <= theta { 1.0 } else { 0.0 }
    let a = g1[i] -
      g0[i] +
      data.z[i] / m[i] * (treated[i] * iy - g1[i]) -
      (1.0 - data.z[i]) / (1.0 - m[i]) * (treated[i] * iy - g0[i])
    out[i] = sign * a / comp - q
  }
  out
}

///|
/// IPW-only LPQ score (no g0/g1 cross-fit). Used as the bisection
/// objective in `DoubleMLLPQ::fit` (Bug #3 fix). Matches the
/// upstream `doubleml.irm.lpq.DoubleMLLPQ._compute_ipw_score`:
///   `score[i] = sign * (z[i] / m[i] - (1 - z[i]) / (1 - m[i]))
///               * treated[i] * (y[i] <= theta ? 1 : 0) / comp - q`
/// The bisection does not need g0/g1, so this avoids the
/// `2 * 50 = 100` g cross-fits that the pre-fix code did.
pub fn lpq_score_ipw(
  data : DoubleMLLPQData,
  treated : Array[Double],
  m : Array[Double],
  comp : Double,
  theta : Double,
  q : Double,
  sign : Double,
) -> Array[Double] {
  let out = Array::make(data.y.length(), 0.0)
  for i = 0; i < out.length(); i = i + 1 {
    let iy = if data.y[i] <= theta { 1.0 } else { 0.0 }
    let w = sign *
      (data.z[i] / m[i] - (1.0 - data.z[i]) / (1.0 - m[i])) *
      treated[i] *
      iy /
      comp -
      q
    out[i] = w
  }
  out
}

///|
pub struct DoubleMLLPQ {
  data : DoubleMLLPQData
  treatment : Double
  quantile : Double
  n_folds : Int
  seed : Int
  propensity_clip : Double
  coef : Double
  se : Double
  fitted : Bool
  // Cross-fitted nuisance predictions stored post-fit. Length
  // `n_obs`. v0.53.0-dev Task 2: predictions() accessors mirror
  // the upstream DoubleMLLPQ `predictions["g0"/"g1"/"m"]` API.
  predictions_g0 : Array[Double]
  predictions_g1 : Array[Double]
  predictions_m : Array[Double]
  // v0.64.0+: per-observation influence function at the fitted
  // `coef`. Already centered (mean 0 at the bisection root);
  // `sqrt(mean(psi^2))` is the multiplier-bootstrap denominator.
  // Persisted for `bootstrap(...)`.
  psi : Array[Double]
  // v0.93.0+: the IPW quantile score's theta-derivative at `coef`,
  // i.e. `d/dtheta mean(psi_ipw) ~= f_theta / n`. Persisted because
  // the sandwich variance needs it as the Jacobian (`M_inv = 1/deriv`)
  // and it cannot be recovered after `fit()` returns. Length `n_obs`,
  // every entry equal to the same scalar -- the derivative of a MEAN
  // is a scalar, so a per-observation array here is a uniform-API
  // convenience, not a claim of per-observation variation.
  psi_a : Array[Double]
  // v0.64.0+: multiplier bootstrap state. `boot_t_stat` is a
  // length-`n_rep_boot` array of t-statistics for `coef`.
  // Populated by `bootstrap(...)`; empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
  // v0.82.0+: memoization state. LPQ does not use multi-rep
  // (n_rep is implicit 1) -- the cross-fit is a single-pass
  // bisection over the IPW-QTE score. Mirrors the IRM /
  // PLR plumbing.
  memoize_enabled : Bool
  fit_cache : FitCache
} derive(Debug)

///|
pub extend DoubleMLLPQ with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLLPQ::new(
  data : DoubleMLLPQData,
  treatment? : Double = 1.0,
  quantile? : Double = 0.5,
  n_folds? : Int = 2,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
) -> DoubleMLLPQ {
  try {
    require(n_folds >= 2)
    require(seed >= 0)
    require(quantile > 0.0 && quantile < 1.0)
    require(propensity_clip > 0.0)
    {
      data,
      treatment,
      quantile,
      n_folds,
      seed,
      propensity_clip,
      coef: 0.0,
      se: 0.0,
      fitted: false,
      predictions_g0: Array::make(data.y.length(), 0.0),
      predictions_g1: Array::make(data.y.length(), 0.0),
      predictions_m: Array::make(data.y.length(), 0.0),
      psi: Array::make(data.y.length(), 0.0),
      psi_a: Array::make(data.y.length(), 0.0),
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      // v0.82.0+: default memoize off so v0.81.0 callers see
      // byte-identical fit() output.
      memoize_enabled: false,
      fit_cache: FitCache::empty(),
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLLPQ::fit(self : DoubleMLLPQ) -> DoubleMLLPQ {
  try {
    let n = self.data.y.length()
    require(n >= self.n_folds) // kfold precondition: `n_folds <= n_obs`
    let nf = n.to_double()
    // v0.82.0+: memoize check. LPQ has implicit `n_rep = 1`
    // and a single-pass bisection + cross-fit. The cache
    // stores the LAST (only) repetition's g0, g1, m, fold_ids.
    let memoize = self.memoize_enabled
    let data_hash : UInt64 = if memoize {
      // DoubleMLLPQData does not carry cluster_vars (v0.82.0);
      // pass an empty vector.
      hash_data(self.data.x, self.data.y, self.data.d, z=self.data.z, cluster_vars=[])
    } else {
      0UL
    }
    let hparams_hash : UInt64 = if memoize {
      hash_hyperparams(
        "lpq",
        LearnerDispatch::linear_regression(),
        LearnerDispatch::linear_regression(),
        self.propensity_clip,
      )
    } else {
      0UL
    }
    let cluster_hash : UInt64 = if memoize { hash_cluster_ids([]) } else { 0UL }
    let cache_hit = memoize &&
      self.fit_cache.is_valid(
        self.seed,
        self.n_folds,
        1,
        n,
        data_hash,
        hparams_hash,
        cluster_hash,
        "lpq",
      )
    let tr = indicator_level(self.data.d, self.treatment)
    let folds = kfold(n, self.n_folds, self.seed)
    // v0.82.0+: if memoize is on and the cache is valid, the
    // fold_ids, g0, g1, m are all reusable.
    let mut fold_ids : Array[Int] = []
    if cache_hit {
      fold_ids = self.fit_cache.fold_ids
    } else {
      // Build the row -> fold_id map for the cache write below.
      let fid : Array[Int] = Array::make(n, 0)
      for f = 0; f < folds.length(); f = f + 1 {
        for i in folds[f].test_indices() {
          fid[i] = f
        }
      }
      fold_ids = fid
    }
    let m = if cache_hit {
      self.fit_cache.predictions[2]
    } else {
      fit_propensity(
        LearnerDispatch::linear_regression(),
        self.data.x,
        self.data.z,
        folds,
        self.propensity_clip,
      )
    }
    let z0 = Array::make(n, 0.0)
    let z1 = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      z0[i] = if self.data.z[i] == 0.0 { 1.0 } else { 0.0 }
      z1[i] = self.data.z[i]
    }
    // Bug #4 fix: complier prob is the full-sample
    // `E[D | Z=1] - E[D | Z=0]`, NOT the per-fold mean difference
    // averaged over folds (which dilutes the estimate). The upstream
    // `doubleml.irm.lpq.LPQScore` uses the full-sample
    // `comp_prob = E[D | Z=1] - E[D | Z=0]` once, irrespective of the
    // cross-fit partition.
    let idz1 = filter_indices(range_indices(n), z1)
    let idz0 = filter_indices(range_indices(n), z0)
    let mut comp = 0.0
    if idz1.length() > 0 && idz0.length() > 0 {
      let r1 = mean(slice_vector(self.data.d, idz1))
      let r0 = mean(slice_vector(self.data.d, idz0))
      comp = r1 - r0
    }
    if comp.abs() < self.propensity_clip {
      comp = self.propensity_clip
    }
    // `sign = 2 * treatment - 1` flips the score sign so that the
    // bisection brackets the complier quantile regardless of which
    // treatment level is being scored. Bug #4 fix: previously missing.
    let sign = 2.0 * self.treatment - 1.0
    // Bug #3 fix: use the IPW score for the bisection, then
    // cross-fit g0, g1 ONCE at the preliminary theta (plus
    // 4 more cross-fits for the numerical derivative). This
    // drops the total g cross-fit count from `2 * 50 = 100`
    // (bisection) + 4 (derivative) = 104 to 2 + 4 = 6.
    let y_min = array_min(self.data.y) catch {
      EmptyArrayError =>
        abort("array_min: empty y array (data.y.length() == 0)")
    }
    let y_max = array_max(self.data.y) catch {
      EmptyArrayError =>
        abort("array_max: empty y array (data.y.length() == 0)")
    }
    let y_range = y_max - y_min
    let margin = if y_range > 0.0 { y_range * 0.1 } else { 1.0 }
    let mut lo = y_min - margin
    let mut hi = y_max + margin
    for _iter = 0; _iter < 60; _iter = _iter + 1 {
      let mid = (lo + hi) / 2.0
      let s = mean(
        lpq_score_ipw(self.data, tr, m, comp, mid, self.quantile, sign),
      )
      if s < 0.0 {
        lo = mid
      } else {
        hi = mid
      }
    }
    let theta = (lo + hi) / 2.0
    // Cross-fit g0, g1 ONCE at theta (replaces the per-iteration
    // g cross-fit from the pre-fix code). v0.62.0+:
    // `cross_fit_conditional` takes a `LearnerDispatch` first
    // arg. LPQ has no learner injection, so use the OLS
    // default for byte-equality with v0.61.0.
    // v0.82.0+: when the cache is valid, reuse the cached g0 /
    // g1 directly (the bisection-derived `theta` is part of the
    // hyperparam fingerprint; a `theta` change invalidates the
    // cache).
    let iy = outcome_indicator(self.data.y, theta)
    let (g0, g1) = if cache_hit {
      (self.fit_cache.predictions[0], self.fit_cache.predictions[1])
    } else {
      let g0_fresh = cross_fit_conditional(
        LearnerDispatch::linear_regression(),
        self.data.x,
        iy,
        z0,
        folds,
      )
      let g1_fresh = cross_fit_conditional(
        LearnerDispatch::linear_regression(),
        self.data.x,
        iy,
        z1,
        folds,
      )
      (g0_fresh, g1_fresh)
    }
    let psi = lpq_score(
      self.data,
      tr,
      m,
      g0,
      g1,
      comp,
      theta,
      self.quantile,
      sign,
    )
    // Numerical derivative via KDE-weighted evaluation at `theta`.
    // TODO 0.6.0: replace the finite-difference `2 * n_folds = 4` extra
    // cross-fits with a single weighted-KDE evaluation of the IPW
    // coefficient at `theta`. The IPW score's `theta`-derivative is
    //   `d/dtheta mean(psi_ipw) = (1/n) * sum_i w_i * delta(y_i - theta)`
    // which we smooth by replacing the Dirac with a Gaussian KDE
    // `K_h((theta - y_i) / h) / h`. The Silverman bandwidth is
    // sample-size-aware so the KDE is consistent at the canonical DGP
    // scale (continuous `y`) and does not collapse to zero at discrete
    // `y` like the previous finite-difference did.
    //
    // Bandwidth selection: Silverman's rule on `y` directly (rather than
    // the previous `min(1% y_range, 1/sqrt(n))` heuristic). For the
    // canonical DGPs the new bandwidth is comparable to the old heuristic
    // (typically a few percent of `y_range`); for discrete `y` it
    // adapts to the local cell width automatically.
    let w_kde : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      let z_i = self.data.z[i]
      let m_i = m[i]
      let comp_safe = if comp.abs() < 1.0e-12 { 1.0e-12 } else { comp }
      w_kde[i] = sign *
        (z_i / m_i - (1.0 - z_i) / (1.0 - m_i)) *
        tr[i] /
        comp_safe
    }
    let h_kde = silverman_bandwidth(self.data.y)
    let f_theta = gaussian_kde_weighted(self.data.y, w_kde, theta, h_kde)
    // v0.93.0: the Jacobian `deriv = d/dtheta mean(psi_ipw)`, which
    // `gaussian_kde_weighted` evaluates as `f_theta / n` (the `1/n`
    // turns the weighted-KDE mass into the derivative of a MEAN).
    //
    // The v0.7.0 - v0.92.x comment above this line claimed the IPW
    // score's `psi_a` is "the constant -1" and that therefore only
    // the `psi_b` part contributes to the derivative. That was false
    // about the code next to it, and reading it literally is the trap
    // this release exists to close: it invites building the sandwich
    // with `psi_a = -1` / `M_inv = [[1 / mean(psi_a)]] == [[-1]]`.
    // LPQ is NOT a member of the package-wide family
    // `f(theta) = E[theta * psi_a + psi_b]`. Its estimating equation
    // is a quantile FIRST-ORDER CONDITION, `E[psi_ipw(theta)] = 0`,
    // and its Jacobian `d mean(psi_ipw) / d theta` is genuinely
    // data-dependent -- which is precisely why `fit` needs
    // `var_est_with_jacobian` at all instead of the plain `var_est`
    // the other estimators use. `deriv` is that data-dependent
    // scalar; it is emphatically NOT `-1`, and substituting `-1`
    // yields a `sandwich_se` that is wrong by the factor `1/deriv`
    // (the v0.86.0 LPLR skip was the same class of mistake, worth
    // ~60x there).
    let deriv = f_theta / nf
    // v0.93.0+: persist the Jacobian as a uniform-API length-`n_obs`
    // array of the SAME scalar on every row, so `mean(psi_a) == deriv`
    // and `sandwich_variance`'s `psi_a` slot can be filled directly.
    //
    // Placement is load-bearing for the memoize path. Both `psi` and
    // `deriv` are RECOMPUTED on every `fit()` call from the
    // (possibly cache-restored) `g0` / `g1` / `m` rather than read
    // out of `FitCache` -- `FitCache` holds only the nuisance
    // predictions. So building `psi_a` here, after the `cache_hit`
    // branch, makes it correct on a cache hit by construction rather
    // than by a second, separately-maintained restore path that could
    // drift. `expand_v093_test.mbt::lpq_sandwich_after_memoize_cache_hit`
    // pins that.
    let psi_a : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      psi_a[i] = deriv
    }
    // REVIEW L11 fix (0.7.0): use the shared `var_est_with_jacobian`
    // helper instead of inlining `sum(psi^2) / n / (deriv^2 * n)`.
    // The math is byte-equal; the helper gives a Kahan-compensated
    // accumulator and the test contract is the same.
    let se = var_est_with_jacobian(psi, deriv)
    // v0.82.0+: write to cache when memoize is on and the
    // cache missed. Predictions stored as `[g0, g1, m]`.
    let next_cache = if memoize && !cache_hit {
      FitCache::from_fit(
        fold_ids,
        [g0, g1, m],
        self.seed,
        self.n_folds,
        1,
        n,
        data_hash,
        hparams_hash,
        cluster_hash,
        "lpq",
      )
    } else {
      self.fit_cache
    }
    {
      data: self.data,
      treatment: self.treatment,
      quantile: self.quantile,
      n_folds: self.n_folds,
      seed: self.seed,
      propensity_clip: self.propensity_clip,
      coef: theta,
      se,
      fitted: true,
      predictions_g0: g0,
      predictions_g1: g1,
      predictions_m: m,
      psi,
      psi_a,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      // v0.82.0+: persist the memoize flag and (possibly
      // updated) cache.
      memoize_enabled: self.memoize_enabled,
      fit_cache: next_cache,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.64.0+: multiplier bootstrap for `DoubleMLLPQ`. The
/// per-observation influence function `psi` is the centered
/// score at the bisection root (mean 0, `se_psi =
/// sqrt(mean(psi^2))` is the bootstrap denominator). Routes
/// through the shared `generic_bootstrap_single_psi` helper
/// (see `bootstrap_helper.mbt`).
///
/// `method_name` selects the multiplier distribution:
/// `"normal"` (default), `"Bayes"`, `"wild"`. `seed` defaults
/// to `2024`; `n_rep_boot` defaults to `500`.
///
/// Calling on an un-fit model aborts via `PreconditionError`.
pub fn DoubleMLLPQ::bootstrap(
  self : DoubleMLLPQ,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLLPQ {
  try {
    require(self.fitted)
    require(
      method_name == "normal" || method_name == "Bayes" || method_name == "wild",
    )
    require(n_rep_boot >= 2)
    let boot_t_stat = generic_bootstrap_single_psi(
      self.psi,
      method_name,
      n_rep_boot,
      seed,
    ) catch {
      BootstrapMethodError::UnknownMethod(m) =>
        abort(
          "draw_bootstrap_weights: unknown method (set in DoubleMLLPQ::bootstrap): " +
          m,
        )
    }
    {
      ..self,
      boot_t_stat,
      boot_method: method_name,
      n_rep_boot,
      boot_seed: seed,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.67.0+: Cinelli & Hazlett (2020) omitted-variable bias
/// analysis for the LPQ (Local Quantile) estimator. The IF
/// `psi` is centered (mean 0 at the bisection root);
/// `nu2 = mean(psi^2)` and `sigma2 = Var(y)`. Routes
/// through the shared `single_psi_sensitivity` helper (see
/// sensitivity.mbt).
pub fn DoubleMLLPQ::sensitivity_analysis(
  self : DoubleMLLPQ,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  single_psi_sensitivity(self.coef, self.psi, self.data.y, cf_y, cf_d)
}

///|
/// v0.74.0+: cluster-robust analogue of
/// `DoubleMLLPQ::sensitivity_analysis`. The IID path uses
/// the centered-IF formulation (`sigma2 = Var(y)`,
/// `nu2 = mean(psi^2)`); we replicate that here by
/// routing through `irm_style_sensitivity_cluster` with
/// `residuals = y - mean(y)` (so `mean(residuals^2) =
/// Var(y)`) and `psi_a = psi` (so `mean(psi_a^2) =
/// mean(psi^2)`); the IRM-style helper's per-obs C&H
/// max_bias is identical to `single_psi_sensitivity`'s in
/// this case. Only the variance / bias computation is
/// cluster-aware (sigma2_cluster and nu2_cluster are the
/// `G / n_clusters` sums of squared cluster sums).
///
/// `DoubleMLLPQData` has no `cluster_vars` field, so the
/// user must pass `cluster_ids` explicitly.
/// `cluster_ids.length()` must equal `self.data.n_obs()`.
/// Cluster indices are 0-based; `1 + max(cluster_ids)` is the
/// number of clusters.
pub fn DoubleMLLPQ::sensitivity_analysis_cluster(
  self : DoubleMLLPQ,
  cluster_ids : Array[Int],
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let n = self.data.y.length()
  require(cluster_ids.length() == n)
  let y = self.data.y
  // y_bar for the centered-y "residual" (so IRM-style
  // mean(residuals^2) == Var(y)).
  let mut y_sum = 0.0
  for i = 0; i < n; i = i + 1 {
    y_sum = y_sum + y[i]
  }
  let y_bar = y_sum / n.to_double()
  let residuals : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    residuals[i] = y[i] - y_bar
  }
  irm_style_sensitivity_cluster(
    self.coef,
    residuals,
    self.psi,
    cluster_ids,
    cf_y,
    cf_d,
  )
}

///|
/// Number of observations.
pub fn DoubleMLLPQ::n_obs(self : DoubleMLLPQ) -> Int {
  self.data.x.rows()
}

///|
/// Number of features (covariate columns).
pub fn DoubleMLLPQ::n_features(self : DoubleMLLPQ) -> Int {
  self.data.x.cols()
}

///|
/// 95% Wald confidence interval (z = 1.959963984540054). Matches the
/// `DoubleMLLPLR::confint` idiom byte-for-byte.
/// v0.67.0+: `joint` is a no-op for single-theta estimators.
pub fn DoubleMLLPQ::confint(
  self : DoubleMLLPQ,
  joint? : Bool = false,
  level? : Double = 0.95,
) -> (Double, Double) {
  try {
    require(self.fitted)
    require(level > 0.0 && level < 1.0)
    ignore(joint)
    let z = if (level - 0.95).abs() < 1.0e-12 {
      1.959963984540054
    } else {
      1.96
    }
    (self.coef - z * self.se, self.coef + z * self.se)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLLPQ::coef(self : DoubleMLLPQ) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLLPQ::se(self : DoubleMLLPQ) -> Double {
  try {
    require(self.fitted)
    self.se
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Cross-fitted outcome nuisance for Z=0 (length `n_obs`).
/// v0.53.0-dev: matches upstream `DoubleMLLPQ.predictions["g0"]`.
pub fn DoubleMLLPQ::predictions_g0(self : DoubleMLLPQ) -> Array[Double] {
  try {
    require(self.fitted)
    self.predictions_g0
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Cross-fitted outcome nuisance for Z=1 (length `n_obs`).
/// v0.53.0-dev: matches upstream `DoubleMLLPQ.predictions["g1"]`.
pub fn DoubleMLLPQ::predictions_g1(self : DoubleMLLPQ) -> Array[Double] {
  try {
    require(self.fitted)
    self.predictions_g1
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Cross-fitted treatment nuisance (propensity score, length `n_obs`).
/// v0.53.0-dev: matches upstream `DoubleMLLPQ.predictions["m"]`.
pub fn DoubleMLLPQ::predictions_m(self : DoubleMLLPQ) -> Array[Double] {
  try {
    require(self.fitted)
    self.predictions_m
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.82.0+: turn on memoization for subsequent `fit()` calls.
pub fn DoubleMLLPQ::enable_memoize(self : DoubleMLLPQ) -> DoubleMLLPQ {
  { ..self, memoize_enabled: true, }
}

///|
/// v0.82.0+: turn off memoization.
pub fn DoubleMLLPQ::disable_memoize(self : DoubleMLLPQ) -> DoubleMLLPQ {
  { ..self, memoize_enabled: false, }
}

///|
/// v0.82.0+: drop any cached nuisance predictions.
pub fn DoubleMLLPQ::clear_cache(self : DoubleMLLPQ) -> DoubleMLLPQ {
  { ..self, fit_cache: FitCache::empty(), }
}

///|
/// v0.82.0+: `true` iff `fit_cache` holds at least one cached
/// observation.
pub fn DoubleMLLPQ::has_cache(self : DoubleMLLPQ) -> Bool {
  !self.fit_cache.is_empty()
}

// ---------------------------------------------------------------------------
// v0.93.0: the sandwich API
// ---------------------------------------------------------------------------
//
// WHY LPQ IS NOT ONE OF THE ORDINARY 12
// =====================================
//
// `var_est.mbt` defines the package's estimating function as
//     f(theta) = E[theta * psi_a + psi_b]
// a mean moment whose root is `-mean(psi_b) / mean(psi_a)` and whose
// Jacobian is `J = mean(psi_a)`. For the eleven estimators that
// follow that convention, the sandwich is a mechanical three-liner:
// evaluate the score with `psi_at(coef, self.psi_a, self.psi_b)` and
// set `M_inv = [[1 / mean(self.psi_a)]]`.
//
// LPQ does not fit that template, and forcing it to is exactly what
// skipped LPQ in v0.86.0 and v0.90.0:
//
//   1. LPQ's estimating equation is a quantile FIRST-ORDER
//      CONDITION, `mean(psi_ipw(theta)) = 0`, found by bisection.
//      It has no `psi_b` to solve for, and no `psi_at` split to
//      reconstruct the score from. `self.psi` is ALREADY the score
//      evaluated at `coef`, and this method therefore uses it
//      directly. Calling `psi_at` here would evaluate a DIFFERENT
//      function whose root is not `coef`.
//
//   2. Its Jacobian is `d mean(psi_ipw) / d theta`, a genuinely
//      data-dependent scalar (the KDE-smoothed weighted density
//      `f_theta / n` computed in `fit`), NOT the constant `-1` and
//      NOT `mean` of any per-observation array. This is why `fit`
//      calls `var_est_with_jacobian` rather than `var_est`.
//
// The payoff invariant, and the whole reason for persisting the
// Jacobian in v0.93.0:
//
//     sandwich_variance_hc0 = M_inv[0,0]^2 * sum_i psi[i]^2 / n / n
//                           = (1/deriv^2) * sum_i psi[i]^2 / n^2
//
// which is exactly `var_est_with_jacobian(psi, deriv)`'s
// `se = sqrt((sum_i psi[i]^2 / n) / (deriv^2 * n))` -- the same
// quantity, accumulated in the same Kahan order. So:
//
//     sandwich_se(HC0) == se()
//
// to floating-point tolerance, and `se()` remains the reference.
//
// `self.psi_a` is the length-`n_obs` array whose every entry is the
// same scalar `deriv`, so `mean(self.psi_a) == deriv` exactly.
// `sandwich_variance` reads that array only to satisfy its length
// preconditions (the v0.91.0 accumulator carries no `psi_a` weight);
// the Jacobian enters solely through `M_inv`.

///|
/// The Jacobian inverse `M_inv = [[1 / deriv]]` (1x1), where
/// `deriv` is the data-dependent `d mean(psi_ipw) / d theta` at
/// `coef`. Only `M_inv[0,0]^2` enters the variance, so the sign of
/// the inverse is irrelevant.
///
/// The degenerate-input guard is `require(deriv.abs() >= 1e-12)`,
/// which ABORTS rather than clipping. Two reasons:
///
///   - `fit` already routes the same `deriv` through
///     `var_est_with_jacobian`, which aborts on `deriv == 0`
///     (`require(jacobian.abs() > 0.0)`). So an exactly-zero
///     Jacobian can never reach this method on a fitted model, and
///     a clip here could only ever DISAGREE with `se()`.
///   - Clipping to `1e-12` (the `comp_safe` idiom used inside
///     `fit`) would silently break the `sandwich_se(HC0) == se()`
///     invariant for small-but-nonzero `deriv`, because `se()` uses
///     the unclipped value. Aborting keeps the two paths honest
///     rather than quietly returning a different number.
///
/// The `1e-12` floor (rather than `!= 0`) also catches the
/// sub-normal case where `1 / deriv` overflows to infinity and the
/// variance would come back `inf` while still passing a
/// `>= 0.0` check.
fn DoubleMLLPQ::m_inv_1x1(self : DoubleMLLPQ) -> Matrix {
  try {
    require(self.fitted)
    require(self.psi_a.length() == self.psi.length())
    require(self.psi.length() >= 1)
    let deriv = self.psi_a[0]
    require(deriv.abs() >= 1.0e-12)
    Matrix::from_array([1.0 / deriv], 1, 1)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.93.0+: heteroskedasticity-consistent (Huber-White) sandwich
/// standard error for the fitted LPQ. Routes through the shared
/// `sandwich_variance` dispatch, so the HC0 / HC1 / HC2 / HC3
/// relationships are the package-wide ones (see the file header in
/// `sandwich.mbt` and the identities pinned in
/// `expand_v088_test.mbt`).
///
/// The two inputs are NOT the usual `(psi_at(...), 1/mean(psi_a))`
/// pair, and the deviation is deliberate -- see the section comment
/// above. `self.psi` is used AS the score (it is already evaluated
/// at `coef`; there is no `psi_b` to reconstruct it from, and
/// `psi_at` would evaluate a different function whose root is not
/// `coef`), and the Jacobian is the persisted data-dependent
/// `deriv` in `self.psi_a[0]`, NOT the constant `-1`.
///
/// `n_obs` is `self.psi.length()`, the full sample: LPQ has no
/// transformed or subset domain.
///
/// Preconditions: `self.fitted`, `|psi_a[0]| >= 1e-12`.
pub fn DoubleMLLPQ::sandwich_se(
  self : DoubleMLLPQ,
  kind : SandwichKind,
) -> Double {
  try {
    let m_inv = self.m_inv_1x1()
    let n = self.psi.length()
    let variance_val = sandwich_variance(
      kind,
      self.psi_a,
      self.psi,
      m_inv,
      n,
      1,
    )
    require(variance_val >= 0.0)
    variance_val.sqrt()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.93.0+: cluster-robust sandwich standard error for the fitted
/// LPQ (Arellano 1987, Cameron-Gelbach-Miller 2011). Routes through
/// `cluster_sandwich_variance` with the SAME `self.psi` and `M_inv`
/// inputs as the IID `sandwich_se` path -- see the section comment
/// above for why those are not the ordinary `(psi_at(...),
/// 1/mean(psi_a))` pair.
///
/// `DoubleMLLPQData` carries no `cluster_vars`, so the caller must
/// supply `cluster_ids` explicitly (any grouping variable the
/// application has: region, site, panel unit). With all-singleton
/// clusters the meat degenerates to `sum_i psi[i]^2` and the formula
/// collapses to `sandwich_se(HC0)`, hence to `se()`.
///
/// Preconditions: `self.fitted`, `|psi_a[0]| >= 1e-12`,
/// `cluster_ids.length() == psi.length()`.
pub fn DoubleMLLPQ::cluster_sandwich_se(
  self : DoubleMLLPQ,
  cluster_ids : Array[Int],
) -> Double {
  try {
    let m_inv = self.m_inv_1x1()
    let n = self.psi.length()
    require(cluster_ids.length() == n)
    let variance_val = cluster_sandwich_variance(
      self.psi_a,
      self.psi,
      m_inv,
      cluster_ids,
      1,
    )
    require(variance_val >= 0.0)
    variance_val.sqrt()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.93.0+: returns `coef` UNCHANGED -- a documented no-op, not a
/// bias correction. Identical in reasoning to the twelve
/// `bias_corrected_coef` methods added in v0.86.0 - v0.92.0; see
/// `DoubleMLIRM::bias_corrected_coef` and `bias_corrected_theta`
/// in `sandwich.mbt` for the full argument.
///
/// `coef` is the bisection root of the LPQ quantile moment
/// `mean(psi_ipw(theta)) = 0`. That estimating function is
/// orthogonal at its root by construction -- and that orthogonality
/// IS what makes the estimator consistent -- so no correction built
/// from the fitted scores is a bias estimate for this class of
/// estimator. This accessor therefore reports the uncorrected point
/// estimate rather than a number that merely looks like a
/// correction.
///
/// The pre-v0.91.0 form `coef + mean(psi_b - coef * psi_a)` is
/// algebraically `3 * coef` for a constant-`psi_a` estimator and is
/// not a bias estimate for ANY of them; the v0.91.0 argument applies
/// here unchanged.
///
/// Preconditions: `self.fitted`.
pub fn DoubleMLLPQ::bias_corrected_coef(self : DoubleMLLPQ) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
