import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/providers/music_player_provider.dart';
import 'package:mosix/widgets/expressive_button.dart';
import 'package:mosix/widgets/player_playback_controls.dart';
import 'package:mosix/widgets/player_artwork.dart';
import 'package:mosix/widgets/player_queue_dismissible.dart';

Future<void> showPlayerQueueSheet(
  BuildContext context,
  ColorScheme colorScheme,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: colorScheme.surfaceContainerHigh,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.6,
    maxChildSize: 0.9,
    minChildSize: 0.4,
    builder: (context, scrollController) => PlayerQueueSheet(
      colorScheme: colorScheme,
      scrollController: scrollController,
    ),
  ),
);

class PlayerQueueSheet extends ConsumerWidget {
  const PlayerQueueSheet({
    super.key,
    required this.colorScheme,
    required this.scrollController,
  });

  final ColorScheme colorScheme;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(playQueueProvider).value ?? const [];
    final current = ref.watch(currentMediaItemProvider).value;
    final controller = ref.read(musicPlayerControllerProvider);
    final textTheme = Theme.of(context).textTheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.nowPlayingUpNext,
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
              PlayerPlaybackModeButton(
                mode: PlayerPlaybackMode.autoplay,
                colorScheme: colorScheme,
                secondary: true,
              ),
              const SizedBox(width: 4),
              PlayerPlaybackModeButton(
                mode: PlayerPlaybackMode.repeat,
                colorScheme: colorScheme,
                secondary: true,
              ),
              const SizedBox(width: 4),
              PlayerPlaybackModeButton(
                mode: PlayerPlaybackMode.shuffle,
                colorScheme: colorScheme,
                secondary: true,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: SizedBox(
            width: double.infinity,
            child: ExpressiveButton(
              tonal: true,
              onPressed: () => _shuffleLibrary(context, controller),
              icon: const Icon(Icons.shuffle, size: 18),
              child: Text(context.l10n.nowPlayingShuffleLibrary),
            ),
          ),
        ),
        if (queue.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                context.l10n.nowPlayingQueueEmpty,
                style: textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          Expanded(
            child: ReorderableListView.builder(
              scrollController: scrollController,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
              itemCount: queue.length,
              onReorderItem: (oldIndex, newIndex) {
                controller.moveQueueItem(oldIndex, newIndex);
              },
              proxyDecorator: (child, index, animation) {
                return Material(
                  elevation: 4,
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  child: child,
                );
              },
              itemBuilder: (context, i) {
                final item = queue[i];
                final isCurrent = current?.id == item.id;
                return PlayerQueueDismissible(
                  key: ObjectKey(item),
                  enabled: !isCurrent,
                  onRemove: () => controller.removeQueuedItem(item),
                  child: ListTile(
                    selected: isCurrent,
                    selectedTileColor: colorScheme.secondaryContainer
                        .withValues(alpha: 0.55),
                    contentPadding: const EdgeInsets.only(left: 16, right: 4),
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox.square(
                        dimension: 44,
                        child: PlayerArtwork(
                          artUri: item.artUri?.toString(),
                          colorScheme: colorScheme,
                          cacheWidth: 132,
                          iconSize: 22,
                        ),
                      ),
                    ),
                    title: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyLarge?.copyWith(
                        fontWeight: isCurrent
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: isCurrent
                            ? colorScheme.primary
                            : colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      item.artist ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: ReorderableDragStartListener(
                      index: i,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          Icons.drag_handle,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    onTap: () => controller.jumpTo(i),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Future<void> _shuffleLibrary(
    BuildContext context,
    MusicPlayerController controller,
  ) async {
    try {
      if (!await controller.shuffleLibrary()) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.nowPlayingLibraryEmpty)),
        );
        return;
      }
      if (context.mounted) Navigator.of(context).maybePop();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.nowPlayingShuffleLibraryFailed(
              context.friendlyError(e),
            ),
          ),
        ),
      );
    }
  }
}
