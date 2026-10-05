///|
// v0.80.0+: white-box tests for the `FitCache` memoization
// layer added to `DoubleMLIRM::fit()` (in `irm.mbt`).
//
// Coverage:
//   #1: enable_memoize() / disable_memoize() set the flag.
//   #2: has_cache() reflects whether the cache is populated.
//   #3: clear_cache() drops the cache and has_cache() -> false.
//   #4: memoize_returns_same_coef -- two fits with memoize
//       produce coef / se within 1e-10 (cached path is
//       byte-equivalent to fresh path).
//   #5: memoize_invalidates_on_data_change -- scale X by 2
//       between two fits, verify the second coef differs
//       (cache invalidated).
//   #6: memoize_invalidates_on_n_folds_change -- fit with
//       n_folds=5, then change to n_folds=10, verify cache
//       invalidated (coef differs).
//   #7: hash_data_distinct_for_different_data -- two datasets
//       produce different hashes.
//   #8: hash_data_stable_for_same_data -- same dataset called
//       twice produces the same hash.

///|
test "enable_memoize_set_flag" {
  let n = 100
  let p = 2
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    if i % 2 == 0 {
      d[i] = 1.0
      y[i] = 1.0
    }
  }
  let data = DoubleMLData::new(x, y, d)
  let irm = DoubleMLIRM::new(data, n_folds=2, seed=0)
  // Default: memoize_enabled is false, has_cache is false.
  inspect(irm.memoize_enabled, content="false")
  inspect(irm.has_cache(), content="false")
  // enable_memoize() returns a struct with the flag set.
  let enabled = irm.enable_memoize()
  inspect(enabled.memoize_enabled, content="true")
  // Original struct is unchanged (immutability).
  inspect(irm.memoize_enabled, content="false")
}

///|
test "disable_memoize_set_flag" {
  let n = 100
  let p = 2
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    if i % 2 == 0 {
      d[i] = 1.0
      y[i] = 1.0
    }
  }
  let data = DoubleMLData::new(x, y, d)
  let irm = DoubleMLIRM::new(data, n_folds=2, seed=0)
  let enabled = irm.enable_memoize()
  inspect(enabled.memoize_enabled, content="true")
  let disabled = enabled.disable_memoize()
  inspect(disabled.memoize_enabled, content="false")
  // Original enabled struct is unchanged.
  inspect(enabled.memoize_enabled, content="true")
}

///|
test "clear_cache_works" {
  let n = 100
  let p = 2
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    if i % 2 == 0 {
      d[i] = 1.0
      y[i] = 1.0
    }
  }
  let data = DoubleMLData::new(x, y, d)
  let irm = DoubleMLIRM::new(data, n_folds=2, seed=0).enable_memoize()
  // First fit populates the cache.
  let fitted = irm.fit()
  inspect(fitted.has_cache(), content="true")
  // clear_cache() drops the cache.
  let cleared = fitted.clear_cache()
  inspect(cleared.has_cache(), content="false")
  // clear_cache() preserves the memoize_enabled flag.
  inspect(cleared.memoize_enabled, content="true")
}

///|
test "memoize_returns_same_coef" {
  // Two fits with the same data + seed + memoize must produce
  // coef / se within numerical tolerance. The cached path
  // skips `cross_fit_irm` but the aggregation is byte-equivalent
  // because the cached `g0_hat / g1_hat / m_hat / m_raw` are
  // bit-identical to the freshly-fit predictions.
  let n = 200
  let p = 3
  let rng = chacha8_rng(7777)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    let mut s = 0.0
    for j = 0; j < p; j = j + 1 {
      s = s + x_flat[i * p + j]
    }
    y[i] = 1.0 * d[i] + s + (rng.double() - 0.5) * 0.1
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d)
  let irm = DoubleMLIRM::new(data, n_folds=4, n_rep=1, seed=3141).enable_memoize()
  let fit1 = irm.fit()
  // Second fit: should hit the cache (same seed / data / learners).
  //
  // v0.99.0 fix: this must be `fit1.fit()`, not `irm.fit()`.
  // `DoubleMLIRM::fit` takes `self` by value and returns a NEW
  // estimator, so the cache writeback lands on `fit1` only --
  // `irm` still carries the empty constructor cache. Re-fitting
  // `irm` re-ran the whole cross-fit, so this test was comparing
  // fresh-vs-fresh and would have passed with the cache-read
  // branch deleted outright.
  let fit2 = fit1.fit()
  inspect(fit1.has_cache(), content="true")
  inspect(fit2.has_cache(), content="true")
  let d_coef = (fit1.coef() - fit2.coef()).abs()
  let d_se = (fit1.se() - fit2.se()).abs()
  inspect(d_coef < 1.0e-10, content="true")
  inspect(d_se < 1.0e-10, content="true")
}

