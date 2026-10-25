import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:mosix/controllers/metadata_editor_controller.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/providers/extension_provider.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/services/metadata_cover_resources.dart';
import 'package:mosix/services/metadata_autofill_service.dart';
import 'package:mosix/services/metadata_persistence_service.dart';
import 'package:mosix/services/platform_bridge.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/theme/mornye_icons.dart';
import 'package:mosix/utils/artist_utils.dart';
import 'package:mosix/utils/extension_auth_launcher.dart';
import 'package:mosix/utils/logger.dart';
import 'package:mosix/widgets/app_action_button.dart';
import 'package:mosix/widgets/app_bottom_sheet.dart';
import 'package:mosix/widgets/app_choice_chip.dart';
import 'package:mosix/widgets/app_snack_bar.dart';
import 'package:mosix/widgets/app_switch.dart';
import 'package:mosix/widgets/metadata_candidate_tile.dart';
import 'package:mosix/widgets/metadata_text_field.dart';
import 'package:mosix/widgets/mornye_chrome.dart';
import 'package:mosix/widgets/settings_group.dart';

final _log = AppLogger('MetadataEditor');

class _AutoFillPreview {
  final Map<String, String> values;
  final String sourceName;
  final String? coverUrl;
  final String? coverPath;
  final String? coverTempDir;
  final ({int width, int height, int bytes})? coverDetails;

  const _AutoFillPreview({
    required this.values,
    required this.sourceName,
    this.coverUrl,
    this.coverPath,
    this.coverTempDir,
    this.coverDetails,
  });
}

class EditMetadataSheet extends StatefulWidget {
  static const _onlineCoverSentinel = '__online_cover__';
  final ColorScheme colorScheme;
  final Map<String, String> initialValues;
  final String filePath;
  final String? sourceTrackId;
  final int durationMs;
  final String artistTagMode;

  const EditMetadataSheet({
    super.key,
    required this.colorScheme,
    required this.initialValues,
    required this.filePath,
    this.sourceTrackId,
    required this.durationMs,
    required this.artistTagMode,
  });

  @override
  State<EditMetadataSheet> createState() => _EditMetadataSheetState();
}

class _EditMetadataSheetState extends State<EditMetadataSheet> {
  static const _coverResizeDimensions = <int>[500, 1000, 1500, 2000, 3000];

  bool _saving = false;
  final _covers = MetadataCoverResources();
  late final _persistence = MetadataPersistenceService(covers: _covers);
  final _autofill = MetadataAutofillService();
  bool _showAdvanced = false;
  bool _showAutoFill = false;
  bool _fetching = false;
  String? _selectedCoverPath;
  String? _selectedCoverTempDir;
  String? _selectedCoverName;
  String? _currentCoverPath;
  String? _currentCoverTempDir;
  bool _loadingCurrentCover = false;
  int? _coverMaxDimension;
  final Map<String, ({int width, int height, int bytes})> _coverDetails = {};
  final Set<String> _coverDetailLoads = {};
  String? _selectedMetadataProviderId;
  _AutoFillPreview? _autoFillPreview;
  final GlobalKey<ScaffoldMessengerState> _sheetMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  String _metadataProviderName(String? providerId) {
    final normalized = providerId?.trim() ?? '';
    if (normalized.isEmpty) {
      return context.l10n.editMetadataAutoFillSourceAutomatic;
    }
    final extensionState = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(extensionProvider);
    return extensionState.extensions
            .where((extension) => extension.id == normalized)
            .firstOrNull
            ?.displayName ??
        normalized;
  }

