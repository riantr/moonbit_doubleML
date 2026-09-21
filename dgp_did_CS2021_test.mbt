// dgp_did_CS2021_test.mbt
//
// Tests for the Callaway-Sant'Anna multi-cohort DID DGP.

///|
test "DIDMulti_returns_correct_shapes" {
  let data = make_did_CS2021(800, 3, 1.0, 3141)
  let y = data.y_get()
  inspect(y.length() > 0, content="true")
  inspect(data.y_get().length() == data.d_get().length(), content="true")
  inspect(data.t_get().length() == data.g_get().length(), content="true")
  inspect(data.g_get().length() == data.id_get().length(), content="true")
  inspect(data.x_get().rows() == y.length(), content="true")
  inspect(data.x_get().cols() == 3, content="true")
  inspect(data.n_groups_get() == 4, content="true")
  inspect(data.n_periods_get() == 4, content="true")
}

///|
test "DIDMulti_treatment_is_binary" {
  let data = make_did_CS2021(800, 3, 1.0, 3141)
  let d = data.d_get()
  for i = 0; i < d.length(); i = i + 1 {
    let v = d[i]
    inspect((v == 0.0) || (v == 1.0), content="true")
  }
}

///|
test "DIDMulti_never_treated_cohort_d_always_zero" {
  let data = make_did_CS2021(800, 3, 1.0, 3141)
  let g = data.g_get()
  let d = data.d_get()
  let mut any_violation = false
  for i = 0; i < g.length(); i = i + 1 {
    if g[i] == 0 && d[i] != 0.0 {
      any_violation = true
      break
    }
  }
  inspect(any_violation == false, content="true")
}

///|
test "DIDMulti_treated_cohorts_have_post_indicator" {
  // For cohort g>=1, d should be 1 at all periods t >= g-1
  // (the upstream tau_g = g - 1 pattern).
  let data = make_did_CS2021(800, 3, 1.0, 3141)
  let g = data.g_get()
  let t = data.t_get()
  let d = data.d_get()
  let mut ok = true
  for i = 0; i < g.length(); i = i + 1 {
    if g[i] >= 1 && t[i] >= g[i] - 1 && d[i] != 1.0 {
      ok = false
      break
    }
  }
  inspect(ok == true, content="true")
}

///|
test "DIDMulti_deterministic_in_seed" {
  let a = make_did_CS2021(800, 3, 1.0, 42)
  let b = make_did_CS2021(800, 3, 1.0, 42)
  let ya = a.y_get()
  let da = a.d_get()
  let yb = b.y_get()
  let db = b.d_get()
  for i = 0; i < ya.length(); i = i + 1 {
    inspect(ya[i] == yb[i], content="true")
    inspect(da[i] == db[i], content="true")
  }
}