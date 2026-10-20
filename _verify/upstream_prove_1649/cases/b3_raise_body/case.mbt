// Blocker 3 -- `raise X` in a contracted function body.

// Verbatim from _verify/test-bucket3-raise/raise_test.mbt -- NOT from
// _verify/audit_bucket3_raise/raise_test.mbt, which the records cite
// but which holds the Bucket 2 Double source (see the record's note).

// Audit finding A3 says this shape makes `moonc prove` exit with the
// help-text error rather than a clean diagnostic.

///|
pub suberror SomeError

///|
pub fn foo(x : Int) -> Int raise SomeError where {
  proof_require: x > 0,
} {
  if x <= 0 {
    raise SomeError
  }
  x
}
