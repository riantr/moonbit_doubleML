///|
// Regularised linear learners for the DML nuisance path.
//
// v0.120.0. Before this file the package had exactly ONE linear
// learner (`LinearRegression`, unpenalised OLS) and the CHANGELOG
// carried the standing gap "Regularized linear learners (Lasso /
// ElasticNet / Ridge): still not in the DML nuisance path". This
// module closes it with three `Learner` implementations that mirror
// scikit-learn 1.9's `Ridge` / `Lasso` / `ElasticNet`.
//
// EVERY convention below was MEASURED against sklearn 1.9.0, not read
// off its documentation. The measurements are in
// `_verify/_probe_v120_sklearn{,2,3}.py` (what sklearn does),
// `_verify/_probe_v120_algo{2,3,4}.py` (this algorithm vs sklearn) and
// the gates live in `expand_v120_test.mbt`. Three of them are load
// bearing and non-obvious, so they are spelled out again here because
// getting any of them wrong produces a plausible-looking model:
//
//   1. THE INTERCEPT IS NOT PENALISED, AND IS NOT A COLUMN OF X.
//      `LinearRegression` folds the intercept into the design matrix as
//      a leading column of ones. Doing that here and penalising it
//      would shrink the intercept and give a DIFFERENT ESTIMATOR: on
//      the v0.120.0 oracle fixture the two intercepts differ by 2.7e-2
//      at alpha = 0.7. sklearn instead CENTRES, solves for the slopes
//      only, and adds the intercept back as `y_mean - x_mean . beta`.
//      Measured: |that identity - sklearn.intercept_| = 3.3e-16.
//
//   2. THE CENTROID IS THE WEIGHTED MEAN, for all three learners.
//      `Ridge`, `Lasso` and `ElasticNet` all centre on
//      `sum_i w_i x_i / sum_i w_i` when `sample_weight` is supplied,
//      and on the plain mean otherwise. A solver-to-solver comparison
//      briefly suggested otherwise for Lasso (the plain-mean version
//      was 1.6e-2 off while the weighted one was 3.3e-16) because the
//      plain-mean prototype was itself unconverged; the intercept
//      identity above is solver-free and settled it.
//
//   3. `alpha` MEANS TWO DIFFERENT THINGS, and they differ BY n.
//      `Ridge` minimises `||y - Xw||^2 + alpha * ||w||^2` -- the RAW
//      sum of squares. `Lasso` / `ElasticNet` minimise
//      `(1 / 2n) ||y - Xw||^2 + alpha * (...)` -- the 1/(2n)-NORMALISED
//      form. So the same numeric alpha is ~n times stronger for Lasso.
//      Measured identity, and used as a gate:
//          ElasticNet(l1_ratio = 0, alpha = a)
//              == Ridge(alpha = a * sum(sample_weight))
//      with `sum(sample_weight) = n` for an unweighted fit. The
//      weighted form of that factor was NOT obvious and the oracle
//      caught the unweighted-only version: using `a * n` on a
//      weighted fixture is wrong by 2.1e-1, while `a * sum(w)` agrees
//      to 1.1e-11. It follows from the mean-1 renormalisation below --
//      the solver's system is `(sum_i wt_i x x' + a n I) b = ...`, and
//      rescaling by `sum(w)/n` turns the penalty into `a * sum(w)`.
//
// Two further asymmetries, also measured:
//
//   * `Lasso` / `ElasticNet` are SCALE-INVARIANT in `sample_weight`:
//     they renormalise the weights to mean 1 (`w *= n / sum(w)`), so
//     multiplying every weight by 17 changes the answer by exactly 0.0.
//     `Ridge` is NOT scale-invariant -- alpha is absolute there, so
//     `w = 0.01 * 1` moves the coefficients by 1.21 on the oracle
//     fixture. Do not "fix" one to match the other.
//
//   * `sample_weight` is a HARD requirement for `Lasso` / `ElasticNet`
//     weights to be meaningful, but it is accepted (not ignored) in
//     sklearn 1.9 -- an early probe assumed it was a silent no-op
//     because uniform weights are. Non-uniform weights move the answer
//     by 3.3e-4, so they are genuinely used.
//
// WHY THE GATES GATE THE OBJECTIVE AND NOT THE COEFFICIENTS
//
// `Ridge` is closed form, so its coefficients match sklearn to 7.1e-14
// and the gates assert them directly at 1e-9. `Lasso` / `ElasticNet`
// are ITERATIVE, and two correct iterative solvers stopped by
// different criteria land at different points on a linear-convergence
// design: at tol = 1e-10 the coefficients differ by up to 8.8e-4 while
// the OBJECTIVE differs by 4.4e-9 absolute / 1.2e-7 relative. The
// objective is flat near the optimum and the active set is not, so the
// objective is the criterion-independent statement "both of these are
// at the optimum". `expand_v120_test.mbt` therefore gates on
//   |F(this implementation) - F(sklearn)| / |F| <= 1e-6
// (measured worst 1.2e-7, so ~10x margin) plus a coefficient gate on
// the closed-form `Ridge` and a zero-pattern gate on the iterative
// learners. `Lasso::iterations()` is exposed because `max_iter` is a
// real failure mode and a silent hit on it would be invisible
// otherwise.

