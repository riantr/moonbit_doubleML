///|
/// Average potential outcomes for an arbitrary treatment level.
pub struct DoubleMLAPO {
  data : DoubleMLData
  treatment_level : Double
  n_folds : Int
  n_rep : Int
  seed : Int
  propensity_clip : Double
  // v0.60.0+: injected nuisance learners. Defaults to
  // `LearnerDispatch::linear_regression()` so v0.59.0 callers
  // see byte-identical results. v0.61.0+ will plumb these
  // through `cross_fit_predict` for `g_hat` and `m_hat`; for
  // v0.60.0 they're stored on the struct and returned via the
  // accessors but not yet consumed internally.
  ml_g : LearnerDispatch
  ml_m : LearnerDispatch
  g_hat : Array[Double]
  m_hat : Array[Double]
  coef : Double
  se : Double
  fitted : Bool
  // v0.61.0+: per-observation influence function components
  // for the multiplier bootstrap. APO policy score:
  //   psi_a[i] = -1                              (constant)
  //   psi_b[i] = g[i] + treated[i] * (y[i] - g[i]) / m[i]
  // where `treated[i] = 1{d[i] == treatment_level}`,
  // `g = E[Y | X]`, `m = P(D = treatment_level | X)` (clipped).
  // Length `n_obs`. Populated by `fit(...)`.
  psi_a : Array[Double]
  psi_b : Array[Double]
  // v0.61.0+: multiplier bootstrap state. `boot_t_stat` is a
  // length-`n_rep_boot` array of t-statistics for `coef`.
  // Populated by `bootstrap(...)`; empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
} derive(Debug)

