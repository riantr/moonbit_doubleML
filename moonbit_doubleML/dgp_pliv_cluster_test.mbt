// dgp_pliv_cluster_test.mbt

///|
test "PLIVCluster_returns_correct_shapes" {
  let data = make_pliv_multiway_cluster(500, 20, 1.0, 3141)
  let m = data.x_get()
  inspect(m.rows() == 500, content="true")
  inspect(m.cols() == 20, content="true")
  inspect(data.y_get().length() == 500, content="true")
  inspect(data.d_get().length() == 500, content="true")
  inspect(data.z_get().length() == 500, content="true")
  inspect(data.cluster_a_get().length() == 500, content="true")
  inspect(data.cluster_b_get().length() == 500, content="true")
}

///|
test "PLIVCluster_cluster_ids_in_range" {
  let data = make_pliv_multiway_cluster(500, 20, 1.0, 3141)
  let ca = data.cluster_a_get()
  let cb = data.cluster_b_get()
  for i = 0; i < ca.length(); i = i + 1 {
    inspect(ca[i] >= 0 && ca[i] < 50, content="true")
    inspect(cb[i] >= 0 && cb[i] < 50, content="true")
  }
}

///|
test "PLIVCluster_deterministic_in_seed" {
  let a = make_pliv_multiway_cluster(200, 10, 1.0, 42)
  let b = make_pliv_multiway_cluster(200, 10, 1.0, 42)
  let ya = a.y_get()
  let da = a.d_get()
  let yb = b.y_get()
  let db = b.d_get()
  for i = 0; i < ya.length(); i = i + 1 {
    inspect(ya[i] == yb[i], content="true")
    inspect(da[i] == db[i], content="true")
  }
}
