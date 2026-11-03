import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../ai/ai_engine.dart';
import '../ai/detection.dart';
import '../ai/event_store.dart';
import '../models/camera.dart';
import '../recording/recording_service.dart';
import '../services/camera_repository.dart';
import '../services/secure_http.dart';
import '../services/stream_url.dart';

/// Live picture of one camera. RTSP/ONVIF cameras play through libmpv with
/// automatic reconnect; HTTP API cameras refresh a pinned-HTTPS snapshot.
class LiveView extends StatefulWidget {
  const LiveView({super.key, required this.camera, required this.repo, this.fit = BoxFit.cover, this.controllerOut, this.aiActive = false});
  final Camera camera;
  final CameraRepository repo;
  final BoxFit fit;

  /// Run the camera's enabled AI detectors on the live picture.
  final bool aiActive;

  /// Gives the parent access to take snapshots.
  final void Function(LiveViewHandle handle)? controllerOut;

  @override
  State<LiveView> createState() => _LiveViewState();
}

abstract class LiveViewHandle {
  Future<Uint8List?> snapshot();
}

class _LiveViewState extends State<LiveView> implements LiveViewHandle {
  Player? _player;
  VideoController? _video;
  final _subs = <StreamSubscription<dynamic>>[];
  Timer? _retry;
  Timer? _poll;
  int _attempt = 0;
  String? _status = 'Connecting…';
  Uint8List? _jpeg;
  bool _disposed = false;
  Timer? _aiTimer;
  FrameAnalysis? _analysis;
  String? _aiError;

  bool get _isStream => widget.camera.kind != CameraKind.httpApi;

  @override
  void initState() {
    super.initState();
    widget.controllerOut?.call(this);
    _start();
    _syncAi();
  }

  void _syncAi() {
    _aiTimer?.cancel();
    _aiTimer = null;
    if (!widget.aiActive || !widget.camera.aiEnabled) {
      _analysis = null;
      return;
    }
    final every = Duration(seconds: widget.camera.aiIntervalSeconds.clamp(1, 30));
    _aiTimer = Timer.periodic(every, (_) => _analyzeOnce());
  }

  Future<void> _analyzeOnce() async {
    if (_disposed || _status != null) return;
    final c = widget.camera;
    // A background worker already analyses this camera: show its results.
    final w = RecordingService.instance.workerFor(c.id);
    if (w != null) {
      final a = w.analysis.value;
      if (a != null && mounted) setState(() => _analysis = a);
      return;
    }
    try {
      final frame = await snapshot();
      if (frame == null || _disposed) return;
      final r = await AiEngine.instance.analyze(frame, faces: c.aiFaces, plates: c.aiPlates);
      if (r == null || _disposed) return;
      if (mounted) {
        setState(() {
          _analysis = r.analysis;
          _aiError = null;
        });
      }
      if (r.analysis.detections.isNotEmpty) {
        await EventStore.instance.record(c.id, c.name, r);
      }
    } catch (e) {
      if (mounted) setState(() => _aiError = 'AI: $e');
    }
  }

  @override
  void didUpdateWidget(LiveView old) {
    super.didUpdateWidget(old);
    if (old.camera.toJson().toString() != widget.camera.toJson().toString()) {
      _stop();
      _start();
    }
    if (old.aiActive != widget.aiActive || old.camera.aiEnabled != widget.camera.aiEnabled) _syncAi();
  }

  Future<void> _start() async {
    if (_isStream) {
      await _startStream();
    } else {
      _startPolling();
    }
  }

  Future<void> _startStream() async {
    final pw = await widget.repo.password(widget.camera.id);
    final url = buildStreamUrl(widget.camera, password: pw);
    if (_disposed) return;
    if (url.isEmpty) {
      setState(() => _status = 'No stream address. Edit the camera to finish setup.');
      return;
    }
    final player = Player(configuration: const PlayerConfiguration(muted: true, bufferSize: 8 * 1024 * 1024));
    final native = player.platform;
    if (native is NativePlayer) {
      await native.setProperty('rtsp-transport', 'tcp');
      await native.setProperty('network-timeout', '10');
      await native.setProperty('cache', 'no');
    }
    _player = player;
    _video = VideoController(player);
    _subs.add(player.stream.error.listen((e) => _fail(e)));
    _subs.add(player.stream.completed.listen((done) {
      if (done) _fail('Stream ended');
    }));
    _subs.add(player.stream.width.listen((w) {
      if (w != null && w > 0 && mounted) {
        _attempt = 0;
        setState(() => _status = null);
      }
    }));
    await player.open(Media(url));
    if (mounted) setState(() {});
  }

  void _fail(Object e) {
    if (_disposed) return;
    final msg = redact(e.toString());
    _attempt++;
    final wait = Duration(seconds: (2 << (_attempt.clamp(1, 5) - 1)).clamp(2, 30));
    setState(() => _status = 'Reconnecting in ${wait.inSeconds}s ($msg)');
    _retry?.cancel();
    _retry = Timer(wait, () {
      if (_disposed) return;
      _stop();
      _start();
    });
  }

