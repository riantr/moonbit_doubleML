///|
/// Pack an integer `seed` into a 32-byte buffer using a 32-bit
/// little-endian encoding of `seed` (as a signed 32-bit integer;
/// `-1` becomes `0xFF FF FF FF`). The four bytes are tiled 8 times
/// to fill the 32-byte key that `chacha8` requires. Distinct
/// integer seeds give distinct byte strings, and the layout is
/// independent of the host endianness.
///
/// Encoding (per byte index 0..3):
///   byte[0] =  seed         & 0xff
///   byte[1] = (seed >> 8)   & 0xff
///   byte[2] = (seed >> 16)  & 0xff
///   byte[3] = (seed >> 24)  & 0xff
///
/// `seed` is a signed 64-bit `Int`; the upper 32 bits are ignored
/// so the 32-bit LE view is well-defined for any seed. For
/// negative seeds, arithmetic right-shift + mask is sign-clean
/// (e.g. `seed = -1` gives `[0xff, 0xff, 0xff, 0xff]`).
///
/// This is the canonical seed-to-bytes helper for the dml
/// package's RNG-backed tests and for `cmd/main`'s demo entry
/// point. It supersedes the earlier 7-bit-tiling helper that
/// existed in `irm_test.mbt` and `cmd/main/main.mbt` and produced
/// non-portable encodings.
pub fn seed_to_bytes(seed : Int) -> Array[Byte] {
  let b0 : Byte = (seed & 0xff).to_byte()
  let b1 : Byte = ((seed >> 8) & 0xff).to_byte()
  let b2 : Byte = ((seed >> 16) & 0xff).to_byte()
  let b3 : Byte = ((seed >> 24) & 0xff).to_byte()
  let bytes : Array[Byte] = []
  for k = 0; k < 32; k = k + 1 {
    // REVIEW L6: `Int % Int` is signed in MoonBit, so `k % 4` can
    // return negative values for `k < 0`. The wildcard covers
    // that branch — writing `3 => b3` instead would leave a
    // non-exhaustive match that `moon --deny-warn` rejects.
    let b = match k % 4 {
      0 => b0
      1 => b1
      2 => b2
      _ => b3
    }
    bytes.push(b)
  }
  bytes
}
