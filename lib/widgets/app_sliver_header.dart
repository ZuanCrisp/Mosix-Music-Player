import 'package:flutter/material.dart';
import 'package:mosix/theme/app_tokens.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/utils/adaptive_layout.dart';
import 'package:mosix/utils/app_bar_layout.dart';

/// The collapsing header used by every top-level tab and every settings-style
/// sub-page.
///
/// Expanded titles use [AppTokens.headerExpandedTitleSize].
class AppSliverHeader extends StatelessWidget {
  /// Root of a navigation tab: no back button, and the title stays aligned with
  /// the content margin at every collapse ratio.
  const AppSliverHeader.tabRoot({super.key, required this.title, this.actions})
    : leading = null,
      _showLeading = false;

  /// A pushed page: shows [leading] (a back button by default) and slides the
  /// title clear of it as the header collapses.
  const AppSliverHeader.page({
    super.key,
    required this.title,
    this.actions,
    this.leading,
  }) : _showLeading = true;

  final String title;
  final List<Widget>? actions;

  /// Overrides the default back button. Only used by the page variant.
  final Widget? leading;

  final bool _showLeading;

  /// Left inset of the collapsed title when a leading button is present: enough
  /// to clear a 48dp icon button plus the 8dp toolbar margin.
  static const double _leadingClearance = 56;

  /// Content margin the expanded title aligns to.
  static const double _contentMargin = 24;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;
    final topPadding = normalizedHeaderTopPadding(context);
    final maxHeight = tokens.headerExpandedHeight + topPadding;
    final edgeInset = detailHeaderEdgeInset(context);

    return SliverAppBar(
      expandedHeight: maxHeight,
      collapsedHeight: kToolbarHeight,
      floating: false,
      pinned: true,
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      automaticallyImplyLeading: false,
      leadingWidth: _showLeading ? kToolbarHeight + edgeInset : null,
      leading: _showLeading
          ? Padding(
              padding: EdgeInsets.only(left: edgeInset),
              child:
                  leading ??
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    icon: Icon(
                      context.isMornye ? Icons.chevron_left : Icons.arrow_back,
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
            )
          : null,
      actionsPadding: EdgeInsets.only(right: edgeInset),
      actions: actions,
      flexibleSpace: LayoutBuilder(
        builder: (context, constraints) {
          // SliverAppBar adds the platform's actual top safe-area inset to its
          // extents. Deriving the collapse ratio from our requested heights
          // left notched iPhones looking almost fully expanded even after the
          // toolbar had collapsed, so the large title occupied the back
          // button's space. Read the resolved sliver geometry instead.
          final settings = context
              .dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
          final minExtent = settings?.minExtent ?? kToolbarHeight;
          final maxExtent = settings?.maxExtent ?? maxHeight;
          final currentExtent =
              settings?.currentExtent ?? constraints.maxHeight;
          final extentDelta = maxExtent - minExtent;
          final expandRatio = extentDelta > 0
              ? ((currentExtent - minExtent) / extentDelta).clamp(0.0, 1.0)
              : 0.0;
          final leftPadding = _showLeading
              ? (_leadingClearance + edgeInset) -
                    (((_leadingClearance + edgeInset) - _contentMargin) *
                        expandRatio)
              : _contentMargin;
          final fontSize =
              tokens.headerCollapsedTitleSize +
              (tokens.headerExpandedTitleSize -
                      tokens.headerCollapsedTitleSize) *
                  expandRatio;

          return FlexibleSpaceBar(
            centerTitle: false,
            expandedTitleScale: 1.0,
            titlePadding: EdgeInsets.only(
              left: leftPadding,
              right: tokens.gapLg,
              bottom: tokens.gapLg,
            ),
            title: Text(
              title,
              // The title grows as the header expands; without a cap a long
              // localized title overflowed instead of ellipsizing.
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.bold,
                letterSpacing: context.isMornye ? -0.7 * expandRatio : null,
                color: colorScheme.onSurface,
              ),
            ),
          );
        },
      ),
    );
  }
}