///|
/// Outcome of one coordinate-descent solve.
priv struct EnetSolution {
  coef : Array[Double]
  n_iter : Int
}

///|
/// Soft-threshold operator `sign(t) * max(|t| - thresh, 0)`, the exact
/// 1-D minimiser of `t^2 / 2 + thresh * |t|`. Written branch-wise
/// rather than with `sign(t) * max(...)` so that `thresh = 0` and
/// `t = 0` land on the same value sklearn produces rather than on
/// `-0.0 * 0.0`.
fn enet_soft_threshold(t : Double, thresh : Double) -> Double {
  let a = t.abs()
  if a <= thresh {
    0.0
  } else if t < 0.0 {
    -(a - thresh)
  } else {
    a - thresh
  }
}

///|
/// Column means and the response mean used to centre `(x, y)`.
///
/// With an empty `w` this is the plain mean of every column and of `y`.
/// With a non-empty `w` it is the WEIGHTED mean
/// `sum_i w_i x_ij / sum_i w_i`, which is invariant to a global
/// rescaling of `w` -- matching sklearn 1.9's `np.average`, and the
/// reason `Ridge` is insensitive to a constant rescaling of `w` even
/// though its `alpha` is not.
fn reg_fit_means(
  x : Matrix,
  y : Array[Double],
  w : Array[Double],
) -> (Array[Double], Double) {
  let n = x.nrows
  let p = x.ncols
  let weighted = !w_is_unweighted(w)
  let mut wsum = 0.0
  for i = 0; i < n; i = i + 1 {
    wsum = wsum + (if weighted { w[i] } else { 1.0 })
  }
  let denom = if weighted { wsum } else { n.to_double() }
  let xm = Array::make(p, 0.0)
  let mut yacc = 0.0
  for i = 0; i < n; i = i + 1 {
    let wi = if weighted { w[i] } else { 1.0 }
    yacc = yacc + wi * y[i]
    for j = 0; j < p; j = j + 1 {
      xm[j] = xm[j] + wi * x.data[i * p + j]
    }
  }
  for j = 0; j < p; j = j + 1 {
    xm[j] = xm[j] / denom
  }
  (xm, yacc / denom)
}

///|
/// Renormalise `w` to mean 1, exactly as `Lasso.fit` does before
/// handing the weights to its Cython kernel (`sample_weight = sample_weight * (n_samples / sum(sample_weight))`).
///
/// Returns `[]` when `w` is empty, which the kernel reads as "all ones".
fn reg_mean_one_weights(w : Array[Double], n : Int) -> Array[Double] {
  if w_is_unweighted(w) {
    return []
  }
  let mut total = 0.0
  for wi in w {
    total = total + wi
  }
  if !(total > 0.0) {
    return []
  }
  let scale = n.to_double() / total
  let out = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    out[i] = w[i] * scale
  }
  out
}

