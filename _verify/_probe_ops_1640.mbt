/// Re-measure the operator bit-exactness table on the CURRENT toolchain.
///
/// The README's determinism table ("sqrt 6/6, cos 6/6, sin 6/6, ln 5/6")
/// was measured on `moon 0.1.20261012` vs CPython 3.14. The local toolchain
/// has moved on, so the table has to be re-measured or qualified.
///
/// Prints `op arg moonvalue` lines; the Python side compares the value's
/// IEEE-754 bit pattern against its own.
fn main {
  let args = [0.5, 1.5, 2.0, 3.0, 7.25, 10.0]
  for a in args {
    println("sqrt " + a.to_string() + " " + a.sqrt().to_string())
    println("cos " + a.to_string() + " " + @math.cos(a).to_string())
    println("sin " + a.to_string() + " " + @math.sin(a).to_string())
    println("ln " + a.to_string() + " " + @math.ln(a).to_string())
  }
}
