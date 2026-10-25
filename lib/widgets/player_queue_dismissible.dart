import 'package:flutter/cupertino.dart' show CupertinoColors, CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_icon.dart';

/// Removing a row affects the queue only, never the song on disk.
class PlayerQueueDismissible extends StatefulWidget {
  const PlayerQueueDismissible({
    super.key,
    required this.onRemove,
    required this.child,
    this.enabled = true,
  });

  final VoidCallback onRemove;
  final Widget child;
  final bool enabled;

  @override
  State<PlayerQueueDismissible> createState() => _PlayerQueueDismissibleState();
}

class _PlayerQueueDismissibleState extends State<PlayerQueueDismissible> {
  final _progress = ValueNotifier<double>(0);

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dismissible(
    key: const ValueKey('queue-dismiss'),
    direction: widget.enabled
        ? DismissDirection.endToStart
        : DismissDirection.none,
    dismissThresholds: context.isMornye
        ? const {DismissDirection.endToStart: 0.5}
        : const {},
    onUpdate: context.isMornye
        ? (details) => _progress.value = details.progress
        : null,
    // Remove before collapsing so a concurrently playing row is never left
    // dismissed in the tree. The service resolves the entry by identity.
    confirmDismiss: (_) async {
      widget.onRemove();
      return false;
    },
    background: context.isMornye
        ? _buildMornyeBackground(context)
        : Container(
            alignment: AlignmentDirectional.centerEnd,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.error,
              // Matches the queue sheet's row corners.
              borderRadius: BorderRadius.circular(16),
            ),
            child: AppIcon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.onError,
              semanticLabel: MaterialLocalizations.of(
                context,
              ).deleteButtonTooltip,
            ),
          ),
    child: widget.child,
  );

  Widget _buildMornyeBackground(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: CupertinoColors.systemRed.resolveFrom(context),
      borderRadius: BorderRadius.circular(12),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) => ValueListenableBuilder<double>(
        valueListenable: _progress,
        child: Icon(
          CupertinoIcons.trash,
          color: Colors.white,
          size: 24,
          semanticLabel: context.l10n.dialogRemove,
        ),
        builder: (context, progress, icon) {
          final revealedWidth = constraints.maxWidth * progress;
          // Center in the revealed area first, then follow the song's edge.
          // Dismissible drives this during dragging, completion and reversal.
          final follow = Curves.easeOut.transform(
            ((progress - 0.5) / 0.25).clamp(0.0, 1.0),
          );
          final center = revealedWidth / 2;
          final inset = center + (center - 36).clamp(0.0, center) * follow;
          return Stack(
            children: [
              PositionedDirectional(
                end: inset - 12,
                top: 0,
                bottom: 0,
                child: icon!,
              ),
            ],
          );
        },
      ),
    ),
  );
}
