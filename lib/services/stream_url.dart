import '../models/camera.dart';

/// Builds the playable stream URL for [cam], with credentials injected.
/// Credentials are percent-encoded so passwords containing `@`, `:` or `/`
/// work. Never log the result; use [redact] for display.
String buildStreamUrl(Camera cam, {String? password}) {
  final base = switch (cam.kind) {
    CameraKind.onvif => cam.resolvedStreamUri ?? '',
    _ => _rtspFromParts(cam),
  };
  if (base.isEmpty) return base;
  return withCredentials(base, cam.username, password);
}

String _rtspFromParts(Camera cam) {
  final h = cam.host.trim();
  // Allow pasting a full rtsp:// URL into the host field.
  if (h.startsWith('rtsp://') || h.startsWith('rtsps://')) return h;
  final scheme = cam.useTls ? 'rtsps' : 'rtsp';
  var p = cam.path.trim();
  if (p.isNotEmpty && !p.startsWith('/')) p = '/$p';
  return '$scheme://${_hostForUri(h)}:${cam.effectivePort}$p';
}

String _hostForUri(String h) => h.contains(':') && !h.startsWith('[') ? '[$h]' : h;

/// Returns [url] with `user:password@` set. Existing credentials in the URL
/// are replaced when [user] is non-empty.
String withCredentials(String url, String user, String? password) {
  if (user.isEmpty) return url;
  final m = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*://)(?:[^@/]*@)?(.*)$').firstMatch(url);
  if (m == null) return url;
  final info = password == null || password.isEmpty
      ? Uri.encodeComponent(user)
      : '${Uri.encodeComponent(user)}:${Uri.encodeComponent(password)}';
  return '${m.group(1)}$info@${m.group(2)}';
}

/// Hides any password in a URL for display or logs.
String redact(String url) {
  final u = Uri.tryParse(url);
  if (u == null || u.userInfo.isEmpty) return url;
  final user = u.userInfo.split(':').first;
  return url.replaceFirst(u.userInfo, '$user:••••');
}
