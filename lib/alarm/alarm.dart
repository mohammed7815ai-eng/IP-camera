import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/detection.dart';
import '../models/camera.dart';

enum ArmMode { disarmed, home, away }

extension ArmModeLabel on ArmMode {
  String get label => switch (this) {
        ArmMode.disarmed => 'Disarmed',
        ArmMode.home => 'Home',
        ArmMode.away => 'Away',
      };
}

/// Normalises a plate for comparison: upper case, no spaces or dashes.
String normPlate(String s) => s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

class AlarmSettings {
  AlarmSettings({
    this.mode = ArmMode.disarmed,
    List<String>? watchlist,
    List<String>? allowlist,
    this.siren = true,
    this.notify = true,
  })  : watchlist = watchlist ?? [],
        allowlist = allowlist ?? [];

  ArmMode mode;

  /// Plates that always raise an alert, even when disarmed.
  List<String> watchlist;

  /// Plates that never raise an alarm (your own cars).
  List<String> allowlist;
  bool siren;
  bool notify;

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'watchlist': watchlist,
        'allowlist': allowlist,
        'siren': siren,
        'notify': notify,
      };

  factory AlarmSettings.fromJson(Map<String, dynamic> j) => AlarmSettings(
        mode: ArmMode.values.firstWhere((m) => m.name == j['mode'], orElse: () => ArmMode.disarmed),
        watchlist: (j['watchlist'] as List?)?.cast<String>(),
        allowlist: (j['allowlist'] as List?)?.cast<String>(),
        siren: j['siren'] as bool? ?? true,
        notify: j['notify'] as bool? ?? true,
      );
}

class AlarmDecision {
  AlarmDecision(this.reason, this.kind, {this.loud = true, this.detectionIndex});
  final String reason;
  final DetectionKind kind;

  /// Siren allowed (false for watchlist hits while disarmed).
  final bool loud;
  final int? detectionIndex;
}

/// Pure rules: which detections on a camera should raise an alarm now.
List<AlarmDecision> evaluateAlarm(AlarmSettings s, Camera cam, List<Detection> dets) {
  final out = <AlarmDecision>[];
  final watch = s.watchlist.map(normPlate).where((p) => p.isNotEmpty).toSet();
  final allow = s.allowlist.map(normPlate).where((p) => p.isNotEmpty).toSet();
  final armedHere = s.mode == ArmMode.away || (s.mode == ArmMode.home && cam.alarmWhenHome);
  for (var i = 0; i < dets.length; i++) {
    final d = dets[i];
    final plate = d.text == null ? '' : normPlate(d.text!);
    if (d.kind == DetectionKind.plate && plate.isNotEmpty && watch.contains(plate)) {
      out.add(AlarmDecision('Watchlist plate $plate at ${cam.name}', d.kind, loud: s.mode != ArmMode.disarmed, detectionIndex: i));
      continue;
    }
    if (!armedHere) continue;
    switch (d.kind) {
      case DetectionKind.motion:
        if (cam.alarmMotion) out.add(AlarmDecision('Motion at ${cam.name}', d.kind, detectionIndex: i));
      case DetectionKind.face:
        if (cam.alarmFaces) out.add(AlarmDecision('Person (face) at ${cam.name}', d.kind, detectionIndex: i));
      case DetectionKind.plate:
        if (cam.alarmPlates && !allow.contains(plate)) {
          out.add(AlarmDecision(
            plate.isEmpty ? 'Vehicle at ${cam.name}' : 'Vehicle $plate at ${cam.name}',
            d.kind,
            detectionIndex: i,
          ));
        }
    }
  }
  return out;
}

class AlarmRecord {
  AlarmRecord({
    required this.id,
    required this.time,
    required this.cameraId,
    required this.cameraName,
    required this.reason,
    required this.kind,
    this.imagePath,
    this.acknowledged = false,
  });
  final String id;
  final DateTime time;
  final String cameraId;
  final String cameraName;
  final String reason;
  final DetectionKind kind;
  final String? imagePath;
  bool acknowledged;

