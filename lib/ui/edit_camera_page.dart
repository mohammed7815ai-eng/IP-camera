import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/camera.dart';
import '../services/app_state.dart';
import '../services/onvif.dart';
import '../services/secure_http.dart';
import 'live_view.dart' show snapshotUri;

class EditCameraPage extends StatefulWidget {
  const EditCameraPage({super.key, required this.state, this.existing});
  final AppState state;
  final Camera? existing;

  @override
  State<EditCameraPage> createState() => _EditCameraPageState();
}

class _EditCameraPageState extends State<EditCameraPage> {
  final _form = GlobalKey<FormState>();
  late final Camera _cam;
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _path = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _apiHeader = TextEditingController();
  final _apiKey = TextEditingController();
  final _refresh = TextEditingController();
  bool _hidePass = true;
  bool _busy = false;
  String? _message;
  List<OnvifProfile> _profiles = [];
  OnvifProfile? _profile;
  Uri? _mediaUri;
  List<DiscoveredDevice>? _discovered;

  bool get _isNew => widget.existing == null;

  @override
  void initState() {
    super.initState();
    _cam = widget.existing?.copy() ?? Camera(id: const Uuid().v4(), name: '', kind: CameraKind.onvif, useTls: false);
    _name.text = _cam.name;
    _host.text = _cam.host;
    _port.text = _cam.port == 0 ? '' : '${_cam.port}';
    _path.text = _cam.path;
    _user.text = _cam.username;
    _apiHeader.text = _cam.apiKeyHeader;
    _refresh.text = '${_cam.refreshSeconds}';
  }

  @override
  void dispose() {
    for (final c in [_name, _host, _port, _path, _user, _pass, _apiHeader, _apiKey, _refresh]) {
      c.dispose();
    }
    super.dispose();
  }

  void _readForm() {
    _cam
      ..name = _name.text.trim().isEmpty ? 'Camera' : _name.text.trim()
      ..host = _host.text.trim()
      ..port = int.tryParse(_port.text.trim()) ?? 0
      ..path = _path.text.trim()
      ..username = _user.text.trim()
      ..apiKeyHeader = _apiHeader.text.trim().isEmpty ? 'X-API-Key' : _apiHeader.text.trim()
      ..refreshSeconds = int.tryParse(_refresh.text.trim()) ?? 2;
  }

  /// Password typed now, or the stored one when editing and the field is blank.
  Future<String> _password() async =>
      _pass.text.isNotEmpty ? _pass.text : (await widget.state.repo.password(_cam.id) ?? '');

  Future<String> _apiKeyValue() async =>
      _apiKey.text.isNotEmpty ? _apiKey.text : (await widget.state.repo.apiKey(_cam.id) ?? '');

