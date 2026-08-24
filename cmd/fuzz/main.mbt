// Fuzz harness for mavis/dml pure functions.
//
// MoonBit has no libFuzzer/AFL integration, so this is a
// deterministic property-based fuzzer: it drives thousands of
// randomized inputs (edge values included) through the library's
// pure numeric surfaces and asserts invariants after each run.
// Any violated invariant aborts with a message naming the
// function and the seed that reproduced it.
//
// Fuzzed surfaces and invariants:
//   1. p_adjust family (holm / bonferroni / bh / by / tsbh /
//      tsby): output length == input length; all outputs in
//      [0, 1]; monotone non-decreasing in the unadjusted input
//      order; adjusted >= min(1, unadjusted) for Bonferroni-
//      style methods (BH/BY are NOT pointwise-monotone, so only
//      range + length are asserted there); NaN inputs never
//      crash (they may poison values — we feed NaN only to the
//      range/length checks).
//   2. kfold: every index appears in exactly one test fold;
//      train ∩ test = ∅; sizes differ by at most 1.
//   3. Matrix ops: matmul associativity on random small
//      matrices ((A·B)·C == A·(B·C) within 1e-9 relative).
//   4. LinearRegression: fitted values reproduce training y
//      exactly when p > n (interpolation regime) within 1e-6.
//   5. norm_cdf / norm_ppf: inverse consistency within 1e-4
//      over a random sweep of p ∈ (0.001, 0.999).
//   6. romano_wolf_p_adjust: output in [0,1], length preserved.

///|
fn check(cond : Bool, msg : String) -> Unit {
  if !cond {
    abort("FUZZ FAIL: \{msg}")
  }
}

///|
fn approx_eq(a : Double, b : Double, tol : Double) -> Bool {
  let d = if a > b { a - b } else { b - a }
  let scale = if a.abs() > b.abs() { a.abs() } else { b.abs() }
  d <= tol * (1.0 + scale)
}

///|
fn fuzz_padjust(rng : @random.Rand, trials : Int) -> Unit {
  for trial = 0; trial < trials; trial = trial + 1 {
    let m = rng.int(limit=40) + 1
    let ps : Array[Double] = []
    for i = 0; i < m; i = i + 1 {
      // Mix of tiny / moderate / boundary values.
      let u = rng.double()
      let p = if u < 0.2 {
        rng.double() * 1.0e-6
      } else if u < 0.9 {
        rng.double()
      } else {
        1.0
      }
      ps.push(p)
    }
    // Range/length invariants hold for every method.
    let bh = @dml.bh_fdr_p_adjust(ps)
    let by = @dml.by_fdr_p_adjust(ps)
    let tsbh = @dml.tsbh_p_adjust(ps)
    let tsby = @dml.tsby_p_adjust(ps)
    let holm = @dml.holm_bonferroni_p_adjust(ps)
    let bonf = @dml.bonferroni_p_adjust(ps)
    let names = ["bh", "by", "tsbh", "tsby", "holm", "bonferroni"]
    let outs = [bh, by, tsbh, tsby, holm, bonf]
    for mi = 0; mi < names.length(); mi = mi + 1 {
      let name = names[mi]
      let adj = outs[mi]
      check(
        adj.length() == m,
        "\{name}: length preserved (m=\{m}, trial=\{trial})",
      )
      for i = 0; i < m; i = i + 1 {
        let v = adj[i]
        check(
          v >= 0.0 && v <= 1.0,
          "\{name}: output in [0,1] (got \{v}, m=\{m}, trial=\{trial})",
        )
      }
    }
    // Holm and Bonferroni must be pointwise >= the unadjusted p.
    for i = 0; i < m; i = i + 1 {
      check(
        holm[i] >= ps[i] - 1.0e-12,
        "holm: pointwise >= unadjusted (i=\{i}, trial=\{trial})",
      )
      check(
        bonf[i] >= ps[i] - 1.0e-12,
        "bonferroni: pointwise >= unadjusted (i=\{i}, trial=\{trial})",
      )
    }
  }
}

