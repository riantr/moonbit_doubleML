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
  // is conservative — most natural fold splits have J > 1e-3.
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
  coef_ : Double
  se_ : Double
  l_hat : Array[Double]
  m_hat : Array[Double]
  fitted : Bool
} derive(Debug)

///|
pub fn DoubleMLPLPR::new(
  panel : DoubleMLPanelData,
  approach? : String = "fd_exact",
  score? : String = "partialling out",
  n_folds? : Int = 2,
  n_rep? : Int = 1,
  seed? : Int = 3141,
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
      coef_: 0.0,
      se_: 0.0,
      l_hat: [],
      m_hat: [],
      fitted: false,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
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

///|
/// Fit the DML estimator. Runs the standard cross-fit PO or
/// IV-type score on the transformed data, including upstream's
/// cre_general post-hoc m_hat adjustment and the clustered
/// inference path (unit-level folds, fold-weighted coefficient,
/// cluster-robust SE).
pub fn DoubleMLPLPR::fit(
  self : DoubleMLPLPR,
  learner? : LinearRegression = LinearRegression::new(),
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
    for r = 0; r < nrep; r = r + 1 {
      // v0.40.0: retry loop on J-floor (see plr.mbt::fit_cluster).
      let mut theta_r = 0.0
      let mut se_r = 0.0
      let mut attempt = 0
      let mut succeeded = false
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
        l_pred = cross_fit_predict(
          LinearRegression::new(),
          tf.x,
          tf.y,
          folds_row,
        )
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
          m_pred = cross_fit_predict(
            LinearRegression::new(),
            xm,
            tf.d,
            folds_row,
          )
        } else {
          m_pred = cross_fit_predict(
            LinearRegression::new(),
            tf.x,
            tf.d,
            folds_row,
          )
        }
        // cre_general: post-hoc adjustment
        //   m_hat* = m_hat + d_mean - mean_by_id(m_hat).
        if self.approach == "cre_general" {
          let mh_mean = unit_means(m_pred, tf.id)
          for i = 0; i < n; i = i + 1 {
            m_pred[i] = m_pred[i] + tf.d_mean_row[i] - mh_mean[i]
          }
        }
        let v_hat : Array[Double] = Array::make(n, 0.0)
        for i = 0; i < n; i = i + 1 {
          v_hat[i] = tf.d[i] - m_pred[i]
        }
        let (psi_a, psi_b) = if self.score == "IV-type" {
          // theta_initial from the PO score, then g on y - theta*d.
          let u_hat : Array[Double] = Array::make(n, 0.0)
          for i = 0; i < n; i = i + 1 {
            u_hat[i] = tf.y[i] - l_pred[i]
          }
          let psi_a0 : Array[Double] = Array::make(n, 0.0)
          let psi_b0 : Array[Double] = Array::make(n, 0.0)
          for i = 0; i < n; i = i + 1 {
            psi_a0[i] = -v_hat[i] * v_hat[i]
            psi_b0[i] = v_hat[i] * u_hat[i]
          }
          // Upstream seeds the IV-type g fit with a plain ratio of
          // means (np.nanmean), independent of clustering.
          let (theta_init, _) = var_est(psi_a0, psi_b0)
          let y_resid : Array[Double] = Array::make(n, 0.0)
          for i = 0; i < n; i = i + 1 {
            y_resid[i] = tf.y[i] - theta_init * tf.d[i]
          }
          let g_pred = cross_fit_predict(
            LinearRegression::new(),
            tf.x,
            y_resid,
            folds_row,
          )
          let psi_a_iv : Array[Double] = Array::make(n, 0.0)
          let psi_b_iv : Array[Double] = Array::make(n, 0.0)
          for i = 0; i < n; i = i + 1 {
            psi_a_iv[i] = -v_hat[i] * tf.d[i]
            psi_b_iv[i] = v_hat[i] * (tf.y[i] - g_pred[i])
          }
          (psi_a_iv, psi_b_iv)
        } else {
          let u_hat : Array[Double] = Array::make(n, 0.0)
          let psi_a_po : Array[Double] = Array::make(n, 0.0)
          let psi_b_po : Array[Double] = Array::make(n, 0.0)
          for i = 0; i < n; i = i + 1 {
            u_hat[i] = tf.y[i] - l_pred[i]
            psi_a_po[i] = -v_hat[i] * v_hat[i]
            psi_b_po[i] = v_hat[i] * u_hat[i]
          }
          (psi_a_po, psi_b_po)
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
    {
      panel: self.panel,
      approach: self.approach,
      score: self.score,
      n_folds: self.n_folds,
      n_rep: self.n_rep,
      seed: self.seed,
      coef_: coef,
      se_: se,
      l_hat: l_pred,
      m_hat: m_pred,
      fitted: true,
    }
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}
