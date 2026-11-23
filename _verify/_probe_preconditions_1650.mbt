// Probe for the precondition guards.
//
// COPIED INTO the library package by `_verify_precondition_guards_1650.py`,
// which flips the package to an executable and runs one mode per process.
// The MODE is chosen by the generated `main.mbt`, not by argv, so the
// package needs no extra import.
//
// WHY A PROCESS PER MODE
// ======================
// The difference the probe measures is the difference between two ways a
// bad input can fail:
//
//   a precondition failure -> the library aborts with
//                             "precondition failed at <file>:<line>", or
//                             raises `PreconditionError::Violated`, which
//                             the probe can CATCH;
//   a raw MoonBit panic   -> the process dies with "PanicError", and the
//                             catch never runs.
//
// A probe that only asserted "it failed" could not tell those apart. The
// two abort cases have to be separate processes because an abort kills the
// process it runs in.
//
// Every mode's expectation lives in the verifier, not here: this file
// only makes each outcome OBSERVABLE.

///|
/// A cluster id of -1 must be refused by a precondition, not by an
/// out-of-bounds index into the per-cluster accumulator.
fn probe_cluster_neg() -> Unit raise {
  let residuals = [1.0, 2.0, 3.0]
  let psi_a = [1.0, 2.0, 3.0]
  let ids : Array[Int32] = [-1, 0, 1]
  let r = irm_style_sensitivity_cluster(
    1.0,
    residuals,
    psi_a,
    ids,
    0.05,
    0.05,
  )
  println("PROBE cluster_neg SURVIVED rv=" + r.rv.to_string())
}

///|
/// The same, on the `_from_elements` entry point, which additionally
/// requires `cluster_ids.length() == n`: a SHORT `cluster_ids` used to
/// read past its end.
fn probe_cluster_len() -> Unit raise {
  let residuals = [1.0, 2.0, 3.0]
  let nu2 = [1.0, 1.0, 1.0]
  let rr = [1.0, 1.0, 1.0]
  let ids : Array[Int32] = [0]
  let r = irm_style_sensitivity_cluster_from_elements(
    1.0,
    residuals,
    nu2,
    rr,
    ids,
    0.05,
    0.05,
  )
  println("PROBE cluster_len SURVIVED rv=" + r.rv.to_string())
}

///|
/// The control for the two cluster modes: valid ids must still work.
fn probe_cluster_ok() -> Unit raise {
  let residuals = [1.0, 2.0, 3.0]
  let psi_a = [1.0, 2.0, 3.0]
  let ids : Array[Int32] = [0, 1, 2]
  let r = irm_style_sensitivity_cluster(
    1.0,
    residuals,
    psi_a,
    ids,
    0.05,
    0.05,
  )
  println("PROBE cluster_ok SURVIVED rv=" + r.rv.to_string())
}

///|
/// A negative matrix dimension used to reach `Array::make` with a negative
/// size, which PANICS in `moonbit_make_double_array_raw`.
fn probe_matrix_neg() -> Unit {
  let m = Matrix::zeros(-1, 3)
  println(
    "PROBE matrix_neg SURVIVED rows=" +
    m.rows().to_string() +
    " cols=" +
    m.cols().to_string(),
  )
}

///|
/// Two negative dimensions have a POSITIVE product, so this one did not
/// even panic: it built a matrix whose own `rows()` / `cols()` disagree
/// with its data, silently.
fn probe_matrix_negneg() -> Unit {
  let m = Matrix::zeros(-1, -3)
  println(
    "PROBE matrix_negneg SURVIVED rows=" +
    m.rows().to_string() +
    " cols=" +
    m.cols().to_string(),
  )
}

///|
/// The control for the two matrix modes: valid dimensions must still work.
fn probe_matrix_ok() -> Unit {
  let m = Matrix::zeros(2, 3)
  println(
    "PROBE matrix_ok SURVIVED rows=" +
    m.rows().to_string() +
    " cols=" +
    m.cols().to_string(),
  )
}

///|
/// Dispatch. The generated `main.mbt` calls this with one mode.
fn probe_dispatch(mode : String) -> Unit raise {
  if mode == "cluster_neg" {
    probe_cluster_neg()
  } else if mode == "cluster_len" {
    probe_cluster_len()
  } else if mode == "cluster_ok" {
    probe_cluster_ok()
  } else if mode == "matrix_neg" {
    probe_matrix_neg()
  } else if mode == "matrix_negneg" {
    probe_matrix_negneg()
  } else if mode == "matrix_ok" {
    probe_matrix_ok()
  } else {
    println("PROBE unknown mode " + mode)
  }
}