///|
/// Cyclic coordinate descent for the ElasticNet objective
///
///     F(w) = (1 / 2n) ||y - Xw||^2
///          + l1_reg  * ||w||_1
///          + (l2_reg / 2) * ||w||^2
///
/// with `l1_reg = alpha * l1_ratio * n` and `l2_reg = alpha * (1 - l1_ratio) * n`,
/// i.e. sklearn's UNNORMALISED internal convention (see the header note
/// on alpha). `wt` is the mean-1 weight vector from
/// `reg_mean_one_weights`; `[]` means unweighted.
///
/// The per-coordinate update is the exact minimiser in `w[j]`:
///
///     w[j] <- soft(rho_j, l1_reg) / (norm_sq[j] + l2_reg)
///     rho_j = sum_i wt_i * x_ij * r_i
///
/// with the residual `r` maintained incrementally (the `w[j]`
/// contribution is added back before the inner product and subtracted
/// after the update), which is what keeps the sweep O(n * p) instead of
/// O(n * p^2).
///
/// Stopping: sklearn exits a sweep when the largest coefficient change
/// falls below `tol * (1 + 0.001 * ||w||_1)`, and after a sweep when
/// the objective moved by less than `tol * ||y_centred||^2`. Both are
/// implemented. The third sklearn exit -- the duality gap -- is NOT
/// reproduced; it only ever stops sklearn EARLIER than this loop does,
/// so a port here is at least as converged. See the gate note in
/// `expand_v120_test.mbt` for how that is bounded rather than assumed.
fn enet_coordinate_descent(
  x : Matrix,
  y : Array[Double],
  xm : Array[Double],
  ym : Double,
  wt : Array[Double],
  l1_reg : Double,
  l2_reg : Double,
  tol : Double,
  max_iter : Int,
) -> EnetSolution {
  let n = x.nrows
  let p = x.ncols
  let coef = Array::make(p, 0.0)
  let weighted = !w_is_unweighted(wt)
  // weighted column norms of the CENTRED design: sum_i wt_i x_ij^2
  let norm_sq = Array::make(p, 0.0)
  for i = 0; i < n; i = i + 1 {
    let wi = if weighted { wt[i] } else { 1.0 }
    for j = 0; j < p; j = j + 1 {
      let xij = x.data[i * p + j] - xm[j]
      norm_sq[j] = norm_sq[j] + wi * xij * xij
    }
  }
  // centred response, i.e. the initial residual at w = 0
  let r = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    r[i] = y[i] - ym
  }
  let mut yn2 = 0.0
  for i = 0; i < n; i = i + 1 {
    let wi = if weighted { wt[i] } else { 1.0 }
    yn2 = yn2 + wi * r[i] * r[i]
  }
  let mut t_prev = 0.5 * yn2
  let mut n_iter = 0
  let mut iter = 0
  while iter < max_iter {
    // tol scaled by ||w||_1, matching sklearn's `tol_`
    let mut w_l1 = 0.0
    for j = 0; j < p; j = j + 1 {
      w_l1 = w_l1 + coef[j].abs()
    }
    let tol_scaled = tol * (1.0 + 0.001 * w_l1.sqrt())
    let mut max_change = 0.0
    for j = 0; j < p; j = j + 1 {
      if norm_sq[j] == 0.0 {
        continue
      }
      let old_w_j = coef[j]
      if old_w_j != 0.0 {
        for i = 0; i < n; i = i + 1 {
          r[i] = r[i] + old_w_j * (x.data[i * p + j] - xm[j])
        }
      }
      let mut rho = 0.0
      for i = 0; i < n; i = i + 1 {
        let wi = if weighted { wt[i] } else { 1.0 }
        rho = rho + wi * r[i] * (x.data[i * p + j] - xm[j])
      }
      if l1_reg != 0.0 {
        coef[j] = enet_soft_threshold(rho, l1_reg) / (norm_sq[j] + l2_reg)
      } else {
        coef[j] = rho / (norm_sq[j] + l2_reg)
      }
      let w_j = coef[j]
      for i = 0; i < n; i = i + 1 {
        r[i] = r[i] - w_j * (x.data[i * p + j] - xm[j])
      }
      let d = (w_j - old_w_j).abs()
      if d > max_change {
        max_change = d
      }
    }
    n_iter = iter + 1
    if max_change < tol_scaled {
      break
    }
    let mut rss = 0.0
    for i = 0; i < n; i = i + 1 {
      let wi = if weighted { wt[i] } else { 1.0 }
      rss = rss + wi * r[i] * r[i]
    }
    let mut l1n = 0.0
    let mut l2n = 0.0
    for j = 0; j < p; j = j + 1 {
      l1n = l1n + coef[j].abs()
      l2n = l2n + coef[j] * coef[j]
    }
    let t_new = 0.5 * rss + l1_reg * l1n + 0.5 * l2_reg * l2n
    let delta = (t_new - t_prev).abs()
    t_prev = t_new
    if delta < tol * yn2 {
      break
    }
    iter = iter + 1
  }
  { coef, n_iter, }
}

