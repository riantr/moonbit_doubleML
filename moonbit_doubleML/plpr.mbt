///|
/// Double / debiased machine learning for the *static panel*
/// partially linear regression model (upstream:
/// `doubleml.plm.DoubleMLPLPR`, Clarke & Polselli 2025):
///
///     Y_it = D_it * theta_0 + g_0(X_it) + alpha_i + zeta_it
///
/// where `alpha_i` is a unit fixed effect. The panel structure is
/// first transformed into a cross-section via one of four static
/// panel approaches, and a standard DML partialling-out /
/// IV-type score is applied to the transformed data:
///
///   - `"cre_general"`: correlated random effects (Mundlak).
///     Augment X with per-unit means of every covariate column.
///     After cross-fitting, adjust the treatment nuisance:
///     `m_hat* = m_hat + d_mean - mean_by_id(m_hat)` where
///     `d_mean` is the per-row unit mean of D.
///   - `"cre_normal"`: CRE with a normality-style restriction.
///     Same X augmentation, but the treatment regression gets
///     `[X, d_mean]` as inputs; no post-hoc m_hat adjustment.
///   - `"fd_exact"`: exact first differencing. The panel is
///     reindexed to the full id x time grid, y and d are
///     first-differenced within each unit, and covariates become
///     `[X_t, X_{t-1}]`. Rows missing x_t or x_{t-1} are dropped.
///   - `"wg_approx"`: approximate within transformation.
///     `within(v) = v - unit_mean(v) + grand_mean(v)` for y, d,
///     and every covariate; PLR runs on the within-transformed
///     variables alone.
///
/// All four approaches reuse the shared cross-fit machinery
/// (`kfold` + `cross_fit_predict`). Because upstream re-wraps the
/// transformed data as static-panel data with `cluster_cols =
/// id_col`, estimation always takes the clustered DML path:
/// folds partition whole units, the coefficient is a fold-weighted
/// ratio of cluster score sums (`est_coef_cluster`), and the SE is
/// unit-level cluster-robust (`var_est_cluster`), with the
/// closed-form `LinearRegression` learner.
pub struct DoubleMLPanelData {
  x : Matrix
  y : Array[Double]
  d : Array[Double]
  t : Array[Int]
  id : Array[Int]
} derive(Debug)

