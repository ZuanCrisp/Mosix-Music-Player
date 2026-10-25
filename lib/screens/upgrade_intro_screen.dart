import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/models/theme_settings.dart';
import 'package:mosix/providers/theme_provider.dart';
import 'package:mosix/theme/app_theme.dart';
import 'package:mosix/theme/mornye_icons.dart';
import 'package:mosix/theme/mornye_theme.dart';

/// A local, replayable release tour. Theme changes require an explicit choice.
class UpgradeIntroScreen extends StatefulWidget {
  const UpgradeIntroScreen({super.key});

  @override
  State<UpgradeIntroScreen> createState() => _UpgradeIntroScreenState();
}

class _UpgradeIntroScreenState extends State<UpgradeIntroScreen> {
  final _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _goTo(int page) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _pages.jumpToPage(page);
    } else {
      _pages.animateToPage(
        page,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  void _finish() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final mornye = context.isMornye;
    final pageCount = mornye ? 5 : 3;
    final last = _page == pageCount - 1;
    return PopScope(
      canPop: _page == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goTo(_page - 1);
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        if (_page > 0)
                          IconButton(
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).backButtonTooltip,
                            onPressed: () => _goTo(_page - 1),
                            color: scheme.primary,
                            icon: Icon(
                              mornye
                                  ? CupertinoIcons.chevron_back
                                  : Icons.arrow_back,
                            ),
                          )
                        else
                          const SizedBox(width: 48, height: 48),
                        const Spacer(),
                        TextButton(
                          onPressed: _finish,
                          child: Text(l10n.upgradeIntroSkip),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: PageView(
                      controller: _pages,
                      onPageChanged: (page) => setState(() => _page = page),
                      children: [
                        _TourPage(
                          title: l10n.upgradeIntroWelcome,
                          description: l10n.upgradeIntroWelcomeBody,
                          children: [
                            _TourFeature(
                              icon: Icons.play_circle_outline,
                              title: 'Mornye',
                              body: l10n.upgradeIntroMornyeBody,
                            ),
                            _TourFeature(
                              icon: Icons.library_music_outlined,
                              title: l10n.navLibrary,
                              body: l10n.upgradeIntroLibrarySummary,
                            ),
                            _TourFeature(
                              icon: Icons.extension_outlined,
                              title: l10n.navStore,
                              body: l10n.upgradeIntroRepoSummary,
                            ),
                          ],
                        ),
                        _TourPage(
                          title: l10n.upgradeIntroThemeTitle,
                          description: l10n.upgradeIntroThemeBody,
                          children: const [_ThemePicker()],
                        ),
                        if (mornye)
                          _TourPage(
                            title: l10n.upgradeIntroLibraryTitle,
                            description: l10n.upgradeIntroLibraryBody,
                            children: [
                              const _LibraryPreview(),
                              const SizedBox(height: 28),
                              _TourFeature(
                                icon: Icons.downloading_outlined,
                                title: l10n.libraryDownloads,
                                body: l10n.upgradeIntroDownloadsBody,
                              ),
                              _TourFeature(
                                icon: Icons.search,
                                title: l10n.mornyeSearch,
                                body: l10n.upgradeIntroSearchBody,
                              ),
                            ],
                          ),
                        _TourPage(
                          title: l10n.upgradeIntroRustTitle,
                          description: l10n.upgradeIntroRustBody,
                          hero: Icon(
                            Icons.memory_outlined,
                            size: 76,
                            color: scheme.primary,
                          ),
                          children: [
                            _TourFeature(
                              icon: Icons.download_outlined,
                              title: l10n.upgradeIntroRustEngineTitle,
                              body: l10n.upgradeIntroRustEngineBody,
                            ),
                            _TourFeature(
                              icon: Icons.memory_outlined,
                              title: l10n.upgradeIntroRustMemoryTitle,
                              body: l10n.upgradeIntroRustMemoryBody,
                            ),
                            _TourFeature(
                              icon: Icons.library_music_outlined,
                              title: l10n.upgradeIntroRustKeepTitle,
                              body: l10n.upgradeIntroRustKeepBody,
                            ),
                          ],
                        ),
                        if (mornye)
                          _TourPage(
                            title: l10n.upgradeIntroPlayerTitle,
                            description: l10n.upgradeIntroPlayerBody,
                            hero: Icon(
                              CupertinoIcons.music_note_2,
                              size: 76,
                              color: scheme.primary,
                            ),
                            children: [
                              _TourFeature(
                                icon: Icons.palette_outlined,
                                title: l10n.appearanceTitle,
                                body: l10n.upgradeIntroAppearanceBody,
                              ),
                              _TourFeature(
                                icon: Icons.graphic_eq,
                                title: 'AutoMix',
                                body: l10n.upgradeIntroAutoMixBody,
                              ),
                              _TourFeature(
                                icon: Icons.person_outline,
                                title: l10n.navSettings,
                                body: l10n.upgradeIntroSettingsBody,
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 16, 32, 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Semantics(
                          label: '${_page + 1} / $pageCount',
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: List.generate(
                              pageCount,
                              (index) => Container(
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: index == _page
                                      ? scheme.primary
                                      : scheme.onSurface.withValues(
                                          alpha: 0.16,
                                        ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: last ? _finish : () => _goTo(_page + 1),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(54),
                              shape: mornye
                                  ? RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    )
                                  : null,
                              textStyle: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            child: Text(
                              last
                                  ? l10n.upgradeIntroDone
                                  : l10n.upgradeIntroContinue,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TourPage extends StatelessWidget {
  const _TourPage({
    required this.title,
    required this.description,
    required this.children,
    this.hero,
  });
  final String title;
  final String description;
  final List<Widget> children;
  final Widget? hero;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 16, 32, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hero != null) ...[hero!, const SizedBox(height: 22)],
          Text(
            title,
            style: theme.textTheme.headlineLarge?.copyWith(
              fontSize: context.isMornye ? 36 : 34,
              height: context.isMornye ? 1.08 : 1.18,
              letterSpacing: context.isMornye ? -1.2 : null,
              fontWeight: context.isMornye ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            description,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 17,
              height: 1.4,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 32),
          ...children,
        ],
      ),
    );
  }
}

class _ThemePicker extends ConsumerWidget {
  const _ThemePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(themeProvider);
    final brightness = Theme.of(context).brightness;
    final l10n = context.l10n;
    return Column(
      children: [
        for (final style in AppThemeStyle.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Theme(
              data: style == AppThemeStyle.mornye
                  ? MornyeTheme.build(
                      brightness,
                      accent: settings.mornyeAccent,
                      useSystemFont: settings.useSystemFont,
                      glassClarity: settings.mornyeGlassClarity,
                      glassOutlines: settings.mornyeGlassOutlines,
                    )
                  : brightness == Brightness.dark
                  ? AppTheme.dark(
                      seedColor: settings.seedColor,
                      isAmoled: settings.useAmoled,
                      useSystemFont: settings.useSystemFont,
                    )
                  : AppTheme.light(
                      seedColor: settings.seedColor,
                      useSystemFont: settings.useSystemFont,
                    ),
              child: _ThemeOption(
                style: style,
                selected: settings.style == style,
                label: style == AppThemeStyle.mornye ? 'Mornye' : 'Material',
                description: style == AppThemeStyle.mornye
                    ? l10n.upgradeIntroThemeMornyeBody
                    : l10n.upgradeIntroThemeMaterialBody,
                onTap: () => ref.read(themeProvider.notifier).setStyle(style),
              ),
            ),
          ),
      ],
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    required this.style,
    required this.selected,
    required this.label,
    required this.description,
    required this.onTap,
  });

  final AppThemeStyle style;
  final bool selected;
  final String label;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mornye = style == AppThemeStyle.mornye;
    return Semantics(
      selected: selected,
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(mornye ? 20 : 28),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('intro-theme-${style.name}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Icon(
                      selected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  description,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),
                ExcludeSemantics(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      for (final icon in [
                        Icons.home_rounded,
                        Icons.library_music,
                        Icons.extension,
                        mornye ? Icons.search : Icons.settings_outlined,
                      ])
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: icon == Icons.home_rounded
                                ? mornye
                                      ? scheme.onSurface.withValues(alpha: 0.08)
                                      : scheme.secondaryContainer
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Icon(
                            mornye
                                ? icon == Icons.home_rounded
                                      ? CupertinoIcons.house_fill
                                      : mornyeIconFor(icon)
                                : icon,
                            size: 22,
                            color: icon == Icons.home_rounded
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
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
}

class _TourFeature extends StatelessWidget {
  const _TourFeature({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 36,
            child: Icon(
              context.adaptiveIcon(icon),
              size: 28,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    height: 1.35,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A small map of the new Library, using its actual labels and icon language.
/// Decorative rows deliberately have no buttons or fake playback state.
class _LibraryPreview extends StatelessWidget {
  const _LibraryPreview();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Text.rich(
                TextSpan(
                  children: [
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Icon(
                        CupertinoIcons.arrow_down_circle,
                        size: 18,
                        color: scheme.primary,
                      ),
                    ),
                    TextSpan(text: '  ${l10n.libraryDownloads}'),
                  ],
                ),
                style: TextStyle(
                  color: scheme.primary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.navLibrary,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            for (final item in [
              (CupertinoIcons.music_note_list, l10n.searchPlaylists),
              (CupertinoIcons.mic, l10n.searchArtists),
              (CupertinoIcons.square_stack, l10n.searchAlbums),
            ]) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Row(
                  children: [
                    Icon(item.$1, color: scheme.primary, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(item.$2, style: theme.textTheme.bodyLarge),
                    ),
                    Icon(
                      CupertinoIcons.chevron_right,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