  Future<void> _showMetadataProviderPicker(List<Extension> providers) async {
    FocusScope.of(context).unfocus();
    final selectedId = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      builder: (sheetContext) {
        final cs = Theme.of(sheetContext).colorScheme;
        final currentId =
            providers.any(
              (extension) => extension.id == _selectedMetadataProviderId,
            )
            ? _selectedMetadataProviderId!
            : '';
        final options = <({String id, String name, IconData icon})>[
          (
            id: '',
            name: sheetContext.l10n.editMetadataAutoFillSourceAutomatic,
            icon: Icons.auto_awesome_outlined,
          ),
          for (final extension in providers)
            (
              id: extension.id,
              name: extension.displayName,
              icon: Icons.extension_outlined,
            ),
        ];

        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  child: Text(
                    sheetContext.l10n.editMetadataAutoFillSource,
                    style: Theme.of(sheetContext).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _editorOptions(
                      children: [
                        for (var index = 0; index < options.length; index++)
                          _metadataProviderOption(
                            context: sheetContext,
                            id: options[index].id,
                            name: options[index].name,
                            icon: options[index].icon,
                            selected: options[index].id == currentId,
                            showDivider: index != options.length - 1,
                            cs: cs,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted || selectedId == null) return;
    setState(() {
      _selectedMetadataProviderId = selectedId.isEmpty ? null : selectedId;
      _invalidateAutoFillPreview();
    });
  }

  Future<void> _showCoverResolutionPicker() async {
    FocusScope.of(context).unfocus();
    final currentValue = _coverMaxDimension ?? 0;
    final selectedValue = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      builder: (sheetContext) {
        final cs = Theme.of(sheetContext).colorScheme;
        final options = <({int value, String label})>[
          (
            value: 0,
            label: _originalCoverResolutionLabel(
              sheetContext.l10n.trackConvertOriginal,
            ),
          ),
          for (final dimension in _coverResizeDimensions)
            (value: dimension, label: '$dimension px'),
        ];
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  child: Text(
                    sheetContext.l10n.trackCoverResolution,
                    style: Theme.of(sheetContext).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _editorOptions(
                      children: [
                        for (var index = 0; index < options.length; index++)
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 4,
                                ),
                                leading: Icon(
                                  context.isMornye
                                      ? CupertinoIcons.photo
                                      : options[index].value == 0
                                      ? Icons.photo_size_select_actual_outlined
                                      : Icons.photo_size_select_large_outlined,
                                  color: options[index].value == currentValue
                                      ? cs.primary
                                      : cs.onSurfaceVariant,
                                ),
                                title: Text(options[index].label),
                                selected: options[index].value == currentValue,
                                selectedColor: cs.primary,
                                trailing: options[index].value == currentValue
                                    ? Icon(
                                        context.isMornye
                                            ? CupertinoIcons.checkmark
                                            : Icons.check_rounded,
                                      )
                                    : null,
                                onTap: () => Navigator.pop(
                                  sheetContext,
                                  options[index].value,
                                ),
                              ),
                              if (index != options.length - 1)
                                Divider(
                                  height: 1,
                                  indent: 60,
                                  endIndent: 20,
                                  color: cs.outlineVariant.withValues(
                                    alpha: 0.3,
                                  ),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted || selectedValue == null) return;
    setState(() {
      _coverMaxDimension = selectedValue == 0 ? null : selectedValue;
    });
  }

  Widget _metadataProviderOption({
    required BuildContext context,
    required String id,
    required String name,
    required IconData icon,
    required bool selected,
    required bool showDivider,
    required ColorScheme cs,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 4,
          ),
          leading: Icon(
            context.adaptiveIcon(icon),
            color: selected ? cs.primary : cs.onSurfaceVariant,
          ),
          title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
          selected: selected,
          selectedColor: cs.primary,
          trailing: selected
              ? Icon(
                  context.isMornye
                      ? CupertinoIcons.checkmark
                      : Icons.check_rounded,
                )
              : null,
          onTap: () => Navigator.pop(context, id),
        ),
        if (showDivider)
          Divider(
            height: 1,
            indent: 60,
            endIndent: 20,
            color: cs.outlineVariant.withValues(alpha: 0.3),
          ),
      ],
    );
  }

  void _invalidateAutoFillPreview() {
    _form.invalidateLookup();
    final preview = _autoFillPreview;
    _autoFillPreview = null;
    final coverPath = preview?.coverPath;
    if (coverPath != null) {
      _coverDetails.remove(coverPath);
      _coverDetailLoads.remove(coverPath);
    }
    final tempDir = preview?.coverTempDir;
    if (tempDir != null && tempDir.isNotEmpty) {
      unawaited(_covers.release(tempDir));
    }
  }

  void _showSheetSnackBar(String message) {
    final snackBar = SnackBar(content: Text(message));
    final messenger = _sheetMessengerKey.currentState;
    if (messenger != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(snackBar);
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(snackBar);
  }

  late final MetadataEditorController _form;
  bool _fetchingMusicBrainz = false;

  bool _hasValue(String? value) => value != null && value.trim().isNotEmpty;

  String _originalCoverResolutionLabel(String originalLabel) {
    final sourcePath = _selectedCoverPath ?? _currentCoverPath;
    final details = sourcePath == null ? null : _coverDetails[sourcePath];
    if (details == null) return originalLabel;
    return '$originalLabel · ${details.width} × ${details.height} px · '
        '${_formatCoverBytes(details.bytes)}';
  }

  String _formatCoverBytes(int bytes) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }

  Future<void> _loadCoverDetails(String path) async {
    if (_coverDetails.containsKey(path) || !_coverDetailLoads.add(path)) {
      return;
    }
    final details = await _covers.readDetails(path);
    if (!mounted) return;
    setState(() {
      _coverDetailLoads.remove(path);
      final isActivePath =
          path == _currentCoverPath || path == _selectedCoverPath;
      if (isActivePath && details != null) {
        _coverDetails[path] = details;
      }
    });
  }

  String _resolveImageExtension(String? ext, Uint8List? bytes) {
    final normalized = (ext ?? '').toLowerCase();
    if (normalized == 'png' ||
        normalized == 'jpg' ||
        normalized == 'jpeg' ||
        normalized == 'webp') {
      return normalized == 'jpeg' ? 'jpg' : normalized;
    }
    if (bytes != null && bytes.length >= 8) {
      if (bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4E &&
          bytes[3] == 0x47) {
        return 'png';
      }
      if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
        return 'jpg';
      }
      if (bytes.length >= 12 &&
          bytes[0] == 0x52 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x46 &&
          bytes[8] == 0x57 &&
          bytes[9] == 0x45 &&
          bytes[10] == 0x42 &&
          bytes[11] == 0x50) {
        return 'webp';
      }
    }
    return 'jpg';
  }

  Future<void> _cleanupSelectedCoverTemp() async {
    final directory = _selectedCoverTempDir;
    final path = _selectedCoverPath;
    _selectedCoverPath = null;
    _selectedCoverTempDir = null;
    _selectedCoverName = null;
    _coverDetails.remove(path);
    _coverDetailLoads.remove(path);
    await _covers.release(directory);
  }

  Future<void> _loadCurrentCoverPreview() async {
    if (_loadingCurrentCover) return;
    setState(() => _loadingCurrentCover = true);
    final preview = await _covers.extract(widget.filePath);
    if (!mounted) return;
    final oldDirectory = _currentCoverTempDir;
    _coverDetails.remove(_currentCoverPath);
    _coverDetailLoads.remove(_currentCoverPath);
    setState(() {
      _currentCoverPath = preview?.path;
      _currentCoverTempDir = preview?.tempDir;
      _loadingCurrentCover = false;
      if (preview?.details case final details?) {
        _coverDetails[preview!.path] = details;
      }
    });
    await _covers.release(oldDirectory);
  }

  Future<void> _pickCoverImage() async {
    try {
      final picked = await FilePicker.pickFile(type: FileType.image);
      if (picked == null || !mounted) return;
      final sourcePath = picked.path;
      final bytes = _hasValue(sourcePath) ? null : await picked.readAsBytes();
      if (!mounted) return;
      final extension = _resolveImageExtension(
        p.extension(picked.name).replaceFirst('.', ''),
        bytes,
      );
      final preview = await _covers.copyPicked(
        extension: extension,
        sourcePath: sourcePath,
        bytes: bytes,
      );
      if (!mounted) return;
      await _cleanupSelectedCoverTemp();
      if (!mounted) return;
      setState(() {
        _selectedCoverPath = preview.path;
        _selectedCoverTempDir = preview.tempDir;
        _selectedCoverName = picked.name;
      });
      unawaited(_loadCoverDetails(preview.path));
    } catch (e) {
      if (!mounted) return;
      _showSheetSnackBar(context.l10n.snackbarError(context.friendlyError(e)));
    }
  }

  String _fieldLabel(String key) {
    final l10n = context.l10n;
    return switch (key) {
      'title' => l10n.editMetadataFieldTitle,
      'artist' => l10n.editMetadataFieldArtist,
      'album' => l10n.editMetadataFieldAlbum,
      'album_artist' => l10n.editMetadataFieldAlbumArtist,
      'date' => l10n.editMetadataFieldDate,
      'track_number' => l10n.editMetadataFieldTrackNum,
      'total_tracks' => l10n.editMetadataFieldTrackTotal,
      'disc_number' => l10n.editMetadataFieldDiscNum,
      'total_discs' => l10n.editMetadataFieldDiscTotal,
      'genre' => l10n.editMetadataFieldGenre,
      'isrc' => l10n.editMetadataFieldIsrc,
      'lyrics' => l10n.trackLyrics,
      'label' => l10n.editMetadataFieldLabel,
      'copyright' => l10n.editMetadataFieldCopyright,
      'composer' => l10n.editMetadataFieldComposer,
      'comment' => l10n.editMetadataFieldComment,
      'album_type' => l10n.trackAlbumType,
      'explicit' => l10n.editMetadataFieldExplicit,
      'upc' => l10n.editMetadataFieldUpc,
      'cover' => l10n.editMetadataFieldCover,
      _ => key,
    };
  }

  void _selectAllFields() {
    setState(() {
      _invalidateAutoFillPreview();
      _form.autoFillFields.addAll(MetadataEditorController.fieldKeys);
    });
  }

  void _selectEmptyFields() {
    setState(() {
      _invalidateAutoFillPreview();
      _form.selectEmptyFields(
        hasCover: _hasValue(_currentCoverPath) || _hasValue(_selectedCoverPath),
      );
    });
  }

  void _selectNoFields() {
    setState(() {
      _invalidateAutoFillPreview();
      _form.autoFillFields.clear();
    });
  }

  Future<List<Map<String, dynamic>>> _searchAutoFillCandidates({
    required String query,
    required bool usesAutomaticProvider,
    required Extension? selectedProvider,
    required ExtensionState extensionState,
    bool allowVerificationRetry = true,
  }) async {
    try {
      return await _autofill.search(query, provider: selectedProvider);
    } catch (error) {
      if (!allowVerificationRetry || !isExtensionVerificationRequired(error)) {
        rethrow;
      }

      final extensionId = usesAutomaticProvider
          ? extensionIdFromVerificationError(
              error,
              extensionState.extensions.map((extension) => extension.id),
            )
          : selectedProvider?.id;
      if (extensionId == null || extensionId.isEmpty) rethrow;

      _log.i(
        'Metadata autofill requires verification; waiting for $extensionId',
      );
      final verified = await openVerificationAndAwaitGrant(
        extensionId,
        browserMode: ProviderScope.containerOf(
          context,
          listen: false,
        ).read(settingsProvider).extensionVerificationBrowserMode,
      );
      if (!verified || !mounted) rethrow;

      return _searchAutoFillCandidates(
        query: query,
        usesAutomaticProvider: usesAutomaticProvider,
        selectedProvider: selectedProvider,
        extensionState: extensionState,
        allowVerificationRetry: false,
      );
    }
  }

  Future<Map<String, dynamic>?> _showAutoFillCandidatePicker({
    required List<Map<String, dynamic>> candidates,
    required String sourceName,
    required String currentTitle,
    required String currentArtist,
  }) {
    return showAppBottomSheet<Map<String, dynamic>>(
      context: context,
      useRootNavigator: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      title: context.l10n.editMetadataAutoFillSource,
      subtitle: [
        currentTitle,
        currentArtist,
        sourceName,
      ].where((value) => value.trim().isNotEmpty).join(' · '),
      maxHeightFactor: 0.82,
      builder: (sheetContext) => ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          _editorOptions(
            children: [
              for (var index = 0; index < candidates.length; index++) ...[
                MetadataCandidateTile(
                  candidate: candidates[index],
                  onTap: () => Navigator.pop(sheetContext, candidates[index]),
                ),
                if (index != candidates.length - 1)
                  Divider(
                    height: 1,
                    indent: 88,
                    endIndent: 16,
                    color: Theme.of(
                      sheetContext,
                    ).colorScheme.outlineVariant.withValues(alpha: 0.3),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _fetchAutoFillPreview() async {
    if (_fetching || _saving) return;
    if (_form.autoFillFields.isEmpty) {
      _showSheetSnackBar(context.l10n.editMetadataAutoFillNoneSelected);
      return;
    }

    setState(() {
      _fetching = true;
      _invalidateAutoFillPreview();
    });
    final generation = _form.beginLookup();
    bool isCurrent() => mounted && _form.isCurrent(generation);
    final currentValues = _form.values;
    final fields = Set<String>.of(_form.autoFillFields);
    final settingsNotifier = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(settingsProvider.notifier);

    try {
      final title = currentValues['title']!.trim();
      final artist = currentValues['artist']!.trim();
      final album = currentValues['album']!.trim();
      final albumArtist = currentValues['album_artist']!.trim();
      final searchArtist = primaryArtistName(artist, albumArtist: albumArtist);
      final currentIsrc = currentValues['isrc']!.trim().toUpperCase();
      final configuredProviderId = _selectedMetadataProviderId?.trim();
      final extensionState = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(extensionProvider);
      final selectedProvider = configuredProviderId == null
          ? null
          : extensionState.extensions
                .where(
                  (extension) =>
                      extension.id == configuredProviderId &&
                      extension.enabled &&
                      extension.hasMetadataProvider,
                )
                .firstOrNull;
      final selectedProviderId = selectedProvider?.id;
      final usesAutomaticProvider =
          selectedProviderId == null || selectedProviderId.isEmpty;
      final needsTrackLookup = fields.any((key) => key != 'lyrics');
      Map<String, dynamic>? best;

      final queryParts = <String>[];
      if (title.isNotEmpty) queryParts.add(title);
      if (searchArtist.isNotEmpty) queryParts.add(searchArtist);
      if (queryParts.isEmpty && album.isNotEmpty) queryParts.add(album);

      if (needsTrackLookup && queryParts.isEmpty) {
        if (mounted) {
          _showSheetSnackBar(context.l10n.editMetadataAutoFillNoResults);
        }
        return;
      }

      final normalizedTitle = _autofill.normalizeText(title);
      final normalizedArtist = _autofill.normalizeText(searchArtist);
      final normalizedAlbum = _autofill.normalizeText(album);

      if (needsTrackLookup) {
        final query = queryParts.join(' ');
        final results = await _searchAutoFillCandidates(
          query: query,
          usesAutomaticProvider: usesAutomaticProvider,
          selectedProvider: selectedProvider,
          extensionState: extensionState,
        );

        if (!mounted || !isCurrent()) return;

        if (results.isEmpty) {
          _showSheetSnackBar(context.l10n.editMetadataAutoFillNoResults);
          return;
        }

        final rankedResults = [...results]
          ..sort((a, b) {
            final aScore = _autofill.matchScore(
              a,
              currentTitle: normalizedTitle,
              currentArtist: normalizedArtist,
              currentAlbum: normalizedAlbum,
              currentIsrc: currentIsrc,
            );
            final bScore = _autofill.matchScore(
              b,
              currentTitle: normalizedTitle,
              currentArtist: normalizedArtist,
              currentAlbum: normalizedAlbum,
              currentIsrc: currentIsrc,
            );
            return bScore.compareTo(aScore);
          });

        if (usesAutomaticProvider) {
          best = rankedResults.first;
          if (!_autofill.matchIsConfident(
            best,
            currentTitle: normalizedTitle,
            currentArtist: normalizedArtist,
            currentAlbum: normalizedAlbum,
            currentIsrc: currentIsrc,
          )) {
            best = null;
          }
        } else {
          best = await _showAutoFillCandidatePicker(
            candidates: rankedResults,
            sourceName: _metadataProviderName(selectedProviderId),
            currentTitle: title,
            currentArtist: searchArtist,
          );
          if (!mounted || !isCurrent() || best == null) return;
        }

        if (best == null) {
          _showSheetSnackBar(context.l10n.editMetadataAutoFillNoResults);
          return;
        }

        best = await _autofill.resolveDetails(
          best,
          providerId: usesAutomaticProvider
              ? best['provider_id']?.toString().trim() ?? ''
              : selectedProviderId,
          includeCover: fields.contains('cover'),
        );
      }

      final selectedBest = best;
      if (needsTrackLookup && selectedBest == null) {
        throw StateError('No metadata match resolved for auto-fill');
      }

      final result = await _autofill.enrich(
        selectedBest,
        currentValues: currentValues,
        fields: fields,
        providerId: selectedProviderId,
        sourceTrackId: widget.sourceTrackId,
        durationMs: widget.durationMs,
        syncLyricsSettings: settingsNotifier.syncLyricsSettingsToBackend,
        isCurrent: isCurrent,
      );
      if (!mounted || !isCurrent() || result == null) return;
      final availableValues = result.values;
      final coverUrl = result.coverUrl;
      final hasSelectedValue = _form.autoFillFields.any(
        (key) => key == 'cover'
            ? coverUrl != null && coverUrl.isNotEmpty
            : availableValues.containsKey(key),
      );
      if (!hasSelectedValue) {
        _showSheetSnackBar(context.l10n.editMetadataAutoFillNoResults);
        return;
      }

      final coverPreview =
          _form.autoFillFields.contains('cover') &&
              coverUrl != null &&
              coverUrl.isNotEmpty
          ? await _covers.download(coverUrl)
          : null;
      if (!mounted || !isCurrent()) {
        if (coverPreview != null) {
          await _covers.release(coverPreview.tempDir);
        }
        return;
      }

      final resolvedSourceName = result.lyricsSource?.isNotEmpty == true
          ? result.lyricsSource!
          : _metadataProviderName(result.sourceId);
      setState(() {
        _autoFillPreview = _AutoFillPreview(
          values: availableValues,
          sourceName: resolvedSourceName,
          coverUrl: coverUrl?.isNotEmpty == true ? coverUrl : null,
          coverPath: coverPreview?.path,
          coverTempDir: coverPreview?.tempDir,
          coverDetails: coverPreview?.details,
        );
        if (coverPreview?.details case final details?) {
          _coverDetails[coverPreview!.path] = details;
        }
      });
    } catch (e, stackTrace) {
      _log.e('Metadata auto-fill failed: $e', e, stackTrace);
      if (mounted && isCurrent()) {
        _showSheetSnackBar(
          context.l10n.snackbarError(context.friendlyError(e)),
        );
      }
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<void> _applyAutoFillPreview() async {
    final preview = _autoFillPreview;
    if (preview == null || _saving || _fetching) return;

    setState(() => _fetching = true);
    try {
      var filledCount = _form.apply(preview.values);
      var coverDownloadFailed = false;

      if (_form.autoFillFields.contains('cover') && preview.coverUrl != null) {
        var coverPath = preview.coverPath;
        var coverTempDir = preview.coverTempDir;
        var coverDetails = preview.coverDetails;
        if (coverPath == null ||
            coverTempDir == null ||
            !await File(coverPath).exists()) {
          final downloaded = await _covers.download(preview.coverUrl!);
          coverPath = downloaded?.path;
          coverTempDir = downloaded?.tempDir;
          coverDetails = downloaded?.details;
        }
        if (coverPath != null && coverTempDir != null) {
          await _cleanupSelectedCoverTemp();
          if (mounted) {
            _selectedCoverPath = coverPath;
            _selectedCoverTempDir = coverTempDir;
            _selectedCoverName = EditMetadataSheet._onlineCoverSentinel;
            if (coverDetails != null) {
              _coverDetails[coverPath] = coverDetails;
            } else {
              unawaited(_loadCoverDetails(coverPath));
            }
            filledCount++;
          }
        } else {
          coverDownloadFailed = true;
        }
      }

      if (!mounted) return;
      setState(() {
        if (filledCount > 0) {
          final previewCoverWasTransferred =
              preview.coverPath != null &&
              preview.coverPath == _selectedCoverPath;
          if (previewCoverWasTransferred) {
            _autoFillPreview = null;
          } else {
            _invalidateAutoFillPreview();
          }
        }
      });
      _showSheetSnackBar(
        coverDownloadFailed
            ? context.l10n.updateDownloadFailed
            : filledCount > 0
            ? context.l10n.editMetadataAutoFillDoneFromSource(
                filledCount,
                preview.sourceName,
              )
            : context.l10n.editMetadataAutoFillNoResults,
      );
    } catch (e) {
      if (mounted) {
        _showSheetSnackBar(
          context.l10n.snackbarError(context.friendlyError(e)),
        );
      }
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _form = MetadataEditorController(widget.initialValues);
    unawaited(_loadCurrentCoverPreview());
  }

  @override
  void dispose() {
    unawaited(_covers.dispose());
    _form.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || _fetching || _fetchingMusicBrainz) return;
    setState(() => _saving = true);
    try {
      final result = await _persistence.save(
        MetadataSaveRequest(
          filePath: widget.filePath,
          metadata: _form.saveMetadata(artistTagMode: widget.artistTagMode),
          artistTagMode: widget.artistTagMode,
          selectedCoverPath: _selectedCoverPath,
          currentCoverPath: _currentCoverPath,
          coverMaxDimension: _coverMaxDimension,
        ),
      );
      if (!mounted) return;
      if (result.failure == null) {
        Navigator.pop(context, true);
        return;
      }
      final l10n = context.l10n;
      _showSheetSnackBar(switch (result.failure!) {
        MetadataSaveFailure.backend => context.friendlyError(
          result.error,
          fallback: l10n.metadataSaveFailedFfmpeg,
        ),
        MetadataSaveFailure.ffmpeg => l10n.metadataSaveFailedFfmpeg,
        MetadataSaveFailure.storage => l10n.metadataSaveFailedStorage,
        MetadataSaveFailure.noCover => l10n.snackbarError(
          l10n.trackCoverNoEmbeddedArt,
        ),
        MetadataSaveFailure.resize => l10n.snackbarError(
          l10n.trackCoverResizeFailed,
        ),
        MetadataSaveFailure.unexpected => l10n.snackbarError(
          context.friendlyError(result.error),
        ),
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.colorScheme;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => AppScaffoldMessenger(
          key: _sheetMessengerKey,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: false,
            body: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 8),
                  child: const AppSheetHandle(),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          context.l10n.trackEditMetadata,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      if (_saving)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: context.isMornye
                                ? const CupertinoActivityIndicator()
                                : const CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                          ),
                        )
                      else
                        AppActionButton(
                          onPressed: _fetching || _fetchingMusicBrainz
                              ? null
                              : _save,
                          icon: const Icon(Icons.check, size: 18),
                          label: Text(context.l10n.dialogSave),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  color: cs.outlineVariant.withValues(alpha: 0.5),
                ),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
                    children: [
                      _buildCoverEditor(cs),
                      _buildAutoFillSection(cs),
                      _sectionCard(
                        icon: Icons.info_outline,
                        title: context.l10n.trackMetadata,
                        children: [
                          MetadataTextField(
                            cs,
                            context.l10n.editMetadataFieldTitle,
                            _form['title']!,
                          ),
                          MetadataTextField(
                            cs,
                            context.l10n.editMetadataFieldArtist,
                            _form['artist']!,
                          ),
                          MetadataTextField(
                            cs,
                            context.l10n.editMetadataFieldAlbum,
                            _form['album']!,
                          ),
                          MetadataTextField(
                            cs,
                            context.l10n.editMetadataFieldAlbumArtist,
                            _form['album_artist']!,
                          ),
                          MetadataTextField(
                            cs,
                            context.l10n.editMetadataFieldDate,
                            _form['date']!,
                            hint: context.l10n.editMetadataFieldDateHint,
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: MetadataTextField(
                                  cs,
                                  context.l10n.editMetadataFieldTrackNum,
                                  _form['track_number']!,
                                  keyboard: TextInputType.number,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: MetadataTextField(
                                  cs,
                                  context.l10n.editMetadataFieldTrackTotal,
                                  _form['total_tracks']!,
                                  keyboard: TextInputType.number,
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: MetadataTextField(
                                  cs,
                                  context.l10n.editMetadataFieldDiscNum,
                                  _form['disc_number']!,
                                  keyboard: TextInputType.number,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: MetadataTextField(
                                  cs,
                                  context.l10n.editMetadataFieldDiscTotal,
                                  _form['total_discs']!,
                                  keyboard: TextInputType.number,
                                ),
                              ),
                            ],
                          ),
                          MetadataTextField(
                            cs,
                            context.l10n.editMetadataFieldGenre,
                            _form['genre']!,
                          ),
                          MetadataTextField(
                            cs,
                            context.l10n.editMetadataFieldIsrc,
                            _form['isrc']!,
                          ),
                        ],
                      ),
                      _sectionCard(
                        icon: Icons.lyrics_outlined,
                        title: context.l10n.trackLyrics,
                        children: [
                          MetadataTextField(
                            cs,
                            context.l10n.trackLyrics,
                            _form['lyrics']!,
                            maxLines: 8,
                            keyboard: TextInputType.multiline,
                          ),
                        ],
                      ),
                      _sectionCard(
                        icon: Icons.tune,
                        title: context.l10n.editMetadataAdvanced,
                        onHeaderTap: () =>
                            setState(() => _showAdvanced = !_showAdvanced),
                        expanded: _showAdvanced,
                        children: [
                          if (_showAdvanced) ...[
                            MetadataTextField(
                              cs,
                              context.l10n.editMetadataFieldLabel,
                              _form['label']!,
                            ),
                            MetadataTextField(
                              cs,
                              context.l10n.editMetadataFieldCopyright,
                              _form['copyright']!,
                            ),
                            MetadataTextField(
                              cs,
                              context.l10n.editMetadataFieldComposer,
                              _form['composer']!,
                            ),
                            MetadataTextField(
                              cs,
                              context.l10n.trackAlbumType,
                              _form['album_type']!,
                              hint: context.l10n.editMetadataFieldAlbumTypeHint,
                            ),
                            _switchField(
                              label: context.l10n.editMetadataFieldExplicit,
                              subtitle:
                                  context.l10n.editMetadataFieldExplicitHint,
                              value: _form.explicit,
                              onChanged: (value) =>
                                  setState(() => _form.explicit = value),
                            ),
                            MetadataTextField(
                              cs,
                              context.l10n.editMetadataFieldUpc,
                              _form['upc']!,
                              hint: context.l10n.editMetadataFieldUpcHint,
                              keyboard: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(18),
                              ],
                            ),
                            MetadataTextField(
                              cs,
                              context.l10n.editMetadataFieldComment,
                              _form['comment']!,
                              maxLines: 3,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAutoFillSection(ColorScheme cs) {
    return _sectionCard(
      icon: Icons.travel_explore,
      title: context.l10n.editMetadataAutoFill,
      onHeaderTap: () => setState(() => _showAutoFill = !_showAutoFill),
      expanded: _showAutoFill,
      children: [
        if (_showAutoFill) ...[
          Text(
            context.l10n.editMetadataAutoFillDesc,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Consumer(
            builder: (context, ref, _) {
              final extensionState = ref.watch(extensionProvider);
              final providers = _autofill.orderedProviders(extensionState);
              final selectedProviderIsAvailable = providers.any(
                (extension) => extension.id == _selectedMetadataProviderId,
              );
              final selectedId = selectedProviderIsAvailable
                  ? _selectedMetadataProviderId
                  : null;
              return _selectionField(
                label: context.l10n.editMetadataAutoFillSource,
                value: _metadataProviderName(selectedId),
                enabled: !_fetching && !_saving,
                onTap: () => _showMetadataProviderPicker(providers),
              );
            },
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _quickSelectButton(
                label: context.l10n.editMetadataSelectAll,
                onTap: _selectAllFields,
                cs: cs,
              ),
              _quickSelectButton(
                label: context.l10n.editMetadataSelectEmpty,
                onTap: _selectEmptyFields,
                cs: cs,
              ),
              _quickSelectButton(
                label: context.l10n.editMetadataSelectNone,
                onTap: _selectNoFields,
                cs: cs,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: MetadataEditorController.fieldKeys.map((key) {
              final selected = _form.autoFillFields.contains(key);
              if (context.isMornye) {
                return MornyeFilterChip(
                  label: _fieldLabel(key),
                  selected: selected,
                  glass: false,
                  icon: selected
                      ? CupertinoIcons.checkmark_circle_fill
                      : CupertinoIcons.circle,
                  onTap: _fetching
                      ? null
                      : () => setState(() {
                          _invalidateAutoFillPreview();
                          if (selected) {
                            _form.autoFillFields.remove(key);
                          } else {
                            _form.autoFillFields.add(key);
                          }
                        }),
                );
              }
              return AppChoiceChip(
                label: Text(_fieldLabel(key)),
                selected: selected,
                onSelected: _fetching
                    ? null
                    : (val) {
                        setState(() {
                          _invalidateAutoFillPreview();
                          if (val) {
                            _form.autoFillFields.add(key);
                          } else {
                            _form.autoFillFields.remove(key);
                          }
                        });
                      },
              );
            }).toList(),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: AppActionButton(
              glass: false,
              onPressed: (_fetching || _saving || _form.autoFillFields.isEmpty)
                  ? null
                  : _fetchAutoFillPreview,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: _fetching
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.auto_fix_high),
              label: Text(
                _fetching
                    ? context.l10n.editMetadataAutoFillSearching
                    : context.l10n.editMetadataAutoFillFind,
              ),
            ),
          ),
          if (_autoFillPreview case final preview?) ...[
            const SizedBox(height: 12),
            _buildAutoFillPreview(cs, preview),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: AppActionButton(
              outlined: true,
              glass: false,
              tonal: true,
              onPressed: (_fetching || _fetchingMusicBrainz || _saving)
                  ? null
                  : _fetchFromMusicBrainz,
              style: OutlinedButton.styleFrom(
                backgroundColor: cs.surfaceContainerHigh,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: _fetchingMusicBrainz
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.library_music_outlined),
              label: Text(context.l10n.editMetadataMusicBrainzButton),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _buildAutoFillPreview(ColorScheme cs, _AutoFillPreview preview) {
    final previewFields = _form.autoFillFields
        .where((key) {
          if (key == 'cover') return preview.coverUrl != null;
          return preview.values.containsKey(key);
        })
        .toList(growable: false);

    return Container(
      width: double.infinity,
      padding: context.isMornye
          ? const EdgeInsets.symmetric(vertical: 12)
          : const EdgeInsets.all(12),
      decoration: context.isMornye
          ? null
          : BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cs.outlineVariant),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.fact_check_outlined, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.editMetadataAutoFillPreview(preview.sourceName),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (preview.coverPath case final coverPath?) ...[
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(
                  File(coverPath),
                  width: 112,
                  height: 112,
                  fit: BoxFit.cover,
                  cacheWidth: (112 * MediaQuery.devicePixelRatioOf(context))
                      .round(),
                  cacheHeight: (112 * MediaQuery.devicePixelRatioOf(context))
                      .round(),
                  filterQuality: FilterQuality.low,
                  semanticLabel:
                      context.l10n.editMetadataAutoFillCoverAvailable,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
            if (preview.coverDetails case final details?) ...[
              const SizedBox(height: 6),
              Center(
                child: Text(
                  '${details.width} × ${details.height} px · '
                  '${_formatCoverBytes(details.bytes)}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
          ],
          ...previewFields.map((key) {
            final details = preview.coverDetails;
            final value = key == 'cover'
                ? details != null
                      ? '${details.width} × ${details.height} px · '
                            '${_formatCoverBytes(details.bytes)}'
                      : context.l10n.editMetadataAutoFillCoverAvailable
                : preview.values[key]!;
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 104,
                    child: Text(
                      _fieldLabel(key),
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      value,
                      maxLines: key == 'lyrics' ? 3 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: AppActionButton(
              outlined: context.isMornye,
              glass: false,
              onPressed: (_fetching || _saving) ? null : _applyAutoFillPreview,
              icon: const Icon(Icons.check),
              label: Text(context.l10n.editMetadataAutoFillApply),
            ),
          ),
        ],
      ),
    );
  }

  /// Fills genre and album artist from MusicBrainz (keyed by ISRC) as
  /// editable suggestions; nothing is saved until the user taps Save.
  Future<void> _fetchFromMusicBrainz() async {
    if (_saving || _fetching || _fetchingMusicBrainz) return;
    final isrc = _form['isrc']!.text.trim();
    if (isrc.isEmpty) {
      _showSheetSnackBar(context.l10n.editMetadataMusicBrainzNeedsIsrc);
      return;
    }
    setState(() => _fetchingMusicBrainz = true);
    final generation = _form.beginLookup();
    try {
      final tags = await PlatformBridge.fetchMusicBrainzTags(
        isrc: isrc,
        albumName: _form['album']!.text.trim(),
      );
      if (!mounted || !_form.isCurrent(generation)) return;
      var filled = 0;
      if (tags.genre.isNotEmpty) {
        _form['genre']!.text = tags.genre;
        filled++;
      }
      if (tags.albumArtist.isNotEmpty) {
        _form['album_artist']!.text = tags.albumArtist;
        filled++;
      }
      _showSheetSnackBar(
        filled > 0
            ? context.l10n.editMetadataMusicBrainzFilled
            : context.l10n.editMetadataMusicBrainzNothing,
      );
    } catch (_) {
      if (mounted) {
        _showSheetSnackBar(context.l10n.editMetadataMusicBrainzNothing);
      }
    } finally {
      if (mounted) setState(() => _fetchingMusicBrainz = false);
    }
  }

  Widget _editorOptions({required List<Widget> children}) {
    if (!context.isMornye) return SettingsGroup(children: children);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Material(
        color: MornyeTheme.controlFill(context),
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }

  Widget _quickSelectButton({
    required String label,
    required VoidCallback onTap,
    required ColorScheme cs,
  }) {
    if (context.isMornye) {
      return CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        onPressed: _fetching ? null : onTap,
        child: Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: cs.primary),
        ),
      );
    }
    return InkWell(
      onTap: _fetching ? null : onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cs.outline.withValues(alpha: 0.5)),
        ),
        child: Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: cs.primary),
        ),
      ),
    );
  }

  Widget _buildCoverEditor(ColorScheme cs) {
    final hasSelectedCover = _hasValue(_selectedCoverPath);
    final hasCurrentCover = _hasValue(_currentCoverPath);
    return _sectionCard(
      icon: Icons.image_outlined,
      title: context.l10n.editMetadataFieldCover,
      children: [
        if (_loadingCurrentCover)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: LinearProgressIndicator(minHeight: 2),
          )
        else if (!hasCurrentCover && !hasSelectedCover)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              context.l10n.trackCoverNoEmbeddedArt,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: AppActionButton(
                outlined: true,
                glass: false,
                onPressed: _saving ? null : _pickCoverImage,
                icon: const Icon(Icons.image_outlined),
                label: Text(
                  hasSelectedCover
                      ? context.l10n.trackCoverReplace
                      : context.l10n.trackCoverPick,
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            if (hasSelectedCover) ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: context.l10n.trackCoverClearSelected,
                onPressed: _saving
                    ? null
                    : () async {
                        await _cleanupSelectedCoverTemp();
                        if (!mounted) return;
                        setState(() {});
                      },
                icon: const Icon(Icons.close),
              ),
            ],
          ],
        ),
        if (hasCurrentCover || hasSelectedCover) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              if (hasCurrentCover)
                Expanded(
                  child: _buildCoverPreviewTile(
                    cs: cs,
                    path: _currentCoverPath!,
                    label: context.l10n.trackCoverCurrent,
                  ),
                ),
              if (hasCurrentCover && hasSelectedCover)
                const SizedBox(width: 12),
              if (hasSelectedCover)
                Expanded(
                  child: _buildCoverPreviewTile(
                    cs: cs,
                    path: _selectedCoverPath!,
                    label:
                        _selectedCoverName ==
                            EditMetadataSheet._onlineCoverSentinel
                        ? context.l10n.trackCoverOnline
                        : (_selectedCoverName ??
                              context.l10n.trackCoverSelected),
                  ),
                ),
            ],
          ),
          if (hasSelectedCover) ...[
            const SizedBox(height: 8),
            Text(
              context.l10n.trackCoverReplaceNotice,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 12),
          _selectionField(
            label: context.l10n.trackCoverResolution,
            value: _coverMaxDimension == null
                ? _originalCoverResolutionLabel(
                    context.l10n.trackConvertOriginal,
                  )
                : '${_coverMaxDimension!} px',
            enabled: !_saving,
            onTap: _showCoverResolutionPicker,
          ),
          Text(
            context.l10n.trackCoverResolutionHint,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildCoverPreviewTile({
    required ColorScheme cs,
    required String path,
    required String label,
  }) {
    final details = _coverDetails[path];
    final loadingDetails = _coverDetailLoads.contains(path);
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: cs.shadow.withValues(alpha: 0.15),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              File(path),
              height: 160,
              width: 160,
              fit: BoxFit.cover,
              cacheWidth: (160 * MediaQuery.devicePixelRatioOf(context))
                  .round(),
              cacheHeight: (160 * MediaQuery.devicePixelRatioOf(context))
                  .round(),
              filterQuality: FilterQuality.low,
              errorBuilder: (_, _, _) => Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.broken_image,
                  color: cs.onSurfaceVariant,
                  size: 32,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 3),
        if (details != null)
          Text(
            '${details.width} × ${details.height} px · '
            '${_formatCoverBytes(details.bytes)}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          )
        else if (loadingDetails)
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: cs.primary,
            ),
          ),
      ],
    );
  }

  Widget _switchField({
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final cs = widget.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        children: [
          Material(
            color: metadataEditorFieldFill(context, cs),
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: AppSwitchListTile(
              adaptive: true,
              value: value,
              onChanged: onChanged,
              contentPadding: EdgeInsets.symmetric(
                horizontal: context.isMornye ? 4 : 16,
              ),
              title: Text(label, style: Theme.of(context).textTheme.bodyLarge),
              subtitle: Text(
                subtitle,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          ),
          if (context.isMornye) const Divider(height: 0.5),
        ],
      ),
    );
  }

  Widget _selectionField({
    required String label,
    required String value,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    final cs = widget.colorScheme;
    if (context.isMornye) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
            CupertinoButton(
              color: metadataEditorFieldFill(context, cs),
              disabledColor: Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
              onPressed: enabled ? onTap : null,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: enabled ? cs.onSurface : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    CupertinoIcons.chevron_up_chevron_down,
                    size: 16,
                    color: cs.primary,
                  ),
                ],
              ),
            ),
            const Divider(height: 0.5),
          ],
        ),
      );
    }
    final radius = BorderRadius.circular(14);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: enabled ? cs.onSurfaceVariant : cs.outline,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
          ),
          Material(
            color: metadataEditorFieldFill(context, cs),
            borderRadius: radius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: enabled ? onTap : null,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: enabled ? cs.onSurface : cs.outline,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.expand_more_rounded,
                      color: enabled ? cs.onSurfaceVariant : cs.outline,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  RoundedRectangleBorder _sectionCardShape(ColorScheme cs) {
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
    );
  }

  /// Titled section card. When [onHeaderTap] is set the header is a full-width
  /// tappable row (ripple clipped to the card) with an auto chevron.
  Widget _sectionCard({
    required IconData icon,
    required String title,
    required List<Widget> children,
    VoidCallback? onHeaderTap,
    bool expanded = true,
  }) {
    final cs = widget.colorScheme;
    final collapsible = onHeaderTap != null;
    const inset = 16.0;

    final headerRow = Row(
      children: [
        Icon(context.adaptiveIcon(icon), size: 20, color: cs.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
        ),
        if (collapsible)
          AnimatedRotation(
            turns: expanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: Icon(
              context.isMornye
                  ? CupertinoIcons.chevron_down
                  : Icons.expand_more,
              size: 22,
              color: cs.onSurfaceVariant,
            ),
          ),
      ],
    );

    final Widget header = collapsible
        ? InkWell(
            onTap: onHeaderTap,
            child: Padding(
              padding: EdgeInsets.fromLTRB(inset, 16, inset, 16),
              child: headerRow,
            ),
          )
        : Padding(
            padding: EdgeInsets.fromLTRB(inset, 16, inset, 8),
            child: headerRow,
          );

    final content = AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          if (children.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(inset, 0, inset, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
            ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: context.isMornye
          ? Material(
              color: MornyeTheme.controlFill(context),
              borderRadius: BorderRadius.circular(28),
              clipBehavior: Clip.antiAlias,
              child: DividerTheme(
                data: DividerTheme.of(
                  context,
                ).copyWith(color: MornyeTheme.metadataDividerColor(context)),
                child: content,
              ),
            )
          : Card(
              elevation: 0,
              margin: EdgeInsets.zero,
              color: settingsGroupColor(context),
              shape: _sectionCardShape(cs),
              clipBehavior: Clip.antiAlias,
              child: content,
            ),
    );
  }
}
