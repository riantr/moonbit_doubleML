///|
/// 1000 copies of 0.1 summed naively drift to ~99.9999999999986
/// (off by ~1.4e-12) because 0.1 is not exactly representable in IEEE
/// 754. Kahan recovers the exact 100.0 within 1e-10.
test "kahan_sum_matches_naive" {
  let n = 1000
  let arr : Array[Double] = Array::make(n, 0.1)
  let s = kahan_sum(arr)
  // exact 100.0 is 100.0 in double; Kahan should land within 1e-10.
  inspect((s - 100.0).abs() < 1.0e-10, content="true")
  // the value really is 100.0 to the printer's resolution
  inspect(s > 99.99999999, content="true")
  inspect(s < 100.00000001, content="true")
}

///|
/// Cancellation torture test: a 1e16 followed by 4999 ones, a -1e16,
/// and 5000 ones. The exact sum is 9999.0. Naive summation destroys
/// the 1e16 against the -1e16 (each individual `1e16 + 1.0` rounds
/// 1.0 to zero, and `1e16 + (-1e16)` rounds to 0), so naive sum
/// collapses to ~5000. Kahan must recover 9999.0 exactly.
test "kahan_sum_cancellation" {
  let n = 10000
  let arr : Array[Double] = Array::make(n, 1.0)
  arr[0] = 1.0e16
  arr[5000] = -1.0e16
  // indices 1..4999 and 5001..9999 are 1.0 by default.
  let s = kahan_sum(arr)
  // 1e16 + 4999 ones + (-1e16) + 5000 ones = 9999.0
  inspect((s - 9999.0).abs() < 1.0e-6, content="true")
  // and a sanity bound: the answer must be in the right ballpark
  // even if cancellation ate the leading 1e16 spike.
  inspect(s > 9000.0, content="true")
  inspect(s < 11000.0, content="true")
}

///|
/// `kahan_sum([])` must abort via the same `check.mbt:require` surface
/// every other public API in the package uses (n >= 1 precondition).
test "panic_kahan_sum_empty" {
  let _ = kahan_sum([])
}
