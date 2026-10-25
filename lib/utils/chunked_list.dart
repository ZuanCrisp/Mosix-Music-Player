import 'dart:collection';

/// Immutable indexed storage for frequent sparse updates. Each update copies
/// the chunk directory and only the affected 64-element chunks, without
/// retaining a chain of previous snapshots.
class ChunkedList<T> extends ListBase<T> {
  static const _chunkSize = 64;
  final List<List<T>> _chunks;
  final int _length;

  ChunkedList._(this._chunks, this._length);

  factory ChunkedList.from(List<T> items) {
    if (items is ChunkedList<T>) return items;
    return ChunkedList._([
      for (var start = 0; start < items.length; start += _chunkSize)
        List<T>.unmodifiable(
          items.getRange(start, (start + _chunkSize).clamp(0, items.length)),
        ),
    ], items.length);
  }

  ChunkedList<T> updated(Map<int, T> changes) {
    if (changes.isEmpty) return this;
    final chunks = List<List<T>>.of(_chunks);
    final copied = <int>{};
    for (final entry in changes.entries) {
      RangeError.checkValidIndex(entry.key, this);
      final chunk = entry.key ~/ _chunkSize;
      if (copied.add(chunk)) chunks[chunk] = List<T>.of(chunks[chunk]);
      chunks[chunk][entry.key % _chunkSize] = entry.value;
    }
    return ChunkedList._(chunks, length);
  }

  @override
  int get length => _length;

  @override
  set length(int value) => throw UnsupportedError('Immutable list');

  @override
  T operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return _chunks[index ~/ _chunkSize][index % _chunkSize];
  }

  @override
  void operator []=(int index, T value) =>
      throw UnsupportedError('Immutable list');
}
