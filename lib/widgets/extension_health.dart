import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:mosix/theme/mosix_theme.dart';

Color extensionHealthColor(BuildContext context, String status) {
  final colorScheme = Theme.of(context).colorScheme;
  switch (status) {
    case 'online':
      return context.isMosix
          ? CupertinoColors.systemGreen.resolveFrom(context)
          : colorScheme.primary;
    case 'degraded':
      return colorScheme.tertiary;
    case 'offline':
      return colorScheme.error;
    default:
      return colorScheme.onSurfaceVariant;
  }
}

IconData extensionHealthIcon(BuildContext context, String status) {
  if (context.isMosix) {
    return switch (status) {
      'online' => CupertinoIcons.check_mark_circled_solid,
      'degraded' => CupertinoIcons.exclamationmark_triangle,
      'offline' => CupertinoIcons.exclamationmark_circle,
      _ => CupertinoIcons.question_circle,
    };
  }
  switch (status) {
    case 'online':
      return Icons.check_circle;
    case 'degraded':
      return Icons.warning_amber_rounded;
    case 'offline':
      return Icons.error_outline;
    default:
      return Icons.help_outline;
  }
}
