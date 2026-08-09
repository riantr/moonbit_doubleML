///|
/// Closed-form OLS linear regression.
///
/// Fits a linear model `y = X * beta + intercept` (intercept is folded into
/// `X` via a leading column of ones) by solving the normal equations
/// `X^T X beta = X^T y` using a Cholesky factorisation. A small ridge
/// `lambda` is added to the diagonal of `X^T X` to guard against
/// singularity when the design matrix is near-collinear; the default
/// `lambda = 1e-10` is small enough to be invisible on well-conditioned
/// data but prevents the Cholesky from failing on degenerate inputs.
pub struct LinearRegression {
  ridge : Double
  // fitted parameters: coefficients of the augmented design matrix
  // (length = p + 1, where p is the number of raw features)
  coef_ : Array[Double]
  // diagonal of (X^T X + ridge * I)^{-1}, stored at fit time so
  // `covariance_diagonal()` is O(p) instead of re-inverting X^T X.
  xtx_inv_diag : Array[Double]
  // diagonal of (X^T W X + ridge * I)^{-1} for the WLS fit, OR an
  // empty array for the unweighted fit. Used by `DoubleMLRDD` for
  // the WLS-aware intercept variance (TODO #11c.2).
  xtwx_inv_diag : Array[Double]
  fitted : Bool
} derive(Debug)

///|
pub fn LinearRegression::new(ridge? : Double = 1.0e-10) -> LinearRegression {
  { ridge, coef_: [], xtx_inv_diag: [], xtwx_inv_diag: [], fitted: false }
}

///|
/// Number of features (excluding the intercept).
pub fn LinearRegression::n_features(self : LinearRegression) -> Int {
  if self.fitted {
    self.coef_.length() - 1
  } else {
    0
  }
}

///|
pub fn LinearRegression::coefficients(self : LinearRegression) -> Array[Double] {
  require(self.fitted)
  self.coef_
}

///|
/// Internal helper: solve a linear system of normal equations with a small
/// ridge. `xtx` is `X^T X` and `xty` is `X^T y`.
fn solve_normal_eqs(
  xtx : Matrix,
  xty : Array[Double],
  ridge : Double,
) -> Array[Double] {
  let aug = add_ridge(xtx, ridge)
  solve_spd(aug, xty)
}

///|
/// Augment a feature matrix `X` (n x p) with a leading column of ones to
/// form the design matrix used by the OLS fit. The result has shape
/// `n x (p + 1)`. Exposed as `pub` so other learners (e.g. the
/// `LogisticRegression` IRLS fit) can reuse the same convention
/// without duplicating the loop.
pub fn augment_with_intercept(x : Matrix) -> Matrix {
  let n = x.nrows
  let p = x.ncols
  let out = Matrix::zeros(n, p + 1)
  for i = 0; i < n; i = i + 1 {
    out.data[i * (p + 1) + 0] = 1.0
    for j = 0; j < p; j = j + 1 {
      out.data[i * (p + 1) + (j + 1)] = x.data[i * p + j]
    }
  }
  out
}

///|
/// Fit the linear regression to `(x, y)`. `x` is `n x p` and `y` is a
/// length-`n` vector. Returns the fitted `LinearRegression` with
/// `coef_[0] = intercept` and `coef_[1..] = slopes`.
///
/// At fit time we also cache the diagonal of `(X^T X + ridge I)^{-1}`
/// so that `covariance_diagonal()` (used by `DoubleMLBLP` for the
/// per-coefficient standard error) is `O(p)` instead of re-inverting
/// `X^T X` from scratch.
pub fn LinearRegression::fit(
  self : LinearRegression,
  x : Matrix,
  y : Array[Double],
) -> LinearRegression {
  require(x.nrows == y.length())
  let xa = augment_with_intercept(x)
  let xt = xa.transpose()
  let xtx = matmul(xt, xa)
  let xty = matvec(xt, y)
  let coef = solve_normal_eqs(xtx, xty, self.ridge)
  // cache (X^T X + ridge I)^{-1} diagonal for the per-coefficient SE
  let xtx_aug = add_ridge(xtx, self.ridge)
  let xtx_inv = inv_spd(xtx_aug)
  let p1 = coef.length()
  let xtx_inv_diag = Array::make(p1, 0.0)
  for j = 0; j < p1; j = j + 1 {
    xtx_inv_diag[j] = xtx_inv.data[j * p1 + j]
  }
  {
    ridge: self.ridge,
    coef_: coef,
    xtx_inv_diag,
    xtwx_inv_diag: [],
    fitted: true,
  }
}

