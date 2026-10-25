import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/notification_service.dart';
import 'package:mornye/services/verification_notification.dart';

class _LinuxNotifications extends Fake
    implements FlutterLocalNotificationsPlugin {
  int initializationCount = 0;
  int launchDetailsCount = 0;
  final shownIds = <int>[];
  final bodies = <String?>[];
  DidReceiveNotificationResponseCallback? onResponse;

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async {
    expect(settings.linux, isNotNull);
    initializationCount++;
    onResponse = onDidReceiveNotificationResponse;
    return true;
  }

  @override
  Future<NotificationAppLaunchDetails?>
  getNotificationAppLaunchDetails() async {
    launchDetailsCount++;
    throw UnimplementedError(
      'getNotificationAppLaunchDetails() has not been implemented',
    );
  }

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    shownIds.add(id);
    bodies.add(body);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Linux delivers results and verification taps without launch details',
    () async {
      final notifications = _LinuxNotifications();
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });

      final service = NotificationService.forTesting(notifications);
      await service.showQueueComplete(completedCount: 10, failedCount: 0);
      await service.showLibraryScanComplete(totalTracks: 10);
      expect(notifications.initializationCount, 1);
      expect(notifications.launchDetailsCount, 0);
      expect(notifications.shownIds, [
        NotificationService.downloadProgressId,
        NotificationService.libraryScanId,
      ]);
      expect(notifications.bodies.first, '10 tracks downloaded successfully');

      const target = VerificationNotification(
        extensionId: 'example-provider',
        itemId: 'example-track',
        tapId: 'linux:tap',
      );
      final received = <VerificationNotification>[];
      service.verificationNotifications.setHandler((notification) async {
        received.add(notification);
      });
      addTearDown(() => service.verificationNotifications.setHandler(null));
      notifications.onResponse!(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: target.encode(),
        ),
      );
      expect(received.single.extensionId, target.extensionId);
      expect(received.single.itemId, target.itemId);
    },
  );
}
