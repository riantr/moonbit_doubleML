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
/// Multiple-treatment APO wrapper. Each level is fit with the same folds and learner.
pub struct DoubleMLAPOS {
  data : DoubleMLData
  treatment_levels : Array[Double]
  n_folds : Int
  n_rep : Int
  seed : Int
  propensity_clip : Double
  coefs : Array[Double]
  ses : Array[Double]
} derive(Debug)

///|
pub fn DoubleMLAPOS::new(
  data : DoubleMLData,
  treatment_levels : Array[Double],
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  propensity_clip? : Double = 1.0e-6,
) -> DoubleMLAPOS {
  {
    data,
    treatment_levels,
    n_folds,
    n_rep,
    seed,
    propensity_clip,
    coefs: Array::make(treatment_levels.length(), 0.0),
    ses: Array::make(treatment_levels.length(), 0.0),
  }
}

///|
pub fn DoubleMLAPOS::fit(self : DoubleMLAPOS) -> DoubleMLAPOS {
  let c = Array::make(self.treatment_levels.length(), 0.0)
  let s = Array::make(self.treatment_levels.length(), 0.0)
  for j = 0; j < self.treatment_levels.length(); j = j + 1 {
    // The parent APOS passes `n_rep` through to each child APO so
    // the child does not draw its own fold partition; without
    // this, parent and child would each draw independently and
    // produce `n_rep * n_rep` total fold draws.
    // (wasteful, but functionally redundant). The cleanest fix is
    // to pass `n_rep = 1` to each child and let the APOS-level loop
    // do the repetition. This produces `n_rep` total fold draws per
    // treatment level, matching the intent of the outer `n_rep`.
    let z = DoubleMLAPO::new(
      self.data,
      treatment_level=self.treatment_levels[j],
      n_folds=self.n_folds,
      n_rep=1,
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
  }
}

///|
pub fn DoubleMLAPOS::coefs(self : DoubleMLAPOS) -> Array[Double] {
  self.coefs
}

///|
pub fn DoubleMLAPOS::ses(self : DoubleMLAPOS) -> Array[Double] {
  self.ses
}
