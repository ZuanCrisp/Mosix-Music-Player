import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/screens/main_shell.dart';
import 'package:mosix/services/shell_navigation_service.dart';

void main() {
  int? switched(
    int index, {
    required bool fromMosix,
    required bool showStore,
    bool desktop = true,
  }) => shellIndexOfTab(
    shellTabAt(index, mornye: fromMosix, showStore: showStore),
    mornye: !fromMosix,
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
          switched(materialSettings, fromMosix: false, showStore: showStore),
          mornyeSettings,
        );
        expect(
          switched(mornyeSettings, fromMosix: true, showStore: showStore),
          materialSettings,
        );
        // Mosix's Search lands on Material's Home, where Material searches.
        expect(
          switched(mornyeSearch, fromMosix: true, showStore: showStore),
          0,
        );
        for (final index in [0, 1, if (showStore) 2]) {
          expect(
            switched(index, fromMosix: false, showStore: showStore),
            index,
          );
        }
        // Mosix phones have no Settings destination.
        expect(
          switched(
            materialSettings,
            fromMosix: false,
            showStore: showStore,
            desktop: false,
          ),
          isNull,
        );
      },
    );
  }

  test('Mosix Search maps to its own tab', () {
    expect(shellTabAt(2, mornye: true, showStore: false), ShellTab.search);
  });
}
