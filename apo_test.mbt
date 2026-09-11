///|
test "apo_recovers_average_potential_outcome" {
  let n = 400
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    d[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
    y[i] = 2.0 + 3.0 * d[i]
  }
  let data = DoubleMLData::new(x, y, d)
  let apo1 = DoubleMLAPO::new(data, treatment_level=1.0, seed=3141).fit()
  inspect((apo1.coef() - 5.0).abs() < 1.0e-8, content="true")
  inspect(apo1.predictions_g().length(), content="400")
  inspect(apo1.predictions_m().length(), content="400")
}

///|
/// Test helper: count how many of the `indices` rows in `arr` equal
/// `target`. Used by `kfold_stratified_balances_each_stratum` to
/// verify the fold partition is balanced per stratum.
fn count_eq(indices : Array[Int], arr : Array[Double], target : Double) -> Int {
  let mut n = 0
  for k = 0; k < indices.length(); k = k + 1 {
    if arr[indices[k]] == target {
      n = n + 1
    }
  }
  n
}

///|
test "apos_fits_each_treatment_level" {
  let n = 400
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    d[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
    y[i] = 2.0 + 3.0 * d[i]
  }
  let fitted = DoubleMLAPOS::new(
    DoubleMLData::new(x, y, d),
    [0.0, 1.0],
    seed=3141,
  ).fit()
  let coefs = fitted.coefs()
  inspect((coefs[0] - 2.0).abs() < 1.0e-8, content="true")
  inspect((coefs[1] - 5.0).abs() < 1.0e-8, content="true")
  inspect(fitted.ses().length(), content="2")
}

///|
/// v0.49.0: causal_contrast returns the level-by-level difference
/// (and SE) between each treatment level and the supplied reference.
test "apos_causal_contrast_with_reference" {
  let n = 400
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    d[i] = if i % 2 == 0 { 1.0 } else { 0.0 }
    y[i] = 2.0 + 3.0 * d[i]
  }
  let fitted = DoubleMLAPOS::new(
    DoubleMLData::new(x, y, d),
    [0.0, 1.0],
    seed=3141,
  ).fit()
  // Reference level 0: contrast is coefs[1] - coefs[0] = 5 - 2 = 3.
  let contrasts = fitted.causal_contrast([0.0])
  inspect(contrasts.length(), content="1")
  // Each row has 2*(n_treatment_levels) - 1 entries: the reference
  // slot is 0.0 (delta = 0 by definition) and the other slots are
  // (delta, se) pairs. With n_treatment_levels = 2, that's
  // 1 + 2*(2-1) = 3 entries.
  let row0 = contrasts[0]
  inspect(row0.length(), content="3")
  inspect((row0[0] - 0.0).abs() < 1.0e-8, content="true")
  inspect((row0[1] - 3.0).abs() < 1.0e-8, content="true")
  // The trailing entry is the SE of the contrast (positive).
  inspect(row0[2] > 0.0, content="true")
}

///|
/// v0.49.0: causal_contrast accepts a single ref level (scalar) via
/// the same array-form accessor (the upstream Python allows either).
test "apos_accessors_match" {
  let n = 200
  let x = Matrix::zeros(n, 2)
  let y = Array::make(n, 0.0)
  let d : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    d[i] = (i % 3).to_double()
    y[i] = d[i] * 2.0 + 1.0
  }
  let fitted = DoubleMLAPOS::new(
    DoubleMLData::new(x, y, d),
    [0.0, 1.0, 2.0],
    seed=3141,
  ).fit()
  inspect(fitted.n_treatment_levels(), content="3")
  inspect(fitted.treatment_levels().length(), content="3")
  inspect(fitted.treatment_levels()[0], content="0")
  inspect(fitted.treatment_levels()[1], content="1")
  inspect(fitted.treatment_levels()[2], content="2")
  inspect(fitted.fitted(), content="true")
}

///|
/// v0.49.0: kfold_stratified helper produces balanced folds per
/// stratum. Use a 3-level treatment assignment; each fold should
/// contain ~equal proportions of each level.
test "kfold_stratified_balances_each_stratum" {
  let n = 60
  let strata : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    strata[i] = (i % 3).to_double() // three levels: 0, 1, 2
  }
  let folds = kfold_stratified(n, strata, 5, 3141)
  inspect(folds.length(), content="5")
  // Every fold should have test_size = n / n_folds = 12 (no remainder
  // since 60 % 5 == 0).
  for f = 0; f < folds.length(); f = f + 1 {
    inspect(folds[f].test_indices().length(), content="12")
  }
  // Per fold, count how many rows are in each stratum. Each stratum
  // has n/3 = 20 members, so each fold should have 20/5 = 4 members
  // of each level.
  for f = 0; f < folds.length(); f = f + 1 {
    let te = folds[f].test_indices()
    let c0 = count_eq(te, strata, 0.0)
    let c1 = count_eq(te, strata, 1.0)
    let c2 = count_eq(te, strata, 2.0)
    inspect(c0, content="4")
    inspect(c1, content="4")
    inspect(c2, content="4")
  }
}
