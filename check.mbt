///|
/// Runtime precondition used by every public API and numerical kernel.
/// `#callsite(autofill(loc))` instructs the compiler to auto-inject the
/// call-site source location into `loc` at every call, so the abort
/// message always points at the offending line. The `loc~` labelled
/// argument also lets callers forward their own `loc` when wrapping
/// `check` (see `require` below).
#callsite(autofill(loc))
pub fn check(condition : Bool, loc~ : SourceLoc) -> Unit {
  if !condition {
    abort("precondition failed at " + loc.to_string())
  }
}

///|
/// Internal alias of `check`, kept for terse call sites that already read
/// like `require(x == y)`. Forwards the auto-injected `loc` so the abort
/// message still points at the offending source line.
#callsite(autofill(loc))
pub fn require(condition : Bool, loc~ : SourceLoc) -> Unit {
  check(condition, loc~)
}
