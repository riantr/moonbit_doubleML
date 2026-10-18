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
/// Two scores are supported, exactly as upstream's SCORE FORMULAS:
///   - `"nuisance_space"`: `psi_hat * (y*exp(-theta*D)*d_tilde -
///     d_tilde*(1-Y)*exp(r_hat))`, upstream `plm/lplr.py:522-524`.
///     The starting `beta` is computed per fold, one per fold, from the
///     inner predictions.
///   - `"instrument"`: the score itself is upstream's instrument-type
///     form `(Y - expit(theta*D + r_hat)) * (D - m_hat)`, with the
///     derivative upstream gives at `plm/lplr.py:536-538`. The
///     starting `beta` is still per-fold.
///
/// v0.105.0: the two SCORE FORMULAS used to be inert. `score` was
/// validated and stored but never read, so both strings returned the
/// nuisance_space answer bit for bit; `instrument` now produces a
/// genuinely different estimate.
///
/// WHAT IS NOT UPSTREAM, and is easy to assume otherwise: upstream also
/// CONDITIONS WHAT `ml_m` IS FITTED ON, per score
/// (`plm/lplr.py:244-264`) -- `Y = 0` subsamples for `nuisance_space`,
/// `M*(1-M)` sample weights for `instrument`. That is implemented on
/// neither branch here; `m_pred` is aliased to `a_pred`, unconditioned
/// and unweighted. See the `m_pred = a_pred` block in `fit` for the full
/// measurement and why it is held off.
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
  train_idx : Array[Int32],
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
  beta : Array[Double],
  kind : LplrScoreKind,
) -> LplrScore {
  // The Newton root of mean(score) gives theta_hat.
  let n = d.length()
  let psi : Array[Double] = Array::make(n, 0.0)
  let psi_deriv : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let r_hat = t_pred[i] - beta[i] * a_pred[i]
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
  tol_theta~ : Double = 1.0e-9,
  max_iter~ : Int32 = 50,
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
  n_folds : Int32
  n_folds_inner : Int32
  n_rep : Int32
  seed : Int32
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
  // v0.145.0: diagnostics from the most recent `fit(...)`, one entry per
  // repetition whose Newton solver failed to reach a solution. Empty array when
  // every repetition converged. Never printed -- read via
  // `DoubleMLLPLR::warnings`, which documents why.
  fit_warnings : Array[String]
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
  n_rep_boot : Int32
  boot_seed : Int32
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
  score~ : String = "nuisance_space",
  n_folds~ : Int32 = 2,
  n_folds_inner~ : Int32 = 2,
  n_rep~ : Int32 = 1,
  seed~ : Int32 = 3141,
  ml_g~ : LearnerDispatch = LearnerDispatch::linear_regression(),
  ml_m~ : LearnerDispatch = LearnerDispatch::logistic_regression(
    LogisticRegression::new(),
  ),
) -> DoubleMLLPLR {
  try {
    require(score == "nuisance_space" || score == "instrument")
    require(n_folds >= 2)
    require(n_folds_inner >= 2)
    require(n_rep >= 1)
    // `ml_m` drives BOTH binary-target nuisances: `M_hat = E[Y | X]` (fitted
    // on `y`) and `a_hat = E[D | X]` (fitted on `d`). Both targets are 0/1,
    // so the default has to be a CLASSIFIER. An OLS default predicts outside
    // [0, 1] on both, which is what upstream refuses to do: `_check_learner`
    // rejects a regressor for `ml_M` and `_check_is_propensity` rejects the
    // resulting out-of-range `ml_m` predictions (`lplr.py:268-269`).
    //
    // The old default was `linear_regression()`. It was not merely
    // less accurate -- it made the estimator unidentified on some fixtures
    // once the `Y == 0` conditioning below was switched on, which is why that
    // conditioning was reverted twice. See the `m_pred` block in `fit` and
    // `_verify/LPLR_GATE_BLINDNESS_1680.md`.
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
      fit_warnings: [],
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
/// Diagnostics from the most recent `fit(...)` call. v0.145.0+.
///
/// THE WARNING CONVENTION, since this package has none.
///
/// Until this release the package had no output channel of any kind -- no
/// `println`, no stderr -- and that is deliberate: a numerical library that
/// writes to the console makes its test output unreadable and its behaviour
/// untestable. It also meant that when the LPLR Newton solver failed to reach
/// a solution, `fit` discarded the flag (`let _ = converged`) and returned a
/// coefficient and standard error computed at a non-solution anyway. Upstream
/// warns here; this port had nowhere to.
///
/// So warnings are RETURNED, not emitted. The caller asks:
///
/// ```moonbit nocheck
/// let model = DoubleMLLPLR::new(data, alpha=1.5).fit()
/// for w in model.warnings() {
///   println(w)          // the CALLER decides whether to print
/// }
/// ```
///
/// That keeps the library silent, keeps the condition observable, and keeps it
/// testable -- a gate can assert that a degenerate design produces a warning
/// and a healthy one does not.
///
/// ONE ENTRY PER FAILED REPETITION, and the text names WHICH failure, because
/// the three are different problems:
///
/// | `stop_reason` | meaning |
/// |---|---|
/// | `degenerate_derivative` | `|d psi / d theta| < 1e-300` -- the Jacobian vanished, so the Newton direction is undefined |
/// | `diverged` | the iterate passed `1e6` and was abandoned |
/// | `exhausted_step_budget` | all 50 damped-Newton steps were used without meeting the `1e-9` step tolerance |
///
/// A non-empty result means `coef()` and `se()` are not an estimate and its
/// standard error. Note that `se()` is computed as `sqrt(gamma / (j^2 * n))`
/// with `j = mean(psi_deriv)`, so a non-solution point can yield a
/// deceptively SMALL standard error rather than a conspicuously large one --
/// the failure does not look like a failure.
pub fn DoubleMLLPLR::warnings(self : DoubleMLLPLR) -> Array[String] {
  self.fit_warnings
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
///   3. Build per-fold targets `W_inner` from `ml_M` INNER-OOF
///      predictions (clipped to `[1e-8, 1 - 1e-8]`, then
///      `logit`) -- upstream's `M_hat["preds_inner"][i][train]`
///      (`plm/lplr.py:318`); cross-fit `ml_t` (a `LinearRegression`)
///      on `x` -> `W_inner` to get `t_hat`.
///   4. Per fold, compute `beta_f` from inner `W` and
///      `(d - a_inner)`, and write it onto that fold's TEST rows
///      (`beta[test] = b_f`, `:323`). Average across rows for the
///      Newton starting value (`:326`).
///   5. `ml_m` supplies `d_tilde = d - m_hat`. Upstream fits it as a
///      separate learner, restricted to the `Y = 0` rows under
///      `score="nuisance_space"`; this port aliases `m_hat = a_hat`
///      (see the `m_pred = a_pred` comment in the body).
///   6. Build the score at any `theta` from
///      `r_i = t_hat_i - beta_i * a_hat_i` -- `beta_i` is that ROW's
///      value, not a shared scalar (`plm/lplr.py:345`); no `theta`
///      in `r`; see `lplr_score_at` for both upstream formulas -- they
///      differ, and that difference is what `score` selects.
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
  ml_g~ : LearnerDispatch = self.ml_g,
  ml_m~ : LearnerDispatch = self.ml_m,
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
    // v0.83.0+: track the LAST rep's preliminary `beta`
    // so the cache-hit path can skip the inner-OOF /
    // `prelim_beta_per_fold` step entirely.
    // v0.163.0 (D3): per-observation (length `n`), not a scalar.
    let mut last_beta_start : Array[Double] = []
    // v0.83.0+: track the LAST rep's row-to-fold mapping for
    // the cache writeback.
    let fold_ids : Array[Int32] = Array::make(n, 0)
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
    // `beta` vector is stored alongside as a fourth entry
    // (v0.163.0: length-`n` per-observation, not a length-1 scalar).
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
    // v0.145.0: diagnostics accumulated across reps. See the warning-convention
    // note on `DoubleMLLPLR::warnings` for why these are RETURNED rather than
    // printed -- the package deliberately has no output channel.
    let warnings : Array[String] = []
    for r = 0; r < nrep; r = r + 1 {
      let beta_start : Array[Double] = if cache_hit && r == nrep - 1 {
        // Reuse the cached LAST-rep nuisances + beta;
        // skip all per-fold crossfits. The Newton / score / SE
        // path below is the only computation we re-run.
        let preds = self.fit_cache.predictions
        for i = 0; i < n; i = i + 1 {
          t_pred[i] = preds[0][i]
          m_pred[i] = preds[1][i]
          a_pred[i] = preds[2][i]
          fold_ids[i] = self.fit_cache.fold_ids[i]
        }
        preds[3]
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
        //
        // v0.163.0 (D2): the OUTER OOF is no longer read anywhere below.
        // `W_inner` and the `beta` regression both moved to the INNER
        // cross-fit of the same learner (`m_inner_per_fold`), which is
        // what upstream reads (`plm/lplr.py:318`, `:323`). The outer
        // cross-fit was deleted rather than left as an unused binding
        // because an unused `let` is an error under `--deny-warn` -- and
        // because leaving it invites the next reader to wire it back in.
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
        // v0.163.0 (D2): the INNER cross-fit of `ml_M` -- E[Y | D, X] -- which
        // upstream reads at `plm/lplr.py:318`:
        //
        //     M_iteration = M_hat["preds_inner"][i][train]
        //     M_iteration = np.clip(M_iteration, 1e-8, 1 - 1e-8)
        //     w = scipy.special.logit(M_iteration)
        //
        // `w` is `W_inner`, handed to the `ml_t` inner cross-fit (`:332-341`)
        // and regressed on for `beta[test]` (`:323`). Before this both read
        // `m_hat_outer`, the OUTER OOF.
        //
        // The seed offset is deliberately IDENTICAL to `a_inner_per_fold`'s:
        // upstream draws both inner partitions from the one
        // `_DoubleML__smpls__inner`, so the ml_M and ml_a inner OOFs see the
        // same fold structure there and must here.
        let m_inner_per_fold : Array[Array[Double]] = double_cross_fit_predict_dispatch(
          ml_m,
          xd,
          y,
          outer,
          self.n_folds_inner,
          self.seed + r * 1000 + 7,
        )
        // Combine per-fold inner predictions into a single n-vector
        // of inner OOF for `a` (the prediction made on each row
        // when it is in the test set of the inner split).
        // ml_a outer cross-fit (a_hat), same outer folds.
        a_pred = cross_fit_predict_dispatch(ml_m, x, d, outer)
        // `d_tilde = d - m_hat` uses `ml_m`'s OWN nuisance, and upstream
        // conditions what that nuisance is FITTED on. The two scores differ
        // (`plm/lplr.py:244-252`):
        //
        //   score == "nuisance_space":  train_filtered = train[y[train] == 0]
        //                               -- no sample weights
        //   score == "instrument":     filtered_smpls = smpls  (unfiltered)
        //                               weights = M * (1 - M)
        //
        // This port ALIASES `m_pred = a_pred` for BOTH, which is `a_hat`
        // fitted on the whole sample with no conditioning -- correct for
        // neither. The two branches above are NOT implemented.
        //
        // The conditioning gates what the model is FITTED on, NOT what it
        // predicts on: the test fold is the full fold in both cases. Reading
        // that the other way round would leave rows in a fallback regime.
        //
        // It was implemented and reverted twice before this, and both reverts
        // were correct at the time:
        //
        //   * With the old OLS default `ml_m`, restricting to `Y == 0` made
        //     the score nearly unidentified. On `lplr_test`'s n=120 fixture
        //     `beta_start` reached -4.75, `max |r_hat|` reached 19.1 and
        //     `mean(psi_deriv)` collapsed to -3.2e-8; Newton failed to
        //     converge and `var_est` returned -2.4e6 for an O(0.5)
        //     quantity. On `examples/fuzz` trial 5 it gave `se = 1.3e7`.
        //   * In v0.163.0, implemented in FULL (both branches) on top of the
        //     D2+D3 baseline and measured again. It is the faithful port and
        //     it drives both SE ratios to ~1.0 (1.1549 -> 0.9949 and
        //     1.0269 -> 0.9914) -- the best SE agreement measured in this
        //     series. It still does not ship: both gated gaps got WORSE
        //     (`nuisance_space` 0.007307 -> 0.021078), and A/B over 200 of
        //     fuzz's own designs put the worst `|coef|` at 7.93e12 against
        //     1.03e11 on the shipped state, with `examples/fuzz` going from
        //     11/11 to FAIL at trial 141. The 0.113896 -> 0.005995 and
        //     0.024022 -> 0.000526 figures an earlier note quoted here were
        //     measured on the PRE-D2 baseline and describe nothing that
        //     exists now.
        //
        // Full record: `_verify/LPLR_GATE_BLINDNESS_1680.md` sections 8-10.
        //
        // The non-convergence cliff also moves with the conditioning, and NOT
        // by one constant: it is past 1.50 and warning from 1.75 at
        // (n=1000, seed=11), and still silent at 2.50 with warning from 3.00
        // at (n=800, seed=17). Transplanting one fixture's bound onto the
        // other would assert a property of neither.
        // HELD OFF, and this is the finding rather than a TODO.
        //
        // An earlier version of this comment read "It still cannot ship:
        // examples/fuzz FAILS", meaning the CONDITIONING. It was written as
        // though it described the repository, and that reading was wrong for
        // the shipped state, where `moon run examples/fuzz --target native`
        // reports ALL 11 SURFACES PASSED. Both recorded failures
        // were in configurations that do not ship --
        //
        //   trial  5, se = 13072741.313829884   old OLS `ml_m` default,
        //                                        fixed by the classifier
        //                                        default (v0.163.0)
        //   trial 25, se = 14771494.100785563   bounded default + THIS
        //                                        conditioning, which is off
        //
        // So "D1 is blocked on D3" described a variant that is switched off,
        // not a live red gate. Anyone reading the old wording would have gone
        // looking for a failure that is not there -- this one did.
        //
        // CAVEAT ON THE GREEN: `fuzz` is registered as a **full-scope** check,
        // and no workflow passes `--full` except the service step, which runs
        // `--only api_test,security_dast`. So `fuzz` is not executed by ANY
        // workflow. Its passing here is a local measurement, not something CI
        // is holding in place.
        //
        // ---- the per-observation `beta` divergence is now FIXED ----------
        //
        // The remainder of this block described `beta` being one
        // fold-averaged scalar against upstream's per-observation array. That
        // was v0.163.0 (D3) and it SHIPPED, together with D2 above. The only
        // part still true is the smaller one about fold-size weighting:
        // `np.average(beta)` averages the n-vector (fold-size weighted) while
        // the pre-D3 `beta_acc / beta_count` was the unweighted mean of
        // per-fold betas. They coincide on equal-size folds and differ on
        // unequal ones (cluster folds, or an external partition).
        //
        // The observable for this is the LPLR GATE GAP, not the fuzz blowup:
        // `pyexample_lplr.py` already prints the port/upstream coefficient gap
        // on both score names every run. Changing the score to the per-fold
        // array is a behaviour change to a published `pub fn` signature, so it
        // wants its own increment with its own before/after gap -- not a drive
        // by on the strength of a failure that does not exist.
        //
        // The alias is restored deliberately rather than left as an oversight.
        // Full measurements: `_verify/LPLR_GATE_BLINDNESS_1680.md`.
        m_pred = a_pred
        // 3) Per-fold W_inner, with row positions recorded by the outer
        // fold's training set. This is upstream's behaviour verbatim
        // (`M_iteration = M_hat["preds_inner"][i][train]`, i.e. the INNER
        // out-of-fold prediction, not the outer one).
        //
        // Before this the loop read `m_hat_outer`, the OUTER OOF, on the
        // stated grounds that "inner OOF for ml_M would require the same
        // double-cross-fit scaffolding as ml_a" -- but `a_inner_per_fold`
        // had been sitting right above doing exactly that since v0.62.0.
        // The scaffolding was already there and was simply not used for
        // this.
        let w_inner : Array[Array[Double]] = []
        for fi = 0; fi < outer.length(); fi = fi + 1 {
          let ti = outer[fi].train_idx
          let mi = m_inner_per_fold[fi]
          let w : Array[Double] = Array::make(ti.length(), 0.0)
          for k = 0; k < ti.length(); k = k + 1 {
            let mc = if mi[k] < 1.0e-8 {
              1.0e-8
            } else if mi[k] > 1.0 - 1.0e-8 {
              1.0 - 1.0e-8
            } else {
              mi[k]
            }
            w[k] = @math.ln(mc / (1.0 - mc))
          }
          w_inner.push(w)
        }
        t_pred = cross_fit_predict_inner_dispatch(ml_g, x, w_inner, outer)
        // 4) Per-fold preliminary beta.
        //
        // v0.163.0 (D3): upstream writes each fold's `b_f` onto that
        // fold's TEST rows (`beta[test] = b_f`, `plm/lplr.py:323`) and
        // the score reads the row's own entry. A single averaged scalar
        // is what this used to produce, which is upstream's Newton START
        // only. `beta_acc` / `beta_count` are still accumulated because
        // that average is genuinely needed -- for `theta0`.
        let mut beta_acc = 0.0
        let mut beta_count = 0
        let beta_vec : Array[Double] = Array::make(n, 0.0)
        for fi = 0; fi < outer.length(); fi = fi + 1 {
          let ti = outer[fi].train_idx
          // v0.163.0 (D2): the `m_inner` slot used to be handed the `a`
          // copy, so `beta` was regressed on `logit(a_hat)` twice and
          // ml_M's inner OOF reached this function exactly never. That is
          // upstream's `beta[test]` regressed on `W_inner`'s own `m`
          // (`plm/lplr.py:323`), which is `m_inner_per_fold[fi]`.
          let b_f = prelim_beta_per_fold(
            m_inner_per_fold[fi],
            a_inner_per_fold[fi],
            d,
            ti,
          )
          beta_acc = beta_acc + b_f
          beta_count = beta_count + 1
          // v0.163.0 (D3): upstream keeps `beta` PER OBSERVATION
          // (`plm/lplr.py:315-323` writes `beta[test] = b_f`) and reads
          // `beta[i]` for row `i` at `:345` (`r_hat = t_hat - beta * a_hat`).
          // Only the Newton START averages it (`np.average(beta)`, `:326`).
          // So each row takes the `b_f` of the fold it was predicted in.
          let te_rows = outer[fi].test_indices()
          for j = 0; j < te_rows.length(); j = j + 1 {
            beta_vec[te_rows[j]] = b_f
          }
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
        beta_vec
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
      let beta_scalar = mean(beta_start)
      let (theta0, _) = lplr_initial_theta(beta_scalar, d, y, t_pred, a_pred)
      let mut theta = theta0
      let mut converged = false
      // v0.145.0: WHY the solver stopped, not merely whether. There are three
      // distinct non-convergence exits below and they mean different things to
      // a caller staring at a collapsed standard error: a vanishing Jacobian,
      // a diverging iterate, and an exhausted step budget. Before this, all
      // three reached the caller as one silently discarded `let _ = converged`
      // and a coefficient computed at a non-solution.
      let mut stop_reason = "exhausted_step_budget"
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
          stop_reason = "degenerate_derivative"
          break
        }
        // Newton with a damped step. THIS IS A DEVIATION FROM UPSTREAM, and
        // the deviation is deliberate for now -- see below.
        //
        // Upstream solves with `root_scalar(score, x0=..., fprime=...,
        // method="newton")` (`doubleml/double_ml_score_mixins.py:149`), and
        // scipy's Newton (`scipy.optimize._zeros_py.newton`) is a bare step
        // with a convergence test and nothing between them:
        //
        //     newton_step = fval / fder
        //     p = p0 - newton_step
        //     if np.isclose(p, p0, rtol=rtol, atol=tol): converged
        //
        // There is no step cap, no `rmax` and no damping in that
        // implementation -- read out of the installed scipy 1.18, not assumed.
        // So this clamp does not exist upstream, and it costs agreement:
        // capped at 0.25 a step over 50 iterations, theta can travel at most
        // 12.5 from its start, while on the small-n designs the start is
        // O(10) and the root is at the truth (0.5), so the solver runs out of
        // budget mid-descent and returns a point that was never a solution.
        // Measured on identical rows and the identical partition (truth 0.5),
        // at `8c01e96`, by temporarily raising the two damping thresholds to
        // 1.0e300 so the branch cannot fire, running `pyexample_lplr.py`, then
        // reverting. Reproducible; the revert is exact.
        //
        //              clamped            unclamped         upstream
        //     n=60    -0.0491291  ok      -0.0491291  ok      3.53962
        //     n=100   14.431      WARNED  -0.643589   ok     -0.558127
        //     n=160    0.580578   ok       0.580578   ok      0.749398
        //
        // Gap to upstream is 3.589 / 14.989 / 0.169 clamped, against
        // 3.589 / 0.085 / 0.169 unclamped.
        //
        // **THE CLAMP COSTS NOTHING AT n=60 AND n=160** -- bit-identical to the
        // unclamped arm on both. It bites at n=100 and nowhere else on these
        // three designs, because that is the one where the solver exhausts its
        // 50-step budget mid-descent. At n=100 it is the difference between
        // agreeing with upstream to 0.085 and being 14.989 away.
        //
        // v0.163.4: this table previously read `n=60 14.966 WARNED` and
        // `n=100 13.285 WARNED` for the clamped arm, and the README repeated
        // the gap as "11.4 -> 3.59 at n=60". Both were measured BEFORE D4
        // (v0.163.0), when the reported coefficient was a re-derivation rather
        // than `theta` itself, so neither describes this code. The post-D4
        // clamped iterate at n=60 is -0.0491291 with NO warning: the damping
        // never fired there and the solve converged either way. **D4 fixed the
        // REPORTING of that row, not the clamp** -- which is why the n=60 gap
        // is now 3.589 on both arms instead of "11.4 clamped, 3.59 unclamped".
        //
        // Upstream is itself far from the truth at n=60 -- 3.54 against 0.5,
        // with se 20.199. These designs are ill-conditioned for both
        // implementations; what the clamp buys at n=100 is a finite WARNED
        // answer, not a correct one.
        //
        // WHY IT IS STILL HERE, which is the part that is easy to get wrong:
        // removing it was measured and it is worse, not better.
        //
        //   * `examples/fuzz` goes RED without it: `lplr non-negative finite se
        //     (trial=2, se=NaN, th=-440.15956528046615)`, reproduced to the
        //     digit. **v0.163.4: this bullet used to read "On this repo's own
        //     binary DGP at n = 500, upstream stayed finite on 300/300 draws
        //     while the unclamped port reaches se = NaN ... by trial 2."** That
        //     spliced two different experiments together. "trial 2" is a
        //     `moon run examples/fuzz` trial, and that harness draws
        //     `n = rng.int(limit=100) + 60` (`examples/fuzz/main.mbt:412`), so
        //     it only ever runs at n in [60, 160] -- never n=500. The n=500
        //     upstream figure is a separate probe, not this one.
        //   * That distinction mattered, and it has since been settled. The
        //     fuzz DGP is a pure function of `trial` -- `n`, `seed`, `x`, `y`,
        //     `d` come from `chacha8_rng(seed)` and nothing there reads this
        //     clamp -- so the SAME rows are produced clamped or not. Dumping
        //     trial 2 and 7 and running real `DoubleMLLPLR` on them: upstream
        //     is FINITE on both under `nuisance_space` (`n=66`:
        //     `coef=-1.479, se=0.580`; `n=97`: `coef=0.279, se=0.407`) while
        //     this port unclamped gives `se = NaN` at `th = -440` and
        //     `se = 8.9e+59` at `th = 140`. **So this is not a regime where the
        //     estimator is ill-posed for everyone: the port's Newton is
        //     unstable on identical rows where upstream's converges.** The
        //     clamp substitutes for a stability upstream has and the port
        //     lacks. It stays. Upstream does fail on the `instrument` score at
        //     n=97 (`se = inf`, "could not find a root"), but that is not the
        //     score this path exercises.
        //     `_verify/LPLR_GATE_BLINDNESS_1680.md` sections 25e-25g.
        //   * At **small n, upstream reaches it too** -- measured with real
        //     `DoubleMLLPLR` fits, 25 draws per n: non-finite SE on 7/25 at
        //     n=60 (`coef = nan` twice, `coef = 5.4e22, se = inf` once),
        //     1/25 at n=100, 1/25 at n=160, 0/25 at n=500; and upstream's own
        //     `Could not find a root of the score function` warning fires on
        //     11/25 draws at n=60. So the "0/300" that once justified this
        //     clamp was measured where nothing fails, and generalised past
        //     the sample size it was measured at.
        //   * The overflow is in the variance, not the iterate: `d` is binary
        //     in that DGP so `exp(-theta*d)` is only `exp(440)` at that point
        //     -- finite -- and it is the squaring in
        //     `sigma2 = mean(psi^2) / (n * J^2)` that produces `Inf/Inf`.
        //   * Upstream has no guard there either. At n=500 it simply never
        //     arrives; below that it arrives and is itself non-finite. What
        //     this clamp buys is a finite, WARNED answer in place of `nan`,
        //     not the absence of the failure.
        //
        // It is NOT the `d_tilde` input. An earlier version of this comment
        // said it was, on the reasoning that the alias `m_pred = a_pred`
        // substitutes the propensity where upstream uses `m_hat`. That is
        // wrong: `plm/lplr.py:254` builds `m_hat` from `self._learner["ml_m"]`
        // on `x, d` as a plain outer cross-fit, which is exactly the array
        // `a_pred` holds here (`:836`). The alias is faithful. Pointing
        // `m_pred` at `ml_M`'s nuisance instead was tested and fails fuzz at
        // trial 0 -- worse than leaving the alias in place.
        //
        // The gap that WAS still open is the other nuisance, `a_hat`, in
        // `r_hat = t_hat["preds"] - beta * a_hat["preds"]` (`:345`):
        // upstream's is double-cross-fitted and a full `n`-vector, the port's
        // is a plain outer cross-fit, so rows inside an outer fold's training
        // set get an outer-model prediction where upstream uses an inner one.
        //
        // **Two DIFFERENT differences live in that one sentence, and only one
        // of them was ever tested.** The one tested here is `preds_inner`
        // (`:318`, `:322`) -- upstream reads `a_hat["preds_inner"][i][train]`
        // to build `beta`. Substituting `a_inner_per_fold` for `a_pred` was
        // implemented and measured, and it is NOT the cause: the fuzz
        // surfaces stay green but the gated gaps get 4.6x and 5.1x WORSE
        // (0.007307 -> 0.033977 and 0.010609 -> 0.054513), and n=160 moves
        // from a 0.169 gap to 3.14. Combined with the unclamped Newton it
        // still aborts at `var_est.mbt:79`.
        //
        // The other is `a_hat["preds"]` itself, the vector that feeds
        // `r_hat`. Upstream builds it by summing EVERY inner model's
        // prediction on the outer test rows and dividing by `len(smpls)`
        // (`utils/_estimation.py:207-229`) -- a bagged predictor. `:836`
        // is a single outer OOF. That difference is REAL but it is SMALL,
        // and it is NOT a cause. Measured with both nuisances on the
        // PROBABILITY scale (see 21a): it moves `a_hat` by 1.7% of its own
        // span on the gate fixture, 21.5% at n=60 falling to 2.6% at n=500;
        // substituting it into upstream shifts the coefficient by +3.9e-4
        // against a band floor of 1.3e-1; and Newton survival TIES at every
        // n (18/18, 20/20, 25/25, 25/25 of 25 at n = 60/100/160/500) with
        // `mean(psi)` and first-step ratios of 0.99-1.02.
        //
        // v0.163.4: this paragraph previously claimed "69% of `a_hat`'s own
        // span", "`mean(psi)` ~13x larger", "first Newton step ~1400x larger"
        // and "survives strictly less often (15 vs 16, 19 vs 21, 19 vs 20)".
        // ALL FOUR ARE WITHDRAWN. They came from a Python reconstruction of
        // this file's own construction that used sklearn `.predict` -- hard
        // 0/1 labels -- where upstream uses `predict_proba` (`lplr.py:166`,
        // `:150`). This port is on the probability side too: `predict` returns
        // `sigmoid(eta)` clipped into `(1e-15, 1-1e-15)` (`logistic.mbt:217`)
        // and the labels are a separate `predict_class` (`logistic.mbt:250`).
        // The old control measured labels-against-probabilities, which
        // guarantees a large answer for a reason that has nothing to do with
        // bagging. **Do not implement the bagging**: it cannot move the gated
        // gap (0.007307) and it does not improve small-n survival. Full record
        // and numbers in `_verify/LPLR_GATE_BLINDNESS_1680.md` section 21.
        //
        // So four explanations are now measured and none holds: the start
        // value and the point estimate (both fixed at df049c2), `d_tilde`
        // (falsified), `preds_inner` (falsified above), and the `a_hat`
        // bagging (withdrawn above). The stopping
        // tolerance is also measured and irrelevant: scipy 1.18's `newton`
        // stops at `|step| <= 1.48e-8` and this loop at `< 1e-9`, a 14.8x
        // difference -- but 0 of 600 fuzz solves, and 0 of 5 on the arm that
        // actually diverges, ever produce a step in the window where the two
        // disagree. The behaviour is bimodal: a solve lands inside 1e-9 or
        // never approaches even 1.48e-8.
        //
        // So the honest statement is not "a port deviation whose cause is
        // unknown". It is: **at n <~ 200 this estimator is ill-posed for both
        // implementations.** Upstream is 0/300 finite at n=500 and 7/25
        // non-finite at n=60, where it also raises its own root warning on
        // 11/25 draws. The port returns a finite WARNED answer where upstream
        // returns `nan` or `1e22`. This clamp is what makes that trade; it is
        // not hiding a bug it caused.
        //
        // One real divergence remains and it is NOT implemented: upstream's
        // `a_hat["preds"]` is a bagged average of every inner model's
        // prediction, this `:836` is a single outer OOF (69% of `a_hat`'s own
        // span apart). Matching it is directionally right and partial. It is
        // left alone until someone can show it does not cost the gated
        // n=500 parity, which is the one design point where upstream has a
        // defined answer to agree with.
        //
        // `_verify/LPLR_GATE_BLINDNESS_1680.md` sections 13-20 carry the
        // record, including three retractions of claims this comment used to
        // make.
        //
        // The `|theta_new| > 1e6` guard below is the real runaway check, and it
        // is what turns an overflow into a `diverged` warning instead of a
        // silent infinite.
        let raw_delta = s / sd
        let mut theta_new = theta - raw_delta
        if theta_new.abs() > 5.0 || (theta_new - theta).abs() > 1.0 {
          let step = if raw_delta.abs() < 0.25 { raw_delta } else { 0.25 }
          theta_new = theta - step * (if s > 0.0 { 1.0 } else { -1.0 })
        }
        if (theta_new - theta).abs() < 1.0e-9 {
          theta = theta_new
          converged = true
          stop_reason = "converged"
          break
        }
        if theta_new.abs() > 1.0e6 {
          stop_reason = "diverged"
          break
        }
        theta = theta_new
      }
      // v0.145.0: the discarded flag becomes a returned warning. This line used
      // to read `let _ = converged`, which is why a coefficient and standard
      // error computed at a point that is not a solution shipped silently:
      // measured at alpha >= 1.25 the SE collapses to ~4.6e-5 because it is a
      // Jacobian evaluated away from the root.
      //
      // Upstream WARNS here too (`double_ml_score_mixins.py:143-162`, via
      // `error_on_convergence_failure=False` by default). The difference is
      // only the channel: upstream writes to a warnings list, and so does this
      // -- see the convention documented on `DoubleMLLPLR::warnings`.
      if !converged {
        warnings.push(
          "rep " +
          r.to_string() +
          ": LPLR Newton solver did not converge (" +
          stop_reason +
          "); coef and se were computed at theta = " +
          theta.to_string() +
          ", which is not a solution of the estimating equation",
        )
      }
      // 7) Variance at the converged theta. For the linear
      // var_est path, we use psi_deriv(theta) as the linear slope
      // and psi(theta) - theta * psi_deriv(theta) as the constant
      // offset; the resulting \	heta_hat = -mean(psi_b)/mean(psi_a)    // recovers the same \	heta\, and the SE reflects the score
      // residual at convergence.
      let sc = lplr_score_at(
        theta, d, y, t_pred, a_pred, m_pred, beta_start, kind,
      )
      let psi_a : Array[Double] = sc.psi_deriv
      // v0.163.0 (D4): the point estimate is `theta`, the Newton iterate.
      //
      // It used to be re-derived here as `var_est(...).0`, which is
      // `-mean(psi_b)/mean(psi_a)`. Upstream does NOT do that -- it takes
      // `theta_hat = root_res.root` (`double_ml_score_mixins.py`,
      // `_root_find`), and computes only the VARIANCE from the score.
      //
      // The two agree at a root, since psi(theta) = 0 makes
      // `psi_b = -theta*psi_a` and the ratio collapse to theta. Off a root
      // they do not, and the ratio carries a factor `1/mean(psi_a)`. That
      // is harmless while the solver converges and catastrophic when it does
      // not, because a near-degenerate Jacobian is exactly what a
      // non-converging design produces. Measured on the small-n designs where
      // upstream converges and this port did not:
      //
      //     n=60    theta = O(10)   re-derived coef = -3.32e6   upstream 3.54
      //     n=100   theta = O(10)   re-derived coef = -1.12e6   upstream -0.558
      //
      // The Newton clamps each step to 0.25 over 50 iterations, so `theta`
      // cannot exceed its start by more than 12.5 -- the 1e6 was never in
      // the root at all, it was the re-derivation amplifying a root that had
      // merely stopped short.
      //
      // `var_est_with_jacobian` is the upstream variance: `gamma` evaluated
      // at the KNOWN root (`sc.psi`) rather than at the re-derived one, and
      // divided by `J = mean(psi_deriv)` squared.
      let se_r = var_est_with_jacobian(sc.psi, mean(psi_a))
      coefs[r] = theta
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
    // the freshly-computed fold_ids + nuisances + beta
    // to the cache. `beta` is already length-`n`, so it fits the
    // `Array[Array[Double]]` shape of `FitCache` unchanged.
    let next_cache = if memoize && !cache_hit && nrep == 1 {
      FitCache::from_fit(
        fold_ids,
        [t_pred, m_pred, a_pred, last_beta_start],
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
      fit_warnings: warnings,
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
  method_name~ : String = "normal",
  n_rep_boot~ : Int32 = 500,
  seed~ : Int32 = 2024,
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
  scoring_method~ : String = "MSE",
  n_folds_tune~ : Int32 = 5,
  seed~ : Int32 = 3141,
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
/// The Newton starting value `x0`.
///
/// It is `mean(beta)`, which is upstream verbatim: `plm/lplr.py:326` sets
/// `self._coef_start_val = np.average(beta)` and `:149` passes that as `x0`
/// to `root_scalar`. The port's `mean(beta_start)` is the same quantity on
/// the same per-fold `beta` vector.
///
/// This used to carry a comment claiming an OLS scale -- "Simple OLS scale:
/// theta ~ mean(d * t) / mean(d^2)", evaluated at `theta = 0`, "taking
/// whichever magnitude is smaller" -- and it computed exactly that
/// (`num = sum(d * t_pred)`, `den = sum(d^2)`) before returning `beta_start`
/// anyway. So `num` and `den` were dead: the OLS scale the comment described
/// was never used for anything, and a reader comparing this against upstream
/// would have concluded the start value was a *different* quantity when it is
/// the same one. `num` is gone and `t_pred` is renamed to `_t_pred`.
///
/// `den` is kept: its zero case is a live guard, and it is the only thing
/// that function still computes.
///
/// v0.163.4: comment corrected. No behavioural change -- `mean(beta_start)`
/// was already what this returned before the edit.
fn lplr_initial_theta(
  beta_start : Double,
  d : Array[Double],
  _y : Array[Double],
  _t_pred : Array[Double],
  _a_pred : Array[Double],
) -> (Double, Bool) {
  // Only the all-d==0 guard is live here. Upstream has no equivalent: it goes
  // straight to `np.average(beta)`, which is 0.0 (or nan) when every fold's
  // `sum(d_tilde**2)` was 0. Returning (0.0, false) is closer to that than
  // handing `beta_start` back, so the guard stays.
  let mut den = 0.0
  for i = 0; i < d.length(); i = i + 1 {
    den = den + d[i] * d[i]
  }
  if den.abs() < 1.0e-300 {
    return (0.0, false)
  }
  (beta_start, true)
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
    Ridge(r) => cross_fit_predict_inner(r, x, targets, folds)
    Lasso(l) => cross_fit_predict_inner(l, x, targets, folds)
    ElasticNet(e) => cross_fit_predict_inner(e, x, targets, folds)
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
///
/// ---------------------------------------------------------------------------
/// v0.144.0: DOCUMENTED DEVIATION -- UPSTREAM RAISES NOT IMPLEMENTED.
///
/// This is the strongest of the three. Verified against upstream
/// `doubleml-0.11.4`: `plm/lplr.py` sets
/// `self._sensitivity_implemented = False` and its
/// `_sensitivity_element_est` body is literally
/// `raise NotImplementedError()`. Upstream does not merely decline to compute
/// an LPLR sensitivity analysis -- reaching for the elements raises. This port
/// returns a result anyway, kept for API compatibility, and it must be read as
/// PORT-DEFINED.
///
/// Note this is a DIFFERENT issue from the solver's discarded convergence flag
/// (`let _ = converged`, further down in `fit`, tracked separately in
/// v0.145.0). One concerns the sensitivity API surface; the other concerns a
/// coefficient computed at a non-solution. Both are real, and fixing either
/// does not address the other.
///
/// `mean(psi_a^2)` below uses `psi_a = -d * (d - a_hat)`, the simplified LPLR
/// IF denominator, which is NOT upstream's Riesz representer. The `nu2` here
/// is not comparable to `DoubleMLPLR`'s upstream-aligned `1 / mean(v^2)`.
pub fn DoubleMLLPLR::sensitivity_analysis(
  self : DoubleMLLPLR,
  cf_y~ : Double = 0.05,
  cf_d~ : Double = 0.05,
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
  cluster_ids : Array[Int32],
  cf_y~ : Double = 0.05,
  cf_d~ : Double = 0.05,
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
  cluster_ids : Array[Int32],
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
