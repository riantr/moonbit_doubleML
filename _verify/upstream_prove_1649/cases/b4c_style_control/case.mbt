// CONTROL for Blocker 4 -- the C-style rewrite, over the SAME Array.

// The record claims the C-style rewrite 'compiles and proves (no
// errors) under `moon prove`'.  Over Array[Int] it does NOT: the
// C-style form still carries Blocker 1.  Keeping Array fixed and
// changing only the loop form is what isolates the foreach.

///|
pub fn sum_array_c(arr : Array[Int]) -> Int where {
  proof_require: arr.length() > 0,
  proof_ensure: result => result > 0,
} {
  let mut total = 0
  for i = 0; i < arr.length(); i = i + 1 {
    total = total + arr[i]
  }
  total
}
