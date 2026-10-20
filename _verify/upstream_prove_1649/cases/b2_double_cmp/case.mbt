// Blocker 2 / audit finding 2a -- Double literal and comparison.

// Verbatim from _verify/audit-bucket2-double/double_cmp.mbt, the file
// the records cite.  Tests BOTH restrictions at once: the `<` operator
// on a Double, and the `1.5` Double literal (finding A2, a distinct
// error class the original 4-blocker summary did not name).

///|
pub fn double_cmp(x : Double, n : Int) -> Bool where {
  proof_require: x < 1.5,
  proof_require: n > 0,
  proof_ensure: result => result == (x < 1.5),
} {
  x < 1.5
}
