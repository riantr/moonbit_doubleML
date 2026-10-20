// CONTROL -- no restricted construct at all.

// If this case does not reach the Why3 stage with zero frontend
// errors, the harness cannot discriminate a proof failure from a
// platform failure, and every other case is void.

///|
pub fn sum_to(n : Int) -> Int where {
  proof_require: n > 0,
  proof_ensure: result => result > 0,
} {
  let mut total = 0
  for i = 0; i < n; i = i + 1 {
    total = total + i
  }
  total
}
