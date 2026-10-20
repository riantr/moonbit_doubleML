// Blocker 1 -- Array[T] in a STRUCT FIELD.

// The other half of Blocker 1: the record says the lowering gap is
// 'not struct-field-specific', so the field shape is tested
// separately from the parameter shape above.

///|
pub struct Holder {
  data : Array[Int]
}

///|
pub fn holder_sum(h : Holder) -> Int where {
  proof_require: h.data.length() > 0,
  proof_ensure: result => result >= 0,
} {
  let mut total = 0
  for i = 0; i < h.data.length(); i = i + 1 {
    total = total + h.data[i]
  }
  total
}
