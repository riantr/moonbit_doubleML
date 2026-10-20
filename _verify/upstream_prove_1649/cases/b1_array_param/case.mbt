// Blocker 1 -- Array[T] in a CONTRACTED FUNCTION PARAMETER.

// Mirrors the shape named in UPSTREAM_ISSUE_01_array_lowering.md
// (`pub fn array_min(arr : Array[Double]) -> Double raise ...`) but
// with Int elements and an Int contract, so the only construct under
// test is the Array[T] lowering: no Double comparison, no raise,
// no foreach, no helper call.

///|
pub fn array_sum(arr : Array[Int]) -> Int where {
  proof_require: arr.length() > 0,
  proof_ensure: result => result >= 0,
} {
  let mut total = 0
  for i = 0; i < arr.length(); i = i + 1 {
    total = total + arr[i]
  }
  total
}
