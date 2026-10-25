import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/providers/music_player_provider.dart';
import 'package:mosix/widgets/app_snack_bar.dart';

/// Receives transient playback feedback across all foreground app routes.
class PlaybackFeedback extends ConsumerStatefulWidget {
  const PlaybackFeedback({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PlaybackFeedback> createState() => _PlaybackFeedbackState();
}

class _PlaybackFeedbackState extends ConsumerState<PlaybackFeedback> {
  StreamSubscription<void>? _subscription;
  int _subscriptionRevision = 0;

  @override
  void initState() {
    super.initState();
    ref.listenManual(musicPlayerRuntimeProvider, (_, runtime) {
      final revision = ++_subscriptionRevision;
      unawaited(_subscription?.cancel());
      _subscription = runtime.mutedPlaybackEvents.listen((_) {
        if (!mounted ||
            revision != _subscriptionRevision ||
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed) {
          return;
        }
        showAppSnackBar(
          context,
          content: Text(context.l10n.snackbarPlaybackMuted),
        );
      });
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _subscriptionRevision++;
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
