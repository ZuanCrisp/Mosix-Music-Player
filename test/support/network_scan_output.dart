import 'dart:convert';
import 'dart:io';

/// Real filesystem output with observable write boundaries and injected faults.
/// [splitWrites] restores one awaited physical write per NDJSON row to isolate
/// filesystem dispatch cost in paired scanner benchmarks.
class InstrumentedScanOutput implements RandomAccessFile {
  InstrumentedScanOutput(
    this.file, {
    this.splitWrites = false,
    this.writeError,
    this.closeError,
    this.afterWrite,
    this.afterClose,
  });

  final RandomAccessFile file;
  final bool splitWrites;
  final Object? writeError, closeError;
  final void Function()? afterWrite, afterClose;
  final writeLengths = <int>[];
  final rowCounts = <int>[];
  int physicalWrites = 0;
  int concurrentWrites = 0;
  int maximumConcurrentWrites = 0;
  var _closed = false;

  @override
  Future<RandomAccessFile> writeString(
    String value, {
    Encoding encoding = utf8,
  }) async {
    writeLengths.add(value.length);
    rowCounts.add('\n'.allMatches(value).length);
    concurrentWrites++;
    if (concurrentWrites > maximumConcurrentWrites) {
      maximumConcurrentWrites = concurrentWrites;
    }
    try {
      final error = writeError;
      if (error != null) {
        // Leave partial bytes on disk so cleanup, not just exception handling,
        // is exercised. The scanner must never publish this staging file.
        await file.writeString(value.substring(0, 9), encoding: encoding);
        physicalWrites++;
        throw error;
      }
      if (splitWrites) {
        var start = 0;
        while (start < value.length) {
          final newline = value.indexOf('\n', start);
          final end = newline < 0 ? value.length : newline + 1;
          await file.writeString(
            value.substring(start, end),
            encoding: encoding,
          );
          physicalWrites++;
          start = end;
        }
      } else {
        await file.writeString(value, encoding: encoding);
        physicalWrites++;
      }
      afterWrite?.call();
      return this;
    } finally {
      concurrentWrites--;
    }
  }

  @override
  Future<void> close() async {
    if (!_closed) {
      await file.close();
      _closed = true;
      afterClose?.call();
    }
    final error = closeError;
    if (error != null) throw error;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