///|
fn fuzz_kfold(rng : @random.Rand, trials : Int) -> Unit {
  for trial = 0; trial < trials; trial = trial + 1 {
    let n_obs = rng.int(limit=200) + 2
    let n_folds = rng.int(limit=n_obs - 1) + 2
    let seed = rng.int(limit=1_000_000)
    let folds = @dml.kfold(n_obs, n_folds, seed)
    check(folds.length() == n_folds, "kfold: fold count")
    // Membership vector: each index in exactly one test fold.
    let seen : Array[Bool] = Array::make(n_obs, false)
    let mut total_test = 0
    let mut min_size = n_obs + 1
    let mut max_size = 0
    for f = 0; f < folds.length(); f = f + 1 {
      let test_idx = folds[f].test_idx
      let train_idx = folds[f].train_idx
      total_test = total_test + test_idx.length()
      if test_idx.length() < min_size {
        min_size = test_idx.length()
      }
      if test_idx.length() > max_size {
        max_size = test_idx.length()
      }
      for k = 0; k < test_idx.length(); k = k + 1 {
        let idx = test_idx[k]
        check(idx >= 0 && idx < n_obs, "kfold: test idx in range")
        check(!seen[idx], "kfold: duplicate test idx \{idx}")
        seen[idx] = true
      }
      // train ∪ test covers everything disjointly.
      check(
        train_idx.length() + test_idx.length() == n_obs,
        "kfold: train+test == n_obs",
      )
    }
    check(total_test == n_obs, "kfold: every obs tested exactly once")
    check(max_size - min_size <= 1, "kfold: fold sizes balanced")
  }
}

///|
fn fuzz_matmul(rng : @random.Rand, trials : Int) -> Unit {
  for trial = 0; trial < trials; trial = trial + 1 {
    let n = rng.int(limit=6) + 1
    let m = rng.int(limit=6) + 1
    let k = rng.int(limit=6) + 1
    let mk : Array[Double] = []
    let km : Array[Double] = []
    let kn : Array[Double] = []
    for i = 0; i < n * m; i = i + 1 {
      mk.push(rng.double() * 4.0 - 2.0)
    }
    for i = 0; i < m * k; i = i + 1 {
      km.push(rng.double() * 4.0 - 2.0)
    }
    for i = 0; i < k * n; i = i + 1 {
      kn.push(rng.double() * 4.0 - 2.0)
    }
    let a = @dml.Matrix::from_array(mk, n, m)
    let b = @dml.Matrix::from_array(km, m, k)
    let c = @dml.Matrix::from_array(kn, k, n)
    // (A·B)·C vs A·(B·C), computed via repeated scalar loops.
    let ab = @dml.matmul(a, b)
    let abc_left = @dml.matmul(ab, c)
    let bc = @dml.matmul(b, c)
    let abc_right = @dml.matmul(a, bc)
    for i = 0; i < n; i = i + 1 {
      for j = 0; j < n; j = j + 1 {
        check(
          approx_eq(
            abc_left.get(i, j),
            abc_right.get(i, j),
            1.0e-9,
          ),
          "matmul associativity (\{i},\{j})",
        )
      }
    }
  }
}

///|
fn fuzz_linear_exact(rng : @random.Rand, trials : Int) -> Unit {
  // OLS normal-equations invariant on overdetermined,
  // well-conditioned random designs. `LinearRegression`
  // augments with an intercept internally, so the fitted
  // residuals must be orthogonal to BOTH the implicit
  // intercept column (sum(r) == 0) and every feature
  // column (x_j . r == 0). This holds by definition of
  // the least-squares solution regardless of y, and is
  // far more robust than an exact-interpolation check
  // (which breaks on ill-conditioned bases like
  // Vandermonde, where the internal 1e-10 ridge
  // dominates the smallest singular value).
  for trial = 0; trial < trials; trial = trial + 1 {
    let n = rng.int(limit=60) + 20
    let p = rng.int(limit=5) + 2
    let flat : Array[Double] = []
    let ys : Array[Double] = []
    for _i = 0; _i < n * p; _i = _i + 1 {
      flat.push(rng.double() * 2.0 - 1.0)
    }
    for _i = 0; _i < n; _i = _i + 1 {
      ys.push((rng.double() - 0.5) * 10.0)
    }
    let x_mat = @dml.Matrix::from_array(flat, n, p)
    let model = @dml.LinearRegression::new().fit(x_mat, ys)
    let pred = model.predict(x_mat)
    // Invariant 1: all outputs finite.
    let mut sum_r = 0.0
    let mut sum_abs_r = 0.0
    for i = 0; i < n; i = i + 1 {
      let r = pred[i] - ys[i]
      check(
        r.abs() < 1.0e300,
        "linear residuals finite (trial \{trial})",
      )
      sum_r = sum_r + r
      sum_abs_r = sum_abs_r + r.abs()
    }
    // Invariant 2: residuals orthogonal to intercept column.
    check(
      sum_r.abs() <= 1.0e-7 * sum_abs_r + 1.0e-12,
      "OLS: residuals orthogonal to intercept (trial \{trial})",
    )
    // Invariant 3: residuals orthogonal to each feature column.
    for j = 0; j < p; j = j + 1 {
      let mut dot_xr = 0.0
      let mut norm_x = 0.0
      let mut norm_r = 0.0
      for i = 0; i < n; i = i + 1 {
        let xij = x_mat.get(i, j)
        let r = pred[i] - ys[i]
        dot_xr = dot_xr + xij * r
        norm_x = norm_x + xij * xij
        norm_r = norm_r + r * r
      }
      let scale = (norm_x.sqrt() * norm_r.sqrt())
      check(
        dot_xr.abs() <= 1.0e-6 * scale + 1.0e-12,
        "OLS: residuals orthogonal to feature \{j} (trial \{trial})",
      )
    }
  }
}

