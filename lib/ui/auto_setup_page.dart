import 'package:flutter/material.dart';

import '../discovery/camera_agent.dart';
import '../services/app_state.dart';

/// "Find and set up cameras automatically": runs [CameraSetupAgent] and lets
/// the user add the cameras it got working with one tap.
class AutoSetupPage extends StatefulWidget {
  const AutoSetupPage({super.key, required this.state});
  final AppState state;

  @override
  State<AutoSetupPage> createState() => _AutoSetupPageState();
}

class _AutoSetupPageState extends State<AutoSetupPage> {
  final _agent = CameraSetupAgent();
  final _user = TextEditingController(text: 'admin');
  final _pass = TextEditingController();
  bool _hidePass = true;
  bool _started = false;
  bool _showLog = false;

  @override
  void dispose() {
    _agent.cancel();
    _agent.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    FocusScope.of(context).unfocus();
    setState(() => _started = true);
    await _agent.run(user: _user.text.trim(), password: _pass.text);
  }

  Future<void> _add(FoundDevice d) async {
    final cam = d.camera;
    if (cam == null) return;
    // Skip cameras already in the app at the same address.
    if (widget.state.cameras.any((c) => c.host == cam.host)) {
      setState(() {
        d.status = DeviceStatus.added;
        d.detail = 'Already in your cameras.';
      });
      return;
    }
    await widget.state.saveCamera(cam, password: d.password.isEmpty ? null : d.password);
    setState(() {
      d.status = DeviceStatus.added;
      d.detail = 'Added as "${cam.name}".';
    });
  }

  Future<void> _addAll() async {
    for (final d in _agent.devices.values.where((d) => d.status == DeviceStatus.ready).toList()) {
      await _add(d);
    }
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cameras added to your Home screen.')));
  }

  Future<void> _askPassword(FoundDevice d) async {
    final user = TextEditingController(text: d.user);
    final pass = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Login for ${d.ip}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Use the user name and password from the camera\'s app or its sticker. ONVIF cameras may need a separate ONVIF user.'),
          const SizedBox(height: 12),
          TextField(controller: user, decoration: const InputDecoration(labelText: 'User name')),
          TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Try again')),
        ],
      ),
    );
    if (ok == true) await _agent.retry(d, user: user.text.trim(), password: pass.text);
    user.dispose();
    pass.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Auto setup')),
      body: ListenableBuilder(
        listenable: _agent,
        builder: (context, _) {
          final list = _agent.sorted;
          final ready = list.where((d) => d.status == DeviceStatus.ready).length;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'HomeGuard scans your home network, finds cameras, works out their stream settings and checks the login. '
                'Nothing leaves your network.',
              ),
              const SizedBox(height: 12),
              Text('Camera login (most cameras share one)', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _user,
                    enabled: !_agent.running,
                    decoration: const InputDecoration(labelText: 'User name', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _pass,
                    enabled: !_agent.running,
                    obscureText: _hidePass,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      helperText: 'Often printed on the camera',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_hidePass ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _hidePass = !_hidePass),
                      ),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                if (_agent.running)
                  OutlinedButton.icon(onPressed: _agent.cancel, icon: const Icon(Icons.stop), label: const Text('Stop'))
                else
                  FilledButton.icon(
                    onPressed: _start,
                    icon: const Icon(Icons.radar),
                    label: Text(_started ? 'Scan again' : 'Find my cameras'),
                  ),
                const Spacer(),
                if (ready > 0 && !_agent.running)
                  FilledButton.tonalIcon(onPressed: _addAll, icon: const Icon(Icons.done_all), label: Text('Add all ($ready)')),
              ]),
              if (_agent.running) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _agent.progress == 0 ? null : _agent.progress),
                const SizedBox(height: 6),
                Text(_agent.phase, style: Theme.of(context).textTheme.bodySmall),
              ],
              const SizedBox(height: 12),
              for (final d in list) _DeviceCard(d: d, onAdd: () => _add(d), onPassword: () => _askPassword(d)),
              if (_started && !_agent.running && list.isEmpty && _agent.log.isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 8), child: Text(_agent.log.last)),
              if (_agent.log.isNotEmpty) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => setState(() => _showLog = !_showLog),
                  icon: Icon(_showLog ? Icons.expand_less : Icons.expand_more),
                  label: Text(_showLog ? 'Hide details' : 'Show what the agent did'),
                ),
                if (_showLog)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(_agent.log.join('\n'), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.d, required this.onAdd, required this.onPassword});
  final FoundDevice d;
  final VoidCallback onAdd;
  final VoidCallback onPassword;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (d.status) {
      DeviceStatus.ready => (Icons.check_circle, Colors.green),
      DeviceStatus.added => (Icons.check_circle_outline, Colors.grey),
      DeviceStatus.needsPassword => (Icons.lock_outline, Colors.orange),
      DeviceStatus.noStream => (Icons.help_outline, Colors.grey),
      DeviceStatus.checking => (Icons.hourglass_top, Colors.blue),
    };
    return Card(
      child: ListTile(
        leading: d.status == DeviceStatus.checking
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(icon, color: color),
        title: Text(d.title),
        subtitle: Text(d.detail),
        isThreeLine: d.detail.length > 50,
        onTap: d.status == DeviceStatus.needsPassword || d.status == DeviceStatus.noStream ? onPassword : null,
        trailing: switch (d.status) {
          DeviceStatus.ready => FilledButton(onPressed: onAdd, child: const Text('Add')),
          DeviceStatus.needsPassword => OutlinedButton(onPressed: onPassword, child: const Text('Password')),
          _ => null,
        },
      ),
    );
  }
}
