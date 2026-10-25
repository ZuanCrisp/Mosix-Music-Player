/// FNV-1a 32-bit hash over [units] (UTF-8 bytes or UTF-16 code units).
///
/// The result feeds on-disk file names, so the algorithm must not change.
int fnv1a32(Iterable<int> units) {
  var hash = 0x811c9dc5;
  for (final unit in units) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}