  Future<void> _discover() async {
    setState(() {
      _busy = true;
      _message = 'Searching your network for ONVIF cameras…';
    });
    try {
      final list = await discoverOnvif();
      setState(() {
        _discovered = list;
        _message = list.isEmpty ? 'No cameras answered. Enter the address by hand.' : null;
      });
    } catch (e) {
      setState(() => _message = 'Search failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  /// Shows the certificate fingerprint and asks the user to trust it.
  Future<bool> _confirmCertificate(String fp) async {
    if (_cam.pinnedSha256 == fp) return true;
    final changed = _cam.pinnedSha256 != null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: Icon(changed ? Icons.warning_amber : Icons.verified_user_outlined),
        title: Text(changed ? 'Certificate changed' : 'Trust this camera?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(changed
              ? 'The camera now presents a different certificate. Only continue if you reset or re-keyed it.'
              : 'HomeGuard will only ever accept this exact certificate from the camera. '
                  'If the camera\'s web page shows a fingerprint, check that it matches.'),
          const SizedBox(height: 12),
          const Text('SHA-256 fingerprint', style: TextStyle(fontWeight: FontWeight.w600)),
          SelectableText(formatFingerprint(fp), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Trust')),
        ],
      ),
    );
    if (ok == true) {
      _cam.pinnedSha256 = fp;
      return true;
    }
    return false;
  }

  Uri _onvifDeviceUri() {
    final h = _cam.host;
    if (h.startsWith('http://') || h.startsWith('https://')) return Uri.parse(h);
    final p = _cam.path.isEmpty ? '/onvif/device_service' : (_cam.path.startsWith('/') ? _cam.path : '/${_cam.path}');
    return Uri(scheme: _cam.useTls ? 'https' : 'http', host: h, port: _cam.effectivePort, path: p);
  }

  Future<void> _connectOnvif() async {
    _readForm();
    if (_cam.host.isEmpty) {
      setState(() => _message = 'Enter the camera address first.');
      return;
    }
    setState(() {
      _busy = true;
      _message = 'Connecting over ONVIF…';
    });
    try {
      final device = _onvifDeviceUri();
      final pw = await _password();
      var client = OnvifClient(
        deviceUri: device,
        username: _cam.username,
        password: pw,
        pinnedSha256: _cam.pinnedSha256,
        trustOnFirstUse: device.scheme == 'https' && _cam.pinnedSha256 == null,
      );
      await client.syncClock();
      if (device.scheme == 'https' && client.lastFingerprint != null && _cam.pinnedSha256 == null) {
        if (!await _confirmCertificate(client.lastFingerprint!)) {
          setState(() => _message = 'Not connected: certificate not trusted.');
          return;
        }
        client = OnvifClient(deviceUri: device, username: _cam.username, password: pw, pinnedSha256: _cam.pinnedSha256);
        await client.syncClock();
      }
      final media = await client.mediaService();
      final profiles = await client.profiles(media);
      _mediaUri = media;
      final profile = profiles.first;
      final uri = await client.streamUri(media, profile.token);
      setState(() {
        _profiles = profiles;
        _profile = profile;
        _cam.resolvedStreamUri = uri;
        _message = 'Connected. ${profiles.length} stream profile(s) found.';
      });
    } on CertificatePinMismatch catch (e) {
      setState(() => _message = e.toString());
    } catch (e) {
      setState(() => _message = 'Could not connect: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickProfile(OnvifProfile? p) async {
    if (p == null || _mediaUri == null) return;
    setState(() => _busy = true);
    try {
      final client = OnvifClient(
        deviceUri: _onvifDeviceUri(),
        username: _cam.username,
        password: await _password(),
        pinnedSha256: _cam.pinnedSha256,
      );
      await client.syncClock();
      final uri = await client.streamUri(_mediaUri!, p.token);
      setState(() {
        _profile = p;
        _cam.resolvedStreamUri = uri;
      });
    } catch (e) {
      setState(() => _message = 'Could not switch profile: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _testHttpApi() async {
    _readForm();
    setState(() {
      _busy = true;
      _message = 'Testing…';
    });
    try {
      final uri = snapshotUri(_cam);
      final key = await _apiKeyValue();
      final headers = <String, String>{if (key.isNotEmpty) _cam.apiKeyHeader: key};
      if (uri.scheme == 'https' && _cam.pinnedSha256 == null) {
        final probe = await SecureHttp(trustOnFirstUse: true).get(uri, headers: headers);
        if (probe.fingerprint != null && !await _confirmCertificate(probe.fingerprint!)) {
          setState(() => _message = 'Not saved: certificate not trusted.');
          return;
        }
      }
      final res = await SecureHttp(pinnedSha256: _cam.pinnedSha256).get(uri, headers: headers);
      setState(() => _message = res.status == 200
          ? 'Connected: received a ${(res.body.length / 1024).toStringAsFixed(0)} KB image.'
          : 'Camera answered HTTP ${res.status}. Check the path and API key.');
    } catch (e) {
      setState(() => _message = 'Could not connect: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    _readForm();
    if (_cam.kind == CameraKind.onvif && _cam.resolvedStreamUri == null) {
      await _connectOnvif();
      if (_cam.resolvedStreamUri == null) return;
    }
    if (_cam.kind == CameraKind.httpApi && _cam.useTls && _cam.pinnedSha256 == null) {
      await _testHttpApi();
      if (_cam.pinnedSha256 == null) return;
    }
    if (!_cam.useTls && _cam.kind != CameraKind.rtsp) _cam.pinnedSha256 = null;
    await widget.state.saveCamera(
      _cam,
      password: _pass.text.isEmpty ? null : _pass.text,
      apiKey: _apiKey.text.isEmpty ? null : _apiKey.text,
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove ${_cam.name}?'),
        content: const Text('The camera and its stored password or API key are deleted from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.state.deleteCamera(_cam.id);
    if (mounted) Navigator.of(context).pop();
  }

  Widget _field(TextEditingController c, String label, {String? hint, bool required = false, TextInputType? type, Widget? suffix, bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: c,
        keyboardType: type,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: !obscure,
        decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder(), suffixIcon: suffix),
        validator: required ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final kind = _cam.kind;
    final passHint = _isNew ? null : 'Leave blank to keep the saved one';
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Add camera' : 'Edit camera'),
        actions: [if (!_isNew) IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline), onPressed: _delete)],
      ),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          SegmentedButton<CameraKind>(
            segments: const [
              ButtonSegment(value: CameraKind.onvif, label: Text('ONVIF'), icon: Icon(Icons.travel_explore)),
              ButtonSegment(value: CameraKind.rtsp, label: Text('RTSP'), icon: Icon(Icons.videocam_outlined)),
              ButtonSegment(value: CameraKind.httpApi, label: Text('API key'), icon: Icon(Icons.key_outlined)),
            ],
            selected: {kind},
            onSelectionChanged: (s) => setState(() {
              _cam.kind = s.first;
              _cam.pinnedSha256 = null;
              _cam.resolvedStreamUri = null;
              _profiles = [];
              _message = null;
            }),
          ),
          const SizedBox(height: 16),
          _field(_name, 'Name', hint: 'Front door', required: true),
          if (kind == CameraKind.onvif) ...[
            OutlinedButton.icon(
              onPressed: _busy ? null : _discover,
              icon: const Icon(Icons.wifi_find),
              label: const Text('Find cameras on my network'),
            ),
            if (_discovered != null)
              for (final d in _discovered!)
                ListTile(
                  leading: const Icon(Icons.videocam),
                  title: Text(d.name),
                  subtitle: Text(d.xaddr.toString()),
                  onTap: () => setState(() {
                    _host.text = d.xaddr.host;
                    _port.text = d.xaddr.hasPort ? '${d.xaddr.port}' : '';
                    _path.text = d.xaddr.path;
                    _cam.useTls = d.xaddr.scheme == 'https';
                    if (_name.text.isEmpty) _name.text = d.name;
                  }),
                ),
            const SizedBox(height: 12),
          ],
          _field(_host, kind == CameraKind.rtsp ? 'Address or full rtsp:// URL' : 'Address', hint: '192.168.1.20', required: true),
          Row(children: [
            Expanded(child: _field(_port, 'Port', hint: '${_cam.effectivePort}', type: TextInputType.number)),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: _field(
                _path,
                switch (kind) {
                  CameraKind.rtsp => 'Stream path',
                  CameraKind.onvif => 'ONVIF path',
                  CameraKind.httpApi => 'Snapshot path',
                },
                hint: switch (kind) {
                  CameraKind.rtsp => '/Streaming/Channels/101',
                  CameraKind.onvif => '/onvif/device_service',
                  CameraKind.httpApi => '/api/snapshot.jpg',
                },
              ),
            ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(kind == CameraKind.rtsp ? 'Encrypted stream (RTSPS)' : 'Encrypted connection (HTTPS)'),
            subtitle: Text(_cam.useTls
                ? (kind == CameraKind.rtsp ? 'Traffic is encrypted.' : 'Certificate is pinned on first connect.')
                : 'Unencrypted. Only use on a private home network or a separate camera VLAN.'),
            value: _cam.useTls,
            onChanged: (v) => setState(() {
              _cam.useTls = v;
              _cam.pinnedSha256 = null;
            }),
          ),
          const SizedBox(height: 8),
          _field(_user, 'User name'),
          _field(
            _pass,
            'Password',
            hint: passHint,
            obscure: _hidePass,
            suffix: IconButton(
              icon: Icon(_hidePass ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              onPressed: () => setState(() => _hidePass = !_hidePass),
            ),
          ),
          if (kind == CameraKind.httpApi) ...[
            _field(_apiHeader, 'API key header', hint: 'X-API-Key'),
            _field(_apiKey, 'API key', hint: passHint, obscure: true),
            _field(_refresh, 'Refresh every (seconds)', type: TextInputType.number),
          ],
          if (kind == CameraKind.onvif && _profiles.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: DropdownButtonFormField<OnvifProfile>(
                initialValue: _profile,
                decoration: const InputDecoration(labelText: 'Stream quality', border: OutlineInputBorder()),
                items: [for (final p in _profiles) DropdownMenuItem(value: p, child: Text(p.label))],
                onChanged: _busy ? null : _pickProfile,
              ),
            ),
          if (_cam.pinnedSha256 != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.verified_user, color: Colors.green),
              title: const Text('Pinned certificate'),
              subtitle: Text(short(_cam.pinnedSha256!), style: const TextStyle(fontFamily: 'monospace')),
            ),
          if (_message != null)
            Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(_message!)),
          if (_busy) const LinearProgressIndicator(),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 12, children: [
            if (kind == CameraKind.onvif)
              OutlinedButton.icon(onPressed: _busy ? null : _connectOnvif, icon: const Icon(Icons.link), label: const Text('Connect')),
            if (kind == CameraKind.httpApi)
              OutlinedButton.icon(onPressed: _busy ? null : _testHttpApi, icon: const Icon(Icons.network_check), label: const Text('Test')),
            FilledButton.icon(onPressed: _busy ? null : _save, icon: const Icon(Icons.save_outlined), label: const Text('Save')),
          ]),
        ]),
      ),
    );
  }
}
