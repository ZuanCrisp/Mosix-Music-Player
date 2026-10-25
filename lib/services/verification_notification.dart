import 'dart:async';
import 'dart:convert';

class VerificationNotification {
  const VerificationNotification({
    required this.extensionId,
    required this.itemId,
    required this.tapId,
  });

  final String extensionId;
  final String itemId;
  final String tapId;

  String encode() => jsonEncode({
    'kind': 'extension_verification',
    'extension_id': extensionId,
    'item_id': itemId,
    'tap_id': tapId,
  });

  static VerificationNotification? parse(Object? payload) {
    try {
      final value = payload is String ? jsonDecode(payload) : payload;
      if (value is! Map || value['kind'] != 'extension_verification') {
        return null;
      }
      final extensionId = value['extension_id'];
      final itemId = value['item_id'];
      final tapId = value['tap_id'];
      if (extensionId is! String ||
          extensionId.trim().isEmpty ||
          itemId is! String ||
          itemId.trim().isEmpty ||
          tapId is! String ||
          tapId.trim().isEmpty) {
        return null;
      }
      return VerificationNotification(
        extensionId: extensionId.trim(),
        itemId: itemId.trim(),
        tapId: tapId.trim(),
      );
    } on FormatException {
      return null;
    }
  }
}

/// Holds cold-start taps until extensions and queue restoration are ready.
/// A repeated native/plugin delivery must not launch a second challenge.
class VerificationNotificationRouter {
  final Map<String, VerificationNotification> _pending = {};
  final Set<String> _handled = {};
  final Set<String> _active = {};
  Future<void> Function(VerificationNotification)? _handler;

  void setHandler(Future<void> Function(VerificationNotification)? handler) {
    _handler = handler;
    _drain();
  }

  void receive(Object? payload) {
    final target = VerificationNotification.parse(payload);
    if (target == null ||
        _handled.contains(target.tapId) ||
        _active.contains(target.tapId)) {
      return;
    }
    _pending.putIfAbsent(target.tapId, () => target);
    _drain();
  }

  void _drain() {
    final handler = _handler;
    if (handler == null) return;
    for (final target in _pending.values.toList()) {
      _pending.remove(target.tapId);
      _active.add(target.tapId);
      // The queue deduplicates flows per extension. A different provider's
      // notification must not wait behind an unrelated grant timeout.
      unawaited(
        Future<void>.sync(() => handler(target)).whenComplete(() {
          _active.remove(target.tapId);
          _handled.add(target.tapId);
          if (_handled.length > 32) _handled.remove(_handled.first);
        }),
      );
    }
  }
}