///|
/// Return the diagonal of `(X^T W X + ridge I)^{-1}` cached from the
/// last `fit_weighted()` call. Empty array if the last fit was the
/// unweighted `fit()`. Used by `DoubleMLRDD` for the WLS-aware
/// intercept variance (TODO #11c.2).
pub fn LinearRegression::xtwx_inv_diag(
  self : LinearRegression,
) -> Array[Double] {
  require(self.fitted)
  self.xtwx_inv_diag
}

///|
/// Diagonal of the homoskedastic coefficient covariance matrix
/// `sigma^2 * (X^T X + ridge * I)^{-1}`. The caller supplies
/// `sigma^2 = RSS / (n - p)`; this separation keeps `LinearRegression`
/// ignorant of the response vector (and hence the residual sum of
/// squares). Returns a length-`(p + 1)` array whose `j`th entry is the
/// variance of `coef_[j]`. The corresponding SE is `sqrt(cov[j])`.
/// Used by `DoubleMLBLP` to recover the per-coefficient standard error
/// (Bug #5: previously every coefficient shared the same SE =
/// `sqrt(RSS / (n - p))`, ignoring the `(X^T X)^{-1}` scaling).
pub fn LinearRegression::covariance_diagonal(
  self : LinearRegression,
  sigma2 : Double,
) -> Array[Double] {
  require(self.fitted)
  require(sigma2 >= 0.0)
  let p1 = self.coef_.length()
  let out = Array::make(p1, 0.0)
  for j = 0; j < p1; j = j + 1 {
    out[j] = sigma2 * self.xtx_inv_diag[j]
  }
  out
}

///|
/// Weighted OLS fit. Solves `X^T W X beta = X^T W y` for a positive
/// diagonal weight matrix `W = diag(w)`. Used by `DoubleMLRDD` for
/// local-linear regression with the triangular kernel weights
/// (Bug #6: previously the weights were only applied to the variance
/// sum, so the point estimate ignored them). The covariance diagonal
/// is computed against the **unweighted** `X^T X` so the SE is the
/// standard homoskedastic-OLS form for the same design matrix — this
/// matches the upstream `RDD` reference for `cov_type='nonrobust'`.
///
/// The full weighted-Normal inverse `(X^T W X + ridge I)^{-1}` is also
/// cached for the WLS-aware SE (TODO #11c.2): the RDD delta-method
/// variance scales the weighted residual variance by the
/// `(X^T W X)^{-1}[0, 0]` (intercept) entry, which is the variance
/// formula for the WLS point estimate at the cutoff.
pub fn LinearRegression::fit_weighted(
  self : LinearRegression,
  x : Matrix,
  y : Array[Double],
  w : Array[Double],
) -> LinearRegression {
  require(x.nrows == y.length())
  require(x.nrows == w.length())
  let n = x.nrows
  let xa = augment_with_intercept(x)
  let p1 = xa.ncols
  // X^T W X (p1 x p1) and X^T W y (p1)
  let xtwx = Matrix::zeros(p1, p1)
  let xtwy = Array::make(p1, 0.0)
  for i = 0; i < n; i = i + 1 {
    let wi = w[i]
    for a = 0; a < p1; a = a + 1 {
      xtwy[a] = xtwy[a] + xa.data[i * p1 + a] * wi * y[i]
      for b = 0; b < p1; b = b + 1 {
        xtwx.data[a * p1 + b] = xtwx.data[a * p1 + b] +
          xa.data[i * p1 + a] * wi * xa.data[i * p1 + b]
      }
    }
  }
  let coef = solve_normal_eqs(xtwx, xtwy, self.ridge)
  // Cache both (X^T X + ridge I)^{-1} diagonal (for the BLP
  // homoskedastic-OLS SE) and (X^T W X + ridge I)^{-1} diagonal (for
  // the WLS-aware RDD SE in TODO #11c.2).
  let xt = xa.transpose()
  let xtx = matmul(xt, xa)
  let xtx_aug = add_ridge(xtx, self.ridge)
  let xtx_inv = inv_spd(xtx_aug)
  let xtx_inv_diag = Array::make(p1, 0.0)
  for j = 0; j < p1; j = j + 1 {
    xtx_inv_diag[j] = xtx_inv.data[j * p1 + j]
  }
  let xtwx_aug = add_ridge(xtwx, self.ridge)
  let xtwx_inv = inv_spd(xtwx_aug)
  let xtwx_inv_diag = Array::make(p1, 0.0)
  for j = 0; j < p1; j = j + 1 {
    xtwx_inv_diag[j] = xtwx_inv.data[j * p1 + j]
  }
  { ridge: self.ridge, coef_: coef, xtx_inv_diag, xtwx_inv_diag, fitted: true }
}

