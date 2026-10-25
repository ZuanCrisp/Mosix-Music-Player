import 'package:flutter/widgets.dart';

/// Bottom inset needed to clear the transparent shell navigation bar.
///
/// The shell Scaffold uses `extendBody: true`, so its body (and any route
/// pushed inside the tab navigators) receives the navbar height plus the system
/// gesture inset as `MediaQuery.padding.bottom`. Scrollable screens add this as
/// trailing padding so their last item can scroll clear of the bar while the
/// content still shows faintly behind it.
extension NavBarInset on BuildContext {
  double get navBarBottomInset => MediaQuery.paddingOf(this).bottom;
}

/// Keeps animated navigation-bar insets local to the trailing spacer instead
/// of rebuilding the screen and its lists on every chrome animation frame.
class NavBarSliverSpacer extends StatelessWidget {
  const NavBarSliverSpacer({super.key, this.bottomInset});

  /// An explicit inset for surfaces that do not inherit the shell's padding.
  final double? bottomInset;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: SizedBox(height: bottomInset ?? context.navBarBottomInset),
  );
}
