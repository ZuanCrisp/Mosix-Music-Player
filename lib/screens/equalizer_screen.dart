import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:share_plus/share_plus.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/providers/equalizer_provider.dart';
import 'package:mornye/services/playback_equalizer.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_choice_chip.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_menu_button.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/app_switch.dart';
import 'package:mornye/widgets/app_text_field.dart';
import 'package:mornye/widgets/beta_badge.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/expressive_icon_button.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_level_slider.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/slider_value_header.dart';

part 'equalizer_widgets.dart';
part 'equalizer_curve.dart';

class EqualizerScreen extends ConsumerStatefulWidget {
  const EqualizerScreen({super.key});

  @override
  ConsumerState<EqualizerScreen> createState() => _EqualizerScreenState();
}

enum _PresetAction { manage, import, export }

class _EqualizerScreenState extends ConsumerState<EqualizerScreen> {
  bool _busy = false;

  void _message(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _savePreset() async {
    final name = await showAppDialog<String>(
      context: context,
      builder: (context) => const _PresetNameDialog(),
    );
    if (!mounted || name == null) return;
    try {
      ref.read(equalizerProvider.notifier).savePreset(name);
      _message(context.l10n.equalizerSaved);
    } on FormatException catch (error) {
      _message(error.message);
    }
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (file == null) return;
      if ((await file.length() ?? 65537) > 65536) throw const FormatException();
      final source = utf8.decode(await file.readAsBytes());
      if (!mounted) return;
      ref.read(equalizerProvider.notifier).importPreset(source);
      _message(context.l10n.equalizerSaved);
    } catch (_) {
      if (mounted) _message(context.l10n.equalizerImportInvalid);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    final source = ref
        .read(equalizerProvider.notifier)
        .exportPreset('Custom EQ');
    final box = context.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              Uint8List.fromList(utf8.encode(source)),
              mimeType: 'application/json',
            ),
          ],
          fileNameOverrides: ['mornye-equalizer.json'],
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (error) {
      if (mounted) _message(context.l10n.snackbarError(error.toString()));
    }
  }

  Future<void> _presets() => showAppBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    title: context.l10n.equalizerPresets,
    maxHeightFactor: 0.85,
    builder: (sheetContext) => Consumer(
      builder: (context, ref, _) {
        final state = ref.watch(equalizerProvider);
        final selected = _matchingPreset(state);
        final mornye = context.isMornye;
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final preset in [
                ...EqualizerPreset.builtIn,
                ...state.presets,
              ])
                AppSheetOption(
                  title: Text(preset.name),
                  selected: preset == selected,
                  // iOS lists mark the choice with a trailing checkmark.
                  leading: mornye
                      ? null
                      : preset == selected
                      ? const AppIcon(Icons.check)
                      : const AppIcon(Icons.graphic_eq),
                  trailing:
                      (mornye && preset == selected) ||
                          state.presets.contains(preset)
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (mornye && preset == selected)
                              AppIcon(
                                Icons.check,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            if (state.presets.contains(preset))
                              IconButton(
                                tooltip: context.l10n.equalizerDeletePreset,
                                icon: const AppIcon(Icons.delete_outline),
                                onPressed: () => ref
                                    .read(equalizerProvider.notifier)
                                    .deletePreset(preset.name),
                              ),
                          ],
                        )
                      : null,
                  onTap: () {
                    ref.read(equalizerProvider.notifier).applyPreset(preset);
                    Navigator.pop(sheetContext);
                  },
                ),
            ],
          ),
        );
      },
    ),
  );

  Future<void> _reset() async {
    final accepted = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppAlertDialog(
        title: Text(context.l10n.equalizerResetTitle),
        content: Text(context.l10n.equalizerResetDescription),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.dialogCancel),
          ),
          AppDialogAction(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.libraryFilterReset),
          ),
        ],
      ),
    );
    if (mounted && accepted == true) {
      final enabled = ref.read(equalizerProvider).settings.enabled;
      ref
          .read(equalizerProvider.notifier)
          .update(EqualizerSettings(enabled: enabled));
    }
  }

  @override
  Widget build(BuildContext context) => MornyeSettingsTheme(
    // Reached from Playback and Now Playing alike, so the page brings its own
    // inset grouped surfaces in Mornye.
    child: Builder(builder: _buildPage),
  );

  Widget _buildPage(BuildContext context) {
    final state = ref.watch(equalizerProvider);
    final settings = state.settings;
    final notifier = ref.read(equalizerProvider.notifier);
    final l10n = context.l10n;
    final mornye = context.isMornye;
    final selectedPreset = _matchingPreset(state);
    final presetName = selectedPreset?.name ?? l10n.equalizerCustom;
    void update(EqualizerSettings next) => notifier.update(next);
    void setEnabled(bool v) => update(settings.copyWith(enabled: v));
    Widget section(Widget child) => SliverToBoxAdapter(child: child);
    final error = section(
      ValueListenableBuilder<String?>(
        valueListenable: playbackEqualizerError,
        builder: (context, error, _) {
          final message = error ?? state.error;
          return message == null
              ? const SizedBox.shrink()
              : SettingsInfoCard(
                  message: message,
                  icon: Icons.error_outline,
                  tone: SettingsInfoTone.error,
                  glass: true,
                );
        },
      ),
    );
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: l10n.equalizerTitle),
          if (mornye) ...[
            // iOS order: the master switch, its footnote, then the response.
            section(
              SettingsGroup(
                children: [
                  SettingsSwitchItem(
                    icon: Icons.graphic_eq,
                    title: l10n.equalizerEnable,
                    titleTrailing: const BetaBadge(),
                    value: settings.enabled,
                    onChanged: setEnabled,
                    showDivider: false,
                  ),
                ],
              ),
            ),
            section(_Footnote(l10n.equalizerBypass)),
            error,
            section(
              SettingsGroup(
                children: [
                  _EqualizerOverview(
                    settings: settings,
                    presetName: presetName,
                  ),
                ],
              ),
            ),
            // The value cell names the group, so it needs no header.
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
            section(
              SettingsGroup(
                children: [
                  SettingsItem(
                    title: l10n.equalizerPresets,
                    trailing: _DetailValue(presetName),
                    onTap: _presets,
                  ),
                  _ActionRow(
                    label: l10n.equalizerSavePreset,
                    onTap: _savePreset,
                  ),
                  _ActionRow(
                    label: l10n.equalizerImport,
                    onTap: _busy ? null : _import,
                  ),
                  _ActionRow(
                    label: l10n.equalizerExport,
                    onTap: _export,
                    last: true,
                  ),
                ],
              ),
            ),
          ] else ...[
            section(
              SettingsGroup(
                children: [
                  _EqualizerOverview(
                    settings: settings,
                    presetName: presetName,
                    onEnabledChanged: setEnabled,
                  ),
                ],
              ),
            ),
            error,
            section(
              SettingsInfoCard(
                message: l10n.equalizerBypass,
                icon: Icons.info_outline,
              ),
            ),
            section(SettingsSectionHeader(title: l10n.equalizerPresets)),
            section(
              _PresetBar(
                presets: [...EqualizerPreset.builtIn, ...state.presets],
                selected: selectedPreset,
                busy: _busy,
                onApply: notifier.applyPreset,
                onSave: _savePreset,
                onReset: _reset,
                onAction: (action) => switch (action) {
                  _PresetAction.manage => _presets(),
                  _PresetAction.import => _import(),
                  _PresetAction.export => _export(),
                },
              ),
            ),
          ],
          section(SettingsSectionHeader(title: l10n.equalizerBands)),
          section(
            SettingsGroup(
              children: [_BandEditor(settings: settings, onChanged: update)],
            ),
          ),
          section(SettingsSectionHeader(title: l10n.equalizerTone)),
          section(
            SettingsGroup(
              connected: true,
              children: [
                _SliderTile(
                  icon: Icons.volume_up_outlined,
                  title: l10n.equalizerPreamp,
                  subtitle:
                      '${l10n.equalizerEffectivePreamp}: ${_signed(settings.inputGain)} dB',
                  value: settings.preamp,
                  min: -24,
                  max: 12,
                  step: 0.5,
                  unit: 'dB',
                  onChanged: (v) => update(settings.copyWith(preamp: v)),
                ),
                _SliderTile(
                  icon: Icons.speaker_outlined,
                  title: l10n.equalizerBass,
                  value: settings.bass,
                  min: -12,
                  max: 12,
                  step: 0.5,
                  unit: 'dB',
                  centered: true,
                  onChanged: (v) => update(settings.copyWith(bass: v)),
                ),
                _SliderTile(
                  icon: Icons.music_note_outlined,
                  title: l10n.equalizerTreble,
                  value: settings.treble,
                  min: -12,
                  max: 12,
                  step: 0.5,
                  unit: 'dB',
                  centered: true,
                  onChanged: (v) => update(settings.copyWith(treble: v)),
                ),
                _SliderTile(
                  icon: Icons.surround_sound_outlined,
                  title: l10n.equalizerBalance,
                  value: settings.balance * 100,
                  min: -100,
                  max: 100,
                  step: 1,
                  unit: '%',
                  centered: true,
                  last: true,
                  onChanged: (v) => update(settings.copyWith(balance: v / 100)),
                ),
              ],
            ),
          ),
          section(SettingsSectionHeader(title: l10n.equalizerDynamics)),
          section(
            SettingsGroup(
              connected: true,
              children: [
                SettingsSwitchItem(
                  icon: Icons.vertical_align_bottom,
                  title: l10n.equalizerHeadroom,
                  subtitle: l10n.equalizerHeadroomDescription,
                  value: settings.autoHeadroom,
                  onChanged: (v) => update(settings.copyWith(autoHeadroom: v)),
                ),
                SettingsSwitchItem(
                  icon: Icons.health_and_safety_outlined,
                  title: l10n.equalizerLimiter,
                  subtitle: l10n.equalizerLimiterDescription,
                  value: settings.limiter,
                  onChanged: (v) => update(settings.copyWith(limiter: v)),
                ),
                SettingsSwitchItem(
                  icon: Icons.compress,
                  title: l10n.equalizerCompressor,
                  subtitle: l10n.equalizerCompressorDescription,
                  value: settings.compressor,
                  onChanged: (v) => update(settings.copyWith(compressor: v)),
                  showDivider: settings.compressor,
                ),
                if (settings.compressor) ...[
                  _SliderTile(
                    title: l10n.equalizerThreshold,
                    indented: true,
                    value: settings.threshold,
                    min: -60,
                    max: 0,
                    step: 0.5,
                    unit: 'dB',
                    onChanged: (v) => update(settings.copyWith(threshold: v)),
                  ),
                  _SliderTile(
                    title: l10n.equalizerRatio,
                    indented: true,
                    value: settings.ratio,
                    min: 1,
                    max: 20,
                    step: 0.5,
                    unit: ':1',
                    signed: false,
                    onChanged: (v) => update(settings.copyWith(ratio: v)),
                  ),
                  _SliderTile(
                    title: l10n.equalizerAttack,
                    indented: true,
                    value: settings.attack,
                    min: 1,
                    max: 100,
                    step: 1,
                    unit: 'ms',
                    signed: false,
                    onChanged: (v) => update(settings.copyWith(attack: v)),
                  ),
                  _SliderTile(
                    title: l10n.equalizerRelease,
                    indented: true,
                    value: settings.release,
                    min: 20,
                    max: 1000,
                    step: 10,
                    unit: 'ms',
                    signed: false,
                    last: true,
                    onChanged: (v) => update(settings.copyWith(release: v)),
                  ),
                ],
              ],
            ),
          ),
          if (mornye) ...[
            // iOS keeps a destructive command in its own group at the end.
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
            section(
              SettingsGroup(
                children: [
                  _ActionRow(
                    label: l10n.libraryFilterReset,
                    onTap: _reset,
                    destructive: true,
                    last: true,
                  ),
                ],
              ),
            ),
          ],
          SliverToBoxAdapter(
            child: SizedBox(height: 40 + MediaQuery.paddingOf(context).bottom),
          ),
        ],
      ),
    );
  }
}

/// The preset whose curve, tone and dynamics match the current settings.
EqualizerPreset? _matchingPreset(EqualizerState state) {
  // Matches when applying the preset would change nothing.
  String key(EqualizerSettings settings) => jsonEncode(settings.toJson());
  final current = key(state.settings);
  for (final preset in [...EqualizerPreset.builtIn, ...state.presets]) {
    if (key(state.settings.withToneOf(preset.settings)) == current) {
      return preset;
    }
  }
  return null;
}
