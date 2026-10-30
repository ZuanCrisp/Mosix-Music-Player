import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/providers/runtime_profile_provider.dart';
import 'package:mosix/services/mosix_glass_warmup.dart';
import 'package:mosix/theme/mosix_theme.dart';

/// Starts the one-time preparation when the full glass theme is enabled,
/// including switching to Mosix or enabling blur after the app has started.
class MosixGlassPreparation extends ConsumerWidget {
  const MosixGlassPreparation({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (context.isMosix &&
        ref.watch(mosixGlassLevelProvider) == MosixGlassLevel.liquid &&
        MosixTheme.glassClarityOf(context) > 0.2 &&
        !ref.watch(
          mosixGlassContrastBlockedProvider(
            MediaQuery.highContrastOf(context),
          ),
        )) {
      unawaited(MosixGlassWarmup.prepare(View.of(context)));
    }
    return child;
  }
}