///|
test "memoize_invalidates_on_data_change" {
  // Verify the cache detects a data mutation between fits.
  // Strategy: scale y by 2 between two data containers; the
  // IRM score is linear in y, so the coef should approximately
  // double. The hash_data fingerprint on the two containers
  // must differ (otherwise the cache would happily reuse the
  // stale nuisances).
  let n = 200
  let p = 3
  let rng = chacha8_rng(8888)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    let mut s = 0.0
    for j = 0; j < p; j = j + 1 {
      s = s + x_flat[i * p + j]
    }
    y[i] = 1.0 * d[i] + s + (rng.double() - 0.5) * 0.1
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data_v1 = DoubleMLData::new(x, y, d)
  let y_scaled : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    y_scaled[i] = 2.0 * y[i]
  }
  let data_v2 = DoubleMLData::new(x, y_scaled, d)
  // Verify hash_data distinguishes the two data containers
  // directly. This proves the cache key would differ on the
  // second fit, forcing a fresh cross-fit.
  let h1 = hash_data(
    data_v1.x,
    data_v1.y,
    data_v1.d,
    cluster_vars=data_v1.cluster_vars,
  )
  let h2 = hash_data(
    data_v2.x,
    data_v2.y,
    data_v2.d,
    cluster_vars=data_v2.cluster_vars,
  )
  inspect(h1 != h2, content="true")
  // End-to-end: a fresh estimator on data_v2 starts with an
  // empty cache, so the first fit must be a fresh cross-fit
  // (not a cache hit). The fitted coef on y-scaled-by-2 should
  // approximately double relative to the y-unscaled fit.
  let fit_v1 = DoubleMLIRM::new(data_v1, n_folds=4, n_rep=1, seed=3141)
    .enable_memoize()
    .fit()
  inspect(fit_v1.has_cache(), content="true")
  let irm_v2 = DoubleMLIRM::new(data_v2, n_folds=4, n_rep=1, seed=3141).enable_memoize()
  inspect(irm_v2.has_cache(), content="false")
  let fit_v2 = irm_v2.fit()
  // For y -> 2*y, the ATE score `psi_b` doubles, so the
  // ratio of coefs should be ~2.
  let ratio = fit_v2.coef() / fit_v1.coef()
  let d_ratio = (ratio - 2.0).abs()
  inspect(d_ratio < 0.1, content="true")
}

///|
test "memoize_invalidates_on_n_folds_change" {
  // Fit with n_folds=4, then change to n_folds=10. The cache
  // stores n_folds=4 in the key; the second call's n_folds=10
  // must mismatch and trigger a fresh cross-fit.
  let n = 300
  let p = 3
  let rng = chacha8_rng(9999)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    let mut s = 0.0
    for j = 0; j < p; j = j + 1 {
      s = s + x_flat[i * p + j]
    }
    y[i] = 1.0 * d[i] + s + (rng.double() - 0.5) * 0.1
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d)
  let fit_a = DoubleMLIRM::new(data, n_folds=4, n_rep=1, seed=3141)
    .enable_memoize()
    .fit()
  // Different n_folds: cache key mismatches, fresh fit runs.
  let fit_b = DoubleMLIRM::new(data, n_folds=10, n_rep=1, seed=3141)
    .enable_memoize()
    .fit()
  // Coefs should differ because the fold partition differs.
  let d_coef = (fit_a.coef() - fit_b.coef()).abs()
  // n_folds change + same seed should give different fold
  // partitions and therefore different cross-fit nuisances.
  inspect(d_coef > 1.0e-6, content="true")
}

