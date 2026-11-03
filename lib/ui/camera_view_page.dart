import 'package:flutter/material.dart';

import '../models/camera.dart';
import '../services/app_state.dart';
import '../services/snapshots.dart';
import 'edit_camera_page.dart';
import 'live_view.dart';

class CameraViewPage extends StatefulWidget {
  const CameraViewPage({super.key, required this.camera, required this.state});
  final Camera camera;
  final AppState state;

  @override
  State<CameraViewPage> createState() => _CameraViewPageState();
}

class _CameraViewPageState extends State<CameraViewPage> {
  LiveViewHandle? _handle;
  bool _contain = true;

  Future<void> _snap() async {
    final messenger = ScaffoldMessenger.of(context);
    final bytes = await _handle?.snapshot();
    if (bytes == null) {
      messenger.showSnackBar(const SnackBar(content: Text('No picture yet to save.')));
      return;
    }
    final f = await saveSnapshot(widget.camera.name, bytes);
    messenger.showSnackBar(SnackBar(content: Text('Saved ${f.path}')));
  }

  @override
  Widget build(BuildContext context) {
    final cam = widget.camera;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(cam.name),
        actions: [
          IconButton(
            tooltip: _contain ? 'Fill screen' : 'Fit to screen',
            icon: Icon(_contain ? Icons.fullscreen : Icons.fullscreen_exit),
            onPressed: () => setState(() => _contain = !_contain),
          ),
          IconButton(tooltip: 'Save snapshot', icon: const Icon(Icons.camera_alt_outlined), onPressed: _snap),
          IconButton(
            tooltip: 'Edit camera',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              final nav = Navigator.of(context);
              await nav.push(MaterialPageRoute<void>(builder: (_) => EditCameraPage(state: widget.state, existing: cam)));
              if (mounted) nav.pop();
            },
          ),
        ],
      ),
      body: InteractiveViewer(
        maxScale: 6,
        child: LiveView(
          camera: cam,
          repo: widget.state.repo,
          fit: _contain ? BoxFit.contain : BoxFit.cover,
          controllerOut: (h) => _handle = h,
        ),
      ),
    );
  }
}
