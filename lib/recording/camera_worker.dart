import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';

import '../ai/ai_engine.dart';
import '../ai/detection.dart';
import '../ai/event_store.dart';
import '../ai/vision_math.dart';
import '../alarm/alarm.dart';
import '../models/camera.dart';
import '../services/camera_repository.dart';
import '../services/secure_http.dart';
import '../services/stream_url.dart';
import '../ui/live_view.dart' show snapshotUri;
import 'motion.dart';
import 'recording_store.dart';

/// Decides which closed segments to keep in "events only" mode: a segment is
/// kept when an event happened during it, during the next one (pre-roll), or
/// during the previous one (post-roll).
class EventRetention {
  File? _previous;
  bool _previousKeep = false;
  bool _currentKeep = false;
  bool _keepNext = false;

  void onEvent() {
    _currentKeep = true;
    if (_previous != null) _previousKeep = true;
  }

  /// Called when a segment closes. Returns the file to delete, if any.
  File? onRotate(File closed) {
    File? delete;
    if (_previous != null && !_previousKeep) delete = _previous;
    final closedKeep = _currentKeep || _keepNext;
    _keepNext = _currentKeep;
    _previous = closedKeep ? null : closed;
    _previousKeep = false;
    _currentKeep = false;
    return delete;
  }

  /// Flushes on stop: returns the unkept previous and current segments.
  List<File> onStop(File? current) {
    final del = <File>[
      if (_previous != null && !_previousKeep) _previous!,
      if (current != null && !_currentKeep && !_keepNext) current,
    ];
    _previous = null;
    _previousKeep = _currentKeep = _keepNext = false;
    return del;
  }
}

/// Runs one camera in the background: records the stream to rotating
/// segments, analyses keyframes for motion / faces / plates, logs events and
/// raises alarms. Uses a headless player that decodes keyframes only, so it
/// costs far less than a live view.
class CameraWorker {
  CameraWorker(this.camera, this.repo);

  final Camera camera;
  final CameraRepository repo;
  final analysis = ValueNotifier<FrameAnalysis?>(null);
  final status = ValueNotifier<String>('Starting');

  static const continuousSegment = Duration(minutes: 5);
  static const eventSegment = Duration(minutes: 1);

  Player? _player;
  final _subs = <StreamSubscription<dynamic>>[];
  Timer? _rotateTimer, _analyzeTimer, _retryTimer;
  File? _segment;
  int _attempt = 0;
  bool _stopped = false;
  bool _connected = false;
  final _motion = MotionDetector();
  final _retention = EventRetention();

  bool get recording => camera.canRecord && camera.recording != RecordingMode.off;
  String? get activeFile => _segment?.path;

  Future<void> start() async {
    _stopped = false;
    if (camera.kind == CameraKind.httpApi) {
      status.value = 'Watching snapshots';
      _startAnalysis();
      return;
    }
    final pw = await repo.password(camera.id);
    final url = buildStreamUrl(camera, password: pw);
    if (url.isEmpty || _stopped) {
      status.value = 'No stream address';
      return;
    }
    final p = Player(configuration: const PlayerConfiguration(vo: 'null', muted: true, bufferSize: 16 * 1024 * 1024));
    _player = p;
    final n = p.platform;
    if (n is NativePlayer) {
      await n.setProperty('vid', 'auto');
      await n.setProperty('ao', 'null');
      await n.setProperty('hwdec', 'no');
      // Decode only keyframes: enough for analysis, a fraction of the CPU.
      await n.setProperty('vd-lavc-skipframe', 'nonkey');
      await n.setProperty('rtsp-transport', 'tcp');
      await n.setProperty('network-timeout', '15');
    }
    _subs.add(p.stream.error.listen(_fail));
    _subs.add(p.stream.completed.listen((done) {
      if (done) _fail('stream ended');
    }));
    _subs.add(p.stream.width.listen((w) {
      if (w != null && w > 0 && !_connected) _onConnected();
    }));
    status.value = 'Connecting';
    await p.open(Media(url));
  }

  Future<void> _onConnected() async {
    _connected = true;
    _attempt = 0;
    status.value = recording ? 'Recording' : 'Watching';
    if (recording) await _rotate();
    _startAnalysis();
  }

  Duration get _segmentLength => camera.recording == RecordingMode.events ? eventSegment : continuousSegment;

