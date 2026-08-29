// Entry point: the canonical "DML on a simple partially linear
// regression" example. This reproduces `doubleml.tests.conftest.generate_data_simple`
// in MoonBit and runs the ported `DoubleMLPLR` estimator on the same
// DGP. The true treatment effect is `theta_0 = 1.0`; the estimated
// coefficient should land within a few standard errors of that value.

///|
fn main {
  // -------- generate data --------
  // n = 500, p = 5, theta = 1.0
  // D1 = 1.0 * (uniform > 0.5)
  // D2 = 1.0 * (uniform > 0.5)
  // X  ~ N(0, 1)  shape (n, p)
  // Y  = 1.0 * D1 + X @ ones(p) + N(0, 1)
  let n = 500
  let p = 5
  let theta0 = 1.0
  let seed = 1111
  let rng = @dml.chacha8_rng(seed)
  // build X, D1, D2, eps via a deterministic uniform->normal transform.
  // to keep the port self-contained we use a simple Box-Muller for normals.
  let x_flat : Array[Double] = Array::make(n * p, 0.0)
  let d1 : Array[Double] = Array::make(n, 0.0)
  let d2 : Array[Double] = Array::make(n, 0.0)
  let eps : Array[Double] = Array::make(n, 0.0)
  // generate 2*n*p standard normals + 2*n uniforms via Box-Muller / direct.
  // we use chacha8 to get reproducible bytes; we pack the bits into
  // uniform doubles in [0, 1) and transform to normals via Box-Muller.
  let buf : Array[Double] = []
  // we need n*p normals for X, n normals for eps, and 2n uniforms for D1, D2
  // we generate them via Box-Muller (2 normals per pair of uniforms) plus
  // direct uniforms. To keep things simple we generate enough Box-Muller
  // pairs to cover n*p + n normals, then add extra uniforms for the binary
  // treatments.
  while buf.length() < n * p + n {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe_u1 = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe_u1)).sqrt()
    let theta = 2.0 * 3.141592653589793 * u2
    buf.push(r * @math.cos(theta))
    buf.push(r * @math.sin(theta))
  }
  // add 2n more uniforms for the binary treatments
  for _i = 0; _i < 2 * n; _i = _i + 1 {
    buf.push(rng.double())
  }
  // X gets the first n*p normals
  for i = 0; i < n * p; i = i + 1 {
    x_flat[i] = buf[i]
  }
  // eps gets the next n
  for i = 0; i < n; i = i + 1 {
    eps[i] = buf[n * p + i]
  }
  // D1 and D2 use the next 2n uniforms
  for i = 0; i < n; i = i + 1 {
    let u = buf[n * p + n + 2 * i]
    d1[i] = if u > 0.5 { 1.0 } else { 0.0 }
    let u2 = buf[n * p + n + 2 * i + 1]
    d2[i] = if u2 > 0.5 { 1.0 } else { 0.0 }
  }
  // build Y = theta0 * D1 + X @ 1 + eps
  let y : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let mut s = eps[i]
    for j = 0; j < p; j = j + 1 {
      s = s + x_flat[i * p + j] * 1.0
    }
    y[i] = theta0 * d1[i] + s
  }
  let x_mat = @dml.Matrix::from_array(x_flat, n, p)
  let data = @dml.DoubleMLData::new(x_mat, y, d1)
  // -------- run DML --------
  let model = @dml.DoubleMLPLR::new(data, n_folds=2, n_rep=1, seed=3141)
  let fitted = model.fit()
  let (lo, hi) = fitted.confint()
  println("=== MoonBit DML PLR (partialling out) ===")
  println("true theta_0      = \{theta0}")
  println("estimated theta   = \{fitted.coef()}")
  println("standard error    = \{fitted.se()}")
  println("95% confint       = [\{lo}, \{hi}]")
  println("n_obs             = \{fitted.n_obs()}")
  let model5 = @dml.DoubleMLPLR::new(data, n_folds=2, n_rep=5, seed=3141)
  let fitted5 = model5.fit()
  println("=== MoonBit DML PLR (n_rep=5) ===")
  println("estimated theta (n_rep=5) = \{fitted5.coef()}")
  println("se (n_rep=5) = \{fitted5.se()}")

  // -------- run IRM --------
  // Same DGP works for IRM too: ATE is also theta0.
  let irm = @dml.DoubleMLIRM::new(data, n_folds=2, n_rep=1, seed=3141)
  let irm_fitted = irm.fit()
  let (ilo, ihi) = irm_fitted.confint()
  println("")
  println("=== MoonBit DML IRM (ATE score) ===")
  println("true theta_0      = \{theta0}")
  println("estimated ATE     = \{irm_fitted.coef()}")
  println("standard error    = \{irm_fitted.se()}")
  println("95% confint       = [\{ilo}, \{ihi}]")
  println("n_obs             = \{irm_fitted.n_obs()}")
  let irm5 = @dml.DoubleMLIRM::new(data, n_folds=2, n_rep=5, seed=3141)
  let irm_fitted5 = irm5.fit()
  println("=== MoonBit DML IRM (n_rep=5) ===")
  println("estimated theta (n_rep=5) = \{irm_fitted5.coef()}")
  println("se (n_rep=5) = \{irm_fitted5.se()}")

  // -------- run PLIV --------
  // Build an instrument z = x[:, 0] + xi and add explicit
  // endogeneity `u` to d. The instrument is correlated with d
  // through x[:, 0] but xi is independent of u, so the exclusion
  // restriction holds.
  // DGP: y = alpha * d + x @ 1 + eps
  //      d = 0.5 * x[:, 0] + 0.5 * z + u
  //      z = x[:, 0] + xi
  // generate extra normals for z-noise, d-noise, y-noise via a
  // second Box-Muller pass.
  let iv_pool : Array[Double] = []
  while iv_pool.length() < 3 * n {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let theta = 2.0 * 3.141592653589793 * u2
    iv_pool.push(r * @math.cos(theta))
    iv_pool.push(r * @math.sin(theta))
  }
  let z : Array[Double] = Array::make(n, 0.0)
  let eps_iv : Array[Double] = Array::make(n, 0.0)
  let u_iv : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    // z = x[:, 0] + 0.5 * (independent noise)
    z[i] = x_mat.get(i, 0) + 0.5 * iv_pool[i]
    u_iv[i] = 0.3 * iv_pool[n + i]
    eps_iv[i] = 0.3 * iv_pool[2 * n + i]
  }
  let d_iv : Array[Double] = Array::make(n, 0.0)
  let y_iv : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let mut d_part = 0.5 * x_mat.get(i, 0) + 0.5 * z[i] + u_iv[i]
    for j = 1; j < p; j = j + 1 {
      d_part = d_part + 0.1 * x_mat.get(i, j)
    }
    d_iv[i] = d_part
    let mut s = eps_iv[i]
    for j = 0; j < p; j = j + 1 {
      s = s + x_mat.get(i, j)
    }
    y_iv[i] = theta0 * d_iv[i] + s
  }
  let pliv_data = @dml.DoubleMLPLIVData::new(x_mat, y_iv, d_iv, z)
  let pliv = @dml.DoubleMLPLIV::new(pliv_data, n_folds=2, n_rep=1, seed=3141)
  let pliv_fitted = pliv.fit()
  let (plo, phi_) = pliv_fitted.confint()
  println("")
  println("=== MoonBit DML PLIV (partialling out, single IV) ===")
  println("true theta_0      = \{theta0}")
  println("estimated theta   = \{pliv_fitted.coef()}")
  println("standard error    = \{pliv_fitted.se()}")
  println("95% confint       = [\{plo}, \{phi_}]")
  println("n_obs             = \{pliv_fitted.n_obs()}")
  let pliv5 = @dml.DoubleMLPLIV::new(pliv_data, n_folds=2, n_rep=5, seed=3141)
  let pliv_fitted5 = pliv5.fit()
  println("=== MoonBit DML PLIV (n_rep=5) ===")
  println("estimated theta (n_rep=5) = \{pliv_fitted5.coef()}")
  println("se (n_rep=5) = \{pliv_fitted5.se()}")

  // -------- run IIVM --------
  // Build an IIVM DGP:
  //   z ~ Bernoulli(0.5)
  //   d = 1{alpha * z + v > 0}
  //   y = theta * d + x @ 1 + eps
  // Re-use the existing x and draw a fresh batch of normals.
  let alpha_z = 0.5
  let iivm_pool : Array[Double] = []
  while iivm_pool.length() < 2 * n {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let theta_ = 2.0 * 3.141592653589793 * u2
    iivm_pool.push(r * @math.cos(theta_))
    iivm_pool.push(r * @math.sin(theta_))
  }
  let z_iivm : Array[Double] = Array::make(n, 0.0)
  let v_iivm : Array[Double] = Array::make(n, 0.0)
  let eps_iivm : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    z_iivm[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    v_iivm[i] = iivm_pool[i]
    eps_iivm[i] = 0.3 * iivm_pool[n + i]
  }
  let d_iivm : Array[Double] = Array::make(n, 0.0)
  let y_iivm : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let score = alpha_z * z_iivm[i] + v_iivm[i]
    d_iivm[i] = if score > 0.0 { 1.0 } else { 0.0 }
    let mut s = eps_iivm[i]
    for j = 0; j < p; j = j + 1 {
      s = s + x_mat.get(i, j)
    }
    y_iivm[i] = theta0 * d_iivm[i] + s
  }
  let iivm_data = @dml.DoubleMLIIVMData::new(x_mat, y_iivm, d_iivm, z_iivm)
  let iivm = @dml.DoubleMLIIVM::new(iivm_data, n_folds=2, n_rep=1, seed=3141)
  let iivm_fitted = iivm.fit()
  let (ilo_, ihi_) = iivm_fitted.confint()
  println("")
  println("=== MoonBit DML IIVM (LATE score) ===")
  println("true LATE         = \{theta0}")
  println("estimated LATE    = \{iivm_fitted.coef()}")
  println("standard error    = \{iivm_fitted.se()}")
  println("95% confint       = [\{ilo_}, \{ihi_}]")
  println("n_obs             = \{iivm_fitted.n_obs()}")
  let iivm5 = @dml.DoubleMLIIVM::new(iivm_data, n_folds=2, n_rep=5, seed=3141)
  let iivm_fitted5 = iivm5.fit()
  println("=== MoonBit DML IIVM (n_rep=5) ===")
  println("estimated theta (n_rep=5) = \{iivm_fitted5.coef()}")
  println("se (n_rep=5) = \{iivm_fitted5.se()}")

  // -------- run DID --------
  // Simple DID DGP: y = y_post - y_pre = theta * d + noise.
  let d_did : Array[Double] = Array::make(n, 0.0)
  let y_did : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    // propensity: linear in x[:,0]
    let p_x = 0.3 + 0.2 * x_mat.get(i, 0)
    let p_x_ = if p_x < 0.05 { 0.05 } else if p_x > 0.95 { 0.95 } else { p_x }
    d_did[i] = if rng.double() < p_x_ { 1.0 } else { 0.0 }
    y_did[i] = theta0 * d_did[i] + 0.3 * (i + 1).to_double() / n.to_double()
  }
  let did_data = try
    @dml.DoubleMLDIDData::new(x_mat, y_did, d_did)
  catch {
    @dml.DIDDataError::NonBinaryTreatment(i) =>
      abort(
        "DoubleMLDIDData.d must be binary {0, 1} (index " +
        i.to_string() +
        ")",
      )
  }
  let did = @dml.DoubleMLDID::new(did_data, n_folds=2, n_rep=1, seed=3141)
  let did_fitted = did.fit()
  let (dlo, dhi_) = did_fitted.confint()
  println("")
  println("=== MoonBit DML DID (observational score) ===")
  println("true theta_0      = \{theta0}")
  println("estimated theta   = \{did_fitted.coef()}")
  println("standard error    = \{did_fitted.se()}")
  println("95% confint       = [\{dlo}, \{dhi_}]")
  println("n_obs             = \{did_fitted.n_obs()}")
  let did5 = @dml.DoubleMLDID::new(did_data, n_folds=2, n_rep=5, seed=3141)
  let did_fitted5 = did5.fit()
  println("=== MoonBit DML DID (n_rep=5) ===")
  println("estimated theta (n_rep=5) = \{did_fitted5.coef()}")
  println("se (n_rep=5) = \{did_fitted5.se()}")

  // -------- run SSM --------
  // Simple SSM DGP (MAR):
  //   d ~ Bernoulli(0.5)
  //   s = 1{d + x[:, 0] + v > 0}
  //   y (observed iff s=1) = theta * d + 0.3 * x[:, 0] * d + noise
  let ssm_pool : Array[Double] = []
  while ssm_pool.length() < 2 * n {
    let u1 = rng.double()
    let u2 = rng.double()
    let safe = if u1 < 1.0e-12 { 1.0e-12 } else { u1 }
    let r = (-2.0 * @math.ln(safe)).sqrt()
    let t = 2.0 * 3.141592653589793 * u2
    ssm_pool.push(r * @math.cos(t))
    ssm_pool.push(r * @math.sin(t))
  }
  let d_ssm : Array[Double] = Array::make(n, 0.0)
  let s_ssm : Array[Double] = Array::make(n, 0.0)
  let y_ssm : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    d_ssm[i] = if rng.double() > 0.5 { 1.0 } else { 0.0 }
    let mut linear = d_ssm[i] + 0.5 * x_mat.get(i, 0) + ssm_pool[i]
    for j = 1; j < p; j = j + 1 {
      linear = linear + 0.05 * x_mat.get(i, j)
    }
    s_ssm[i] = if linear > 0.0 { 1.0 } else { 0.0 }
    let noise = 0.3 * ssm_pool[n + i]
    let y_part = theta0 * d_ssm[i] + 0.3 * x_mat.get(i, 0) * d_ssm[i]
    y_ssm[i] = y_part + noise
  }
  let ssm_data = @dml.DoubleMLSSMData::new(x_mat, y_ssm, d_ssm, s_ssm)
  let ssm = @dml.DoubleMLSSM::new(ssm_data, n_folds=2, n_rep=1, seed=3141)
  let ssm_fitted = ssm.fit()
  let (slo_, shi_) = ssm_fitted.confint()
  println("")
  println("=== MoonBit DML SSM (MAR score) ===")
  println("true theta_0      = \{theta0}")
  println("estimated theta   = \{ssm_fitted.coef()}")
  println("standard error    = \{ssm_fitted.se()}")
  println("95% confint       = [\{slo_}, \{shi_}]")
  println("n_obs             = \{ssm_fitted.n_obs()}")

  // -------- run LPQ --------
  // LPQ (Local Potential Quantile) DGP: y = d + (i % 100) / 100
  // with z = d (all compliers, full take-up). For treatment=1, the
  // treated quantile at q=0.5 should be ≈ 1.49 — matches
  // lpq_test.mbt and validate_quantile_with_python.py.
  let d_lpq : Array[Double] = Array::make(n, 0.0)
  let z_lpq : Array[Double] = Array::make(n, 0.0)
  let y_lpq : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    z_lpq[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
    d_lpq[i] = z_lpq[i] // all compliers
    y_lpq[i] = d_lpq[i] + (i % 100).to_double() / 100.0
  }
  let lpq_x = @dml.Matrix::zeros(n, 1)
  let lpq_data = @dml.DoubleMLLPQData::new(lpq_x, y_lpq, d_lpq, z_lpq)
  let lpq_fitted = @dml.DoubleMLLPQ::new(
    lpq_data,
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=3141,
  ).fit()
  println("")
  println("=== MoonBit DML LPQ (complier potential median, treatment=1) ===")
  println("true complier q0.5 = 1.49")
  println("estimated theta   = \{lpq_fitted.coef()}")
  println("standard error    = \{lpq_fitted.se()}")
  // -------- run PQ --------
  // PQ (potential quantile) for the same LPQ-style DGP:
  // treated median y | d=1 should be ~ 1.49 (matches
  // quantile_test.mbt and validate_quantile_with_python.py).
  // The new IPW bisection (Bug #3) drops the per-iteration
  // g cross-fit, so the per-fit cross-fit count drops from
  // 53 to 3.
  let pq_x = @dml.Matrix::zeros(n, 1)
  let d_pq : Array[Double] = Array::make(n, 0.0)
  let y_pq : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    d_pq[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
    y_pq[i] = d_pq[i] + (i % 100).to_double() / 100.0
  }
  let pq_data = @dml.DoubleMLData::new(pq_x, y_pq, d_pq)
  let pq_fitted = @dml.DoubleMLPQ::new(
    pq_data,
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=3141,
  ).fit()
  println("")
  println(
    "=== MoonBit DML PQ (potential median, treatment=1, Bug #3 IPW bisection) ===",
  )
  println("true potential q0.5 (treated) = 1.49")
  println("estimated theta   = \{pq_fitted.coef()}")
  println("standard error    = \{pq_fitted.se()}")
  // -------- run QTE --------
  // QTE = theta_d1 - theta_d0. The new (Bug #2) SE uses the
  // full covariance between psi_d1 and psi_d0 (not the
  // quadrature `sqrt(SE_1^2 + SE_0^2)` which assumes zero
  // covariance). For this DGP the cross-covariance is small
  // so the new SE is very close to the buggy SE; for DGPs
  // with larger cross-covariance the new SE can be larger
  // or smaller than the buggy one (see `qte_se_*` tests).
  let qte_fitted = @dml.DoubleMLQTE::new(
    pq_data,
    quantiles=[0.25, 0.5, 0.75],
    n_folds=2,
    seed=3141,
  ).fit()
  println("")
  println(
    "=== MoonBit DML QTE (potential quantile difference, Bug #2 covariance SE) ===",
  )
  println("true QTE (q=0.25, 0.5, 0.75) = [0.99, 0.99, 0.99] (location shift)")
  println(
    "QTE coefficients = [\{qte_fitted.coefs()[0]}, \{qte_fitted.coefs()[1]}, \{qte_fitted.coefs()[2]}]",
  )
  println(
    "QTE SEs = [\{qte_fitted.ses()[0]}, \{qte_fitted.ses()[1]}, \{qte_fitted.ses()[2]}]",
  )
  // Also print the per-treatment PQ SEs for reference and the
  // pre-fix buggy quadrature SE for comparison. The post-fix
  // QTE SE is `se = sqrt(mean((psi_d1/deriv_d1 - psi_d0/deriv_d0)^2)/n)`;
  // the pre-fix SE was `sqrt(se_d1^2 + se_d0^2)`.
  let pq_se_1 = @dml.DoubleMLPQ::new(
    pq_data,
    treatment=1.0,
    quantile=0.5,
    n_folds=2,
    seed=3141,
  ).fit()
  let pq_se_0 = @dml.DoubleMLPQ::new(
    pq_data,
    treatment=0.0,
    quantile=0.5,
    n_folds=2,
    seed=3141,
  ).fit()
  let se_buggy = (pq_se_1.se() * pq_se_1.se() + pq_se_0.se() * pq_se_0.se()).sqrt()
  println(
    "PQ SE (treat=1) = \{pq_se_1.se()}, PQ SE (treat=0) = \{pq_se_0.se()}",
  )
  println("Pre-fix buggy QTE SE (q=0.5) = sqrt(SE_1^2 + SE_0^2) = \{se_buggy}")

  // -------- run BLP --------
  // BLP: y = 2 + 3*x (linear), so the slope and intercept should
  // match exactly. The SEs should be tiny for the (n=500, p=2)
  // well-conditioned design.
  let blp_x = @dml.Matrix::zeros(n, 1)
  let blp_s : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let z = (i.to_double() - (n / 2).to_double()) / (n / 2).to_double()
    blp_x.set(i, 0, z)
    blp_s[i] = 2.0 + 3.0 * z
  }
  let blp_fitted = @dml.DoubleMLBLP::new(blp_x, blp_s).fit()
  let blp_c = blp_fitted.coef()
  let blp_se = blp_fitted.se()
  println("")
  println("=== MoonBit BLP (per-coefficient SE, Bug #5) ===")
  println("true intercept=2, slope=3")
  println("coef = [\{blp_c[0]}, \{blp_c[1]}]")
  println("se   = [\{blp_se[0]}, \{blp_se[1]}]")

  // -------- run PolicyTree --------
  // PolicyTree: signal = -1 if z<0 else +1. With the new
  // variance-reduction gain, the optimal split is at z=0, with
  // left_treatment=0 (signal ≤ 0) and right_treatment=1.
  let pt_x = @dml.Matrix::zeros(n, 1)
  let pt_s : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let z = (i.to_double() - (n / 2).to_double()) / (n / 2).to_double()
    pt_x.set(i, 0, z)
    pt_s[i] = if z < 0.0 { -1.0 } else { 1.0 }
  }
  let pt_fitted = @dml.DoubleMLPolicyTree::new(pt_x, pt_s).fit()
  println("")
  println("=== MoonBit PolicyTree (Bug #8: variance-reduction gain) ===")
  println("split_feature = \{pt_fitted.split_feature()}")
  println("split_value   = \{pt_fitted.split_value()}")
  let pt_pred = pt_fitted.predict(@dml.Matrix::from_array([-0.5, 0.5], 2, 1))
  println("predict([-0.5, 0.5]) = [\{pt_pred[0]}, \{pt_pred[1]}]")

  // -------- run RDD --------
  // Sharp RD: y = 2 + u + 2 * d where d = 1{u >= 0}. The local
  // linear intercept jump at the cutoff should be 2.0.
  let rdd_x = @dml.Matrix::zeros(n, 1)
  let rdd_y : Array[Double] = Array::make(n, 0.0)
  let rdd_d : Array[Double] = Array::make(n, 0.0)
  let rdd_score : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u = (i.to_double() + 0.5) / (n / 2).to_double() - 1.0
    rdd_score[i] = u
    rdd_d[i] = if u >= 0.0 { 1.0 } else { 0.0 }
    rdd_y[i] = 2.0 + u + 2.0 * rdd_d[i]
  }
  let rdd_sharp = @dml.DoubleMLRDD::new(
    @dml.DoubleMLRDDData::new(rdd_x, rdd_y, rdd_d, rdd_score),
    bandwidth=0.5,
  ).fit()
  println("")
  println("=== MoonBit RDD (sharp, Bug #6: kernel weights in fit) ===")
  println("true jump = 2.0")
  println("coef = \{rdd_sharp.coef()}")
  println("se   = \{rdd_sharp.se()}")

  // Fuzzy RD: y = u + 0.6 * d, d = 0.7{u >= 0} + 0.5{u < 0}.
  // The Wald ratio = (raw / jump) ≈ 0.6.
  let rdd_d_fz : Array[Double] = Array::make(n, 0.0)
  let rdd_y_fz : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let u = (i.to_double() + 0.5) / (n / 2).to_double() - 1.0
    rdd_d_fz[i] = if u >= 0.0 { 0.7 } else { 0.5 }
    rdd_y_fz[i] = u + 0.6 * rdd_d_fz[i]
  }
  let rdd_fuzzy = @dml.DoubleMLRDD::new(
    @dml.DoubleMLRDDData::new(rdd_x, rdd_y_fz, rdd_d_fz, rdd_score),
    bandwidth=0.5,
    fuzzy=true,
  ).fit()
  println("")
  println("=== MoonBit RDD (fuzzy, Bug #7: delta-method cross-cov) ===")
  println("true Wald = 0.6")
  println("coef = \{rdd_fuzzy.coef()}")
  println("se   = \{rdd_fuzzy.se()}")
}
