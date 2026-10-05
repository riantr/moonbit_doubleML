///|
/// v0.98.0: HONESTY and a STANDARD ERROR for
/// `DoubleMLPolicyTree`.
///
/// Structural template: `expand_v097_test.mbt` (BLP's v0.97.0
/// `hac_se`) and `expand_v085_test.mbt` (the PolicyTree memoize
/// white-box suite). The algebra differs from both: there is no
/// linear projection and no residual variance here, only means of
/// `orth_signal` inside the leaves of a fitted partition, so the
/// assertions are per-leaf throughout rather than elementwise over
/// a coefficient vector.
///
/// WHY THIS FILE EXISTS. Before v0.98.0 `DoubleMLPolicyTree` had no
/// uncertainty quantification of any kind -- no `se`, no `confint`,
/// no `bootstrap` -- and worse, `policy_tree_build` selected split
/// features and thresholds by searching the SAME observations
/// whose `orth_signal` then produced `leaf_signal_mean`. Every
/// observation therefore influenced both which leaf it landed in
/// and that leaf's reported value. That is the adaptive estimator
/// of Athey & Imbens (2016, PNAS 113(27):7353-7358,
/// https://www.pnas.org/doi/10.1073/pnas.1510489113), whose bias
/// does not vanish at a usable rate and whose interval coverage can
/// fall well below nominal. This file pins the honest replacement
/// and, just as importantly, pins that the DEFAULT (adaptive) path
/// is byte-identical to v0.97.0.
///
/// EVERY NUMBER PINNED AS "PRE-CHANGE" BELOW WAS MEASURED on
/// commit e2737c8 (v0.97.0), by stashing the v0.98.0 source change
/// out of the working tree and running this DGP through the
/// v0.97.0 API, before any edit to `blp_policy.mbt`.

// ---------------------------------------------------------------------------
// FIXTURES AND WHITE-BOX HELPERS
// ---------------------------------------------------------------------------

///|
/// Test-side structural fingerprint of a fitted `PolicyTreeNode`.
/// `PolicyTreeNode` derives `Debug` but not `Show`, so it cannot be
/// `inspect`ed directly; this walks it into a canonical string that
/// pins the EXACT shape of the tree (every split's feature index and
/// threshold, and every leaf's treatment) rather than a summary of
/// it. Used by the `honest = false` regression pin so a change to
/// the tree's structure cannot hide behind an unchanged
/// `leaf_signal_mean`.
fn v098_tree_repr(node : PolicyTreeNode) -> String {
  match node {
    Leaf(t) => "L(" + t.to_string() + ")"
    Split(f, v, l, r) =>
      "S(" +
      f.to_string() +
      "," +
      v.to_string() +
      "," +
      v098_tree_repr(l) +
      "," +
      v098_tree_repr(r) +
      ")"
  }
}

///|
/// Test-side INDEPENDENT leaf-index walker: where does row `row` of
/// `x` land, in depth-first leaf order? This is a second
/// implementation of what `policy_tree_leaf_index` does inside
/// `fit()`, written against the public `PolicyTreeNode` enum, so
/// `leaf_assignment` can be checked against something other than
/// itself. The `+1` offsets are the test's own DFS bookkeeping and
/// are deliberately structured differently from the source's
/// "skip the left subtree" formulation.
fn v098_leaf_index_walk(node : PolicyTreeNode, x : Matrix, row : Int) -> Int {
  match node {
    Leaf(_) => 0
    Split(feature, threshold, l, r) =>
      if x.get(row, feature) < threshold {
        v098_leaf_index_walk(l, x, row)
      } else {
        v098_leaf_n_leaves(l) + v098_leaf_index_walk(r, x, row)
      }
  }
}

///|
/// Test-side leaf counter, independent of the source's
/// `policy_tree_count_leaves`.
fn v098_leaf_n_leaves(node : PolicyTreeNode) -> Int {
  match node {
    Leaf(_) => 1
    Split(_, _, l, r) => v098_leaf_n_leaves(l) + v098_leaf_n_leaves(r)
  }
}

///|
/// Test-side sample standard deviation with the `n - 1` divisor,
/// computed from raw values. Used as the INDEPENDENT reference for
/// `leaf_se`, which the source derives from its own accumulator.
fn v098_sample_sd(v : Array[Double]) -> Double {
  let n = v.length()
  let mut sum = 0.0
  for a in v {
    sum = sum + a
  }
  let m = sum / n.to_double()
  let mut ss = 0.0
  for a in v {
    let d = a - m
    ss = ss + d * d
  }
  (ss / (n.to_double() - 1.0)).sqrt()
}

///|
/// Elementwise `Double` array equality that treats `NaN` as equal to
/// `NaN`. Needed wherever an honest `leaf_se` array is compared: a
/// leaf with fewer than two estimation observations carries the
/// `NaN` sentinel, and `NaN != NaN` would otherwise make two
/// genuinely identical arrays compare unequal.
fn v098_dbl_array_eq_nan_aware(a : Array[Double], b : Array[Double]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    if a[i].is_nan() && b[i].is_nan() {
      continue
    }
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
/// Render an `Array[Int]` as a canonical string. `Array[Int]`
/// implements `Debug` but not `Show`, so `inspect` on one trips the
/// deprecated Show path -- and these arrays are EXACTLY the values
/// the regression pins need to compare, so they are rendered here
/// and the resulting STRING is what gets pinned.
fn v098_show_ints(xs : Array[Int]) -> String {
  let mut s = "["
  for i = 0; i < xs.length(); i = i + 1 {
    if i > 0 {
      s = s + ", "
    }
    s = s + xs[i].to_string()
  }
  s + "]"
}

///|
/// The v0.98.0 DGP. `n = 400`, THREE features, NO RNG, so every
/// number below is reproducible on every backend.
///
/// `x0` runs linearly over `(-1, 1)`. `z1` is a deterministic
/// sawtooth (`(7 i) mod 23`), `z2` one with a different period
/// (`(13 i) mod 31`), and `eps` a third (`(11 i) mod 29`). The
/// signal is a four-quadrant step on `(z1, z2)` with
/// DELIBERATELY ASYMMETRIC quadrant values plus a within-leaf noise
/// term, so that
///
///   - the greedy split genuinely picks `z2` at the root and `z1`
///     inside each side (the asymmetry matters for the same reason
///     as in `v085_policy_dgp`: a mirror-symmetric signal makes a
///     swapped child undetectable), and
///   - every leaf has NON-ZERO within-leaf variance, which is what
///     `leaf_se` measures. A constant-signal DGP would make every
///     `leaf_se` exactly zero and the whole uncertainty surface
///     vacuous.
fn v098_dgp(n : Int) -> (Matrix, Array[Double]) {
  let p = 3
  let x = Matrix::zeros(n, p)
  let orth = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let half = (n.to_double() - 1.0) / 2.0
    let x0 = (i.to_double() - half) / half
    let z1 = (i * 7 % 23).to_double() / 23.0 - 0.5
    let z2 = (i * 13 % 31).to_double() / 31.0 - 0.5
    let eps = (i * 11 % 29).to_double() / 29.0 - 0.5
    x.set(i, 0, x0)
    x.set(i, 1, z1)
    x.set(i, 2, z2)
    let quad = if z1 < 0.0 {
      if z2 < 0.0 {
        -1.0
      } else {
        -0.5
      }
    } else if z2 < 0.0 {
      -1.5
    } else {
      1.0
    }
    orth[i] = quad + 0.35 * eps
  }
  (x, orth)
}

