// Demo: the isotonic-regression core (`pava` / PAVA) on fixed
// inputs.
//
// Why fixed inputs and not a seeded DGP: the isotonic fit of a
// sorted vector is the unique minimiser of the weighted sum of
// squared residuals subject to monotonicity. There is no sampling
// involved, so the two sides can be compared exactly instead of
// within Monte-Carlo error -- and they do not have to share an RNG
// stream. Every other cross-check in this repository has to allow
// for that; this one does not, and the tolerance can be 1e-12.
//
// `validate_pava_with_python.py` prints these vectors through
// `sklearn.isotonic.isotonic_regression` and compares elementwise.
// Through v0.103.0 that file raised `NotImplementedError` from both
// of its MoonBit drivers and ended in a hard-coded
// `PAVA cross-check PASS`.

///|
fn main {
  // Each case: (label, y already sorted by x, weights or []).
  //
  // The vectors are chosen to hit different parts of the block
  // stack, not to be pretty:
  //
  //   v0  a single violation that pools everything -> exercises
  //       the "pool and re-check" loop.
  //   v1  already non-decreasing, with a tie -> must come back
  //       unchanged, so a buggy pool that fired on equality would
  //       show up here.
  //   v2  a cascade: 3,2,1 pools down, then 5,4 pools up, and
  //       the 6 at the end must NOT drag the 4.5 block up with
  //       it. This is the case that separates a correct
  //       stack from a "pool only the immediate pair" variant.
  //   v3  a realistic probability profile with a plateau in the
  //       middle, where the fit must stay inside [0, 1].
  //   v4  weighted, with one small weight carrying a large value
  //       -- a bug that drops the weights changes the answer
  //       while leaving v0-v3 untouched.
  let cases : Array[(String, Array[Double], Array[Double])] = [
    ("v0", [0.9, 0.7, 0.8, 0.1], []),
    ("v1", [0.1, 0.3, 0.3, 0.7], []),
    ("v2", [3.0, 2.0, 1.0, 5.0, 4.0, 6.0], []),
    ("v3", [0.01, 0.02, 0.03, 0.9, 0.4, 0.5, 0.6], []),
    ("v4", [0.2, 0.5, 0.1, 0.8], [1.0, 1.0, 0.25, 1.0]),
  ]
  println("=== MoonBit PAVA / isotonic core (fixed inputs) ===")
  for c in cases {
    let (label, y, w) = c
    let fitted = @moonbit_doubleML.pava(y, weights=w)
    if fitted.length() != y.length() {
      abort("pava returned a different length than it was given")
    }
    let parts : Array[String] = []
    for i = 0; i < fitted.length(); i = i + 1 {
      parts.push(fitted[i].to_string())
    }
    println("case[\{label}] n=\{y.length()} pava = \{parts.join(" ")}")
  }
  println("PAVA example done")
}
