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
}

///|
pub fn DoubleMLAPO::n_obs(self : DoubleMLAPO) -> Int {
  self.data.n_obs()
}

///|
pub fn DoubleMLAPO::coef(self : DoubleMLAPO) -> Double {
  require(self.fitted)
  self.coef
}

///|
pub fn DoubleMLAPO::se(self : DoubleMLAPO) -> Double {
  require(self.fitted)
  self.se
}

///|
pub fn DoubleMLAPO::confint(self : DoubleMLAPO) -> (Double, Double) {
  require(self.fitted)
  (self.coef - 1.96 * self.se, self.coef + 1.96 * self.se)
}

///|
pub fn DoubleMLAPO::predictions_g(self : DoubleMLAPO) -> Array[Double] {
  self.g_hat
}

///|
pub fn DoubleMLAPO::predictions_m(self : DoubleMLAPO) -> Array[Double] {
  self.m_hat
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
  let ga = Array::make(n, 0.0)
  let ma = Array::make(n, 0.0)
  for r = 0; r < self.n_rep; r = r + 1 {
    let (g, m) = cross_fit_apo(
      self.data.x,
      self.data.y,
      treated,
      kfold(n, self.n_folds, self.seed + r),
      self.propensity_clip,
    )
    for i = 0; i < n; i = i + 1 {
      ga[i] = ga[i] + g[i]
      ma[i] = ma[i] + m[i]
    }
  }
  let inv = 1.0 / self.n_rep.to_double()
  let g = Array::make(n, 0.0)
  let m = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    g[i] = ga[i] * inv
    m[i] = ma[i] * inv
  }
  let pa = Array::make(n, -1.0)
  let pb = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    pb[i] = g[i] + treated[i] * (self.data.y[i] - g[i]) / m[i]
  }
  let a = mean(pa)
  let b = mean(pb)
  let theta = -b / a
  let mut gamma = 0.0
  for i = 0; i < n; i = i + 1 {
    let z = theta * pa[i] + pb[i]
    gamma = gamma + z * z
  }
  let se = (gamma / n.to_double() / (a * a * n.to_double())).sqrt()
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
