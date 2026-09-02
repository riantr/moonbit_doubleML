///|
/// Binary logistic regression fit by Newton-Raphson IRLS.
///
/// Fits a binary logit model `P(y = 1 | x) = sigmoid(x @ beta)` by
/// iterated reweighted least squares. The intercept is folded into the
/// design matrix as a leading column of ones via
/// `augment_with_intercept`; the returned `coef_[0]` is the intercept
/// and `coef_[1..]` are the slopes. Only binary outcomes (y in {0, 1})
/// are supported — multiclass classification is intentionally out of
/// scope for this learner.
pub struct LogisticRegression {
  fitted : Bool
  coef_ : Array[Double]
} derive(Debug)

///|
/// Build an unfitted `LogisticRegression` learner. Call `fit(x, y)`
/// to estimate the coefficients; `predict` and `coefficients` abort
/// until then.
pub fn LogisticRegression::new() -> LogisticRegression {
  { fitted: false, coef_: [], }
}

///|
/// Fitted coefficient vector `[intercept, slope_1, ..., slope_p]`.
/// Aborts when called before `fit()` via `require(self.fitted)`.
pub fn LogisticRegression::coefficients(
  self : LogisticRegression,
) -> Array[Double] {
  require(self.fitted)
  self.coef_
}

///|
/// Numerically safe sigmoid. For non-negative `x` the
/// `1 / (1 + exp(-x))` form avoids computing `exp` of a large positive
/// argument; for negative `x` the `exp(x) / (1 + exp(x))` form avoids
/// underflowing `exp(-|x|)` to 0 (which would push the result to
/// exactly 1.0 and break downstream divisions by `p (1-p)` in the IRLS
/// step).
fn sigmoid(x : Double) -> Double {
  if x >= 0.0 {
    let e = @math.exp(-x)
    1.0 / (1.0 + e)
  } else {
    let e = @math.exp(x)
    e / (1.0 + e)
  }
}

///|
/// Public elementwise `expit(x) = 1 / (1 + exp(-x))` for callers
/// that need to evaluate the logistic link (e.g. LPLR's nonlinear
/// score). Numerically safe at both tails: for `x >= 0` the
/// `1/(1+exp(-x))` form avoids large `exp`; for `x < 0` the
/// `exp(x)/(1+exp(x))` form avoids underflowing to 0. The output
/// is in the open interval `(0, 1)` for any finite input.
pub fn expit(x : Double) -> Double {
  sigmoid(x)
}

///|
/// Public elementwise `logit(p) = log(p / (1 - p))`. Inputs are
/// clamped to `[eps, 1 - eps]` (default `eps = 1e-8`) so the result
/// stays finite; the LPLR score clips inner-fold `M` predictions
/// to `[1e-8, 1 - 1e-8]` upstream before logit, mirroring scipy
/// `logit(clip(p, 1e-8, 1 - 1e-8))`.
pub fn logit(p : Double, eps? : Double = 1.0e-8) -> Double {
  let plo = eps
  let phi = 1.0 - eps
  let pc = if p < plo { plo } else if p > phi { phi } else { p }
  @math.ln(pc / (1.0 - pc))
}

