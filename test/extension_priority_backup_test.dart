import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/providers/extension_provider.dart';

Extension _extension(String id) => Extension.fromJson({
  'id': id,
  'name': id,
  'display_name': id,
  'version': '1.0.0',
  'enabled': true,
  'has_download_provider': true,
  'has_metadata_provider': true,
});

class _InstalledExtensions extends ExtensionNotifier {
  @override
  ExtensionState build() => ExtensionState(
    extensions: [
      _extension('example-a'),
      _extension('example-b'),
      _extension('example-c'),
    ],
    providerPriority: const ['example-a', 'example-b', 'example-c'],
    metadataProviderPriority: const ['example-a', 'example-b', 'example-c'],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<String, List<String>> pushed;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    pushed = {};
    messenger.setMockMethodCallHandler(backend, (call) async {
      final args = call.arguments;
      if (args is Map && args['priority'] is String) {
        pushed[call.method] = (jsonDecode(args['priority'] as String) as List)
            .cast<String>();
      }
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(backend, null));

  ExtensionNotifier notifierFor(ProviderContainer container) =>
      container.read(extensionProvider.notifier);

  ProviderContainer container() {
    final container = ProviderContainer(
      overrides: [extensionProvider.overrideWith(_InstalledExtensions.new)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('backup carries both provider priority lists', () {
    final notifier = notifierFor(container());
    expect(notifier.providerPriorityBackup(), {
      'provider_priority': ['example-a', 'example-b', 'example-c'],
      'metadata_provider_priority': ['example-a', 'example-b', 'example-c'],
    });
  });

  test('restore applies the saved order to state, prefs and backend', () async {
    final notifier = notifierFor(container());

    await notifier.restoreProviderPriorityBackup({
      'provider_priority': ['example-c', 'example-a', 'example-b'],
      'metadata_provider_priority': ['example-b', 'example-c', 'example-a'],
    });

    expect(notifier.state.providerPriority, [
      'example-c',
      'example-a',
      'example-b',
    ]);
    expect(notifier.state.metadataProviderPriority, [
      'example-b',
      'example-c',
      'example-a',
    ]);
    expect(pushed['setProviderPriority'], notifier.state.providerPriority);
    expect(
      pushed['setMetadataProviderPriority'],
      notifier.state.metadataProviderPriority,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      jsonDecode(prefs.getString('provider_priority')!),
      notifier.state.providerPriority,
    );
    expect(
      jsonDecode(prefs.getString('metadata_provider_priority')!),
      notifier.state.metadataProviderPriority,
    );
  });

  test('restore keeps missing and new providers usable', () async {
    final notifier = notifierFor(container());

    await notifier.restoreProviderPriorityBackup({
      'provider_priority': ['example-missing', 'example-c'],
    });

    // Unavailable IDs are dropped; providers absent from the backup follow.
    expect(notifier.state.providerPriority, [
      'example-c',
      'example-a',
      'example-b',
    ]);
    expect(notifier.state.metadataProviderPriority, [
      'example-a',
      'example-b',
      'example-c',
    ]);
    expect(pushed.keys, ['setProviderPriority']);
  });

  test('backups without priority lists leave the current order', () async {
    final notifier = notifierFor(container());

    await notifier.restoreProviderPriorityBackup({
      'items': const <Object>[],
      'provider_priority': 'invalid',
    });

    expect(notifier.state.providerPriority, [
      'example-a',
      'example-b',
      'example-c',
    ]);
    expect(pushed, isEmpty);
  });
}
