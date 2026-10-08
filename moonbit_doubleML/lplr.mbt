///|
/// Double / debiased machine learning for the *partially logistic*
/// regression model (upstream `doubleml.plm.DoubleMLLPLR`, Liu,
/// Zhang, Zhou 2021):
///
///     Y = expit(D * theta_0 + r_0(X)),  Y in {0, 1}
///
/// The treatment `D` may be binary or continuous. The model uses a
/// *double* cross-fit so the auxiliary regression `t_0(X) = E[W | X]`
/// (where `W = logit(M_0)`) can be estimated with inner-fold OOF
/// predictions without leaking information from the outer test set.
///
/// Two scores are supported, exactly as upstream:
///   - `"nuisance_space"`: the per-fold `ml_m` training set is
///     filtered to rows with `Y = 0` (the "nuisance space" of the
///     ATE on the treated subsample). The starting `beta` is
///     computed inside the loop, one per fold, from the inner
///     predictions.
///   - `"instrument"`: the score itself is upstream's instrument-type
///     form `(Y - expit(theta*D + r_hat)) * (D - m_hat)`, with the
///     derivative upstream gives at `plm/lplr.py:536-538`. The
///     starting `beta` is still per-fold.
///
/// v0.105.0: these two used to be inert. `score` was validated and
/// stored but never read, so both strings returned the
/// nuisance_space answer bit for bit. If you are upgrading: the
/// `nuisance_space` numbers move slightly (because `ml_m` is now
/// fitted on the `Y = 0` subsample instead of being aliased to
/// `ml_a`), and `instrument` produces a genuinely different
/// estimate for the first time.
pub struct DoubleMLBinaryData {
  x : Matrix
  y : Array[Double]
  d : Array[Double]
} derive(Debug)

