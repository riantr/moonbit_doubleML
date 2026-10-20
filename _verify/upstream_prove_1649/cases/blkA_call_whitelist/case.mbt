// New Block A -- the proof-callable whitelist.

// A call to a function that is not #proof_pure / #proof_callable
// inside a contracted body.  The record lists the calls it blocks:
// seed_to_bytes, @random.Rand::chacha8, Bytes::from_array,
// Array::make, Array::makei, perm.swap, rng.int, the .push methods
// and Fold::new.  `helper` below is the minimal user-code instance of
// the same shape.

///|
pub fn helper(x : Int) -> Int {
  x + 1
}

///|
pub fn uses_helper(x : Int) -> Int where {
  proof_require: x > 0,
  proof_ensure: result => result > 1,
} {
  helper(x)
}
