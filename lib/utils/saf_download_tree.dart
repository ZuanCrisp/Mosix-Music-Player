import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/platform_bridge.dart';

/// Opens the Android SAF tree picker and stores the chosen tree as the
/// download folder. Returns true when a folder was saved. When
/// [setStorageModeFirst] is true the storage mode is switched to 'saf' before
/// the tree URI is stored.
Future<bool> pickAndStoreSafDownloadTree(
  WidgetRef ref, {
  bool setStorageModeFirst = true,
}) async {
  final result = await PlatformBridge.pickSafTree();
  if (result == null) return false;
  final treeUri = result['tree_uri'] as String? ?? '';
  final displayName = result['display_name'] as String? ?? '';
  if (treeUri.isEmpty) return false;
  final notifier = ref.read(settingsProvider.notifier);
  if (setStorageModeFirst) notifier.setStorageMode('saf');
  notifier.setDownloadTreeUri(
    treeUri,
    displayName: displayName.isNotEmpty ? displayName : treeUri,
  );
  return true;
}