  Future<void> _rotate() async {
    _rotateTimer?.cancel();
    if (_stopped || _player == null) return;
    final now = DateTime.now();
    final file = await RecordingStore.instance.newSegmentFile(camera.id, now);
    final n = _player!.platform;
    if (n is NativePlayer) await n.setProperty('stream-record', file.path);
    final closed = _segment;
    _segment = file;
    if (closed != null && camera.recording == RecordingMode.events) {
      final del = _retention.onRotate(closed);
      if (del != null) await _delete(del);
    }
    // Align to the clock so files start on round minutes.
    final len = _segmentLength;
    final next = DateTime.fromMillisecondsSinceEpoch(
      (now.millisecondsSinceEpoch ~/ len.inMilliseconds + 1) * len.inMilliseconds,
    );
    _rotateTimer = Timer(next.difference(DateTime.now()) + const Duration(milliseconds: 50), _rotate);
  }

  void _startAnalysis() {
    _analyzeTimer?.cancel();
    final needAnalysis = camera.motion || camera.alarmMotion || camera.aiEnabled || camera.alarmFaces || camera.alarmPlates;
    if (!needAnalysis && camera.recording != RecordingMode.events) return;
    final every = Duration(seconds: camera.aiIntervalSeconds.clamp(1, 30));
    _analyzeTimer = Timer.periodic(every, (_) => _analyzeOnce());
  }

  bool _analyzing = false;
  Future<void> _analyzeOnce() async {
    if (_analyzing || _stopped) return;
    _analyzing = true;
    try {
      final jpeg = await _grabFrame();
      if (jpeg == null) return;
      final faces = camera.aiFaces || camera.alarmFaces;
      final plates = camera.aiPlates || camera.alarmPlates;
      final motionOn = camera.motion || camera.alarmMotion || camera.recording == RecordingMode.events;

      EngineResult? ai;
      if (faces || plates) ai = await AiEngine.instance.analyze(jpeg, faces: faces, plates: plates);
      final img.Image frame = ai?.frame ?? await Isolate.run(() => img.decodeImage(jpeg)!.convert(numChannels: 3));
      final dets = <Detection>[...?ai?.analysis.detections];
      final boxes = <Box>[...?ai?.boxes];
      if (motionOn) {
        final frac = _motion.update(motionThumb(frame));
        if (_motion.isMotion(frac)) {
          dets.add(Detection(kind: DetectionKind.motion, x1: 0, y1: 0, x2: 1, y2: 1, score: frac.clamp(0, 1)));
          boxes.add(Box(0, 0, frame.width.toDouble(), frame.height.toDouble(), frac));
        }
      }
      final result = EngineResult(FrameAnalysis(dets, frame.width, frame.height, DateTime.now()), frame, boxes);
      analysis.value = result.analysis;
      if (dets.isEmpty) return;
      _retention.onEvent();
      final added = await EventStore.instance.record(camera.id, camera.name, result);
      final image = added.isEmpty ? null : added.first.framePath;
      await AlarmCenter.instance.handle(camera, dets, imagePath: image);
    } catch (e) {
      debugPrint('worker ${camera.name}: $e');
    } finally {
      _analyzing = false;
    }
  }

  Future<Uint8List?> _grabFrame() async {
    if (camera.kind == CameraKind.httpApi) {
      final key = await repo.apiKey(camera.id);
      final headers = <String, String>{if (key != null && key.isNotEmpty) camera.apiKeyHeader: key};
      final res = await SecureHttp(pinnedSha256: camera.pinnedSha256).get(snapshotUri(camera), headers: headers);
      return res.status == 200 ? res.body : null;
    }
    if (!_connected) return null;
    return _player?.screenshot(format: 'image/jpeg');
  }

  void _fail(Object e) {
    if (_stopped) return;
    _connected = false;
    _attempt++;
    final wait = Duration(seconds: (2 << (_attempt.clamp(1, 5) - 1)).clamp(2, 30));
    status.value = 'Offline, retrying in ${wait.inSeconds}s (${redact(e.toString())})';
    _teardown();
    _retryTimer?.cancel();
    _retryTimer = Timer(wait, () {
      if (!_stopped) start();
    });
  }

  Future<void> _teardown() async {
    _rotateTimer?.cancel();
    _analyzeTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final p = _player;
    _player = null;
    if (p != null) {
      final n = p.platform;
      if (n is NativePlayer) {
        try {
          await n.setProperty('stream-record', '');
        } catch (_) {}
      }
      await p.dispose();
    }
    if (camera.recording == RecordingMode.events) {
      for (final f in _retention.onStop(_segment)) {
        await _delete(f);
      }
    }
    _segment = null;
    _motion.reset();
  }

  Future<void> stop() async {
    _stopped = true;
    _retryTimer?.cancel();
    await _teardown();
    status.value = 'Stopped';
  }

  Future<void> _delete(File f) async {
    try {
      await f.delete();
    } catch (_) {}
  }
}
