import 'package:flutter/material.dart';

/// Keeps touch-first tablets on the bottom navigation used by phones. A rail
/// is reserved for genuinely desktop-width windows; the old 600dp threshold
/// made an iPad portrait layout look like a shrunken desktop app.
const double navigationRailBreakpoint = 1440;
const double defaultWideContentMaxWidth = 960;
const double maxWideContentInset = 32;

bool useNavigationRailForWidth(double width) =>
    width >= navigationRailBreakpoint;

/// Explicit horizontal safe spacing for controls drawn in full-bleed detail
/// headers. iOS reports no left/right safe-area inset in portrait, so toolbar
/// buttons otherwise land only a few pixels from the device edge.
double detailHeaderEdgeInset(BuildContext context) {
  final platform = Theme.of(context).platform;
  return platform == TargetPlatform.iOS || platform == TargetPlatform.macOS
      ? 12
      : 0;
}

/// Visual scale for touch-first tablet surfaces. Large iPads have enough
/// pixels to make an unscaled phone density feel miniature, especially when
/// Simulator shrinks the whole device to fit a desktop display.
double adaptiveUiScaleForSize(Size size) {
  if (size.shortestSide < 600 || size.width >= navigationRailBreakpoint) {
    return 1;
  }
  return size.shortestSide >= 800 ? 1.2 : 1.1;
}

EdgeInsets _scaledInsets(EdgeInsets value, double divisor) => EdgeInsets.only(
  left: value.left / divisor,
  top: value.top / divisor,
  right: value.right / divisor,
  bottom: value.bottom / divisor,
);

/// Scales the complete app surface on tablets, including controls, dialogs,
/// navigation, spacing and hit targets. The child receives the correspondingly
/// smaller logical viewport so responsive layouts still reflow instead of
/// being cropped, while [FittedBox] maps that viewport back to the full screen.
class AdaptiveUiScaler extends StatelessWidget {
  const AdaptiveUiScaler({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final scale = adaptiveUiScaleForSize(mediaQuery.size);
    if (scale == 1) return child;

    final scaledSize = Size(
      mediaQuery.size.width / scale,
      mediaQuery.size.height / scale,
    );
    final scaledMediaQuery = mediaQuery.copyWith(
      size: scaledSize,
      // One inner logical pixel occupies [scale] outer logical pixels.
      // Advertising the effective density keeps decoded artwork sharp.
      devicePixelRatio: mediaQuery.devicePixelRatio * scale,
      padding: _scaledInsets(mediaQuery.padding, scale),
      viewPadding: _scaledInsets(mediaQuery.viewPadding, scale),
      viewInsets: _scaledInsets(mediaQuery.viewInsets, scale),
      systemGestureInsets: _scaledInsets(mediaQuery.systemGestureInsets, scale),
    );

    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.fill,
        alignment: Alignment.topLeft,
        child: SizedBox.fromSize(
          size: scaledSize,
          child: MediaQuery(data: scaledMediaQuery, child: child),
        ),
      ),
    );
  }
}

/// Widest content span for a surface of [maxWidth]: content is never narrower
/// than [contentMaxWidth], and the centering margin never exceeds 32dp per
/// side so tablets retain near-full-width rows.
double adaptiveContentMaxWidth(
  double maxWidth, {
  double contentMaxWidth = defaultWideContentMaxWidth,
}) => maxWidth > contentMaxWidth + (maxWideContentInset * 2)
    ? maxWidth - (maxWideContentInset * 2)
    : contentMaxWidth;

/// Horizontal inset that centers content of [maxWidth] at
/// [adaptiveContentMaxWidth]; zero once it fits. Prefer this constraint-based
/// form when the widget may live inside an already clamped box (e.g. a bottom
/// sheet), where screen width would over-inset.
double wideInsetForWidth(
  double maxWidth, {
  double contentMaxWidth = defaultWideContentMaxWidth,
}) => maxWidth > contentMaxWidth
    ? ((maxWidth - contentMaxWidth) / 2).clamp(0.0, maxWideContentInset)
    : 0;

/// Horizontal inset that centers full-width list content on tablets/landscape;
/// zero on phones, so rows stop stretching across the whole screen.
double wideListInset(
  BuildContext context, {
  double contentMaxWidth = defaultWideContentMaxWidth,
}) => wideInsetForWidth(
  MediaQuery.sizeOf(context).width,
  contentMaxWidth: contentMaxWidth,
);
