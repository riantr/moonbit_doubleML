///|
/// For `seed = 3141` (0x0000_0C45), the four little-endian bytes
/// are `[0x45, 0x0c, 0x00, 0x00]`. Tiling gives `[0x45, 0x0c, 0x00,
/// 0x00]` repeated 8 times → 32 bytes total. This pins down the
/// byte ordering and the tiling shape.
///
/// WHY THESE ASSERT THE VALUE, NOT THE PRINTED BYTE.
///
/// The expectations used to be written against the toolchain's
/// *rendering* of a `Byte` -- `b'\x45'` -- which is a display detail
/// of `inspect`, not part of this module's contract. The core that
/// ships with moon 0.1.20261117 renders a `Byte` as its integer value
/// instead, so the three tests below failed on the new toolchain while
/// the bytes they check were still exactly right (`69 == 0x45`).
///
/// Pinning `bytes[k].to_int()` keeps the assertion on the contract --
/// the numeric value of the byte at index k -- and makes it
/// independent of how the toolchain chooses to print a byte. Measured
/// on moon 0.1.20261119 / core 0.10.22: `to_int()` of 0x45 is 69, of
/// 0x0c is 12, of 0xff is 255, of 0x00 is 0.
test "seed_to_bytes_layout" {
  let bytes = seed_to_bytes(3141)
  inspect(bytes.length(), content="32")
  // first 4 bytes are the little-endian encoding of 3141
  inspect(bytes[0].to_int(), content="69")
  inspect(bytes[1].to_int(), content="12")
  inspect(bytes[2].to_int(), content="0")
  inspect(bytes[3].to_int(), content="0")
  // the next 4 bytes repeat the same pattern
  inspect(bytes[4].to_int(), content="69")
  inspect(bytes[5].to_int(), content="12")
  inspect(bytes[6].to_int(), content="0")
  inspect(bytes[7].to_int(), content="0")
  // the last 4 bytes also tile the same pattern
  inspect(bytes[28].to_int(), content="69")
  inspect(bytes[29].to_int(), content="12")
  inspect(bytes[30].to_int(), content="0")
  inspect(bytes[31].to_int(), content="0")
}

///|
/// For `seed = -1` (i.e. all 1s in the low 32 bits), the four
/// little-endian bytes are `[0xff, 0xff, 0xff, 0xff]`. Confirms the
/// arithmetic-shift + mask implementation is sign-clean: the
/// negative input must still produce a well-formed 32-bit LE
/// pattern of all-0xFF bytes, not a sign-extended i64 value.
test "seed_to_bytes_negative" {
  let bytes = seed_to_bytes(-1)
  inspect(bytes.length(), content="32")
  // every byte is 0xff
  for k = 0; k < 32; k = k + 1 {
    inspect(bytes[k].to_int(), content="255")
  }
}

///|
/// The returned buffer must always be exactly 32 bytes long, the
/// chacha8 key size. The first four bytes are the LE encoding; the
/// rest tile the same 4 bytes 8 times.
test "seed_to_bytes_length" {
  inspect(seed_to_bytes(0).length(), content="32")
  inspect(seed_to_bytes(1).length(), content="32")
  inspect(seed_to_bytes(3141).length(), content="32")
  inspect(seed_to_bytes(99999).length(), content="32")
  inspect(seed_to_bytes(-1).length(), content="32")
  inspect(seed_to_bytes(-2147483648).length(), content="32")
  inspect(seed_to_bytes(2147483647).length(), content="32")
}

///|
/// For `seed = 0`, the four little-endian bytes are all zero, and
/// the tiled 32-byte buffer is uniformly 0x00. The simple edge
/// case is the most direct check that no spurious high-bit bias is
/// introduced by the encoding (e.g. that an `Int` sign-extension
/// does not leak into the high bytes).
test "seed_to_bytes_zero" {
  let bytes = seed_to_bytes(0)
  inspect(bytes.length(), content="32")
  for k = 0; k < 32; k = k + 1 {
    inspect(bytes[k].to_int(), content="0")
  }
}
