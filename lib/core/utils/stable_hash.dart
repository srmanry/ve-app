/// 64-bit FNV-1a hash rendered as hex. Unlike [String.hashCode] it is stable
/// across app launches, so it can be used for on-disk cache keys.
///
/// Dart native ints are 64-bit two's complement and multiplication wraps,
/// which is exactly the arithmetic FNV-1a needs.
String stableHash(String input) {
  var hash = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  for (final unit in input.codeUnits) {
    hash ^= unit & 0xff;
    hash *= prime;
    hash ^= unit >> 8;
    hash *= prime;
  }
  // Render as two unsigned 32-bit halves: a 64-bit value with the top bit
  // set can't be represented as a positive Dart int.
  String half(int v) => (v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  return half(hash >> 32) + half(hash);
}
