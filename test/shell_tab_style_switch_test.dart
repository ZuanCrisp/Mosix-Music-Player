import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/screens/main_shell.dart';
import 'package:mornye/services/shell_navigation_service.dart';

void main() {
  int? switched(
    int index, {
    required bool fromMornye,
    required bool showStore,
    bool desktop = true,
  }) => shellIndexOfTab(
    shellTabAt(index, mornye: fromMornye, showStore: showStore),
    mornye: !fromMornye,
    showStore: showStore,
    desktop: desktop,
  );

  for (final showStore in [false, true]) {
    test(
      'switching styles keeps the tab, not the index (store: $showStore)',
      () {
        final materialSettings = showStore ? 3 : 2;
        final mornyeSearch = showStore ? 3 : 2;
        final mornyeSettings = showStore ? 4 : 3;

        // Material Settings stays Settings instead of becoming Search.
        expect(
          switched(materialSettings, fromMornye: false, showStore: showStore),
          mornyeSettings,
        );
        expect(
          switched(mornyeSettings, fromMornye: true, showStore: showStore),
          materialSettings,
        );
        // Mornye's Search lands on Material's Home, where Material searches.
        expect(
          switched(mornyeSearch, fromMornye: true, showStore: showStore),
          0,
        );
        for (final index in [0, 1, if (showStore) 2]) {
          expect(
            switched(index, fromMornye: false, showStore: showStore),
            index,
          );
        }
        // Mornye phones have no Settings destination.
        expect(
          switched(
            materialSettings,
            fromMornye: false,
            showStore: showStore,
            desktop: false,
          ),
          isNull,
        );
      },
    );
  }

  test('Mornye Search maps to its own tab', () {
    expect(shellTabAt(2, mornye: true, showStore: false), ShellTab.search);
  });
}