///|
/// Shared tail of both iterative learners: centre, solve, un-centre.
/// `l1_ratio` is what distinguishes them, so `Lasso` delegates here
/// with `1.0` rather than keeping a second copy of the solver (a
/// v0.119.0 lesson: two copies of one formula is how a bug survived 890
/// tests).
fn enet_fit_tail(
  self_alpha : Double,
  l1_ratio : Double,
  self_tol : Double,
  self_max_iter : Int,
  x : Matrix,
  y : Array[Double],
  w : Array[Double],
) -> (Array[Double], Double, Int) {
  let n = x.nrows
  let p = x.ncols
  for wi in w {
    if wi < 0.0 {
      abort("sample_weight entries must be non-negative")
    }
  }
  let (xm, ym) = reg_fit_means(x, y, w)
  let wt = reg_mean_one_weights(w, n)
  let nf = n.to_double()
  let l1_reg = self_alpha * l1_ratio * nf
  let l2_reg = self_alpha * (1.0 - l1_ratio) * nf
  let sol = enet_coordinate_descent(
    x, y, xm, ym, wt, l1_reg, l2_reg, self_tol, self_max_iter,
  )
  let mut intercept = ym
  for j = 0; j < p; j = j + 1 {
    intercept = intercept - xm[j] * sol.coef[j]
  }
  (sol.coef, intercept, sol.n_iter)
}

///|
/// L2-penalised linear model (ridge regression), scikit-learn
/// `Ridge(alpha=...)` with `fit_intercept=True`.
///
/// Minimises `||y - Xw||^2 + alpha * ||w||^2` with the intercept left
/// UNPENALISED, obtained by centring. `alpha` is on the RAW
/// sum-of-squares scale (contrast `Lasso` / `ElasticNet`, where it is
/// on the `1 / 2n` scale and therefore ~n times stronger).
///
/// `alpha` must be strictly positive. `alpha = 0` is plain OLS, which
/// this package already has as `LinearRegression`; allowing it here
/// would make the normal equations singular on a rank-deficient design
/// for no benefit. The positivity also guarantees the Cholesky inside
/// `solve_spd` cannot fail: `X'WX` is positive semi-definite and
/// `alpha * I` is positive definite.
pub struct Ridge {
  alpha : Double
  coef_ : Array[Double]
  intercept_ : Double
  n_features_ : Int
  fitted : Bool
} derive(Debug)

