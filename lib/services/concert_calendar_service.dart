import 'package:flutter/services.dart';

class ConcertCalendarService {
  ConcertCalendarService._();

  static const MethodChannel _channel = MethodChannel(
    'com.zarz.mornye/concert_calendar',
  );

  /// Opens the platform calendar editor for a concert. Returns true when the
  /// editor was opened; platform errors propagate to the caller.
  static Future<bool?> add({
    required String title,
    required String location,
    required int start,
    int? end,
    String? url,
  }) {
    return _channel.invokeMethod<bool>('add', {
      'title': title,
      'location': location,
      'start': start,
      'end': end,
      'url': url,
    });
  }
}
