// GENERATED-AT-RUN-TIME PLACEHOLDER. See `pyexample_did.py`.
//
// WHY THIS FILE EXISTS EVEN THOUGH IT IS NEVER USED FOR A COMPARISON
// ================================================================
// MoonBit 0.1.20261028 has no file I/O (measured: `@std/env`, `@std/fs`,
// `@std/io`, `@std/process` all fail to resolve -- `Cannot find import
// '@std/env'`; the builtin `read_file` does not exist, error 4021), so
// Python-generated data cannot be handed to the port as a file. It has to
// arrive as literals in a compiled `.mbt` source.
//
// That means the symbol `sec_did_pyexample` in `main.mbt` has to exist in
// every build of this package -- including `moon build` and `moon test` at
// the workspace root, which CI runs on a checkout where `pyexample_did.py`
// has not run. So a tiny placeholder is committed, and the gate overwrites
// it with the real dataset for the duration of one comparison and then
// restores it byte for byte.
//
// The values below are a 3-row stub. If you ever see them in a validator
// output, the fixture was never overwritten and the comparison is vacuous --
// `pyexample_did.py` asserts the row count before trusting a result.
//
// Regenerate with:  python pyexample_did.py --write
// Restore with:     python pyexample_did.py --restore

///|
/// 0 = this is the committed placeholder stub, 1 = the real Python-generated
/// dataset is loaded. `main.mbt` reads it and skips both fits when it is 0, so
/// a run without generation still COMPLETES and the validator can report "the
/// fixture was never generated" -- instead of the emitter dying deep inside a
/// 3-row panel, which is what a bare stub produced (measured: a panic at
/// `require(n_folds <= data.n_obs())`, `did.mbt:276`, n_folds=2 on three
/// observations).
fn pyexample_generated() -> Int32 {
  0
}

///|
fn sz2020_n_obs() -> Int32 {
  3
}

///|
fn sz2020_n_feat() -> Int32 {
  4
}

///|
fn sz2020_x() -> Array[Double] {
  [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2]
}

///|
fn sz2020_y() -> Array[Double] {
  [10.0, 11.0, 12.0]
}

///|
fn sz2020_d() -> Array[Double] {
  [1.0, 0.0, 1.0]
}

///|
/// Its own sentinel, deliberately NOT `pyexample_generated()`. The two gates
/// share one fixture file and splice disjoint halves, so a shared sentinel
/// would mean the SZ2020 writer's value decides whether the CS2021 half runs:
/// measured, that made this gate report "fixture not generated" while the data
/// was sitting right there. Separate sentinels make each half self-contained.
fn cs2021_generated() -> Int32 {
  0
}

///|
fn cs2021_n_obs() -> Int32 {
  3
}

///|
fn cs2021_n_feat() -> Int32 {
  4
}

///|
fn cs2021_x() -> Array[Double] {
  [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2]
}

///|
fn cs2021_y() -> Array[Double] {
  [10.0, 11.0, 12.0]
}

///|
fn cs2021_d() -> Array[Double] {
  [1.0, 0.0, 1.0]
}

///|
fn cs2021_t() -> Array[Int32] {
  [0, 1, 2]
}

///|
fn cs2021_id() -> Array[Int32] {
  [0, 0, 0]
}

///|
fn cs2021_g() -> Array[Int32] {
  [1, 1, 1]
}

///|
/// The comparable (g, t_pre, t_eval) cells, one triple per index. A zero cell
/// count is what keeps the placeholder inert: `sec_did_pyexample_cs2021` loops
/// over `cs2021_n_cells()`, which is 0 here, so nothing is fitted.
fn cs2021_n_cells() -> Int32 {
  0
}

///|
fn cs2021_cell_g(i : Int32) -> Int32 {
  let _ = i
  0
}

///|
fn cs2021_cell_t_pre(i : Int32) -> Int32 {
  let _ = i
  0
}

///|
fn cs2021_cell_t_eval(i : Int32) -> Int32 {
  let _ = i
  0
}