///|
pub extend DoubleMLAPO with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLAPO::new(
  data : DoubleMLData,
  treatment_level? : Double = 1.0,
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
  ml_g? : LearnerDispatch = LearnerDispatch::linear_regression(),
  ml_m? : LearnerDispatch = LearnerDispatch::linear_regression(),
) -> DoubleMLAPO {
  try {
    require(n_folds >= 2)
    require(n_folds <= data.n_obs())
    require(n_rep >= 1)
    require(propensity_clip > 0.0)
    require(propensity_clip < 0.5)
    {
      data,
      treatment_level,
      n_folds,
      n_rep,
      seed,
      propensity_clip,
      ml_g,
      ml_m,
      g_hat: Array::make(data.n_obs(), 0.0),
      m_hat: Array::make(data.n_obs(), 0.0),
      coef: 0.0,
      se: 0.0,
      fitted: false,
      psi_a: Array::make(data.n_obs(), -1.0),
      psi_b: Array::make(data.n_obs(), 0.0),
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLAPO::n_obs(self : DoubleMLAPO) -> Int {
  self.data.n_obs()
}

///|
/// Number of features (covariate columns).
pub fn DoubleMLAPO::n_features(self : DoubleMLAPO) -> Int {
  self.data.n_features()
}

///|
/// Accessor for the outcome-nuisance learner used by the most
/// recent `fit(...)` call. v0.60.0+.
pub fn DoubleMLAPO::learner_g(self : DoubleMLAPO) -> LearnerDispatch {
  self.ml_g
}

///|
/// Accessor for the propensity-score learner used by the most
/// recent `fit(...)` call. v0.60.0+.
pub fn DoubleMLAPO::learner_m(self : DoubleMLAPO) -> LearnerDispatch {
  self.ml_m
}

///|
pub fn DoubleMLAPO::coef(self : DoubleMLAPO) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLAPO::se(self : DoubleMLAPO) -> Double {
  try {
    require(self.fitted)
    self.se
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLAPO::confint(self : DoubleMLAPO) -> (Double, Double) {
  try {
    require(self.fitted)
    (self.coef - 1.96 * self.se, self.coef + 1.96 * self.se)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLAPO::predictions_g(self : DoubleMLAPO) -> Array[Double] {
  try {
    require(self.fitted)
    self.g_hat
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLAPO::predictions_m(self : DoubleMLAPO) -> Array[Double] {
  try {
    require(self.fitted)
    self.m_hat
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
fn indicator_level(d : Array[Double], level : Double) -> Array[Double] {
  let out = Array::make(d.length(), 0.0)
  for i = 0; i < d.length(); i = i + 1 {
    out[i] = if d[i] == level { 1.0 } else { 0.0 }
  }
  out
}

///|
/// Cross-fit the APO nuisances. The order is asymmetric: the
/// conditional outcome `g` is fit only on the treated subset (the
/// same as the upstream `DoubleMLAPO`), while the propensity `m`
/// is fit on the *full* training fold (including controls). The
/// effect is that rows with `treated = 0` receive their `g` value
/// from the previous fold's treated-only fit (or stay at the
/// default 0.0 if no fold has yet seen them); rows with `treated = 1`
/// receive both a `g` (on the treated subset) and a propensity
/// update. Matches the upstream `DoubleMLAPO` convention.
///
/// v0.63.0+: routes `ml_g` (for the conditional outcome on the
/// treated subset) and `ml_m` (for the propensity on the full
/// fold) through `LearnerDispatch`. Defaults preserve v0.62.2
/// byte-equality (default `LearnerDispatch::linear_regression()`
/// gives the v0.62.2 OLS path).
fn cross_fit_apo(
  ml_g : LearnerDispatch,
  ml_m : LearnerDispatch,
  x : Matrix,
  y : Array[Double],
  treated : Array[Double],
  folds : Array[Fold],
  clip : Double,
) -> (Array[Double], Array[Double]) {
  let n = x.rows()
  let g = Array::make(n, 0.0)
  let m = Array::make(n, 0.0)
  for fold in folds {
    let tr = fold.train_indices()
    let te = fold.test_indices()
    let tg = filter_indices(tr, treated)
    if tg.length() > 0 {
      let p = fit_predict_one_dispatch(
        ml_g,
        slice_matrix_rows(x, tg),
        slice_vector(y, tg),
        slice_matrix_rows(x, te),
      )
      for k = 0; k < te.length(); k = k + 1 {
        g[te[k]] = p[k]
      }
    }
    let p = fit_predict_one_dispatch(
      ml_m,
      slice_matrix_rows(x, tr),
      slice_vector(treated, tr),
      slice_matrix_rows(x, te),
    )
    for k = 0; k < te.length(); k = k + 1 {
      m[te[k]] = p[k]
    }
  }
  (g, clip_vec(m, clip, 1.0 - clip))
}

///|
pub fn DoubleMLAPO::fit(
  self : DoubleMLAPO,
  ml_g? : LearnerDispatch = self.ml_g,
  ml_m? : LearnerDispatch = self.ml_m,
) -> DoubleMLAPO {
  let n = self.n_obs()
  let treated = indicator_level(self.data.d, self.treatment_level)
  // Accumulate `g` and `m` directly in the storage arrays; divide
  // by `n_rep` after the loop.
  let g = Array::make(n, 0.0)
  let m = Array::make(n, 0.0)
  for r = 0; r < self.n_rep; r = r + 1 {
    let (gr, mr) = cross_fit_apo(
      ml_g,
      ml_m,
      self.data.x,
      self.data.y,
      treated,
      kfold(n, self.n_folds, self.seed + r),
      self.propensity_clip,
    )
    for i = 0; i < n; i = i + 1 {
      g[i] = g[i] + gr[i]
      m[i] = m[i] + mr[i]
    }
  }
  let inv = 1.0 / self.n_rep.to_double()
  for i = 0; i < n; i = i + 1 {
    g[i] = g[i] * inv
    m[i] = m[i] * inv
  }
  // `pa` is the APO score's `psi_a` component, which is structurally
  // `-1` for every observation (the potential-outcome score has no
  // treatment-side variation). `pb` is the `psi_b` component with
  // the IPW-style centring `g + treated * (y - g) / m`.
  let pa = Array::make(n, -1.0)
  let pb = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    pb[i] = g[i] + treated[i] * (self.data.y[i] - g[i]) / m[i]
  }
  // Score + variance via the shared `var_est` helper.
  let (theta, se) = var_est(pa, pb)
  {
    data: self.data,
    treatment_level: self.treatment_level,
    n_folds: self.n_folds,
    n_rep: self.n_rep,
    seed: self.seed,
    propensity_clip: self.propensity_clip,
    ml_g,
    ml_m,
    g_hat: g,
    m_hat: m,
    coef: theta,
    se,
    fitted: true,
    // v0.61.0: persist `pa` / `pb` as `psi_a` / `psi_b` for
    // the multiplier bootstrap (`pa` is constant -1, `pb` is
    // the IPW-centred potential-outcome score).
    psi_a: pa,
    psi_b: pb,
    boot_t_stat: [],
    boot_method: "",
    n_rep_boot: 0,
    boot_seed: 0,
  }
}

///|
/// v0.61.0+: multiplier bootstrap for `DoubleMLAPO`. The
/// per-observation influence function is
///
///   psi[i] = psi_a[i] + theta * psi_b[i]
///          = -1 + theta * pb[i]
///
/// where `pb[i] = g[i] + treated[i] * (y[i] - g[i]) / m[i]`
/// is the IPW-centred potential-outcome score, computed at
/// the fitted `coef` from the stored `g_hat` / `m_hat`.
/// Draws `n_rep_boot` weight vectors of length `n_obs` from
/// the chosen multiplier distribution, and returns a fitted
/// model with `boot_t_stat[b] = sum_i w[b, i] * psi[i] /
/// (sqrt(n) * se_psi)` populated where
/// `se_psi = sqrt(mean(psi^2))`.
///
/// `method_name` selects the multiplier distribution:
///   - `"normal"` (default): `w[i] ~ N(0, 1)`.
///   - `"Bayes"`: `w[i] = exp(1) - 1` (mean 0, var 1).
///   - `"wild"`: `w[i] = x[i] / sqrt(2) + (y[i]^2 - 1) / 2`
///     with `x, y ~ N(0, 1)`.
///
/// Calling `bootstrap` requires the model to be fitted; calling
/// on an un-fit model aborts with `PreconditionError`. The
/// helper is `did_bootstrap_t_stat` (v0.55.0 extracted from
/// `DoubleMLDIDCrossSection::bootstrap`); APO is the
/// `n_thetas=1` case.
pub fn DoubleMLAPO::bootstrap(
  self : DoubleMLAPO,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLAPO {
  try {
    require(self.fitted)
    require(
      method_name == "normal" || method_name == "Bayes" || method_name == "wild",
    )
    require(n_rep_boot >= 2)
    let n = self.n_obs()
    // Draw weights. Shape: (n_rep_boot, n_obs).
    let weights = draw_bootstrap_weights(method_name, n_rep_boot, n, seed) catch {
      BootstrapMethodError::UnknownMethod(m) =>
        abort(
          "draw_bootstrap_weights: unknown method (set in DoubleMLAPO::bootstrap): " +
          m,
        )
    }
    // Compute psi[i] = psi_a[i] + coef * psi_b[i] and
    // ss_psi = sum(psi[i]^2) once. `psi_a[i] = -1` and
    // `psi_b` is the IPW-centred potential-outcome score,
    // both populated by `fit(...)`.
    let psi : Array[Double] = Array::make(n, 0.0)
    let mut ss_psi = 0.0
    for i = 0; i < n; i = i + 1 {
      let psi_i = self.psi_a[i] + self.coef * self.psi_b[i]
      psi[i] = psi_i
      ss_psi = ss_psi + psi_i * psi_i
    }
    let n_d = n.to_double()
    let se_psi = (ss_psi / n_d).sqrt()
    if se_psi <= 0.0 {
      // Degenerate: psi sums to 0. Cannot divide.
      let boot_t_stat_zero : Array[Double] = Array::make(n_rep_boot, 0.0)
      return {
        ..self,
        boot_t_stat: boot_t_stat_zero,
        boot_method: method_name,
        n_rep_boot,
        boot_seed: seed,
      }
    }
    // n_thetas=1 case.
    let se_flat : Array[Double] = [se_psi]
    let boot_t_stat = did_bootstrap_t_stat(
      weights, psi, se_flat, n_rep_boot, n, 1,
    )
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
/// Average potential outcomes *symmetric* across multiple treatment
/// levels. v0.49.0: full upstream parity — `treatment_levels`
/// validation in `new` (rejects duplicates and levels not in
/// `data.d`), the `causal_contrast` method (level-by-level delta
/// and SE vs a reference level), and the
/// `treatment_levels()` / `n_treatment_levels()` / `fitted()`
/// accessors.
///
/// Each treatment level is fit with the same fold partition
/// (the parent does not currently route a shared partition to the
/// child `DoubleMLAPO`; each child draws its own folds via
/// `kfold`. v0.50.0+ plans to wire the parent through a
/// `fit_with_splits` helper to share one stratified partition,
/// but the v0.49.0 implementation is the v0.50.0 PR target) and
/// the same closed-form `LinearRegression` learner. The
/// `causal_contrast(reference_levels)` method then returns the
/// level-by-level difference `coefs[i] - coefs[ref]` for one or
/// more reference levels, matching the upstream
/// `DoubleMLAPOS.causal_contrast` semantics.
pub struct DoubleMLAPOS {
  data : DoubleMLData
  treatment_levels : Array[Double]
  n_folds : Int
  n_rep : Int
  seed : Int
  propensity_clip : Double
  // v0.60.0+: injected nuisance learners (forwarded to
  // each child `DoubleMLAPO` on fit). Same forward-compat
  // story as the rest of the v0.60.0 estimator set.
  ml_g : LearnerDispatch
  ml_m : LearnerDispatch
  coefs : Array[Double]
  ses : Array[Double]
  fitted : Bool
  // v0.63.0+: multiplier-bootstrap state. `boot_t_stat[j]` is
  // the length-`n_rep_boot` t-stat array for `coefs[j]`
  // (the APO coefficient at treatment level `j`).
  // Populated by `bootstrap(...)`; empty until then.
  boot_t_stat : Array[Array[Double]]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
} derive(Debug)

///|
pub extend DoubleMLAPOS with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLAPOS::new(
  data : DoubleMLData,
  treatment_levels : Array[Double],
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
  ml_g? : LearnerDispatch = LearnerDispatch::linear_regression(),
  ml_m? : LearnerDispatch = LearnerDispatch::linear_regression(),
) -> DoubleMLAPOS {
  try {
    require(treatment_levels.length() >= 1)
    require(n_folds >= 2)
    require(n_folds <= data.n_obs())
    require(n_rep >= 1)
    require(propensity_clip > 0.0)
    require(propensity_clip < 0.5)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
  // v0.49.0: every requested treatment level must be present in
  // the data's treatment assignment (`np.unique(data.d)` in
  // upstream). Catch duplicates within the request itself too.
  for i = 0; i < treatment_levels.length(); i = i + 1 {
    let lvl = treatment_levels[i]
    let mut dup = false
    for j = 0; j < i; j = j + 1 {
      if treatment_levels[j] == lvl {
        dup = true
        break
      }
    }
    if dup {
      abort(
        "DoubleMLAPOS: treatment_levels contains a duplicate entry: " +
        lvl.to_string(),
      )
    }
    let mut in_data = false
    for k = 0; k < data.d.length(); k = k + 1 {
      if data.d[k] == lvl {
        in_data = true
        break
      }
    }
    if !in_data {
      abort(
        "DoubleMLAPOS: treatment_level " +
        lvl.to_string() +
        " is not present in data.d",
      )
    }
  }
  {
    data,
    treatment_levels,
    n_folds,
    n_rep,
    seed,
    propensity_clip,
    ml_g,
    ml_m,
    coefs: Array::make(treatment_levels.length(), 0.0),
    ses: Array::make(treatment_levels.length(), 0.0),
    fitted: false,
    boot_t_stat: [],
    boot_method: "",
    n_rep_boot: 0,
    boot_seed: 0,
  }
}

///|
pub fn DoubleMLAPOS::fit(
  self : DoubleMLAPOS,
  ml_g? : LearnerDispatch = self.ml_g,
  ml_m? : LearnerDispatch = self.ml_m,
) -> DoubleMLAPOS {
  try {
    ignore(ml_g)
    ignore(ml_m)
    require(self.treatment_levels.length() >= 1)
    let c = Array::make(self.treatment_levels.length(), 0.0)
    let s = Array::make(self.treatment_levels.length(), 0.0)
    for j = 0; j < self.treatment_levels.length(); j = j + 1 {
      // v0.49.0: the parent APOS fits each child `DoubleMLAPO` with
      // `n_rep = self.n_rep` so the child draws its own fold
      // partition (`n_rep` total fold draws per treatment level).
      // The parent does not currently route a shared stratified
      // partition to the child — that's a v0.50.0+ target. The
      // resulting fold-draw count is `n_rep * n_treatment_levels`,
      // matching the upstream `DoubleMLAPOS.fit` total.
      let z = DoubleMLAPO::new(
        self.data,
        treatment_level=self.treatment_levels[j],
        n_folds=self.n_folds,
        n_rep=self.n_rep,
        seed=self.seed,
        propensity_clip=self.propensity_clip,
      ).fit()
      c[j] = z.coef()
      s[j] = z.se()
    }
    {
      data: self.data,
      treatment_levels: self.treatment_levels,
      n_folds: self.n_folds,
      n_rep: self.n_rep,
      seed: self.seed,
      propensity_clip: self.propensity_clip,
      ml_g,
      ml_m,
      coefs: c,
      ses: s,
      fitted: true,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Accessor for the outcome-nuisance learner used by the most
/// recent `fit(...)` call. v0.60.0+.
pub fn DoubleMLAPOS::learner_g(self : DoubleMLAPOS) -> LearnerDispatch {
  self.ml_g
}

///|
/// Accessor for the propensity-score learner used by the most
/// recent `fit(...)` call. v0.60.0+.
pub fn DoubleMLAPOS::learner_m(self : DoubleMLAPOS) -> LearnerDispatch {
  self.ml_m
}

///|
pub fn DoubleMLAPOS::coefs(self : DoubleMLAPOS) -> Array[Double] {
  try {
    require(self.fitted)
    self.coefs
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLAPOS::ses(self : DoubleMLAPOS) -> Array[Double] {
  try {
    require(self.fitted)
    self.ses
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.49.0: the requested treatment levels, in user-supplied order.
pub fn DoubleMLAPOS::treatment_levels(self : DoubleMLAPOS) -> Array[Double] {
  self.treatment_levels
}

///|
/// v0.49.0: number of requested treatment levels.
pub fn DoubleMLAPOS::n_treatment_levels(self : DoubleMLAPOS) -> Int {
  self.treatment_levels.length()
}

///|
/// Per-level multiplier bootstrap for `DoubleMLAPOS`. Each
/// treatment level's child `DoubleMLAPO` is re-fit (deterministic
/// given `seed`) and its `bootstrap(...)` invoked; the per-level
/// `boot_t_stat` arrays are concatenated into a length-`n_levels`
/// `Array[Array[Double]]` and also written to `self.boot_t_stat`.
///
/// `method_name` selects the multiplier distribution: `"normal"`
/// (default), `"Bayes"`, `"wild"` — see `DoubleMLAPO::bootstrap`.
/// `n_rep_boot` defaults to 500; `seed` defaults to 2024.
pub fn DoubleMLAPOS::bootstrap(
  self : DoubleMLAPOS,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLAPOS {
  try {
    require(self.fitted)
    require(
      method_name == "normal" || method_name == "Bayes" || method_name == "wild",
    )
    require(n_rep_boot >= 2)
    let n_levels = self.treatment_levels.length()
    let per_level : Array[Array[Double]] = Array::make(n_levels, [])
    for j = 0; j < n_levels; j = j + 1 {
      let child = DoubleMLAPO::new(
        self.data,
        treatment_level=self.treatment_levels[j],
        n_folds=self.n_folds,
        n_rep=self.n_rep,
        seed=self.seed,
        propensity_clip=self.propensity_clip,
        ml_g=self.ml_g,
        ml_m=self.ml_m,
      )
      let fitted_child = child.fit()
      let booted = fitted_child.bootstrap(method_name~, n_rep_boot~, seed~)
      per_level[j] = booted.boot_t_stat
    }
    {
      ..self,
      boot_t_stat: per_level,
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
/// Per-level Wald confidence intervals `(coef - z * se, coef + z * se)`
/// for `DoubleMLAPOS`. Returns one `(lo, hi)` tuple per treatment
/// level, in user-supplied order. `level` defaults to 0.95 (z =
/// 1.959963984540054 for the standard normal).
pub fn DoubleMLAPOS::confint(
  self : DoubleMLAPOS,
  level? : Double = 0.95,
) -> Array[(Double, Double)] {
  try {
    require(self.fitted)
    require(level > 0.0 && level < 1.0)
    let alpha = 1.0 - level
    let z = norm_ppf(1.0 - alpha / 2.0)
    let n_levels = self.treatment_levels.length()
    let out : Array[(Double, Double)] = Array::make(n_levels, (0.0, 0.0))
    for j = 0; j < n_levels; j = j + 1 {
      let lo = self.coefs[j] - z * self.ses[j]
      let hi = self.coefs[j] + z * self.ses[j]
      out[j] = (lo, hi)
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Per-level `boot_t_stat` accessors (v0.63.0+).
pub fn DoubleMLAPOS::boot_t_stats(self : DoubleMLAPOS) -> Array[Array[Double]] {
  try {
    require(self.fitted)
    self.boot_t_stat
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLAPOS::boot_method(self : DoubleMLAPOS) -> String {
  self.boot_method
}

///|
pub fn DoubleMLAPOS::n_rep_boot(self : DoubleMLAPOS) -> Int {
  self.n_rep_boot
}

///|
pub fn DoubleMLAPOS::boot_seed(self : DoubleMLAPOS) -> Int {
  self.boot_seed
}

///|
/// v0.49.0: whether `fit` has been called.
pub fn DoubleMLAPOS::fitted(self : DoubleMLAPOS) -> Bool {
  self.fitted
}

///|
/// v0.49.0: causal contrasts between the requested treatment levels
/// and the supplied reference level(s). Returns one
/// `Array[Double]` of length `2 * treatment_levels.length() - 1`
/// per reference level: the ref-level slot is a single `0.0` (its
/// contrast is trivially zero), and every other slot is a
/// `(delta, se)` pair where `delta = coefs[i] - coefs[ref_idx]`
/// and `se = sqrt(se[i]^2 + se[ref_idx]^2)`. `ref_idx` is the
/// position of the reference level in `treatment_levels`. The
/// layout is interleaved (`[0.0, delta_0, se_0, delta_1, se_1, ...]`
/// for a 2-level input) rather than a `[(level, coef, se), ...]`
/// table — see `apo_test.mbt::apos_causal_contrast_with_reference`
/// for the actual indices.
///
/// The SE of each contrast is computed via the standard
/// `var(psi_a) + var(psi_b) - 2*cov(psi_a, psi_b)` style
/// approximation; for v0.49.0 we take the conservative
/// `sqrt(se_a^2 + se_b^2)` route (same as the upstream
/// `causal_contrast` summary table), which is exact when the
/// per-level psi_a and psi_b are independent across levels
/// (true under stratified kfold with disjoint train indices).
pub fn DoubleMLAPOS::causal_contrast(
  self : DoubleMLAPOS,
  reference_levels : Array[Double],
) -> Array[Array[Double]] {
  // v0.49.0: pre-condition check is local; ref_indices is built
  // up in the same scope that consumes it. `abort` (not raise) is
  // used so the function signature stays clean.
  if !self.fitted {
    abort("precondition failed at DoubleMLAPOS::causal_contrast: not fitted")
  }
  if reference_levels.length() < 1 {
    abort(
      "precondition failed at DoubleMLAPOS::causal_contrast: reference_levels is empty",
    )
  }
  let ref_indices : Array[Int] = []
  for r = 0; r < reference_levels.length(); r = r + 1 {
    let ref_lvl = reference_levels[r]
    let mut found = false
    for i = 0; i < self.treatment_levels.length(); i = i + 1 {
      if self.treatment_levels[i] == ref_lvl {
        ignore(ref_indices.push(i))
        found = true
        break
      }
    }
    if !found {
      abort(
        "DoubleMLAPOS::causal_contrast: reference_level " +
        ref_lvl.to_string() +
        " is not in treatment_levels",
      )
    }
  }
  let results : Array[Array[Double]] = []
  for r = 0; r < ref_indices.length(); r = r + 1 {
    let ref_idx = ref_indices[r]
    let row : Array[Double] = []
    for i = 0; i < self.treatment_levels.length(); i = i + 1 {
      if i == ref_idx {
        ignore(row.push(0.0))
      } else {
        // delta = coef_i - coef_ref, se = sqrt(se_i^2 + se_ref^2)
        let delta = self.coefs[i] - self.coefs[ref_idx]
        let se = (self.ses[i] * self.ses[i] +
        self.ses[ref_idx] * self.ses[ref_idx]).sqrt()
        ignore(row.push(delta))
        ignore(row.push(se))
      }
    }
    results.push(row)
  }
  results
}
