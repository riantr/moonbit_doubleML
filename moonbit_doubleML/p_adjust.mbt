///|
// Public p-adjustment utility.
//
// Extracted from `did_multi.mbt` in v0.54.0 so that the 7
// algorithms are reusable across all estimators (not just
// DIDMulti). Each function matches the corresponding upstream
// `statsmodels.stats.multitest.multipletests` semantics so the
// outputs are byte-comparable to `statsmodels` reference.
//
// Algorithms:
//   - romano_wolf_p_adjust     (stepdown bootstrap, NOT in statsmodels)
//   - holm_bonferroni_p_adjust ("holm")
//   - bonferroni_p_adjust      ("bonferroni")
//   - bh_fdr_p_adjust          ("fdr_bh" / "bh")
//   - by_fdr_p_adjust          ("fdr_by" / "by")
//   - tsbh_p_adjust            ("fdr_tsbh" / "tsbh")
//   - tsby_p_adjust            ("fdr_tsbky" / "tsby")
//
// All output arrays are clipped to `[0, 1]`. Order matches the
// order of the input array (no sort-then-unsort dance in the
// caller).

// ---------------------------------------------------------------------------
// Internal: insertion-sort helper
// ---------------------------------------------------------------------------

///|
/// Insertion sort by ascending `unadjusted[order[i]]`. Returns
/// the permutation `order` such that `unadjusted[order[0]] <=
/// unadjusted[order[1]] <= ...`. O(n^2); n is typically small
/// (3-12 cells for DIDMulti) so this is fine.
fn argsort_asc(unadjusted : Array[Double]) -> Array[Int] {
  let n = unadjusted.length()
  let order : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    order[i] = i
  }
  for i = 1; i < n; i = i + 1 {
    let mut j = i
    while j > 0 && unadjusted[order[j]] < unadjusted[order[j - 1]] {
      let tmp = order[j]
      order[j] = order[j - 1]
      order[j - 1] = tmp
      j = j - 1
    }
  }
  order
}

// ---------------------------------------------------------------------------
// Romano-Wolf stepdown bootstrap
// ---------------------------------------------------------------------------

