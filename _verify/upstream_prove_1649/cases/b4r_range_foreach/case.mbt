// Blocker 4 -- `for x in 0..<n`, the single-binder Int range form.

// The record says the same help-text error fires for this form too,
// not just for `for x in arr`.  Tested separately, because the two
// forms are different restrictions in the proof frontend.

///|
pub fn sum_range(n : Int) -> Int where {
  proof_require: n > 0,
  proof_ensure: result => result > 0,
} {
  let mut total = 0
  for x in 0..<n {
    total = total + x
  }
  total
}