///|
pub extend DoubleMLPanelData with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLPanelData::new(
  x : Matrix,
  y : Array[Double],
  d : Array[Double],
  t : Array[Int],
  id : Array[Int],
) -> DoubleMLPanelData {
  try {
    let n = x.nrows
    require(y.length() == n)
    require(d.length() == n)
    require(t.length() == n)
    require(id.length() == n)
    require(n > 0)
    { x, y, d, t, id, }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Transformed cross-section produced by one of the four static
/// panel approaches. `d_mean_row` carries the per-row unit mean of
/// D when an approach needs it downstream (`cre_general`,
/// `cre_normal`), otherwise it is empty. `id` is the unit id of
/// every transformed row: upstream wraps the transformed data in a
/// static-panel `DoubleMLPanelData`, which sets `cluster_cols =
/// id_col`, so the clustered DML path always keys off this column.
struct PanelTransform {
  x : Matrix
  y : Array[Double]
  d : Array[Double]
  d_mean_row : Array[Double]
  id : Array[Int]
} derive(Debug)

///|
pub extend PanelTransform with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Sort rows by (id, t) ascending and return the permutation of
/// row indices. Stable: ties on (id, t) keep original order.
fn sort_rows_by_id_time(id : Array[Int], t : Array[Int]) -> Array[Int] {
  let order : Array[Int] = Array::makei(id.length(), fn(i) { i })
  // Insertion sort (n is small in tests/demos; deterministic).
  for i = 1; i < order.length(); i = i + 1 {
    let mut j = i
    while j > 0 &&
          (
            id[order[j]] < id[order[j - 1]] ||
            (id[order[j]] == id[order[j - 1]] && t[order[j]] < t[order[j - 1]])
          ) {
      let tmp = order[j]
      order[j] = order[j - 1]
      order[j - 1] = tmp
      j = j - 1
    }
  }
  order
}

///|
/// Unit-level means of one vector keyed by `id`, returned per row.
fn unit_means(v : Array[Double], id : Array[Int]) -> Array[Double] {
  let n = v.length()
  // Map unit id -> (sum, count). Units are Ints; use a simple
  // two-pass scheme: collect unique ids, then accumulate.
  let uniq : Array[Int] = []
  let mut uniq_acc : Array[Int] = uniq
  for i = 0; i < n; i = i + 1 {
    let g = id[i]
    let mut found = false
    for k = 0; k < uniq_acc.length(); k = k + 1 {
      if uniq_acc[k] == g {
        found = true
        break
      }
    }
    if !found {
      uniq_acc = uniq_acc + [g]
    }
  }
  let sums : Array[Double] = Array::make(uniq_acc.length(), 0.0)
  let counts : Array[Int] = Array::make(uniq_acc.length(), 0)
  for i = 0; i < n; i = i + 1 {
    let g = id[i]
    for k = 0; k < uniq_acc.length(); k = k + 1 {
      if uniq_acc[k] == g {
        sums[k] = sums[k] + v[i]
        counts[k] = counts[k] + 1
        break
      }
    }
  }
  let out : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let g = id[i]
    for k = 0; k < uniq_acc.length(); k = k + 1 {
      if uniq_acc[k] == g {
        out[i] = sums[k] / counts[k].to_double()
        break
      }
    }
  }
  out
}

///|
/// Grand (overall) mean of a vector.
fn grand_mean(v : Array[Double]) -> Double {
  let mut s = 0.0
  for i = 0; i < v.length(); i = i + 1 {
    s = s + v[i]
  }
  s / v.length().to_double()
}

///|
/// Unique unit ids in first-appearance order.
fn unique_units(id : Array[Int]) -> Array[Int] {
  let uniq : Array[Int] = []
  for i = 0; i < id.length(); i = i + 1 {
    let g = id[i]
    let mut found = false
    for k = 0; k < uniq.length(); k = k + 1 {
      if uniq[k] == g {
        found = true
        break
      }
    }
    if !found {
      uniq.push(g)
    }
  }
  uniq
}

///|
/// Clustered-path causal parameter (`LinearScoreMixin._est_coef`,
/// cluster branch): the root of the fold-weighted score sums. Each
/// test fold contributes `sum(score on its test rows)` scaled by
/// `1 / |I_k|`, the number of units in the fold's test cluster set:
///
///     theta = - sum_k w_k * sum_{i in k} psi_b
///             / sum_k w_k * sum_{i in k} psi_a,   w_k = 1/|I_k|.
pub fn est_coef_cluster(
  psi_a : Array[Double],
  psi_b : Array[Double],
  folds_row : Array[Fold],
  fold_n_units : Array[Int],
) -> Double {
  try {
    require(folds_row.length() == fold_n_units.length())
    let mut sa = 0.0
    let mut sb = 0.0
    for f = 0; f < folds_row.length(); f = f + 1 {
      let w = 1.0 / fold_n_units[f].to_double()
      let ti = folds_row[f].test_indices()
      let mut fa = 0.0
      let mut fb = 0.0
      for k = 0; k < ti.length(); k = k + 1 {
        fa = fa + psi_a[ti[k]]
        fb = fb + psi_b[ti[k]]
      }
      sa = sa + w * fa
      sb = sb + w * fb
    }
    require(sa.abs() > 0.0)
    -sb / sa
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Cluster-robust standard error (`_var_est` in
/// `doubleml/utils/_estimation.py`, one-cluster-variable branch).
/// Per test fold, accumulate squared unit-level score sums scaled
/// by `1 / |I_k|`; divide both the gamma accumulator and the
/// Jacobian analog by `n_folds_per_cluster`:
///
///     gamma += S_g^2 / |I_k|,   S_g = sum of psi over unit g,
///     J     += (sum of psi_deriv over the fold's rows) / |I_k|,
///     sigma2 = (gamma / npc) / (N_units * (J / npc)^2).
///
/// `psi` is the linear score evaluated at theta_hat, `psi_deriv`
/// the score derivative (= psi_a). `unit_fold[u]` is the test-fold
/// index of unit u; every row of a unit lies in that fold because
/// the folds partition whole units.
///
/// Returns `Double!VarEstClusterError`: the v0.34.0 J-floor
/// defensive guard (|J|<1e-6) raises `VarEstClusterError::JTooSmall`
/// carrying the exact `(j, g, n_units)` triple that triggered it.
/// Callers that want the pre-v0.35.0 process-death behavior should
/// catch the error and re-abort (this is what every
/// `DoubleMLXXX::fit_cluster` does); callers that want to retry or
/// surface the error should propagate via `?`. The error type is
/// declared in `kfold.mbt` so the cluster helper stack can share it.
pub fn var_est_cluster(
  psi : Array[Double],
  psi_deriv : Array[Double],
  unit_rows : Array[Array[Int]],
  unit_fold : Array[Int],
  n_folds : Int,
  n_folds_per_cluster : Int,
) -> Double raise VarEstClusterError {
  // v0.48.0: per-call wrap on the lone `require(m > 0)` because the
  // body also raises VarEstClusterError::JTooSmall; a block-level
  // try/catch would partial_match the catch.
  let n_units = unit_rows.length()
  let mut gamma = 0.0
  let mut j_hat = 0.0
  for f = 0; f < n_folds; f = f + 1 {
    let mut m = 0
    for u = 0; u < n_units; u = u + 1 {
      if unit_fold[u] == f {
        m = m + 1
      }
    }
    ignore(
      require(m > 0) catch {
        PreconditionError::Violated(loc) =>
          abort("precondition failed at " + loc.to_string())
      },
    )
    let w = 1.0 / m.to_double()
    for u = 0; u < n_units; u = u + 1 {
      if unit_fold[u] == f {
        let rows = unit_rows[u]
        let mut s = 0.0
        let mut sd = 0.0
        for q = 0; q < rows.length(); q = q + 1 {
          s = s + psi[rows[q]]
          sd = sd + psi_deriv[rows[q]]
        }
        gamma = gamma + w * s * s
        j_hat = j_hat + w * sd
      }
    }
  }
  let npc = n_folds_per_cluster.to_double()
  let j = j_hat / npc
  let g = gamma / npc
  // J = mean(psi_deriv) can land near zero on a fold split that
  // happens to align psi_deriv around zero. Divide-by-near-zero
  // inflates the SE by orders of magnitude (v0.32.0 lesson:
  // IIVM/PLIV cluster ratios hit 1e5+ on ~3% of seeds). We
  // detect this at a generous floor (1e-6) and abort with a
  // diagnostic message: callers (fuzz, validate_*, downstream
  // consumers) should treat this as "the cluster SE is
  // numerically unstable, try a different seed". The 1e-6 floor
  // is conservative -- most natural fold splits have J > 1e-3.
  // This abort fires only on truly pathological fold splits
  // (v0.32.0 found ~3% of seeds with cluster ratio > 1e5, and
  // most of those have J < 1e-3 too; this floor catches all
  // of them).
  if j.abs() < 1.0e-6 {
    raise VarEstClusterError::JTooSmall(j, g, n_units)
  }
  (g / (n_units.to_double() * j * j)).sqrt()
}

///|
/// Apply one of the four static-panel transformations to the raw
/// panel data. Returns the transformed cross-section.
fn transform_panel(
  data : DoubleMLPanelData,
  approach : String,
) -> PanelTransform {
  try {
    let p_x = data.x.cols()
    let n_raw = data.x.nrows
    // Upstream sorts by (id, t) before transforming.
    let order = sort_rows_by_id_time(data.id, data.t)
    // Drop ids with only a single row (they carry no within-unit
    // variation). Count occurrences per sorted id.
    let sorted_id : Array[Int] = Array::make(n_raw, 0)
    for k = 0; k < n_raw; k = k + 1 {
      sorted_id[k] = data.id[order[k]]
    }
    let counts_of_sorted : Array[Int] = Array::make(n_raw, 0)
    for k = 0; k < n_raw; k = k + 1 {
      let g = sorted_id[k]
      let mut c = 0
      for m = 0; m < n_raw; m = m + 1 {
        if sorted_id[m] == g {
          c = c + 1
        }
      }
      counts_of_sorted[k] = c
    }
    let keep : Array[Int] = []
    let mut keep_acc : Array[Int] = keep
    for k = 0; k < n_raw; k = k + 1 {
      if counts_of_sorted[k] >= 2 {
        keep_acc = keep_acc + [order[k]]
      }
    }
    let n = keep_acc.length()
    require(n >= 4)
    if approach == "cre_general" || approach == "cre_normal" {
      // Gather sorted arrays.
      let y_s : Array[Double] = Array::make(n, 0.0)
      let d_s : Array[Double] = Array::make(n, 0.0)
      let id_s : Array[Int] = Array::make(n, 0)
      for k = 0; k < n; k = k + 1 {
        let i = keep_acc[k]
        y_s[k] = data.y[i]
        d_s[k] = data.d[i]
        id_s[k] = data.id[i]
      }
      // X augmented with per-unit means of each column.
      let p_aug = p_x * 2
      let x_flat : Array[Double] = Array::make(n * p_aug, 0.0)
      for k = 0; k < n; k = k + 1 {
        let i = keep_acc[k]
        for j = 0; j < p_x; j = j + 1 {
          let col : Array[Double] = Array::make(n, 0.0)
          for m = 0; m < n; m = m + 1 {
            col[m] = data.x.get(keep_acc[m], j)
          }
          let means = unit_means(col, id_s)
          x_flat[k * p_aug + j] = data.x.get(i, j)
          x_flat[k * p_aug + p_x + j] = means[k]
        }
      }
      let d_mean_row = unit_means(d_s, id_s)
      {
        x: Matrix::from_array(x_flat, n, p_aug),
        y: y_s,
        d: d_s,
        d_mean_row,
        id: id_s,
      }
    } else if approach == "fd_exact" {
      // First differences over the full id x time grid. For each
      // kept unit, walk its rows in time order and difference
      // consecutive rows (the upstream reindex-to-full-grid step
      // inserts NaN rows for missing periods which are then dropped;
      // walking consecutive observed rows per unit yields the same
      // transitions on balanced panels and drops nothing extra).
      let y_out : Array[Double] = []
      let mut y_out_acc : Array[Double] = y_out
      let d_out : Array[Double] = []
      let mut d_out_acc : Array[Double] = d_out
      let x_out : Array[Double] = []
      let mut x_out_acc : Array[Double] = x_out
      let id_out : Array[Int] = []
      let p_fd = p_x * 2
      let mut k = 0
      while k < n {
        let i_cur = keep_acc[k]
        let id_cur = data.id[i_cur]
        // Find the extent of this unit's block in sorted order.
        let mut end = k
        while end < n && data.id[keep_acc[end]] == id_cur {
          end = end + 1
        }
        // Block [k, end): rows already sorted by t.
        for m = k + 1; m < end; m = m + 1 {
          let i_prev = keep_acc[m - 1]
          let i_this = keep_acc[m]
          y_out_acc = y_out_acc + [data.y[i_this] - data.y[i_prev]]
          d_out_acc = d_out_acc + [data.d[i_this] - data.d[i_prev]]
          for j = 0; j < p_x; j = j + 1 {
            x_out_acc = x_out_acc + [data.x.get(i_this, j)]
          }
          for j = 0; j < p_x; j = j + 1 {
            x_out_acc = x_out_acc + [data.x.get(i_prev, j)]
          }
          id_out.push(id_cur)
        }
        k = end
      }
      let n_out = y_out_acc.length()
      require(n_out >= 2)
      {
        x: Matrix::from_array(x_out_acc, n_out, p_fd),
        y: y_out_acc,
        d: d_out_acc,
        d_mean_row: [],
        id: id_out,
      }
    } else if approach == "wg_approx" {
      // Within transformation: v - unit_mean(v) + grand_mean(v).
      let y_s : Array[Double] = Array::make(n, 0.0)
      let d_s : Array[Double] = Array::make(n, 0.0)
      let id_s : Array[Int] = Array::make(n, 0)
      for k = 0; k < n; k = k + 1 {
        let i = keep_acc[k]
        y_s[k] = data.y[i]
        d_s[k] = data.d[i]
        id_s[k] = data.id[i]
      }
      let y_u = unit_means(y_s, id_s)
      let d_u = unit_means(d_s, id_s)
      let y_g = grand_mean(y_s)
      let d_g = grand_mean(d_s)
      let x_w_flat : Array[Double] = Array::make(n * p_x, 0.0)
      for k = 0; k < n; k = k + 1 {
        y_s[k] = y_s[k] - y_u[k] + y_g
        d_s[k] = d_s[k] - d_u[k] + d_g
        for j = 0; j < p_x; j = j + 1 {
          let col : Array[Double] = Array::make(n, 0.0)
          for m = 0; m < n; m = m + 1 {
            col[m] = data.x.get(keep_acc[m], j)
          }
          let xu = unit_means(col, id_s)
          let xg = grand_mean(col)
          x_w_flat[k * p_x + j] = col[k] - xu[k] + xg
        }
      }
      {
        x: Matrix::from_array(x_w_flat, n, p_x),
        y: y_s,
        d: d_s,
        d_mean_row: [],
        id: id_s,
      }
    } else {
      // v0.45.0: dead-code abort. `DoubleMLPLPR::new` requires
      // `approach` to be one of {cre_general, cre_normal,
      // fd_exact, wg_approx}, so this else branch is
      // unreachable through the public API. The abort is
      // kept as a defense-in-depth measure for callers that
      // construct `DoubleMLPLPR` directly via struct literal
      // (the struct is `pub`). v0.45.0 marks this explicitly
      // and improves the abort message to be more descriptive
      // (mentions `DoubleMLPLPR::new` as the expected
      // configuration site) so the diagnostic is actionable
      // if the abort ever fires.
      //
      // Same dead-code pattern as v0.37.0's
      // `did_multi.mbt:558` (p_adjust fallback), which was
      // documented and skipped.
      abort(
        "DoubleMLPLPR: unknown approach (set in DoubleMLPLPR::new): " + approach,
      )
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// DoubleMLPLPR model. See the struct docs on `DoubleMLPanelData`
/// and `transform_panel` for the four approaches. Scores:
/// `"partialling out"` (default) or `"IV-type"` (fits an extra
/// g-nuisance on `y - theta_initial * d` exactly like upstream).
pub struct DoubleMLPLPR {
  panel : DoubleMLPanelData
  approach : String
  score : String
  n_folds : Int
  n_rep : Int
  seed : Int
  // v0.59.0+: injected nuisance learner (replaces the v0.57.0
  // hardcoded `LinearRegression`). Defaults to OLS so v0.57.0
  // callers see byte-identical results.
  learner : LearnerDispatch
  coef_ : Double
  se_ : Double
  l_hat : Array[Double]
  m_hat : Array[Double]
  fitted : Bool
  // v0.75.0+: per-observation influence function components
  // for the multiplier bootstrap. Populated by `fit(...)` from
  // the LAST rep's cross-fitted nuisances on the
  // TRANSFORMED-domain sample (i.e. `l_hat / m_hat` length,
  // not `self.panel.y.length()`). `psi_a` is the score
  // derivative w.r.t. theta (PO: `-v_hat^2`; IV-type:
  // `-v_hat * d`); `psi_b` is the score offset
  // (PO: `v_hat * u_hat`; IV-type: `v_hat * (y - g_pred)`).
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
  // caches the LAST rep's `(l_hat, m_hat, fold_ids)` /
  // row-level fold mapping in `fit_cache` and reuses them on
  // the next call when the panel fingerprint, fold split,
  // and learner configuration are unchanged. Mirrors the IRM
  // / PLR / CVAR / SSM plumbing.
  memoize_enabled : Bool
  fit_cache : FitCache
} derive(Debug)

///|
pub extend DoubleMLPLPR with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DoubleMLPLPR::new(
  panel : DoubleMLPanelData,
  approach? : String = "fd_exact",
  score? : String = "partialling out",
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
  learner? : LearnerDispatch = LearnerDispatch::linear_regression(),
) -> DoubleMLPLPR {
  try {
    require(
      approach == "cre_general" ||
      approach == "cre_normal" ||
      approach == "fd_exact" ||
      approach == "wg_approx",
    )
    require(score == "partialling out" || score == "IV-type")
    require(n_folds >= 2)
    require(n_rep >= 1)
    {
      panel,
      approach,
      score,
      n_folds,
      n_rep,
      seed,
      learner,
      coef_: 0.0,
      se_: 0.0,
      l_hat: [],
      m_hat: [],
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
/// v0.83.0+: turn on memoization for subsequent `fit()` calls.
/// When enabled, `fit()` will cache the LAST rep's cross-
/// fitted `(l_hat, m_hat)` and the row-to-fold mapping; on a
/// repeat call whose panel fingerprint + fold split +
/// learner + approach + score is identical, the entire
/// per-fold crossfit is skipped and the cached values feed
/// the cluster-robust score / SE pipeline.
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
pub fn DoubleMLPLPR::enable_memoize(self : DoubleMLPLPR) -> DoubleMLPLPR {
  { ..self, memoize_enabled: true, }
}

///|
/// v0.83.0+: turn off memoization. Same immutability contract
/// as `enable_memoize()`. After this, `fit()` will not read or
/// write the cache; the existing `fit_cache` is preserved on
/// the returned struct (call `clear_cache()` to drop it).
pub fn DoubleMLPLPR::disable_memoize(self : DoubleMLPLPR) -> DoubleMLPLPR {
  { ..self, memoize_enabled: false, }
}

///|
/// v0.83.0+: drop any cached nuisance predictions and fold
/// assignment. Forces the next `fit()` to recompute from
/// scratch.
pub fn DoubleMLPLPR::clear_cache(self : DoubleMLPLPR) -> DoubleMLPLPR {
  { ..self, fit_cache: FitCache::empty(), }
}

///|
/// v0.83.0+: `true` iff `fit_cache` holds at least one cached
/// observation (i.e. at least one prior `fit()` call with
/// `memoize_enabled = true` has populated the cache). Note
/// that the cache may still be stale relative to the current
/// panel + learner configuration -- check `memoize_enabled`
/// before assuming a cache hit.
pub fn DoubleMLPLPR::has_cache(self : DoubleMLPLPR) -> Bool {
  !self.fit_cache.is_empty()
}

///|
pub fn DoubleMLPLPR::coef(self : DoubleMLPLPR) -> Double {
  try {
    require(self.fitted)
    self.coef_
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLPLPR::se(self : DoubleMLPLPR) -> Double {
  try {
    require(self.fitted)
    self.se_
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
pub fn DoubleMLPLPR::confint(self : DoubleMLPLPR) -> (Double, Double) {
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
/// Cross-fitted E[Y | X'] from the last repetition.
pub fn DoubleMLPLPR::predictions_l(self : DoubleMLPLPR) -> Array[Double] {
  try {
    require(self.fitted)
    self.l_hat
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Cross-fitted E[D | X'] (after any cre adjustment) from the last
/// repetition.
pub fn DoubleMLPLPR::predictions_m(self : DoubleMLPLPR) -> Array[Double] {
  try {
    require(self.fitted)
    self.m_hat
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

// ---------------------------------------------------------------------------
// Sensitivity (v0.70.0+)
// ---------------------------------------------------------------------------

///|
/// v0.70.0+: Cinelli & Hazlett (2020) omitted-variable bias
/// analysis for `DoubleMLPLPR` (Clarke & Polselli 2025 panel
/// partialling-out / IV-type). Single-theta IRM-style
/// decomposition: outcome residual is `y - l_hat` (the
/// cross-fitted outcome nuisance from the last rep; the same
/// convention used by the v0.66.0
/// `DoubleMLPLR::sensitivity_analysis`); the per-observation
/// Riesz representer `psi_a` is the score derivative w.r.t.
/// `theta`, recomputed on-the-fly from the stored
/// `(d, l_hat, m_hat)` to avoid growing the struct shape:
///
///   - `"partialling out"` score (default):
///     `psi_a[i] = -v_hat[i] * v_hat[i]` where
///     `v_hat[i] = d[i] - m_hat[i]`.
///   - `"IV-type"` score:
///     `psi_a[i] = -v_hat[i] * d[i]`
///
/// (matches the per-iteration `psi_a` definitions used by
/// `est_coef_cluster` / `var_est_cluster` inside `fit`).
///
/// The score branch is selected from `self.score` so the
/// sensitivity decomposition stays consistent with the score
/// actually used to fit the model.
///
/// `cf_y` / `cf_d` default to `0.05` matching the rest of the
/// v0.66.0-onward sensitivity family. Calling on an un-fit model
/// aborts via `PreconditionError`.
pub fn DoubleMLPLPR::sensitivity_analysis(
  self : DoubleMLPLPR,
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let y = self.panel.y
  let d = self.panel.d
  let l_hat = self.l_hat
  let m_hat = self.m_hat
  // plpr's fit() transforms the panel via `transform_panel` (e.g.
  // fd_exact drops the first period), so `l_hat / m_hat` are
  // indexed against the TRANSFORMED y, not `self.panel.y`.
  // We use `l_hat.length()` as the canonical n to keep both
  // arrays aligned; `self.panel.y[d]` accessors below only
  // touch the transformed-domain rows. This avoids an OOB
  // when `l_hat.length() != panel.y.length()`.
  let n = l_hat.length()
  let residuals : Array[Double] = Array::make(n, 0.0)
  let psi_a : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    residuals[i] = y[i] - l_hat[i]
    let v_hat = d[i] - m_hat[i]
    if self.score == "IV-type" {
      psi_a[i] = -v_hat * d[i]
    } else {
      psi_a[i] = -v_hat * v_hat
    }
  }
  irm_style_sensitivity(self.coef_, residuals, psi_a, cf_y, cf_d)
}

///|
/// Fit the DML estimator. Runs the standard cross-fit PO or
/// IV-type score on the transformed data, including upstream's
/// cre_general post-hoc m_hat adjustment and the clustered
/// inference path (unit-level folds, fold-weighted coefficient,
/// cluster-robust SE).
pub fn DoubleMLPLPR::fit(
  self : DoubleMLPLPR,
  learner? : LearnerDispatch = self.learner,
  max_attempts? : Int = 1,
) -> DoubleMLPLPR {
  try {
    ignore(learner)
    require(max_attempts >= 1)
    let tf = transform_panel(self.panel, self.approach)
    let n = tf.y.length()
    // Upstream re-wraps the transformed panel in a static-panel
    // DoubleMLPanelData whose constructor pins cluster_cols to the id
    // column, so PLPR always runs the clustered DML path: folds are
    // drawn over whole units (`Resampling.split_samples` KFolds the
    // unique cluster values), the causal parameter is the fold-weighted
    // ratio of cluster score sums, and the variance aggregates scores
    // at the unit level.
    let uniq = unique_units(tf.id)
    let n_units = uniq.length()
    require(n_units >= self.n_folds)
    // Row -> unit-position lookup (uses the shared
    // `build_row_unit_map` from kfold.mbt). v0.36.0: it raises
    // ClusterDataError::MissingUnit on a malformed cluster vector;
    // catch and re-abort to preserve pre-v0.36.0 behavior.
    let row_unit = build_row_unit_map(tf.id, uniq) catch {
      ClusterDataError::MissingUnit(g) =>
        abort(
          "expand_unit_folds_to_rows: row without a unit id (unit_id=" +
          g.to_string() +
          ")",
        )
    }
    // Ascending row indices per unit.
    let unit_rows : Array[Array[Int]] = Array::makei(n_units, fn(_) {
      let rows : Array[Int] = []
      rows
    })
    for i = 0; i < n; i = i + 1 {
      unit_rows[row_unit[i]].push(i)
    }
    let nrep = self.n_rep
    let coefs : Array[Double] = Array::make(nrep, 0.0)
    let ses : Array[Double] = Array::make(nrep, 0.0)
    let mut l_pred : Array[Double] = Array::make(n, 0.0)
    let mut m_pred : Array[Double] = Array::make(n, 0.0)
    // v0.83.0+: track the LAST rep's row-to-fold mapping for
    // the cache writeback. PLPR's fold structure is unit-level
    // (clusters) but the cache uses row-level `fold_ids` to
    // match the rest of the package's `FitCache` layout.
    let fold_ids : Array[Int] = Array::make(n, 0)
    // v0.83.0+: cached g_pred (only meaningful for IV-type
    // score; PO leaves it as an empty array). Stored so the
    // cache-hit path can reuse the IV-type auxiliary crossfit
    // without paying its `cross_fit_predict_dispatch` cost.
    let mut last_g_pred : Array[Double] = []
    // v0.75.0+: capture psi_a / psi_b from the LAST rep for the
    // multiplier bootstrap. Same convention as `l_pred` / `m_pred`:
    // each rep overwrites, so the post-loop values match the
    // last rep's nuisances (which are the ones persisted on the
    // struct).
    let mut last_psi_a : Array[Double] = Array::make(n, 0.0)
    let mut last_psi_b : Array[Double] = Array::make(n, 0.0)
    // v0.83.0+: memoize check (mirrors the PLR / IRM / CVAR
    // / SSM pattern). The cache stores the LAST rep's
    // `(l_pred, m_pred, g_pred)` plus row-to-fold mapping.
    // Honored only when `n_rep == 1` -- multi-rep
    // aggregations must run every rep fresh.
    let memoize = self.memoize_enabled && nrep == 1
    let data_hash : UInt64 = if memoize {
      // PLPR uses the panel's transformed-domain data; the
      // raw panel fields (x, y, d, t, id) are the user-visible
      // fingerprint and `transform_panel` is deterministic in
      // them + `approach`.
      hash_data(self.panel.x, self.panel.y, self.panel.d)
    } else {
      0UL
    }
    let hparams_hash : UInt64 = if memoize {
      // Approach + score enter the cache key via the
      // `estimator_kind` string ("plpr") + the propensity-clip
      // proxy. Approach/score are otherwise reflected through
      // the data_hash because `transform_panel` is fully
      // determined by the panel + approach.
      hash_hyperparams("plpr", learner, learner, 0.0)
    } else {
      0UL
    }
    let cluster_hash : UInt64 = if memoize {
      // PLPR's clustered DML path keys off the unit id column;
      // hash it so a different panel with the same numeric
      // content but different unit partition invalidates the
      // cache.
      hash_cluster_ids(self.panel.id)
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
        "plpr",
      )
    for r = 0; r < nrep; r = r + 1 {
      // v0.40.0: retry loop on J-floor (see plr.mbt::fit_cluster).
      let mut theta_r = 0.0
      let mut se_r = 0.0
      let mut attempt = 0
      let mut succeeded = false
      // v0.75.0+: psi_a / psi_b scoped to the for-loop so they
      // remain visible after the while-loop closes (the inner
      // while is the per-attempt loop; we persist the last
      // SUCCESSFUL attempt's IF components).
      let psi_a : Array[Double] = Array::make(n, 0.0)
      let psi_b : Array[Double] = Array::make(n, 0.0)
      if cache_hit && r == nrep - 1 {
        // Reuse the cached LAST-rep nuisances + fold_ids;
        // recompute the score + cluster SE from cached values
        // (the cluster fold structure is deterministic from
        // `seed + r` so we can rebuild it here).
        let preds = self.fit_cache.predictions
        for i = 0; i < n; i = i + 1 {
          l_pred[i] = preds[0][i]
          m_pred[i] = preds[1][i]
          fold_ids[i] = self.fit_cache.fold_ids[i]
        }
        let cached_g_pred : Array[Double] = preds[2]
        // Recompute folds from the seed (no retry on the
        // cache-hit path -- if the cluster SE path raises on
        // a previously-validated input, we let the error
        // propagate rather than silently re-fitting).
        let rep_seed = self.seed + r
        let folds_u = kfold(n_units, self.n_folds, rep_seed)
        let (folds_row, unit_fold, fold_n_units) = expand_unit_folds_to_rows(
          tf.id,
          folds_u,
          row_unit,
        )
        let v_hat = vector_subtract(tf.d, m_pred)
        if self.score == "IV-type" {
          let u_hat = vector_subtract(tf.y, l_pred)
          let psi_a0 = vector_multiply(vector_scale(v_hat, -1.0), v_hat)
          let psi_b0 = vector_multiply(v_hat, u_hat)
          let (theta_init, _) = var_est(psi_a0, psi_b0)
          ignore(theta_init) // we use cached g_pred, not a re-fit
          for i = 0; i < n; i = i + 1 {
            psi_a[i] = -v_hat[i] * tf.d[i]
            psi_b[i] = v_hat[i] * (tf.y[i] - cached_g_pred[i])
          }
        } else {
          let u_hat = vector_subtract(tf.y, l_pred)
          for i = 0; i < n; i = i + 1 {
            psi_a[i] = -v_hat[i] * v_hat[i]
            psi_b[i] = v_hat[i] * u_hat[i]
          }
        }
        let (t, s) = cluster_causal_param_and_se(
          psi_a,
          psi_b,
          folds_row,
          fold_n_units,
          unit_rows,
          unit_fold,
          folds_u.length(),
          self.n_folds,
        ) catch {
          // v0.83.0+: on the cache-hit path we don't retry --
          // the cache was already validated as
          // cluster-numerically-stable when it was populated. If
          // the cluster SE path still raises here (e.g. a
          // numerical edge case the original write didn't
          // catch), abort with the same message the retry
          // loop uses after `max_attempts` fires.
          _ =>
            abort(
              "var_est_cluster: J-floor fired on cache-hit path for rep=" +
              r.to_string() +
              " (cluster SE numerically unstable; clear_cache() and re-fit with a different seed)",
            )
        }
        theta_r = t
        se_r = s
        succeeded = true
      } else {
        while attempt < max_attempts && !succeeded {
          let rep_seed = self.seed + r + attempt * nrep
          // Unit-level folds expanded to row-level folds via the
          // shared helper (rows of one unit stay on the same side
          // of every split).
          let folds_u = kfold(n_units, self.n_folds, rep_seed)
          let (folds_row, unit_fold, fold_n_units) = expand_unit_folds_to_rows(
            tf.id,
            folds_u,
            row_unit,
          )
          l_pred = cross_fit_predict_dispatch(learner, tf.x, tf.y, folds_row)
          if self.approach == "cre_normal" {
            // ml_m gets [X, d_mean] as inputs.
            let p = tf.x.cols()
            let xm_flat : Array[Double] = Array::make(n * (p + 1), 0.0)
            for i = 0; i < n; i = i + 1 {
              for j = 0; j < p; j = j + 1 {
                xm_flat[i * (p + 1) + j] = tf.x.get(i, j)
              }
              xm_flat[i * (p + 1) + p] = tf.d_mean_row[i]
            }
            let xm = Matrix::from_array(xm_flat, n, p + 1)
            m_pred = cross_fit_predict_dispatch(learner, xm, tf.d, folds_row)
          } else {
            m_pred = cross_fit_predict_dispatch(learner, tf.x, tf.d, folds_row)
          }
          // cre_general: post-hoc adjustment
          //   m_hat* = m_hat + d_mean - mean_by_id(m_hat).
          if self.approach == "cre_general" {
            let mh_mean = unit_means(m_pred, tf.id)
            for i = 0; i < n; i = i + 1 {
              m_pred[i] = m_pred[i] + tf.d_mean_row[i] - mh_mean[i]
            }
          }
          // Build row->fold_id map for the LAST rep / LAST
          // attempt (used by the cache writeback below).
          if memoize && r == nrep - 1 {
            for f = 0; f < folds_row.length(); f = f + 1 {
              for i in folds_row[f].test_indices() {
                fold_ids[i] = f
              }
            }
          }
          // v0.83.0+: residual vector via `vector_subtract`.
          let v_hat = vector_subtract(tf.d, m_pred)
          let mut g_pred : Array[Double] = []
          // v0.75.0+: psi_a / psi_b computed in both score
          // branches; assigned directly into the outer-scope
          // `psi_a` / `psi_b` (declared at for-loop level) so the
          // values survive the while-loop closing.
          if self.score == "IV-type" {
            // theta_initial from the PO score, then g on y - theta*d.
            let u_hat = vector_subtract(tf.y, l_pred)
            let psi_a0 = vector_multiply(vector_scale(v_hat, -1.0), v_hat)
            let psi_b0 = vector_multiply(v_hat, u_hat)
            // Upstream seeds the IV-type g fit with a plain ratio of
            // means (np.nanmean), independent of clustering.
            let (theta_init, _) = var_est(psi_a0, psi_b0)
            let y_resid = vector_subtract(tf.y, vector_scale(tf.d, theta_init))
            g_pred = cross_fit_predict_dispatch(
              learner,
              tf.x,
              y_resid,
              folds_row,
            )
            for i = 0; i < n; i = i + 1 {
              psi_a[i] = -v_hat[i] * tf.d[i]
              psi_b[i] = v_hat[i] * (tf.y[i] - g_pred[i])
            }
          } else {
            let u_hat = vector_subtract(tf.y, l_pred)
            for i = 0; i < n; i = i + 1 {
              psi_a[i] = -v_hat[i] * v_hat[i]
              psi_b[i] = v_hat[i] * u_hat[i]
            }
          }
          // Track g_pred for the LAST rep (used by the cache
          // writeback below).
          if memoize && r == nrep - 1 {
            last_g_pred = g_pred
          }
          // Clustered-path coefficient and standard error via the
          // shared helper (fold-weighted cluster ratio + unit-level
          // cluster-robust SE).
          let (t, s) = cluster_causal_param_and_se(
            psi_a,
            psi_b,
            folds_row,
            fold_n_units,
            unit_rows,
            unit_fold,
            folds_u.length(),
            self.n_folds,
          ) catch {
            _ => {
              attempt = attempt + 1
              (0.0, 0.0)
            }
          }
          theta_r = t
          se_r = s
          succeeded = true
        }
      }
      // Persist the last rep's IF components for the bootstrap.
      last_psi_a = psi_a
      last_psi_b = psi_b
      if !succeeded {
        abort(
          "var_est_cluster: J-floor fired " +
          max_attempts.to_string() +
          " times for rep=" +
          r.to_string() +
          " (cluster SE numerically unstable across multiple fold splits, try a different seed or larger n_units)",
        )
      }
      coefs[r] = theta_r
      ses[r] = se_r
    }
    let (coef, se) = aggregate_coef_se(coefs, ses)
    // v0.83.0+: write freshly-computed fold_ids + nuisances
    // (incl. g_pred for IV-type reuse) to the cache if memoize
    // is on and the cache missed.
    let next_cache = if memoize && !cache_hit && nrep == 1 {
      FitCache::from_fit(
        fold_ids,
        [l_pred, m_pred, last_g_pred],
        self.seed,
        self.n_folds,
        nrep,
        n,
        data_hash,
        hparams_hash,
        cluster_hash,
        "plpr",
      )
    } else {
      self.fit_cache
    }
    {
      panel: self.panel,
      approach: self.approach,
      score: self.score,
      n_folds: self.n_folds,
      n_rep: self.n_rep,
      seed: self.seed,
      learner,
      coef_: coef,
      se_: se,
      l_hat: l_pred,
      m_hat: m_pred,
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
/// v0.75.0+: multiplier bootstrap for `DoubleMLPLPR`. The
/// per-observation influence function is
///
///   psi[i] = theta * psi_a[i] + psi_b[i]
///
/// where `psi_a[i]` (PO: `-v_hat[i]^2`; IV-type:
/// `-v_hat[i] * d[i]`) and `psi_b[i]` (PO:
/// `v_hat[i] * u_hat[i]`; IV-type:
/// `v_hat[i] * (y[i] - g_pred[i])`) are populated by `fit(...)`
/// from the LAST rep's cross-fitted nuisances on the
/// TRANSFORMED-domain sample. Note that this is an IID bootstrap
/// (multipliers drawn independently of `transform_panel`'s
/// clustering); the cluster-aware variance comes from the
/// `var_est_cluster` call inside `fit(...)`, not from the
/// multiplier weights.
///
/// `method_name` selects the multiplier distribution:
/// `"normal"` (default), `"Bayes"`, `"wild"`; `seed` defaults to
/// `2024`; `n_rep_boot` defaults to `500`.
///
/// Calling on an un-fit model aborts via `PreconditionError`.
/// Returns a new `DoubleMLPLPR` with `boot_t_stat` /
/// `boot_method` / `n_rep_boot` / `boot_seed` populated.
pub fn DoubleMLPLPR::bootstrap(
  self : DoubleMLPLPR,
  method_name? : String = "normal",
  n_rep_boot? : Int = 500,
  seed? : Int = 2024,
) -> DoubleMLPLPR {
  try {
    require(self.fitted)
    require(
      method_name == "normal" || method_name == "Bayes" || method_name == "wild",
    )
    require(n_rep_boot >= 2)
    let boot_t_stat = generic_bootstrap_t_stat(
      self.psi_a,
      self.psi_b,
      self.coef_,
      method_name,
      n_rep_boot,
      seed,
    ) catch {
      BootstrapMethodError::UnknownMethod(m) =>
        abort(
          "draw_bootstrap_weights: unknown method (set in DoubleMLPLPR::bootstrap): " +
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
/// Tune the single nuisance `learner` via MSE-on-l_hat
/// cross-fitting. The winning learner is re-fit on the FINAL-FIT
/// fold partition (`self.n_folds`) under `DoubleMLPLPR::fit`; the
/// tune-time cross-fit is not reused. `scoring_method` is `"MSE"`
/// (default), `"RMSE"` or `"NegMSE"`; `n_folds_tune` defaults to
/// 5 and `seed` to 3141. Returns a re-fitted `DoubleMLPLPR`.
///
/// Grid shape: `param_set` is a bare `Array[LearnerDispatch]`,
/// NOT an `Array[TuneParam]`. PLPR is a one-slot estimator, so a
/// two-learner `TuneParam` would be a wrapper around a single
/// value, and upstream's one-slot estimators use the bare array
/// (same shape as `DoubleMLPLIV::tune`). PLPR is outcome-first:
/// the candidates are outcome learners `E[y|x]`, so there is no
/// slot role to disambiguate and no `for_outcome` / `for_treatment`
/// factory to reach for.
///
/// v0.108.0: new. PLPR had no `tune` at all, so it was one of the
/// estimators carrying a coverage gap against upstream, where
/// `tune` reaches every estimator through the `BaseDML` mixin.
/// The fold draw, the scoring loop and the argmin/argmax
/// selection route through the shared `tune_score_grid` core,
/// which is keyed on the learner array precisely so both the
/// two-slot and the one-slot grid shapes can share it. PLPR
/// exposes no `n_obs()`, which is why the core derives the
/// observation count from `y.length()`.
///
/// `max_attempts` is NOT forwarded. It is a `fit` parameter with
/// no corresponding struct field, so there is no
/// `self.max_attempts` to read; the re-fit gets `fit`'s default
/// of 1 retry. A caller who needs the numerical-retry path must
/// call `fit(learner = ..., max_attempts = k)` explicitly after
/// tuning, rather than expecting `tune` to preserve it.
///
/// Two mismatches between the tune-time cross-fit and the
/// estimation path, stated here because a guard cannot fix them
/// and a caller choosing learners needs to know:
///
///   1. Fold granularity. `tune_score_grid` draws a ROW-WISE
///      `kfold` schedule, while `fit` always runs the clustered
///      DML path with folds drawn over whole UNITS
///      (`unique_units(tf.id)`). For a panel this is the same
///      row-vs-unit hazard the cluster guard exists to block in
///      the other estimators, except that PLPR is unconditionally
///      clustered, so there is no non-clustered case to admit and
///      no guard could do useful work.
///   2. Domain. The grid scores candidates against the RAW panel
///      (`self.panel.x` / `self.panel.y`), while `fit` estimates on
///      the TRANSFORMED cross-section produced by
///      `transform_panel` (`fd_exact` first-differences and drops
///      rows, `wg_approx` within-transforms). The ranking is a
///      proxy measured on the raw domain, not on the domain the
///      estimate is computed in.
///
/// No cluster guard: `DoubleMLPanelData` has no `cluster_vars`
/// field and exposes no `is_cluster_data()`, so the guard has
/// nothing to call. The method does not add the method.
pub fn DoubleMLPLPR::tune(
  self : DoubleMLPLPR,
  param_set~ : Array[LearnerDispatch],
  scoring_method? : String = "MSE",
  n_folds_tune? : Int = 5,
  seed? : Int = 3141,
) -> DoubleMLPLPR {
  try {
    require(param_set.length() > 0)
    require(n_folds_tune >= 2)
    let scoring = TuneScoring::parse(scoring_method)
    // `param_set` is already a learner array, so it is passed
    // straight through; see the doc comment on the grid shape.
    let grid = tune_score_grid(
      self.panel.x,
      self.panel.y,
      param_set,
      n_folds_tune,
      seed,
      scoring,
    )
    // `max_attempts` is deliberately absent; see the doc comment.
    self.fit(learner=param_set[grid.best_index])
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.73.0+: cluster-robust analogue of
/// `DoubleMLPLPR::sensitivity_analysis`. Same
/// partialling-out / IV-type residual form `y - l_hat`
/// and the same per-observation Riesz representer
/// (PO: `-v_hat^2`; IV-type: `-v_hat * d`) as the IID
/// path; only the variance / bias computation is
/// cluster-aware (see `irm_style_sensitivity_cluster` in
/// sensitivity.mbt).
///
/// **`cluster_ids` MUST be in the TRANSFORMED domain**
/// (length `self.l_hat.length()`), not the raw panel length
/// (`self.panel.y.length()`). `plpr`'s `fit()` applies
/// `transform_panel` to the raw panel -- for example,
/// `fd_exact` drops the first period -- and `l_hat` /
/// `m_hat` are indexed against the transformed cross-
/// section. The user must pre-drop rows from
/// `cluster_ids` matching `transform_panel`'s drop logic
/// (e.g., drop rows where `t == 0` for `fd_exact` on a
/// 0-indexed time grid). The DGP is balanced enough that
/// dropping by `(t == 0)` works in practice.
///
/// `DoubleMLPanelData` has no `cluster_vars` field, so the
/// user must pass `cluster_ids` explicitly.
pub fn DoubleMLPLPR::sensitivity_analysis_cluster(
  self : DoubleMLPLPR,
  cluster_ids : Array[Int],
  cf_y? : Double = 0.05,
  cf_d? : Double = 0.05,
) -> SensitivityResult raise {
  require(self.fitted)
  let y = self.panel.y
  let d = self.panel.d
  let l_hat = self.l_hat
  let m_hat = self.m_hat
  let n = l_hat.length()
  require(cluster_ids.length() == n)
  let residuals : Array[Double] = Array::make(n, 0.0)
  let psi_a : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    residuals[i] = y[i] - l_hat[i]
    let v_hat = d[i] - m_hat[i]
    if self.score == "IV-type" {
      psi_a[i] = -v_hat * d[i]
    } else {
      psi_a[i] = -v_hat * v_hat
    }
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
// v0.87.0+: sandwich variance + bias correction
// ---------------------------------------------------------------------------

///|
/// v0.87.0+: Huber-White sandwich standard error for the
/// fitted PLPR. Returns `sqrt(var)` where `var` comes from
/// the shared `sandwich_variance(kind, ...)` dispatch in
/// `sandwich.mbt` (HC0 / HC1 / HC2 / HC3), the same dispatch
/// `DoubleMLDID` / `DoubleMLIIVM` / `DoubleMLCVAR` use.
///
/// The three inputs are the ones `fit(...)` already persists
/// for the multiplier bootstrap (see the `psi_a` / `psi_b`
/// field docs on `DoubleMLPLPR`):
///   - `psi_a`  = `self.psi_a` -- the score derivative in
///     theta (partialling-out: `-v_hat[i]^2`; IV-type:
///     `-v_hat[i] * d[i]`). Under the default PO score every
///     element is `<= 0`, so `mean(psi_a) <= 0`.
///   - `psi`    = `psi_at(self.coef_, self.psi_a, self.psi_b)`
///     -- the per-observation influence function at the
///     fitted `coef`, matching the `psi[i] = psi_a[i] +
///     theta * psi_b[i]` form documented on
///     `DoubleMLPLPR::bootstrap`.
///   - `M_inv`  = `[[1 / mean(psi_a)]]` (1x1). Only
///     `M_inv[0, 0]^2` enters the variance, so the sign of
///     the (up-to-sign) Jacobian inverse is irrelevant.
///
/// Note the sample length: `psi_a` / `psi_b` live on the
/// TRANSFORMED-domain sample, so the variance's `n_obs` is
/// `self.psi_a.length()` (= `self.l_hat.length()`), which
/// equals `self.data.n_obs()` for the untransformed
/// approaches and can differ once an `fd_exact` /
/// `within_transform` approach changes the row set. The
/// variance's `n_obs` therefore follows `psi_a`, never the
/// raw panel width.
///
/// Preconditions: `self.fitted`, `mean(psi_a) != 0`.
pub fn DoubleMLPLPR::sandwich_se(
  self : DoubleMLPLPR,
  kind : SandwichKind,
) -> Double {
  try {
    require(self.fitted)
    let n = self.psi_a.length()
    require(n == self.psi_b.length())
    let psi = psi_at(self.coef_, self.psi_a, self.psi_b)
    let mean_a = mean(self.psi_a)
    require(mean_a.abs() > 0.0)
    let m_inv = Matrix::from_array([1.0 / mean_a], 1, 1)
    let variance_val = sandwich_variance(kind, self.psi_a, psi, m_inv, n, 1)
    require(variance_val >= 0.0)
    variance_val.sqrt()
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

///|
/// v0.87.0+: cluster-robust sandwich standard error for the
/// fitted PLPR. Routes through `cluster_sandwich_variance`
/// with the same `psi_a` / `psi` / `M_inv` inputs as the IID
/// `sandwich_se` path. `DoubleMLPanelData` carries no
/// `cluster_vars` field, so the user must pass `cluster_ids`
/// explicitly (typically the panel unit id).
///
/// Note: PLPR's own `se` is already unit-clustered (it uses
/// the fold-level cluster sums); this method exposes the
/// generic cluster-robust sandwich on the same sample so the
/// two can be compared on a common footing.
///
/// Preconditions: `self.fitted`,
/// `cluster_ids.length() == psi_a.length()`.
pub fn DoubleMLPLPR::cluster_sandwich_se(
  self : DoubleMLPLPR,
  cluster_ids : Array[Int],
) -> Double {
  try {
    require(self.fitted)
    let n = self.psi_a.length()
    require(n == self.psi_b.length())
    require(cluster_ids.length() == n)
    let psi = psi_at(self.coef_, self.psi_a, self.psi_b)
    let mean_a = mean(self.psi_a)
    require(mean_a.abs() > 0.0)
    let m_inv = Matrix::from_array([1.0 / mean_a], 1, 1)
    let variance_val = cluster_sandwich_variance(
      self.psi_a,
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
/// v0.91.0+: returns `coef` UNCHANGED -- a documented
/// no-op, not a bias correction.
///
/// `coef` is the root of the DML moment
/// `f(theta) = E[theta * psi_a + psi_b]` (see
/// `var_est.mbt`), so `mean(f(coef))` is identically
/// zero: the estimating function is orthogonal by
/// construction, and that orthogonality IS what makes
/// the estimator consistent. Nothing computable from
/// the fitted scores is a bias estimate for this class
/// of estimator, so this accessor reports the
/// uncorrected point estimate rather than a number
/// that merely looks like a correction.
///
///
/// v0.79.0 - v0.90.0 returned
/// `coef + mean(psi_b - coef * psi_a)`. That
/// vector is the score at `-coef`, NOT at `coef`;
/// since `coef = -mean_b / mean_a` its mean is
/// `mean_b - coef * mean_a = -2 * coef * mean_a`,
/// so the accessor returned
/// `coef * (1 - 2 * mean(psi_a))` (exactly `3 * coef`
/// when `mean(psi_a) = -1`). That is not a bias
/// estimate. See `bias_corrected_theta` in
/// `sandwich.mbt` for the algebra. The method is kept
/// so the API surface stays stable; removing it
/// outright is the obvious follow-up.
///
/// Preconditions: `self.fitted`.
pub fn DoubleMLPLPR::bias_corrected_coef(self : DoubleMLPLPR) -> Double {
  try {
    require(self.fitted)
    self.coef_
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