///|
/// Romano-Wolf (2005) stepdown p-adjustment. The stepdown
/// critical value at rank `i_theta` is
/// `max_{j > i_theta} |boot_t_stat[b, j]|` per bootstrap
/// replication `b`. The unadjusted p-value at rank `i_theta`
/// is `frac{b : cv_b >= |t_{i_theta}|} / n_boot`. Enforces
/// monotonicity from the smallest |t| upward. Re-orders to
/// the original cell order.
///
/// `boot_t_stat` is row-major `(n_boot, n_thetas)`.
///
/// The algorithm does not depend on the `unadjusted` p-values
/// directly; it consumes `t_stats` (length `n_thetas`). The
/// `unadjusted` argument is accepted for API symmetry with the
/// other p-adjust entry points and is ignored.
pub fn romano_wolf_p_adjust(
  boot_t_stat : Array[Double],
  unadjusted : Array[Double],
  t_stats : Array[Double],
) -> Array[Double] {
  try {
    let n = t_stats.length()
    let n_boot = boot_t_stat.length() / n
    require(n_boot > 0)
    // Sort |t| descending. We use a simple O(n^2) selection
    // sort because n is typically small (3-12 cells).
    let stepdown_ind : Array[Int] = Array::make(n, 0)
    for i = 0; i < n; i = i + 1 {
      stepdown_ind[i] = i
    }
    let abs_t : Array[Double] = Array::make(n, 0.0)
    for i = 0; i < n; i = i + 1 {
      let t = t_stats[i]
      abs_t[i] = if t < 0.0 { -t } else { t }
    }
    // Simple insertion sort on `stepdown_ind` by descending
    // `abs_t`.
    for i = 1; i < n; i = i + 1 {
      let mut j = i
      while j > 0 && abs_t[stepdown_ind[j]] > abs_t[stepdown_ind[j - 1]] {
        let tmp = stepdown_ind[j]
        stepdown_ind[j] = stepdown_ind[j - 1]
        stepdown_ind[j - 1] = tmp
        j = j - 1
      }
    }
    // `ro` is the inverse permutation of `stepdown_ind`:
    // `ro[stepdown_ind[i]] = i`.
    let ro : Array[Int] = Array::make(n, 0)
    for i = 0; i < n; i = i + 1 {
      ro[stepdown_ind[i]] = i
    }
    // Compute the stepdown p-values.
    let p_sorted : Array[Double] = Array::make(n, 1.0)
    for i_theta = 0; i_theta < n; i_theta = i_theta + 1 {
      // Bootstrap critical value per replication: max
      // |boot_t_stat[b, j]| for `j > i_theta` (in stepdown
      // order). Use `np.delete`-equivalent: skip the cells
      // at stepdown positions `0..i_theta`.
      let mut p_k = 0.0
      for b = 0; b < n_boot; b = b + 1 {
        let mut cv = 0.0
        for j = i_theta; j < n; j = j + 1 {
          let idx = stepdown_ind[j]
          let v = boot_t_stat[b * n + idx]
          let av = if v < 0.0 { -v } else { v }
          if av > cv {
            cv = av
          }
        }
        let t_target = abs_t[stepdown_ind[i_theta]]
        if cv >= t_target {
          p_k = p_k + 1.0
        }
      }
      let p_k_normalised = if p_k / n_boot.to_double() > 1.0 {
        1.0
      } else {
        p_k / n_boot.to_double()
      }
      p_sorted[i_theta] = p_k_normalised
    }
    // Enforce monotonicity.
    for i_theta = 1; i_theta < n; i_theta = i_theta + 1 {
      if p_sorted[i_theta] < p_sorted[i_theta - 1] {
        p_sorted[i_theta] = p_sorted[i_theta - 1]
      }
    }
    // Re-order to original cell order via `ro`.
    let out : Array[Double] = Array::make(n, 1.0)
    for i = 0; i < n; i = i + 1 {
      out[i] = p_sorted[ro[i]]
    }
    ignore(unadjusted)
    out
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc.to_string())
  }
}

// ---------------------------------------------------------------------------
// Holm-Bonferroni and Bonferroni
// ---------------------------------------------------------------------------

///|
/// Holm-Bonferroni stepdown correction. Sort unadjusted
/// p-values ascending, then `p_corrected_sorted[k] =
/// max((n - k) * p_sorted[k], p_corrected_sorted[k - 1])`,
/// clipped to `1.0`. Re-order to original cell order.
pub fn holm_bonferroni_p_adjust(unadjusted : Array[Double]) -> Array[Double] {
  let n = unadjusted.length()
  let order = argsort_asc(unadjusted)
  let ro : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    ro[order[i]] = i
  }
  let p_sorted : Array[Double] = Array::make(n, 1.0)
  p_sorted[0] = if unadjusted[order[0]] * n.to_double() > 1.0 {
    1.0
  } else {
    unadjusted[order[0]] * n.to_double()
  }
  for i = 1; i < n; i = i + 1 {
    let raw = unadjusted[order[i]] * (n - i).to_double()
    let mut candidate = if raw > 1.0 { 1.0 } else { raw }
    if candidate < p_sorted[i - 1] {
      candidate = p_sorted[i - 1]
    }
    p_sorted[i] = candidate
  }
  let out : Array[Double] = Array::make(n, 1.0)
  for i = 0; i < n; i = i + 1 {
    out[i] = p_sorted[ro[i]]
  }
  out
}

///|
/// Bonferroni correction. `p_corrected[k] = min(1.0, n *
/// p_unadjusted[k])`.
pub fn bonferroni_p_adjust(unadjusted : Array[Double]) -> Array[Double] {
  let n = unadjusted.length()
  let out : Array[Double] = Array::make(n, 1.0)
  for i = 0; i < n; i = i + 1 {
    let p = unadjusted[i] * n.to_double()
    out[i] = if p > 1.0 { 1.0 } else { p }
  }
  out
}

// ---------------------------------------------------------------------------
// Benjamini-Hochberg / Benjamini-Yekutieli (FDR)
// ---------------------------------------------------------------------------

