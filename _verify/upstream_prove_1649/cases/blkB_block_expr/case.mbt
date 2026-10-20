// New Block B -- block and literal expressions in a contracted body.

// The v0.48.0 cascade wrap, copied from the production shape in
// moonbit_doubleML/plr.mbt: `try { require(...) } catch { ... abort(...) }`
// is the FIRST statement of every DML estimator body, so this shape is
// the one that blocks the whole main package.

// The `require` call is replaced by an inline raise: `require` lives
// in the main package and is unbound in a standalone case, so the
// first version of this case measured the wrong thing entirely.

///|
pub suberror PreconditionError {
  Violated(String)
}

///|
pub fn with_try(x : Int) -> Int where {
  proof_require: x > 0,
  proof_ensure: result => result == x,
} {
  try {
    if x <= 0 {
      raise PreconditionError::Violated("x")
    }
    x
  } catch {
    PreconditionError::Violated(loc) =>
      abort("precondition failed at " + loc)
  }
}
