import 'dart:io';

import 'package:flutter/material.dart';

import '../ai/detection.dart';
import '../ai/event_store.dart';
import 'enhance_page.dart';

/// Log of faces and number plates the AI has seen, newest first.
class EventsPage extends StatefulWidget {
  const EventsPage({super.key});
  @override
  State<EventsPage> createState() => _EventsPageState();
}

class _EventsPageState extends State<EventsPage> {
  final store = EventStore.instance;
  DetectionKind? _kind;
  String _search = '';

  @override
  void initState() {
    super.initState();
    store.load();
  }

  String _when(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete all detections?'),
        content: const Text('Removes the detection log and its pictures from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await store.clear();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final list = store.query(kind: _kind, search: _search);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Detections'),
            actions: [IconButton(tooltip: 'Delete all', icon: const Icon(Icons.delete_sweep_outlined), onPressed: _clear)],
          ),
          body: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search plate number or camera',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _search = v),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(spacing: 8, children: [
                ChoiceChip(label: const Text('All'), selected: _kind == null, onSelected: (_) => setState(() => _kind = null)),
                ChoiceChip(label: const Text('Faces'), selected: _kind == DetectionKind.face, onSelected: (_) => setState(() => _kind = DetectionKind.face)),
                ChoiceChip(label: const Text('Plates'), selected: _kind == DetectionKind.plate, onSelected: (_) => setState(() => _kind = DetectionKind.plate)),
                ChoiceChip(label: const Text('Motion'), selected: _kind == DetectionKind.motion, onSelected: (_) => setState(() => _kind = DetectionKind.motion)),
              ]),
            ),
            Expanded(
              child: list.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Nothing yet. Turn on face or plate detection in a camera\'s settings; '
                          'detections appear here while that camera is on screen.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final e = list[i];
                        final title = switch (e.kind) {
                          DetectionKind.plate => e.text ?? 'Plate (unreadable)',
                          DetectionKind.face => 'Face',
                          DetectionKind.motion => 'Motion',
                        };
                        return ListTile(
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.file(File(e.cropPath), width: 72, height: 54, fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const SizedBox(width: 72, height: 54, child: Icon(Icons.broken_image))),
                          ),
                          title: Text(title, style: TextStyle(fontFamily: e.kind == DetectionKind.plate ? 'monospace' : null, fontWeight: FontWeight.w600)),
                          subtitle: Text('${e.cameraName} · ${_when(e.time)} · ${(e.score * 100).round()}%'),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _EventDetail(event: e, when: _when(e.time)))),
                        );
                      },
                    ),
            ),
          ]),
        );
      },
    );
  }
}

class _EventDetail extends StatelessWidget {
  const _EventDetail({required this.event, required this.when});
  final AiEvent event;
  final String when;

  @override
  Widget build(BuildContext context) {
    final e = event;
    return Scaffold(
      appBar: AppBar(
        title: Text(switch (e.kind) { DetectionKind.plate => e.text ?? 'Plate', DetectionKind.face => 'Face', DetectionKind.motion => 'Motion' }),
        actions: [
          IconButton(
            tooltip: 'Enhance',
            icon: const Icon(Icons.auto_fix_high),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EnhancePage(file: File(e.cropPath)))),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Text('${e.cameraName} · $when', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(File(e.cropPath), fit: BoxFit.contain, height: 220)),
        const SizedBox(height: 12),
        InteractiveViewer(maxScale: 6, child: Image.file(File(e.framePath), fit: BoxFit.contain)),
      ]),
    );
  }
}
