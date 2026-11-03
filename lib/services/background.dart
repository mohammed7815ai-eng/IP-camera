import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Android only: keeps HomeGuard running (recording, detection, alarms) while
/// the app is in the background, with a permanent notification as Android
/// requires. Windows keeps running while the window is open or minimised.
class BackgroundMode {
  static bool get supported => Platform.isAndroid;

  static void init() {
    if (!supported) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'homeguard_watch',
        channelName: 'HomeGuard watching',
        channelDescription: 'Shown while HomeGuard records and watches your cameras',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
        autoRunOnBoot: false,
      ),
    );
  }

  static Future<bool> enabled() async => (await SharedPreferences.getInstance()).getBool('background') ?? false;

  static Future<String?> set(bool on) async {
    if (!supported) return null;
    (await SharedPreferences.getInstance()).setBool('background', on);
    return on ? start() : stop();
  }

  static Future<String?> start() async {
    if (!supported) return null;
    final perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) await FlutterForegroundTask.requestNotificationPermission();
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    if (await FlutterForegroundTask.isRunningService) return null;
    final r = await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.specialUse],
      notificationTitle: 'HomeGuard is watching',
      notificationText: 'Recording and alarms stay on in the background',
    );
    return r is ServiceRequestFailure ? r.error.toString() : null;
  }

  static Future<String?> stop() async {
    if (!supported || !await FlutterForegroundTask.isRunningService) return null;
    final r = await FlutterForegroundTask.stopService();
    return r is ServiceRequestFailure ? r.error.toString() : null;
  }
}
