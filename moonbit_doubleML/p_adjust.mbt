///|
// Public p-adjustment utility.
//
// Extracted from `did_multi.mbt` in v0.54.0 so that the 7
// algorithms are reusable across all estimators (not just
// DIDMulti).
//
// UPSTREAM PARITY -- MEASURED, NOT ASSUMED
// ========================================
// `validate_padjust_with_python.py` runs the real
// `statsmodels.stats.multitest.multipletests` against this
// module on TWO fixed p-vectors and reports, per method,
// `max |moonbit - statsmodels|`:
//
//                   vector a   vector b
//   holm               0          0
//   bonferroni         0          0
//   bh                 0       1.11e-16
//   by              1.11e-16   1.11e-16
//   tsbh               0          0
//
//   a = [0.001, 0.008, 0.02, 0.04, 0.2, 0.5, 0.9]
//   b = [0.07, 0.11, 0.19, 0.23, 0.41, 0.53, 0.71]
//
// 108 comparison rows in all.
//
// `holm`, `bonferroni` and `tsbh` come out BIT-IDENTICAL on both
// vectors, so the validator gates them at exact equality, not at a
// tolerance. That is a demand the code can meet because these
// algorithms use only +, -, * and / on the p-values: no
// transcendentals, therefore no libm, therefore IEEE-754 arithmetic
// that is identical on every platform.
//
// WHY TWO VECTORS
// ---------------
// Vector `b` exists for a measured reason, not for coverage. The
// step-up factor can be applied as `p / ((k+1) / n)` (what
// statsmodels does, and what `bh_step_up_sorted` does) or as the
// algebraically equal `p * n / (k + 1)` (what `bh_fdr_p_adjust`
// still does). They differ only in rounding, by at most 1 ULP.
// Vector `a` does not expose that difference anywhere -- 0 of 7
// cells -- so on vector `a` alone an exact gate cannot tell the two
// forms apart. Vector `b` does: cell 5 differs by 1.11e-16. That is
// what makes the `bh` row above 1.11e-16 instead of 0, and it is why
// changing `bh_fdr_p_adjust` to the division form would move `bh` to
// 0 on both.
//
// TSBH WAS RECONCILED; TSBY WAS NOT
// ================================
// `tsbh` used to be the one real parity gap. It ran BH and then a
// global rescale by the Storey 2002 null count
// `m0_hat = #{p > 0.05} / (1 - 0.05) = 3 / 0.95`, while statsmodels'
// `fdr_tsbh` re-levels `alpha` from its own stage-1 rejection count.
// `statsmodels / port` was the CONSTANT 1.2666666666666667 on every
// cell of vector `a`, and this header used to advertise a
// byte-compatibility that did not hold.
//
// `tsbh_p_adjust` now runs statsmodels' lambda search; see its
// docstring. On vector `a` that gives `r1 = 3`, `n0 = 4`, and cell 0
// moves 0.0031578947368421056 -> 0.004.
//
// `tsby_p_adjust` still uses the old estimator and still diverges
// from `fdr_tsbky` -- but NOT by a constant factor: measured
// `max |port - statsmodels| = 0.1595` with the ratio running
// 0.5129 ... 1.1970. It was left alone because the fix was scoped to
// `tsbh`. `validate_padjust_with_python.py` has no `tsby` rows, so
// nothing in CI would catch a drift in it. See its docstring.
//
// Algorithms:
//   - romano_wolf_p_adjust     (stepdown bootstrap, NOT in statsmodels)
//   - holm_bonferroni_p_adjust ("holm")
//   - bonferroni_p_adjust      ("bonferroni")
//   - bh_fdr_p_adjust          ("fdr_bh" / "bh")
//   - by_fdr_p_adjust          ("fdr_by" / "by")
//   - tsbh_p_adjust            ("fdr_tsbh" / "tsbh")   -- see above
//   - tsby_p_adjust            ("fdr_tsbky" / "tsby") -- see above
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
fn argsort_asc(unadjusted : Array[Double]) -> Array[Int32] {
  let n = unadjusted.length()
  let order : Array[Int32] = Array::make(n, 0)
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
    let stepdown_ind : Array[Int32] = Array::make(n, 0)
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
    let ro : Array[Int32] = Array::make(n, 0)
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
  let ro : Array[Int32] = Array::make(n, 0)
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
  let ro : Array[Int32] = Array::make(n, 0)
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
  let ro : Array[Int32] = Array::make(n, 0)
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
// Two-stage BH (statsmodels `fdrcorrection_twostage`, method='bh', maxiter=1)
// ---------------------------------------------------------------------------

///|
/// One Benjamini-Hochberg step-up pass over ALREADY-SORTED ascending
/// p-values, reproducing `statsmodels.stats.multitest.fdrcorrection`
/// with `method='indep', is_sorted=True`.
///
/// Returns `(p_corrected_sorted, n_rejected)`.
///
/// Two details are load-bearing and were transcribed rather than
/// re-derived:
///   * the ECDF factor is applied as a DIVISION,
///     `p_sorted[k] / ((k + 1) / n)`, not as the algebraically
///     equal `p_sorted[k] * n / (k + 1)`. The two differ by up to
///     1 ULP and only the first reproduces statsmodels bit for bit.
///   * `n_rejected` is counted AFTER the step-up closure. BH
///     rejects a prefix, so once any rank rejects, every smaller
///     rank does too (statsmodels: `reject[:rejectmax] = True`).
///     Counting the raw `p <= ecdf * alpha` hits instead would
///     under-count and feed the lambda search a wrong `n0`.
///
/// `alpha` is a parameter because that is what makes the two-stage
/// search expressible as two calls to this one pass.
fn bh_step_up_sorted(
  p_sorted : Array[Double],
  alpha : Double,
) -> (Array[Double], Int32) {
  let n = p_sorted.length()
  let n_d = n.to_double()
  let corrected : Array[Double] = Array::make(n, 1.0)
  // Largest rank whose raw comparison rejects; -1 means none do.
  let mut rejectmax = -1
  for i = 0; i < n; i = i + 1 {
    let ecdf = (i + 1).to_double() / n_d
    if p_sorted[i] <= ecdf * alpha {
      rejectmax = i
    }
    let raw = p_sorted[i] / ecdf
    corrected[i] = if raw > 1.0 { 1.0 } else { raw }
  }
  let n_rejected = if rejectmax < 0 { 0 } else { rejectmax + 1 }
  // `np.minimum.accumulate(corr[::-1])[::-1]`: running minimum
  // taken from the largest rank downward (this is the BH
  // direction; Holm goes the other way).
  let mut k = n - 2
  while k >= 0 {
    if corrected[k] > corrected[k + 1] {
      corrected[k] = corrected[k + 1]
    }
    k = k - 1
  }
  (corrected, n_rejected)
}

///|
/// v0.24.0+ two-stage Benjamini-Hochberg FDR correction.
///
/// Reproduces `statsmodels.stats.multitest.multipletests` with
/// `method='fdr_tsbh'` at its default `maxiter=1` -- the
/// Benjamini-Hochberg two-stage method -- INCLUDING the
/// lambda search that re-levels `alpha` in terms of the
/// stage-1 rejections. Measured BIT-EXACT against
/// statsmodels (`max |diff| = 0.0`, not merely inside a
/// tolerance) on nine vectors covering both early-return
/// branches, tied p-values, unsorted input and `n = 1`;
/// `validate_padjust_with_python.py` gates it.
///
/// `alpha = 0.05` is fixed here only because this signature
/// carries no alpha parameter; the search itself is
/// statsmodels'.
///
/// Two vectors are gated: `a = [0.001, 0.008, 0.02, 0.04,
/// 0.2, 0.5, 0.9]` (spans three orders of magnitude, crosses
/// BH's threshold) and `b = [0.07, 0.11, 0.19, 0.23, 0.41,
/// 0.53, 0.71]`. Between them they cover both branches: on `a`
/// `r1 = 3` so the search runs, on `b` `r1 = 0` so statsmodels'
/// short-circuit returns stage 1 untouched.
///
/// Algorithm (`fdrcorrection_twostage`, `method='bh'`,
/// `maxiter=1`), over the sorted p-vector `p` of length `m`:
///   1. Stage 1: `r1 = ` number of BH rejections at `alpha`.
///   2. If `r1 == 0` or `r1 == m`, return the stage-1 corrected
///      p-values UNCHANGED. statsmodels short-circuits here: if
///      nothing or everything rejected there is no fraction to
///      estimate, so no lambda search runs.
///   3. Otherwise `n0 = m - r1` (the estimated number of true
///      nulls) and `alpha_star = alpha * m / n0`.
///   4. Stage 2: a BH pass at `alpha_star`. Its corrected
///      p-values are `p_adj`.
///   5. Rescale for the estimated null fraction:
///      `p_adj[k] = min(1, p_adj[k] * n0 / m)`.
///   6. Re-order to original cell order via `ro`.
///
/// Step 5 is the whole of the two-stage correction: it shrinks
/// the adjusted p-values by the estimated fraction of truly null
/// hypotheses, which is what makes the two-stage procedure more
/// powerful than plain BH when a non-trivial fraction of
/// hypotheses are non-null -- the common case for DID across
/// many (g, t) cells, where post-treatment cells are non-null
/// and pre-treatment ones are null.
///
/// Only `r1`, the STAGE-1 count, reaches the p-values.
/// statsmodels also derives a stage-2 count for its own `m0`
/// return value, but `multipletests` discards it, and at
/// `maxiter=1` it never influences the corrected values.
///
/// CONSEQUENCE, WORTH KNOWING BEFORE YOU "SIMPLIFY" THIS:
/// because the stage-2 rejection count is dropped, `alpha_star`
/// currently cannot change what this function returns -- the
/// corrected array a BH pass produces depends only on the sorted
/// p-values and `n`. Measured: mutating `alpha_star` to `alpha * m`
/// leaves all fourteen outputs (two vectors x seven cells)
/// bit-identical. The lambda search that matters is the one that
/// produced `n0`, not the one that re-levels `alpha`. The call is
/// kept because it mirrors statsmodels line for line and because
/// that equivalence stops holding the moment this module starts
/// returning a rejection array. Mutation M1 in
/// `_verify/_tsbh_mutation_1660.py` is recorded as a documented
/// equivalent for exactly this reason.
pub fn tsbh_p_adjust(unadjusted : Array[Double]) -> Array[Double] {
  let n = unadjusted.length()
  let alpha = 0.05
  let order = argsort_asc(unadjusted)
  let ro : Array[Int32] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    ro[order[i]] = i
  }
  let p_sorted : Array[Double] = Array::make(n, 1.0)
  for i = 0; i < n; i = i + 1 {
    p_sorted[i] = unadjusted[order[i]]
  }
  // Stage 1: plain BH at `alpha`.
  let (stage1, r1) = bh_step_up_sorted(p_sorted, alpha)
  let adjusted = if r1 == 0 || r1 == n {
    stage1
  } else {
    // The lambda search: re-level alpha by the estimated null
    // fraction, then rescale by that same fraction.
    let n_d = n.to_double()
    let n0 = 1.0 * n_d - r1.to_double()
    let alpha_star = alpha * n_d / n0
    // The stage-2 rejection count is deliberately dropped:
    // statsmodels returns it as `m0`, but `multipletests` keeps
    // only `[:2]`, so it cannot reach the corrected p-values.
    let stage2 = bh_step_up_sorted(p_sorted, alpha_star).0
    let scale = n0 * 1.0 / n_d
    for i = 0; i < n; i = i + 1 {
      let raw = stage2[i] * scale
      stage2[i] = if raw > 1.0 { 1.0 } else { raw }
    }
    stage2
  }
  let out : Array[Double] = Array::make(n, 1.0)
  for i = 0; i < n; i = i + 1 {
    out[i] = adjusted[ro[i]]
  }
  out
}

