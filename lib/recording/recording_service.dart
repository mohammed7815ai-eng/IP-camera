import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/camera.dart';
import '../services/app_state.dart';
import 'camera_worker.dart';
import 'recording_store.dart';

/// Keeps one [CameraWorker] per camera that records or is watched for
/// alarms, restarting workers when camera settings change, and enforces the
/// storage limits every 10 minutes.
class RecordingService extends ChangeNotifier {
  RecordingService._();
  static final RecordingService instance = RecordingService._();

  final Map<String, CameraWorker> _workers = {};
  final Map<String, String> _configs = {};
  AppState? _state;
  Timer? _cleanup;

  /// Total storage limit for recordings.
  int maxGigabytes = 50;

  CameraWorker? workerFor(String cameraId) => _workers[cameraId];
  Iterable<CameraWorker> get workers => _workers.values;

  Future<void> attach(AppState state) async {
    _state = state;
    maxGigabytes = (await SharedPreferences.getInstance()).getInt('maxGigabytes') ?? 50;
    state.addListener(_sync);
    await _sync();
    _cleanup = Timer.periodic(const Duration(minutes: 10), (_) => enforceRetention());
    unawaited(enforceRetention());
  }

  Future<void> setMaxGigabytes(int gb) async {
    maxGigabytes = gb;
    (await SharedPreferences.getInstance()).setInt('maxGigabytes', gb);
    notifyListeners();
    await enforceRetention();
  }

  Future<void> _sync() async {
    final s = _state;
    if (s == null) return;
    final wanted = {for (final c in s.cameras.where((c) => c.needsWorker)) c.id: c};
    for (final id in _workers.keys.toList()) {
      final c = wanted[id];
      if (c == null || _configs[id] != c.toJson().toString()) {
        await _workers.remove(id)!.stop();
        _configs.remove(id);
      }
    }
    for (final c in wanted.values) {
      if (_workers.containsKey(c.id)) continue;
      final w = CameraWorker(c.copy(), s.repo);
      _workers[c.id] = w;
      _configs[c.id] = c.toJson().toString();
      unawaited(w.start());
    }
    notifyListeners();
  }

  Future<int> enforceRetention() async {
    final s = _state;
    if (s == null) return 0;
    return RecordingStore.instance.enforceRetention(
      keepDays: {for (final Camera c in s.cameras) c.id: c.retentionDays},
      maxBytes: maxGigabytes * 1024 * 1024 * 1024,
      active: _workers.values.map((w) => w.activeFile).whereType<String>().toSet(),
    );
  }

  Future<void> stopAll() async {
    _cleanup?.cancel();
    for (final w in _workers.values) {
      await w.stop();
    }
    _workers.clear();
    _configs.clear();
  }
}
