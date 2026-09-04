// probe_int.mbt -- secondary probe for Pilot 2 to determine whether
// the gap extends to `Double` comparison primitives, or whether it's
// specifically about `Array[T]` indexing. The kfold pilot's FixedArray[Int]
// mirror used `uniq[k] == g` and `arr[i] != b[j]` (Int comparison)
// without issue. This probe uses `FixedArray[Int]` instead of
// `FixedArray[Double]` so the only difference from the failing
// quantile_view is the element type. If this probe lowers correctly,
// the gap is `Double` (specifically the comparison primitive), and
// the migration story changes: even after switching `Array[T]` to
// `FixedArray[T]`, the `Array[Double] -> Double` path still won't
// prove.

///|
/// array_min equivalent with FixedArray[Int] -- the comparison
/// shape mirrors quantile_view.mbt::array_min_view line-for-line,
/// but with Int instead of Double.
pub fn array_min_view_int(
  v : FixedArray[Int],
) -> Int where {
  proof_require: v.length() > 0,
  proof_ensure: result => array_min_view_int_ok(v, result),
} {
  let n = v.length()
  let mut z = v[0]
  for i = 0; i < n; i = i + 1 {
    if v[i] < z {
      z = v[i]
    }
  }
  z
}

///|
test "array_min_view_int_basic" {
  let v : FixedArray[Int] = FixedArray::make(5, 0)
  v[0] = 3
  v[1] = 1
  v[2] = 4
  v[3] = 1
  v[4] = 5
  inspect(array_min_view_int(v), content="1")
}