///|
pub extend Ridge with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Build an un-fitted `Ridge`. `alpha` defaults to `1.0`, matching
/// scikit-learn's `Ridge`.
pub fn Ridge::new(alpha? : Double = 1.0) -> Ridge {
  { alpha, coef_: [], intercept_: 0.0, n_features_: 0, fitted: false, }
}

///|
/// Number of features seen at fit time (excluding the intercept).
pub fn Ridge::n_features(self : Ridge) -> Int {
  self.n_features_
}

///|
/// The fitted slopes. Length is `n_features()`; the intercept is NOT
/// included in this vector (unlike `LinearRegression::coefficients()`,
/// whose length is `p + 1` and whose first entry is the intercept).
pub fn Ridge::coefficients(self : Ridge) -> Array[Double] {
  try {
    require(self.fitted)
    self.coef_
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// The fitted intercept.
pub fn Ridge::intercept(self : Ridge) -> Double {
  try {
    require(self.fitted)
    self.intercept_
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Fit on `(x, y)` with no sample weights. This is the byte-identical
/// path to `fit_weighted(x, y, ones)` -- see the uniform-weight gate in
/// `expand_v120_test.mbt`.
pub fn Ridge::fit(self : Ridge, x : Matrix, y : Array[Double]) -> Ridge {
  self.fit_weighted(x, y, [])
}

///|
/// Weighted ridge fit. Solves
/// `(Xc' W Xc + alpha I) beta = Xc' W yc` on the CENTRED, weighted
/// design and returns the intercept as `y_mean - x_mean . beta`.
///
/// Note this is `W`, not `W^2` and not a `sqrt(W)` row rescale: sklearn
/// rescaling the rows by `sqrt(w)` inflates the effective `alpha` to
/// `alpha * mean(w)`, and a prototype that did that was wrong by 0.68
/// on the oracle fixture. Uniform `w` is a no-op here (it scales the
/// whole system by a constant); non-uniform `w` is not.
pub fn Ridge::fit_weighted(
  self : Ridge,
  x : Matrix,
  y : Array[Double],
  w : Array[Double],
) -> Ridge {
  try {
    require(x.nrows > 0)
    require(x.ncols > 0)
    require(x.nrows == y.length())
    require(w_is_unweighted(w) || x.nrows == w.length())
    require(self.alpha > 0.0)
    for wi in w {
      require(wi >= 0.0)
    }
    let n = x.nrows
    let p = x.ncols
    let weighted = !w_is_unweighted(w)
    let (xm, ym) = reg_fit_means(x, y, w)
    let g = Matrix::zeros(p, p)
    let rhs = Array::make(p, 0.0)
    for i = 0; i < n; i = i + 1 {
      let wi = if weighted { w[i] } else { 1.0 }
      let yci = y[i] - ym
      for a = 0; a < p; a = a + 1 {
        let xai = x.data[i * p + a] - xm[a]
        rhs[a] = rhs[a] + wi * xai * yci
        for b = 0; b < p; b = b + 1 {
          let xbi = x.data[i * p + b] - xm[b]
          g.data[a * p + b] = g.data[a * p + b] + wi * xai * xbi
        }
      }
    }
    // add the penalty ONLY to the diagonal: the intercept is not a
    // column here, so nothing is penalised that should not be
    for j = 0; j < p; j = j + 1 {
      g.data[j * p + j] = g.data[j * p + j] + self.alpha
    }
    let coef = solve_spd(g, rhs)
    let mut intercept = ym
    for j = 0; j < p; j = j + 1 {
      intercept = intercept - xm[j] * coef[j]
    }
    {
      alpha: self.alpha,
      coef_: coef,
      intercept_: intercept,
      n_features_: p,
      fitted: true,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Predict `x . beta + intercept` for every row of `x`.
pub fn Ridge::predict(self : Ridge, x : Matrix) -> Array[Double] {
  try {
    require(self.fitted)
    require(x.ncols == self.n_features_)
    let n = x.nrows
    let p = x.ncols
    let out = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      let mut acc = self.intercept_
      for j = 0; j < p; j = j + 1 {
        acc = acc + x.data[i * p + j] * self.coef_[j]
      }
      out[i] = acc
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.120.0: `w` empty routes to the unweighted fit; the trait method
/// (three-argument) delegates to the inherent `fit_weighted`.
impl Learner for Ridge with fn fit(self, x, y, w) {
  self.fit_weighted(x, y, w)
}

///|
impl Learner for Ridge with fn predict(self, x) {
  self.predict(x)
}

///|
/// L1-penalised linear model, scikit-learn `Lasso(alpha=...)`.
///
/// Minimises `(1 / 2n) ||y - Xw||^2 + alpha * ||w||_1` with an
/// UNPENALISED intercept (obtained by centring). Note the `1 / 2n`:
/// at equal `n`, a `Lasso(alpha)` shrinks far harder than a
/// `Ridge(alpha)`. See the module header for the measured identity
/// `ElasticNet(l1_ratio = 0, alpha = a) == Ridge(alpha = a * n)`.
///
/// `sample_weight` is accepted and renormalised to mean 1, so this
/// learner is invariant to a constant rescaling of the weights.
pub struct Lasso {
  alpha : Double
  tol : Double
  max_iter : Int
  coef_ : Array[Double]
  intercept_ : Double
  n_iter_ : Int
  n_features_ : Int
  fitted : Bool
} derive(Debug)

///|
pub extend Lasso with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Build an un-fitted `Lasso`. Defaults match scikit-learn: `alpha =
/// 1.0`, `tol = 1e-4`, `max_iter = 1000`.
pub fn Lasso::new(
  alpha? : Double = 1.0,
  tol? : Double = 1.0e-4,
  max_iter? : Int = 1000,
) -> Lasso {
  {
    alpha,
    tol,
    max_iter,
    coef_: [],
    intercept_: 0.0,
    n_iter_: 0,
    n_features_: 0,
    fitted: false,
  }
}

///|
/// Number of features seen at fit time (excluding the intercept).
pub fn Lasso::n_features(self : Lasso) -> Int {
  self.n_features_
}

///|
/// Number of coordinate-descent sweeps performed by the last fit.
/// Exposed because `max_iter` is a real failure mode: a silent cap
/// would show up as a plausible-but-wrong model and nothing else in
/// the API would say so.
pub fn Lasso::iterations(self : Lasso) -> Int {
  self.n_iter_
}

///|
/// The fitted slopes, length `n_features()`. The intercept is NOT
/// included; read it with `intercept()`.
pub fn Lasso::coefficients(self : Lasso) -> Array[Double] {
  try {
    require(self.fitted)
    self.coef_
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// The fitted (unpenalised) intercept.
pub fn Lasso::intercept(self : Lasso) -> Double {
  try {
    require(self.fitted)
    self.intercept_
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Fit on `(x, y)` with no sample weights.
pub fn Lasso::fit(self : Lasso, x : Matrix, y : Array[Double]) -> Lasso {
  self.fit_weighted(x, y, [])
}

///|
/// Weighted fit. The weights are renormalised to mean 1 before the
/// sweep, so `fit_weighted(x, y, w)` and `fit_weighted(x, y, 17 * w)`
/// agree exactly -- a gate in `expand_v120_test.mbt` pins that.
///
/// The body is a one-line delegation to `ElasticNet` with
/// `l1_ratio = 1.0`. It is deliberately NOT a second copy of the
/// solver.
pub fn Lasso::fit_weighted(
  self : Lasso,
  x : Matrix,
  y : Array[Double],
  w : Array[Double],
) -> Lasso {
  try {
    require(x.nrows > 0)
    require(x.ncols > 0)
    require(x.nrows == y.length())
    require(w_is_unweighted(w) || x.nrows == w.length())
    require(self.alpha >= 0.0)
    require(self.tol > 0.0)
    require(self.max_iter > 0)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
  let en = ElasticNet::new(
    alpha=self.alpha,
    l1_ratio=1.0,
    tol=self.tol,
    max_iter=self.max_iter,
  ).fit_weighted(x, y, w)
  {
    alpha: self.alpha,
    tol: self.tol,
    max_iter: self.max_iter,
    coef_: en.coef_,
    intercept_: en.intercept_,
    n_iter_: en.n_iter_,
    n_features_: en.n_features_,
    fitted: true,
  }
}

///|
/// Predict `x . beta + intercept` for every row of `x`.
pub fn Lasso::predict(self : Lasso, x : Matrix) -> Array[Double] {
  try {
    require(self.fitted)
    require(x.ncols == self.n_features_)
    let n = x.nrows
    let p = x.ncols
    let out = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      let mut acc = self.intercept_
      for j = 0; j < p; j = j + 1 {
        acc = acc + x.data[i * p + j] * self.coef_[j]
      }
      out[i] = acc
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
impl Learner for Lasso with fn fit(self, x, y, w) {
  self.fit_weighted(x, y, w)
}

///|
impl Learner for Lasso with fn predict(self, x) {
  self.predict(x)
}

///|
/// ElasticNet, the convex blend of `Lasso` and `Ridge`:
/// minimises
///
///     (1 / 2n) ||y - Xw||^2
///   + alpha * l1_ratio * ||w||_1
///   + alpha * (1 - l1_ratio) / 2 * ||w||^2
///
/// with an unpenalised intercept obtained by centring. `l1_ratio = 1`
/// recovers `Lasso` exactly (that identity is a gate, not a comment);
/// `l1_ratio = 0` recovers `Ridge(alpha * sum(sample_weight))` -- note
/// the `sum(sample_weight)` factor, which reduces to `n` unweighted and
/// is the `1/(2n)`-versus-raw normalisation difference between the two
/// families.
///
/// Defaults match scikit-learn: `alpha = 1.0`, `l1_ratio = 0.5`,
/// `tol = 1e-4`, `max_iter = 1000`.
pub struct ElasticNet {
  alpha : Double
  l1_ratio : Double
  tol : Double
  max_iter : Int
  coef_ : Array[Double]
  intercept_ : Double
  n_iter_ : Int
  n_features_ : Int
  fitted : Bool
} derive(Debug)

///|
pub extend ElasticNet with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Build an un-fitted `ElasticNet`.
pub fn ElasticNet::new(
  alpha? : Double = 1.0,
  l1_ratio? : Double = 0.5,
  tol? : Double = 1.0e-4,
  max_iter? : Int = 1000,
) -> ElasticNet {
  {
    alpha,
    l1_ratio,
    tol,
    max_iter,
    coef_: [],
    intercept_: 0.0,
    n_iter_: 0,
    n_features_: 0,
    fitted: false,
  }
}

///|
/// Number of features seen at fit time (excluding the intercept).
pub fn ElasticNet::n_features(self : ElasticNet) -> Int {
  self.n_features_
}

///|
/// Number of coordinate-descent sweeps performed by the last fit.
pub fn ElasticNet::iterations(self : ElasticNet) -> Int {
  self.n_iter_
}

///|
/// The fitted slopes, length `n_features()`; the intercept is separate.
pub fn ElasticNet::coefficients(self : ElasticNet) -> Array[Double] {
  try {
    require(self.fitted)
    self.coef_
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// The fitted (unpenalised) intercept.
pub fn ElasticNet::intercept(self : ElasticNet) -> Double {
  try {
    require(self.fitted)
    self.intercept_
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Fit on `(x, y)` with no sample weights.
pub fn ElasticNet::fit(
  self : ElasticNet,
  x : Matrix,
  y : Array[Double],
) -> ElasticNet {
  self.fit_weighted(x, y, [])
}

///|
/// Weighted fit; see `Lasso::fit_weighted` for the mean-1
/// renormalisation.
pub fn ElasticNet::fit_weighted(
  self : ElasticNet,
  x : Matrix,
  y : Array[Double],
  w : Array[Double],
) -> ElasticNet {
  try {
    require(x.nrows > 0)
    require(x.ncols > 0)
    require(x.nrows == y.length())
    require(w_is_unweighted(w) || x.nrows == w.length())
    require(self.alpha >= 0.0)
    require(self.l1_ratio >= 0.0)
    require(self.l1_ratio <= 1.0)
    require(self.tol > 0.0)
    require(self.max_iter > 0)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
  let (coef, intercept, n_iter) = enet_fit_tail(
    self.alpha,
    self.l1_ratio,
    self.tol,
    self.max_iter,
    x,
    y,
    w,
  )
  {
    alpha: self.alpha,
    l1_ratio: self.l1_ratio,
    tol: self.tol,
    max_iter: self.max_iter,
    coef_: coef,
    intercept_: intercept,
    n_iter_: n_iter,
    n_features_: x.ncols,
    fitted: true,
  }
}

///|
/// Predict `x . beta + intercept` for every row of `x`.
pub fn ElasticNet::predict(self : ElasticNet, x : Matrix) -> Array[Double] {
  try {
    require(self.fitted)
    require(x.ncols == self.n_features_)
    let n = x.nrows
    let p = x.ncols
    let out = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      let mut acc = self.intercept_
      for j = 0; j < p; j = j + 1 {
        acc = acc + x.data[i * p + j] * self.coef_[j]
      }
      out[i] = acc
    }
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
impl Learner for ElasticNet with fn fit(self, x, y, w) {
  self.fit_weighted(x, y, w)
}

///|
impl Learner for ElasticNet with fn predict(self, x) {
  self.predict(x)
}

///|
/// Objective value of an ElasticNet fit at `coef`, on the SAME `1/(2n)`
/// normalisation the docs for `alpha` describe:
///
///     F = 0.5 / n * sum_i wt_i r_i^2
///       + alpha * l1_ratio * ||coef||_1
///       + 0.5 * alpha * (1 - l1_ratio) * ||coef||^2
///
/// with `r = y_centred - X_centred coef` and `wt` the mean-1
/// weights. This is the criterion the v0.120.0 gates compare across
/// implementations, because it is flat near the optimum while the
/// coefficient vector is not; see the module header.
///
/// Note the deliberate asymmetry with the SOLVER: inside
/// `enet_coordinate_descent` the objective is the unnormalised
/// `0.5 * sum wt_i r_i^2` with `l1_reg = alpha * l1_ratio * n`, which
/// is the same quantity scaled by `n` and is what makes the coordinate
/// update `soft(rho, l1_reg) / (norm_sq + l2_reg)` come out right.
/// Conflating the two was a real v0.120.0 bug caught by the oracle gate
/// on its first run: the objective came back ~n times too large.
pub fn enet_objective(
  coef : Array[Double],
  x : Matrix,
  y : Array[Double],
  w : Array[Double],
  alpha : Double,
  l1_ratio : Double,
) -> Double {
  let n = x.nrows
  let p = x.ncols
  let (xm, ym) = reg_fit_means(x, y, w)
  let wt = reg_mean_one_weights(w, n)
  let weighted = !w_is_unweighted(wt)
  let mut rss = 0.0
  for i = 0; i < n; i = i + 1 {
    let wi = if weighted { wt[i] } else { 1.0 }
    let mut acc = y[i] - ym
    for j = 0; j < p; j = j + 1 {
      acc = acc - (x.data[i * p + j] - xm[j]) * coef[j]
    }
    rss = rss + wi * acc * acc
  }
  let mut l1n = 0.0
  let mut l2n = 0.0
  for j = 0; j < p; j = j + 1 {
    l1n = l1n + coef[j].abs()
    l2n = l2n + coef[j] * coef[j]
  }
  0.5 * rss / n.to_double() +
  alpha * l1_ratio * l1n +
  0.5 * alpha * (1.0 - l1_ratio) * l2n
}