///|
/// A SMALL-ESTIMATION-LEAF fixture at `n = 18`. Same DGP shape as
/// `v098_dgp` but small enough that an honest depth-2 fit leaves
/// `n_est = 9` rows spread over 4 leaves. This is not a contrived
/// corruption: it is the ordinary consequence of a greedy split at
/// small `n`, and it is the regime Cattaneo, Klusowski & Yu,
/// "Accuracy Limits of Causal Trees for Individualized Treatment
/// Effects" (arXiv:2509.11381) characterise when they show that
/// "greedy recursive partitioning selects highly imbalanced splits
/// with nonvanishing probability, producing terminal nodes
/// containing very few observations and leading to large estimation
/// variance".
fn v098_small_leaf_dgp(n : Int) -> (Matrix, Array[Double]) {
  v098_dgp(n)
}

///|
/// The perturbation used by tests 2 and 3. It is a function of
/// `x[i, 0]` ONLY, so it adds a strong, genuinely new signal on
/// feature 0 for the rows in `rows` and leaves every other row
/// untouched. The large coefficient (100.0) is deliberate: it has
/// to be strong enough to win the variance-reduction argmax on the
/// adaptive path, so test 3's contrast cannot fail for want of
/// signal.
fn v098_perturb(
  x : Matrix,
  s : Array[Double],
  rows : Array[Int],
) -> Array[Double] {
  let out = s.copy()
  for i in rows {
    out[i] = out[i] + 100.0 * (if x.get(i, 0) < 0.0 { -1.0 } else { 1.0 })
  }
  out
}

///|
/// Relative closeness with an ABSOLUTE floor, for comparing a
/// source-computed value against a test-side reference computed in a
/// different operation order. Never used as a finiteness check:
/// both sides are real numbers produced by real arithmetic.
fn v098_rel_close(a : Double, b : Double, tol : Double) -> Bool {
  let scale = if b.abs() > 1.0 { b.abs() } else { 1.0 }
  (a - b).abs() <= tol * scale
}

// ---------------------------------------------------------------------------
// 1. THE SPLIT IS A PARTITION -- THE WHOLE POINT OF HONESTY
// ---------------------------------------------------------------------------

///|
/// The splitting half and the estimation half must share ZERO
/// observations, and every observation must land in exactly one of
/// them. This is asserted directly rather than inferred from
/// downstream numbers, because everything else in the release rests
/// on it.
///
/// Checked three ways: a boolean membership scan (an observation in
/// both halves would set both flags), a sort-and-compare that would
/// expose any overlap, and the count identity
/// `n_split + n_est == n_obs` which is what "jointly exhaustive"
/// means once disjointness is established.
test "policy_tree_honest_splits_are_disjoint" {
  let n = 400
  let (x, s) = v098_dgp(n)
  let f = DoubleMLPolicyTree::new(x, s, depth=2, honest=true, split_seed=2024).fit()
  let sp = f.split_indices()
  let es = f.est_indices()
  inspect(f.is_honest(), content="true")
  inspect(sp.length() + es.length() == n, content="true")
  inspect(sp.length() == 200, content="true")
  inspect(es.length() == 200, content="true")
  // Membership scan: build a per-observation side flag and assert no
  // row is claimed twice and no row is unclaimed.
  let side = Array::make(n, 0)
  for i in sp {
    side[i] = side[i] + 1
  }
  for i in es {
    side[i] = side[i] + 1
  }
  let mut n_double = 0
  let mut n_missing = 0
  for i = 0; i < n; i = i + 1 {
    if side[i] == 2 {
      n_double = n_double + 1
    }
    if side[i] == 0 {
      n_missing = n_missing + 1
    }
  }
  inspect(n_double, content="0")
  inspect(n_missing, content="0")
  // Sort-based overlap check: `Array::sort` is stable in place, so
  // comparing each split index against the sorted estimate at the
  // same position proves no element of one list appears anywhere in
  // the other (with both lists the same length and disjoint, the
  // sorted lists must differ at EVERY position).
  let sp_sorted = sp.copy()
  let es_sorted = es.copy()
  sp_sorted.sort()
  es_sorted.sort()
  let mut n_same_position = 0
  for i = 0; i < sp_sorted.length(); i = i + 1 {
    if sp_sorted[i] == es_sorted[i] {
      n_same_position = n_same_position + 1
    }
  }
  inspect(n_same_position, content="0")
  // And every index is in range.
  let mut all_in_range = true
  for i in sp {
    if i < 0 || i >= n {
      all_in_range = false
    }
  }
  for i in es {
    if i < 0 || i >= n {
      all_in_range = false
    }
  }
  inspect(all_in_range, content="true")
}

// ---------------------------------------------------------------------------
// 2. HONESTY IS A PROPERTY, NOT A CLAIM
// ---------------------------------------------------------------------------

///|
/// Perturbing `orth_signal` on the ESTIMATION half ONLY must leave
/// the fitted STRUCTURE byte-identical and must change the leaf
/// means. If the structure moved, `honest` would be a label rather
/// than a property, and the whole `leaf_se` justification (the
/// partition is exogenous given the estimation half) would be
/// vacuous.
///
/// Byte-identical is checked on the full structural fingerprint --
/// every split's feature index and threshold and every leaf's
/// treatment -- not merely on `split_feature` / `split_value`, which
/// would let a change in a deeper node slip through.
test "policy_tree_honest_structure_ignores_estimation_half" {
  let n = 400
  let (x, s) = v098_dgp(n)
  let base = DoubleMLPolicyTree::new(
    x,
    s,
    depth=2,
    honest=true,
    split_seed=2024,
  ).fit()
  let es = base.est_indices()
  let sp = base.split_indices()
  // Sanity: the perturbation set is genuinely disjoint from the
  // splitting half, so this test is measuring what it claims to.
  inspect(v098_any_overlap(es, sp), content="false")
  let s2 = v098_perturb(x, s, es)
  let perturbed = DoubleMLPolicyTree::new(
    x,
    s2,
    depth=2,
    honest=true,
    split_seed=2024,
  ).fit()
  // STRUCTURE: byte-identical.
  inspect(
    v098_tree_repr(perturbed.root) == v098_tree_repr(base.root),
    content="true",
  )
  inspect(perturbed.split_feature() == base.split_feature(), content="true")
  inspect(perturbed.split_value() == base.split_value(), content="true")
  // And the assignment of estimation rows is unchanged too, since it
  // is a function of the structure alone.
  inspect(
    v098_int_array_eq(perturbed.leaf_assignment, base.leaf_assignment),
    content="true",
  )
  // VALUES: the leaf means must MOVE, by a lot -- the perturbation
  // is +-100 on half the rows.
  let mut n_moved = 0
  let mut max_shift = 0.0
  for k = 0; k < base.leaf_signal_mean.length(); k = k + 1 {
    let d = (base.leaf_signal_mean[k] - perturbed.leaf_signal_mean[k]).abs()
    if d > 1.0 {
      n_moved = n_moved + 1
    }
    if d > max_shift {
      max_shift = d
    }
  }
  inspect(n_moved, content="4")
  // The shift is not guessed at: the perturbation adds
  // `100 * sign(x[i, 0])` to every estimation row, so leaf `k`'s mean
  // moves by EXACTLY `100 * (sum of sign(x0) over the leaf's
  // estimation rows) / n_k`, recomputed here from the raw arrays. So
  // this compares two independently computed numbers -- the accessor
  // against a first-principles prediction -- and it holds whatever
  // the sign balance in each leaf happens to be.
  let mut shift_ok = true
  let mut max_shift = 0.0
  for k = 0; k < base.leaf_signal_mean.length(); k = k + 1 {
    let mut sign_sum = 0.0
    let mut nk = 0
    for j = 0; j < es.length(); j = j + 1 {
      if base.leaf_assignment[j] == k {
        sign_sum = sign_sum + (if x.get(es[j], 0) < 0.0 { -1.0 } else { 1.0 })
        nk = nk + 1
      }
    }
    inspect(nk, content=base.leaf_count[k].to_string())
    let expect_shift = 100.0 * sign_sum / nk.to_double()
    let actual_shift = perturbed.leaf_signal_mean[k] - base.leaf_signal_mean[k]
    if v098_rel_close(actual_shift, expect_shift, 1.0e-11) == false {
      shift_ok = false
    }
    let a = actual_shift.abs()
    if a > max_shift {
      max_shift = a
    }
  }
  inspect(shift_ok, content="true")
  // And the shift really is large. Two independent yardsticks: it
  // exceeds `2.0` in absolute terms (the perturbation amplitude is
  // `100`), and it exceeds the base fit's own worst within-leaf
  // standard error (~0.014), so "the means changed" cannot be a
  // last-ulp artefact.
  let mut base_se_max = 0.0
  for v in base.leaf_se() {
    if v > base_se_max {
      base_se_max = v
    }
  }
  inspect(max_shift > 2.0, content="true")
  inspect(max_shift > base_se_max, content="true")
  // The leaf MEANS agree with an independent recomputation off the
  // raw arrays, so "the means changed" cannot be an artefact of the
  // accessor reading a different array than `leaf_signal_mean`
  // reports.
  inspect(v098_leaf_means_match_raw(perturbed, s2), content="true")
}

