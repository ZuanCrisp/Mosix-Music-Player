part of 'queue_tab.dart';

extension _QueueTabItemWidgets on _QueueTabState {
  Widget _buildSelectionBottomBar(
    BuildContext context,
    ColorScheme colorScheme,
    List<UnifiedLibraryItem> unifiedItems,
    double bottomPadding,
  ) {
    final selectedCount = _selectedIds.length;
    final allSelected =
        selectedCount == unifiedItems.length && unifiedItems.isNotEmpty;
    final localOnlySelection = _isLocalOnlySelection(unifiedItems);

    return LibraryTrackSelectionBar(
      playbackActions: LibrarySelectionPlaybackActions(
        items: _selectedItemsFromAll(unifiedItems),
        onClose: _exitSelectionMode,
      ),
      selectedCount: selectedCount,
      allSelected: allSelected,
      onClose: _exitSelectionMode,
      onToggleSelectAll: () {
        if (allSelected) {
          _exitSelectionMode();
        } else {
          _selectAll(unifiedItems);
        }
      },
      bottomPadding: bottomPadding,
      flacEligibleCount: localOnlySelection
          ? _selectedFlacEligibleLocalItems(unifiedItems).length
          : 0,
      onQueueFlac: () => _queueSelectedLocalAsFlac(unifiedItems),
      onReEnrich: () => _reEnrichSelectedFromQueue(unifiedItems),
      onConvert: () => _showBatchConvertSheet(context, unifiedItems),
      onReplayGain: ({required remove}) =>
          _runBatchReplayGain(unifiedItems, remove: remove),
      onDelete: () => _deleteSelected(unifiedItems),
    );
  }