///|
/// Benjamini-Hochberg FDR correction.
///
/// Algorithm (matches `statsmodels.stats.multitest.multipletests`
/// with `method='fdr_bh'`):
///   1. Sort unadjusted p-values ascending; let `order` be the
///      resulting permutation of cell indices and `ro` its
///      inverse.
///   2. `p_corrected_sorted[k] = min(1.0, p_sorted[k] * n / (k + 1))`.
///   3. Enforce monotonicity **from the largest rank downward**
///      (this is the BH-specific direction; Holm goes the
///      other way):
///      `p_corrected_sorted[k] = min(p_corrected_sorted[k],
///      p_corrected_sorted[k + 1])`.
///   4. Re-order to original cell order via `ro`.
///
/// `p_corrected[k] >= p_unadjusted[k]` is not guaranteed
/// (BH controls FDR, not FWER); some adjusted p-values can
/// be smaller than the unadjusted ones.
pub fn bh_fdr_p_adjust(unadjusted : Array[Double]) -> Array[Double] {
  let n = unadjusted.length()
  let order = argsort_asc(unadjusted)
  let ro : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    ro[order[i]] = i
  }
  let p_sorted : Array[Double] = Array::make(n, 1.0)
  let n_d = n.to_double()
  for i = 0; i < n; i = i + 1 {
    let raw = unadjusted[order[i]] * n_d / (i + 1).to_double()
    p_sorted[i] = if raw > 1.0 { 1.0 } else { raw }
  }
  // Enforce monotonicity from the largest rank downward.
  let mut k = n - 2
  while k >= 0 {
    if p_sorted[k] > p_sorted[k + 1] {
      p_sorted[k] = p_sorted[k + 1]
    }
    k = k - 1
  }
  let out : Array[Double] = Array::make(n, 1.0)
  for i = 0; i < n; i = i + 1 {
    out[i] = p_sorted[ro[i]]
  }
  out
}

///|
/// Benjamini-Yekutieli FDR correction.
///
/// Algorithm (matches `statsmodels.stats.multitest.multipletests`
/// with `method='fdr_by'`):
///   1. Compute the harmonic-sum factor
///      `c = sum_{i=1}^{n} 1/i` (a.k.a. `H_n`).
///   2. Same as BH, but
///      `p_corrected_sorted[k] = min(1.0, p_sorted[k] * n * c / (k + 1))`.
///   3. Enforce monotonicity from the largest rank downward
///      (same as BH).
///   4. Re-order to original cell order via `ro`.
///
/// The `c` factor accounts for the dependence structure
/// under arbitrary dependence; the BY procedure is more
/// conservative than BH but valid under weaker assumptions.
pub fn by_fdr_p_adjust(unadjusted : Array[Double]) -> Array[Double] {
  let n = unadjusted.length()
  // Harmonic sum `c = sum_{i=1}^{n} 1/i`.
  let mut c = 0.0
  for i = 1; i <= n; i = i + 1 {
    c = c + 1.0 / i.to_double()
  }
  let order = argsort_asc(unadjusted)
  let ro : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    ro[order[i]] = i
  }
  let p_sorted : Array[Double] = Array::make(n, 1.0)
  let n_d = n.to_double()
  for i = 0; i < n; i = i + 1 {
    let raw = unadjusted[order[i]] * n_d * c / (i + 1).to_double()
    p_sorted[i] = if raw > 1.0 { 1.0 } else { raw }
  }
  let mut k = n - 2
  while k >= 0 {
    if p_sorted[k] > p_sorted[k + 1] {
      p_sorted[k] = p_sorted[k + 1]
    }
    k = k - 1
  }
  let out : Array[Double] = Array::make(n, 1.0)
  for i = 0; i < n; i = i + 1 {
    out[i] = p_sorted[ro[i]]
  }
  out
}

// ---------------------------------------------------------------------------
// Two-stage BH / BY (Storey 2002)
// ---------------------------------------------------------------------------

