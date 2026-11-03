import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../ai/event_store.dart';
import '../models/camera.dart';
import '../recording/recording_store.dart';
import '../services/app_state.dart';
import 'sync_playback_page.dart';
import 'timeline.dart';

String hms(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
String ymd(DateTime t) => '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

/// Playback of recorded footage: pick camera and day, tap the timeline.
class RecordingsPage extends StatefulWidget {
  const RecordingsPage({super.key, required this.state, this.initialCamera, this.initialTime});
  final AppState state;
  final Camera? initialCamera;
  final DateTime? initialTime;

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  final _player = Player();
  late final _video = VideoController(_player);
  Camera? _camera;
  DateTime _day = DateTime.now();
  List<Segment> _segments = [];
  List<TimelineMark> _marks = [];
  Segment? _current;
  DateTime? _position;
  double _rate = 1;
  int _zoom = 0; // 0: 24 h, 1: 6 h, 2: 1 h
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _doneSub;

  List<Camera> get _cams => widget.state.cameras.where((c) => c.canRecord).toList();

  @override
  void initState() {
    super.initState();
    _camera = widget.initialCamera ?? (_cams.isEmpty ? null : _cams.first);
    if (widget.initialTime != null) _day = widget.initialTime!;
    _posSub = _player.stream.position.listen((p) {
      final s = _current;
      if (s != null && mounted) setState(() => _position = s.start.add(p));
    });
    _doneSub = _player.stream.completed.listen((done) {
      if (done) _playNext();
    });
    _load(seekTo: widget.initialTime);
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _doneSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _load({DateTime? seekTo}) async {
    final c = _camera;
    if (c == null) return;
    final segs = await RecordingStore.instance.segmentsForDay(c.id, _day);
    await EventStore.instance.load();
    final dayStart = DateTime(_day.year, _day.month, _day.day);
    final marks = EventStore.instance.events
        .where((e) => e.cameraId == c.id && !e.time.isBefore(dayStart) && e.time.isBefore(dayStart.add(const Duration(days: 1))))
        .map((e) => TimelineMark(e.time, e.kind))
        .toList();
    if (!mounted) return;
    setState(() {
      _segments = segs;
      _marks = marks;
    });
    if (seekTo != null) {
      await _seek(seekTo);
    } else if (segs.isNotEmpty && _current == null) {
      await _seek(segs.last.start);
    }
  }

  Future<void> _seek(DateTime t) async {
    if (_segments.isEmpty) return;
    var seg = _segments.where((s) => s.contains(t)).firstOrNull;
    var offset = seg == null ? Duration.zero : t.difference(seg.start);
    seg ??= _segments.where((s) => s.start.isAfter(t)).firstOrNull ?? _segments.last;
    if (_current?.file.path != seg.file.path) {
      _current = seg;
      await _player.open(Media(seg.file.uri.toString()), play: true);
      await _player.stream.duration.firstWhere((d) => d > Duration.zero).timeout(const Duration(seconds: 5), onTimeout: () => Duration.zero);
    }
    await _player.setRate(_rate);
    await _player.seek(offset);
    setState(() => _position = seg!.start.add(offset));
  }

  Future<void> _playNext() async {
    final cur = _current;
    if (cur == null) return;
    final i = _segments.indexWhere((s) => s.file.path == cur.file.path);
    if (i >= 0 && i + 1 < _segments.length) await _seek(_segments[i + 1].start);
  }

  Future<void> _export() async {
    final s = _current;
    final c = _camera;
    if (s == null || c == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final f = await RecordingStore.instance.export(s, c.name);
      messenger.showSnackBar(SnackBar(content: Text('Exported to ${f.path} (with SHA-256 fingerprint)')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  Future<void> _pickDay() async {
    final d = await showDatePicker(context: context, initialDate: _day, firstDate: DateTime(2024), lastDate: DateTime.now());
    if (d == null) return;
    setState(() {
      _day = d;
      _current = null;
      _position = null;
    });
    await _player.stop();
    await _load();
  }

  (Duration, Duration) get _window {
    const spans = [Duration(hours: 24), Duration(hours: 6), Duration(hours: 1)];
    final span = spans[_zoom];
    if (_zoom == 0) return (Duration.zero, span);
    final dayStart = DateTime(_day.year, _day.month, _day.day);
    final centre = (_position ?? dayStart.add(const Duration(hours: 12))).difference(dayStart);
    var from = centre - span ~/ 2;
    if (from < Duration.zero) from = Duration.zero;
    if (from + span > const Duration(hours: 24)) from = const Duration(hours: 24) - span;
    return (from, span);
  }

  @override
  Widget build(BuildContext context) {
    final cams = _cams;
    final (from, span) = _window;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recordings'),
        actions: [
          PopupMenuButton<double>(
            tooltip: 'Speed',
            icon: Text('${_rate == _rate.roundToDouble() ? _rate.toInt() : _rate}x', style: const TextStyle(fontWeight: FontWeight.w700)),
            onSelected: (r) {
              setState(() => _rate = r);
              _player.setRate(r);
            },
            itemBuilder: (_) => [for (final r in [0.5, 1.0, 2.0, 4.0, 8.0, 16.0]) PopupMenuItem(value: r, child: Text('${r}x'))],
          ),
          IconButton(tooltip: 'Export clip', icon: const Icon(Icons.ios_share), onPressed: _current == null ? null : _export),
          IconButton(
            tooltip: 'Multi-camera view',
            icon: const Icon(Icons.grid_view),
            onPressed: cams.length < 2
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => SyncPlaybackPage(state: widget.state, time: _position ?? DateTime.now().subtract(const Duration(minutes: 5))),
                    )),
          ),
        ],
      ),
      body: cams.isEmpty
          ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No cameras can record yet. Turn on recording in a camera\'s settings.')))
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(children: [
                  Expanded(
                    child: DropdownButton<Camera>(
                      isExpanded: true,
                      value: cams.where((c) => c.id == _camera?.id).firstOrNull,
                      items: [for (final c in cams) DropdownMenuItem(value: c, child: Text(c.name))],
                      onChanged: (c) {
                        setState(() {
                          _camera = c;
                          _current = null;
                        });
                        _player.stop();
                        _load(seekTo: _position);
                      },
                    ),
                  ),
                  TextButton.icon(onPressed: _pickDay, icon: const Icon(Icons.calendar_month), label: Text(ymd(_day))),
                ]),
              ),
              Expanded(
                child: _segments.isEmpty
                    ? const Center(child: Text('No recordings on this day.'))
                    : Video(controller: _video, controls: MaterialVideoControls),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Row(children: [
                  Text(_position == null ? '--:--:--' : hms(_position!), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(tooltip: 'Back 30 s', icon: const Icon(Icons.replay_30), onPressed: _position == null ? null : () => _seek(_position!.subtract(const Duration(seconds: 30)))),
                  IconButton(tooltip: 'Forward 30 s', icon: const Icon(Icons.forward_30), onPressed: _position == null ? null : () => _seek(_position!.add(const Duration(seconds: 30)))),
                  IconButton(tooltip: 'Zoom timeline', icon: Icon(_zoom == 2 ? Icons.zoom_out : Icons.zoom_in), onPressed: () => setState(() => _zoom = (_zoom + 1) % 3)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: DayTimeline(day: _day, segments: _segments, marks: _marks, position: _position, onSeek: _seek, from: from, span: span),
              ),
            ]),
    );
  }
}
