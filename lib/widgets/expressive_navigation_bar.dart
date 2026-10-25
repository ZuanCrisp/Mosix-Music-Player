import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mosix/theme/material_expressive.dart';

class ExpressiveNavigationBar extends StatelessWidget {
  const ExpressiveNavigationBar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.backgroundColor,
    this.isTablet = false,
  });

  final List<NavigationDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final Color backgroundColor;
  final bool isTablet;

  @override
  Widget build(BuildContext context) {
    if (!materialExpressiveEnabled(context)) {
      return NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: onDestinationSelected,
        animationDuration: Duration.zero,
        elevation: 0,
        height: isTablet ? 72 : 64,
        backgroundColor: backgroundColor,
        destinations: destinations,
      );
    }
    return MaterialExpressiveScope(
      child: ColoredBox(
        color: backgroundColor,
        // Paint the tint once across both the controls and system gesture area.
        // Use the app's scaled MediaQuery insets, rather than raw view metrics.
        child: SafeArea(
          top: false,
          child: M3ENavigationBar(
            selectedIndex: selectedIndex,
            onDestinationSelected: onDestinationSelected,
            size: isTablet ? M3ENavBarSize.medium : M3ENavBarSize.small,
            autoLayout: false,
            safeArea: false,
            padding: EdgeInsets.zero,
            backgroundColor: Colors.transparent,
            destinations: [
              for (final destination in destinations)
                M3ENavigationBarDestination(
                  icon: destination.icon,
                  selectedIcon: destination.selectedIcon,
                  label: destination.label,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
