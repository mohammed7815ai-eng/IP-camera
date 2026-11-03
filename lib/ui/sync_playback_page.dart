import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/camera.dart';
import '../recording/recording_store.dart';
import '../services/app_state.dart';
import 'recordings_page.dart' show hms;

/// Plays up to four cameras at the same moment, with shared controls.
class SyncPlaybackPage extends StatefulWidget {
  const SyncPlaybackPage({super.key, required this.state, required this.time});
  final AppState state;
  final DateTime time;

  @override
  State<SyncPlaybackPage> createState() => _SyncPlaybackPageState();
}

class _Lane {
  _Lane(this.camera) : player = Player(configuration: const PlayerConfiguration(muted: true)) {
    video = VideoController(player);
  }
  final Camera camera;
  final Player player;
  late final VideoController video;
  List<Segment> segments = [];
  Segment? current;
}

class _SyncPlaybackPageState extends State<SyncPlaybackPage> {
  late DateTime _time = widget.time;
  final _lanes = <_Lane>[];
  bool _playing = true;
  double _rate = 1;

  @override
  void initState() {
    super.initState();
    for (final c in widget.state.cameras.where((c) => c.canRecord).take(4)) {
      _lanes.add(_Lane(c));
    }
    _goTo(_time);
  }

  @override
  void dispose() {
    for (final l in _lanes) {
      l.player.dispose();
    }
    super.dispose();
  }

  Future<void> _goTo(DateTime t) async {
    setState(() => _time = t);
    await Future.wait(_lanes.map((l) async {
      l.segments = await RecordingStore.instance.segmentsForDay(l.camera.id, t);
      final seg = l.segments.where((s) => s.contains(t)).firstOrNull;
      if (seg == null) {
        l.current = null;
        await l.player.stop();
        return;
      }
      if (l.current?.file.path != seg.file.path) {
        l.current = seg;
        await l.player.open(Media(seg.file.uri.toString()), play: _playing);
        await l.player.stream.duration.firstWhere((d) => d > Duration.zero).timeout(const Duration(seconds: 5), onTimeout: () => Duration.zero);
      }
      await l.player.setRate(_rate);
      await l.player.seek(t.difference(seg.start));
      if (_playing) await l.player.play();
    }));
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    setState(() => _playing = !_playing);
    for (final l in _lanes) {
      _playing ? await l.player.play() : await l.player.pause();
    }
  }

  DateTime get _now {
    for (final l in _lanes) {
      if (l.current != null) return l.current!.start.add(l.player.state.position);
    }
    return _time;
  }

  @override
  Widget build(BuildContext context) {
    final cols = _lanes.length <= 1 ? 1 : 2;
    return Scaffold(
      appBar: AppBar(title: const Text('Multi-camera playback')),
      body: Column(children: [
        Expanded(
          child: GridView.count(
            crossAxisCount: cols,
            childAspectRatio: 16 / 9,
            padding: const EdgeInsets.all(6),
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            children: [
              for (final l in _lanes)
                Stack(fit: StackFit.expand, children: [
                  ColoredBox(
                    color: Colors.black,
                    child: l.current == null
                        ? const Center(child: Text('No recording at this time', style: TextStyle(color: Colors.white54)))
                        : Video(controller: l.video, controls: NoVideoControls),
                  ),
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      color: Colors.black54,
                      child: Text(l.camera.name, style: const TextStyle(color: Colors.white, fontSize: 12)),
                    ),
                  ),
                ]),
            ],
          ),
        ),
        StreamBuilder<Object?>(
          stream: Stream<Object?>.periodic(const Duration(milliseconds: 500)),
          builder: (context, _) => Padding(
            padding: const EdgeInsets.all(8),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(icon: const Icon(Icons.replay_30), onPressed: () => _goTo(_now.subtract(const Duration(seconds: 30)))),
              IconButton.filled(icon: Icon(_playing ? Icons.pause : Icons.play_arrow), onPressed: _toggle),
              IconButton(icon: const Icon(Icons.forward_30), onPressed: () => _goTo(_now.add(const Duration(seconds: 30)))),
              const SizedBox(width: 12),
              Text(hms(_now), style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              DropdownButton<double>(
                value: _rate,
                items: [for (final r in [0.5, 1.0, 2.0, 4.0, 8.0]) DropdownMenuItem(value: r, child: Text('${r}x'))],
                onChanged: (r) async {
                  setState(() => _rate = r ?? 1);
                  for (final l in _lanes) {
                    await l.player.setRate(_rate);
                  }
                },
              ),
              const SizedBox(width: 12),
              TextButton(onPressed: () => _goTo(_now), child: const Text('Re-sync')),
            ]),
          ),
        ),
      ]),
    );
  }
}
