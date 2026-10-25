import 'package:flutter/material.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/widgets/app_action_button.dart';
import 'package:mosix/widgets/selection_action_button.dart';
import 'package:mosix/widgets/selection_bottom_bar.dart';

/// Shared Library toolbar for playlist/queue actions and audio file operations.
/// FLAC upgrade applies only to eligible local selections.
class LibraryTrackSelectionBar extends StatelessWidget {
  const LibraryTrackSelectionBar({
    super.key,
    required this.selectedCount,
    required this.allSelected,
    required this.onClose,
    required this.onToggleSelectAll,
    required this.bottomPadding,
    required this.onReEnrich,
    required this.onConvert,
    required this.onReplayGain,
    required this.onDelete,
    this.flacEligibleCount = 0,
    this.onQueueFlac,
    this.playbackActions,
  });

  final int selectedCount;
  final bool allSelected;
  final VoidCallback onClose;
  final VoidCallback onToggleSelectAll;
  final double bottomPadding;
  final VoidCallback onReEnrich;
  final VoidCallback onConvert;
  final void Function({required bool remove}) onReplayGain;
  final VoidCallback onDelete;

  /// FLAC upgrade is offered when this is positive and [onQueueFlac] is set.
  final int flacEligibleCount;
  final VoidCallback? onQueueFlac;
  final Widget? playbackActions;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasSelection = selectedCount > 0;
    return SelectionBottomBar(
      selectedCount: selectedCount,
      allSelected: allSelected,
      onClose: onClose,
      onToggleSelectAll: onToggleSelectAll,
      bottomPadding: bottomPadding,
      children: [
        ?playbackActions,
        if (playbackActions != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(context.l10n.trackEditMetadata),
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            const spacing = 8.0;
            final columns = (constraints.maxWidth / 320).floor().clamp(2, 4);
            final itemWidth =
                (constraints.maxWidth - spacing * (columns - 1)) / columns;
            final actions = <Widget>[
              if (onQueueFlac != null && flacEligibleCount > 0)
                SelectionActionButton(
                  icon: Icons.download_for_offline_outlined,
                  label: '${context.l10n.queueFlacAction} ($flacEligibleCount)',
                  onPressed: onQueueFlac,
                  colorScheme: colorScheme,
                ),
              SelectionActionButton(
                icon: Icons.auto_fix_high_outlined,
                label: '${context.l10n.trackReEnrich} ($selectedCount)',
                onPressed: hasSelection ? onReEnrich : null,
                colorScheme: colorScheme,
              ),
              SelectionActionButton(
                icon: Icons.swap_horiz,
                label: context.l10n.selectionConvertCount(selectedCount),
                onPressed: hasSelection ? onConvert : null,
                colorScheme: colorScheme,
              ),
              for (final remove in [false, true])
                SelectionActionButton(
                  icon: remove ? Icons.remove_circle_outline : Icons.graphic_eq,
                  label: remove
                      ? context.l10n.selectionRemoveReplayGainCount(
                          selectedCount,
                        )
                      : context.l10n.selectionReplayGainCount(selectedCount),
                  onPressed: hasSelection
                      ? () => onReplayGain(remove: remove)
                      : null,
                  colorScheme: colorScheme,
                ),
            ];
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final action in actions)
                  SizedBox(width: itemWidth, child: action),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: AppActionButton(
            isDestructive: true,
            onPressed: hasSelection ? onDelete : null,
            icon: const Icon(Icons.delete_outline),
            label: Text(
              hasSelection
                  ? context.l10n.selectionDeleteTracksCount(selectedCount)
                  : context.l10n.selectionSelectToDelete,
            ),
            style: FilledButton.styleFrom(
              backgroundColor: hasSelection
                  ? colorScheme.error
                  : colorScheme.surfaceContainerHighest,
              foregroundColor: hasSelection
                  ? colorScheme.onError
                  : colorScheme.onSurfaceVariant,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
