part of 'queue_tab.dart';

extension _QueueTabDownloadDialogs on _QueueTabState {
  Future<void> _confirmCancelDownload(
    BuildContext context,
    DownloadItem item,
  ) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(context.l10n.cancelDownloadTitle),
        content: Text(context.l10n.cancelDownloadContent(item.track.name)),
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
    );
    if (confirmed == true) {
      // cancelItem (not dismissItem): the item stays in the queue as
      // cancelled so it can be retried without re-searching the track.
      ref.read(downloadQueueProvider.notifier).cancelItem(item.id);
    }
  }

  Future<void> _showDownloadErrorDialog(
    BuildContext context,
    DownloadItem item,
  ) async {
    final colorScheme = Theme.of(context).colorScheme;
    final isRateLimit = item.errorType == DownloadErrorType.rateLimit;
    final isCancelled = item.status == DownloadStatus.skipped;
    final errorMessage = _downloadErrorForDisplay(item);
    final isFolderAccessLost = _requiresFolderReselection(item);
    final title = isCancelled
        ? context.l10n.queueCancelledTitle
        : isRateLimit
        ? context.l10n.queueRateLimitTitle
        : context.l10n.updateDownloadFailed;
    final message = isCancelled
        ? context.l10n.queueCancelledMessage
        : isRateLimit
        ? context.l10n.queueRateLimitMessage
        : (errorMessage.trim().isNotEmpty
              ? _localizedDownloadError(context, errorMessage)
              : context.l10n.updateDownloadFailed);
    final action = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                item.track.name,
                style: Theme.of(
                  ctx,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              SelectableText(
                message,
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        actions: [
          AppDialogAction(
            isDestructive: true,
            onPressed: () => Navigator.of(ctx).pop('remove'),
            style: TextButton.styleFrom(foregroundColor: colorScheme.error),
            child: Text(context.l10n.dialogRemove),
          ),
          AppDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.l10n.dialogCancel),
          ),
          if (isFolderAccessLost)
            AppDialogAction(
              filled: true,
              onPressed: () => Navigator.of(ctx).pop('reselect'),
              child: Text(context.l10n.downloadFolderReselect),
            )
          else
            AppDialogAction(
              filled: true,
              onPressed: () => Navigator.of(ctx).pop('retry'),
              child: Text(context.l10n.dialogRetry),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'retry') {
      ref.read(downloadQueueProvider.notifier).retryItem(item.id);
    } else if (action == 'remove') {
      ref.read(downloadQueueProvider.notifier).removeItem(item.id);
    } else if (action == 'reselect') {
      final reselected = await _reselectDownloadFolder();
      if (reselected && mounted) {
        ref.read(downloadQueueProvider.notifier).retryItem(item.id);
      }
    }
  }

  /// Reopen the platform folder picker to restore download folder access,
  /// then persist the new location. Returns true when a folder was saved.
  Future<bool> _reselectDownloadFolder() async {
    if (Platform.isAndroid) {
      return pickAndStoreSafDownloadTree(ref);
    }
    if (Platform.isIOS) {
      IosPickedDirectory? picked;
      try {
        picked = await PlatformBridge.pickIosDirectory();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.l10n.snackbarFolderPickerFailed(
                  context.friendlyError(e),
                ),
              ),
            ),
          );
        }
        return false;
      }
      if (picked == null || !mounted) return false;
      final validation = validateIosPath(
        picked.path,
        bookmark: picked.bookmark,
      );
      if (!validation.isValid) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                validation.errorReason ?? context.l10n.setupIcloudNotSupported,
              ),
            ),
          );
        }
        return false;
      }
      ref
          .read(settingsProvider.notifier)
          .setDownloadDirectory(picked.path, iosBookmark: picked.bookmark);
      return true;
    }
    return false;
  }
}
