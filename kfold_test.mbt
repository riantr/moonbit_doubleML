///|
test "kfold_partitions_n_obs" {
  let n = 10
  let folds = kfold(n, 5, 42)
  inspect(folds.length(), content="5")
  // train and test for each fold together contain every index in [0, n)
  let seen : Array[Bool] = Array::make(n, false)
  for fold in folds {
    for i in fold.test_indices() {
      ignore(seen[i])
      seen[i] = true
    }
    for i in fold.train_indices() {
      ignore(seen[i])
      seen[i] = true
    }
  }
  for v in seen {
    inspect(v, content="true")
  }
}

///|
test "kfold_test_size_sum_equals_n" {
  let n = 13
  let folds = kfold(n, 4, 1)
  // test sizes should be ceil(13/4)=4, 3, 3, 3 -> sum 13
  let mut total = 0
  for fold in folds {
    total = total + fold.test_indices().length()
  }
  inspect(total, content="13")
}

///|
test "kfold_reproducible" {
  let f1 = kfold(20, 4, 3141)
  let f2 = kfold(20, 4, 3141)
  for i = 0; i < f1.length(); i = i + 1 {
    inspect(
      f1[i].test_indices().length() == f2[i].test_indices().length(),
      content="true",
    )
    for j = 0; j < f1[i].test_indices().length(); j = j + 1 {
      inspect(
        f1[i].test_indices()[j] == f2[i].test_indices()[j],
        content="true",
      )
    }
  }
}

///|
test "kfold_different_seeds_differ" {
  let f1 = kfold(20, 4, 3141)
  let f2 = kfold(20, 4, 9999)
  // at least one fold's first test index should differ
  let mut any_diff = false
  for i = 0; i < f1.length(); i = i + 1 {
    if f1[i].test_indices()[0] != f2[i].test_indices()[0] {
      any_diff = true
      break
    }
  }
  inspect(any_diff, content="true")
}

///|
test "slice_vector" {
  let v = [10.0, 20.0, 30.0, 40.0, 50.0]
  let out = slice_vector(v, [2, 0, 4])
  inspect(out.length(), content="3")
  inspect(out[0], content="30")
  inspect(out[1], content="10")
  inspect(out[2], content="50")
}

///|
test "slice_matrix_rows" {
  let m = Matrix::from_array([1.0, 2.0, 3.0, 4.0, 5.0, 6.0], 3, 2)
  let out = slice_matrix_rows(m, [2, 0])
  inspect(out.rows(), content="2")
  inspect(out.cols(), content="2")
  inspect(out.get(0, 0), content="5")
  inspect(out.get(0, 1), content="6")
  inspect(out.get(1, 0), content="1")
  inspect(out.get(1, 1), content="2")
}
