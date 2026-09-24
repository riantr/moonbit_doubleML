///|
/// For `seed = 3141` (0x0000_0C45), the four little-endian bytes
/// are `[0x45, 0x0c, 0x00, 0x00]`. Tiling gives `[0x45, 0x0c, 0x00,
/// 0x00]` repeated 8 times → 32 bytes total. This pins down the
/// byte ordering and the tiling shape.
test "seed_to_bytes_layout" {
  let bytes = seed_to_bytes(3141)
  inspect(bytes.length(), content="32")
  // first 4 bytes are the little-endian encoding of 3141
  inspect(bytes[0], content="b'\\x45'")
  inspect(bytes[1], content="b'\\x0C'")
  inspect(bytes[2], content="b'\\x00'")
  inspect(bytes[3], content="b'\\x00'")
  // the next 4 bytes repeat the same pattern
  inspect(bytes[4], content="b'\\x45'")
  inspect(bytes[5], content="b'\\x0C'")
  inspect(bytes[6], content="b'\\x00'")
  inspect(bytes[7], content="b'\\x00'")
  // the last 4 bytes also tile the same pattern
  inspect(bytes[28], content="b'\\x45'")
  inspect(bytes[29], content="b'\\x0C'")
  inspect(bytes[30], content="b'\\x00'")
  inspect(bytes[31], content="b'\\x00'")
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
    inspect(bytes[k], content="b'\\xFF'")
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
    inspect(bytes[k], content="b'\\x00'")
  }
}
