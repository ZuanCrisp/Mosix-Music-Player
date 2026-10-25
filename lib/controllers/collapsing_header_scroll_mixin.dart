import 'package:flutter/material.dart';

/// Expanded height of the album-style collapsing header, shared with the
/// loading screens that show the same header before the tracks arrive.
double collectionHeaderExpandedHeight(BuildContext context) {
  final mediaSize = MediaQuery.sizeOf(context);
  return (mediaSize.height * 0.6).clamp(400.0, 580.0);
}

/// Shared collapsing-header scroll behavior for album-style screens: owns the
/// [ScrollController] and flips [showTitleInAppBar] once the header has
/// scrolled out of view.
mixin CollapsingHeaderScrollMixin<T extends StatefulWidget> on State<T> {
  final ScrollController scrollController = ScrollController();
  bool showTitleInAppBar = false;

  @override
  void initState() {
    super.initState();
    scrollController.addListener(_onHeaderScroll);
  }

  @override
  void dispose() {
    scrollController.removeListener(_onHeaderScroll);
    scrollController.dispose();
    super.dispose();
  }

  double calculateExpandedHeight(BuildContext context) =>
      collectionHeaderExpandedHeight(context);

  void _onHeaderScroll() {
    final expandedHeight = calculateExpandedHeight(context);
    final shouldShow =
        scrollController.offset > (expandedHeight - kToolbarHeight - 20);
    if (shouldShow != showTitleInAppBar) {
      setState(() => showTitleInAppBar = shouldShow);
    }
  }
}
