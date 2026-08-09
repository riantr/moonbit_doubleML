///|
/// Happy-path smoke test: `check(true)` and `require(true)` must be
/// no-ops. This is the same surface covered by the legacy
/// `preconditions_test.mbt`, retained here so that the `check`/`require`
/// alias is exercised from a blackbox test file.
test "check_accepts_valid_preconditions" {
  check(true)
  require(true)
  let matrix = Matrix::from_array([1.0, 2.0, 3.0, 4.0], 2, 2)
  inspect(matrix.rows(), content="2")
  let folds = kfold(4, 2, 3141)
  inspect(folds.length(), content="2")
}

///|
/// `matvec` must abort when the matrix column count does not match the
/// vector length. The panic path goes through `require(a.ncols ==
/// x.length())` inside `matrix.mbt`; the auto-injected `SourceLoc` from
/// `check.mbt` is what populates the abort message.
test "panic_matvec_length_mismatch" {
  // matmul/matvec/dot dimension mismatch
  let _ = matvec(Matrix::zeros(2, 2), [1.0])
}

///|
/// `cholesky` must abort when the pivot is non-positive. The panic path
/// goes through `require(diag > 0.0)` inside `linalg.mbt`.
test "panic_cholesky_non_psd" {
  // Pass a non-positive-definite matrix; cholesky must abort.
  let bad = Matrix::from_array([1.0, 2.0, 2.0, 1.0], 2, 2)
  let _ = cholesky(bad)
}

///|
/// `DoubleMLPLR::coef` must abort when called before `fit()`. The panic
/// path goes through `require(self.fitted)` inside `plr.mbt`.
test "panic_plr_coef_before_fit" {
  let data = DoubleMLData::new(Matrix::zeros(4, 1), [0.0, 1.0, 0.0, 1.0], [
    0.0, 1.0, 0.0, 1.0,
  ])
  let model = DoubleMLPLR::new(data, n_folds=2)
  let _ = model.coef()
}

///|
/// `DoubleMLIRM::new` must abort when `n_folds` is below the legal
/// minimum (2). The panic path goes through `require(n_folds >= 2)`
/// inside `irm.mbt`.
test "panic_irm_new_n_folds_zero" {
  let data = DoubleMLData::new(Matrix::zeros(4, 1), [0.0, 1.0, 0.0, 1.0], [
    0.0, 1.0, 0.0, 1.0,
  ])
  let _ = DoubleMLIRM::new(data, n_folds=0)
}

// ---------------------------------------------------------------------------
// TODO #6: comprehensive runtime precondition panic coverage.
//
// The four tests above cover a single representative site per category
// (matvec column mismatch, cholesky non-PSD, PLR::coef before fit, IRM
// n_folds below 2). The tests below extend the same `check`/`require`
// precondition surface to twelve additional, distinct production-code
// `require(...)` call sites that previously had no panic-test coverage.
// Each test below exercises a different `file:line` site and is named
// after the panic it is supposed to trigger, so the `panic_` prefix
// still applies.
// ---------------------------------------------------------------------------

///|
/// `Matrix::from_array` must abort when the supplied buffer length does
/// not match the declared `nrows * ncols`. The panic path goes through
/// `require(data.length() == nrows * ncols)` inside `matrix.mbt`. Here
/// the buffer has 3 elements while the declared shape is 2 x 2 = 4.
test "panic_matrix_from_array_length_mismatch" {
  let _ = Matrix::from_array([1.0, 2.0, 3.0], 2, 2)
}

///|
/// `matmul` must abort when the inner dimensions of the two operands do
/// not agree. The panic path goes through `require(a.ncols == b.nrows)`
/// inside `matrix.mbt`. Here `a` is 2 x 3 and `b` is 2 x 2, so
/// `a.ncols (3) != b.nrows (2)`.
test "panic_matmul_inner_dim_mismatch" {
  let a = Matrix::from_array([1.0, 2.0, 3.0, 4.0, 5.0, 6.0], 2, 3)
  let b = Matrix::from_array([1.0, 2.0, 3.0, 4.0], 2, 2)
  let _ = matmul(a, b)
}

