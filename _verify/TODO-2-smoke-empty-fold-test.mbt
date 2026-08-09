///|
/// `DoubleMLIRM::fit` must abort when the conditional training subset
/// for the `D = 0` branch is empty. With `D = ones(n)` and
/// `n_folds = 2`, every train fold contains only `D = 1` observations
/// and `cross_fit_irm`'s `require(train_d0.length() > 0)` aborts.
/// This is a verifier-side smoke variant — the `panic_` prefix in the
/// production test name is what allows the project test run to report
/// these as green; renamed to `smoke_` they must fail.
test "smoke_irm_d0_empty" {
  let n = 4
  let p = 2
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = [0.0, 1.0, 2.0, 3.0]
  // All D = 1 -> no train fold has a D = 0 observation.
  let d : Array[Double] = [1.0, 1.0, 1.0, 1.0]
  let data = DoubleMLData::new(x, y, d)
  let _ = DoubleMLIRM::new(data, n_folds=2).fit()
}

///|
/// `DoubleMLIRM::fit` must abort when the conditional training subset
/// for the `D = 1` branch is empty. With `D = zeros(n)` and
/// `n_folds = 2`, every train fold contains only `D = 0` observations
/// and `cross_fit_irm`'s `require(train_d1_only.length() > 0)` aborts.
test "smoke_irm_d1_empty" {
  let n = 4
  let p = 2
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = [0.0, 1.0, 2.0, 3.0]
  // All D = 0 -> no train fold has a D = 1 observation.
  let d : Array[Double] = [0.0, 0.0, 0.0, 0.0]
  let data = DoubleMLData::new(x, y, d)
  let _ = DoubleMLIRM::new(data, n_folds=2).fit()
}

///|
/// `DoubleMLIIVM::fit` must abort when the conditional training subset
/// for the `Z = 0` branch is empty. With `Z = ones(n)` and
/// `n_folds = 2`, every train fold contains only `Z = 1` observations
/// and `cross_fit_iivm`'s `require(train_z0.length() > 0)` aborts.
test "smoke_iivm_z0_empty" {
  let n = 4
  let p = 2
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = [0.0, 1.0, 2.0, 3.0]
  let d : Array[Double] = [0.0, 1.0, 0.0, 1.0]
  // All Z = 1 -> no train fold has a Z = 0 observation.
  let z : Array[Double] = [1.0, 1.0, 1.0, 1.0]
  let data = DoubleMLIIVMData::new(x, y, d, z)
  let _ = DoubleMLIIVM::new(data, n_folds=2).fit()
}

///|
/// `DoubleMLIIVM::fit` must abort when the conditional training subset
/// for the `Z = 1` branch is empty. With `Z = zeros(n)` and
/// `n_folds = 2`, every train fold contains only `Z = 0` observations
/// and `cross_fit_iivm`'s `require(train_z1.length() > 0)` aborts.
test "smoke_iivm_z1_empty" {
  let n = 4
  let p = 2
  let x = Matrix::zeros(n, p)
  let y : Array[Double] = [0.0, 1.0, 2.0, 3.0]
  let d : Array[Double] = [0.0, 1.0, 0.0, 1.0]
  // All Z = 0 -> no train fold has a Z = 1 observation.
  let z : Array[Double] = [0.0, 0.0, 0.0, 0.0]
  let data = DoubleMLIIVMData::new(x, y, d, z)
  let _ = DoubleMLIIVM::new(data, n_folds=2).fit()
}
