import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'ai_engine.dart';
import 'detection.dart';
import 'vision_math.dart';

class AiEvent {
  AiEvent({
    required this.id,
    required this.cameraId,
    required this.cameraName,
    required this.time,
    required this.kind,
    required this.score,
    this.text,
    required this.cropPath,
    required this.framePath,
  });

  final String id;
  final String cameraId;
  final String cameraName;
  final DateTime time;
  final DetectionKind kind;
  final double score;
  final String? text;
  final String cropPath;
  final String framePath;

  Map<String, dynamic> toJson() => {
        'id': id,
        'cameraId': cameraId,
        'cameraName': cameraName,
        'time': time.toIso8601String(),
        'kind': kind.name,
        'score': score,
        'text': text,
        'crop': cropPath,
        'frame': framePath,
      };

  factory AiEvent.fromJson(Map<String, dynamic> j) => AiEvent(
        id: j['id'] as String,
        cameraId: j['cameraId'] as String,
        cameraName: j['cameraName'] as String? ?? '',
        time: DateTime.parse(j['time'] as String),
        kind: DetectionKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => DetectionKind.face),
        score: (j['score'] as num).toDouble(),
        text: j['text'] as String?,
        cropPath: j['crop'] as String,
        framePath: j['frame'] as String,
      );
}

/// Decides whether a detection is a new event or a repeat of one just seen.
class Cooldown {
  Cooldown({this.face = const Duration(seconds: 20), this.plate = const Duration(minutes: 2), this.unreadPlate = const Duration(seconds: 30)});
  final Duration face, plate, unreadPlate;
  final Map<String, DateTime> _last = {};

  bool allow(String cameraId, Detection d, DateTime now) {
    final key = switch (d.kind) {
      DetectionKind.face => '$cameraId/face',
      DetectionKind.plate => d.text == null ? '$cameraId/plate?' : 'plate/${d.text}',
    };
    final window = switch (d.kind) {
      DetectionKind.face => face,
      DetectionKind.plate => d.text == null ? unreadPlate : plate,
    };
    final prev = _last[key];
    if (prev != null && now.difference(prev) < window) return false;
    _last[key] = now;
    return true;
  }
}

/// Keeps a local log of face and plate sightings with crops and a reduced
/// frame, capped at [maxEvents] (oldest files deleted).
class EventStore extends ChangeNotifier {
  EventStore._();
  static final EventStore instance = EventStore._();

  static const maxEvents = 500;
  final cooldown = Cooldown();
  List<AiEvent> events = [];
  Directory? _dir;
  bool _loaded = false;

  Future<Directory> _root() async {
    if (_dir != null) return _dir!;
    final base = Platform.isAndroid
        ? (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory()
        : Directory('${(await getApplicationDocumentsDirectory()).path}${Platform.pathSeparator}HomeGuard');
    _dir = Directory('${base.path}${Platform.pathSeparator}Events');
    await _dir!.create(recursive: true);
    return _dir!;
  }

  File get _index => File('${_dir!.path}${Platform.pathSeparator}events.json');

  Future<void> load() async {
    if (_loaded) return;
    await _root();
    if (await _index.exists()) {
      try {
        final list = jsonDecode(await _index.readAsString()) as List<dynamic>;
        events = list.map((e) => AiEvent.fromJson(e as Map<String, dynamic>)).toList();
      } catch (_) {
        events = [];
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    final tmp = File('${_index.path}.tmp');
    await tmp.writeAsString(jsonEncode(events.map((e) => e.toJson()).toList()));
    await tmp.rename(_index.path);
  }

  /// Records new detections from [r]. Returns the events that were added.
  Future<List<AiEvent>> record(String cameraId, String cameraName, EngineResult r) async {
    await load();
    final now = r.analysis.at;
    final fresh = <int>[];
    for (var i = 0; i < r.analysis.detections.length; i++) {
      if (cooldown.allow(cameraId, r.analysis.detections[i], now)) fresh.add(i);
    }
    if (fresh.isEmpty) return const [];
    final dir = await _root();
    final sep = Platform.pathSeparator;
    final stamp = now.millisecondsSinceEpoch;
    final framePath = '${dir.path}$sep${stamp}_$cameraId.jpg';
    final small = r.frame.width > 960 ? img.copyResize(r.frame, width: 960) : r.frame;
    await File(framePath).writeAsBytes(img.encodeJpg(small, quality: 80));
    final added = <AiEvent>[];
    for (final i in fresh) {
      final d = r.analysis.detections[i];
      final b = r.boxes[i].expand(d.kind == DetectionKind.face ? 0.35 : 0.08, r.frame.width, r.frame.height);
      final cropPath = '${dir.path}$sep${stamp}_${cameraId}_$i.jpg';
      await File(cropPath).writeAsBytes(Uint8List.fromList(img.encodeJpg(crop(r.frame, b), quality: 90)));
      added.add(AiEvent(
        id: '${stamp}_${cameraId}_$i',
        cameraId: cameraId,
        cameraName: cameraName,
        time: now,
        kind: d.kind,
        score: d.score,
        text: d.text,
        cropPath: cropPath,
        framePath: framePath,
      ));
    }
    events.insertAll(0, added.reversed);
    await _prune();
    await _save();
    notifyListeners();
    return added;
  }

  Future<void> _prune() async {
    if (events.length <= maxEvents) return;
    final dropped = events.sublist(maxEvents);
    events = events.sublist(0, maxEvents);
    final stillUsed = events.map((e) => e.framePath).toSet();
    for (final e in dropped) {
      await _tryDelete(e.cropPath);
      if (!stillUsed.contains(e.framePath)) await _tryDelete(e.framePath);
    }
  }

  Future<void> clear() async {
    await load();
    for (final e in events) {
      await _tryDelete(e.cropPath);
      await _tryDelete(e.framePath);
    }
    events = [];
    await _save();
    notifyListeners();
  }

  Future<void> _tryDelete(String p) async {
    try {
      await File(p).delete();
    } catch (_) {}
  }

  /// Events filtered by kind and plate/camera text.
  List<AiEvent> query({DetectionKind? kind, String search = ''}) {
    final q = search.trim().toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    return events.where((e) {
      if (kind != null && e.kind != kind) return false;
      if (q.isEmpty) return true;
      return (e.text ?? '').contains(q) || e.cameraName.toUpperCase().contains(q);
    }).toList();
  }
}
