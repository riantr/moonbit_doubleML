// Blocker 4 -- `for x in arr` in a contracted body.

// Verbatim from _verify/audit_bucket4_foreach/foreach_test.mbt.  Audit
// finding A4 says this also exits with the help-text error.

///|
pub fn sum_array(arr : Array[Int]) -> Int where {
  proof_require: arr.length() > 0,
  proof_ensure: result => result > 0,
} {
  let mut total = 0
  for x in arr {
    total = total + x
  }
  total
}
