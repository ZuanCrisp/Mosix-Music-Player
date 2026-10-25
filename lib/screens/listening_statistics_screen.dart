import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/services/listening_statistics.dart';
import 'package:mosix/widgets/app_alert_dialog.dart';
import 'package:mosix/widgets/app_choice_chip.dart';
import 'package:mosix/widgets/app_loading_indicator.dart';
import 'package:mosix/widgets/app_sliver_header.dart';
import 'package:mosix/widgets/player_artwork.dart';
import 'package:mosix/widgets/settings_group.dart';

final listeningSummaryProvider = FutureProvider.autoDispose
    .family<ListeningSummary, ({int days, int year})>((ref, period) async {
      await listeningRecorder.flush();
      final now = DateTime.now();
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      final start = period.days == 0
          ? DateTime(period.year)
          : DateTime(now.year, now.month, now.day - period.days + 1);
      final end = period.days == 0 ? DateTime(period.year + 1) : tomorrow;
      return ListeningStatisticsStore.instance.load(start, end);
    });

class ListeningStatisticsScreen extends ConsumerStatefulWidget {
  const ListeningStatisticsScreen({super.key});

  @override
  ConsumerState<ListeningStatisticsScreen> createState() =>
      _ListeningStatisticsScreenState();
}

class _ListeningStatisticsScreenState
    extends ConsumerState<ListeningStatisticsScreen> {
  int _days = 7;
  int _year = DateTime.now().year;
  bool _clearing = false;

  Future<void> _clear() async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppAlertDialog(
        title: Text(context.l10n.listeningStatsClear),
        content: Text(context.l10n.listeningStatsClearDescription),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.dialogCancel),
          ),
          AppDialogAction(
            isDestructive: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.listeningStatsClear),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      await listeningRecorder.clear(ListeningStatisticsStore.instance.clear);
      ref.invalidate(listeningSummaryProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.listeningStatsClearError)),
        );
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final period = (days: _days, year: _year);
    final summary = ref.watch(listeningSummaryProvider(period));
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(listeningSummaryProvider(period).future),
        child: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: context.l10n.listeningStats),
            SliverToBoxAdapter(
              child: SettingsGroup(
                children: [
                  SettingsSwitchItem(
                    icon: Icons.insights_outlined,
                    title: context.l10n.listeningStatsRecord,
                    subtitle: context.l10n.listeningStatsDescription,
                    value: ref
                        .watch(settingsProvider)
                        .listeningStatisticsEnabled,
                    enabled: !_clearing,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setListeningStatisticsEnabled(value),
                    showDivider: false,
                  ),
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final days in [7, 30, 0])
                      AppChoiceChip(
                        label: Text(
                          days == 0
                              ? '$_year'
                              : context.l10n.listeningStatsDays(days),
                        ),
                        selected: _days == days,
                        onSelected: (_) => setState(() => _days = days),
                      ),
                    if (_days == 0)
                      IconButton(
                        tooltip: context.l10n.listeningStatsPreviousYear,
                        onPressed: () => setState(() => _year--),
                        icon: const Icon(Icons.chevron_left),
                      ),
                    if (_days == 0)
                      IconButton(
                        tooltip: context.l10n.listeningStatsNextYear,
                        onPressed: _year >= DateTime.now().year
                            ? null
                            : () => setState(() => _year++),
                        icon: const Icon(Icons.chevron_right),
                      ),
                  ],
                ),
              ),
            ),
            ...summary.when(
              loading: () => [
                const SliverToBoxAdapter(
                  child: Center(child: AppLoadingIndicator()),
                ),
              ],
              error: (error, _) => [
                SliverToBoxAdapter(
                  child: ListTile(
                    title: Text(context.l10n.listeningStatsLoadError),
                    trailing: IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: () =>
                          ref.invalidate(listeningSummaryProvider(period)),
                    ),
                  ),
                ),
              ],
              data: (data) => _summarySlivers(context, data),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 48),
                child: TextButton.icon(
                  onPressed: _clearing ? null : _clear,
                  icon: Icon(Icons.delete_outline, color: colors.error),
                  label: Text(
                    context.l10n.listeningStatsClear,
                    style: TextStyle(color: colors.error),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _summarySlivers(BuildContext context, ListeningSummary data) {
    final colors = Theme.of(context).colorScheme;
    final artists = data.artists.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final artistArtwork = data.artistArtwork;
    final days = data.days.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.listeningStatsMinutes(
                      (data.milliseconds / 60000).round(),
                    ),
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.l10n.listeningStatsTotals(
                      data.plays,
                      data.tracks.length,
                      data.days.length,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      if (data.tracks.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(context.l10n.listeningStatsEmpty),
          ),
        ),
      if (days.isNotEmpty) ...[
        SliverToBoxAdapter(
          child: SettingsSectionHeader(
            title: context.l10n.listeningStatsActivity,
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                for (final day in days.skip(
                  (days.length - 7).clamp(0, days.length),
                ))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 68,
                          child: Text(
                            DateFormat.MMMd(
                              Localizations.localeOf(context).toLanguageTag(),
                            ).format(DateTime.parse(day.key)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: LinearProgressIndicator(
                            value:
                                day.value /
                                days
                                    .map((e) => e.value)
                                    .reduce((a, b) => a > b ? a : b),
                            minHeight: 8,
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text('${(day.value / 60000).round()}'),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
      SliverToBoxAdapter(
        child: SettingsSectionHeader(
          title: context.l10n.listeningStatsTopArtists,
        ),
      ),
      SliverList.list(
        children: [
          for (final artist in artists.take(10))
            ListTile(
              leading: ExcludeSemantics(
                child: ClipOval(
                  child: SizedBox.square(
                    dimension: 48,
                    child: artistArtwork[artist.key] == null
                        ? ColoredBox(
                            color: colors.surfaceContainerHighest,
                            child: const Icon(Icons.person_outline),
                          )
                        : PlayerArtwork(
                            artUri: artistArtwork[artist.key],
                            colorScheme: colors,
                            cacheWidth:
                                (48 * MediaQuery.devicePixelRatioOf(context))
                                    .ceil(),
                            iconSize: 24,
                          ),
                  ),
                ),
              ),
              title: Text(artist.key),
              subtitle: Text(
                context.l10n.listeningStatsMinutes(
                  (artist.value / 60000).round(),
                ),
              ),
            ),
        ],
      ),
      SliverToBoxAdapter(
        child: SettingsSectionHeader(
          title: context.l10n.listeningStatsTopTracks,
        ),
      ),
      SliverList.list(
        children: [
          for (final total in data.tracks.take(20))
            ListTile(
              leading: ExcludeSemantics(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox.square(
                    dimension: 48,
                    child: PlayerArtwork(
                      artUri: total.track.artwork,
                      colorScheme: Theme.of(context).colorScheme,
                      cacheWidth: (48 * MediaQuery.devicePixelRatioOf(context))
                          .ceil(),
                      iconSize: 24,
                    ),
                  ),
                ),
              ),
              title: Text(
                total.track.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                total.track.artist.trim().isEmpty
                    ? context.l10n.unknownArtist
                    : total.track.artist,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(
                context.l10n.listeningStatsMinutes(
                  (total.milliseconds / 60000).round(),
                ),
              ),
            ),
        ],
      ),
    ];
  }
}