///|
/// Storey 2002 / BH-BKY 2006 null-count estimator,
/// `m0_hat = #{p > alpha} / (1 - alpha)` clamped to
/// `[1, n]`, with `alpha` fixed at 0.05.
///
/// SCOPE: this estimator is now used by `tsby_p_adjust`
/// ONLY. It was previously shared with `tsbh_p_adjust`,
/// and sharing it was the entire reason `tsbh` diverged
/// from statsmodels -- `tsbh_p_adjust` now runs
/// statsmodels' own lambda search instead (see its
/// docstring). `tsby_p_adjust` still diverges from
/// `multipletests(method='fdr_tsbky')` for the same
/// historical reason, and that gap is deliberately left
/// in place rather than changed unannounced.
///
/// Do NOT re-share this with `tsbh_p_adjust`: the two
/// estimators are not interchangeable, and
/// `validate_padjust_with_python.py` gates `tsbh`
/// against statsmodels but does not gate `tsby`.
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
/// v0.24.0+ two-stage Benjamini-Yekutieli FDR
/// correction. Combines the two-stage `m0_hat`
/// adjustment (from `storey_m0_hat`) with the
/// harmonic-sum `c` factor (from `by_fdr_p_adjust`)
/// to handle arbitrary dependence between tests.
///
/// Algorithm. Structurally
/// `statsmodels.stats.multitest.multipletests` with
/// `method='fdr_tsbky'`, but NOT numerically identical to
/// it: both run BY then a global `m0_hat / m` rescale,
/// but this module fixes `alpha = 0.05` where statsmodels
/// searches lambda.
///
/// MEASURED on `[0.001, 0.008, 0.02, 0.04, 0.2, 0.5, 0.9]`:
/// `max |port - statsmodels| = 0.1595`. Unlike the `tsbh`
/// gap this one was, it is NOT a constant factor -- the
/// ratio runs 0.5129 ... 1.1970, spread 0.684 -- so no
/// single multiplicative constant describes it. The
/// largest cells saturate: this function clips at 1.0
/// BEFORE the rescale while statsmodels applies
/// `fact = 1 + alpha` AFTER it, so the two clip at
/// different points and cells 5 and 6 come back identical
/// here (0.45112781954887221 twice).
///
/// KNOWN DIVERGENCE, LEFT IN PLACE DELIBERATELY:
/// `tsbh_p_adjust` was reconciled with statsmodels'
/// lambda search; this one was not, because the
/// reconciliation was scoped to `tsbh` and changing a
/// second published method's numbers unannounced would
/// be worse than leaving the gap documented. Note that
/// `validate_padjust_with_python.py` does NOT gate
/// `tsby` against statsmodels -- it has no `tsby` rows
/// -- so nothing there would catch a silent drift.
/// Reconciling it means porting the BKY two-stage
/// search (`fact = 1 + alpha`, `alpha_prime = alpha /
/// fact`, `pvalscorr *= (1 + alpha)` after the rescale)
/// and adding `tsby` to that validator.
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
  let ro : Array[Int32] = Array::make(n, 0)
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
  boot_t_stat~ : Array[Double] = [],
  t_stats~ : Array[Double] = [],
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
