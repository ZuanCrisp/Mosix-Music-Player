import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/providers/weekly_releases_provider.dart';
import 'package:mosix/utils/clickable_metadata.dart';
import 'package:mosix/utils/nav_bar_inset.dart';
import 'package:mosix/widgets/app_choice_chip.dart';
import 'package:mosix/widgets/app_loading_indicator.dart';
import 'package:mosix/widgets/app_sliver_header.dart';
import 'package:mosix/widgets/cached_cover_image.dart';

class WeeklyReleasesScreen extends ConsumerStatefulWidget {
  const WeeklyReleasesScreen({super.key});

  @override
  ConsumerState<WeeklyReleasesScreen> createState() =>
      _WeeklyReleasesScreenState();
}

class _WeeklyReleasesScreenState extends ConsumerState<WeeklyReleasesScreen> {
  int _days = 7;
  bool _refresh = false;

  Future<void> _reload() async {
    if (_refresh) return;
    setState(() => _refresh = true);
    try {
      await ref.refresh(weeklyReleasesProvider(true).future).then((_) {});
      if (mounted) ref.invalidate(weeklyReleasesProvider(false));
    } catch (_) {
      // The provider displays the failure without leaving refresh latched on.
    } finally {
      if (mounted) setState(() => _refresh = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(weeklyReleasesProvider(_refresh));
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _reload,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            AppSliverHeader.page(title: context.l10n.weeklyReleases),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.l10n.weeklyReleasesDescription),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final days in [7, 30])
                          AppChoiceChip(
                            label: Text(context.l10n.listeningStatsDays(days)),
                            selected: _days == days,
                            onSelected: (_) => setState(() => _days = days),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            ...feed.when(
              loading: () => [
                const SliverToBoxAdapter(
                  child: Center(child: AppLoadingIndicator()),
                ),
              ],
              error: (_, _) => [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(context.l10n.weeklyReleasesLoadError),
                  ),
                ),
              ],
              data: (data) {
                final releases = data.inPeriod(DateTime.now(), _days);
                return [
                  if (data.unavailableArtists.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          '${context.l10n.weeklyReleasesUnavailable}\n'
                          '${data.unavailableArtists.join(', ')}',
                        ),
                      ),
                    ),
                  if (releases.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(context.l10n.weeklyReleasesEmpty),
                      ),
                    ),
                  SliverList.list(
                    children: [
                      for (final release in releases)
                        ListTile(
                          leading: release.coverUrl == null
                              ? const SizedBox(
                                  width: 56,
                                  height: 56,
                                  child: Icon(Icons.album_outlined),
                                )
                              : CachedCoverImage(
                                  imageUrl: release.coverUrl!,
                                  width: 56,
                                  height: 56,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                          title: Text(release.name),
                          subtitle: Text(
                            '${release.artist}\n${DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).format(release.date)}',
                          ),
                          onTap: () => navigateToAlbum(
                            context,
                            albumName: release.name,
                            albumId: release.id,
                            artistName: release.artist,
                            coverUrl: release.coverUrl,
                            extensionId: release.providerId,
                          ),
                        ),
                    ],
                  ),
                ];
              },
            ),
            SliverToBoxAdapter(
              child: SizedBox(height: context.navBarBottomInset),
            ),
          ],
        ),
      ),
    );
  }
}
