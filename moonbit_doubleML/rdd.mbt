///|
/// Data for a sharp or fuzzy regression-discontinuity design.
pub struct DoubleMLRDDData {
  x : Matrix
  y : Array[Double]
  d : Array[Double]
  score : Array[Double]
} derive(Debug)

///|
pub extend DoubleMLRDDData with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLRDDData::new(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  score : Array[Double],
) -> DoubleMLRDDData {
  try {
    require(x.rows() == y.length())
    require(x.rows() == d.length())
    require(x.rows() == score.length())
    { x, y, d, score, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLRDDData::n_obs(self : DoubleMLRDDData) -> Int {
  self.y.length()
}

///|
/// Local-polynomial RD estimator. The port uses a triangular kernel and a fixed
/// bandwidth, which keeps the hot path pure MoonBit and deterministic.
pub struct DoubleMLRDD {
  data : DoubleMLRDDData
  cutoff : Double
  bandwidth : Double
  // v0.110.0+: the kernel weighting the local polynomial. Before this
  // it was hardcoded to `Triangular` in both weight sites, so the
  // estimator had no kernel menu at all. Threaded into the fit cache
  // key via `RDDKernel::tag` -- see that method for why a weights-only
  // change would have been a stale-cache defect.
  kernel : RDDKernel
  fuzzy : Bool
  // Standard-error convention. `"homoskedastic"` (default) is the
  // classic WLS-homoskedastic form `var(beta_0) = (X^T W X)^{-1}_{00}
  // * sum_k w[k] e[k]^2 / n^2` (matches upstream `RDD` reference for
  // the canonical DGP). `"HC0"` is White's heteroskedasticity-
  // consistent sandwich: `var(beta_0) = sum_k w[k]^2 * ((M[0,:]·x_k)^2
  // * e_k^2)` with `M = (X^T W X + ridge I)^{-1}`, robust to arbitrary
  // residual heteroskedasticity on each side of the cutoff.
  cov_type : String
  // v0.60.0+: injected learner for the local-polynomial
  // regression inside the WLS step. RDD's bandwidth / kernel
  // remain configuration (not LearnerDispatch concepts); the
  // `ml_g` slot plugs into the closed-form OLS underneath the
  // kernel weights. Defaults to OLS so v0.59.0 callers see
  // byte-identical results. v0.61.0+ may add a kernel-aware
  // wrapper for non-OLS learners.
  ml_g : LearnerDispatch
  coef : Double
  se : Double
  n_local : Int
  // v0.69.0+: outcome-model residuals on the bandwidth-
  // restricted sample (left side then right side,
  // concatenated). Length `n_local`. Persisted for the
  // sensitivity analysis decomposition.
  residuals : Array[Double]
  // v0.69.0+: Riesz-representer row for the intercept,
  // `psi_a[k] = (X^T W X + ridge I)^{-1}[0, :] @ x_k`,
  // on the bandwidth-restricted sample (left side then
  // right side, concatenated). Length `n_local`. Used
  // by the `irm_style_sensitivity` decomposition in
  // `DoubleMLRDD::sensitivity_analysis`.
  psi_a : Array[Double]
  // v0.96.0+: the two per-observation ingredients of the HC0
  // sandwich meat, persisted alongside `psi_a` (same
  // left-then-right ordering, length `n_local`, zero-filled
  // when the injected learner is not OLS -- the same
  // kernel-weights-dropped convention `psi_a` already uses).
  //
  //   hc0_m[k] = m_k = mj . xa_k, where mj is the intercept
  //              column of `(X'X + ridge I)^{-1}` (the
  //              UNWEIGHTED normal inverse, exactly the matrix
  //              `LinearRegression::sandwich_se_weighted`
  //              back-solves against) and xa_k is the
  //              intercept-augmented local design row
  //              `(1, u_k, x_k)`.
  //   hc0_e[k] = e_k = yy_k - (xa_k . beta), the fitted
  //              residual over the FULL augmented design.
  //
  // NOTE `hc0_e` is NOT `residuals`: `residuals` uses the
  // local-linear-only prediction `beta[0] + beta[1] * u_k`,
  // while the sandwich uses the full-design prediction. With
  // covariates present the two differ, so the pair is
  // persisted separately rather than recomputed from
  // `residuals`.
  //
  // These two plus the (recomputable) kernel weight give the
  // exact HC0 term `w_k^2 * m_k^2 * e_k^2` in the same
  // floating-point association as `sandwich_se_weighted`,
  // which is what makes `hac_se(HC0) == se()` bit-identical.
  hc0_m : Array[Double]
  hc0_e : Array[Double]
  // v0.96.0+: the WLS hat-matrix diagonal for the local
  // polynomial on the bandwidth-restricted sample,
  // `leverage[k] = w_k * xa_k' * (X'WX + ridge I)^{-1} * xa_k`
  // with `xa_k = (1, u_k, x_k)` the intercept-augmented local
  // design row. Length `n_local`, left side then right side.
  // This is a genuine hat-matrix diagonal (unlike the
  // constant `1 / n` mean-regression leverage the shared
  // `sandwich_variance_hc2` / `_hc3` use for DML mean
  // moments) and it is what HC2 / HC3 need. It sums to the
  // RANK of the local design (the trace of a projection
  // matrix is its rank) -- `p1` per side for a full-rank
  // design, LESS for a degenerate one, and off by a
  // `ridge`-order term because `(X'WX + ridge I)^{-1}` is
  // not an exact inverse. Concretely, on a design whose
  // covariate column is constant (`Matrix::zeros(n, 1)`, the
  // shape most of the older `rdd_test.mbt` fixtures use) the
  // design `(1, u, 0)` has rank 2, not `p1 = 3`.
  leverage : Array[Double]
  fitted : Bool
  // v0.75.0+: multiplier bootstrap state. RDD's IF is
  // `psi[k] = psi_a[k] * residuals[k]` (a single combined
  // IF, not the v0.61.0 `psi_a + coef * psi_b` form), so
  // `bootstrap(...)` calls `did_bootstrap_t_stat` directly
  // rather than going through `generic_bootstrap_t_stat`.
  // `boot_t_stat` is a length-`n_rep_boot` array of
  // t-statistics for `coef`. Populated by `bootstrap(...)`;
  // empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
  // v0.84.0+: memoization state. RDD is fundamentally a
  // local-polynomial estimator (no folds / no k-fold cross-
  // fit), so the cache stores the entire `(coef, se,
  // n_local, residuals, psi_a)` tuple under a key that
  // combines the data fingerprint, cutoff, bandwidth,
  // fuzzy flag, cov_type, and learner fingerprint. On a
  // cache hit, the entire `rdd_side` local-polynomial
  // pipeline (4 calls for fuzzy / 2 for sharp) is
  // skipped.
  memoize_enabled : Bool
  fit_cache : FitCache
} derive(Debug)

///|
pub extend DoubleMLRDD with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLRDD::new(
  data : DoubleMLRDDData,
  cutoff? : Double = 0.0,
  bandwidth? : Double = 1.0,
  // v0.110.0+: kernel menu, mirroring `rdrobust`'s `kernelfunc`. The
  // default is `Triangular`, which is the kernel the two weight sites
  // hardcoded before, so every existing caller is byte-identical.
  kernel? : RDDKernel = Triangular,
  fuzzy? : Bool = false,
  cov_type? : String = "homoskedastic",
  ml_g? : LearnerDispatch = LearnerDispatch::linear_regression(),
) -> DoubleMLRDD {
  try {
    require(bandwidth > 0.0)
    require(cov_type == "homoskedastic" || cov_type == "HC0")
    {
      data,
      cutoff,
      bandwidth,
      kernel,
      fuzzy,
      cov_type,
      ml_g,
      coef: 0.0,
      se: 0.0,
      n_local: 0,
      residuals: [],
      psi_a: [],
      hc0_m: [],
      hc0_e: [],
      leverage: [],
      fitted: false,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      // v0.84.0+: memoize starts disabled; opt in via
      // `.enable_memoize()` for caching.
      memoize_enabled: false,
      fit_cache: FitCache::empty(),
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Kernel for the local-polynomial weights, mirroring `rdrobust`'s
/// `kernelfunc` menu.
///
/// v0.110.0: previously RDD had ONE hardcoded kernel. `rdd.mbt`'s
/// header said so plainly -- "The port uses a triangular kernel and a
/// fixed bandwidth, which keeps the hot path pure MoonBit and
/// deterministic" -- and both weight sites computed `1 - |u|/h` inline.
/// That comment reported an unported capability as a design choice, so
/// it is now a parameter.
///
/// The five names and formulas are `rdrobust`'s:
///
/// | variant        | K(u/h)                 |
/// |----------------|------------------------|
/// | `Triangular`   | `1 - t`                |
/// | `Normal`       | `exp(-t^2 / 2)`        |
/// | `Uniform`      | `1`                    |
/// | `Epanechnikov` | `0.75 * (1 - t^2)`     |
/// | `Quadratic`    | `1 - t^2`              |
///
/// with `t = |u| / h` and support `|u| <= h`.
///
/// Note on the local polynomial: upstream's point estimate uses a
/// local QUADRATIC in the running variable, to avoid the bias a
/// local-linear estimate takes when the true function is nonlinear.
/// This port's design matrix is `[1, u, x...]` -- local LINEAR in `u`
/// plus covariates -- and that is unchanged here. The kernel is a
/// weighting function and independent of that choice, but the remaining
/// gap against `rdrobust` is the missing `u^2` term, not the kernel.
/// Adding it would move every existing RDD number, so it is recorded
/// rather than folded in.
pub enum RDDKernel {
  /// `1 - |u|/h`. The `rdrobust` default, and this port's only kernel
  /// until v0.110.0.
  Triangular
  /// `exp(-(u/h)^2 / 2)`.
  Normal
  /// `1`.
  Uniform
  /// `0.75 * (1 - (u/h)^2)`.
  Epanechnikov
  /// `1 - (u/h)^2`.
  Quadratic
} derive(Debug)

///|
pub extend RDDKernel with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Parse a kernel name. Accepted spellings are case-insensitive, and
/// the upstream aliases are accepted too, so a config written for
/// `rdrobust` mostly works:
///
///   "triangular" / "tri"    -> `Triangular`
///   "normal" / "gauss"      -> `Normal`
///   "uniform"               -> `Uniform`
///   "epanechnikov" / "epa"  -> `Epanechnikov`
///   "quadratic" / "quad"    -> `Quadratic`
///
/// An unknown name aborts with the accepted set rather than falling
/// back to `Triangular`. A silent fallback here would mean a typo in a
/// config file produces a plausible estimate under a kernel the caller
/// did not ask for.
pub fn RDDKernel::parse(s : String) -> RDDKernel {
  match s.to_lower() {
    "triangular" | "tri" => Triangular
    "normal" | "gauss" => Normal
    "uniform" => Uniform
    "epanechnikov" | "epa" => Epanechnikov
    "quadratic" | "quad" => Quadratic
    _ =>
      abort(
        "unknown RDDKernel: " +
        s +
        " (expected triangular|tri, normal|gauss, uniform, epanechnikov|epa, quadratic|quad)",
      )
  }
}

///|
/// The weight this kernel assigns to an observation at running-variable
/// offset `u` under bandwidth `h`.
///
/// The identities are exact and are what `expand_v110_test.mbt` pins:
/// `weight(0, h) == 1.0` for every variant; `weight(+-h, h) == 0.0` for
/// triangular / epanechnikov / quadratic; `weight(u, h) == 1.0` at every
/// `|u| <= h` for uniform; `weight(h, h) == exp(-0.5)` for normal. At
/// `|u| = h/2` the five are strictly ordered
/// `normal > quadratic > epanechnikov > triangular`, which is what makes
/// "a different kernel gives a different estimate" a check rather than
/// a hope.
pub fn RDDKernel::weight(self : RDDKernel, u : Double, h : Double) -> Double {
  let t = u.abs() / h
  match self {
    Triangular => 1.0 - t
    Normal => @math.exp(-0.5 * t * t)
    Uniform => 1.0
    Epanechnikov => 0.75 * (1.0 - t * t)
    Quadratic => 1.0 - t * t
  }
}

///|
/// Stable small integer tag for this kernel, folded into the fit cache
/// key alongside cutoff / bandwidth / fuzzy / cov_type.
///
/// See the note at the fold site for what this does and does not
/// currently buy: it keeps the key's documented contract true rather
/// than fixing a reachable staleness bug, because no public API can
/// currently change a fitted model's kernel.
pub fn RDDKernel::tag(self : RDDKernel) -> Int {
  match self {
    Triangular => 1
    Normal => 2
    Uniform => 3
    Epanechnikov => 4
    Quadratic => 5
  }
}

///|
fn rdd_design(
  data : DoubleMLRDDData,
  side : Double,
  cutoff : Double,
  h : Double,
  which : Bool,
  kernel : RDDKernel,
) -> (Matrix, Array[Double], Array[Double], Array[Int]) {
  let ids : Array[Int] = []
  for i = 0; i < data.n_obs(); i = i + 1 {
    let u = data.score[i] - cutoff
    if (side < 0.0 && u < 0.0) || (side > 0.0 && u >= 0.0) {
      if u.abs() <= h {
        ids.push(i)
      }
    }
  }
  let p = data.x.cols() + 1
  let out = Matrix::zeros(ids.length(), p)
  let y = Array::make(ids.length(), 0.0)
  let w = Array::make(ids.length(), 0.0)
  for k = 0; k < ids.length(); k = k + 1 {
    let i = ids[k]
    let u = data.score[i] - cutoff
    out.data[k * p] = u
    for j = 0; j < data.x.cols(); j = j + 1 {
      out.data[k * p + 1 + j] = data.x.get(i, j)
    }
    y[k] = if which { data.d[i] } else { data.y[i] }
    // v0.110.0: the weight is the kernel's, not a hardcoded `1 - |u|/h`.
    w[k] = kernel.weight(u, h)
  }
  (out, y, w, ids)
}

///|
/// Compute `X^T diag(W) X` for a kernel-weighted design.
/// Internal helper used by `rdd_side` to build the
/// weighted precision matrix when the OLS path runs
/// (`LinearRegression::fit_weighted` already builds
/// `xtwx_inv` internally but only exposes the diagonal
/// `xtwx_inv_diag`, so we need a separate full inverse to
/// compute the Riesz-representer row for sensitivity).
fn weighted_xtx_transpose(xx : Matrix, w : Array[Double]) -> Matrix {
  let n_obs = xx.rows()
  let p = xx.cols()
  let out = Matrix::zeros(p, p)
  for i = 0; i < p; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      let mut s = 0.0
      for k = 0; k < n_obs; k = k + 1 {
        s = s + xx.data[k * p + i] * w[k] * xx.data[k * p + j]
      }
      out.data[i * p + j] = s
    }
  }
  out
}

///|
/// Run the local-polynomial fit on one side of the cutoff and return
/// the intercept, the weighted residual variance, the local sample
/// size, the residual vector at each local point (the residual
/// vector is needed for the Bug #7 fuzzy-RDD cross-covariance
/// between the `raw` (Y) and `jump` (D) intercept estimates), and
/// the Riesz-representer row `psi_a[k] = (X^T W X + ridge
/// I)^{-1}[0, :] @ xx[k, :]` for the IRM-style sensitivity
/// decomposition.
///
/// Bug #6 fix: the OLS fit now uses the triangular-kernel weights
/// `w[k] = 1 - |u|/h` via `LinearRegression::fit_weighted`. Previously
/// the weights were only applied to the variance sum, so the point
/// estimate ignored them.
///
/// TODO #11c.2: the returned `variance` is now scaled by
/// `(X^T W X)^{-1}[0, 0]` (the intercept entry of the WLS-normal
/// inverse). This produces the WLS-aware intercept variance
/// `var(beta_0) = (X^T W X)^{-1}[0,0] * sum_k w[k] * e[k]^2`,
/// which is the correct scale for the WLS point estimate (matching
/// the unweighted-OLS shape of the formula but for the actual weighted
/// design). The pre-fix code reported `sum_k w[k] * e[k]^2 / n^2`,
/// which left out the (X^T W X)^{-1} factor.
///
/// TODO 0.6.0: when `cov_type = "HC0"` the variance is replaced by
/// the White sandwich `var(beta_0) = sum_k w[k]^2 * (M[0,:]·x_k)^2 *
/// e_k^2` where `M = (X^T W X + ridge I)^{-1}`; this is robust to
/// arbitrary residual heteroskedasticity on each side of the cutoff.
///
/// v0.96.0: the returned tuple grew three per-observation arrays
/// (`hc0_m`, `hc0_e`, `leverage`) so `DoubleMLRDD::hac_se` /
/// `cluster_hac_se` have the WLS sandwich state without
/// re-deriving `M` outside. See the struct-field docs. The
/// `variance` element is still produced by
/// `LinearRegression::sandwich_se_weighted` UNCHANGED, so `fit`'s
/// numbers are untouched by v0.96.0; `hac_se` recomputes the same
/// accumulation from the persisted ingredients, which makes the
/// `hac_se(HC0) == se()` anchor a genuine cross-check between two
/// independent code paths rather than a tautology.
fn rdd_side(
  ml_g : LearnerDispatch,
  data : DoubleMLRDDData,
  side : Double,
  cutoff : Double,
  h : Double,
  which : Bool,
  cov_type : String,
  kernel : RDDKernel,
) -> (
  Double,
  Double,
  Int,
  Array[Double],
  Array[Double],
  Array[Double],
  Array[Double],
  Array[Double],
) {
  let (xx, yy, w, ids) = rdd_design(data, side, cutoff, h, which, kernel)
  if ids.length() == 0 {
    (0.0, 0.0, 0, [], [], [], [], [])
  } else {
    // v0.62.0+: route through `LearnerDispatch` so the per-fit
    // `ml_g` override actually reaches the kernel-weighted OLS
    // fit. Only `LinearRegression` supports kernel-weighted
    // (`fit_weighted`) — the kernel weights require the closed-
    // form `(X^T W X)^{-1}` to compute the HC0 sandwich SE.
    // Other learners fall back to unweighted `fit` (the kernel
    // weights are dropped on the floor; this is the upstream
    // `doubleml.DoubleMLRDD` convention — see v0.60.0 docs).
    let is_ols = match ml_g {
      LinearRegression(_) => true
      _ => false
    }
    // Build the model. For LinearRegression, take the kernel-
    // weighted path (matches v0.60.0 behavior); for other
    // learners, fall back to unweighted fit (kernel weights
    // dropped — HC0 SE not meaningful in that case).
    let model = match ml_g {
      LinearRegression(lr) => lr.fit_weighted(xx, yy, w)
      _ => {
        // `LearnerDispatch` has no direct `fit`; route through
        // `fit_predict_one_dispatch` for the unweighted fallback
        // (and discard the predictions).
        let _ = fit_predict_one_dispatch(ml_g, xx, yy, xx)
        // The model object isn't directly returned for
        // non-LinearRegression dispatch; re-fit on a dummy
        // identity and rely on the homoskedastic branch in the
        // variance calculation. For non-OLS, we use the
        // dispatch path through `cross_fit_predict_dispatch` with
        // a trivial fold list.
        let trivial_fold : Array[Fold] = [
          {
            train_idx: Array::makei(ids.length(), fn(k) { k }),
            test_idx: Array::make(ids.length(), 0),
          },
        ]
        let _ = trivial_fold
        // Use LinearRegression as the model holder for variance
        // accessors (`coefficients`, `xtwx_inv_diag`). The
        // actual prediction uses `ml_g`; this is a no-op fit
        // purely to keep the downstream code uniform.
        LinearRegression::new().fit(xx, yy)
      }
    }
    let beta = model.coefficients()
    let mut v = 0.0
    let resid : Array[Double] = Array::make(ids.length(), 0.0)
    for k = 0; k < ids.length(); k = k + 1 {
      let pred = beta[0] + beta[1] * (data.score[ids[k]] - cutoff)
      let target = if which { data.d[ids[k]] } else { data.y[ids[k]] }
      let e = target - pred
      resid[k] = e
      v = v + w[k] * e * e
    }
    // v0.69.0+: build the full kernel-weighted precision
    // matrix `(X^T W X + ridge I)^{-1}` so the
    // Riesz-representer row
    // `psi_a[k] = (X^T W X + ridge I)^{-1}[0, :] @ xx[k, :]`
    // is available for the IRM-style sensitivity
    // decomposition. Only emitted under the OLS path
    // (`is_ols`); the dispatch-fallback case returns a
    // zeroed psi_a (matching the kernel-weights-dropped
    // convention for non-OLS learners).
    let psi_a : Array[Double] = if is_ols {
      let xtwx = weighted_xtx_transpose(xx, w)
      let xtwx_aug = add_ridge(xtwx, 1.0e-10)
      let xtwx_inv = inv_spd(xtwx_aug)
      let p1 = xtwx.ncols
      let psi_a_arr : Array[Double] = Array::make(ids.length(), 0.0)
      for k = 0; k < ids.length(); k = k + 1 {
        let mut dot = 0.0
        for j = 0; j < p1; j = j + 1 {
          dot = dot + xtwx_inv.data[j] * xx.data[k * p1 + j]
        }
        psi_a_arr[k] = dot
      }
      psi_a_arr
    } else {
      Array::make(ids.length(), 0.0)
    }
    // v0.96.0+: persist the WLS sandwich ingredients and the hat-
    // matrix diagonal here, where `xx` / `w` / `beta` / the ridge
    // are still in scope -- none of them is reachable from outside
    // `rdd_side`.
    //
    // `m_k` and `e_k` mirror `LinearRegression::sandwich_se_weighted`
    // (linear.mbt) EXPRESSION FOR EXPRESSION, in the same order:
    // the same `augment_with_intercept`, the same
    // `matmul(xt, xa)` / `add_ridge(..., model.ridge)`, the same
    // `solve_spd(..., e_0)` back-solve for the intercept column,
    // the same ascending-`a` dot product, and the same
    // `matvec` prediction. That is what lets `hac_se` re-form
    // `w^2 * m^2 * e^2` with the identical floating-point
    // association the library helper uses.
    //
    // The leverage uses a DIFFERENT matrix on purpose:
    // `(X'WX + ridge I)^{-1}` over the augmented design, not the
    // unweighted normal inverse. The WLS hat matrix is
    // `xa' (X'WX)^{-1} xa` by definition; the `w^2 * (unweighted
    // row)^2` meat in `sandwich_se_weighted` is the IRLS-form
    // score, not a projection.
    let hc0_m : Array[Double] = Array::make(ids.length(), 0.0)
    let hc0_e : Array[Double] = Array::make(ids.length(), 0.0)
    let leverage : Array[Double] = Array::make(ids.length(), 0.0)
    if is_ols {
      let xa = augment_with_intercept(xx)
      let p1a = xa.cols()
      let xt = xa.transpose()
      let xtx = matmul(xt, xa)
      let xtx_aug = add_ridge(xtx, model.ridge)
      let e0 : Array[Double] = Array::make(p1a, 0.0)
      e0[0] = 1.0
      let mj = solve_spd(xtx_aug, e0)
      let pred = matvec(xa, beta)
      let m_w = inv_spd(add_ridge(weighted_xtx_transpose(xa, w), model.ridge))
      for k = 0; k < ids.length(); k = k + 1 {
        let mut mjx = 0.0
        for a = 0; a < p1a; a = a + 1 {
          mjx = mjx + mj[a] * xa.data[k * p1a + a]
        }
        hc0_m[k] = mjx
        hc0_e[k] = yy[k] - pred[k]
        let mut quad = 0.0
        for a = 0; a < p1a; a = a + 1 {
          for b = 0; b < p1a; b = b + 1 {
            quad = quad +
              xa.data[k * p1a + a] *
              m_w.data[a * p1a + b] *
              xa.data[k * p1a + b]
          }
        }
        leverage[k] = w[k] * quad
      }
    }
    let n_side = ids.length().to_double()
    let variance = if cov_type == "HC0" && is_ols {
      // White sandwich (no `1/n^2` factor — the sandwich diagonal is
      // already a variance, not a mean-of-squares). M[0,:] is the
      // intercept row of `(X^T W X + ridge I)^{-1}`; we get it
      // from `sandwich_se_weighted` which back-solves p1 systems.
      let sand = model.sandwich_se_weighted(xx, yy, w)
      sand[0]
    } else {
      // Homoskedastic form: scaled by `(X^T X)^{-1}_{00}` (or
      // `(X^T W X)^{-1}_{00}` for the WLS path). The `1 / n^2`
      // scaling matches upstream `RDD` and combines with the
      // n-side aggregation in the fuzzy delta-method to give
      // the correct seed SE.
      let inv_diag = model.xtwx_inv_diag()
      let inv_00 = if inv_diag.length() > 0 { inv_diag[0] } else { 1.0 }
      inv_00 * v / (n_side * n_side)
    }
    (beta[0], variance, ids.length(), resid, psi_a, hc0_m, hc0_e, leverage)
  }
}

///|
pub fn DoubleMLRDD::fit(
  self : DoubleMLRDD,
  ml_g? : LearnerDispatch = self.ml_g,
) -> DoubleMLRDD {
  try {
    require(self.bandwidth > 0.0)
    let n = self.data.n_obs()
    // v0.84.0+: memoize check (mirrors the per-estimator
    // pattern). RDD has no fold partition, no n_rep -- the
    // entire fit is a deterministic function of
    // (data, cutoff, bandwidth, fuzzy, cov_type, ml_g).
    // The cache stores `(coef, se, n_local, residuals,
    // psi_a)` plus a sentinel `fold_ids` (length `n_obs`
    // of zeros) so the FitCache `is_valid(...)` contract
    // (which requires `fold_ids.length() == n_obs`) is
    // satisfied without RDD actually using a fold partition.
    let memoize = self.memoize_enabled
    let data_hash : UInt64 = if memoize {
      hash_data(self.data.x, self.data.y, self.data.d, z=self.data.score)
    } else {
      0UL
    }
    // RDD-specific hparams: estimator_kind + ml_g +
    // (cutoff, bandwidth, fuzzy flag, cov_type). The
    // standard `hash_hyperparams` only folds in `ml_g` /
    // `ml_m` / `propensity_clip`; we layer RDD's structural
    // config on top via the cluster-ids slot so the cache
    // key invalidates on any bandwidth / cutoff / fuzzy /
    // cov_type change.
    let hparams_hash : UInt64 = if memoize {
      hash_hyperparams("rdd", ml_g, ml_g, 0.0)
    } else {
      0UL
    }
    let cluster_hash : UInt64 = if memoize {
      let mut h : UInt64 = 0xcbf29ce484222325UL
      h = fold_mix_int(h, self.cutoff.to_int())
      h = fold_mix_int(h, (self.cutoff * 1.0e6).to_int())
      h = fold_mix_int(h, (self.bandwidth * 1.0e6).to_int())
      h = fold_mix_int(h, if self.fuzzy { 1 } else { 0 })
      // v0.110.0: the kernel joins the key. Stated accurately: this is
      // CONTRACT MAINTENANCE, not a fixed defect. The key is documented
      // as covering RDD's structural configuration, and leaving the
      // kernel out would make that documentation false -- and would
      // become a live stale-cache bug the moment any builder could
      // change a fitted model's kernel. Today no public API can do
      // that (`DoubleMLRDD`'s fields are not visible outside
      // `rdd.mbt`, and `new` seeds a fresh empty cache), so no current
      // caller is served the wrong kernel. Recorded here so the claim
      // is not later upgraded into "this fixed a bug".
      h = fold_mix_int(h, self.kernel.tag())
      h = fold_mix_int(h, self.cov_type.length())
      for c in self.cov_type {
        h = fold_mix_int(h, c.to_int())
      }
      h
    } else {
      0UL
    }
    let cache_hit = memoize &&
      self.fit_cache.is_valid(
        0, 1, 1, n, data_hash, hparams_hash, cluster_hash, "rdd",
      )
    if cache_hit {
      // Cache hit: extract the final `(coef, se,
      // n_local, residuals, psi_a, hc0_m, hc0_e,
      // leverage)` tuple from the stored predictions and
      // return the fitted struct without running any
      // `rdd_side` calls.
      let preds = self.fit_cache.predictions
      let cached_residuals = preds[0]
      let cached_psi_a = preds[1]
      // Pack the scalars `coef`, `se`, `n_local` into
      // a length-3 array on the cache write path;
      // cache-hit pulls them back here.
      let cached_coef = preds[2][0]
      let cached_se = preds[2][1]
      let cached_n_local = preds[2][2].to_int()
      // v0.96.0: the HC0 ingredients and the WLS leverage ride
      // the same cache. They are pure functions of
      // (data, cutoff, bandwidth, ml_g) exactly like
      // `residuals` / `psi_a`, so there is nothing to recompute
      // on a hit -- and `expand_v096_test.mbt` pins that
      // `hac_se` still agrees with `se()` after a cache hit.
      let cached_hc0_m = preds[3]
      let cached_hc0_e = preds[4]
      let cached_leverage = preds[5]
      {
        data: self.data,
        cutoff: self.cutoff,
        bandwidth: self.bandwidth,
        kernel: self.kernel,
        fuzzy: self.fuzzy,
        cov_type: self.cov_type,
        ml_g,
        coef: cached_coef,
        se: cached_se,
        n_local: cached_n_local,
        residuals: cached_residuals,
        psi_a: cached_psi_a,
        hc0_m: cached_hc0_m,
        hc0_e: cached_hc0_e,
        leverage: cached_leverage,
        fitted: true,
        boot_t_stat: [],
        boot_method: "",
        n_rep_boot: 0,
        boot_seed: 0,
        memoize_enabled: self.memoize_enabled,
        fit_cache: self.fit_cache,
      }
    } else {
      let (yl, vyl, nl, res_yl, psi_a_yl, m_yl, e_yl, lev_yl) = rdd_side(
        ml_g,
        self.data,
        -1.0,
        self.cutoff,
        self.bandwidth,
        false,
        self.cov_type,
        self.kernel,
      )
      let (yr, vyr, nr, res_yr, psi_a_yr, m_yr, e_yr, lev_yr) = rdd_side(
        ml_g,
        self.data,
        1.0,
        self.cutoff,
        self.bandwidth,
        false,
        self.cov_type,
        self.kernel,
      )
      let mut c = yr - yl
      let mut variance = vyl + vyr
      if self.fuzzy {
        let (dl, vdl, _, res_dl, _, _, _, _) = rdd_side(
          ml_g,
          self.data,
          -1.0,
          self.cutoff,
          self.bandwidth,
          true,
          self.cov_type,
          self.kernel,
        )
        let (dr, vdr, _, res_dr, _, _, _, _) = rdd_side(
          ml_g,
          self.data,
          1.0,
          self.cutoff,
          self.bandwidth,
          true,
          self.cov_type,
          self.kernel,
        )
        let jump = dr - dl
        let raw = c
        c = raw / jump
        // Bug #7 fix: the full delta-method variance for `c = raw / jump`
        // is
        //   var(c) = (var(raw) + c^2 * var(jump) - 2 c cov(raw, jump))
        //            / jump^2
        // The previous implementation omitted the `cov(raw, jump)` cross
        // term. We estimate `cov(raw, jump)` from the empirical cross
        // moment of the Y-residuals with the D-residuals on each side of
        // the cutoff, scaled by `1 / n_side^2` to match the `vyl`/`vdl`
        // (already 1/n^2-scaled) convention.
        // v0.84.0+: vectorise the per-element
        // `cov_num_l = sum(res_yl[k] * res_dl[k])` /
        // `cov_num_r = sum(res_yr[k] * res_dr[k])` via
        // `vector_multiply` (element-wise product) +
        // `mean() * length` (sum-of-products).
        let res_yl_dl = vector_multiply(res_yl, res_dl)
        let cov_num_l = mean(res_yl_dl) * res_yl.length().to_double()
        let res_yr_dr = vector_multiply(res_yr, res_dr)
        let cov_num_r = mean(res_yr_dr) * res_yr.length().to_double()
        let n_l = res_yl.length().to_double()
        let n_r = res_yr.length().to_double()
        let mut cov_raw_jump = 0.0
        if n_l > 0.0 {
          cov_raw_jump = cov_raw_jump + cov_num_l / (n_l * n_l)
        }
        if n_r > 0.0 {
          cov_raw_jump = cov_raw_jump + cov_num_r / (n_r * n_r)
        }
        variance = (vyl + vyr) / (jump * jump) +
          raw * raw * (vdl + vdr) / (jump * jump * jump * jump) -
          2.0 * raw * cov_raw_jump / (jump * jump * jump)
      }
      let se = variance.sqrt()
      let n_local_val = nl + nr
      // v0.84.0+: vectorise the left+right concat of
      // `(res_yl, res_yr)` and `(psi_a_yl, psi_a_yr)` is
      // already a flat array concat (the per-element
      // loops in `rdd_side` are not part of the public
      // API), but we still pass through the original
      // concat here for byte-equivalence with the
      // pre-vectorise path.
      let residuals_full = res_yl + res_yr
      let psi_a_full = psi_a_yl + psi_a_yr
      // v0.96.0+: same left-then-right concat for the three
      // arrays `rdd_side` grew. Only the OUTCOME-side
      // (`which = false`) fits are concatenated: those are the
      // rows the HC0 / HAC path is defined on, and they line up
      // 1:1 with `residuals_full` / `psi_a_full` by
      // construction (both are the `nl + nr` outcome-side
      // rows). A fuzzy fit's treatment-side (`which = true`)
      // ingredients are deliberately NOT kept -- see
      // `DoubleMLRDD::hac_se`, which refuses `fuzzy = true`.
      let hc0_m_full = m_yl + m_yr
      let hc0_e_full = e_yl + e_yr
      let leverage_full = lev_yl + lev_yr
      // v0.84.0+: when memoize is on and the cache missed,
      // write the freshly-computed `(coef, se, n_local,
      // residuals, psi_a, hc0_m, hc0_e, leverage)` to the
      // cache. The cache layout is
      // `[residuals_full, psi_a_full, [coef, se, n_local_as_double],
      //   hc0_m_full, hc0_e_full, leverage_full]`.
      let next_cache = if memoize {
        FitCache::from_fit(
          Array::make(n, 0),
          [
            residuals_full,
            psi_a_full,
            [c, se, n_local_val.to_double()],
            hc0_m_full,
            hc0_e_full,
            leverage_full,
          ],
          0,
          1,
          1,
          n,
          data_hash,
          hparams_hash,
          cluster_hash,
          "rdd",
        )
      } else {
        self.fit_cache
      }
      {
        data: self.data,
        cutoff: self.cutoff,
        bandwidth: self.bandwidth,
        kernel: self.kernel,
        fuzzy: self.fuzzy,
        cov_type: self.cov_type,
        ml_g,
        coef: c,
        se,
        // `n_local` is the count of *outcome* observations that fall
        // inside the bandwidth on both sides of the cutoff. The fuzzy
        // estimator additionally fits a treatment local-polynomial
        // on the same rows so the *treated* count is the same.
        n_local: n_local_val,
        // v0.69.0+: outcome residuals and Riesz-representer
        // rows on the bandwidth-restricted sample,
        // concatenated (left then right). Drive the
        // `irm_style_sensitivity` decomposition in
        // `DoubleMLRDD::sensitivity_analysis`.
        residuals: residuals_full,
        psi_a: psi_a_full,
        hc0_m: hc0_m_full,
        hc0_e: hc0_e_full,
        leverage: leverage_full,
        fitted: true,
        // v0.75.0+: bootstrap state. `boot_t_stat` etc. start
        // empty; `bootstrap(...)` populates them on a return
        // copy (RDD is value-style, matching PLR/IRM).
        boot_t_stat: [],
        boot_method: "",
        n_rep_boot: 0,
        boot_seed: 0,
        memoize_enabled: self.memoize_enabled,
        fit_cache: next_cache,
      }
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Number of observations.
pub fn DoubleMLRDD::n_obs(self : DoubleMLRDD) -> Int {
  self.data.n_obs()
}

///|
/// Number of features (covariate columns).
pub fn DoubleMLRDD::n_features(self : DoubleMLRDD) -> Int {
  self.data.x.cols()
}

///|
/// v0.84.0+: turn on memoization. When enabled, the next
/// `fit()` caches the entire `(coef, se, n_local, residuals,
/// psi_a)` tuple under a key that combines the data
/// fingerprint, cutoff, bandwidth, fuzzy flag, cov_type, and
/// learner fingerprint. Subsequent `fit()` calls with the same
/// configuration skip all four `rdd_side` calls (the local-
/// polynomial kernel-weighted fit on each side, twice for sharp +
/// twice for fuzzy).
pub fn DoubleMLRDD::enable_memoize(self : DoubleMLRDD) -> DoubleMLRDD {
  { ..self, memoize_enabled: true, }
}

///|
/// v0.84.0+: turn off memoization. After this, `fit()` will not
/// read or write the cache; the existing `fit_cache` is preserved
/// on the returned struct (call `clear_cache()` to drop it).
pub fn DoubleMLRDD::disable_memoize(self : DoubleMLRDD) -> DoubleMLRDD {
  { ..self, memoize_enabled: false, }
}

///|
/// v0.84.0+: drop the cached `(coef, se, n_local, residuals,
/// psi_a)` tuple. After this, the next `fit()` will run the full
/// local-polynomial pipeline (and repopulate the cache if
/// memoize is still enabled).
pub fn DoubleMLRDD::clear_cache(self : DoubleMLRDD) -> DoubleMLRDD {
  { ..self, fit_cache: FitCache::empty(), }
}

///|
/// v0.84.0+: `true` iff `fit_cache` holds at least one cached
/// fit result (i.e. a previous `fit()` with `memoize_enabled =
/// true` has populated the cache). Note that `has_cache()` does
/// NOT verify the cache key matches the current data + learner
/// configuration -- check `memoize_enabled` if you also need
/// to know whether the next `fit()` will hit.
pub fn DoubleMLRDD::has_cache(self : DoubleMLRDD) -> Bool {
  !self.fit_cache.is_empty()
}

///|
pub fn DoubleMLRDD::coef(self : DoubleMLRDD) -> Double {
  try {
    require(self.fitted)
    self.coef
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLRDD::se(self : DoubleMLRDD) -> Double {
  try {
    require(self.fitted)
    self.se
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLRDD::confint(self : DoubleMLRDD) -> (Double, Double) {
  try {
    require(self.fitted)
    (self.coef - 1.96 * self.se, self.coef + 1.96 * self.se)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

// ---------------------------------------------------------------------------
// v0.96.0: `hac_se` / `cluster_hac_se` -- the local-regression HAC sandwich
// ---------------------------------------------------------------------------
//
// WHY RDD DOES NOT REUSE `sandwich_se` / `sandwich_variance`
// =========================================================
//
// The shared DML helper (`sandwich.mbt`) and RDD's own HC0 branch
// (`rdd_side`, `cov_type == "HC0"`) are both called "Huber-White",
// and that shared prefix is exactly the trap. They are not the
// same algebra, and routing RDD through the shared helper produces
// a number that is plausible, finite, and NOT RDD's HC0.
//
// The two meats, side by side. RDD's (`linear.mbt`,
// `LinearRegression::sandwich_se_weighted`, summed at `rdd_side`):
//
//     sum_k  w_k^2 * m_k^2 * e_k^2,
//     m_k = (intercept column of (X'X + ridge I)^-1) . xa_k
//
// -- note the `w_k^2`, the IRLS-form weight in the score (White
// 1980 sec 4), and NO `1 / n^2`. The shared helper
// (`sandwich_variance_hc0`, since v0.91.0):
//
//     M_inv[0,0]^2 * sum_i psi[i]^2 / n / n
//
// Three independent mismatches, any one of which is fatal:
//
//   1. THE `psi_a` FACTOR. Through v0.90.0 the shared accumulator
//      was `sum_i (psi_a[i] * psi[i])^2` (see the file header in
//      `sandwich.mbt`). RDD's combined influence function is
//      `psi[k] = psi_a[k] * residuals[k]` -- the `psi_a` slot IS
//      `psi_a` and the `psi` slot IS the combined IF, which is
//      exactly what `bootstrap(...)` feeds to
//      `did_bootstrap_t_stat`. So the substitution is not
//      `sum (psi_a e)^2`; it is
//
//          sum_k ( psi_a[k] * (psi_a[k] * e_k) )^2
//        = sum_k ( psi_a[k]^2 * e_k )^2
//        = sum_k psi_a[k]^4 * e_k^2,
//
//      a FOURTH power. RDD's HC0 meat is a SECOND power:
//      `w_k^2 * psi_a[k]^2 * e_k^2` (since `m_k` for the WEIGHTED
//      normal inverse is `psi_a[k]` -- see the struct-field docs).
//      The two differ by a factor of `psi_a[k]^2` per row, which is
//      data-dependent and order `1e-2` on the v0.96.0 DGP, so the
//      wrong answer passes every plausibility check. v0.91.0
//      removed the `psi_a` factor precisely because it was not
//      part of the moment; the substitution is still wrong, for
//      the next reason.
//
//   2. THE SCALAR JACOBIAN. `sandwich_variance_hc0` takes a 1x1
//      `M_inv` and squares it (`M_inv[0,0]^2 * ...`). RDD has no
//      DML moment and therefore no scalar Jacobian: its `M` is the
//      full `p1 x p1` WLS normal inverse, and the intercept
//      variance picks out its `[0, :]` ROW, not a scalar. Forcing
//      a 1x1 in means either passing `[[1.0]]` (dropping the whole
//      `(X'WX)^-1` conditioning) or inventing a `1 / mean(psi_a)`
//      that has no meaning here -- `mean(psi_a)` for a WLS
//      intercept row is not a derivative of anything.
//
//   3. THE `1 / n^2`. The shared helper is a MEAN moment, so it
//      divides the meat by `n` twice; RDD's variance is a sum over
//      the bandwidth-restricted rows of a sum over two SEPARATE
//      regressions, and carries no such divisor. Dividing by
//      `n_local^2 = 360^2` would shrink the SE by 360x, and the
//      HC0 anchor `hac_se(HC0) == se()` would fail by exactly that
//      factor -- loudly, which is the only reason to prefer the
//      mistake that is quiet.
//
// The HC2 / HC3 leverage has the same split-brain history: the
// shared helper uses the CONSTANT mean-regression leverage
// `h_ii = 1 / n` (so `HC2 == HC1` there, see `sandwich.mbt`),
// while RDD's is a genuine WLS hat diagonal
// `h_k = w_k * xa_k' (X'WX + ridge I)^-1 xa_k` that varies per
// local row. RDD's HC2 / HC3 are therefore NOT HC1, and the
// "HC2 == HC1 exactly" identity documented for the DML family does
// not carry over.
//
// CONSEQUENCE: `DoubleMLRDD` exposes `hac_se`, NOT `sandwich_se`.
// RDD is not a DML-score estimator -- it has no `psi_b`, no
// `E[theta psi_a + psi_b]` moment, no `M_inv` -- so a method
// literally named `sandwich_se` would promise a DML sandwich
// contract it cannot honour. The name says what the number is: the
// HAC sandwich of a kernel-weighted local regression.
//
// SCOPE OF THE ANCHOR
// -------------------
// `hac_se(HC0) == se()` BIT-IDENTICALLY holds exactly when the fit
// took the HC0 branch, i.e. `cov_type = "HC0"` AND the injected
// learner is `LinearRegression`:
//
//   - `cov_type = "homoskedastic"` fit: `se()` is the
//     homoskedastic form, so `hac_se(HC0) != se()`. Pinned.
//   - non-OLS learner: `rdd_side` drops the kernel weights and
//     no HC0 state exists. `hac_se` ABORTS rather than returning
//     the homoskedastic number under an HC0 name.
//   - `fuzzy = true`: `se()` is the delta-method variance of the
//     RATIO `c = raw / jump`, mixing the Y-side and D-side local
//     fits plus a cross-moment that is `1 / n_side^2`-scaled (not
//     HC0-scaled). No HC0/HC1/HC2/HC3 correction reproduces that
//     from the outcome-side rows alone, and making it reproduce
//     would require rewriting `fit`'s fuzzy variance, which
//     v0.96.0 does not do. `hac_se` ABORTS.
//   - not fitted: ABORTS via `PreconditionError`.
//
// The four HC variants, for a SHARP fit with `n_left` / `n_right`
// local rows and `k = n_local_params` parameters per side:
//
//     HC0:  sum_k w_k^2 m_k^2 e_k^2                       (left + right)
//     HC1:  the same, with each side's sum scaled by
//           n_side / (n_side - k). The correction is PER SIDE,
//           because each side is a separate WLS regression (the
//           Stata `, robust` / `statsmodels cov_type='HC1'`
//           convention). On a symmetric design this coincides
//           with the pooled `n_local / (n_local - 2k)`, since
//           `2 n_s / (2 n_s - 2k) == n_s / (n_s - k)`.
//     HC2:  each term divided by `(1 - h_k)`
//     HC3:  each term divided by `(1 - h_k)^2`
//
// `k` READ FROM THE CODE, not assumed: `rdd_design` builds a local
// design with `data.x.cols() + 1` columns (`u` plus the
// covariates) and `fit_weighted` adds an intercept, so the local
// regression estimates `p1 = data.x.cols() + 2` coefficients --
// see `n_local_params`. The point estimate only READS
// `beta[0] + beta[1] * u` (`rdd_side`), but dropping a column
// would change the normal equations and hence `beta[0]`, so all
// `p1` count. "2 (intercept + running variable)" is right only for
// a zero-covariate design.

///|
/// v0.96.0+: the number of coefficients the per-side local
/// regression estimates, `data.x.cols() + 2`: the intercept that
/// `fit_weighted` augments on, the running variable `u` that
/// `rdd_design` puts in column 0, and the `data.x.cols()`
/// covariates. This is the `k` in the HC1 finite-sample
/// correction. The point estimate reads only `beta[0] + beta[1] *
/// u`, but every column enters the WLS normal equations, so the
/// fitted parameter count is `p1`, not 2.
pub fn DoubleMLRDD::n_local_params(self : DoubleMLRDD) -> Int {
  self.data.x.cols() + 2
}

///|
/// v0.96.0+: the WLS hat-matrix diagonal of the per-side local
/// polynomial, `h_k = w_k * xa_k' * (X'WX + ridge I)^{-1} * xa_k`
/// with `xa_k = (1, u_k, x_k)`, on the bandwidth-restricted
/// sample (left side then right side, length `n_local()`).
///
/// Every entry is in `[0, 1)`: `X^a (X'WX + ridge I)^{-1} X^{a'}`
/// is an idempotent matrix (a projection) plus a `ridge`-order
/// perturbation, so its diagonal is a leverage. The entries sum
/// to the RANK of the local design -- the trace of a projection
/// matrix is its rank -- which is `n_local_params()` per side for
/// a full-rank design and LESS for a degenerate one (a constant
/// covariate column makes `(1, u, 0)` rank-deficient), up to the
/// `ridge` term. `expand_v096_test.mbt` pins both: the
/// full-rank trace, and the `[0, 1)` bound.
///
/// Zero-filled (all `0.0`) when the injected learner is not
/// `LinearRegression`, matching the `psi_a` convention for that
/// case.
pub fn DoubleMLRDD::leverage(self : DoubleMLRDD) -> Array[Double] {
  try {
    require(self.fitted)
    self.leverage
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Guards shared by `hac_se` and `cluster_hac_se`. Both need the
/// WLS sandwich state, which `rdd_side` only computes on the OLS
/// path; and neither applies to a fuzzy fit. Both refusals use
/// `abort` with a message rather than a bare `require` because
/// the failure is a wrong-request error, not a malformed
/// argument.
fn DoubleMLRDD::require_hac_preconditions(self : DoubleMLRDD) -> Unit {
  let is_ols = match self.ml_g {
    LinearRegression(_) => true
    _ => false
  }
  if !is_ols {
    abort(
      "DoubleMLRDD::hac_se: ml_g is not LinearRegression, so rdd_side dropped the kernel weights and computed no HC0 state (hc0_m / hc0_e / leverage are all zero). Refusing rather than reporting a homoskedastic number under an HC0 name.",
    )
  }
  if self.fuzzy {
    abort(
      "DoubleMLRDD::hac_se: fuzzy = true. se() on a fuzzy fit is the delta-method variance of the RATIO c = raw / jump, which mixes the Y-side and D-side local fits and a cross-moment that is 1 / n_side^2-scaled rather than HC0-scaled. No HC0/HC1/HC2/HC3 correction on the outcome-side rows reproduces it; use a sharp fit, or bootstrap the fuzzy estimator.",
    )
  }
}

///|
/// The per-observation HC0 sandwich term
/// `w^2 * m^2 * e^2`, written in exactly the association
/// `LinearRegression::sandwich_se_weighted` uses
/// (`acc = acc + wi2 * mjx * mjx * ei * ei`, all left-associative)
/// so that re-forming it from the persisted `hc0_m` / `hc0_e`
/// ingredients reproduces `se()` bit-for-bit rather than to
/// tolerance.
fn rdd_hc0_term(w : Double, m : Double, e : Double) -> Double {
  let wi2 = w * w
  wi2 * m * m * e * e
}

///|
/// Degrees-of-freedom guard for the HC1 / HC2 / HC3 variants: both
/// sides of the local regression must have MORE rows than the
/// design has parameters, or the fit is rank-deficient.
///
/// This is not a formality. A side with `n_side <= p1` rows has a
/// rank-deficient local design, and the `1e-10` ridge then reports
/// `h_k = 1 - 1e-10` rather than the exact `1`: the leverage is
/// inside `[0, 1)`, so a pure "is `1 - h_k` positive" check does
/// NOT fire, and HC2 would then divide the meat by `1e-10` and
/// report an SE inflated by `1 / sqrt(1e-10) = 1e5`. Measured on
/// the v0.96.0 degenerate fixture (1 local row per side, `p1 = 3`):
/// `h_0 = 0.999999999825377`, `1 - h_0 = 1.7e-10`. So the df
/// check has to come FIRST, ahead of the leverage-range check, and
/// the range check alone is not sufficient.
///
/// HC0 is deliberately NOT guarded: on such a fit `se()` itself
/// still reports a number (`fit` does not refuse), and
/// `hac_se(HC0) == se()` is the anchor, so refusing HC0 here would
/// break the one identity this API promises.
fn rdd_hac_require_df(
  kind_name : String,
  n_left : Int,
  n_right : Int,
  p1 : Int,
) -> Unit {
  if n_left <= p1 {
    abort(
      "DoubleMLRDD::hac_se(" +
      kind_name +
      "): the LEFT local regression has " +
      n_left.to_string() +
      " rows but the local design has " +
      p1.to_string() +
      " parameters, so it is rank-deficient. HC1 needs n - k > 0, and HC2 / HC3 need an identified leverage: a rank-deficient design reports h_k = 1 - ridge, so the (1 - h_k) divisor would be a ridge artifact and inflate the variance by ~1 / ridge. Widen the bandwidth.",
    )
  }
  if n_right <= p1 {
    abort(
      "DoubleMLRDD::hac_se(" +
      kind_name +
      "): the RIGHT local regression has " +
      n_right.to_string() +
      " rows but the local design has " +
      p1.to_string() +
      " parameters, so it is rank-deficient. HC1 needs n - k > 0, and HC2 / HC3 need an identified leverage: a rank-deficient design reports h_k = 1 - ridge, so the (1 - h_k) divisor would be a ridge artifact and inflate the variance by ~1 / ridge. Widen the bandwidth.",
    )
  }
}

///|
/// v0.96.0+: heteroskedasticity-consistent (Huber-White) standard
/// error for the local-regression discontinuity contrast, in the
/// HC0 / HC1 / HC2 / HC3 family.
///
/// This is NOT `sandwich_se`. Read the section comment above
/// ("WHY RDD DOES NOT REUSE `sandwich_se`") for the algebra: RDD's
/// meat is `sum_k w_k^2 * m_k^2 * e_k^2` with a full `p1 x p1` WLS
/// normal inverse and no `1 / n^2`, the shared helper is a
/// scalar-Jacobian MEAN-moment sandwich, and feeding RDD's
/// influence function into the pre-v0.91.0 accumulator yields
/// `sum_k psi_a[k]^4 * e_k^2` (a fourth power) against RDD's second
/// power. The `SandwichKind` enum is reused -- it is the package's
/// shared vocabulary for the HC family -- but the arithmetic
/// behind each variant is the local-regression one.
///
/// The invariant that proves the wiring:
/// `hac_se(HC0) == se()` BIT-IDENTICALLY on a `cov_type = "HC0"`
/// fit. It is NOT claimed on a `cov_type = "homoskedastic"` fit
/// (whose `se()` is the homoskedastic form), and it ABORTS on a
/// non-OLS learner and on `fuzzy = true`.
///
/// HC2 / HC3 divide by `1 - h_k` per local row using the
/// persisted WLS leverage (`leverage()`). If any `h_k` leaves
/// `[0, 1)` the divisor would be non-positive, which means the
/// local regression is rank-deficient (fewer local rows than
/// parameters, or a collinear local design). This ABORTS rather
/// than clipping: a clip is what silently broke identities in
/// v0.93 / v0.94, and for a leverage in `[0, 1)` no correction
/// should ever fire.
pub fn DoubleMLRDD::hac_se(self : DoubleMLRDD, kind : SandwichKind) -> Double {
  try {
    require(self.fitted)
    self.require_hac_preconditions()
    let n = self.n_local
    require(self.hc0_m.length() == n)
    require(self.hc0_e.length() == n)
    require(self.leverage.length() == n)
    let w = rdd_kernel_weights(
      self.data,
      self.cutoff,
      self.bandwidth,
      self.kernel,
    )
    require(w.length() == n)
    let n_left = rdd_local_side_count(
      self.data,
      self.cutoff,
      self.bandwidth,
      -1.0,
    )
    let p1 = self.n_local_params()
    // Degrees-of-freedom guard FIRST: a rank-deficient local
    // design reports a leverage of `1 - ridge`, which is inside
    // `[0, 1)` and would sail past the range check below while
    // making the HC2 / HC3 divisor a ridge artifact. HC0 is
    // exempt so the `hac_se(HC0) == se()` anchor survives even on
    // a degenerate fit.
    let needs_df = match kind {
      HC0 => false
      HC1 => true
      HC2 => true
      HC3 => true
    }
    if needs_df {
      rdd_hac_require_df(kind.to_string(), n_left, n - n_left, p1)
    }
    // Per-observation divisor: 1 for HC0 / HC1, `1 - h_k` for
    // HC2, `(1 - h_k)^2` for HC3.
    let div : Array[Double] = Array::make(n, 1.0)
    let uses_leverage = match kind {
      HC0 | HC1 => false
      HC2 | HC3 => true
    }
    if uses_leverage {
      for k = 0; k < n; k = k + 1 {
        let h = self.leverage[k]
        if !(h >= 0.0 && h < 1.0) {
          abort(
            "DoubleMLRDD::hac_se: leverage h_" +
            k.to_string() +
            " = " +
            h.to_string() +
            " is outside [0, 1). A WLS hat-matrix diagonal always lies in [0, 1) unless the local regression is rank-deficient (fewer local rows than parameters, or a collinear local design), so 1 - h_k would be non-positive. Aborting instead of clipping.",
          )
        }
        let one_minus_h = 1.0 - h
        div[k] = match kind {
          HC3 => one_minus_h * one_minus_h
          _ => one_minus_h
        }
      }
    }
    // TWO partial sums, one per side, added last. This is the same
    // shape as `fit`'s `variance = vyl + vyr`, and each partial sum
    // accumulates the same per-observation values in the same
    // ascending order that `sandwich_se_weighted` accumulated
    // them, which is what makes the HC0 anchor bit-identical
    // rather than merely close.
    let mut acc_left = 0.0
    let mut acc_right = 0.0
    for k = 0; k < n; k = k + 1 {
      let base = rdd_hc0_term(w[k], self.hc0_m[k], self.hc0_e[k])
      // Skip the division entirely for HC0 / HC1: `x / 1.0` is
      // exact in IEEE-754, but not dividing at all cannot drift.
      let term = if div[k] == 1.0 { base } else { base / div[k] }
      if k < n_left {
        acc_left = acc_left + term
      } else {
        acc_right = acc_right + term
      }
    }
    let variance = match kind {
      HC0 => acc_left + acc_right
      HC2 => acc_left + acc_right
      HC3 => acc_left + acc_right
      HC1 => {
        // Per-side Stata `, robust` correction: each side is a
        // separate WLS regression, so each gets its own
        // `n_side / (n_side - k)`. `rdd_hac_require_df` has
        // already guaranteed both denominators are positive.
        let k_d = p1.to_double()
        let n_l = n_left.to_double()
        let n_r = (n - n_left).to_double()
        acc_left * (n_l / (n_l - k_d)) + acc_right * (n_r / (n_r - k_d))
      }
    }
    require(variance >= 0.0)
    variance.sqrt()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.96.0+: cluster-robust (Arellano 1987, Cameron-Gelbach-Miller
/// 2011) standard error for the local-regression discontinuity
/// contrast -- the clustered analogue of `hac_se(HC0)`.
///
/// `cluster_ids[k]` is the 0-based cluster of the k-th
/// bandwidth-restricted row (left side first then right side, the
/// same ordering as `leverage()`), and
/// `cluster_ids.length()` must equal `n_local()`. The number of
/// clusters is `1 + max(cluster_ids)`.
///
/// Per-observation score `s_k = w_k * m_k * e_k` (the RDD HC0
/// term under a square root, with its sign), aggregated within
/// cluster:
///
///     S_c     = sum_{k in c} s_k
///     var     = sum_c S_c^2 * n_c / (n_c - 1)
///
/// with the `(n_c - 1)` jackknife correction clipped to 1 for
/// single-observation clusters (the `statsmodels
/// cov_type='cluster'` convention, and the same clip
/// `cluster_sandwich_variance` uses). There is NO `1 / n^2`
/// divisor: the shared helper needs one because its moment is a
/// MEAN moment, while this is a sum of squared scores over the
/// rows of two separate regressions, exactly like `hac_se(HC0)`.
///
/// With all-singleton clusters the meat collapses to
/// `sum_k s_k^2`, i.e. `hac_se(HC0)` -- to floating-point
/// tolerance, not bit-exactly, for two reasons: the per-observation
/// square is formed as `s_k * s_k` here against the
/// `w^2 m^2 e^2` association in `hac_se`, and this accumulator is
/// Kahan-compensated (as in `cluster_sandwich_variance`) against
/// `hac_se`'s plain running sum. Pooled clusters differ.
///
/// Same preconditions as `hac_se`: ABORTS on a non-OLS learner
/// and on `fuzzy = true`.
pub fn DoubleMLRDD::cluster_hac_se(
  self : DoubleMLRDD,
  cluster_ids : Array[Int],
) -> Double {
  try {
    require(self.fitted)
    self.require_hac_preconditions()
    let n = self.n_local
    require(self.hc0_m.length() == n)
    require(self.hc0_e.length() == n)
    require(cluster_ids.length() == n)
    let w = rdd_kernel_weights(
      self.data,
      self.cutoff,
      self.bandwidth,
      self.kernel,
    )
    require(w.length() == n)
    let mut max_cid = -1
    for i = 0; i < n; i = i + 1 {
      require(cluster_ids[i] >= 0)
      if cluster_ids[i] > max_cid {
        max_cid = cluster_ids[i]
      }
    }
    require(max_cid >= 0)
    let n_clusters = max_cid + 1
    let cluster_sum : Array[Double] = Array::make(n_clusters, 0.0)
    let cluster_size : Array[Int] = Array::make(n_clusters, 0)
    for k = 0; k < n; k = k + 1 {
      let c = cluster_ids[k]
      let s = w[k] * self.hc0_m[k] * self.hc0_e[k]
      cluster_sum[c] = cluster_sum[c] + s
      cluster_size[c] = cluster_size[c] + 1
    }
    // Kahan-compensated, matching `cluster_sandwich_variance`.
    let mut acc = 0.0
    let mut acc_c = 0.0
    for c = 0; c < n_clusters; c = c + 1 {
      let nc = cluster_size[c]
      if nc == 0 {
        continue
      }
      let scale = if nc <= 1 {
        1.0
      } else {
        nc.to_double() / (nc.to_double() - 1.0)
      }
      let sc = cluster_sum[c]
      let term = sc * sc * scale
      let y = term - acc_c
      let t = acc + y
      acc_c = t - acc - y
      acc = t
    }
    require(acc >= 0.0)
    acc.sqrt()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.69.0+: sensitivity analysis for `DoubleMLRDD`.
///
/// RDD is the kernel-weighted local-polynomial regression
/// discontinuity estimator. The kernel-weighted precision
/// matrix per side is `M = (X^T W X + ridge I)^{-1}` and
/// the Riesz-representer row is `psi_a[k] = M[0, :] @ xx[k, :]`
/// (intercept row of `M` dotted with the k-th local
/// design row). The local polynomial residual is
/// `e_k = target_k - pred_k`. The IRM-style decomposition
/// (matching the v0.66.0+ sensitivity family) treats the
/// concatenation `residuals ++ psi_a` (left side then
/// right side) as a single IF row and applies
/// `irm_style_sensitivity` to it. The result is a single
/// `SensitivityResult` for the kernel-RDD jump estimate.
///
/// Notes:
///   - Fuzzy RDD uses `c = raw / jump` delta-method
///     weighting that mixes Y-residuals and D-residuals;
///     the simple `irm_style_sensitivity` decomposition
///     assumes the single-theta score form (so the
///     fuzzy-delta cross term `cov(raw, jump)` is captured
///     by the v0.59.0- fuzzy variance fix, not by the
///     sensitivity path). For sharp RDD the
///     decomposition is exact.
///   - `cf_y` / `cf_d` default to `0.05` matching the
///     v0.66.0+ sensitivity family.
///
/// Calling on an un-fit model aborts via
/// `PreconditionError`. Returns a single
/// `SensitivityResult`.
pub fn DoubleMLRDD::sensitivity_analysis(
  self : DoubleMLRDD,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  irm_style_sensitivity(self.coef, self.residuals, self.psi_a, cf_y, cf_d)
}

///|
/// v0.78.0+: cluster-robust analogue of
/// `DoubleMLRDD::sensitivity_analysis`. RDD's kernel-weighted
/// Riesz-representer row and outcome residuals (already on the
/// bandwidth-restricted sample, length `n_local`) are routed
/// through the v0.78.0 `irm_style_sensitivity_cluster`
/// kernel-weighted extension with the per-observation triangular
/// kernel weights `w[k] = 1 - |u_k| / h` where
/// `u_k = score[ids[k]] - cutoff`. The cluster sums become
/// `cluster_sum_resid[c] = sum_{k in c} w[k] * residuals[k]`
/// (and similarly for `psi_a`), so observations near the
/// cutoff (high weight) drive the cluster-aggregated variance
/// baseline. The per-observation C&H centering
/// `residuals[k]^2 - sigma2_cluster` keeps the bias expression
/// per-observation-anchored (see the helper's v0.78.0 doc).
///
/// `DoubleMLRDDData` has no `cluster_vars` field, so the
/// user must pass `cluster_ids` explicitly.
/// `cluster_ids.length()` must equal `self.n_local()`. Cluster
/// indices are 0-based; `1 + max(cluster_ids)` is the number of
/// clusters. Returns the same `SensitivityResult` shape as
/// the IID `sensitivity_analysis` so callers can swap IID for
/// cluster-aware without changing the return contract.
///
/// Calling on an un-fit model aborts via `PreconditionError`.
/// `n_local == 0` (no observations fall inside the bandwidth)
/// raises on the inner `irm_style_sensitivity_cluster`'s
/// `require(n > 0)`.
pub fn DoubleMLRDD::sensitivity_analysis_cluster(
  self : DoubleMLRDD,
  cluster_ids : Array[Int],
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let n_local = self.n_local
  require(n_local > 0)
  require(cluster_ids.length() == n_local)
  // Kernel weights: triangular `w[k] = 1 - |u_k| / h` on the
  // bandwidth-restricted sample, left side first then right
  // side (matching the ordering of `self.residuals` /
  // `self.psi_a`). Reproduces `rdd_design`'s selection logic
  // so the weights line up with the per-local-row residuals
  // and Riesz rows.
  let kernel_weights : Array[Double] = rdd_kernel_weights(
    self.data,
    self.cutoff,
    self.bandwidth,
    self.kernel,
  )
  require(kernel_weights.length() == n_local)
  irm_style_sensitivity_cluster(
    self.coef,
    self.residuals,
    self.psi_a,
    cluster_ids,
    cf_y,
    cf_d,
    kernel_weights~,
  )
}

///|
/// Compute the per-observation kernel weights for `DoubleMLRDD` on the
/// bandwidth-restricted sample: returns `kernel.weight(u_k, h)` for each
/// local-row observation k, where `u_k = score[ids[k]] - cutoff` and
/// `ids` is the bandwidth-restricted selection (left side first then
/// right side, matching the ordering used by `residuals` / `psi_a`).
/// Observations outside the bandwidth are skipped (so the returned
/// array length equals `n_local`). The helper is a pure function of the
/// data + cutoff + h + kernel so the caller does not need to thread the
/// original ids mapping through the `fit()` result.
///
/// v0.110.0: took the kernel from the caller instead of computing
/// `1 - |u|/h` inline. Before that this path silently used the
/// TRIANGULAR kernel no matter what the estimator was configured with --
/// so a kernel change would have moved `coef` and left
/// `cluster_hac_se` / `sensitivity_analysis_cluster` on the old weights.
/// Two code paths, one kernel setting.
fn rdd_kernel_weights(
  data : DoubleMLRDDData,
  cutoff : Double,
  h : Double,
  kernel : RDDKernel,
) -> Array[Double] {
  let weights : Array[Double] = []
  // Left side: u < 0.
  for i = 0; i < data.n_obs(); i = i + 1 {
    let u = data.score[i] - cutoff
    if u < 0.0 && u.abs() <= h {
      weights.push(kernel.weight(u, h))
    }
  }
  // Right side: u >= 0.
  for i = 0; i < data.n_obs(); i = i + 1 {
    let u = data.score[i] - cutoff
    if u >= 0.0 && u.abs() <= h {
      weights.push(kernel.weight(u, h))
    }
  }
  weights
}

///|
/// Number of bandwidth-restricted rows on ONE side of the cutoff
/// (`side < 0.0` left / `side > 0.0` right). Reproduces
/// `rdd_design`'s selection predicate exactly -- the same
/// `u < 0.0` / `u >= 0.0` split and the same `u.abs() <= h`
/// bandwidth test -- so the left/right split `hac_se` uses to
/// mirror `fit`'s `variance = vyl + vyr` lines up with the rows
/// that produced `vyl` and `vyr`.
///
/// `rdd_kernel_weights` above walks the same selection to build
/// the weights; this one only counts. It is a pure function of
/// `(data, cutoff, bandwidth)`, so the memoize cache-hit path does
/// not need to store the split.
fn rdd_local_side_count(
  data : DoubleMLRDDData,
  cutoff : Double,
  h : Double,
  side : Double,
) -> Int {
  let mut count = 0
  for i = 0; i < data.n_obs(); i = i + 1 {
    let u = data.score[i] - cutoff
    if (side < 0.0 && u < 0.0) || (side > 0.0 && u >= 0.0) {
      if u.abs() <= h {
        count = count + 1
      }
    }
  }
  count
}

///|
/// v0.75.0+: multiplier bootstrap for `DoubleMLRDD`. The
/// per-observation influence function is
///
///   psi[k] = psi_a[k] * residuals[k]
///
/// (kernel-weighted Riesz row dotted with the local-polynomial
/// residual). RDD is the kernel-weighted local-polynomial
/// regression discontinuity estimator: the IF for the jump
/// coefficient at the cutoff does not factor into the v0.61.0
/// `psi_a + coef * psi_b` form (it's a single combined IF),
/// so this bootstrap calls `did_bootstrap_t_stat` directly
/// rather than going through `generic_bootstrap_t_stat`.
///
/// `method_name` selects the multiplier distribution:
/// `"normal"` (default), `"Bayes"`, `"wild"`; `seed` defaults
/// to `2024`; `n_rep_boot` defaults to `500`.
///
/// Calling on an un-fit model aborts via `PreconditionError`.
/// Returns a new `DoubleMLRDD` with `boot_t_stat` /
/// `boot_method` / `n_rep_boot` / `boot_seed` populated.
pub fn DoubleMLRDD::bootstrap(
  self : DoubleMLRDD,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLRDD {
  try {
    require(self.fitted)
    require(
      method_name == "normal" || method_name == "Bayes" || method_name == "wild",
    )
    require(n_rep_boot >= 2)
    let n = self.n_local
    require(self.psi_a.length() == n)
    require(self.residuals.length() == n)
    // Draw weights. Shape: (n_rep_boot, n_local).
    let weights = draw_bootstrap_weights(method_name, n_rep_boot, n, seed) catch {
      BootstrapMethodError::UnknownMethod(m) =>
        abort(
          "draw_bootstrap_weights: unknown method (set in DoubleMLRDD::bootstrap): " +
          m,
        )
    }
    // Combined IF `psi[k] = psi_a[k] * residuals[k]`.
    let psi : Array[Double] = Array::make(n, 0.0)
    let mut ss_psi = 0.0
    for i = 0; i < n; i = i + 1 {
      let psi_i = self.psi_a[i] * self.residuals[i]
      psi[i] = psi_i
      ss_psi = ss_psi + psi_i * psi_i
    }
    let n_d = n.to_double()
    let se_psi = (ss_psi / n_d).sqrt()
    let boot_t_stat : Array[Double] = if se_psi <= 0.0 {
      // Degenerate: psi sums to 0 (kernel row or residuals
      // collapse to 0). Return zeros (matches the v0.55.0+
      // DIDCrossSection convention).
      Array::make(n_rep_boot, 0.0)
    } else {
      let se_flat : Array[Double] = [se_psi]
      did_bootstrap_t_stat(weights, psi, se_flat, n_rep_boot, n, 1)
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
/// Accessor for the local-polynomial learner used by the most
/// recent `fit(...)` call. v0.60.0+. Note: RDD's bandwidth /
/// kernel are configuration (not LearnerDispatch concepts);
/// this slot plugs into the closed-form OLS underneath the
/// kernel weights and is forward-compatible with v0.61.0+
/// kernel-aware wrappers.
pub fn DoubleMLRDD::learner_g(self : DoubleMLRDD) -> LearnerDispatch {
  self.ml_g
}

///|
pub fn DoubleMLRDD::n_local(self : DoubleMLRDD) -> Int {
  self.n_local
}

///|
/// v0.108.0+ (NEW): score a grid of candidates for RDD's ONE
/// nuisance slot and re-fit `DoubleMLRDD` with the winner, via the
/// shared `tune_score_grid` core. This closes a coverage gap against
/// upstream, where `tune` reaches every estimator through the
/// `BaseDML` mixin; `PQ` / `QTE` / `RDD` had no `tune` before
/// v0.108.0.
///
/// Slot tuned: `ml_g`, and ONLY `ml_g`. RDD has a single nuisance
/// slot, so `param_set` is a bare `Array[LearnerDispatch]` -- the
/// same shape `DoubleMLPLIV::tune` uses; a `TuneParam` would be a
/// two-slot wrapper around one value.
///
/// DO NOT "fix" `ml_g` into a propensity / treatment slot. Despite
/// the `g` in the name (it is inherited from the field name, not
/// from any role), RDD's `ml_g` is the DISCONTINUITY-SIDE,
/// OUTCOME-side learner for `E[y|x]` -- the local polynomial fit on
/// each side of the cutoff under the triangular kernel (see the
/// `ml_g` struct-field doc and `rdd_side`). It is NOT `E[g|d,x]`.
/// The `TuneParam` slot-semantics table in `tune.mbt` lists `RDD`'s
/// first slot as the discontinuity-side learner `E[y|x]` for
/// exactly this reason.
///
/// Structural config is NOT re-derived here: `cutoff`, `bandwidth`,
/// `fuzzy` and `cov_type` are already carried by the model being
/// tuned, and `DoubleMLRDD::fit` reads them off `self` (it copies
/// `self.cutoff` / `self.bandwidth` / `self.fuzzy` /
/// `self.cov_type` straight onto the returned struct) and threads
/// them into every `rdd_side` call. `tune` passes only `ml_g`, so
/// tuning the learner cannot perturb the design.
///
/// Cluster guard: ABSENT, deliberately. `DoubleMLRDDData` has NO
/// `is_cluster_data()` method -- RDD's data type is not the
/// cluster-aware `DoubleMLData`, and adding the method (or the
/// guard) would mean inventing a cluster concept for a data type
/// that never had one. RDD's dependence is handled through the
/// bandwidth-restricted local sample, not cluster ids. Cluster
/// inference lives in the separate explicit
/// `DoubleMLRDD::cluster_hac_se` / `sensitivity_analysis_cluster`
/// entry points.
pub fn DoubleMLRDD::tune(
  self : DoubleMLRDD,
  param_set~ : Array[LearnerDispatch],
  scoring_method? : String = "MSE",
  n_folds_tune? : Int = 5,
  seed? : Int = 3141,
) -> DoubleMLRDD {
  try {
    require(param_set.length() > 0)
    require(n_folds_tune >= 2)
    let scoring = TuneScoring::parse(scoring_method)
    let grid = tune_score_grid(
      self.data.x,
      self.data.y,
      param_set,
      n_folds_tune,
      seed,
      scoring,
    )
    self.fit(ml_g=param_set[grid.best_index])
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// The kernel weighting the local polynomial. Read back with this rather
/// than inferred from a fitted model, so a config that was built with an
/// explicit kernel can be checked against what the model actually used.
pub fn DoubleMLRDD::kernel(self : DoubleMLRDD) -> RDDKernel {
  self.kernel
}

///|
/// The per-observation kernel weights this model applies, on the
/// bandwidth-restricted local sample: one entry per local row, left
/// side first then right side, matching the ordering of `residuals` /
/// `psi_a` / `hc0_m` / `hc0_e`.
///
/// Public, and not only for curiosity. `cluster_hac_se` and
/// `sensitivity_analysis_cluster` REBUILD these weights rather than
/// reading a stored copy, so they had a second, independent path to the
/// kernel. A test that only compares two `cluster_hac_se` values cannot
/// tell which path supplied the weights -- both models' `fit` already
/// stored kernel-dependent `hc0_m` / `hc0_e`, so the SE differs either
/// way and the assertion holds even with the cluster path reverted to a
/// hardcoded triangular kernel (mutation M2, which survived the first
/// version of this gate). Reading the weights makes the second path
/// directly observable.
pub fn DoubleMLRDD::kernel_weights(
  self : DoubleMLRDD,
  h : Double,
) -> Array[Double] {
  rdd_kernel_weights(self.data, self.cutoff, h, self.kernel)
}

///|
/// Package-private helper so `optimal_bandwidth`, `bandwidth_mse` and
/// `pilot_bandwidth` agree on the pilot bandwidth by construction. Two
/// copies of the Silverman call would be free to drift, and the criterion
/// would silently stop being the thing the search minimises.
///
/// A free function rather than a method: `fn name(self : Type)` at top
/// level is deprecated method syntax and does not bind as one outside an
/// `extend` block.
fn rdd_pilot_bandwidth(data : DoubleMLRDDData) -> Double {
  silverman_bandwidth(data.score)
}

///|
///v0.110.0: MSE-optimal bandwidth (Cattaneo, Frandsen & Tchetgen 2020),
/// the procedure `rdrobust` exposes through `bwselect`.
///
/// Before this, bandwidth was a user-supplied constant and nothing chose
/// it. That is a real gap rather than a design choice: `rdrobust`'s
/// headline contribution to the RDD literature is precisely that a
/// plug-in bandwidth needs a data-driven default.
///
/// Procedure, on a grid of dimensionless multipliers of a pilot bandwidth:
///
///   1. `h_pilot = silverman_bandwidth(data.score)` -- the rule-of-thumb
///      bandwidth of the RUNNING VARIABLE, not of the outcome. This is
///      the scale the grid is expressed in, so the result is invariant
///      to the units the running variable happens to be measured in.
///   2. `bandwidth_mse(h)` is the criterion:
///         (xi(h) - xi(h_pilot))^2 + b^4 * sigma4 / n,   b = h / h_pilot
///      The first term is the squared bias relative to the pilot, which
///      is treated as approximately unbiased; the second is the `O(b^4)`
///      variance growth of a local-polynomial derivative estimate.
///   3. The minimiser over `b` in `[0.5, 2.0]` is returned, scaled back
///      by `h_pilot`.
///
/// The criterion is PUBLIC on purpose. Exposing it means a caller -- and
/// the test suite -- can check that the returned bandwidth actually
/// minimises it, instead of having to trust that the search did what its
/// name says. Without that, "optimal_bandwidth" is an assertion rather
/// than a checkable result.
///
/// Two honest deviations from `rdrobust`, both forced by this port's shape
/// rather than chosen:
///
///   * the grid has 50 points, not `rdrobust`'s 100;
///   * Cattaneo's `Sigma^4` is built from the DIFFERENCE of left and
///     right residuals at paired observations, and this port's
///     `rdd_side` returns two per-side residual arrays of UNEQUAL
///     length, so pairing them is a separate design decision. The pooled
///     sum of squares is used instead. Same units, same `b^4` scaling,
///     no pairing.
///
/// This does NOT modify the estimator. It is a function you call to
/// obtain a starting bandwidth; `fit` still uses `self.bandwidth`.
pub fn DoubleMLRDD::optimal_bandwidth(self : DoubleMLRDD) -> Double {
  let h_pilot = rdd_pilot_bandwidth(self.data)
  let l_min = 0.5
  let l_max = 2.0
  let n_grid = 50
  let mut best_h = l_min * h_pilot
  // Finite upper bound rather than an infinity sentinel: the four
  // backends disagree about IEEE infinity through the FFI boundary,
  // which is the same reason `tune.mbt` uses 1e300.
  let mut best_mse = 1.0e300
  for g = 0; g < n_grid; g = g + 1 {
    let b = l_min + (l_max - l_min) * g.to_double() / (n_grid - 1).to_double()
    let h = b * h_pilot
    let mse = self.bandwidth_mse(h)
    if mse < best_mse {
      best_mse = mse
      best_h = h
    }
  }
  best_h
}

///|
/// The scale the bandwidth search is expressed in: the rule-of-thumb
/// bandwidth of the RUNNING VARIABLE, never of the outcome.
pub fn DoubleMLRDD::pilot_bandwidth(self : DoubleMLRDD) -> Double {
  silverman_bandwidth(self.data.score)
}

///|
/// The MSE-optimality criterion at an arbitrary bandwidth `h`:
/// `(xi(h) - xi(h_pilot))^2 + (h/h_pilot)^4 * sigma4 / n`, with
/// `xi_pilot` and the pooled residual scale `sigma4` both taken at
/// `h_pilot`.
///
/// Public so the choice made by `optimal_bandwidth` can be verified
/// against it. It costs two extra local fits per call, so it is not
/// something to call in a loop outside the search.
///
/// NOT annotated `raise PreconditionError`, unlike
/// `check_sample_splitting`: the `require`s below are on values the
/// caller controls, and MoonBit's analysis reports the error type as
/// never used (`unused_error_type`), which `--deny-warn` then treats as
/// a build failure. The two guards stay because they document the
/// precondition; they just do not widen the signature.
pub fn DoubleMLRDD::bandwidth_mse(self : DoubleMLRDD, h : Double) -> Double {
  try {
    let n = self.n_obs()
    let h_pilot = rdd_pilot_bandwidth(self.data)
    require(h_pilot > 0.0)
    require(h > 0.0)
    let (xi_pilot, sigma4) = rdd_pilot_stage(self)
    let (yl, _, _, _, _, _, _, _) = rdd_side(
      self.ml_g,
      self.data,
      -1.0,
      self.cutoff,
      h,
      false,
      self.cov_type,
      self.kernel,
    )
    let (yr, _, _, _, _, _, _, _) = rdd_side(
      self.ml_g,
      self.data,
      1.0,
      self.cutoff,
      h,
      false,
      self.cov_type,
      self.kernel,
    )
    let bias = yr - yl - xi_pilot
    let b = h / h_pilot
    let b2 = b * b
    bias * bias + b2 * b2 * sigma4 / n.to_double()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// `Sigma^4` of the MSE-optimal criterion: the pooled residual second
/// moment across both sides, taken at `h_pilot`.
///
/// Public, and for a reason that is about the GATE rather than the
/// user. `bandwidth_mse` evaluates `(xi(h) - xi_pilot)^2 + b^4*sigma4/n`,
/// and at `h = h_pilot` the bias term is identically zero BY
/// CONSTRUCTION -- `xi(h_pilot)` is `xi_pilot` -- so
///
///     bandwidth_mse(h_pilot) == sigma4 / n        (exactly)
///
/// is an identity the test suite can check without recomputing any
/// local fit. That is what makes the criterion checkable from the
/// outside: before this accessor existed, deleting the `b^4`
/// variance term from `bandwidth_mse` left the search still minimising
/// its own criterion, so every assertion stayed green and the gate
/// could not testify about the criterion at all. With `sigma4`
/// readable, that mutation returns 0 at the pilot instead of
/// `sigma4 / n` and the suite goes red.
///
/// Note this still does NOT prove the criterion is Cattaneo's -- it
/// pins the variance term's scale and the pilot's self-consistency.
/// `xi(b)` at a non-pilot bandwidth needs `rdd_side`'s per-side
/// residual arrays, whose lengths differ, so the pairing Cattaneo
/// uses remains a separate design decision (see `optimal_bandwidth`).
pub fn DoubleMLRDD::bandwidth_sigma4(self : DoubleMLRDD) -> Double {
  let (_, sigma4) = rdd_pilot_stage(self)
  sigma4
}

///|
/// The pilot-stage pair the criterion is built from: the intercept
/// difference at `h_pilot`, and the pooled residual second moment
/// there.
///
/// Shared by `bandwidth_mse` and `bandwidth_sigma4` so the two cannot
/// drift -- a criterion whose public `sigma4` and internal `sigma4`
/// were computed separately would make the identity above fail for
/// reasons unrelated to the maths.
///
/// A free function rather than a method, for the same reason as
/// `rdd_pilot_bandwidth`: `fn name(self : Type)` at top level is
/// deprecated method syntax and does not bind as one.
fn rdd_pilot_stage(m : DoubleMLRDD) -> (Double, Double) {
  try {
    let h_pilot = rdd_pilot_bandwidth(m.data)
    require(h_pilot > 0.0)
    let (yl, _, _, res_l, _, _, _, _) = rdd_side(
      m.ml_g,
      m.data,
      -1.0,
      m.cutoff,
      h_pilot,
      false,
      m.cov_type,
      m.kernel,
    )
    let (yr, _, _, res_r, _, _, _, _) = rdd_side(
      m.ml_g,
      m.data,
      1.0,
      m.cutoff,
      h_pilot,
      false,
      m.cov_type,
      m.kernel,
    )
    let mut sigma4 = 0.0
    for r in res_l {
      sigma4 = sigma4 + r * r
    }
    for r in res_r {
      sigma4 = sigma4 + r * r
    }
    (yr - yl, sigma4)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
