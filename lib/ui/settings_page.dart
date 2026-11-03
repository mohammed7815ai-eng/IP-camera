import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../services/app_state.dart';
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
            applicationVersion: '1.0.0',
            aboutBoxChildren: [Text('Home security camera viewer for Windows and Android.')],
          ),
        ]),
      ),
    );
  }
}