///|
/// v0.24.0+ two-stage Benjamini-Hochberg FDR
/// correction. First applies the standard BH
/// adjustment, then scales by `m0_hat / m` where
/// `m0_hat` is the estimated number of true nulls
/// (the Storey 2002 / BH-BKY 2006 estimator
/// `m0_hat = #{p > alpha} / (1 - alpha)`).
///
/// Algorithm (matches
/// `statsmodels.stats.multitest.multipletests` with
/// `method='fdr_tsbh'`):
///   1. Apply BH:
///      `p_bh_sorted[k] = min(1, p_sorted[k] * m / (k+1))`.
///   2. Estimate `m0_hat = #{unadjusted > alpha} / (1 -
///      alpha)` (clamped to `[1, m]`).
///   3. Apply correction:
///      `p_adj_sorted[k] = min(1, p_bh_sorted[k] * m0_hat /
///      m)`.
///   4. Enforce monotonicity from the largest rank
///      downward.
///   5. Re-order to original cell order via `ro`.
///
/// The two-stage correction is more powerful than
/// the basic BH when a non-trivial fraction of
/// hypotheses are truly non-null (which is the
/// common case for DID with multiple (g, t) cells:
/// the post-treatment cells are non-null, the
/// pre-treatment cells are null). The corrected
/// p-values are smaller than the BH p-values (by a
/// factor of `m0_hat / m <= 1`).
///
/// Shared `m0_hat` estimator: Storey 2002 /
/// BH-BKY 2006 with `alpha = 0.05` hard-coded:
///   `m0_hat = #{unadjusted > alpha} / (1 - alpha)`
/// clamped to `[1, m]`.
fn storey_m0_hat(unadjusted : Array[Double]) -> Double {
  let n = unadjusted.length()
  let alpha = 0.05
  let mut n_above = 0
  for i = 0; i < n; i = i + 1 {
    if unadjusted[i] > alpha {
      n_above = n_above + 1
    }
  }
  let mut m0_hat = n_above.to_double() / (1.0 - alpha)
  if m0_hat < 1.0 {
    m0_hat = 1.0
  }
  if m0_hat > n.to_double() {
    m0_hat = n.to_double()
  }
  m0_hat
}

///|
pub fn tsbh_p_adjust(unadjusted : Array[Double]) -> Array[Double] {
  let n = unadjusted.length()
  // Estimate `m0_hat` using the Storey 2002 /
  // BH-BKY 2006 estimator with `alpha = 0.05`.
  let m0_hat = storey_m0_hat(unadjusted)
  // Standard sort + BH correction.
  let order = argsort_asc(unadjusted)
  let ro : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    ro[order[i]] = i
  }
  let p_sorted : Array[Double] = Array::make(n, 1.0)
  let n_d = n.to_double()
  for i = 0; i < n; i = i + 1 {
    let raw = unadjusted[order[i]] * n_d / (i + 1).to_double()
    p_sorted[i] = if raw > 1.0 { 1.0 } else { raw }
  }
  // Two-stage correction: scale by `m0_hat / m`.
  let scale = m0_hat / n_d
  for i = 0; i < n; i = i + 1 {
    let raw = p_sorted[i] * scale
    p_sorted[i] = if raw > 1.0 { 1.0 } else { raw }
  }
  // Enforce monotonicity from the largest rank downward.
  let mut k = n - 2
  while k >= 0 {
    if p_sorted[k] > p_sorted[k + 1] {
      p_sorted[k] = p_sorted[k + 1]
    }
    k = k - 1
  }
  let out : Array[Double] = Array::make(n, 1.0)
  for i = 0; i < n; i = i + 1 {
    out[i] = p_sorted[ro[i]]
  }
  out
}

