import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/models/artist_concert.dart';
import 'package:mosix/screens/playlist_screen.dart';
import 'package:mosix/services/platform_bridge.dart';
import 'package:mosix/services/shell_navigation_service.dart';
import 'package:mosix/theme/cover_palette.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/utils/nav_bar_inset.dart';
import 'package:mosix/widgets/album_detail_header.dart';
import 'package:mosix/widgets/animation_utils.dart';
import 'package:mosix/widgets/cached_cover_image.dart';

class ConcertDetailScreen extends StatefulWidget {
  const ConcertDetailScreen({
    super.key,
    required this.artistName,
    required this.concert,
    this.coverUrl,
    this.providerId,
  });

  final String artistName;
  final ArtistConcert concert;
  final String? coverUrl;
  final String? providerId;

  @override
  State<ConcertDetailScreen> createState() => _ConcertDetailScreenState();
}

class _ConcertDetailScreenState extends State<ConcertDetailScreen> {
  ConcertDetail _detail = const ConcertDetail();
  bool _loading = false;
  bool _failed = false;
  bool _calendarOpen = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final provider = widget.providerId;
    final id = widget.concert.detailId;
    if (provider == null || provider.isEmpty || id == null) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final result = await PlatformBridge.getProviderMetadata(
        provider,
        'concert',
        id,
      );
      final json = result['concert'];
      if (json is! Map<String, dynamic>) {
        throw const FormatException('Missing concert');
      }
      final detail = ConcertDetail.fromJson(json);
      if (mounted) setState(() => _detail = detail);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    ShellNavigationService.clearChromeBrightness(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = _detail.coverUrl ?? widget.coverUrl;
    final base = context.isMornye
        ? MornyeTheme.fromContext(context, brightness: Brightness.dark)
        : ThemeData.dark();
    return Theme(
      data: base,
      child: CoverPaletteBuilder(
        imageSource: source,
        builder: (context, palette) {
          final color = HSLColor.fromColor(
            source == null
                ? Colors.grey
                : CoverPalette.sourceColor(source, Brightness.dark) ??
                      Colors.grey,
          );
          final top = color
              .withSaturation((color.saturation * 1.2).clamp(0, 0.65))
              .withLightness(0.27)
              .toColor();
          final bottom = color
              .withSaturation((color.saturation * 0.6).clamp(0, 0.4))
              .withLightness(0.36)
              .toColor();
          final route = ModalRoute.of(context);
          if (route != null) {
            ShellNavigationService.setChromeBrightness(
              owner: this,
              route: route,
              brightness: Brightness.dark,
              surface: bottom,
            );
          }
          final scheme = base.colorScheme.copyWith(
            surface: top,
            onSurface: Colors.white,
            onSurfaceVariant: Colors.white70,
            primary: Colors.white,
            onPrimary: top,
          );
          return Theme(
            data: base.copyWith(
              colorScheme: scheme,
              scaffoldBackgroundColor: top,
            ),
            child: Builder(
              builder: (context) => _page(context, source, top, bottom),
            ),
          );
        },
      ),
    );
  }