///|
/// `matvec_t` (`A^T * x`) must abort when the vector length does not
/// match the matrix row count. The panic path goes through
/// `require(a.nrows == x.length())` inside `matrix.mbt`. Here `a` is
/// 3 x 2 and `x` has length 2, so `a.nrows (3) != x.length() (2)`.
test "panic_matvec_t_dim_mismatch" {
  let a = Matrix::from_array([1.0, 2.0, 3.0, 4.0, 5.0, 6.0], 3, 2)
  let _ = matvec_t(a, [1.0, 2.0])
}

///|
/// `dot` must abort when the two input vectors do not share the same
/// length. The panic path goes through `require(a.length() == b.length())`
/// inside `matrix.mbt`.
test "panic_dot_length_mismatch" {
  let _ = dot([1.0, 2.0, 3.0], [4.0, 5.0])
}

///|
/// `cholesky` must abort when the input matrix is not square (this is
/// the dimension check, separate from the existing
/// `panic_cholesky_non_psd` which exercises the PSD pivot check). The
/// panic path goes through `require(a.nrows == a.ncols)` inside
/// `linalg.mbt`. Here the input is 2 x 3.
test "panic_cholesky_non_square" {
  let bad = Matrix::from_array([1.0, 2.0, 3.0, 4.0, 5.0, 6.0], 2, 3)
  let _ = cholesky(bad)
}

///|
/// `solve_spd` must abort when the right-hand-side vector length does
/// not match the matrix dimension. The panic path goes through
/// `require(a.nrows == b.length())` inside `linalg.mbt`. Here `a` is
/// the 3 x 3 identity matrix and `b` has length 2.
test "panic_solve_spd_rhs_length_mismatch" {
  let a = Matrix::identity(3)
  let _ = solve_spd(a, [1.0, 2.0])
}

///|
/// `DoubleMLData::new` must abort when the treatment vector length does
/// not match the feature row count. The panic path goes through
/// `require(x.nrows == d.length())` inside `data.mbt`. Here `x` has 2
/// rows and `d` has 3 elements.
test "panic_data_d_length_mismatch" {
  let x = Matrix::from_array([1.0, 2.0, 3.0, 4.0], 2, 2)
  let y = [0.0, 1.0]
  let d = [0.0, 1.0, 0.0]
  let _ = DoubleMLData::new(x, y, d)
}

///|
/// `kfold` must abort when the requested number of folds exceeds the
/// observation count. The panic path goes through
/// `require(n_folds <= n_obs)` inside `kfold.mbt`. Here `n_obs = 3`
/// and `n_folds = 5`. (The `n_folds > 0` and `n_obs > 0` sites are not
/// re-tested here to keep this test focused on the third site.)
test "panic_kfold_nfolds_gt_nobs" {
  let _ = kfold(3, 5, 3141)
}

///|
/// `LinearRegression::coefficients` must abort when called before
/// `fit()`. The panic path goes through `require(self.fitted)` inside
/// `linear.mbt`.
test "panic_linear_coefficients_before_fit" {
  let m = LinearRegression::new()
  let _ = m.coefficients()
}

///|
/// `LinearRegression::fit` must abort when the outcome vector length
/// does not match the feature row count. The panic path goes through
/// `require(x.nrows == y.length())` inside `linear.mbt`. Here `x` has
/// 2 rows and `y` has 3 elements.
test "panic_linear_fit_xy_mismatch" {
  let x = Matrix::from_array([1.0, 2.0, 3.0, 4.0], 2, 2)
  let y = [1.0, 2.0, 3.0]
  let _ = LinearRegression::new().fit(x, y)
}

///|
/// `LinearRegression::predict` must abort when the input feature
/// column count does not match the column count used at fit time. The
/// panic path goes through `require(x.ncols == self.n_features())`
/// inside `linear.mbt`. The model is fit on a 1 x 3 matrix, then asked
/// to predict on a 1 x 2 matrix.
test "panic_linear_predict_col_mismatch" {
  let x_train = Matrix::from_array([1.0, 2.0, 3.0], 1, 3)
  let y_train = [1.0]
  let fitted = LinearRegression::new().fit(x_train, y_train)
  let x_wrong = Matrix::from_array([1.0, 2.0], 1, 2)
  let _ = fitted.predict(x_wrong)
}

