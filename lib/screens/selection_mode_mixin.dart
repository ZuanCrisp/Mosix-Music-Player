import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared multi-select state for list screens: enter/exit selection mode,
/// toggle individual items, select all, and prune ids that fell out of the
/// current item list. Mix into a `State<T>` alongside the screen's own
/// per-item lookups (e.g. queue_tab, library_folder, artist screens).
mixin SelectionModeMixin<T extends StatefulWidget> on State<T> {
  bool isSelectionMode = false;
  final Set<String> selectedIds = {};

  void enterSelectionMode(String itemId) {
    HapticFeedback.mediumImpact();
    setState(() {
      isSelectionMode = true;
      selectedIds.add(itemId);
    });
  }

  void exitSelectionMode() {
    setState(() {
      isSelectionMode = false;
      selectedIds.clear();
    });
  }

  void toggleSelection(String itemId) {
    setState(() {
      if (selectedIds.contains(itemId)) {
        selectedIds.remove(itemId);
        if (selectedIds.isEmpty) {
          isSelectionMode = false;
        }
      } else {
        selectedIds.add(itemId);
      }
    });
  }

  void selectAll(Iterable<String> ids) {
    setState(() {
      selectedIds.addAll(ids);
    });
  }

  /// Drops ids no longer present in [validIds]; call from build() with the
  /// current item ids. Exits selection mode next frame if that empties it.
  void pruneSelection(Set<String> validIds) {
    selectedIds.removeWhere((id) => !validIds.contains(id));
    if (selectedIds.isEmpty && isSelectionMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => isSelectionMode = false);
      });
    }
  }
}