  Widget _page(BuildContext context, String? source, Color top, Color bottom) {
    final locale = Localizations.localeOf(context).toString();
    final date = widget.concert.date;
    final artist = _detail.artistName ?? widget.artistName;
    final hasSetList = _detail.setListId != null && widget.providerId != null;
    final photoSize = (MediaQuery.sizeOf(context).width * 0.5).clamp(
      144.0,
      220.0,
    );
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [top, bottom],
          ),
        ),
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              backgroundColor: top,
              surfaceTintColor: Colors.transparent,
              leadingWidth: 64,
              leading: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: HeaderCircleButton(
                  icon: Icons.arrow_back,
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Builder(
                    builder: (context) => HeaderCircleButton(
                      icon: CupertinoIcons.share,
                      tooltip: context.l10n.trackMetadataShare,
                      onPressed: () => _share(context),
                    ),
                  ),
                ),
              ],
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
              sliver: SliverToBoxAdapter(
                child: Column(
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        ClipOval(
                          child: SizedBox.square(
                            dimension: photoSize,
                            child: source == null
                                ? const Icon(Icons.person, size: 96)
                                : CachedCoverImage(
                                    imageUrl: source,
                                    fit: BoxFit.cover,
                                    errorWidget: (_, _, _) =>
                                        const Icon(Icons.person, size: 96),
                                  ),
                          ),
                        ),
                        Positioned(
                          right: -4,
                          bottom: -4,
                          child: Container(
                            width: 64,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xff202023),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  DateFormat.MMM(locale).format(date),
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: Color(0xffff646b),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  DateFormat.d(locale).format(date),
                                  style: const TextStyle(
                                    fontSize: 40,
                                    height: 1.05,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 26),
                    Text(
                      artist,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (_loading)
                      const ShimmerLoading(
                        child: Column(
                          children: [
                            Row(
                              spacing: 16,
                              children: [
                                Expanded(
                                  child: SkeletonBox(
                                    width: double.infinity,
                                    height: 48,
                                    borderRadius: 28,
                                  ),
                                ),
                                Expanded(
                                  child: SkeletonBox(
                                    width: double.infinity,
                                    height: 48,
                                    borderRadius: 28,
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: 20),
                            SkeletonBox(
                              width: double.infinity,
                              height: 164,
                              borderRadius: 28,
                            ),
                          ],
                        ),
                      )
                    else ...[
                      if (_detail.ticketUrl != null || hasSetList) ...[
                        Row(
                          spacing: 16,
                          children: [
                            if (_detail.ticketUrl != null)
                              Expanded(
                                child: _action(
                                  context,
                                  CupertinoIcons.tickets_fill,
                                  context.l10n.concertGetTickets,
                                  () => _openLink(_detail.ticketUrl!),
                                ),
                              ),
                            if (hasSetList)
                              Expanded(
                                child: _action(
                                  context,
                                  CupertinoIcons.play_fill,
                                  context.l10n.concertSetListButton,
                                  _openSetList,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 20),
                      ],
                      Container(
                        decoration: _glassDecoration,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        child: Column(
                          children: [
                            _infoRow(
                              '${DateFormat.yMMMMd(locale).format(date)} · ${DateFormat.EEEE(locale).format(date)}',
                              widget.concert.hasTime
                                  ? DateFormat.Hm(locale).format(date)
                                  : '',
                              CupertinoIcons.calendar_badge_plus,
                              _detail.start == null ? null : _addToCalendar,
                              context.l10n.concertAddToCalendar,
                            ),
                            const Divider(color: Colors.white24, height: 1),
                            _infoRow(
                              _detail.venue ?? widget.concert.venue,
                              _detail.address ?? widget.concert.location,
                              CupertinoIcons.map_pin_ellipse,
                              _detail.mapUrl == null
                                  ? null
                                  : () => _openLink(_detail.mapUrl!),
                              context.l10n.concertOpenMaps,
                            ),
                          ],
                        ),
                      ),
                      if (_detail.attribution != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            _detail.attribution!,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      if (_failed)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Column(
                            children: [
                              Text(
                                context.l10n.concertDetailsUnavailable,
                                textAlign: TextAlign.center,
                              ),
                              TextButton(
                                onPressed: _load,
                                child: Text(context.l10n.dialogRetry),
                              ),
                            ],
                          ),
                        ),
                      if (hasSetList) ...[
                        const SizedBox(height: 32),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            context.l10n.concertSetList,
                            style: const TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        InkWell(
                          onTap: _openSetList,
                          borderRadius: BorderRadius.circular(28),
                          child: Container(
                            decoration: _glassDecoration,
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: SizedBox.square(
                                    dimension: 88,
                                    child: _detail.setListCover == null
                                        ? const Icon(Icons.queue_music)
                                        : CachedCoverImage(
                                            imageUrl: _detail.setListCover!,
                                            fit: BoxFit.cover,
                                          ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    _detail.setListName ??
                                        context.l10n.concertSetList,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(
                                  CupertinoIcons.chevron_forward,
                                  size: 18,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            const NavBarSliverSpacer(),
          ],
        ),
      ),
    );
  }

  BoxDecoration get _glassDecoration => BoxDecoration(
    color: Colors.black.withValues(alpha: 0.15),
    borderRadius: BorderRadius.circular(28),
    border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
  );

  Widget _action(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) => OutlinedButton.icon(
    onPressed: onTap,
    icon: Icon(icon, size: 19),
    label: Text(label, textAlign: TextAlign.center),
    style: OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      backgroundColor: Colors.black.withValues(alpha: 0.15),
      side: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
  );

  Widget _infoRow(
    String title,
    String subtitle,
    IconData icon,
    VoidCallback? onTap,
    String tooltip,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 14),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 15, color: Colors.white70),
                ),
            ],
          ),
        ),
        if (onTap != null)
          IconButton(
            onPressed: onTap,
            tooltip: tooltip,
            icon: Icon(icon, size: 21),
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.12),
            ),
          ),
      ],
    ),
  );

  void _openSetList() {
    Navigator.of(context).push(
      slidePageRoute<void>(
        page: PlaylistScreen(
          playlistName: _detail.setListName ?? context.l10n.concertSetList,
          coverUrl: _detail.setListCover,
          tracks: const [],
          playlistId: _detail.setListId,
          metadataProviderId: widget.providerId,
        ),
      ),
    );
  }

  Future<void> _openLink(String url) async {
    try {
      if (await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      /* Keep the detail page open when no handler is installed. */
    }
    if (mounted) _error(context.l10n.announcementUnableToOpenLink);
  }

  Future<void> _share(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text:
            '${_detail.artistName ?? widget.artistName}\n${_detail.venue ?? widget.concert.venue}\n${_detail.url ?? widget.concert.url ?? ''}',
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  Future<void> _addToCalendar() async {
    if (_calendarOpen || _detail.start == null) return;
    _calendarOpen = true;
    try {
      final opened =
          await const MethodChannel(
            'com.zuancrisp.mosix/concert_calendar',
          ).invokeMethod<bool>('add', {
            'title': _detail.title ?? widget.artistName,
            'location': [
              _detail.venue ?? widget.concert.venue,
              _detail.address ?? widget.concert.location,
            ].join(', '),
            'start': _detail.start!.millisecondsSinceEpoch,
            'end': _detail.end?.millisecondsSinceEpoch,
            'url': _detail.url ?? widget.concert.url,
          });
      if (mounted && opened != true) {
        _error(context.l10n.concertCalendarUnavailable);
      }
    } on PlatformException {
      if (mounted) _error(context.l10n.concertCalendarUnavailable);
    } on MissingPluginException {
      if (mounted) _error(context.l10n.concertCalendarUnavailable);
    } finally {
      _calendarOpen = false;
    }
  }

  void _error(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));
}
