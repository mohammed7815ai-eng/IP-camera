import 'package:flutter/material.dart';

import '../models/camera.dart';
import '../services/app_state.dart';
import 'camera_view_page.dart';
import 'edit_camera_page.dart';
import 'events_page.dart';
import 'alarms_page.dart';
import 'recordings_page.dart';
import '../alarm/alarm.dart';
import 'live_view.dart';
import 'settings_page.dart';
import 'snapshots_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.state});
  final AppState state;

  Future<void> _add(BuildContext context) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EditCameraPage(state: state)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final cams = state.cameras;
        return Scaffold(
          appBar: AppBar(
            title: const Text('HomeGuard'),
            actions: [
              ListenableBuilder(
                listenable: AlarmCenter.instance,
                builder: (context, _) {
                  final a = AlarmCenter.instance;
                  final mode = a.settings.mode;
                  return IconButton(
                    tooltip: 'Alarm: ${mode.label}',
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlarmsPage(state: state))),
                    icon: Badge(
                      isLabelVisible: a.unacknowledged > 0,
                      label: Text('${a.unacknowledged}'),
                      child: Icon(
                        switch (mode) { ArmMode.disarmed => Icons.shield_outlined, ArmMode.home => Icons.home_outlined, ArmMode.away => Icons.shield },
                        color: mode == ArmMode.disarmed ? null : Colors.redAccent,
                      ),
                    ),
                  );
                },
              ),
              IconButton(
                tooltip: 'Recordings',
                icon: const Icon(Icons.video_library_outlined),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RecordingsPage(state: state))),
              ),
              PopupMenuButton<int>(
                tooltip: 'Grid size',
                icon: const Icon(Icons.grid_view),
                onSelected: state.setGridColumns,
                itemBuilder: (_) => [
                  for (final n in [1, 2, 3, 4])
                    CheckedPopupMenuItem(value: n, checked: state.gridColumns == n, child: Text('$n per row')),
                ],
              ),
              IconButton(
                tooltip: 'Detections',
                icon: const Icon(Icons.manage_search),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const EventsPage())),
              ),
              IconButton(
                tooltip: 'Snapshots',
                icon: const Icon(Icons.photo_library_outlined),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SnapshotsPage())),
              ),
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsPage(state: state))),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _add(context),
            icon: const Icon(Icons.add),
            label: const Text('Add camera'),
          ),
          body: cams.isEmpty
              ? _Empty(onAdd: () => _add(context))
              : LayoutBuilder(builder: (context, box) {
                  final cols = box.maxWidth < 500 ? state.gridColumns.clamp(1, 2) : state.gridColumns;
                  return GridView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      childAspectRatio: 16 / 9,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                    ),
                    itemCount: cams.length,
                    itemBuilder: (context, i) => _Tile(camera: cams[i], state: state),
                  );
                }),
        );
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.camera, required this.state});
  final Camera camera;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Material(
        color: Colors.black,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => CameraViewPage(camera: camera, state: state)),
          ),
          child: Stack(fit: StackFit.expand, children: [
            LiveView(key: ValueKey(camera.toJson().toString()), camera: camera, repo: state.repo, aiActive: state.aiEnabled),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: [Colors.transparent, Colors.black87], begin: Alignment.topCenter, end: Alignment.bottomCenter),
                ),
                child: Row(children: [
                  Icon(camera.useTls ? Icons.lock : Icons.lock_open, size: 14, color: camera.useTls ? Colors.greenAccent : Colors.orangeAccent),
                  const SizedBox(width: 6),
                  Expanded(child: Text(camera.name, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white))),
                  if (camera.canRecord && camera.recording != RecordingMode.off)
                    const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.fiber_manual_record, size: 12, color: Colors.redAccent)),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd});
  final VoidCallback onAdd;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.videocam_outlined, size: 72),
            const SizedBox(height: 12),
            const Text('No cameras yet', style: TextStyle(fontSize: 20)),
            const SizedBox(height: 8),
            const Text('Add an RTSP, ONVIF, or HTTPS API camera on your home network.', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('Add camera')),
          ]),
        ),
      );
}