///|
/// v0.24.0+ two-stage Benjamini-Yekutieli FDR
/// correction. Combines the two-stage `m0_hat`
/// adjustment (from `tsbh_p_adjust`) with the
/// harmonic-sum `c` factor (from `by_fdr_p_adjust`)
/// to handle arbitrary dependence between tests.
///
/// Algorithm (matches
/// `statsmodels.stats.multitest.multipletests` with
/// `method='fdr_tsbky'`):
///   1. Compute `c = sum_{i=1}^{n} 1/i`.
///   2. Apply BY:
///      `p_by_sorted[k] = min(1, p_sorted[k] * m * c / (k+1))`.
///   3. Estimate `m0_hat = #{unadjusted > alpha} / (1 -
///      alpha)` (clamped to `[1, m]`).
///   4. Apply correction:
///      `p_adj_sorted[k] = min(1, p_by_sorted[k] * m0_hat /
///      m)`.
///   5. Enforce monotonicity + reorder.
pub fn tsby_p_adjust(unadjusted : Array[Double]) -> Array[Double] {
  let n = unadjusted.length()
  // Harmonic sum `c = sum_{i=1}^{n} 1/i`.
  let mut c = 0.0
  for i = 1; i <= n; i = i + 1 {
    c = c + 1.0 / i.to_double()
  }
  // Estimate `m0_hat`.
  let m0_hat = storey_m0_hat(unadjusted)
  // Standard sort + BY correction.
  let order = argsort_asc(unadjusted)
  let ro : Array[Int] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    ro[order[i]] = i
  }
  let p_sorted : Array[Double] = Array::make(n, 1.0)
  let n_d = n.to_double()
  for i = 0; i < n; i = i + 1 {
    let raw = unadjusted[order[i]] * n_d * c / (i + 1).to_double()
    p_sorted[i] = if raw > 1.0 { 1.0 } else { raw }
  }
  // Two-stage correction: scale by `m0_hat / m`.
  let scale = m0_hat / n_d
  for i = 0; i < n; i = i + 1 {
    let raw = p_sorted[i] * scale
    p_sorted[i] = if raw > 1.0 { 1.0 } else { raw }
  }
  // Enforce monotonicity.
  let mut k = n - 2
  while k >= 0 {
    if p_sorted[k] > p_sorted[k + 1] {
      p_sorted[k] = p_sorted[k + 1]
    }
    k = k - 1
  }
  let out : Array[Double] = Array::make(n, 1.0)
  for i = 0; i < n; i = i + 1 {
    out[i] = p_sorted[ro[i]]
  }
  out
}

// ---------------------------------------------------------------------------
// v0.54.0: unified dispatcher (matches upstream DoubleML p_adjust)
// ---------------------------------------------------------------------------

///|
/// Public dispatcher. `method` accepts:
///   - "romano-wolf" / "rw"             -> romano_wolf_p_adjust
///   - "holm"                          -> holm_bonferroni_p_adjust
///   - "bonferroni" / "bonf"           -> bonferroni_p_adjust
///   - "bh" / "fdr_bh"                  -> bh_fdr_p_adjust
///   - "by" / "fdr_by"                  -> by_fdr_p_adjust
///   - "tsbh" / "fdr_tsbh"              -> tsbh_p_adjust
///   - "tsby" / "fdr_tsbky"             -> tsby_p_adjust
///
/// For `romano-wolf`, the caller must supply `boot_t_stat`
/// (length `n_boot * n_thetas`) and `t_stats` (length
/// `n_thetas`); the `unadjusted` argument is ignored.
/// For all other methods, `boot_t_stat` and `t_stats` are
/// ignored; only `unadjusted` (length `n_thetas`) matters.
pub fn p_adjust(
  method_name : String,
  unadjusted : Array[Double],
  boot_t_stat? : Array[Double] = [],
  t_stats? : Array[Double] = [],
) -> Array[Double] {
  match method_name {
    "romano-wolf" | "rw" =>
      romano_wolf_p_adjust(boot_t_stat, unadjusted, t_stats)
    "holm" => holm_bonferroni_p_adjust(unadjusted)
    "bonferroni" | "bonf" => bonferroni_p_adjust(unadjusted)
    "bh" | "fdr_bh" => bh_fdr_p_adjust(unadjusted)
    "by" | "fdr_by" => by_fdr_p_adjust(unadjusted)
    "tsbh" | "fdr_tsbh" => tsbh_p_adjust(unadjusted)
    "tsby" | "fdr_tsbky" => tsby_p_adjust(unadjusted)
    _ =>
      abort(
        "p_adjust: unknown method '" +
        method_name +
        "' (use romano-wolf|holm|bonferroni|bh|by|tsbh|tsby)",
      )
  }
}
