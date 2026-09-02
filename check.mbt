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

///|
/// Construct a `PreconditionError::Violated(loc)` whose
/// payload is the source location of the **caller**
/// (the `#callsite(autofill(loc))` attribute auto-injects
/// the call-site `SourceLoc` into the `loc` parameter, so
/// the diagnostic message points at the line that called
/// this helper, not at this helper's own definition site).
///
/// Added in v0.47.0 as a forward-compatible hook for the
/// upcoming `check`/`require` → `raise PreconditionError`
/// conversion. Today it has no prod caller (the central
/// `check`/`require` still aborts), so the only usage is
/// the regression test in `check_test.mbt`. In v0.48.0+,
/// `check` will `raise` this error directly and this
/// helper stays as an opt-in builder for callers that
/// want to surface a custom precondition violation
/// without going through the global `check` path.
///
/// The `pub` visibility is required so the `_test` file
/// can call it; see v0.37.0's `apply_calibration` for the
/// same `pub`-but-test-only helper pattern.
#callsite(autofill(loc))
pub fn check_make_violated(loc~ : SourceLoc) -> PreconditionError {
  PreconditionError::Violated(loc)
}
