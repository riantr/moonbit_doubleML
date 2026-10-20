// CONTROL for Blocker 1 -- FixedArray + C-style range.

// This is the shape the `_prove_pilot` package actually uses, and the
// shape the record says the workaround 'works'.  It differs from
// b1_array_param in exactly two ways: FixedArray instead of Array,
// and the C-style range.  If this case reaches the Why3 stage with
// zero frontend errors, then the Array[T] cases fail because of
// Array[T] and not because of the harness.

///|
pub fn sum_fixed(arr : FixedArray[Int]) -> Int where {
  proof_require: arr.length() > 0,
  proof_ensure: result => result >= 0,
} {
  let mut total = 0
  for i = 0; i < arr.length(); i = i + 1 {
    total = total + arr[i]
  }
  total
}