  Widget _buildQueueItem(
    BuildContext context,
    DownloadItem item,
    ColorScheme colorScheme,
  ) {
    final isCompleted = item.status == DownloadStatus.completed;
    final isActive =
        item.status == DownloadStatus.queued ||
        item.status == DownloadStatus.downloading ||
        item.status == DownloadStatus.finalizing;

    return SmoothedProgressScope(
      value: item.progress,
      animate: _shouldAnimateDownloadProgress(context, item),
      child: Dismissible(
        key: ValueKey('dismiss_${item.id}'),
        direction: DismissDirection.endToStart,
        confirmDismiss: isActive
            ? (_) async {
                return await showAppDialog<bool>(
                      context: context,
                      builder: (ctx) => AppAlertDialog(
                        title: Text(context.l10n.cancelDownloadTitle),
                        content: Text(
                          context.l10n.cancelDownloadContent(item.track.name),
                        ),
                        actions: [
                          AppDialogAction(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            child: Text(context.l10n.cancelDownloadKeep),
                          ),
                          AppDialogAction(
                            isDestructive: true,
                            onPressed: () => Navigator.of(ctx).pop(true),
                            child: Text(context.l10n.dialogCancel),
                          ),
                        ],
                      ),
                    ) ??
                    false;
              }
            : null,
        onDismissed: (_) {
          ref.read(downloadQueueProvider.notifier).dismissItem(item.id);
        },
        background: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          child: Icon(
            Icons.delete_outline,
            color: colorScheme.onErrorContainer,
          ),
        ),
        child: DownloadSuccessOverlay(
          showSuccess: isCompleted,
          child: TrackCard(
            onTap: isCompleted
                ? () => _navigateToMetadataScreen(item)
                : item.status == DownloadStatus.failed ||
                      item.status == DownloadStatus.skipped
                ? () => _showDownloadErrorDialog(context, item)
                : null,
            onLongPress: item.status == DownloadStatus.queued
                ? () => _showQueuedItemMenu(context, item)
                : null,
            background: item.status == DownloadStatus.downloading
                ? SmoothedProgressBuilder(
                    builder: (context, progress, child) => Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: progress,
                        child: child,
                      ),
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            colorScheme.primary.withValues(alpha: 0.16),
                            colorScheme.primary.withValues(alpha: 0.04),
                          ],
                        ),
                      ),
                    ),
                  )
                : null,
            leading: isCompleted
                ? Hero(
                    tag: 'cover_${item.id}',
                    child: _buildCoverArt(item, colorScheme),
                  )
                : _buildCoverArt(item, colorScheme),
            title: item.track.name,
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ClickableArtistName(
                  artistName: item.track.artistName,
                  artistId: item.track.artistId,
                  coverUrl: item.track.coverUrl,
                  extensionId: item.track.source,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                if (item.status == DownloadStatus.downloading) ...[
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Icon(
                        Icons.download_rounded,
                        size: 12,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: SmoothedProgressBuilder(
                          builder: (context, progress, child) => Text(
                            _formatDownloadStatusLine(
                              context,
                              item,
                              visualProgress: progress,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (item.status == DownloadStatus.finalizing &&
                    item.preparationStage == 'network_upload') ...[
                  const SizedBox(height: 4),
                  Text(
                    '${context.l10n.networkUploading}${item.bytesTotal > 0 ? ' • ${(100 * item.bytesReceived / item.bytesTotal).round()}%' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.primary,
                    ),
                  ),
                ],
                if (item.status == DownloadStatus.failed) ...[
                  const SizedBox(height: 4),
                  _buildDownloadFailureMessage(context, item, colorScheme),
                ],
              ],
            ),
            trailing: _buildActionButtons(context, item, colorScheme),
          ),
        ),
      ),
    );
  }

  /// Download error messages are stored as fixed English sentinels on the
  /// item (so code can match on them); translate the known ones for display.
  String _localizedDownloadError(BuildContext context, String raw) {
    if (raw == safPermissionLostErrorMessage) {
      return context.l10n.downloadErrorSafPermissionLost;
    }
    if (raw == downloadFolderAccessLostErrorMessage) {
      return context.l10n.downloadErrorFolderAccessLost;
    }
    return context.friendlyError(
      raw,
      fallback: context.l10n.updateDownloadFailed,
    );
  }

  Widget _buildDownloadFailureMessage(
    BuildContext context,
    DownloadItem item,
    ColorScheme colorScheme,
  ) {
    if (item.errorType != DownloadErrorType.rateLimit) {
      return Text(
        _localizedDownloadError(context, item.errorMessage),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: colorScheme.error),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            Icons.hourglass_top_rounded,
            size: 14,
            color: colorScheme.tertiary,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.l10n.queueRateLimitTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.tertiary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                context.l10n.queueRateLimitMessage,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.tertiary.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCoverArt(DownloadItem item, ColorScheme colorScheme) {
    final coverSize = _queueCoverSize();
    final radius = BorderRadius.circular(8);

    final cover = item.track.coverUrl != null
        ? CachedCoverImage(
            imageUrl: item.track.coverUrl!,
            width: coverSize,
            height: coverSize,
            borderRadius: radius,
            fadeInDuration: const Duration(milliseconds: 180),
            fadeOutDuration: const Duration(milliseconds: 90),
          )
        : Container(
            width: coverSize,
            height: coverSize,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: radius,
            ),
            child: Icon(Icons.music_note, color: colorScheme.onSurfaceVariant),
          );

    final isDownloading =
        item.status == DownloadStatus.downloading ||
        item.status == DownloadStatus.finalizing;
    if (!isDownloading) return cover;

    final progress = item.progress.clamp(0.0, 1.0);
    final indeterminate =
        item.status == DownloadStatus.finalizing || progress <= 0;

    return SizedBox(
      width: coverSize,
      height: coverSize,
      child: Stack(
        fit: StackFit.expand,
        children: [
          cover,
          ClipRRect(
            borderRadius: radius,
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
          ),
          if (indeterminate)
            Center(
              child: SizedBox(
                width: coverSize * 0.6,
                height: coverSize * 0.6,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Colors.white,
                  backgroundColor: Colors.white.withValues(alpha: 0.25),
                ),
              ),
            )
          else
            SmoothedProgressBuilder(
              builder: (context, visualProgress, child) => Stack(
                fit: StackFit.expand,
                children: [
                  Center(
                    child: SizedBox(
                      width: coverSize * 0.6,
                      height: coverSize * 0.6,
                      child: CircularProgressIndicator(
                        value: visualProgress,
                        strokeWidth: 3,
                        color: Colors.white,
                        backgroundColor: Colors.white.withValues(alpha: 0.25),
                      ),
                    ),
                  ),
                  Center(
                    child: Text(
                      '${(visualProgress * 100).round()}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showQueuedItemMenu(BuildContext context, DownloadItem item) {
    final notifier = ref.read(downloadQueueProvider.notifier);
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.skip_next),
              title: Text(context.l10n.queueDownloadNext),
              onTap: () {
                Navigator.of(ctx).pop();
                notifier.downloadNext(item.id);
              },
            ),
            ListTile(
              leading: const Icon(Icons.arrow_upward),
              title: Text(context.l10n.queueMoveUp),
              onTap: () {
                Navigator.of(ctx).pop();
                notifier.moveQueuedItem(item.id, -1);
              },
            ),
            ListTile(
              leading: const Icon(Icons.arrow_downward),
              title: Text(context.l10n.queueMoveDown),
              onTap: () {
                Navigator.of(ctx).pop();
                notifier.moveQueuedItem(item.id, 1);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons(
    BuildContext context,
    DownloadItem item,
    ColorScheme colorScheme,
  ) {
    switch (item.status) {
      case DownloadStatus.queued:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: () => ref
                  .read(downloadQueueProvider.notifier)
                  .downloadNext(item.id),
              icon: Icon(Icons.skip_next, color: colorScheme.primary),
              tooltip: context.l10n.queueDownloadNext,
              style: IconButton.styleFrom(
                backgroundColor: colorScheme.primaryContainer.withValues(
                  alpha: 0.3,
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: () =>
                  ref.read(downloadQueueProvider.notifier).cancelItem(item.id),
              icon: Icon(Icons.close, color: colorScheme.error),
              tooltip: context.l10n.dialogCancel,
              style: IconButton.styleFrom(
                backgroundColor: colorScheme.errorContainer.withValues(
                  alpha: 0.3,
                ),
              ),
            ),
          ],
        );
      case DownloadStatus.downloading:
        return IconButton(
          onPressed: () =>
              ref.read(downloadQueueProvider.notifier).cancelItem(item.id),
          icon: Icon(Icons.stop, color: colorScheme.error),
          tooltip: context.l10n.actionStop,
          style: IconButton.styleFrom(
            backgroundColor: colorScheme.errorContainer.withValues(alpha: 0.3),
          ),
        );
      case DownloadStatus.finalizing:
        return Semantics(
          label: context.l10n.queueFinalizingDownload,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  strokeWidth: 3,
                  color: colorScheme.tertiary,
                ),
                ExcludeSemantics(
                  child: Icon(
                    Icons.edit_note,
                    color: colorScheme.tertiary,
                    size: 16,
                  ),
                ),
              ],
            ),
          ),
        );
      case DownloadStatus.completed:
        return ValueListenableBuilder<bool>(
          valueListenable: _fileExistsListenable(item.filePath),
          builder: (context, fileExists, child) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (fileExists)
                  _LibraryPlaybackButton(
                    mediaId: _cleanFilePath(item.filePath!),
                    playTooltip: context.l10n.a11yPlayTrackByArtist(
                      item.track.name,
                      item.track.artistName,
                    ),
                    onPlay: () => _openFile(
                      item.filePath!,
                      title: item.track.name,
                      artist: item.track.artistName,
                      album: item.track.albumName,
                      coverUrl: item.track.coverUrl ?? '',
                    ),
                  )
                else
                  Semantics(
                    label: context.l10n.queueDownloadedFileMissing,
                    child: ExcludeSemantics(
                      child: Icon(
                        Icons.error_outline,
                        color: colorScheme.error,
                        size: 20,
                      ),
                    ),
                  ),
                const SizedBox(width: 4),
                Semantics(
                  label: context.l10n.queueDownloadCompleted,
                  child: ExcludeSemantics(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.check,
                        color: colorScheme.onPrimaryContainer,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      case DownloadStatus.failed:
      case DownloadStatus.skipped:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: () =>
                  ref.read(downloadQueueProvider.notifier).retryItem(item.id),
              icon: Icon(Icons.refresh, color: colorScheme.primary),
              tooltip: context.l10n.dialogRetry,
              style: IconButton.styleFrom(
                backgroundColor: colorScheme.primaryContainer.withValues(
                  alpha: 0.3,
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: () =>
                  ref.read(downloadQueueProvider.notifier).removeItem(item.id),
              icon: Icon(
                Icons.close,
                color: item.status == DownloadStatus.failed
                    ? colorScheme.error
                    : colorScheme.onSurfaceVariant,
              ),
              tooltip: context.l10n.dialogRemove,
              style: item.status == DownloadStatus.failed
                  ? IconButton.styleFrom(
                      backgroundColor: colorScheme.errorContainer.withValues(
                        alpha: 0.3,
                      ),
                    )
                  : null,
            ),
          ],
        );
    }
  }

  Widget _buildFilterButton(BuildContext context) {
    return GestureDetector(
      onLongPress: _activeFilterCount > 0 ? _resetFilters : null,
      child: TextButton.icon(
        onPressed: () => _showFilterSheet(context),
        icon: Badge(
          isLabelVisible: _activeFilterCount > 0,
          label: Text('$_activeFilterCount'),
          child: const Icon(Icons.filter_list, size: 18),
        ),
        label: Text(context.l10n.libraryFilterTitle),
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
      ),
    );
  }

  /// When [size] is provided, renders at fixed dimensions (list mode).
  /// When [size] is null, fills the parent container (grid mode).
  Widget _buildUnifiedCoverImage(
    UnifiedLibraryItem item,
    ColorScheme colorScheme, [
    double? size,
  ]) {
    final isDownloaded = item.source == LibraryItemSource.downloaded;

    // Scanned SAF tracks also recover artwork after a transient provider error.
    if (isDownloaded || item.filePath.startsWith('content://')) {
      return ValueListenableBuilder<int>(
        valueListenable: _embeddedCoverVersion,
        builder: (context, _, child) =>
            _buildUnifiedCoverImageInner(item, colorScheme, isDownloaded, size),
      );
    }

    return _buildUnifiedCoverImageInner(item, colorScheme, isDownloaded, size);
  }

  Widget _buildUnifiedCoverImageInner(
    UnifiedLibraryItem item,
    ColorScheme colorScheme,
    bool isDownloaded, [
    double? size,
  ]) {
    final cacheSize = size != null ? (size * 2).toInt() : 200;
    final iconSize = size != null ? size * 0.4 : 32.0;

    Widget buildPlaceholder({
      bool isLocal = false,
      bool recoverDocument = true,
    }) {
      if (recoverDocument && item.filePath.startsWith('content://')) {
        final recovered = _resolveDownloadedEmbeddedCoverPath(item.filePath);
        if (recovered != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(recovered),
              width: size,
              height: size,
              fit: BoxFit.cover,
              cacheWidth: cacheSize,
              errorBuilder: (_, _, _) =>
                  buildPlaceholder(isLocal: isLocal, recoverDocument: false),
            ),
          );
        }
      }
      final bgColor = (isDownloaded && !isLocal)
          ? colorScheme.surfaceContainerHighest
          : colorScheme.secondaryContainer;
      final fgColor = (isDownloaded && !isLocal)
          ? colorScheme.onSurfaceVariant
          : colorScheme.onSecondaryContainer;
      return Container(
        width: size,
        height: size,
        decoration: size != null
            ? BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(8),
              )
            : null,
        color: size != null ? null : bgColor,
        child: Center(
          child: Icon(Icons.music_note, color: fgColor, size: iconSize),
        ),
      );
    }

    Widget fadeInFileImage(Widget child, int? frame, bool wasSync) {
      if (wasSync) return child;
      final Widget backdrop;
      if (isDownloaded && item.coverUrl != null) {
        backdrop = CachedCoverImage(
          imageUrl: item.coverUrl!,
          width: size,
          height: size,
          memCacheWidth: cacheSize,
          placeholder: (context, url) =>
              buildPlaceholder(recoverDocument: false),
          errorWidget: (context, url, error) => buildPlaceholder(),
        );
      } else {
        backdrop = buildPlaceholder(
          isLocal: !isDownloaded,
          recoverDocument: false,
        );
      }
      final animated = Stack(
        fit: StackFit.expand,
        children: [
          backdrop,
          AnimatedOpacity(
            opacity: frame == null ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: child,
          ),
        ],
      );
      if (size == null) return animated;
      return SizedBox(width: size, height: size, child: animated);
    }

    if (isDownloaded) {
      final embeddedCoverPath = _resolveDownloadedEmbeddedCoverPath(
        item.filePath,
      );
      if (embeddedCoverPath != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(embeddedCoverPath),
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: cacheSize,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
                fadeInFileImage(child, frame, wasSynchronouslyLoaded),
            errorBuilder: (context, error, stackTrace) => buildPlaceholder(),
          ),
        );
      }
    }

    if (item.coverUrl != null) {
      return CachedCoverImage(
        imageUrl: item.coverUrl!,
        width: size,
        height: size,
        memCacheWidth: cacheSize,
        borderRadius: BorderRadius.circular(8),
        placeholder: (context, url) => buildPlaceholder(),
        errorWidget: (context, url, error) => buildPlaceholder(),
        fadeInDuration: const Duration(milliseconds: 180),
        fadeOutDuration: const Duration(milliseconds: 90),
      );
    }

    if (item.localCoverPath != null && item.localCoverPath!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(item.localCoverPath!),
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: cacheSize,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
              fadeInFileImage(child, frame, wasSynchronouslyLoaded),
          errorBuilder: (context, error, stackTrace) =>
              buildPlaceholder(isLocal: true),
        ),
      );
    }

    if (size != null) {
      return buildPlaceholder();
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: buildPlaceholder(),
    );
  }

  Widget _buildUnifiedLibraryItem(
    BuildContext context,
    UnifiedLibraryItem item,
    ColorScheme colorScheme, {
    required List<DownloadHistoryItem> downloadedNavigationItems,
    required int? downloadedNavigationIndex,
    required List<LocalLibraryItem> localNavigationItems,
    required int? localNavigationIndex,
    required List<UnifiedLibraryItem> libraryItems,
    bool playlistDragEnabled = false,
  }) {
    final fileExistsListenable = _fileExistsListenable(item.filePath);
    final isSelected = _selectedIds.contains(item.id);
    final date = item.addedAt;
    final dateStr =
        '${shortMonthNames[date.month - 1]} ${date.day}, ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

    final isDownloaded = item.source == LibraryItemSource.downloaded;
    final quality = item.qualityForMode(_libraryQualityLabelMode);
    final sourceLabel = isDownloaded
        ? context.l10n.librarySourceDownloaded
        : context.l10n.librarySourceLocal;
    final sourceColor = isDownloaded
        ? colorScheme.primaryContainer
        : colorScheme.secondaryContainer;
    final sourceTextColor = isDownloaded
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSecondaryContainer;

    return Semantics(
      label: context.l10n.a11yTrackByArtist(item.trackName, item.artistName),
      selected: isSelected,
      child: TrackCard(
        isSelectionMode: _isSelectionMode,
        isSelected: isSelected,
        onTap: _isSelectionMode
            ? () => _toggleSelection(item.id)
            : isDownloaded
            ? () => _navigateToHistoryMetadataScreen(
                item.historyItem!,
                navigationItems: downloadedNavigationItems,
                navigationIndex: downloadedNavigationIndex,
              )
            : item.localItem != null
            ? () => _navigateToLocalMetadataScreen(
                item.localItem!,
                navigationItems: localNavigationItems,
                navigationIndex: localNavigationIndex,
              )
            : () => _openFile(
                item.filePath,
                title: item.trackName,
                artist: item.artistName,
                album: item.albumName,
                coverUrl: item.coverUrl ?? item.localCoverPath ?? '',
              ),
        onLongPress: playlistDragEnabled
            ? null
            : _isSelectionMode
            ? () => _selectRangeTo(item.id, libraryItems)
            : () => _enterSelectionMode(item.id),
        leading: Hero(
          tag: 'cover_lib_${item.id}',
          child: _buildUnifiedCoverImage(
            item,
            colorScheme,
            context.tokens.coverList,
          ),
        ),
        title: item.trackName,
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClickableArtistName(
              artistName: item.artistName,
              coverUrl: item.coverUrl,
              extensionId: item.historyItem?.service,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Container(
                  padding: context.tokens.badgePadding,
                  decoration: BoxDecoration(
                    color: sourceColor,
                    borderRadius: context.tokens.borderRadiusBadge,
                  ),
                  child: Text(
                    sourceLabel,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: sourceTextColor,
                      fontSize: context.tokens.badgeFontSize,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    dateStr,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (quality != null && quality.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  _buildLibraryQualityBadge(
                    context,
                    colorScheme,
                    quality,
                    listStyle: true,
                  ),
                ],
              ],
            ),
          ],
        ),
        trailing: ValueListenableBuilder<bool>(
          valueListenable: fileExistsListenable,
          builder: (context, fileExists, child) {
            if (fileExists) {
              return _LibraryPlaybackButton(
                mediaId: _libraryPlaybackMediaId(item),
                playTooltip: context.l10n.a11yPlayTrackByArtist(
                  item.trackName,
                  item.artistName,
                ),
                onPlay: () => _playLibraryItem(item, libraryItems),
              );
            }
            return Tooltip(
              message: context.l10n.queueDownloadedFileMissing,
              child: Icon(
                Icons.error_outline,
                color: colorScheme.error,
                size: 20,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildUnifiedGridItem(
    BuildContext context,
    UnifiedLibraryItem item,
    ColorScheme colorScheme, {
    required List<DownloadHistoryItem> downloadedNavigationItems,
    required int? downloadedNavigationIndex,
    required List<LocalLibraryItem> localNavigationItems,
    required int? localNavigationIndex,
    required List<UnifiedLibraryItem> libraryItems,
    bool playlistDragEnabled = false,
  }) {
    final fileExistsListenable = _fileExistsListenable(item.filePath);
    final isSelected = _selectedIds.contains(item.id);
    final isDownloaded = item.source == LibraryItemSource.downloaded;
    final quality = item.qualityForMode(_libraryQualityLabelMode);

    return TrackGridCard(
      isSelected: _isSelectionMode && isSelected,
      semanticLabel: context.l10n.a11yTrackByArtist(
        item.trackName,
        item.artistName,
      ),
      onTap: _isSelectionMode
          ? () => _toggleSelection(item.id)
          : isDownloaded
          ? () => _navigateToHistoryMetadataScreen(
              item.historyItem!,
              navigationItems: downloadedNavigationItems,
              navigationIndex: downloadedNavigationIndex,
            )
          : item.localItem != null
          ? () => _navigateToLocalMetadataScreen(
              item.localItem!,
              navigationItems: localNavigationItems,
              navigationIndex: localNavigationIndex,
            )
          : () => _openFile(
              item.filePath,
              title: item.trackName,
              artist: item.artistName,
              album: item.albumName,
              coverUrl: item.coverUrl ?? item.localCoverPath ?? '',
            ),
      onLongPress: playlistDragEnabled
          ? null
          : _isSelectionMode
          ? () => _selectRangeTo(item.id, libraryItems)
          : () => _enterSelectionMode(item.id),
      cover: Hero(
        tag: 'cover_lib_${item.id}',
        child: _buildUnifiedCoverImage(item, colorScheme),
      ),
      overlays: [
        if (!_isSelectionMode)
          Positioned(
            right: 4,
            top: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: isDownloaded
                    ? colorScheme.primaryContainer
                    : colorScheme.secondaryContainer,
                borderRadius: context.tokens.borderRadiusBadge,
              ),
              child: Icon(
                isDownloaded ? Icons.download_done : Icons.folder,
                size: 12,
                color: isDownloaded
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        if (quality != null && quality.isNotEmpty)
          Positioned(
            left: 4,
            right: _isSelectionMode ? 4 : 28,
            top: 4,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _buildLibraryQualityBadge(context, colorScheme, quality),
            ),
          ),
        if (!_isSelectionMode)
          Positioned(
            right: 4,
            bottom: 4,
            child: ValueListenableBuilder<bool>(
              valueListenable: fileExistsListenable,
              builder: (context, fileExists, child) {
                if (fileExists) {
                  return _LibraryPlaybackButton(
                    mediaId: _libraryPlaybackMediaId(item),
                    playTooltip: context.l10n.a11yPlayTrackByArtist(
                      item.trackName,
                      item.artistName,
                    ),
                    onPlay: () => _playLibraryItem(item, libraryItems),
                    grid: true,
                  );
                }
                return Tooltip(
                  message: context.l10n.queueDownloadedFileMissing,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: colorScheme.errorContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.error_outline,
                      color: colorScheme.error,
                      size: 14,
                    ),
                  ),
                );
              },
            ),
          ),
        if (_isSelectionMode)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: isSelected
                    ? colorScheme.primary.withValues(alpha: 0.3)
                    : Colors.transparent,
                borderRadius: context.tokens.borderRadiusThumb,
              ),
            ),
          ),
        if (_isSelectionMode)
          Positioned(
            right: 4,
            top: 4,
            child: AnimatedSelectionCheckbox(
              visible: true,
              selected: isSelected,
              colorScheme: colorScheme,
              size: 24,
              unselectedColor: colorScheme.surface,
            ),
          ),
      ],
      title: item.trackName,
      subtitle: ClickableArtistName(
        artistName: item.artistName,
        coverUrl: item.coverUrl,
        extensionId: item.historyItem?.service,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _LibraryPlaybackButton extends ConsumerWidget {
  const _LibraryPlaybackButton({
    required this.mediaId,
    required this.playTooltip,
    required this.onPlay,
    this.grid = false,
  });

  final String mediaId;
  final String playTooltip;
  final VoidCallback onPlay;
  final bool grid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(mediaItemPlaybackUiProvider(mediaId));
    final icon = playback.isPlaying ? Icons.pause : Icons.play_arrow;
    final tooltip = playback.isPlaying ? context.l10n.actionPause : playTooltip;
    final onPressed = playback.isLoading
        ? null
        : () {
            if (playback.isCurrent) {
              ref
                  .read(musicPlayerControllerProvider)
                  .togglePlayPause(playback.isPlaying);
            } else {
              onPlay();
            }
          };

    if (grid) {
      return TrackGridPlayButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: icon,
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, color: colorScheme.primary),
      tooltip: tooltip,
      style: IconButton.styleFrom(
        minimumSize: Size.square(context.tokens.minTouchTarget),
        backgroundColor: colorScheme.primaryContainer.withValues(alpha: 0.3),
      ),
    );
  }
}
