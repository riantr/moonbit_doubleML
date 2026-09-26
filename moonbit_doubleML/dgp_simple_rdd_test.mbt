// dgp_simple_rdd_test.mbt
//
// Tests for the simple sharp-RDD DGP.

///|
test "RDD_returns_correct_shapes" {
  let data = make_simple_rdd_dgp(500, 1.0, 3141)
  let x = data.x_get()
  inspect(x.length() == 500, content="true")
  inspect(data.y_get().length() == 500, content="true")
  inspect(data.d_get().length() == 500, content="true")
  inspect(data.score_get().length() == 500, content="true")
  inspect(data.theta_get() == 1.0, content="true")
}

///|
test "RDD_d_is_binary_and_discontinuous_at_zero" {
  let data = make_simple_rdd_dgp(1000, 1.0, 3141)
  let x = data.x_get()
  let d = data.d_get()
  let mut above_zero_count = 0
  let mut above_zero_d_one = 0
  let mut below_zero_d_zero = 0
  for i = 0; i < x.length(); i = i + 1 {
    let v = d[i]
    inspect(v == 0.0 || v == 1.0, content="true")
    if x[i] > 0.0 {
      above_zero_count = above_zero_count + 1
      if v == 1.0 {
        above_zero_d_one = above_zero_d_one + 1
      }
    } else if v == 0.0 {
      below_zero_d_zero = below_zero_d_zero + 1
    }
  }
  // Sharp assignment: D = 1{X > 0} deterministically.
  inspect(above_zero_count == above_zero_d_one, content="true")
  inspect(above_zero_count == 1000 - below_zero_d_zero, content="true")
}

///|
test "RDD_deterministic_in_seed" {
  let a = make_simple_rdd_dgp(200, 1.0, 42)
  let b = make_simple_rdd_dgp(200, 1.0, 42)
  let xa = a.x_get()
  let ya = a.y_get()
  let da = a.d_get()
  let xb = b.x_get()
  let yb = b.y_get()
  let db = b.d_get()
  for i = 0; i < xa.length(); i = i + 1 {
    inspect(xa[i] == xb[i], content="true")
    inspect(ya[i] == yb[i], content="true")
    inspect(da[i] == db[i], content="true")
  }
}

///|
test "RDD_X_in_unit_interval" {
  let data = make_simple_rdd_dgp(500, 1.0, 3141)
  let x = data.x_get()
  for i = 0; i < x.length(); i = i + 1 {
    let v = x[i]
    inspect(v >= -1.0, content="true")
    inspect(v <= 1.0, content="true")
  }
}

///|
test "RDD_values_finite" {
  let data = make_simple_rdd_dgp(500, 1.0, 3141)
  let y = data.y_get()
  for i = 0; i < y.length(); i = i + 1 {
    inspect(y[i] == y[i], content="true")
  }
}