///|
/// Fit the logistic regression by Newton-Raphson IRLS. `x` is `n x p`
/// and `y` is a length-`n` vector of 0/1 labels.
///
/// Each iteration computes:
///
///   eta     = X_aug @ beta
///   p       = sigmoid(eta)
///   w       = p * (1 - p)                # per-observation IRLS weight
///   z       = eta + (y - p) / w          # working response
///   beta_new = (X_aug^T W X_aug + ridge * I)^-1 X_aug^T W z
///
/// and the loop exits early when the L2 step `||beta_new - beta||`
/// drops below `tol`. `ridge` guards the `X^T W X` factor against
/// singularity when `p` is exactly 0 or 1 (which makes `w` zero on
/// some rows); the default of `1e-8` is invisible on well-conditioned
/// data but prevents the Cholesky from failing on separable problems
/// at the boundary.
///
/// The default `max_iter = 25` comfortably covers both well-separated
/// data (3-5 steps) and noisy binary outcomes (10-20 steps).
pub fn LogisticRegression::fit(
  self : LogisticRegression,
  x : Matrix,
  y : Array[Double],
  max_iter? : Int = 25,
  tol? : Double = 1.0e-8,
  ridge? : Double = 1.0e-8,
) -> LogisticRegression {
  ignore(self)
  require(x.nrows == y.length())
  require(x.nrows >= 2)
  // REVIEW L12 fix (0.7.0): validate `y ∈ {0, 1}`. The doc says
  // "Only binary outcomes (y in {0, 1}) are supported" but the
  // pre-fix code silently produced nonsense for out-of-range y
  // (the IRLS `z = eta + (y - p) / w` formula tolerates anything
  // but the interpretation as a binary classification breaks).
  // Catching at the call site is cheaper than a downstream NaN.
  for yi in y {
    require(yi == 0.0 || yi == 1.0)
  }
  let n = x.nrows
  let xa = augment_with_intercept(x)
  let p1 = xa.ncols
  let mut beta = Array::make(p1, 0.0)
  let mut step = 0
  while step < max_iter {
    let eta = matvec(xa, beta)
    let p : Array[Double] = Array::make(n, 0.0)
    let w : Array[Double] = Array::make(n, 0.0)
    let z : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      let pi = sigmoid(eta[i])
      // clamp to (eps, 1-eps) so w_i = p(1-p) > 0 and z stays finite
      // even when y is exactly 0 or 1 and p is near the opposite pole.
      let pi_ = if pi < 1.0e-12 {
        1.0e-12
      } else if pi > 1.0 - 1.0e-12 {
        1.0 - 1.0e-12
      } else {
        pi
      }
      p[i] = pi_
      let wi = pi_ * (1.0 - pi_)
      w[i] = wi
      z[i] = eta[i] + (y[i] - pi_) / wi
    }
    // X^T W X = (sqrt(W) X)^T (sqrt(W) X).  Build sqrt(W) X by
    // scaling each row of X by sqrt(w_i).
    let xw = Matrix::zeros(n, p1)
    for i = 0; i < n; i = i + 1 {
      let sw = w[i].sqrt()
      for j = 0; j < p1; j = j + 1 {
        xw.data[i * p1 + j] = sw * xa.data[i * p1 + j]
      }
    }
    let xtwx = matmul(xw.transpose(), xw)
    // X^T W z = sum_i xa[i, j] * w[i] * z[i]
    let xtwz : Array[Double] = Array::make(p1, 0.0)
    for j = 0; j < p1; j = j + 1 {
      let mut s = 0.0
      for i = 0; i < n; i = i + 1 {
        s = s + xa.data[i * p1 + j] * w[i] * z[i]
      }
      xtwz[j] = s
    }
    let aug = add_ridge(xtwx, ridge)
    let beta_new = solve_spd(aug, xtwz)
    // convergence: L2 norm of the step
    let mut diff = 0.0
    for j = 0; j < p1; j = j + 1 {
      let d = beta_new[j] - beta[j]
      diff = diff + d * d
    }
    diff = diff.sqrt()
    beta = beta_new
    if diff < tol {
      break
    }
    step = step + 1
  }
  { fitted: true, coef_: beta, }
}

///|
/// Predict the probability `P(y = 1 | x)` for each row of `x`. The
/// output is clipped to `(1e-15, 1 - 1e-15)` so the returned
/// probabilities are always strictly inside the open interval `(0, 1)`,
/// matching the strict-inequality guarantee the `predict_class`
/// threshold needs. Aborts when called before `fit()` or when `x` has
/// a column count that does not match the data used at fit time.
pub fn LogisticRegression::predict(
  self : LogisticRegression,
  x : Matrix,
) -> Array[Double] {
  require(self.fitted)
  require(x.ncols == self.coef_.length() - 1)
  let xa = augment_with_intercept(x)
  let eta = matvec(xa, self.coef_)
  let n = x.nrows
  let out : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let pi = sigmoid(eta[i])
    if pi < 1.0e-15 {
      out[i] = 1.0e-15
    } else if pi > 1.0 - 1.0e-15 {
      out[i] = 1.0 - 1.0e-15
    } else {
      out[i] = pi
    }
  }
  out
}

///|
/// Predict the binary class label by thresholding `predict(x)` at
/// `threshold` (default 0.5). Returns 0.0 / 1.0 doubles (not ints) so
/// the output is type-compatible with `predict` for downstream
/// scoring code. Inherits the `predict` abort behaviour.
pub fn LogisticRegression::predict_class(
  self : LogisticRegression,
  x : Matrix,
  threshold? : Double = 0.5,
) -> Array[Double] {
  let p = self.predict(x)
  let n = p.length()
  let out : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    out[i] = if p[i] >= threshold { 1.0 } else { 0.0 }
  }
  out
}