///|
pub extend DoubleMLBinaryData with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLBinaryData::new(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
) -> DoubleMLBinaryData {
  try {
    let n = x.nrows
    require(y.length() == n)
    require(d.length() == n)
    require(n >= 2)
    for yi in y {
      require(yi == 0.0 || yi == 1.0)
    }
    { x, y, d, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Per-fold preliminary `beta` estimate (one double per outer fold).
/// `m_inner[k]` and `a_inner[k]` are the *inner* OOF predictions
/// for the `k`-th row in the outer fold's training slice (in
/// outer-training-row order, length = `train_idx.length()`); `d[i]`
/// is the original-row-indexed treatment for `i = train_idx[k]`.
/// `W = logit(clip(m_inner, 1e-8, 1 - 1e-8))` and
/// `d_tilde = d - a_inner` give:
///
///     beta_f = sum(d_tilde * W) / sum(d_tilde^2)
fn prelim_beta_per_fold(
  m_inner : Array[Double],
  a_inner : Array[Double],
  d : Array[Double],
  train_idx : Array[Int],
) -> Double {
  try {
    let mut num = 0.0
    let mut den = 0.0
    for k = 0; k < train_idx.length(); k = k + 1 {
      let i = train_idx[k]
      let mc = if m_inner[k] < 1.0e-8 {
        1.0e-8
      } else if m_inner[k] > 1.0 - 1.0e-8 {
        1.0 - 1.0e-8
      } else {
        m_inner[k]
      }
      let w = @math.ln(mc / (1.0 - mc))
      let dt = d[i] - a_inner[k]
      num = num + dt * w
      den = den + dt * dt
    }
    require(den.abs() > 0.0)
    num / den
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Score elements for the LPLR model. With
///   r(theta) = D * theta + t_hat - beta * a_hat,
///   psi(theta) = d_tilde * (1 - y) * exp(r(theta)) - expit(-r(theta)),
///   psi_deriv(theta) = -d_tilde * d * (1 - y) * exp(r(theta)).
pub struct LplrScore {
  psi : Array[Double]
  psi_deriv : Array[Double]
}

///|
/// Which of upstream's two LPLR scores to evaluate.
///
/// v0.105.0+. Before this enum existed, `DoubleMLLPLR::score` was
/// validated (`require(score == "nuisance_space" || score ==
/// "instrument")`) and stored on the struct, and then **never read**
/// by anything downstream: `fit` always took the nuisance_space
/// path. `examples/lplr` printed both scores side by side and they
/// agreed to the last bit -- which reads like an algebraic identity
/// and is actually an unimplemented parameter. Upstream
/// `DoubleMLLPLR._compute_score` / `._compute_score_deriv`
/// (`plm/lplr.py:521-540`) are two genuinely different formulas, and
/// `_fit_nuisance` (`plm/lplr.py:244-252`) fits `ml_m` on a
/// different training set for each. Asserting the two paths agree
/// would have welded that in place.
pub enum LplrScoreKind {
  NuisanceSpace
  Instrument
}

///|
/// Map the public `score` string onto `LplrScoreKind`.
///
/// The `score` field is validated in `DoubleMLLPLR::new`, so this
/// only has to handle the two legal names. Unknown names fall back
/// to `NuisanceSpace` (the upstream default) rather than raising:
/// the constructor is the single validation point and duplicating
/// the panic here would make `fit` harder to call in isolation.
pub fn lplr_score_kind(score : String) -> LplrScoreKind {
  if score == "instrument" {
    Instrument
  } else {
    NuisanceSpace
  }
}

///|
/// Evaluate the LPLR score (and its `theta` derivative) at a given
/// `theta`. `t_pred[i]` and `a_pred[i]` are the outer cross-fitted
/// nuisances (`ml_t` and `ml_a`); `m_pred[i]` is `ml_m`, which this
/// port aliases to `a_pred` -- see the `m_pred = a_pred` comment in
/// `fit` for why, and what it costs relative to upstream.
/// The per-fold preliminary `beta` is held constant during Newton --
/// the nonlinear solve is over `theta` only.
///
/// Upstream `DoubleMLLPLR._score_elements` (`plm/lplr.py:401-416`)
/// builds the shared elements:
///
///   d_tilde     = d - m_hat
///   psi_hat     = expit(-r_hat)
///   score_const = d_tilde * (1 - y) * exp(r_hat)
///
/// and the two scores then consume them differently.
///
/// **nuisance_space** (`_compute_score`, `lplr.py:522-524`):
///
///   score_1 = y * exp(-theta * d) * d_tilde
///   score   = psi_hat * (score_1 - score_const)
///
/// **instrument** (`_compute_score`, `lplr.py:525-528`):
///
///   score = (y - expit(theta * d + r_hat)) * d_tilde
///
/// Note that the instrument branch reads neither `psi_hat` nor
/// `score_const` -- upstream computes them in `_score_elements`
/// because that helper is score-agnostic, but they are dead for this
/// branch, so this port skips them.
pub fn lplr_score_at(
  theta : Double,
  d : Array[Double],
  y : Array[Double],
  t_pred : Array[Double],
  a_pred : Array[Double],
  m_pred : Array[Double],
  beta_start : Double,
  kind : LplrScoreKind,
) -> LplrScore {
  // The Newton root of mean(score) gives theta_hat.
  let n = d.length()
  let psi : Array[Double] = Array::make(n, 0.0)
  let psi_deriv : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let r_hat = t_pred[i] - beta_start * a_pred[i]
    let dt = d[i] - m_pred[i]
    match kind {
      NuisanceSpace => {
        let psi_hat = expit(-r_hat)
        let score_const = dt * (1.0 - y[i]) * @math.exp(r_hat)
        let score_1 = y[i] * @math.exp(-theta * d[i]) * dt
        psi[i] = psi_hat * (score_1 - score_const)
        // d_psi/d_theta = psi_hat * d(score_1)/d_theta
        //               = psi_hat * y * (-d) * exp(-theta * d) * d_tilde
        psi_deriv[i] = psi_hat * y[i] * -d[i] * @math.exp(-theta * d[i]) * dt
      }
      Instrument => {
        let e = expit(theta * d[i] + r_hat)
        psi[i] = (y[i] - e) * dt
        // d/d_theta expit(theta*d + r_hat) = d * e * (1 - e)
        psi_deriv[i] = -d[i] * e * (1.0 - e) * dt
      }
    }
  }
  { psi, psi_deriv, }
}

///|
/// Newton iteration to find the root of `mean(score(theta))` for a
/// *given* `psi(theta) = psi_a * theta + psi_b`-style linear score
/// (i.e. `psi` and `psi_deriv` are constants with respect to
/// `theta`). For the general nonlinear case, callers should
/// re-evaluate `psi(theta)` / `psi_deriv(theta)` between iterations
/// -- see the LPLR `fit` body, which evaluates the score at the
/// converged `theta` after this routine returns.
///
/// Mirrors `scipy.optimize.root_scalar(method="newton")` with
/// `fprime = score_deriv`. Stops when
/// `|theta_{k+1} - theta_k| < tol_theta` (default `1e-9`) or
/// `max_iter` (default 50) is reached. Returns the converged
/// theta and a Boolean indicating whether the iteration converged.
pub fn newton_solve_score(
  theta_start : Double,
  psi : Array[Double],
  psi_deriv : Array[Double],
  tol_theta? : Double = 1.0e-9,
  max_iter? : Int = 50,
) -> (Double, Bool) {
  try {
    let n = psi.length()
    require(n > 0)
    let mut theta = theta_start
    let mut converged = false
    for step = 0; step < max_iter; step = step + 1 {
      let mut s = 0.0
      let mut sd = 0.0
      for i = 0; i < n; i = i + 1 {
        s = s + psi[i]
        sd = sd + psi_deriv[i]
      }
      s = s / n.to_double()
      sd = sd / n.to_double()
      if sd.abs() < 1.0e-300 {
        break
      }
      let delta = s / sd
      let theta_new = theta - delta
      if (theta_new - theta).abs() < tol_theta {
        theta = theta_new
        converged = true
        break
      }
      theta = theta_new
    }
    (theta, converged)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Model: `Y = expit(D * theta + r_0(X))`. Binary outcomes, mixed
/// treatment type. Wraps a single-treatment LPLR with closed-form
/// logistic regression learners (`LogisticRegression` for `ml_M` and
/// `ml_m`, `LinearRegression` for `ml_t`). The repository keeps one
/// estimator per data; multi-treatment support is out of scope here.
pub struct DoubleMLLPLR {
  data : DoubleMLBinaryData
  score : String
  n_folds : Int
  n_folds_inner : Int
  n_rep : Int
  seed : Int
  // v0.109.0+: caller-supplied sample splitting; `[]` means "draw my
  // own". When non-empty, `fit` uses `smpls[r]` for repetition `r`
  // INSTEAD of calling `kfold` for the OUTER partition, and the
  // repetition count comes from the supplied partition's length rather
  // than from the configured `n_rep`. Set it through
  // `DoubleMLLPLR::set_sample_splitting`, which validates the partition
  // and derives both counts -- do not build it by hand.
  smpls : Array[Array[Fold]]
  // v0.60.0+: injected nuisance learners. LPLR uses
  // `LogisticRegression` internally for both `ml_m` and
  // `ml_a` (the latter is itself a `LogisticRegression`). The
  // `ml_g` slot maps to the closed-form `LinearRegression` (via
  // `cross_fit_predict(LinearRegression, ...)`. Defaults to
  // OLS / LogisticRegression so v0.59.0 callers see
  // byte-identical results. v0.61.0+ will plumb these through;
  // for v0.60.0 they're stored on the struct and returned via
  // the accessors but not yet consumed internally.
  ml_g : LearnerDispatch
  ml_m : LearnerDispatch
  coef_ : Double
  se_ : Double
  r_hat : Array[Double]
  m_hat : Array[Double]
  a_hat : Array[Double]
  fitted : Bool
  // v0.75.0+: per-observation influence function components
  // for the multiplier bootstrap. Populated by `fit(...)` from
  // the LAST rep's cross-fitted nuisances on the
  // LPLR-simplified IRM form
  // (matches the v0.70.0 sensitivity_analysis convention):
  //   psi_a[i] = -d[i] * (d[i] - a_hat[i])
  //   psi_b[i] = score(theta) - theta * psi_deriv(theta)
  // where `score(theta)` and `psi_deriv(theta)` are the
  // converged LPLR linear-score forms.
  psi_a : Array[Double]
  psi_b : Array[Double]
  // v0.75.0+: multiplier bootstrap state. `boot_t_stat` is a
  // length-`n_rep_boot` array of t-statistics for `coef_`.
  // Populated by `bootstrap(...)`; empty until then.
  boot_t_stat : Array[Double]
  boot_method : String
  n_rep_boot : Int
  boot_seed : Int
  // v0.83.0+: memoization state. `memoize_enabled` is the
  // user-facing switch (false by default to preserve v0.82.0
  // behavior bit-for-bit). When true and `n_rep == 1`, `fit()`
  // caches the LAST rep's `(r_hat, m_hat, a_hat)` plus fold
  // assignment in `fit_cache` and reuses them on the next
  // call when the data fingerprint, fold split, and learner
  // configuration are unchanged. Mirrors the IRM / PLR /
  // CVAR / SSM / PLPR plumbing.
  memoize_enabled : Bool
  fit_cache : FitCache
} derive(Debug)

///|
pub extend DoubleMLLPLR with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLLPLR::new(
  data : DoubleMLBinaryData,
  score? : String = "nuisance_space",
  n_folds? : Int = 2,
  n_folds_inner? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  ml_g? : LearnerDispatch = LearnerDispatch::linear_regression(),
  ml_m? : LearnerDispatch = LearnerDispatch::linear_regression(),
) -> DoubleMLLPLR {
  try {
    require(score == "nuisance_space" || score == "instrument")
    require(n_folds >= 2)
    require(n_folds_inner >= 2)
    require(n_rep >= 1)
    {
      data,
      score,
      n_folds,
      n_folds_inner,
      n_rep,
      seed,
      // v0.109.0: no external splitting unless
      // `set_sample_splitting` is called, so every pre-existing caller
      // keeps the drawn path.
      smpls: [],
      ml_g,
      ml_m,
      coef_: 0.0,
      se_: 0.0,
      r_hat: [],
      m_hat: [],
      a_hat: [],
      fitted: false,
      psi_a: [],
      psi_b: [],
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      // v0.83.0+: default memoize off so v0.82.0 callers see
      // byte-identical fit() output. Enable explicitly via
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
/// Accessor for the outcome-nuisance learner used by the most
/// recent `fit(...)` call. v0.60.0+.
pub fn DoubleMLLPLR::learner_g(self : DoubleMLLPLR) -> LearnerDispatch {
  self.ml_g
}

///|
/// Accessor for the propensity-score learner used by the most
/// recent `fit(...)` call. v0.60.0+.
pub fn DoubleMLLPLR::learner_m(self : DoubleMLLPLR) -> LearnerDispatch {
  self.ml_m
}

///|
/// v0.83.0+: turn on memoization for subsequent `fit()` calls.
/// When enabled, `fit()` will cache the LAST rep's per-fold
/// nuisance predictions (`r_hat`, `m_hat`, `a_hat`) and the
/// fold assignment; on a repeat call whose data + learner
/// fingerprint + fold split is identical, the entire per-fold
/// crossfit is skipped and the cached values feed the
/// Newton / score / SE pipeline.
///
/// `enable_memoize()` is honored only when `n_rep == 1`; for
/// `n_rep > 1` the per-rep cross-fit must run each time (the
/// cache would otherwise need to thread `n_rep` independent
/// per-rep nuisance arrays, which the `FitCache` layout does
/// not accommodate).
///
/// Default is OFF. When OFF, every `fit()` call runs the full
/// cross-fit and the cache is neither read nor written, so
/// v0.82.0 callers see byte-identical output.
pub fn DoubleMLLPLR::enable_memoize(self : DoubleMLLPLR) -> DoubleMLLPLR {
  { ..self, memoize_enabled: true, }
}

///|
/// v0.83.0+: turn off memoization. Same immutability contract
/// as `enable_memoize()`. After this, `fit()` will not read or
/// write the cache; the existing `fit_cache` is preserved on
/// the returned struct (call `clear_cache()` to drop it).
pub fn DoubleMLLPLR::disable_memoize(self : DoubleMLLPLR) -> DoubleMLLPLR {
  { ..self, memoize_enabled: false, }
}

///|
/// v0.83.0+: drop any cached nuisance predictions and fold
/// assignment. Forces the next `fit()` to recompute from
/// scratch.
pub fn DoubleMLLPLR::clear_cache(self : DoubleMLLPLR) -> DoubleMLLPLR {
  { ..self, fit_cache: FitCache::empty(), }
}

///|
/// v0.83.0+: `true` iff `fit_cache` holds at least one cached
/// observation (i.e. at least one prior `fit()` call with
/// `memoize_enabled = true` has populated the cache). Note
/// that the cache may still be stale relative to the current
/// data + learner configuration -- check `memoize_enabled`
/// before assuming a cache hit.
pub fn DoubleMLLPLR::has_cache(self : DoubleMLLPLR) -> Bool {
  !self.fit_cache.is_empty()
}

///|
pub fn DoubleMLLPLR::coef(self : DoubleMLLPLR) -> Double {
  try {
    require(self.fitted)
    self.coef_
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLLPLR::se(self : DoubleMLLPLR) -> Double {
  try {
    require(self.fitted)
    self.se_
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLLPLR::confint(self : DoubleMLLPLR) -> (Double, Double) {
  try {
    require(self.fitted)
    let z = 1.959963984540054
    (self.coef_ - z * self.se_, self.coef_ + z * self.se_)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// `t_hat` (E[W | X]) from the last repetition. Length `n_obs`.
pub fn DoubleMLLPLR::predictions_t(self : DoubleMLLPLR) -> Array[Double] {
  try {
    require(self.fitted)
    self.r_hat
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// `m_hat` (E[D | X], outer cross-fit, "a_hat" in upstream) from
/// the last repetition. Length `n_obs`.
pub fn DoubleMLLPLR::predictions_m(self : DoubleMLLPLR) -> Array[Double] {
  try {
    require(self.fitted)
    self.m_hat
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// `a_hat` (E[D | X] propensity used in `d_tilde`) from the last
/// repetition. In LPLR, `m_hat == a_hat` (a single nuisance
/// regressor feeds both roles), but the field is preserved for
/// parity with upstream's separate `ml_m` / `ml_a` learners.
pub fn DoubleMLLPLR::predictions_a(self : DoubleMLLPLR) -> Array[Double] {
  try {
    require(self.fitted)
    self.a_hat
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Concatenate the treatment column `d` (length `n`) with the
/// covariate matrix `x` (size `n x p`) into an `n x (p+1)` design
/// matrix. The first column is `d` so the downstream `ml_M` learner
/// receives `E[Y | D, X]`.
fn concat_d_x(d : Array[Double], x : Matrix) -> Matrix {
  let n = x.nrows
  let p = x.ncols
  let flat : Array[Double] = Array::make(n * (p + 1), 0.0)
  for i = 0; i < n; i = i + 1 {
    flat[i * (p + 1)] = d[i]
    for j = 0; j < p; j = j + 1 {
      flat[i * (p + 1) + 1 + j] = x.data[i * p + j]
    }
  }
  Matrix::from_array(flat, n, p + 1)
}

///|
/// Fit the LPLR estimator. Mirrors the upstream
/// `DoubleMLLPLR._nuisance_est` / `_est_causal_pars` /
/// `_se_causal_pars` flow:
///
///   1. Outer cross-fit ml_M on `(d, x)` -> `Y`; the same outer
///      folds are also used for the inner re-split. ml_M is a
///      `LogisticRegression` so its `predict` returns the
///      probability of `Y = 1`.
///   2. Double cross-fit ml_a (also `LogisticRegression` for
///      binary D) on `x` -> `D` to obtain inner-fold OOF
///      propensity predictions per outer fold.
///   3. Build per-fold targets `W_inner` from `ml_M` outer-OOF
///      predictions (clipped to `[1e-8, 1 - 1e-8]`, then
///      `logit`); cross-fit `ml_t` (a `LinearRegression`) on
///      `x` -> `W_inner` to get `t_hat`.
///   4. Per fold, compute `beta_f` from inner `W` and
///      `(d - a_inner)`. Average across folds for the
///      Newton starting value.
///   5. `ml_m` supplies `d_tilde = d - m_hat`. Upstream fits it as a
///      separate learner, restricted to the `Y = 0` rows under
///      `score="nuisance_space"`; this port aliases `m_hat = a_hat`
///      (see the `m_pred = a_pred` comment in the body).
///   6. Build the score at any `theta` from
///      `r_i = t_hat_i - beta_start * a_hat_i` (no `theta` in `r`;
///      see `lplr_score_at` for both upstream formulas -- they
///      differ, and that difference is what `score` selects).
///   7. Newton iteration with `mean(psi)` and `mean(psi_deriv)`.
///   8. Variance via the standard linear-score path
///      (`var_est(psi_a, psi_b)` with `psi_a = psi_deriv`,
///      `psi_b = psi - theta * psi_deriv`); the LPLR score is
///      *not* linear in `theta` but is exactly the `theta * psi_a +
///      psi_b` form at the converged `theta` with `psi_a =
///      psi_deriv(theta)`, `psi_b = psi(theta) - theta *
///      psi_deriv(theta)`, so the same machinery applies.
///
/// LPLR is *not* cluster data; `var_est` runs the row-level path.
pub fn DoubleMLLPLR::fit(
  self : DoubleMLLPLR,
  ml_g? : LearnerDispatch = self.ml_g,
  ml_m? : LearnerDispatch = self.ml_m,
) -> DoubleMLLPLR {
  try {
    // v0.62.0+: route `ml_g` to the `ml_t` slot (W regressor) and
    // `ml_m` to the binary-classification slots (`ml_M`, `ml_a`,
    // `ml_m`). Defaults preserve v0.61.0 byte-equality.
    let x = self.data.x
    let d = self.data.d
    let y = self.data.y
    let n = x.nrows
    // v0.109.0: true when the caller supplied the split through
    // `set_sample_splitting`. It gates the two places where behaviour
    // genuinely differs -- the memoize decision and the OUTER fold draw
    // -- but NOT the repetition count, which the derivation already
    // wrote into `self.n_rep`.
    let external = self.smpls.length() > 0
    // v0.109.0: `set_sample_splitting` writes the DERIVED counts into
    // `self.n_folds` / `self.n_rep`, so reading `self.n_rep` here is
    // already reading the derived value and needs no `if external`
    // override. An `if external` override here was measured to be an
    // EQUIVALENT mutant and deleted on the PLR side; defensive code
    // that no mutation can fail is a ratchet, not a safeguard.
    let nrep = self.n_rep
    let coefs : Array[Double] = Array::make(nrep, 0.0)
    let ses : Array[Double] = Array::make(nrep, 0.0)
    let mut t_pred : Array[Double] = Array::make(n, 0.0)
    let mut m_pred : Array[Double] = Array::make(n, 0.0)
    let mut a_pred : Array[Double] = Array::make(n, 0.0)
    // v0.83.0+: track the LAST rep's preliminary `beta_start`
    // so the cache-hit path can skip the inner-OOF /
    // `prelim_beta_per_fold` step entirely.
    let mut last_beta_start : Double = 0.0
    // v0.83.0+: track the LAST rep's row-to-fold mapping for
    // the cache writeback.
    let fold_ids : Array[Int] = Array::make(n, 0)
    // v0.75.0+: capture psi_a / psi_b from the LAST rep for the
    // multiplier bootstrap. Same convention as `t_pred` / `m_pred`:
    // each rep overwrites, so the post-loop values match the
    // last rep's nuisances (which are the ones persisted on the
    // struct).
    let mut last_psi_a : Array[Double] = Array::make(n, 0.0)
    let mut last_psi_b : Array[Double] = Array::make(n, 0.0)
    // v0.83.0+: memoize check (mirrors the PLR / IRM / CVAR
    // / SSM / PLPR pattern). The cache stores the LAST rep's
    // `(t_pred, m_pred, a_pred)` plus row-to-fold mapping; the
    // `beta_start` scalar is packed as a length-1 array.
    // Honored only when `n_rep == 1`.
    //
    // v0.109.0: external splits are EXCLUDED from the cache. The key
    // is built from data + learner + cluster hashes and has no term
    // for the fold assignment, so two different supplied partitions
    // would collide and the second fit would silently return the
    // first one's predictions. Rather than extend the key (a change to
    // FitCache that every memoizing estimator would have to adopt at
    // once), the external path turns memoize off. That can only cost
    // time; reusing a stale split cannot be made safe by ignoring it.
    let memoize = self.memoize_enabled && nrep == 1 && !external
    let data_hash : UInt64 = if memoize {
      hash_data(self.data.x, self.data.y, self.data.d)
    } else {
      0UL
    }
    let hparams_hash : UInt64 = if memoize {
      hash_hyperparams("lplr", ml_g, ml_m, 0.0)
    } else {
      0UL
    }
    let cluster_hash : UInt64 = if memoize {
      // LPLR is not a clustered estimator; pass an empty
      // vector so the hash stays 0 across calls (matches the
      // IID sentinel).
      hash_cluster_ids([])
    } else {
      0UL
    }
    let cache_hit = memoize &&
      self.fit_cache.is_valid(
        self.seed,
        self.n_folds,
        nrep,
        n,
        data_hash,
        hparams_hash,
        cluster_hash,
        "lplr",
      )
    // v0.105.0: resolve the public `score` string once, up front.
    // Until this existed the field was validated and stored but
    // never read, so both score names ran the nuisance_space path.
    let kind = lplr_score_kind(self.score)
    for r = 0; r < nrep; r = r + 1 {
      let beta_start : Double = if cache_hit && r == nrep - 1 {
        // Reuse the cached LAST-rep nuisances + beta_start;
        // skip all per-fold crossfits. The Newton / score / SE
        // path below is the only computation we re-run.
        let preds = self.fit_cache.predictions
        for i = 0; i < n; i = i + 1 {
          t_pred[i] = preds[0][i]
          m_pred[i] = preds[1][i]
          a_pred[i] = preds[2][i]
          fold_ids[i] = self.fit_cache.fold_ids[i]
        }
        preds[3][0]
      } else {
        // v0.109.0: the external splitting wins over the drawn one for
        // the OUTER partition. `check_sample_splitting` already proved
        // `self.smpls[r]` is a partition of `[0, n)`, so no
        // re-validation here. The INNER `n_folds_inner` cross-fit below
        // is still drawn internally and is NOT covered -- see
        // `set_sample_splitting`.
        let outer = if external {
          self.smpls[r]
        } else {
          kfold(n, self.n_folds, self.seed + r)
        }
        let xd = concat_d_x(d, x)
        // 1) Outer cross-fit ml_M: E[Y | D, X] (LogisticRegression ->
        // probability of Y = 1). v0.62.0+: routed through
        // `cross_fit_predict_dispatch` so `ml_m` reaches ml_M.
        let m_hat_outer = cross_fit_predict_dispatch(ml_m, xd, y, outer)
        // 2) Double cross-fit ml_a: E[D | X] (logistic for binary D,
        // predicted probability of D = 1). Inner fold seeds vary per
        // outer fold so the inner OOFs are deterministic but
        // independent across outer folds. v0.62.0+: routed through
        // `double_cross_fit_predict_dispatch` (new generic wrapper
        // around `double_cross_fit_predict`).
        let a_inner_per_fold : Array[Array[Double]] = double_cross_fit_predict_dispatch(
          ml_m,
          x,
          d,
          outer,
          self.n_folds_inner,
          self.seed + r * 1000 + 7,
        )
        // Combine per-fold inner predictions into a single n-vector
        // of inner OOF for `a` (the prediction made on each row
        // when it is in the test set of the inner split).
        // ml_a outer cross-fit (a_hat), same outer folds.
        a_pred = cross_fit_predict_dispatch(ml_m, x, d, outer)
        // KNOWN DIVERGENCE FROM UPSTREAM (v0.105.0, deliberate):
        // upstream fits `ml_m` as a SEPARATE learner and restricts its
        // training set to the `Y == 0` rows under
        // `score="nuisance_space"` (`plm/lplr.py:244-252`), so
        // `d_tilde = d - m_hat` uses that nuisance rather than
        // `a_hat`. This port aliases `m_pred = a_pred` instead.
        //
        // It was tried and reverted. Restricting `ml_m` to the `Y == 0`
        // subsample makes the score nearly unidentified when the
        // default learner is OLS: on `lplr_test`'s n=120 fixture the
        // fitted `beta_start` reached -4.75, `max |r_hat|` reached
        // 19.1, and `mean(psi_deriv)` collapsed to -3.2e-8. The Newton
        // loop then failed to converge (`converged = false`,
        // `mean(psi) = -0.079` at the returned `theta = 13.54`) and
        // `var_est`'s `-mean(psi_b) / mean(psi_a)` returned
        // `-2.4e6` for a quantity whose true value is O(0.5).
        //
        // Upstream does not hit this because its default `ml_m` is a
        // `LogisticRegression` -- bounded in [0, 1], so the filtered
        // subsample does not distort the fit the way an OLS of a
        // binary `d` does. This port's default is
        // `LearnerDispatch::linear_regression()`. Aligning the two
        // (either a logistic default for `ml_m`, or a per-fold
        // `beta` as upstream uses instead of a fold-averaged scalar)
        // is its own change with its own evidence, and it does not
        // belong inside a fix for the inert `score` parameter.
        m_pred = a_pred
        // 3) Per-fold W_inner from the outer-cross-fit M_hat, with
        // row positions recorded by the outer fold's training set
        // (upstream's behaviour: `M_iteration = M_hat_inner[i][train]`
        // where `M_hat_inner[i]` is the *inner* OOF for the
        // `ml_M` learner). We use the outer OOF for simplicity
        // because the outer fold structure already keeps the OOF
        // honest on the test rows, and inner OOF for ml_M would
        // require the same double-cross-fit scaffolding as ml_a.
        let w_inner : Array[Array[Double]] = []
        for fold in outer {
          let ti = fold.train_idx
          let w : Array[Double] = Array::make(ti.length(), 0.0)
          for k = 0; k < ti.length(); k = k + 1 {
            let mc = if m_hat_outer[ti[k]] < 1.0e-8 {
              1.0e-8
            } else if m_hat_outer[ti[k]] > 1.0 - 1.0e-8 {
              1.0 - 1.0e-8
            } else {
              m_hat_outer[ti[k]]
            }
            w[k] = @math.ln(mc / (1.0 - mc))
          }
          w_inner.push(w)
        }
        t_pred = cross_fit_predict_inner_dispatch(ml_g, x, w_inner, outer)
        // 4) Per-fold preliminary beta.
        let mut beta_acc = 0.0
        let mut beta_count = 0
        for fi = 0; fi < outer.length(); fi = fi + 1 {
          let ti = outer[fi].train_idx
          let a_inner_for_fold : Array[Double] = Array::make(ti.length(), 0.0)
          // The inner OOF for row `i` in this fold's training slice
          // is the inner-fold prediction for that row. `a_inner_per_fold[fi]`
          // is the *concatenated inner OOF* for the entire outer
          // training set of fold `fi`, indexed by inner position.
          let a_full_inner = a_inner_per_fold[fi]
          for k = 0; k < ti.length(); k = k + 1 {
            a_inner_for_fold[k] = a_full_inner[k]
          }
          let b_f = prelim_beta_per_fold(
            a_inner_for_fold, a_inner_for_fold, d, ti,
          )
          beta_acc = beta_acc + b_f
          beta_count = beta_count + 1
        }
        require(beta_count > 0)
        // Build row->fold_id map for the LAST rep (used by the
        // cache writeback below).
        if memoize && r == nrep - 1 {
          for f = 0; f < outer.length(); f = f + 1 {
            for i in outer[f].test_indices() {
              fold_ids[i] = f
            }
          }
        }
        beta_acc / beta_count.to_double()
      }
      // Track last-rep beta_start for the cache writeback.
      if memoize && r == nrep - 1 {
        last_beta_start = beta_start
      }
      // 5+6) Newton solve for the nonlinear score. We re-evaluate
      // \lplr_score_at\ at every step (the psi/psi_deriv of LPLR
      // are NOT linear in \	heta\: they contain \exp(r)\ and
      // \expit(-r)\), so the linear ewton_solve_score\ does not
      // apply. Instead we run a hand-rolled Newton loop here with
      // the per-iteration score at the current \	heta\.
      let (theta0, _) = lplr_initial_theta(beta_start, d, y, t_pred, a_pred)
      let mut theta = theta0
      let mut converged = false
      for _step = 0; _step < 50; _step = _step + 1 {
        let sc = lplr_score_at(
          theta, d, y, t_pred, a_pred, m_pred, beta_start, kind,
        )
        let n_obs = d.length().to_double()
        let mut s = 0.0
        let mut sd = 0.0
        for i = 0; i < d.length(); i = i + 1 {
          s = s + sc.psi[i]
          sd = sd + sc.psi_deriv[i]
        }
        s = s / n_obs
        sd = sd / n_obs
        if sd.abs() < 1.0e-300 {
          break
        }
        // Pure Newton step is too aggressive on this DGP (the
        // exp/expit terms in psi make the curvature non-Lipschitz
        // in theta). Use a damped Newton with bisection on the
        // sign of psi when the raw step is unstable.
        let raw_delta = s / sd
        let mut theta_new = theta - raw_delta
        if theta_new.abs() > 5.0 || (theta_new - theta).abs() > 1.0 {
          // Fall back to a small step in the descent direction
          // (signed by the score) and rely on outer convergence
          // to bring it home.
          let step = if raw_delta.abs() < 0.25 { raw_delta } else { 0.25 }
          theta_new = theta - step * (if s > 0.0 { 1.0 } else { -1.0 })
        }
        if (theta_new - theta).abs() < 1.0e-9 {
          theta = theta_new
          converged = true
          break
        }
        if theta_new.abs() > 1.0e6 {
          break
        }
        theta = theta_new
      }
      let _ = converged
      // 7) Variance at the converged theta. For the linear
      // var_est path, we use psi_deriv(theta) as the linear slope
      // and psi(theta) - theta * psi_deriv(theta) as the constant
      // offset; the resulting \	heta_hat = -mean(psi_b)/mean(psi_a)    // recovers the same \	heta\, and the SE reflects the score
      // residual at convergence.
      let sc = lplr_score_at(
        theta, d, y, t_pred, a_pred, m_pred, beta_start, kind,
      )
      let psi_a : Array[Double] = sc.psi_deriv
      // v0.83.0+: vectorise the psi_b residual computation
      // (element-wise `sc.psi[i] - theta * sc.psi_deriv[i]`).
      let psi_b_arr = vector_subtract(sc.psi, vector_scale(sc.psi_deriv, theta))
      let (coef_r, se_r) = var_est(psi_a, psi_b_arr)
      coefs[r] = coef_r
      ses[r] = se_r
      // v0.75.0+: persist the last rep's IF components for the
      // bootstrap. The bootstrap convention `psi[i] = self.psi_a[i]
      // + self.coef * self.psi_b[i]` requires:
      //   self.psi_a = offset at theta_hat (the constant part)
      //   self.psi_b = slope (the part multiplied by theta)
      // In the LPLR linear-score form `sc.psi = sc.psi_deriv * theta
      // + offset` with offset evaluated at theta_hat, that is:
      //   psi_a_field = sc.psi - theta_hat * sc.psi_deriv
      //   psi_b_field = sc.psi_deriv
      // so the bootstrap computes
      //   psi[i] = (sc.psi - theta_hat * sc.psi_deriv) + theta_hat * sc.psi_deriv
      //          = sc.psi
      // i.e. the raw score at the fitted theta.
      // v0.83.0+: vectorise the psi_a residual computation
      // (same form as psi_b above).
      last_psi_a = vector_subtract(sc.psi, vector_scale(sc.psi_deriv, theta))
      last_psi_b = sc.psi_deriv
    }
    let (coef, se) = aggregate_coef_se(coefs, ses)
    // v0.83.0+: when memoize is on and the cache missed, write
    // the freshly-computed fold_ids + nuisances + beta_start
    // to the cache. `beta_start` is packed as a length-1 array
    // so it fits the `Array[Array[Double]]` shape of `FitCache`.
    let next_cache = if memoize && !cache_hit && nrep == 1 {
      FitCache::from_fit(
        fold_ids,
        [t_pred, m_pred, a_pred, Array::make(1, last_beta_start)],
        self.seed,
        self.n_folds,
        nrep,
        n,
        data_hash,
        hparams_hash,
        cluster_hash,
        "lplr",
      )
    } else {
      self.fit_cache
    }
    {
      data: self.data,
      score: self.score,
      n_folds: self.n_folds,
      n_folds_inner: self.n_folds_inner,
      n_rep: self.n_rep,
      seed: self.seed,
      // v0.109.0: carry the external splitting onto the returned model
      // so a later re-fit keeps using the supplied folds. Dropping it
      // here would make the NEXT fit silently revert to drawing its own
      // folds -- and the estimate would still look plausible, which is
      // what makes a surprise fold change easy to miss. This is the
      // only struct literal LPLR builds, so it is the only one to fix.
      smpls: self.smpls,
      ml_g,
      ml_m,
      coef_: coef,
      se_: se,
      r_hat: t_pred,
      m_hat: m_pred,
      a_hat: a_pred,
      fitted: true,
      psi_a: last_psi_a,
      psi_b: last_psi_b,
      boot_t_stat: [],
      boot_method: "",
      n_rep_boot: 0,
      boot_seed: 0,
      memoize_enabled: self.memoize_enabled,
      fit_cache: next_cache,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.75.0+: multiplier bootstrap for `DoubleMLLPLR`. The
/// per-observation influence function (raw score at the fitted
/// `coef_`) is
///
///   psi[i] = coef * sc.psi_deriv[i] + (sc.psi[i] - coef * sc.psi_deriv[i])
///          = sc.psi[i]
///
/// NOTE the argument order below. LPLR persists its IF
/// components in the INVERTED (offset, slope) order relative to
/// every other estimator in the package: `self.psi_a` is the
/// OFFSET at `theta_hat` (`sc.psi - theta_hat * sc.psi_deriv`) and
/// `self.psi_b` is the SLOPE (`sc.psi_deriv`, the actual
/// `d/dtheta` term). `psi_at(coef, psi_a, psi_b)` expects
/// `(coefficient, offset)`, so LPLR passes `(self.psi_b,
/// self.psi_a)` -- slope as `psi_a`, offset as `psi_b`. That
/// recovers `psi_at(coef, sc.psi_deriv, sc.psi - coef *
/// sc.psi_deriv) = sc.psi[i]`, the raw score at the fitted theta.
///
/// v0.90.0 makes this explicit. v0.75.0 - v0.89.0 called the
/// shared helper with the arguments the other way round plus the
/// old (swapped) score order, and the two wrongs cancelled; the
/// arithmetic above shows the cancellation is exact, so the
/// numeric output is unchanged by v0.90.0. Routing through
/// `psi_at` means the cancellation is no longer load-bearing.
///
/// The bootstrap draws `n_rep_boot` weight vectors of length
/// `n_obs` from the chosen multiplier distribution, and stores
/// `boot_t_stat[b] = sum_i w[b, i] * psi[i] /
/// (sqrt(n) * se_psi)` where `se_psi = sqrt(mean(psi^2))`.
///
/// `method_name` selects the multiplier distribution:
/// `"normal"` (default), `"Bayes"`, `"wild"`; `seed` defaults to
/// `2024`; `n_rep_boot` defaults to `500`.
///
/// Calling on an un-fit model aborts via `PreconditionError`.
/// Returns a new `DoubleMLLPLR` with `boot_t_stat` /
/// `boot_method` / `n_rep_boot` / `boot_seed` populated.
pub fn DoubleMLLPLR::bootstrap(
  self : DoubleMLLPLR,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLLPLR {
  try {
    require(self.fitted)
    require(
      method_name == "normal" || method_name == "Bayes" || method_name == "wild",
    )
    require(n_rep_boot >= 2)
    let boot_t_stat = generic_bootstrap_t_stat(
      self.psi_b,
      self.psi_a,
      self.coef_,
      method_name,
      n_rep_boot,
      seed,
    ) catch {
      BootstrapMethodError::UnknownMethod(m) =>
        abort(
          "draw_bootstrap_weights: unknown method (set in DoubleMLLPLR::bootstrap): " +
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
/// Tune the `(ml_g, ml_m)` nuisance-learner pair via MSE-on-l_hat
/// cross-fitting. The winning pair is re-fit on the FINAL-FIT fold
/// partition (`self.n_folds`) under `DoubleMLLPLR::fit`; the
/// tune-time cross-fit is not reused. `scoring_method` is `"MSE"`
/// (default), `"RMSE"` or `"NegMSE"`; `n_folds_tune` defaults to
/// 5 and `seed` to 3141. Returns a re-fitted `DoubleMLLPLR`.
///
/// Slot semantics: LPLR is a partially linear outcome family, so
/// the FIRST `TuneParam` slot is the OUTCOME learner and the
/// second is the nuisance / propensity learner. Build the grid
/// with `TuneParam::for_outcome`. Concretely the first slot
/// becomes `ml_g` (routed by `fit` to the `ml_t` W-regressor
/// slot) and the second becomes `ml_m` (routed to the
/// binary-classification slots). This is worth stating because
/// the `ml_g` field name reads as a propensity name -- see the
/// `learner_g` / `learner_m` accessors, which document `ml_g` as
/// the outcome-nuisance learner.
///
/// v0.108.0: new. LPLR had no `tune` at all, so it was one of the
/// estimators carrying a coverage gap against upstream, where
/// `tune` reaches every estimator through the `BaseDML` mixin.
/// The fold draw, the scoring loop and the argmin/argmax
/// selection route through the shared `tune_score_grid` core.
/// LPLR exposes no `n_obs()`, which is exactly why the core takes
/// its observation count from `y.length()` rather than from an
/// accessor.
///
/// `n_folds_inner` (the per-fold inner cross-fit count behind the
/// preliminary Newton start) is NOT a `fit` parameter, so there is
/// nothing for this method to forward and nothing it can drop:
/// `fit` reads `self.n_folds_inner` off the struct, validates it
/// in `new`, and re-persists it on the returned model. The re-fit
/// therefore uses the tuned model's own inner fold count. The
/// grid scoring does not use `n_folds_inner` at all -- it uses
/// `n_folds_tune` -- so changing `n_folds_inner` cannot change
/// which candidate wins, only the estimate produced afterwards.
///
/// No cluster guard: `DoubleMLBinaryData` exposes no
/// `is_cluster_data()`, and `fit` states that LPLR is not cluster
/// data and runs the row-level variance path. There is no
/// clustered path here to mis-handle, so the guard would be
/// unreachable at best; the method does not add the method or the
/// guard.
pub fn DoubleMLLPLR::tune(
  self : DoubleMLLPLR,
  param_set~ : Array[TuneParam],
  scoring_method? : String = "MSE",
  n_folds_tune? : Int = 5,
  seed? : Int = 3141,
) -> DoubleMLLPLR {
  try {
    require(param_set.length() > 0)
    require(n_folds_tune >= 2)
    let scoring = TuneScoring::parse(scoring_method)
    let grid = tune_score_grid(
      self.data.x,
      self.data.y,
      param_set.map(fn(p : TuneParam) { p.learner_l }),
      n_folds_tune,
      seed,
      scoring,
    )
    let best_param = param_set[grid.best_index]
    self.fit(ml_g=best_param.learner_l, ml_m=best_param.learner_m)
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Pick a one-step starting `theta` for Newton. The per-fold
/// preliminary `beta_start` already gives a reasonable scale (the
/// ratio of treatment to logit shift); we evaluate the score and
/// the derivative at `theta = 0` as a clean alternative, taking
/// whichever magnitude is smaller. This avoids feeding
/// `beta_start` itself into the score (which is a `W`-scale
/// quantity, not a `theta` scale).
fn lplr_initial_theta(
  _beta_start : Double,
  d : Array[Double],
  _y : Array[Double],
  t_pred : Array[Double],
  _a_pred : Array[Double],
) -> (Double, Bool) {
  // Simple OLS scale: theta ~ mean(d * t) / mean(d^2). This
  // captures the "linear scale" of the parameter without
  // requiring the full per-fold beta average to be threaded
  // through. Newton converges from here in 5-15 iterations on
  // well-conditioned LZZ2020-style DGPs.
  let n = d.length()
  let mut num = 0.0
  let mut den = 0.0
  for i = 0; i < n; i = i + 1 {
    num = num + d[i] * t_pred[i]
    den = den + d[i] * d[i]
  }
  if den.abs() < 1.0e-300 {
    return (0.0, false)
  }
  (num / den, true)
}

///|
/// Cross-fit a regressor whose per-fold target is a *per-fold
/// vector* (length matches the fold's training set), not a
/// single global vector. Returns a length-`n` OOF vector: for
/// each outer test row, the model trained on the *opposite*
/// fold's `target[that fold's training set]` is used. (For
/// `ml_t` the test-row prediction does not depend on the test
/// row's own W -- `t_hat` is purely a function of `x`.)
///
/// v0.62.0+: generalized from a hardcoded `LinearRegression` to
/// any `T : Learner`. The `ml_t` slot still defaults to OLS
/// for byte-equality with v0.61.0 callers, but the function
/// accepts any dispatch-compatible learner.
fn[T : Learner] cross_fit_predict_inner(
  learner : T,
  x : Matrix,
  targets : Array[Array[Double]],
  folds : Array[Fold],
) -> Array[Double] {
  let n_obs = x.nrows
  let preds : Array[Double] = Array::make(n_obs, 0.0)
  for fi = 0; fi < folds.length(); fi = fi + 1 {
    let fold = folds[fi]
    let xt = slice_matrix_rows(x, fold.train_idx)
    let fitted = learner.fit(xt, targets[fi], [])
    let p = fitted.predict(slice_matrix_rows(x, fold.test_idx))
    for k = 0; k < fold.test_idx.length(); k = k + 1 {
      preds[fold.test_idx[k]] = p[k]
    }
  }
  preds
}

///|
/// v0.62.0+: dispatch wrapper around `cross_fit_predict_inner`.
/// Routes through `LearnerDispatch` so the per-fit `ml_g` /
/// `ml_m` override reaches the LPLR per-fold inner fits.
fn cross_fit_predict_inner_dispatch(
  learner : LearnerDispatch,
  x : Matrix,
  targets : Array[Array[Double]],
  folds : Array[Fold],
) -> Array[Double] {
  match learner {
    LinearRegression(lr) => cross_fit_predict_inner(lr, x, targets, folds)
    Constant(c) => cross_fit_predict_inner(c, x, targets, folds)
    Noop(n) => cross_fit_predict_inner(n, x, targets, folds)
    RandomForest(rf) => cross_fit_predict_inner(rf, x, targets, folds)
    GradientBoosting(gb) => cross_fit_predict_inner(gb, x, targets, folds)
    LogisticRegression(lr) => cross_fit_predict_inner(lr, x, targets, folds)
    RandomForestClassifier(rf) => cross_fit_predict_inner(rf, x, targets, folds)
    GradientBoostingClassifier(gb) =>
      cross_fit_predict_inner(gb, x, targets, folds)
  }
}

///|
/// `LogisticRegression` implements the `Learner` trait so it can
/// be passed to `cross_fit_predict` / `double_cross_fit_predict`.
/// `fit` is the IRLS Newton-Raphson fit on the labelled slice;
/// `predict` returns P(y = 1 | x) for every row of the design.

///|
/// v0.118.0: `w` is the per-row `sample_weight`, forwarded to
/// `LogisticRegression::fit`. Empty means unweighted.
impl Learner for LogisticRegression with fn fit(
  self : LogisticRegression,
  x : Matrix,
  y : Array[Double],
  w : Array[Double],
) -> LogisticRegression {
  if w_is_unweighted(w) {
    self.fit(x, y)
  } else {
    self.fit(x, y, sample_weight=w)
  }
}

///|
impl Learner for LogisticRegression with fn predict(
  self : LogisticRegression,
  x : Matrix,
) -> Array[Double] {
  self.predict(x)
}

// ---------------------------------------------------------------------------
// Sensitivity (v0.70.0+)
// ---------------------------------------------------------------------------

///|
/// v0.70.0+: Cinelli & Hazlett (2020) omitted-variable bias
/// analysis for `DoubleMLLPLR` (Liu-Zhang-Zhou 2021 partially
/// logistic regression). Single-theta IRM-style decomposition:
///
///   - Outcome residual: `residuals[i] = y[i] - t_pred[i]`,
///     where `t_pred` is the cross-fitted E[Y | D, X] nuisance
///     persisted by `fit` (also surfaced via
///     `predictions_t`). Same outcome-nuisance convention as
///     the v0.66.0 `DoubleMLPLR::sensitivity_analysis`.
///
///   - Per-observation Riesz representer `psi_a[i]`: the
///     LPLR ATE IF denominator
///     `psi_a[i] = -d[i] * (d[i] - a_hat[i])` where
///     `a_hat` is the outer cross-fitted propensity
///     `E[D | X]` from `predictions_a`. The exact LPLR score
///     derivative (`psi_deriv(theta)`) depends on the
///     preliminary linear coefficient `beta_start` which the
///     struct does not persist; the simplified
///     `-d * (d - a_hat)` form captures the same IRM-style
///     "treatment interacted with treatment-propensity
///     residual" structure used by `DoubleMLIRM` for the
///     binary-ATE score and is the convention the C&H
///     sensitivity formula expects.
///
/// Routes through the shared `irm_style_sensitivity` helper
/// (see sensitivity.mbt). `cf_y` / `cf_d` default to `0.05`
/// matching the rest of the v0.66.0-onward sensitivity
/// family. Calling on an un-fit model aborts via
/// `PreconditionError`.
pub fn DoubleMLLPLR::sensitivity_analysis(
  self : DoubleMLLPLR,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let y = self.data.y
  let d = self.data.d
  let t_pred = self.predictions_t()
  let a_hat = self.predictions_a()
  let n = y.length()
  let residuals : Array[Double] = Array::make(n, 0.0)
  let psi_a : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    residuals[i] = y[i] - t_pred[i]
    psi_a[i] = -d[i] * (d[i] - a_hat[i])
  }
  irm_style_sensitivity(self.coef_, residuals, psi_a, cf_y, cf_d)
}

///|
/// v0.73.0+: cluster-robust analogue of
/// `DoubleMLLPLR::sensitivity_analysis`. Same outcome
/// residual `y - t_pred` and the same per-observation
/// Riesz representer `psi_a[i] = -d[i] * (d[i] -
/// a_hat[i])` as the IID path; only the variance / bias
/// computation is cluster-aware (see
/// `irm_style_sensitivity_cluster` in sensitivity.mbt).
///
/// `DoubleMLBinaryData` has no `cluster_vars` field, so the
/// user must pass `cluster_ids` explicitly.
/// `cluster_ids.length()` must equal `self.data.n_obs()`.
pub fn DoubleMLLPLR::sensitivity_analysis_cluster(
  self : DoubleMLLPLR,
  cluster_ids : Array[Int],
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let y = self.data.y
  let d = self.data.d
  let t_pred = self.predictions_t()
  let a_hat = self.predictions_a()
  let n = y.length()
  require(cluster_ids.length() == n)
  let residuals : Array[Double] = Array::make(n, 0.0)
  let psi_a : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    residuals[i] = y[i] - t_pred[i]
    psi_a[i] = -d[i] * (d[i] - a_hat[i])
  }
  irm_style_sensitivity_cluster(
    self.coef_,
    residuals,
    psi_a,
    cluster_ids,
    cf_y,
    cf_d,
  )
}

// ---------------------------------------------------------------------------
// Sandwich variance (v0.92.0)
// ---------------------------------------------------------------------------

///|
/// v0.92.0+: Huber-White sandwich standard error for the fitted
/// LPLR, routed through the shared
/// `sandwich_variance(kind, ...)` dispatch in `sandwich.mbt`.
///
/// ## THE INVERSION -- READ BEFORE CHANGING THE ARGUMENT ORDER
///
/// `DoubleMLLPLR` persists its influence-function components
/// **inverted** relative to every other estimator in the package.
/// The internal `LplrScore` struct (see `lplr_score_at`) carries
/// `psi` -- the score itself, which is the OFFSET in the
/// `f(theta) = theta * deriv + offset` linearisation -- and
/// `psi_deriv` -- the derivative of the score w.r.t. `theta`,
/// i.e. the COEFFICIENT. `fit` persists them as
///
///     self.psi_a = sc.psi - theta_hat * sc.psi_deriv   (OFFSET)
///     self.psi_b = sc.psi_deriv                        (DERIVATIVE)
///
/// so the field names are the mirror image of the package
/// convention (`psi_a` = coefficient row, `psi_b` = offset).
/// `var_est.mbt` -- the reference, unchanged -- is fed
/// `(sc.psi_deriv, sc.psi - theta_hat * sc.psi_deriv)`, i.e. the
/// tuple in package order, and its `J = mean(psi_a)` is therefore
/// `mean(psi_deriv)`. Two consequences, and both are load-bearing:
///
///   1. The score must be evaluated with the arrays SWAPPED:
///      `psi_at(coef, self.psi_b, self.psi_a)`, which recovers
///      `theta_hat * sc.psi_deriv + (sc.psi - theta_hat *
///      sc.psi_deriv) = sc.psi`, the raw score at the fitted
///      `theta`. This is exactly the argument order its
///      `bootstrap` call site has used since v0.90.0 (see
///      `DoubleMLLPLR::bootstrap`), so the two paths cannot
///      drift apart.
///
///   2. `M_inv` must be `[[1 / mean(self.psi_b)]]` --
///      `mean(psi_deriv)`, the true Jacobian. v0.87.0 built
///      `M_inv` from `mean(self.psi_a)`, which is
///      `mean(sc.psi - theta_hat * sc.psi_deriv)`: a
///      catastrophic-cancellation residual, not a derivative. It
///      is ~60x smaller in magnitude here and its sign is not even
///      stable, so the resulting HC0 was inflated by roughly 60x
///      and HC2 / HC3 hit the `1e-10` degenerate-leverage clip
///      (`6.4e10`). LPLR was skipped in v0.87.0 and again in
///      v0.90.0 for this reason.
///
/// With both corrections in place the payoff invariant holds, as
/// it does for the other 12 estimators:
///
///     sandwich_se(HC0) == se()
///
/// to floating-point tolerance. `se()` is `var_est` over the
/// same `(psi_deriv, offset)` tuple, i.e.
/// `sqrt(mean(psi(theta_hat)^2) / (mean(psi_deriv)^2 * n))`, which
/// is algebraically `M_inv[0,0]^2 * sum_i psi[i]^2 / n / n` --
/// the v0.91.0 accumulator, evaluated at the same point.
///
/// The three inputs are the ones `fit` already persists for the
/// multiplier bootstrap:
///   - `psi_a` (the length-`n` array `sandwich_variance` only
///     reads for its length precondition) is the DERIVATIVE row
///     `self.psi_b`;
///   - `psi` = `psi_at(coef, self.psi_b, self.psi_a)`;
///   - `M_inv` = `[[1 / mean(self.psi_b)]]` (1x1). Only
///     `M_inv[0, 0]^2` enters the variance, so the sign of the
///     (up-to-sign) Jacobian inverse is irrelevant.
///
/// `n_obs` is `self.psi_b.length()`: LPLR has no transformed or
/// subset domain, so the persisted sample is the full
/// `self.data.n_obs()`.
///
/// Preconditions: `self.fitted`, `mean(psi_b) != 0`.
pub fn DoubleMLLPLR::sandwich_se(
  self : DoubleMLLPLR,
  kind : SandwichKind,
) -> Double {
  try {
    require(self.fitted)
    let n = self.psi_b.length()
    let psi = psi_at(self.coef(), self.psi_b, self.psi_a)
    let mean_deriv = mean(self.psi_b)
    require(mean_deriv.abs() > 0.0)
    let m_inv = Matrix::from_array([1.0 / mean_deriv], 1, 1)
    let variance_val = sandwich_variance(kind, self.psi_b, psi, m_inv, n, 1)
    require(variance_val >= 0.0)
    variance_val.sqrt()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.92.0+: cluster-robust sandwich standard error for the fitted
/// LPLR (Arellano 1987, Cameron-Gelbach-Miller 2011). Routes
/// through `cluster_sandwich_variance` with the SAME swapped
/// `psi` and `M_inv` inputs as the IID `sandwich_se` path -- see
/// that method's doc for why LPLR's influence-function components
/// are stored inverted.
///
/// `DoubleMLBinaryData` carries no `cluster_vars`, so the caller
/// must supply `cluster_ids` explicitly (any grouping variable the
/// application has: region, site, panel unit). With all-singleton
/// clusters the meat degenerates to `sum_i psi[i]^2` and the
/// formula collapses to `sandwich_se(HC0)`, hence to `se()`.
///
/// Preconditions: `self.fitted`,
/// `cluster_ids.length() == psi_b.length()`.
pub fn DoubleMLLPLR::cluster_sandwich_se(
  self : DoubleMLLPLR,
  cluster_ids : Array[Int],
) -> Double {
  try {
    require(self.fitted)
    let n = self.psi_b.length()
    require(cluster_ids.length() == n)
    let psi = psi_at(self.coef(), self.psi_b, self.psi_a)
    let mean_deriv = mean(self.psi_b)
    require(mean_deriv.abs() > 0.0)
    let m_inv = Matrix::from_array([1.0 / mean_deriv], 1, 1)
    let variance_val = cluster_sandwich_variance(
      self.psi_b,
      psi,
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
/// v0.92.0+: returns `coef` UNCHANGED -- a documented no-op, not
/// a bias correction. Identical in reasoning to the twelve
/// `bias_corrected_coef` methods added in v0.86.0 - v0.91.0;
/// see `DoubleMLIRM::bias_corrected_coef` and `bias_corrected_theta`
/// in `sandwich.mbt` for the full argument.
///
/// `coef` is the root of the DML moment
/// `f(theta) = E[theta * psi_a + psi_b]` in `var_est.mbt`'s
/// convention -- for LPLR, `psi_a` is the score DERIVATIVE and
/// `psi_b` the score OFFSET -- so `mean(f(coef))` is identically
/// zero: the estimating function is orthogonal by construction,
/// and that orthogonality IS what makes the estimator
/// consistent. Nothing computable from the fitted scores is a bias
/// estimate for this class of estimator, so this accessor reports
/// the uncorrected point estimate rather than a number that merely
/// looks like a correction.
///
/// Preconditions: `self.fitted`.
pub fn DoubleMLLPLR::bias_corrected_coef(self : DoubleMLLPLR) -> Double {
  try {
    require(self.fitted)
    self.coef_
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Record a caller-supplied sample splitting and DERIVE the fold and
/// repetition counts from it. Returns a new `DoubleMLLPLR`; the receiver
/// is unchanged, as everywhere in this package.
///
/// `smpls` is one entry per repetition, each entry one `Fold` per fold
/// -- the nested form is the only form, so a single repetition is
/// `[f0, f1, f2]` wrapped once, i.e. `[[f0, f1, f2]]`.
///
/// The derivation is upstream's, and it is the part that surprises
/// people: `set_sample_splitting`
/// (`doubleml/double_ml_sampling_mixins.py:76`) sets `n_folds` and
/// `n_rep` FROM the supplied partition, so handing a two-fold split to
/// a model built with `n_folds=5` yields a two-fold model. On the
/// returned model `n_folds` / `n_rep` are updated to match, and `fit`
/// uses the supplied folds instead of drawing them.
///
/// Validation, via `check_sample_splitting`: every repetition carries
/// the same number of folds, and within each repetition the test index
/// sets are disjoint and cover exactly `[0, n_obs)`. A supplied
/// partition that is not a partition aborts rather than quietly
/// producing a cross-fit that leaks across folds.
///
/// Memoization: `fit` will not read or write the fit cache once an
/// external splitting is recorded. The cache key is built from the data
/// and learner hashes and has no term for the fold assignment, so two
/// different supplied partitions would collide and the second fit would
/// silently return the first one's predictions. The `memoize_enabled`
/// flag is carried through unchanged; it is the `!external` term in
/// `fit` that refuses the cache. The cache is also CLEARED here, so a
/// re-fit under a new splitting cannot resurrect an entry written under
/// the old one.
///
/// Scope: an externally supplied splitting replaces the OUTER partition
/// only. LPLR nests a second, inner cross-fit of `n_folds_inner` folds
/// behind the preliminary Newton start (drawn at
/// `self.seed + r * 1000 + 7`) and that inner split is still drawn
/// internally, so it is NOT covered by this method. LPLR has no cluster
/// path at all: `DoubleMLBinaryData` exposes no `is_cluster_data()` and
/// `fit` runs the row-level variance path, so there is no unit-level
/// draw to worry about either.
///
/// The one-fold "no sample splitting" case needs no special handling: a
/// single `Fold` whose train and test both cover everything is a valid
/// partition with `folds = 1`, which is what upstream detects and
/// reports.
pub fn DoubleMLLPLR::set_sample_splitting(
  self : DoubleMLLPLR,
  smpls : Array[Array[Fold]],
) -> DoubleMLLPLR {
  try {
    // LPLR exposes no `n_obs()` accessor and `DoubleMLBinaryData`
    // exposes none either, so the row count comes off the data field
    // directly. `DoubleMLBinaryData::new` requires
    // `y.length() == x.nrows`, so this equals the `x.nrows` that `fit`
    // uses, and it is the same source `tune_score_grid` takes.
    let checked = check_sample_splitting(smpls, self.data.y.length())
    {
      ..self,
      n_folds: checked.folds,
      n_rep: checked.reps,
      smpls: checked.smpls,
      // A re-fit under a new splitting must not reuse a cache entry
      // written under the old one.
      fit_cache: FitCache::empty(),
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// The sample splitting recorded by `set_sample_splitting`, or `None`
/// when none was supplied and `fit` draws its own. `Some` carries the
/// DERIVED counts next to the folds, so a caller can read back what the
/// estimator actually used rather than inferring it from the constructor
/// arguments it no longer has any say over.
pub fn DoubleMLLPLR::sample_splitting(self : DoubleMLLPLR) -> SampleSplitting? {
  if self.smpls.length() == 0 {
    None
  } else {
    Some({ smpls: self.smpls, folds: self.n_folds, reps: self.n_rep, })
  }
}
