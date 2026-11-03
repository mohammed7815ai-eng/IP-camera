import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'alarm.dart';

/// Shows alarm notifications (Android and Windows toasts) and plays the siren.
class AlarmNotifier {
  AlarmNotifier._();
  static final AlarmNotifier instance = AlarmNotifier._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  Player? _siren;
  int _id = 1;

  Future<void> init() async {
    if (_ready) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          windows: WindowsInitializationSettings(
            appName: 'HomeGuard',
            appUserModelId: 'MAH78.HomeGuard',
            guid: '6b0d6e2a-3f4c-4c8e-9a57-2d1e8c0b7a11',
          ),
        ),
      );
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  /// Asks for notification permission on Android 13+.
  Future<void> requestPermission() async {
    await init();
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  Future<void> show(AlarmRecord r, {required bool loud}) async {
    if (AlarmCenter.instance.settings.notify) {
      await init();
      if (_ready) {
        await _plugin.show(
          id: _id++,
          title: 'HomeGuard alarm',
          body: r.reason,
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'alarms',
              'Alarms',
              channelDescription: 'Security alarms from your cameras',
              importance: Importance.max,
              priority: Priority.high,
              category: AndroidNotificationCategory.alarm,
            ),
            windows: WindowsNotificationDetails(),
          ),
        );
      }
    }
    if (loud) await siren();
  }

  /// Plays a 10-second siren (generated, no audio file shipped).
  Future<void> siren() async {
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}${Platform.pathSeparator}siren.wav');
    if (!await f.exists()) await f.writeAsBytes(sirenWav());
    _siren ??= Player();
    await _siren!.open(Media(f.uri.toString()));
  }

  Future<void> stopSiren() async => _siren?.stop();
}

/// 10 s two-tone siren as 16-bit mono WAV.
Uint8List sirenWav({int seconds = 10, int rate = 22050}) {
  final n = seconds * rate;
  final data = ByteData(44 + n * 2);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  str(36, 'data');
  data.setUint32(40, n * 2, Endian.little);
  var phase = 0.0;
  for (var i = 0; i < n; i++) {
    final t = i / rate;
    final f = (t % 1.0) < 0.5 ? 960.0 : 770.0;
    phase += 2 * math.pi * f / rate;
    data.setInt16(44 + i * 2, (math.sin(phase) * 0.6 * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}
