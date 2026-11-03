import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../recording/recording_service.dart';
import '../recording/recording_store.dart';
import '../services/app_state.dart';
import '../services/background.dart';
import '../services/snapshots.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.state});
  final AppState state;

  Future<void> _toggleLock(BuildContext context, bool v) async {
    final messenger = ScaffoldMessenger.of(context);
    if (v) {
      final auth = LocalAuthentication();
      final supported = await auth.isDeviceSupported();
      if (!supported) {
        messenger.showSnackBar(const SnackBar(content: Text('This device has no Windows Hello, fingerprint, or screen lock set up.')));
        return;
      }
      final ok = await auth.authenticate(localizedReason: 'Confirm to turn on app lock');
      if (!ok) return;
    }
    await state.setAppLock(v);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(children: [
          SwitchListTile(
            secondary: const Icon(Icons.fingerprint),
            title: const Text('App lock'),
            subtitle: const Text('Ask for Windows Hello, fingerprint, or PIN when opening the app'),
            value: state.appLock,
            onChanged: (v) => _toggleLock(context, v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.psychology_outlined),
            title: const Text('AI detection'),
            subtitle: const Text('Face and number-plate detection on cameras where you turned it on. Runs on this device only.'),
            value: state.aiEnabled,
            onChanged: state.setAiEnabled,
          ),
          ListenableBuilder(
            listenable: RecordingService.instance,
            builder: (context, _) => ListTile(
              leading: const Icon(Icons.storage_outlined),
              title: const Text('Recording storage limit'),
              subtitle: FutureBuilder<int>(
                future: RecordingStore.instance.totalBytes(),
                builder: (context, snap) => Text(
                  'Using ${snap.hasData ? (snap.data! / 1073741824).toStringAsFixed(1) : '…'} GB of '
                  '${RecordingService.instance.maxGigabytes} GB; oldest footage is deleted first',
                ),
              ),
              trailing: DropdownButton<int>(
                value: RecordingService.instance.maxGigabytes,
                items: [for (final g in [5, 10, 25, 50, 100, 250, 500, 1000]) DropdownMenuItem(value: g, child: Text('$g GB'))],
                onChanged: (g) => RecordingService.instance.setMaxGigabytes(g ?? 50),
              ),
            ),
          ),
          FutureBuilder(
            future: RecordingStore.instance.root(),
            builder: (context, snap) => ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('Recordings folder'),
              subtitle: Text(snap.data?.path ?? '…'),
            ),
          ),
          if (BackgroundMode.supported) const _BackgroundTile(),
          FutureBuilder(
            future: snapshotDir(),
            builder: (context, snap) => ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Snapshot folder'),
              subtitle: Text(snap.data?.path ?? '…'),
            ),
          ),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.shield_outlined),
            title: Text('Security'),
            subtitle: Text(
              'Camera passwords and API keys are stored in the Android Keystore or Windows DPAPI, never in plain text. '
              'HTTPS cameras are pinned to the certificate you approved when adding them; a changed certificate blocks the connection. '
              'ONVIF logins use digest authentication, so the password is not sent over the network.',
            ),
          ),
          const AboutListTile(
            icon: Icon(Icons.info_outline),
            applicationName: 'HomeGuard',
            applicationVersion: '1.2.0',
            aboutBoxChildren: [
              Text('Home security camera viewer for Windows and Android.'),
              SizedBox(height: 8),
              Text('AI models (MIT licence): UltraFace RFB-320 by Linzaer; YOLOv9 plate detector from open-image-models '
                  'and fast-plate-ocr by ankandrew.'),
            ],
          ),
        ]),
      ),
    );
  }
}

class _BackgroundTile extends StatefulWidget {
  const _BackgroundTile();
  @override
  State<_BackgroundTile> createState() => _BackgroundTileState();
}

class _BackgroundTileState extends State<_BackgroundTile> {
  bool? _on;
  @override
  void initState() {
    super.initState();
    BackgroundMode.enabled().then((v) => setState(() => _on = v));
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
        secondary: const Icon(Icons.nightlight_outlined),
        title: const Text('Keep watching in the background'),
        subtitle: const Text('Recording, detection and alarms continue when you leave the app. Shows a permanent notification.'),
        value: _on ?? false,
        onChanged: _on == null
            ? null
            : (v) async {
                final messenger = ScaffoldMessenger.of(context);
                final err = await BackgroundMode.set(v);
                setState(() => _on = v);
                if (err != null) messenger.showSnackBar(SnackBar(content: Text('Could not change background mode: $err')));
              },
      );
}
