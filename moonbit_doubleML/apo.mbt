///|
/// Average potential outcomes for an arbitrary treatment level.
pub struct DoubleMLAPO {
  data : DoubleMLData
  treatment_level : Double
  n_folds : Int
  n_rep : Int
  seed : Int
  propensity_clip : Double
  g_hat : Array[Double]
  m_hat : Array[Double]
  coef : Double
  se : Double
  fitted : Bool
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
      g_hat: Array::make(data.n_obs(), 0.0),
      m_hat: Array::make(data.n_obs(), 0.0),
      coef: 0.0,
      se: 0.0,
      fitted: false,
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
fn cross_fit_apo(
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
      let p = LinearRegression::new()
        .fit(slice_matrix_rows(x, tg), slice_vector(y, tg))
        .predict(slice_matrix_rows(x, te))
      for k = 0; k < te.length(); k = k + 1 {
        g[te[k]] = p[k]
      }
    }
    let p = LinearRegression::new()
      .fit(slice_matrix_rows(x, tr), slice_vector(treated, tr))
      .predict(slice_matrix_rows(x, te))
    for k = 0; k < te.length(); k = k + 1 {
      m[te[k]] = p[k]
    }
  }
  (g, clip_vec(m, clip, 1.0 - clip))
}

///|
pub fn DoubleMLAPO::fit(self : DoubleMLAPO) -> DoubleMLAPO {
  let n = self.n_obs()
  let treated = indicator_level(self.data.d, self.treatment_level)
  // Accumulate `g` and `m` directly in the storage arrays; divide
  // by `n_rep` after the loop.
  let g = Array::make(n, 0.0)
  let m = Array::make(n, 0.0)
  for r = 0; r < self.n_rep; r = r + 1 {
    let (gr, mr) = cross_fit_apo(
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
    g_hat: g,
    m_hat: m,
    coef: theta,
    se,
    fitted: true,
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
  coefs : Array[Double]
  ses : Array[Double]
  fitted : Bool
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
    coefs: Array::make(treatment_levels.length(), 0.0),
    ses: Array::make(treatment_levels.length(), 0.0),
    fitted: false,
  }
}

///|
pub fn DoubleMLAPOS::fit(self : DoubleMLAPOS) -> DoubleMLAPOS {
  try {
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
      coefs: c,
      ses: s,
      fitted: true,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
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