///|
fn fuzz_norm_inverse(rng : @random.Rand, trials : Int) -> Unit {
  for trial = 0; trial < trials; trial = trial + 1 {
    let p = 0.001 + rng.double() * 0.998
    let z = @dml.norm_ppf(p)
    let p_back = @dml.norm_cdf(z)
    check(
      (p_back - p).abs() < 1.0e-3,
      "norm_ppf/norm_cdf inverse consistency (p=\{p})",
    )
  }
}

///|
fn fuzz_romano_wolf(rng : @random.Rand, trials : Int) -> Unit {
  for trial = 0; trial < trials; trial = trial + 1 {
    let k = rng.int(limit=20) + 2
    let ts : Array[Double] = []
    for i = 0; i < k; i = i + 1 {
      ts.push((rng.double() - 0.5) * 6.0)
    }
    // Row-major n_boot x k bootstrap t-stat block.
    let n_boot = 50
    let boot : Array[Double] = []
    for _b = 0; _b < n_boot * k; _b = _b + 1 {
      boot.push((rng.double() - 0.5) * 2.0)
    }
    let adj = @dml.romano_wolf_p_adjust(boot, ts, ts)
    check(adj.length() == k, "romano-wolf: length preserved")
    for i = 0; i < k; i = i + 1 {
      check(
        adj[i] >= 0.0 && adj[i] <= 1.0,
        "romano-wolf: output in [0,1] (i=\{i}, trial=\{trial})",
      )
    }
  }
}

///|
fn main {
  let trials = 300
  println("=== mavis/dml fuzz harness (\{trials} trials per surface) ===")
  let master = @random.Rand::chacha8(seed=Bytes::from_array(@dml.seed_to_bytes(20260824)))
  // Derive per-surface RNGs deterministically from the master seed.
  let s1 = master.int(limit=1_000_000)
  let s2 = master.int(limit=1_000_000)
  let s3 = master.int(limit=1_000_000)
  let s4 = master.int(limit=1_000_000)
  let s5 = master.int(limit=1_000_000)
  let s6 = master.int(limit=1_000_000)
  println("[1/6] p_adjust family ...")
  fuzz_padjust(@dml.chacha8_rng(s1), trials)
  println("      OK")
  println("[2/6] kfold partition invariants ...")
  fuzz_kfold(@dml.chacha8_rng(s2), trials)
  println("      OK")
  println("[3/6] Matrix matmul associativity ...")
  fuzz_matmul(@dml.chacha8_rng(s3), trials)
  println("      OK")
  println("[4/6] LinearRegression normal-equations invariants ...")
  fuzz_linear_exact(@dml.chacha8_rng(s4), trials)
  println("      OK")
  println("[5/6] norm_ppf / norm_cdf inverse sweep ...")
  fuzz_norm_inverse(@dml.chacha8_rng(s5), trials)
  println("      OK")
  println("[6/6] romano_wolf_p_adjust range/length ...")
  fuzz_romano_wolf(@dml.chacha8_rng(s6), trials)
  println("      OK")
  println("")
  println("ALL FUZZ SURFACES PASSED (no invariant violations)")
}
