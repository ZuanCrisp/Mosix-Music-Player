import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/constants/app_info.dart';

void main() {
  test('desktop release builds mark the version as beta', () {
    expect(
      AppInfo.versionLabel(debug: false, desktop: true),
      '${AppInfo.version} (beta)',
    );
    expect(AppInfo.versionLabel(debug: false, desktop: false), AppInfo.version);
  });

  test('debug builds stay internal on every platform', () {
    expect(AppInfo.versionLabel(debug: true, desktop: true), 'Internal');
    expect(AppInfo.versionLabel(debug: true, desktop: false), 'Internal');
  });
}
