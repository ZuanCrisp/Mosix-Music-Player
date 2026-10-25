import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/app_remote_config_service.dart';

void main() {
  group('AppRemoteConfig', () {
    test('parses announcement and donate payloads from API JSON', () {
      final config = AppRemoteConfig.fromJson({
        'announcement': {
          'id': 'hello-2026',
          'enabled': true,
          'title': 'Server message',
          'message': 'A clear message for users',
          'cta_enabled': true,
          'cta_label': 'Donate',
          'cta_url': 'https://example.test/donate',
          'starts_at': '2026-05-01T00:00:00Z',
          'ends_at': '2026-06-01T00:00:00Z',
          'min_version': '4.5.0',
          'priority': 'high',
        },
        'donate': {
          'enabled': true,
          'title': 'Support Mornye',
          'message': 'Help cover infrastructure.',
          'methods': [
            {
              'id': 'kofi',
              'title': 'Ko-fi',
              'subtitle': 'ko-fi.com/example',
              'url': 'https://ko-fi.com/example',
              'icon': 'kofi',
              'color': '#FF5E5B',
            },
            {
              'id': 'wallet',
              'title': 'USDT',
              'subtitle': 'TRC20',
              'wallet_address': 'T123',
              'icon': 'wallet',
              'color': '0xFF26A17B',
            },
          ],
          'supporters': ['Alice', 'Bob'],
          'notices': ['No paywalls'],
        },
      });

      expect(config.announcement?.id, 'hello-2026');
      expect(config.announcement?.hasCta, isTrue);
      expect(
        config.announcement?.isActive(
          now: DateTime.utc(2026, 5, 11),
          currentVersion: '4.5.1',
        ),
        isTrue,
      );
      expect(config.donate.title, 'Support Mornye');
      expect(config.donate.methods, hasLength(2));
      expect(config.donate.methods.first.color, 0xFFFF5E5B);
      expect(config.donate.methods.last.isWallet, isTrue);
      expect(config.donate.supporters, ['Alice', 'Bob']);
      expect(config.donate.notices, ['No paywalls']);
    });

    test('requires enabled announcement CTA with label and url', () {
      final disabledCta = RemoteAnnouncement.fromJson({
        'id': 'notice',
        'title': 'Notice',
        'message': 'No button',
        'cta_label': 'Open',
        'cta_url': 'https://api.zarz.moe',
      });
      final missingLabel = RemoteAnnouncement.fromJson({
        'id': 'notice',
        'title': 'Notice',
        'message': 'No button',
        'cta_enabled': true,
        'cta_url': 'https://example.test',
      });
      final enabledCta = RemoteAnnouncement.fromJson({
        'id': 'notice',
        'title': 'Notice',
        'message': 'With button',
        'cta_enabled': true,
        'cta_label': 'Read More',
        'cta_url': 'https://example.test',
      });

      expect(disabledCta.hasCta, isFalse);
      expect(missingLabel.hasCta, isFalse);
      expect(enabledCta.hasCta, isTrue);
      expect(enabledCta.ctaLabel, 'Read More');
    });

    test('filters inactive announcements by window and app version', () {
      final announcement = RemoteAnnouncement.fromJson({
        'id': 'future',
        'title': 'Future',
        'message': 'Not yet',
        'starts_at': '2026-06-01T00:00:00Z',
        'min_version': '4.6.0',
      });

      expect(
        announcement.isActive(
          now: DateTime.utc(2026, 5, 11),
          currentVersion: '4.5.1',
        ),
        isFalse,
      );
      expect(
        announcement.isActive(
          now: DateTime.utc(2026, 6, 2),
          currentVersion: '4.5.1',
        ),
        isFalse,
      );
      expect(
        announcement.isActive(
          now: DateTime.utc(2026, 6, 2),
          currentVersion: '4.6.0',
        ),
        isTrue,
      );
    });
  });
}