///|
/// `DoubleMLPLR::new` must abort when `n_rep` is below the legal
/// minimum (1). The panic path goes through `require(n_rep >= 1)`
/// inside `plr.mbt`. (The `n_folds >= 2` and `n_folds <= n_obs` sites
/// have analogous panics; they are not re-tested here to keep this
/// test focused on the third site.)
test "panic_plr_new_n_rep_zero" {
  let data = DoubleMLData::new(Matrix::zeros(4, 1), [0.0, 1.0, 0.0, 1.0], [
    0.0, 1.0, 0.0, 1.0,
  ])
  let _ = DoubleMLPLR::new(data, n_folds=2, n_rep=0)
}

///|
/// `DoubleMLIRM::new` must abort when the propensity clip parameter is
/// non-positive. The panic path goes through
/// `require(propensity_clip > 0.0)` inside `irm.mbt`. (The companion
/// `require(propensity_clip < 0.5)` site is exercised by a separate
/// IIVM test below; this test targets the IRM variant of the lower
/// bound only.)
test "panic_irm_new_propensity_clip_zero" {
  let data = DoubleMLData::new(Matrix::zeros(4, 1), [0.0, 1.0, 0.0, 1.0], [
    0.0, 1.0, 0.0, 1.0,
  ])
  let _ = DoubleMLIRM::new(data, n_folds=2, propensity_clip=0.0)
}

///|
/// `DoubleMLBLP::new` must abort when the basis matrix row count does
/// not match the orthogonal signal length. The panic path goes through
/// `require(basis.rows() == orth_signal.length())` inside
/// `blp_policy.mbt`.
test "panic_blp_basis_length_mismatch" {
  let basis = Matrix::zeros(4, 2)
  let signal = [1.0, 2.0, 3.0]
  let _ = DoubleMLBLP::new(basis, signal)
}

///|
/// `DoubleMLPolicyTree::predict` must abort when called before
/// `fit()`. The panic path goes through `require(self.fitted)` inside
/// `blp_policy.mbt`.
test "panic_policy_tree_predict_before_fit" {
  let x = Matrix::zeros(4, 1)
  let s = [1.0, -1.0, 1.0, -1.0]
  let tree = DoubleMLPolicyTree::new(x, s)
  let _ = tree.predict(x)
}

///|
/// `DoubleMLIIVM::new` must abort when the propensity clip parameter
/// is >= 0.5. The panic path goes through
/// `require(propensity_clip < 0.5)` inside `iivm.mbt:102`. (The companion
/// `require(propensity_clip > 0.0` site has an analogous panic that is
/// already exercised by `panic_irm_new_propensity_clip_zero` for the
/// IRM variant; the IIVM constructor is a separate call site.)
test "panic_iivm_new_propensity_clip_too_large" {
  let x = Matrix::zeros(4, 1)
  let y = [0.0, 1.0, 0.0, 1.0]
  let d = [0.0, 1.0, 0.0, 1.0]
  let z = [1.0, 0.0, 1.0, 0.0]
  let data = DoubleMLIIVMData::new(x, y, d, z)
  let _ = DoubleMLIIVM::new(data, n_folds=2, propensity_clip=0.6)
}

///|
/// `DoubleMLRDD::new` must abort when the bandwidth is non-positive.
/// The panic path goes through `require(bandwidth > 0.0)` inside
/// `rdd.mbt`.
test "panic_rdd_new_bandwidth_zero" {
  let x = Matrix::zeros(4, 1)
  let y = [0.0, 1.0, 0.0, 1.0]
  let d = [0.0, 1.0, 0.0, 1.0]
  let score = [0.1, -0.2, 0.3, -0.4]
  let data = DoubleMLRDDData::new(x, y, d, score)
  let _ = DoubleMLRDD::new(data, bandwidth=0.0)
}
