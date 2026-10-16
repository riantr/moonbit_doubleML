// GENERATED-AT-RUN-TIME PLACEHOLDER. See `pyexample_suite.py`.
//
// MoonBit has no file I/O (measured: `@std/env`, `@std/fs`, `@std/io`,
// `@std/process` do not resolve; builtin `read_file` does not exist), so a
// Python-generated dataset cannot be handed to the port as a file -- it must
// arrive as literals in a compiled `.mbt` source. `main.mbt` references these
// symbols in every build, including the workspace-root `moon build` /
// `moon test` CI runs before this script has ever executed, so a stub is
// committed and the gate overwrites it for one comparison.
//
// `suite_generated()` is 0 here, which is what keeps `sec_pyexample_suite`
// inert: it skips every fit rather than fitting a 3-row panel.
//
// Regenerate with:  python pyexample_suite.py --write
// Restore with:     python pyexample_suite.py --restore

///|
fn suite_generated() -> Int32 {
  0
}

///|
fn suite_n() -> Int32 {
  3
}

///|
fn suite_p() -> Int32 {
  1
}

///|
fn suite_a_x() -> Array[Double] {
  [0.1, 0.2, 0.3]
}

///|
fn suite_a_y() -> Array[Double] {
  [10.0, 11.0, 12.0]
}

///|
fn suite_a_d() -> Array[Double] {
  [1.0, 0.0, 1.0]
}

///|
fn suite_a_s() -> Array[Double] {
  [1.0, 1.0, 0.0]
}

///|
fn suite_a_sig() -> Array[Double] {
  [1.0, 1.0, -1.0]
}

///|
fn suite_b_x() -> Array[Double] {
  [0.1, 0.2, 0.3]
}

///|
fn suite_b_y() -> Array[Double] {
  [10.0, 11.0, 12.0]
}

///|
fn suite_b_d() -> Array[Double] {
  [0.5, 0.4, 0.6]
}

///|
fn suite_b_z() -> Array[Double] {
  [0.5, 0.4, 0.6]
}

///|
fn suite_c_x() -> Array[Double] {
  [0.1, 0.2, 0.3]
}

///|
fn suite_c_y() -> Array[Double] {
  [10.0, 11.0, 12.0]
}

///|
fn suite_c_d() -> Array[Double] {
  [1.0, 0.0, 1.0]
}

///|
fn suite_c_z() -> Array[Double] {
  [1.0, 0.0, 1.0]
}