  Map<String, dynamic> toJson() => {
        'id': id,
        'time': time.toIso8601String(),
        'cameraId': cameraId,
        'cameraName': cameraName,
        'reason': reason,
        'kind': kind.name,
        'image': imagePath,
        'ack': acknowledged,
      };

  factory AlarmRecord.fromJson(Map<String, dynamic> j) => AlarmRecord(
        id: j['id'] as String,
        time: DateTime.parse(j['time'] as String),
        cameraId: j['cameraId'] as String,
        cameraName: j['cameraName'] as String? ?? '',
        reason: j['reason'] as String,
        kind: DetectionKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => DetectionKind.motion),
        imagePath: j['image'] as String?,
        acknowledged: j['ack'] as bool? ?? false,
      );
}

/// Alarm settings plus the alarm inbox, persisted locally.
class AlarmCenter extends ChangeNotifier {
  AlarmCenter._();
  static final AlarmCenter instance = AlarmCenter._();

  AlarmSettings settings = AlarmSettings();
  List<AlarmRecord> inbox = [];
  final Map<String, DateTime> _cooldown = {};
  static const cooldown = Duration(seconds: 60);
  File? _file;

  /// Called for every new alarm (notification + siren are attached here).
  Future<void> Function(AlarmRecord record, bool loud)? onAlarm;

  int get unacknowledged => inbox.where((a) => !a.acknowledged).length;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('alarmSettings');
    if (raw != null) settings = AlarmSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    final dir = await getApplicationSupportDirectory();
    _file = File('${dir.path}${Platform.pathSeparator}alarms.json');
    if (await _file!.exists()) {
      try {
        inbox = (jsonDecode(await _file!.readAsString()) as List)
            .map((e) => AlarmRecord.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> saveSettings() async {
    (await SharedPreferences.getInstance()).setString('alarmSettings', jsonEncode(settings.toJson()));
    notifyListeners();
  }

  Future<void> setMode(ArmMode m) async {
    settings.mode = m;
    await saveSettings();
  }

  Future<void> _saveInbox() async {
    if (_file == null) return;
    await _file!.writeAsString(jsonEncode(inbox.map((e) => e.toJson()).toList()));
  }

  /// Applies the rules to detections and raises alarms (with a 60 s cooldown
  /// per camera and reason).
  Future<List<AlarmRecord>> handle(Camera cam, List<Detection> dets, {String? imagePath, DateTime? now}) async {
    final t = now ?? DateTime.now();
    final raised = <AlarmRecord>[];
    for (final d in evaluateAlarm(settings, cam, dets)) {
      final key = '${cam.id}/${d.reason}';
      final prev = _cooldown[key];
      if (prev != null && t.difference(prev) < cooldown) continue;
      _cooldown[key] = t;
      final r = AlarmRecord(
        id: '${t.microsecondsSinceEpoch}_${cam.id}',
        time: t,
        cameraId: cam.id,
        cameraName: cam.name,
        reason: d.reason,
        kind: d.kind,
        imagePath: imagePath,
      );
      inbox.insert(0, r);
      raised.add(r);
      await onAlarm?.call(r, d.loud && settings.siren);
    }
    if (raised.isNotEmpty) {
      if (inbox.length > 300) inbox = inbox.sublist(0, 300);
      await _saveInbox();
      notifyListeners();
    }
    return raised;
  }

  Future<void> acknowledge(AlarmRecord r) async {
    r.acknowledged = true;
    await _saveInbox();
    notifyListeners();
  }

  Future<void> acknowledgeAll() async {
    for (final r in inbox) {
      r.acknowledged = true;
    }
    await _saveInbox();
    notifyListeners();
  }

  Future<void> clear() async {
    inbox = [];
    await _saveInbox();
    notifyListeners();
  }
}
