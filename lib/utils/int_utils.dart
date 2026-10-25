/// Parses a dynamic value to a positive integer (> 0), or returns null.
///
/// Accepts [num] and parseable [String] values.
int? readPositiveInt(dynamic value) {
  if (value == null) return null;
  if (value is num) {
    final asInt = value.toInt();
    return asInt > 0 ? asInt : null;
  }
  final parsed = int.tryParse(value.toString());
  if (parsed == null || parsed <= 0) return null;
  return parsed;
}

int extractDurationMs(Map<String, dynamic> data) {
  final durationMsRaw = data['duration_ms'];
  if (durationMsRaw is num && durationMsRaw > 0) {
    return durationMsRaw.toInt();
  }
  if (durationMsRaw is String) {
    final parsed = num.tryParse(durationMsRaw.trim());
    if (parsed != null && parsed > 0) {
      return parsed.toInt();
    }
  }

  final durationSecRaw = data['duration'];
  if (durationSecRaw is num && durationSecRaw > 0) {
    return (durationSecRaw * 1000).toInt();
  }
  if (durationSecRaw is String) {
    final parsed = num.tryParse(durationSecRaw.trim());
    if (parsed != null && parsed > 0) {
      return (parsed * 1000).toInt();
    }
  }

  return 0;
}