///|
/// Predict the response for new data `x`. `x` must have the same number
/// of columns as the data used at fit time.
pub fn LinearRegression::predict(
  self : LinearRegression,
  x : Matrix,
) -> Array[Double] {
  require(self.fitted)
  require(x.ncols == self.n_features())
  let xa = augment_with_intercept(x)
  matvec(xa, self.coef_)
}

///|
/// Heteroskedasticity-consistent (HC0) covariance diagonal of the
/// coefficient estimator. Computes the diagonal of the sandwich form
///   `cov(beta_hat) = (X'X)^{-1} (X' diag(e^2) X) (X'X)^{-1}`
/// where `e = y - X beta_hat` is the in-sample residual vector. The
/// diagonal entry `j` simplifies to
///   `cov_jj = sum_i ((M[j,:] · x_i)^2 * e_i^2)`
/// where `M = (X'X + ridge I)^{-1}` is the cached (X'X)^{-1}-with-ridge
/// matrix. This is `O(n * p^2)` and avoids materialising the full
/// sandwich matrix. Used by `DoubleMLBLP` for the per-coefficient
/// heteroskedasticity-robust SE (TODO #11c.1: matches the upstream
/// `statsmodels.OLS(cov_type='HC0')` default).
pub fn LinearRegression::sandwich_se(
  self : LinearRegression,
  x : Matrix,
  y : Array[Double],
) -> Array[Double] {
  require(self.fitted)
  require(x.nrows == y.length())
  let n = x.nrows
  let p1 = self.coef_.length()
  let xa = augment_with_intercept(x)
  let pred = matvec(xa, self.coef_)
  // Compute the full (X'X)^{-1} matrix once. We already have the
  // diagonal cached; for the sandwhich we need the J-th row (for each
  // coefficient j) so we re-invert. To keep this O(p^3) once and
  // O(n*p^2) for the diagonal, we invert here. (Cheap alternative:
  // solve `M[j,:] * (X'X + ridge I) = e_j` for each j via solve_spd,
  // avoiding the full inverse; but inv_spd is also Cholesky-based.)
  let xt = xa.transpose()
  let xtx = matmul(xt, xa)
  let xtx_aug = add_ridge(xtx, self.ridge)
  let m_full = inv_spd(xtx_aug)
  // For each j, compute cov_jj = sum_i (sum_a M[j,a] * xa[i,a])^2 * e_i^2
  let out = Array::make(p1, 0.0)
  for j = 0; j < p1; j = j + 1 {
    let mut acc = 0.0
    for i = 0; i < n; i = i + 1 {
      let mut mjx = 0.0
      for a = 0; a < p1; a = a + 1 {
        mjx = mjx + m_full.data[j * p1 + a] * xa.data[i * p1 + a]
      }
      let ei = y[i] - pred[i]
      acc = acc + mjx * mjx * ei * ei
    }
    out[j] = acc
  }
  out
}

///|
/// Trait for any learner that can be `fit` on `(x, y)` and `predict`
/// on a feature matrix. Used by the DML cross-fit helpers and the PLR
/// estimator.
pub trait Learner {
  fn fit(Self, Matrix, Array[Double]) -> Self
  fn predict(Self, Matrix) -> Array[Double]
}

///|
impl Learner for LinearRegression with fn fit(self, x, y) {
  self.fit(x, y)
}

///|
impl Learner for LinearRegression with fn predict(self, x) {
  self.predict(x)
}