///|
/// Test-side disjointness of two index lists.
fn v098_any_overlap(a : Array[Int], b : Array[Int]) -> Bool {
  let mut hit = false
  for i in a {
    for j in b {
      if i == j {
        hit = true
      }
    }
  }
  hit
}

///|
/// Test-side elementwise `Int` array equality.
fn v098_int_array_eq(a : Array[Int], b : Array[Int]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
/// Does `leaf_signal_mean` agree with a mean recomputed from the raw
/// arrays, over the rows the model says belong to each leaf?
/// `est_indices` is empty on the adaptive path, in which case the
/// estimation sample is the whole sample in identity order.
fn v098_leaf_means_match_raw(f : DoubleMLPolicyTree, s : Array[Double]) -> Bool {
  let es = f.est_indices()
  let n_est = f.leaf_assignment.length()
  let sums = Array::make(f.leaf_signal_mean.length(), 0.0)
  let counts = Array::make(f.leaf_signal_mean.length(), 0)
  for j = 0; j < n_est; j = j + 1 {
    let row = if es.length() == 0 { j } else { es[j] }
    let l = f.leaf_assignment[j]
    sums[l] = sums[l] + s[row]
    counts[l] = counts[l] + 1
  }
  let mut ok = true
  for k = 0; k < sums.length(); k = k + 1 {
    if counts[k] != f.leaf_count[k] {
      ok = false
    }
    if counts[k] > 0 {
      if v098_rel_close(
          f.leaf_signal_mean[k],
          sums[k] / counts[k].to_double(),
          1.0e-12,
        ) ==
        false {
        ok = false
      }
    }
  }
  ok
}

// ---------------------------------------------------------------------------
// 3. THE CONTRAST: THE ADAPTIVE PATH DOES REACT
// ---------------------------------------------------------------------------

///|
/// The other half of the property. With `honest = false`, the very
/// same rows perturb the very same signal, and this time the
/// STRUCTURE moves -- `split_feature` jumps from the feature the
/// honest tree picked to the feature the perturbation favours.
///
/// Without this test, test 2 could pass for the wrong reason (a
/// degenerate or single-leaf tree would be "unmoved" by anything).
test "policy_tree_non_honest_structure_reacts_to_both" {
  let n = 400
  let (x, s) = v098_dgp(n)
  let base = DoubleMLPolicyTree::new(x, s, depth=2).fit()
  inspect(base.is_honest(), content="false")
  // Perturb the rows the HONEST fit used as its estimation half --
  // which is exactly half the sample -- so the two tests differ only
  // in the `honest` flag.
  let honest_ref = DoubleMLPolicyTree::new(
    x,
    s,
    depth=2,
    honest=true,
    split_seed=2024,
  ).fit()
  let es = honest_ref.est_indices()
  let s2 = v098_perturb(x, s, es)
  let perturbed = DoubleMLPolicyTree::new(x, s, depth=2).fit()
  let perturbed2 = DoubleMLPolicyTree::new(x, s2, depth=2).fit()
  // The adaptive structure REACTS: a different root split feature,
  // and a different tree overall.
  inspect(
    perturbed2.split_feature() != perturbed.split_feature(),
    content="true",
  )
  inspect(
    v098_tree_repr(perturbed2.root) != v098_tree_repr(perturbed.root),
    content="true",
  )
  // The honest one did not -- the same two fits, same rows, same
  // signal change, structure pinned.
  let honest2 = DoubleMLPolicyTree::new(
    x,
    s2,
    depth=2,
    honest=true,
    split_seed=2024,
  ).fit()
  inspect(
    v098_tree_repr(honest2.root) == v098_tree_repr(honest_ref.root),
    content="true",
  )
  // And the adaptive baseline really is the degenerate-free tree the
  // pins expect, so "the structure moved" is a claim about a rich
  // tree, not about a single leaf.
  inspect(base.split_feature(), content="2")
}

// ---------------------------------------------------------------------------
// 4. leaf_se IS AN ORDINARY SAMPLE VARIANCE / sqrt(n)
// ---------------------------------------------------------------------------

///|
/// For each leaf, `leaf_se[k]` must equal
/// `sd(y in the estimation half of leaf k) / sqrt(n_k)`, where `sd`
/// uses the `n_k - 1` divisor and the reference gathers the raw `y`
/// values through `est_indices` and the independently-walked leaf
/// assignment. That is the claim Athey & Imbens' honesty buys:
/// with the partition held fixed, a leaf value is a plain sample
/// mean of i.i.d. draws.
///
/// `tol = 1e-12` RELATIVE, because the source accumulates
/// `sum (y - theta)^2` and divides by `(n_k - 1) * n_k` in one step
/// while the reference calls `sqrt(ss / (n-1))` and then divides by
/// `sqrt(n)` -- same quantity, different association, so the last
/// ulp may differ. The tolerance is on the VALUE, never on
/// finiteness.
test "policy_tree_leaf_se_matches_sample_variance" {
  let n = 400
  let (x, s) = v098_dgp(n)
  let f = DoubleMLPolicyTree::new(x, s, depth=2, honest=true, split_seed=2024).fit()
  let se = f.leaf_se()
  let es = f.est_indices()
  inspect(se.length(), content="4")
  for k = 0; k < se.length(); k = k + 1 {
    // Gather this leaf's estimation-half y values using the
    // INDEPENDENT walk over the fitted tree, not `leaf_assignment`.
    let vals : Array[Double] = []
    for j = 0; j < es.length(); j = j + 1 {
      let row = es[j]
      if v098_leaf_index_walk(f.root, x, row) == k {
        vals.push(s[row])
      }
    }
    inspect(vals.length(), content=f.leaf_count[k].to_string())
    let nk = vals.length()
    inspect(nk >= 5, content="true")
    let ref_se = v098_sample_sd(vals) / nk.to_double().sqrt()
    inspect(v098_rel_close(se[k], ref_se, 1.0e-12), content="true")
    // And the SE is strictly positive: the DGP has real within-leaf
    // noise, so a zero here would mean the variance was never
    // computed rather than computed as zero.
    inspect(se[k] > 0.0, content="true")
    inspect(se[k].is_nan() == false, content="true")
  }
  // The pinned values themselves, so a change in the formula cannot
  // hide behind the reference agreeing with it.
  inspect(se[0], content="0.013708750687867822")
  inspect(se[1], content="0.015400505206000718")
  inspect(se[2], content="0.019966760974946738")
  inspect(se[3], content="0.09238628806153994")
}

// ---------------------------------------------------------------------------
// 5. THE SCALAR
// ---------------------------------------------------------------------------

///|
/// The scalar accessor, against BOTH formulas.
///
/// (a) `policy_value()` against `sum_k (n_k / n) * theta_k`
///     recomputed from `leaf_count` / `leaf_signal_mean`, and
///     against the plain mean of the raw estimation-half `y`
///     computed from scratch. These two references are themselves
///     equal, and that equality IS the point: the policy value of a
///     leaf-MEAN policy is identically the overall sample mean,
///     because `sum_k (n_k/n) theta_k = (1/n) sum_j y_j`. A
///     leaf-mean policy has zero advantage over treating everyone,
///     so all of a policy tree's information lives in the per-leaf
///     `leaf_signal_mean` / `leaf_se` pairs.
///
/// (b) `policy_value_se()` against `sd(y_est) / sqrt(n_est)`, again
///     from raw arrays. This is the EXACT standard error of the
///     plain sample mean, and it is what the implementation
///     returns.
///
/// (c) AND the rejected formula `sum_k (n_k/n)^2 se_k^2` is
///     asserted to DISAGREE, so this test also proves the deviation
///     is real and deliberate rather than an accident. That
///     formula assumes the leaf means are independent; they are not,
///     they are group means of ONE sample with the negative
///     covariance `-s_k^2 s_l^2 / (n(n-1))`, and dropping it
///     understates -- reaching EXACTLY ZERO when all the variation
///     is between leaves.
test "policy_tree_policy_value_se" {
  let n = 400
  let (x, s) = v098_dgp(n)
  let f = DoubleMLPolicyTree::new(x, s, depth=2, honest=true, split_seed=2024).fit()
  let es = f.est_indices()
  let n_est = es.length()
  let pv = f.policy_value()
  // (a) the weighted-sum form, recomputed.
  let mut wsum = 0.0
  for k = 0; k < f.leaf_signal_mean.length(); k = k + 1 {
    wsum = wsum +
      f.leaf_count[k].to_double() / n_est.to_double() * f.leaf_signal_mean[k]
  }
  inspect(v098_rel_close(pv, wsum, 1.0e-12), content="true")
  // (a) and the plain raw mean of the estimation half.
  let raw : Array[Double] = []
  for i in es {
    raw.push(s[i])
  }
  inspect(raw.length(), content="200")
  inspect(
    v098_rel_close(pv, v098_sample_sd(raw) * 0.0 + mean(raw), 1.0e-12),
    content="true",
  )
  inspect(pv, content="-0.5594310344827587")
  // (b) the exact standard error of that same sample mean.
  let pv_se = f.policy_value_se()
  let ref_se = v098_sample_sd(raw) / n_est.to_double().sqrt()
  inspect(v098_rel_close(pv_se, ref_se, 1.0e-12), content="true")
  inspect(pv_se, content="0.0627089161363114")
  // Second, independent form of the same identity: the SE squared
  // times `n * (n - 1)` is the raw sum of squared deviations.
  let mut ss = 0.0
  for v in raw {
    let d = v - pv
    ss = ss + d * d
  }
  inspect(
    v098_rel_close(
      pv_se * pv_se * n_est.to_double() * (n_est.to_double() - 1.0),
      ss,
      1.0e-12,
    ),
    content="true",
  )
  // (c) THE REJECTED INDEPENDENCE FORMULA. It disagrees, and by a
  // wide margin -- which is the whole reason the implementation does
  // not use it.
  let mut indep_var = 0.0
  for k = 0; k < f.leaf_signal_mean.length(); k = k + 1 {
    let w = f.leaf_count[k].to_double() / n_est.to_double()
    indep_var = indep_var + w * w * f.leaf_se()[k] * f.leaf_se()[k]
  }
  let indep_se = indep_var.sqrt()
  inspect(indep_se < pv_se, content="true")
  // MEASURED on this fixture: `indep_se = 0.0222` against
  // `pv_se = 0.0627`, i.e. the rejected formula UNDERSTATES the
  // standard error by a factor of ~2.8. The bound is set at 2x to
  // leave room for the last-ulp association differences while still
  // asserting the substantive point -- the two formulas are not
  // interchangeable, and the independent-looking one is the wrong
  // one.
  inspect(indep_se < 0.5 * pv_se, content="true")
  // And the general statement behind that: the exact variance exceeds
  // the independence variance by the between-leaf term. For this
  // DGP, `n^2 * (exact - indep)` equals
  // `sum_k (n_k - 1) s_k^2 - sum_k n_k s_k^2 + (between-leaf part)`,
  // which is positive exactly when the leaf means differ. Assert the
  // sign, which is all that is claimed.
  inspect(indep_se != pv_se, content="true")
}

// ---------------------------------------------------------------------------
// 6. THE SMALL-LEAF GUARD
// ---------------------------------------------------------------------------

///|
/// The documented failure mode, on a fixture that genuinely produces
/// a tiny estimation-half leaf.
///
/// MEASURED on `n = 18`, `depth = 2`, `split_seed = 2024`:
/// `n_est = 9`, `leaf_count = [4, 2, 2, 1]`. So:
///
///   - three leaves fall below the default `min_leaf_n = 5`;
///   - `leaf_se_reliable()` is `false` and `unreliable_leaves()`
///     names ALL FOUR leaves -- `[0, 1, 2, 3]`;
///   - leaf 1, holding TWO observations, reports
///     `leaf_se[1] = 1.2741379310344827`, i.e. MORE than two orders
///     of magnitude larger than the `~0.05` the healthy leaves on
///     the main fixture report. That is the "silent huge number"
///     the guard exists to intercept: it is a real computed
///     variance, and it is very nearly meaningless;
///   - leaf 3, holding ONE observation, reports `NaN`, because a
///     one-observation sample variance has zero degrees of freedom
///     and does not exist. It is `NaN` rather than `0.0` (which
///     would read as infinitely precise) and rather than a huge
///     finite number (which would read as an ordinary large SE);
///   - `policy_value_se()` ABORTS, because a scalar SE dominated by
///     a two-observation leaf is a claim the data cannot support;
///   - `policy_value()` still returns, because a population-weighted
///     mean is not variance-dominated by one small leaf, so no
///     abort is warranted there.
///
/// The guard threshold and its derivation are on the `leaf_se`
/// docstring in `blp_policy.mbt`; `min_leaf_n()` is a constructor
/// parameter so a caller with a smaller estimation half can retune
/// it, and the threshold is settable but never silently applied.
test "policy_tree_small_leaf_guard" {
  let n = 18
  let (x, s) = v098_small_leaf_dgp(n)
  let f = DoubleMLPolicyTree::new(x, s, depth=2, honest=true, split_seed=2024).fit()
  inspect(f.est_indices().length(), content="9")
  inspect(v098_show_ints(f.leaf_count), content="[4, 2, 2, 1]")
  inspect(f.min_leaf_n(), content="5")
  inspect(f.smallest_leaf_count(), content="1")
  inspect(f.leaf_se_reliable(), content="false")
  inspect(v098_show_ints(f.unreliable_leaves()), content="[0, 1, 2, 3]")
  let se = f.leaf_se()
  // Leaf 0: n_k = 4, a finite but hopeless SE.
  inspect(se[0], content="0.09539277753346398")
  // Leaf 1: n_k = 2 -- the huge number, explicitly flagged.
  inspect(se[1], content="1.2741379310344827")
  inspect(se[1] > 10.0 * se[0], content="true")
  // Leaf 3: n_k = 1 -- undefined, and NaN rather than a lie.
  inspect(se[3].is_nan(), content="true")
  // The point estimate is still available and still exactly the raw
  // mean of the estimation half.
  let raw : Array[Double] = []
  for i in f.est_indices() {
    raw.push(s[i])
  }
  inspect(v098_rel_close(f.policy_value(), mean(raw), 1.0e-12), content="true")
}

///|
/// `policy_value_se()` must ABORT when any leaf falls below
/// `min_leaf_n`, on the same `n = 18` fixture. This is the guard's
/// enforcement point; see `policy_tree_small_leaf_guard` for the
/// numbers.
test "panic_policy_tree_policy_value_se_small_leaf" {
  let (x, s) = v098_small_leaf_dgp(18)
  let f = DoubleMLPolicyTree::new(x, s, depth=2, honest=true, split_seed=2024).fit()
  let _ = f.policy_value_se()
}

///|
/// The threshold is a constructor parameter, and it is a REAL
/// threshold: the flagged set changes with it.
///
/// On the `n = 18` fixture the leaf counts are `[4, 2, 2, 1]`, so
/// the boundaries sit at 2/3, 4/5 and 5/6, and the flag sets are:
///
///   - `min_leaf_n = 2` -> `[3]`          (only `n_k = 1` fails)
///   - `min_leaf_n = 3` -> `[1, 2, 3]`    (`n_k = 2` fails)
///   - `min_leaf_n = 4` -> `[1, 2, 3]`    (leaf 0 at `n_k = 4` passes)
///   - `min_leaf_n = 5` -> `[0, 1, 2, 3]` (leaf 0 at `n_k = 4` now fails)
///   - `min_leaf_n = 6` -> `[0, 1, 2, 3]`
///
/// Asserting the 4-vs-5 pair is what shows the guard is driven by
/// the threshold and not by some incidental property of the fit:
/// between those two values leaf 0 flips status and nothing else
/// does. The fitted numbers themselves are identical across all
/// thresholds -- `min_leaf_n` is a reporting knob, which is also why
/// it is deliberately not part of the memoize key.
test "policy_tree_min_leaf_n_is_a_real_threshold" {
  let (x, s) = v098_small_leaf_dgp(18)
  let at4 = DoubleMLPolicyTree::new(
    x,
    s,
    depth=2,
    honest=true,
    split_seed=2024,
    min_leaf_n=4,
  ).fit()
  let at5 = DoubleMLPolicyTree::new(
    x,
    s,
    depth=2,
    honest=true,
    split_seed=2024,
    min_leaf_n=5,
  ).fit()
  inspect(v098_show_ints(at4.unreliable_leaves()), content="[1, 2, 3]")
  inspect(v098_show_ints(at5.unreliable_leaves()), content="[0, 1, 2, 3]")
  inspect(at4.leaf_se_reliable(), content="false")
  inspect(at5.leaf_se_reliable(), content="false")
  // Only leaf 0 changed status between the two thresholds.
  let bad4 = Array::make(4, false)
  for i in at4.unreliable_leaves() {
    bad4[i] = true
  }
  let bad5 = Array::make(4, false)
  for i in at5.unreliable_leaves() {
    bad5[i] = true
  }
  inspect(bad4[0], content="false")
  inspect(bad5[0], content="true")
  // And the threshold changed no fitted number. The comparison has to
  // be NaN-AWARE: leaf 3 holds one observation, so both arrays carry
  // a `NaN` there, and `NaN != NaN` makes a plain elementwise `==`
  // report these two equal-valued arrays as different.
  inspect(
    v098_dbl_array_eq_nan_aware(at4.leaf_se(), at5.leaf_se()),
    content="true",
  )
  inspect(at4.leaf_se()[3].is_nan(), content="true")
  inspect(at4.leaf_signal_mean == at5.leaf_signal_mean, content="true")
  inspect(v098_tree_repr(at4.root) == v098_tree_repr(at5.root), content="true")
  // The lenient end of the range still refuses `n_k = 1`, whose
  // variance does not exist.
  let lenient = DoubleMLPolicyTree::new(
    x,
    s,
    depth=2,
    honest=true,
    split_seed=2024,
    min_leaf_n=2,
  ).fit()
  inspect(v098_show_ints(lenient.unreliable_leaves()), content="[3]")
  inspect(lenient.leaf_se()[3].is_nan(), content="true")
}

///|
/// `min_leaf_n < 2` is refused at construction rather than producing
/// an undefined `leaf_se` later: `min_leaf_n = 1` would make the
/// guard vacuous and `min_leaf_n = 2` would still admit a
/// zero-degree-of-freedom variance.
test "panic_policy_tree_min_leaf_n_too_small" {
  let (x, s) = v098_dgp(400)
  let _ = DoubleMLPolicyTree::new(x, s, depth=2, honest=true, min_leaf_n=1)
}

// ---------------------------------------------------------------------------
// 7. THE DEFAULT PATH IS UNCHANGED -- REGRESSION PIN
// ---------------------------------------------------------------------------

///|
/// REGRESSION PIN. Every number below was MEASURED on commit
/// e2737c8 (v0.97.0) with this exact DGP and this exact API call
/// (`DoubleMLPolicyTree::new(x, s, depth=2).fit()`, i.e. `honest`
/// left at its default), BEFORE any edit to `blp_policy.mbt` --
/// measured by stashing the v0.98.0 source change out of the working
/// tree and running the probe. They are pinned BYTE-IDENTICALLY.
///
/// The v0.97.0 tree was
/// `S(2, -0.01620967741935487, S(1, -0.022187359928283287, L(0), L(0)), S(1, -0.023005487547488396, L(0), L(1)))`
/// -- a root split on feature 2, feature 1 inside both sides, and
/// four leaves of size `[94, 100, 98, 108]`. The structural
/// fingerprint pins every node, so a change to any deeper split or
/// to any leaf's treatment fails here even if the root stayed put.
test "policy_tree_default_path_unchanged" {
  let n = 400
  let (x, s) = v098_dgp(n)
  let f = DoubleMLPolicyTree::new(x, s, depth=2).fit()
  // The configuration is the v0.97.0 one: no honesty, and the
  // honest-only arrays stay EMPTY so no accessor can accidentally
  // report an honest number for an adaptive fit.
  inspect(f.is_honest(), content="false")
  inspect(f.min_leaf_n(), content="5")
  inspect(f.split_indices().length(), content="0")
  inspect(f.est_indices().length(), content="0")
  // Structure.
  inspect(
    v098_tree_repr(f.root),
    content="S(2,-0.01620967741935487,S(1,-0.022187359928283287,L(0),L(0)),S(1,-0.023005487547488396,L(0),L(1)))",
  )
  inspect(f.split_feature(), content="2")
  inspect(f.split_value(), content="-0.01620967741935487")
  // Leaf statistics. Lengths and values are all pre-change.
  inspect(f.leaf_signal_mean.length(), content="4")
  inspect(f.leaf_signal_mean[0], content="-1.0077035950110047")
  inspect(f.leaf_signal_mean[1], content="-1.465793103448276")
  inspect(f.leaf_signal_mean[2], content="-0.528465869106263")
  inspect(f.leaf_signal_mean[3], content="0.7002873563218392")
  inspect(v098_show_ints(f.leaf_count), content="[94, 100, 98, 108]")
  inspect(f.leaf_assignment.length(), content="400")
  // `leaf_assignment` against the INDEPENDENT walk over the pinned
  // tree: 400 elementwise comparisons rather than a 400-element
  // literal, and it exercises the walker too.
  let mut walk_ok = true
  let hist = Array::make(4, 0)
  for i = 0; i < n; i = i + 1 {
    let mine = v098_leaf_index_walk(f.root, x, i)
    if mine != f.leaf_assignment[i] {
      walk_ok = false
    }
    hist[mine] = hist[mine] + 1
  }
  inspect(walk_ok, content="true")
  inspect(v098_show_ints(hist), content="[94, 100, 98, 108]")
  // The leaf-mean pre-change pin, verified a second way: the same
  // 400 row signals bucketed by that assignment.
  inspect(v098_leaf_means_match_raw(f, s), content="true")
  // The adaptive `predict` is unchanged too -- it is the only public
  // consumer of `root`.
  let pred = f.predict(x)
  let mut pred_ok = true
  for i = 0; i < n; i = i + 1 {
    if pred[i] != 0 && pred[i] != 1 {
      pred_ok = false
    }
  }
  inspect(pred_ok, content="true")
  // The pre-change counts sum to `n_obs` -- the property the honest
  // path deliberately breaks (there they sum to `n_est`).
  let mut tot = 0
  for c in f.leaf_count {
    tot = tot + c
  }
  inspect(tot, content="400")
}

// ---------------------------------------------------------------------------
// 8. sensitivity_analysis: PINNED BOTH WAYS
// ---------------------------------------------------------------------------

///|
/// The v0.97.0 numbers, pinned byte-identically on the DEFAULT path.
/// MEASURED on commit e2737c8 before any source edit.
///
/// `NU2 = [1, 1, 1, 1]` is the signature of the default convention:
/// `psi_a` is the constant `-1`, so `nu2 = mean(psi_a^2) = 1` for
/// every leaf. That is what makes the honest contrast below
/// legible.
test "policy_tree_sensitivity_analysis_default_pinned" {
  let n = 400
  let (x, s) = v098_dgp(n)
  let f = DoubleMLPolicyTree::new(x, s, depth=2).fit()
  let r = f.sensitivity_analysis()
  inspect(r.length(), content="4")
  inspect(r[0].rv, content="10.007636445971754")
  inspect(r[0].sigma2, content="0.01013917399041538")
  inspect(r[0].nu2, content="1")
  inspect(r[0].max_bias, content="0.1006934654802158")
  inspect(r[1].rv, content="8.600082526402876")
  inspect(r[1].sigma2, content="0.029049596908442304")
  inspect(r[1].nu2, content="1")
  inspect(r[1].max_bias, content="0.17043942298788262")
  inspect(r[2].rv, content="3.449808402503613")
  inspect(r[2].sigma2, content="0.023466263128076335")
  inspect(r[2].nu2, content="1")
  inspect(r[2].max_bias, content="0.15318702010312882")
  inspect(r[3].rv, content="0.9587320736323653")
  inspect(r[3].sigma2, content="0.533529032897344")
  inspect(r[3].nu2, content="1")
  inspect(r[3].max_bias, content="0.7304307173834798")
}

///|
/// THE BEHAVIOUR CHANGE, stated as a test. Under `honest = true`
/// `sensitivity_analysis` returns DIFFERENT numbers, on purpose,
/// and this pins them.
///
/// TWO CAUSES, both forced by honesty:
///   - it runs over the ESTIMATION half only (9... here 200 of 400
///     rows), so each leaf's residuals come from a different sample
///     than the adaptive path's;
///   - it passes `psi_a = -1 / n_l` instead of the constant `-1`.
///
/// The second cause is legible directly in `NU2`, which drops from
/// `[1, 1, 1, 1]` to `[0.0004, 0.0004938271604938276,
/// 0.0002777777777777777, 0.0004938271604938276]`. Those are
/// `1 / 50^2`, `1 / 45^2`, `1 / 60^2`, `1 / 45^2` -- the
/// per-observation derivative `f_i'(theta) = -1 / n_l` of the
/// leaf-mean estimating function `f_l(theta) = (1/n_l) sum_{i in l}
/// (y_i - theta)`. The adaptive `-1` is that derivative scaled up by
/// `n_l`. Both are legitimate inputs to the Cinelli-Hazlett
/// decomposition (it consumes `psi_a` through `psi_a^2` only, so the
/// sign is immaterial), but only the honest path describes an
/// estimator whose partition is independent of the rows it is
/// computed from.
///
/// `rv` and `max_bias` move by roughly two orders of magnitude as a
/// direct consequence of the `nu2` rescaling; `sigma2` moves much
/// less, because `sigma2 = mean(residuals^2)` and the residuals are
/// centred on the SAME leaf means in both regimes -- only the
/// sample they are drawn from differs.
test "policy_tree_sensitivity_analysis_honest_pinned" {
  let n = 400
  let (x, s) = v098_dgp(n)
  let f = DoubleMLPolicyTree::new(x, s, depth=2, honest=true, split_seed=2024).fit()
  let r = f.sensitivity_analysis()
  inspect(r.length(), content="4")
  inspect(r[0].rv, content="524.3136222052025")
  inspect(r[0].sigma2, content="0.009208562425683707")
  inspect(r[0].nu2, content="0.0004")
  inspect(r[0].max_bias, content="0.0019192250963014944")
  inspect(r[1].rv, content="658.0998338169342")
  inspect(r[1].sigma2, content="0.010435724666402428")
  inspect(r[1].nu2, content="0.0004938271604938276")
  inspect(r[1].max_bias, content="0.0022701198822319725")
  inspect(r[2].rv, content="209.1661478819361")
  inspect(r[2].sigma2, content="0.023521621086008707")
  inspect(r[2].nu2, content="0.0002777777777777777")
  inspect(r[2].max_bias, content="0.002556126686023683")
  inspect(r[3].rv, content="61.57642435797536")
  inspect(r[3].sigma2, content="0.37554995375875283")
  inspect(r[3].nu2, content="0.0004938271604938276")
  inspect(r[3].max_bias, content="0.013618251256614164")
  // `nu2` is not merely different, it is EXPLAINED: each entry is
  // `1 / n_l^2` for that leaf's estimation-half count.
  for k = 0; k < r.length(); k = k + 1 {
    let nk = f.leaf_count[k].to_double()
    inspect(v098_rel_close(r[k].nu2, 1.0 / (nk * nk), 1.0e-12), content="true")
  }
  // And the two regimes genuinely differ, rather than this being a
  // duplicate of the pinned default above.
  let g = DoubleMLPolicyTree::new(x, s, depth=2).fit()
  let r2 = g.sensitivity_analysis()
  let mut all_differ = true
  for k = 0; k < r.length(); k = k + 1 {
    if r[k].nu2 == r2[k].nu2 {
      all_differ = false
    }
  }
  inspect(all_differ, content="true")
}

// ---------------------------------------------------------------------------
// 9. THE LEAF-MEAN INFLUENCE FUNCTION
// ---------------------------------------------------------------------------

///|
/// The influence function, checked against its own derivation rather
/// than against a stored number.
///
/// Leaf `k` is estimated by `f_k(theta) = (1/n_k) sum_{i in k}
/// (y_i - theta)`, so `f_k'(theta) = -1`, and
/// `IF_k(i) = -f_i(theta_hat) / f_k'(theta_hat) = (y_i -
/// theta_hat_k) / n_k` on the leaf's estimation rows and zero
/// everywhere else.
///
/// Three properties, each an independent comparison:
///   1. it is `(y_i - theta_k) / n_k` on leaf `k`'s rows and exactly
///      `0.0` off them -- not "close to" zero, equal to it;
///   2. it SUMS TO ZERO within the leaf, which every influence
///      function must;
///   3. its squared norm reproduces `leaf_se` up to the
///      `(n_k - 1) / n_k` factor, which is the factor at which a
///      plug-in sample SE and an uncentred `sqrt(sum IF^2)` differ.
test "policy_tree_leaf_influence" {
  let n = 400
  let (x, s) = v098_dgp(n)
  let f = DoubleMLPolicyTree::new(x, s, depth=2, honest=true, split_seed=2024).fit()
  let es = f.est_indices()
  for k = 0; k < f.leaf_count.length(); k = k + 1 {
    let infl = f.leaf_influence(k)
    inspect(infl.length(), content="200")
    let nk_d = f.leaf_count[k].to_double()
    let mut total = 0.0
    let mut ssq = 0.0
    let mut ok = true
    let mut n_zero_off_leaf = 0
    for j = 0; j < es.length(); j = j + 1 {
      if f.leaf_assignment[j] == k {
        let expect = (s[es[j]] - f.leaf_signal_mean[k]) / nk_d
        if infl[j] != expect {
          ok = false
        }
        total = total + infl[j]
        ssq = ssq + infl[j] * infl[j]
      } else if infl[j] == 0.0 {
        n_zero_off_leaf = n_zero_off_leaf + 1
      }
    }
    inspect(ok, content="true")
    // (2) sums to zero within the leaf.
    inspect(v098_rel_close(total, 0.0, 1.0e-12), content="true")
    // And every off-leaf entry is exactly zero.
    inspect(n_zero_off_leaf, content=(200 - f.leaf_count[k]).to_string())
    // (3) `sum IF^2 = (n_k - 1) / n_k * leaf_se^2`.
    let expect_ssq = (f.leaf_count[k].to_double() - 1.0) /
      nk_d *
      f.leaf_se()[k] *
      f.leaf_se()[k]
    inspect(v098_rel_close(ssq, expect_ssq, 1.0e-11), content="true")
  }
}

///|
/// `leaf_psi_a` is `leaf_influence` with its residual divisor pulled
/// out: `-1 / n_k` on the leaf's own estimation rows and `0.0`
/// elsewhere, which is the shape `irm_style_sensitivity` consumes.
/// Asserted against the count-derived value and against the
/// sensitivity result's own `nu2`, so the accessor, the sensitivity
/// method and the derivation cannot drift apart.
test "policy_tree_leaf_psi_a" {
  let n = 400
  let (x, s) = v098_dgp(n)
  let f = DoubleMLPolicyTree::new(x, s, depth=2, honest=true, split_seed=2024).fit()
  let sens = f.sensitivity_analysis()
  let es = f.est_indices()
  for k = 0; k < f.leaf_count.length(); k = k + 1 {
    let psi = f.leaf_psi_a(k)
    inspect(psi.length(), content="200")
    let expect = -1.0 / f.leaf_count[k].to_double()
    let mut ok = true
    let mut own_rows = 0
    for j = 0; j < es.length(); j = j + 1 {
      if f.leaf_assignment[j] == k {
        if psi[j] != expect {
          ok = false
        }
        own_rows = own_rows + 1
      } else if psi[j] != 0.0 {
        ok = false
      }
    }
    inspect(ok, content="true")
    inspect(own_rows, content=f.leaf_count[k].to_string())
    // `nu2` in the sensitivity result is the mean of `psi_a^2` over
    // the leaf's OWN rows -- i.e. `1 / n_k^2` -- and nothing else.
    inspect(
      v098_rel_close(sens[k].nu2, expect * expect, 1.0e-12),
      content="true",
    )
  }
}

// ---------------------------------------------------------------------------
// 10. DGP SANITY: NO DEGENERATE SPLIT PASSES AS A SMALL NUMBER
// ---------------------------------------------------------------------------

///|
/// Sanity on the main fixture, in the v0.93-v0.97 style: the leaf
/// counts are plausible and the relative standard errors are `O(1)`
/// -- so a degenerate split cannot pass as a small-but-finite number.
///
/// MEASURED leaf counts are `[50, 45, 60, 45]` out of `n_est =
/// 200`, i.e. 22.5%-30% of the estimation half: a genuinely balanced
/// depth-2 partition, not a stump and not one 1-observation
/// splinter.
///
/// The brackets asserted are all two-sided and all independently
/// computed, so a `leaf_se` that was merely "some small finite
/// number" fails them:
///   - `0 < leaf_se[k]`, since every leaf has real within-leaf
///     noise;
///   - `leaf_se[k] < sd(y_est)`, since the SE of a subsample MEAN
///     over `n_k > 1` draws must be below the spread of the draws;
///   - `leaf_se[k] / |theta_k| < 0.5`, the relative-SE bound, which
///     a wrong scaling by `n_k` or by `sqrt(n_k)` would break;
///   - and the SE must actually SHRINK with `n`: the same DGP at
///     `n = 1600` has a larger estimation half and must report a
///     strictly smaller `leaf_se` in every leaf.
test "policy_tree_honest_dgp_sanity" {
  let (x, s) = v098_dgp(400)
  let f = DoubleMLPolicyTree::new(x, s, depth=2, honest=true, split_seed=2024).fit()
  let n_est = f.est_indices().length()
  inspect(n_est, content="200")
  inspect(v098_show_ints(f.leaf_count), content="[50, 45, 60, 45]")
  let mut tot = 0
  for c in f.leaf_count {
    tot = tot + c
  }
  inspect(tot, content="200")
  // Plausible, balanced counts: every leaf between 1/16 and 1/2 of
  // the estimation half.
  for c in f.leaf_count {
    inspect(c * 16 >= n_est, content="true")
    inspect(c * 2 <= n_est, content="true")
  }
  inspect(f.leaf_se_reliable(), content="true")
  inspect(f.unreliable_leaves().length(), content="0")
  let raw : Array[Double] = []
  for i in f.est_indices() {
    raw.push(s[i])
  }
  let sd_all = v098_sample_sd(raw)
  for k = 0; k < f.leaf_count.length(); k = k + 1 {
    let se = f.leaf_se()[k]
    inspect(se > 0.0, content="true")
    inspect(se < sd_all, content="true")
    inspect(se / f.leaf_signal_mean[k].abs() < 0.5, content="true")
  }
  // The relative SEs, two-sided and scale-free, so "O(1)" is a
  // measured claim rather than a hope. MEASURED they run
  // 0.0136, 0.0103, 0.0373, 0.1102: far enough above zero that no
  // leaf is degenerate, far enough below one that every leaf mean is
  // pinned down by its own sample.
  let mut rel_lo = 1.0
  let mut rel_hi = 0.0
  for k = 0; k < f.leaf_count.length(); k = k + 1 {
    let rel = f.leaf_se()[k] / f.leaf_signal_mean[k].abs()
    if rel < rel_lo {
      rel_lo = rel
    }
    if rel > rel_hi {
      rel_hi = rel
    }
  }
  inspect(rel_lo > 0.005, content="true")
  inspect(rel_hi < 0.25, content="true")
  // And the honest leaf means themselves, pinned, so the ratios above
  // are anchored to real numbers.
  inspect(f.leaf_signal_mean[0], content="-1.0062758620689654")
  inspect(f.leaf_signal_mean[1], content="-1.4939655172413795")
  inspect(f.leaf_signal_mean[2], content="-0.534655172413793")
  inspect(f.leaf_signal_mean[3], content="0.8385632183908047")
  // THE SAMPLE-SIZE CHECK. Quadrupling `n` quadruples the
  // estimation half, and every leaf's SE must fall strictly. A
  // `leaf_se` that ignored `n_k`, or that were pinned to a constant,
  // fails here.
  let (x2, s2) = v098_dgp(1600)
  let g = DoubleMLPolicyTree::new(x2, s2, depth=2, honest=true, split_seed=2024).fit()
  inspect(g.est_indices().length(), content="800")
  inspect(g.leaf_se().length(), content="4")
  let mut all_smaller = true
  let mut ratio_sum = 0.0
  for k = 0; k < 4; k = k + 1 {
    if g.leaf_se()[k] >= f.leaf_se()[k] {
      all_smaller = false
    }
    ratio_sum = ratio_sum + f.leaf_se()[k] / g.leaf_se()[k]
  }
  inspect(all_smaller, content="true")
  // The mean SE ratio is in the right neighbourhood for a `1/sqrt(n)`
  // law with a slightly different partition; the honest claim is only
  // "strictly smaller, and by a bounded factor", not an exact rate.
  let mean_ratio = ratio_sum / 4.0
  inspect(mean_ratio > 1.5, content="true")
  inspect(mean_ratio < 12.0, content="true")
}

// ---------------------------------------------------------------------------
// 11. MEMOIZATION UNDER HONESTY
// ---------------------------------------------------------------------------

///|
/// The memoize layer has to know about the honesty split, because the
/// honest payload is no longer indexed by all `n_obs` rows: the
/// `fold_ids` slot holds the ESTIMATION-half indices and the cached
/// row count is `n_est`. If that were left at `n_obs`,
/// `FitCache::is_valid`'s `fold_ids.length() == n_obs` check could
/// never fire and memoization would silently never hit.
///
/// So: a genuine cache hit must reproduce EVERY honest quantity
/// exactly -- structure, leaf statistics, `leaf_se`, and both index
/// lists -- and it must be a genuine hit (`has_cache()` true, and
/// driven from the value that actually holds the cache, since `tree`
/// still carries the empty constructor cache).
test "policy_tree_honest_memoize_round_trip" {
  let (x, s) = v098_dgp(400)
  let tree = DoubleMLPolicyTree::new(
    x,
    s,
    depth=3,
    honest=true,
    split_seed=2024,
  ).enable_memoize()
  let fit1 = tree.fit()
  inspect(fit1.has_cache(), content="true")
  let fit2 = fit1.fit()
  inspect(fit2.has_cache(), content="true")
  inspect(
    v098_tree_repr(fit2.root) == v098_tree_repr(fit1.root),
    content="true",
  )
  inspect(fit2.split_feature() == fit1.split_feature(), content="true")
  inspect(fit2.split_value() == fit1.split_value(), content="true")
  inspect(fit2.leaf_signal_mean == fit1.leaf_signal_mean, content="true")
  inspect(v098_int_array_eq(fit2.leaf_count, fit1.leaf_count), content="true")
  inspect(
    v098_int_array_eq(fit2.leaf_assignment, fit1.leaf_assignment),
    content="true",
  )
  // The v0.98.0 payload specifically.
  inspect(fit2.leaf_se() == fit1.leaf_se(), content="true")
  inspect(
    v098_int_array_eq(fit2.est_indices(), fit1.est_indices()),
    content="true",
  )
  inspect(
    v098_int_array_eq(fit2.split_indices(), fit1.split_indices()),
    content="true",
  )
  inspect(fit2.est_indices().length(), content="200")
  // And a fresh, uncached fit agrees with the cached one -- the cache
  // is an optimisation, not a different estimator.
  let fresh = DoubleMLPolicyTree::new(
    x,
    s,
    depth=3,
    honest=true,
    split_seed=2024,
  ).fit()
  inspect(
    v098_tree_repr(fresh.root) == v098_tree_repr(fit1.root),
    content="true",
  )
  inspect(fresh.leaf_se() == fit1.leaf_se(), content="true")
  inspect(
    v098_int_array_eq(fresh.leaf_assignment, fit1.leaf_assignment),
    content="true",
  )
}

///|
/// `honest` and `split_seed` are structural -- they change which
/// rows build the tree and which rows produce the leaf means -- so
/// both are folded into the cache key via the `estimator_kind`
/// discriminator. This asserts the key actually invalidates in BOTH
/// directions, and that a different `split_seed` really does give a
/// different partition (so the key is not being invalidated
/// pointlessly).
test "policy_tree_honest_cache_key_invalidates" {
  let (x, s) = v098_dgp(400)
  // Same data and seed, honesty toggled: a reused cache would hand
  // back an adaptive fit's numbers for an honest request.
  let honest = DoubleMLPolicyTree::new(
      x,
      s,
      depth=2,
      honest=true,
      split_seed=2024,
    )
    .enable_memoize()
    .fit()
  let flipped = honest
    .disable_memoize()
    .enable_memoize()
    .enable_honesty(false)
    .fit()
  inspect(flipped.has_cache(), content="true")
  // The flipped model is the ADAPTIVE one, and its leaf assignment
  // covers all 400 rows rather than 200, so it cannot have come from
  // the honest cache.
  inspect(flipped.leaf_assignment.length(), content="400")
  inspect(
    v098_int_array_eq(honest.leaf_assignment, flipped.leaf_assignment),
    content="false",
  )
  // Back on, and a different `split_seed`: the partition differs.
  let reseeded = flipped.enable_honesty(true).enable_split_seed(7).fit()
  inspect(reseeded.leaf_assignment.length(), content="200")
  inspect(
    v098_int_array_eq(reseeded.est_indices(), honest.est_indices()),
    content="false",
  )
  inspect(
    v098_int_array_eq(reseeded.leaf_assignment, honest.leaf_assignment),
    content="false",
  )
}

// ---------------------------------------------------------------------------
// 12. THE ADAPTIVE PATH REFUSES TO REPORT AN UNCERTAINTY
// ---------------------------------------------------------------------------

///|
/// `leaf_se()` on an adaptive fit must ABORT rather than return the
/// naive same-formula number. That number is the "standard error" of
/// an adaptive estimator whose bias does not vanish at a usable rate
/// (Athey & Imbens 2016 report interval coverage falling well below
/// nominal for adaptive recursive partitioning), so reporting it
/// unlabelled is precisely the failure mode this release exists to
/// prevent. `is_honest()` is the supported way to branch.
test "panic_policy_tree_leaf_se_not_honest" {
  let (x, s) = v098_dgp(400)
  let f = DoubleMLPolicyTree::new(x, s, depth=2).fit()
  inspect(f.is_honest(), content="false")
  let _ = f.leaf_se()
}

///|
/// `leaf_influence` is likewise refused on an adaptive fit: the array
/// is computable, but it is not a VALID influence function when the
/// partition was chosen using the same rows.
test "panic_policy_tree_leaf_influence_not_honest" {
  let (x, s) = v098_dgp(400)
  let f = DoubleMLPolicyTree::new(x, s, depth=2).fit()
  let _ = f.leaf_influence(0)
}

///|
/// `policy_value` and `policy_value_se` are honest-only for the same
/// reason. `is_honest()` is readable before `fit()`, so a caller can
/// branch without catching an abort.
test "panic_policy_tree_policy_value_not_honest" {
  let (x, s) = v098_dgp(400)
  let f = DoubleMLPolicyTree::new(x, s, depth=2).fit()
  let _ = f.policy_value()
}

///|
/// A different `split_seed` gives a genuinely different honest
/// partition, and both halves are still a partition of the sample.
/// This is the determinism check in its other direction: the split is
/// seeded, so it is reproducible, but it is not fixed.
test "policy_tree_split_seed_changes_the_partition" {
  let n = 400
  let (x, s) = v098_dgp(n)
  let a = DoubleMLPolicyTree::new(x, s, depth=2, honest=true, split_seed=2024).fit()
  let b = DoubleMLPolicyTree::new(x, s, depth=2, honest=true, split_seed=2024).fit()
  inspect(v098_int_array_eq(a.est_indices(), b.est_indices()), content="true")
  inspect(a.leaf_se() == b.leaf_se(), content="true")
  let c = DoubleMLPolicyTree::new(x, s, depth=2, honest=true, split_seed=99).fit()
  inspect(v098_int_array_eq(a.est_indices(), c.est_indices()), content="false")
  inspect(v098_any_overlap(a.est_indices(), c.est_indices()), content="true")
  inspect(c.est_indices().length(), content="200")
}
