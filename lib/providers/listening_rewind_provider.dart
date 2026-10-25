import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/listening_rewind.dart';
import 'package:mornye/services/listening_statistics.dart';

final listeningRewindProvider = FutureProvider.autoDispose
    .family<ListeningRewind, ListeningRewindPeriod>((ref, period) async {
      await listeningRecorder.flush();
      final range = ListeningRewindRange.of(period, DateTime.now());
      return ListeningStatisticsStore.instance.read(
        (db) => readListeningRewind(
          db,
          range,
          yearly: period == ListeningRewindPeriod.year,
        ),
      );
    });

/// The Rewind the Library advertises today, or null. A window without any
/// listening is not advertised, so the banner never opens an empty story.
final listeningRewindSpotlightProvider =
    FutureProvider.autoDispose<ListeningRewindSpotlight?>((ref) async {
      final now = DateTime.now();
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      final refresh = Timer(tomorrow.difference(now), ref.invalidateSelf);
      ref.onDispose(refresh.cancel);
      final spotlight = ListeningRewindSpotlight.at(now);
      if (spotlight == null) return null;
      await listeningRecorder.flush();
      final range = ListeningRewindRange.of(spotlight.period, now);
      final rows = await ListeningStatisticsStore.instance.read(
        (db) => db.rawQuery(
          'SELECT 1 FROM listening '
          'WHERE day >= ? AND day < ? AND milliseconds > 0 LIMIT 1',
          [listeningDay(range.start), listeningDay(range.end)],
        ),
      );
      return rows.isEmpty ? null : spotlight;
    });