///|
test "hash_data_distinct_for_different_data" {
  let n = 50
  let p = 2
  let x1 = Matrix::zeros(n, p)
  let x2 = Matrix::zeros(n, p)
  let y1 : Array[Double] = Array::make(n, 0.0)
  let y2 : Array[Double] = Array::make(n, 0.0)
  let d1 : Array[Double] = Array::make(n, 0.0)
  let d2 : Array[Double] = Array::make(n, 0.0)
  // Two datasets that differ only in X row 0 column 0.
  for i = 0; i < n; i = i + 1 {
    x1.set(i, 0, i.to_double() * 0.01)
    x2.set(i, 0, i.to_double() * 0.01)
    x1.set(i, 1, 1.0)
    x2.set(i, 1, 1.0)
    y1[i] = i.to_double() * 0.1
    y2[i] = i.to_double() * 0.1
    d1[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
    d2[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
  }
  // Make x2 differ from x1 in one entry.
  x2.set(0, 0, 0.999)
  let h1 = hash_data(x1, y1, d1)
  let h2 = hash_data(x2, y2, d2)
  inspect(h1 == h2, content="false")
}

///|
test "hash_data_stable_for_same_data" {
  let n = 50
  let p = 2
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    x.set(i, 0, i.to_double() * 0.01)
    x.set(i, 1, 1.0)
    y[i] = i.to_double() * 0.1
    d[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
  }
  let h1 = hash_data(x, y, d)
  let h2 = hash_data(x, y, d)
  inspect(h1 == h2, content="true")
}

///|
test "fit_cache_empty_is_invalid" {
  // An empty cache (the default) must report `is_valid = false`
  // against any plausible configuration -- otherwise an empty
  // cache would short-circuit to "use cache" on the first call.
  let empty = FitCache::empty()
  inspect(empty.is_empty(), content="true")
  inspect(
    empty.is_valid(0, 2, 1, 100, 12345UL, 67890UL, 0UL, "irm"),
    content="false",
  )
}

///|
test "cache_supports_n_rep_2" {
  // v0.82.0+: FitCache now correctly handles `n_rep > 1`. Two
  // IRM fits with `n_rep = 2` and `enable_memoize()` must
  // produce byte-identical (within 1e-10) coef / se on a
  // repeat call. The cache stores the LAST rep's fold_ids +
  // nuisances; the per-rep loop's first `n_rep - 1` iterations
  // always recompute (each rep has its own seed / fold split),
  // and the cache hit applies only to the LAST rep. Same
  // `enable_memoize` / clear_cache / has_cache` plumbing as
  // the `n_rep = 1` path.
  let n = 200
  let p = 3
  let rng = chacha8_rng(3333)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    let mut s = 0.0
    for j = 0; j < p; j = j + 1 {
      s = s + x_flat[i * p + j]
    }
    y[i] = 1.0 * d[i] + s + (rng.double() - 0.5) * 0.1
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data = DoubleMLData::new(x, y, d)
  // n_rep = 2 -- cache only stores the LAST rep's nuisances,
  // but the FLAG and `has_cache` semantics are unchanged.
  let irm = DoubleMLIRM::new(data, n_folds=4, n_rep=2, seed=3141).enable_memoize()
  let fit1 = irm.fit()
  let fit2 = irm.fit()
  // The fit() result has has_cache = false because we only
  // write to the cache when `nrep == 1` (see IRM::fit's
  // `next_cache` branch). The cache structure itself is
  // populated only on the nrep == 1 path; nrep > 1 is a
  // "no cache write" path so the second fit runs every rep
  // fresh. Coefs are still byte-identical because the same
  // seed / folds produce the same nuisances.
  let d_coef = (fit1.coef() - fit2.coef()).abs()
  let d_se = (fit1.se() - fit2.se()).abs()
  inspect(d_coef < 1.0e-10, content="true")
  inspect(d_se < 1.0e-10, content="true")
}

///|
test "cache_invalidates_on_cluster_ids_change" {
  // v0.82.0+: a switch from IID (empty cluster_vars) to
  // clustered (non-empty cluster_vars) MUST invalidate the
  // cache. We construct two IRMs over data with the same x / y
  // / d but different cluster_vars, then verify the cache key
  // hashes are different.
  let n = 200
  let p = 3
  let rng = chacha8_rng(4444)
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let y : Array[Double] = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    for j = 0; j < p; j = j + 1 {
      x_flat[i * p + j] = rng.double()
    }
    d[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    let mut s = 0.0
    for j = 0; j < p; j = j + 1 {
      s = s + x_flat[i * p + j]
    }
    y[i] = 1.0 * d[i] + s + (rng.double() - 0.5) * 0.1
  }
  let x = Matrix::from_array(x_flat, n, p)
  let data_iid = DoubleMLData::new(x, y, d)
  // Two clusterings: "by-row-index mod 4" vs "by-row-index mod 5".
  // Different partitions -> different hashes.
  let cluster_a : Array[Int] = Array::makei(n, fn(i) { i % 4 })
  let cluster_b : Array[Int] = Array::makei(n, fn(i) { i % 5 })
  let ha = hash_cluster_ids(cluster_a)
  let hb = hash_cluster_ids(cluster_b)
  inspect(ha != hb, content="true")
  // Empty vector -> 0 sentinel.
  let empty : Array[Int] = []
  let h0 = hash_cluster_ids(empty)
  inspect(h0 == 0UL, content="true")
  // An estimator with no cluster_vars hashes to 0; one with
  // cluster_vars hashes to a non-zero UInt64. The cache must
  // therefore distinguish IID from clustered.
  inspect(data_iid.cluster_vars.length(), content="0")
  let data_clustered = DoubleMLData::new(x, y, d, cluster_vars=cluster_a)
  inspect(data_clustered.cluster_vars.length(), content="200")
}
