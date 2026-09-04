// quantile_view.mbt -- DISABLED in Pilot 2.
//
// The `array_min_view` / `array_max_view` mirrors of
// `quantile.mbt::array_min` / `array_max` were removed because
// the MoonBit proof pipeline (v0.10.11) rejects `Double`
// comparison primitives (`<`, `>`, `<=`, `>=`, `==`) in both the
// logic body and the contracted function body. This is a SECOND
// toolchain gap beyond the `Array[T] -> array` lowering gap
// identified in the kfold pilot.
//
// The Int-version probe (`probe_int.mbt` in this package) is
// kept because it sidesteps the Double gap and lets us determine
// whether the `Array[T] -> array` gap is the only thing in the
// way. If `moon prove _prove_pilot2` succeeds on `probe_int.mbt`,
// we have a clean signal: the gap is specifically `Array[T]`,
// and the `Double` gap is a separate concern.
//
// See `QUANTILE_HANDOFF.md` for the full reproduction and
// recommended migration strategy.
