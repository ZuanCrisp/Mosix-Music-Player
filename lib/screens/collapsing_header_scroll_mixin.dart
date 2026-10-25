import 'package:flutter/material.dart';

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

  double calculateExpandedHeight(BuildContext context) {
    final mediaSize = MediaQuery.sizeOf(context);
    return (mediaSize.height * 0.6).clamp(400.0, 580.0);
  }

  void _onHeaderScroll() {
    final expandedHeight = calculateExpandedHeight(context);
    final shouldShow =
        scrollController.offset > (expandedHeight - kToolbarHeight - 20);
    if (shouldShow != showTitleInAppBar) {
      setState(() => showTitleInAppBar = shouldShow);
    }
  }
}