  void _startPolling() {
    _fetchSnapshot();
    _poll = Timer.periodic(Duration(seconds: widget.camera.refreshSeconds.clamp(1, 60)), (_) => _fetchSnapshot());
  }

  bool _fetching = false;
  Future<void> _fetchSnapshot() async {
    if (_fetching || _disposed) return;
    _fetching = true;
    final c = widget.camera;
    try {
      final key = await widget.repo.apiKey(c.id);
      final pw = await widget.repo.password(c.id);
      final uri = snapshotUri(c);
      final headers = <String, String>{};
      if (key != null && key.isNotEmpty) headers[c.apiKeyHeader] = key;
      if (c.username.isNotEmpty && pw != null) {
        headers['Authorization'] = 'Basic ${base64.encode(utf8.encode('${c.username}:$pw'))}';
      }
      final res = await SecureHttp(pinnedSha256: c.pinnedSha256).get(uri, headers: headers);
      if (res.status != 200) throw Exception('HTTP ${res.status}');
      if (!mounted) return;
      setState(() {
        _jpeg = res.body;
        _status = null;
      });
    } catch (e) {
      if (mounted) setState(() => _status = e.toString());
    } finally {
      _fetching = false;
    }
  }

  void _stop() {
    _retry?.cancel();
    _poll?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _player?.dispose();
    _player = null;
    _video = null;
  }

  @override
  Future<Uint8List?> snapshot() async {
    if (_isStream) return _player?.screenshot(format: 'image/jpeg');
    return _jpeg;
  }

  @override
  void dispose() {
    _disposed = true;
    _aiTimer?.cancel();
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget picture;
    if (_isStream && _video != null) {
      picture = Video(controller: _video!, controls: NoVideoControls, fit: widget.fit, fill: Colors.black);
    } else if (!_isStream && _jpeg != null) {
      picture = Image.memory(_jpeg!, fit: widget.fit, gaplessPlayback: true, width: double.infinity, height: double.infinity);
    } else {
      picture = const ColoredBox(color: Colors.black);
    }
    final a = _analysis;
    final fresh = a != null && DateTime.now().difference(a.at) < Duration(seconds: widget.camera.aiIntervalSeconds * 2 + 2);
    return Stack(fit: StackFit.expand, children: [
      picture,
      if (fresh && a.detections.isNotEmpty)
        IgnorePointer(child: CustomPaint(painter: DetectionPainter(a, widget.fit))),
      if (widget.aiActive && widget.camera.aiEnabled)
        Positioned(
          top: 6,
          right: 6,
          child: Tooltip(
            message: _aiError ?? 'AI detection on',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: _aiError == null ? Colors.black54 : Colors.red.shade900, borderRadius: BorderRadius.circular(6)),
              child: const Text('AI', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      if (_status != null)
        Center(
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
            child: Text(_status!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ),
        ),
    ]);
  }
}


Uri snapshotUri(Camera c) {
  final h = c.host.trim();
  if (h.startsWith('http://') || h.startsWith('https://')) return Uri.parse(h);
  var p = c.path.trim();
  if (p.isNotEmpty && !p.startsWith('/')) p = '/$p';
  final pathUri = Uri.parse(p.isEmpty ? '/' : p);
  return Uri(
    scheme: c.useTls ? 'https' : 'http',
    host: h,
    port: c.effectivePort,
    path: pathUri.path,
    query: pathUri.hasQuery ? pathUri.query : null,
  );
}

/// Draws detection boxes over the video, matching how [fit] places the frame.
class DetectionPainter extends CustomPainter {
  DetectionPainter(this.analysis, this.fit);
  final FrameAnalysis analysis;
  final BoxFit fit;

  @override
  void paint(Canvas canvas, Size size) {
    final fw = analysis.width.toDouble(), fh = analysis.height.toDouble();
    final s = fit == BoxFit.contain
        ? (size.width / fw < size.height / fh ? size.width / fw : size.height / fh)
        : (size.width / fw > size.height / fh ? size.width / fw : size.height / fh);
    final dw = fw * s, dh = fh * s;
    final ox = (size.width - dw) / 2, oy = (size.height - dh) / 2;
    for (final d in analysis.detections) {
      final color = d.kind == DetectionKind.face ? const Color(0xFF4FC3F7) : const Color(0xFFFFC107);
      final r = Rect.fromLTRB(ox + d.x1 * dw, oy + d.y1 * dh, ox + d.x2 * dw, oy + d.y2 * dh);
      canvas.drawRect(r, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color);
      final tp = TextPainter(
        text: TextSpan(text: ' ${d.label} ', style: const TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.w700)),
        textDirection: TextDirection.ltr,
      )..layout();
      final ty = r.top - tp.height < 0 ? r.bottom : r.top - tp.height;
      canvas.drawRect(Rect.fromLTWH(r.left, ty, tp.width, tp.height), Paint()..color = color);
      tp.paint(canvas, Offset(r.left, ty));
    }
  }

  @override
  bool shouldRepaint(DetectionPainter old) => old.analysis != analysis || old.fit != fit;
}
