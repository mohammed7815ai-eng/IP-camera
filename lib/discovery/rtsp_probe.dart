import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Result of an RTSP DESCRIBE request.
class RtspReply {
  RtspReply(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers;
  final String body;

  bool get ok => status == 200;
  bool get hasVideo => body.contains('m=video');
}

/// Replaces `{user}` and `{password}` in a stream path. Some cheap cameras
/// (XMEye / iCSee) expect the login inside the path instead of in the URL.
String fillPathTemplate(String path, String user, String password) =>
    path.replaceAll('{user}', user).replaceAll('{password}', password);

/// Builds an `Authorization` header value for a 401 challenge.
/// Supports RTSP Digest (RFC 2069 and qop=auth) and Basic.
String? authorizationFor({
  required String challenge,
  required String method,
  required String uri,
  required String user,
  required String password,
  String? cnonce,
}) {
  final c = challenge.trim();
  if (c.toLowerCase().startsWith('basic')) {
    return 'Basic ${base64.encode(utf8.encode('$user:$password'))}';
  }
  if (!c.toLowerCase().startsWith('digest')) return null;
  final params = <String, String>{};
  for (final m in RegExp(r'(\w+)=(?:"([^"]*)"|([^,\s]*))').allMatches(c.substring(6))) {
    params[m.group(1)!.toLowerCase()] = m.group(2) ?? m.group(3) ?? '';
  }
  final realm = params['realm'] ?? '';
  final nonce = params['nonce'] ?? '';
  String md5hex(String s) => md5.convert(utf8.encode(s)).toString();
  final ha1 = md5hex('$user:$realm:$password');
  final ha2 = md5hex('$method:$uri');
  final qop = (params['qop'] ?? '').split(',').map((e) => e.trim()).contains('auth') ? 'auth' : null;
  final parts = <String>[
    'username="$user"',
    'realm="$realm"',
    'nonce="$nonce"',
    'uri="$uri"',
  ];
  if (qop != null) {
    final cn = cnonce ?? List.generate(8, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    const nc = '00000001';
    parts.add('response="${md5hex('$ha1:$nonce:$nc:$cn:$qop:$ha2')}"');
    parts.addAll(['qop=$qop', 'nc=$nc', 'cnonce="$cn"']);
  } else {
    parts.add('response="${md5hex('$ha1:$nonce:$ha2')}"');
  }
  if (params['opaque'] != null) parts.add('opaque="${params['opaque']}"');
  return 'Digest ${parts.join(', ')}';
}

/// Parses an RTSP response head and body.
RtspReply? parseRtspReply(String raw) {
  final split = raw.indexOf('\r\n\r\n');
  final head = split < 0 ? raw : raw.substring(0, split);
  final lines = head.split('\r\n');
  final m = RegExp(r'^RTSP/1\.\d\s+(\d{3})').firstMatch(lines.first);
  if (m == null) return null;
  final headers = <String, String>{};
  for (final l in lines.skip(1)) {
    final i = l.indexOf(':');
    if (i <= 0) continue;
    final k = l.substring(0, i).trim().toLowerCase();
    final v = l.substring(i + 1).trim();
    // Keep the first Digest challenge if a camera offers several.
    if (k == 'www-authenticate' && headers.containsKey(k)) {
      if (!headers[k]!.toLowerCase().startsWith('digest') && v.toLowerCase().startsWith('digest')) headers[k] = v;
      continue;
    }
    headers[k] = v;
  }
  return RtspReply(int.parse(m.group(1)!), headers, split < 0 ? '' : raw.substring(split + 4));
}

/// Sends one RTSP DESCRIBE. Answers 401 challenges once with the given
/// credentials. Returns null when the port does not speak RTSP.
Future<RtspReply?> rtspDescribe(
  String host,
  int port,
  String path, {
  String user = '',
  String password = '',
  Duration timeout = const Duration(seconds: 4),
}) async {
  final uri = 'rtsp://${host.contains(':') ? '[$host]' : host}:$port$path';
  var reply = await _send(host, port, uri, null, 1, timeout);
  if (reply == null || reply.status != 401 || user.isEmpty && password.isEmpty) return reply;
  final challenge = reply.headers['www-authenticate'];
  if (challenge == null) return reply;
  final auth = authorizationFor(challenge: challenge, method: 'DESCRIBE', uri: uri, user: user, password: password);
  if (auth == null) return reply;
  reply = await _send(host, port, uri, auth, 2, timeout);
  return reply;
}

Future<RtspReply?> _send(String host, int port, String uri, String? auth, int cseq, Duration timeout) async {
  Socket? s;
  try {
    s = await Socket.connect(host, port, timeout: timeout);
    final req = StringBuffer()
      ..write('DESCRIBE $uri RTSP/1.0\r\n')
      ..write('CSeq: $cseq\r\n')
      ..write('Accept: application/sdp\r\n')
      ..write('User-Agent: HomeGuard\r\n');
    if (auth != null) req.write('Authorization: $auth\r\n');
    req.write('\r\n');
    s.add(ascii.encode(req.toString()));
    await s.flush();
    final buf = BytesBuilder();
    final done = Completer<void>();
    late StreamSubscription<List<int>> sub;
    sub = s.listen(
      (data) {
        buf.add(data);
        final text = latin1.decode(buf.toBytes());
        final end = text.indexOf('\r\n\r\n');
        if (end >= 0) {
          final len = int.tryParse(
                  RegExp(r'content-length:\s*(\d+)', caseSensitive: false).firstMatch(text.substring(0, end))?.group(1) ??
                      '0') ??
              0;
          if (text.length >= end + 4 + len && !done.isCompleted) done.complete();
        }
      },
      onDone: () => done.isCompleted ? null : done.complete(),
      onError: (_) => done.isCompleted ? null : done.complete(),
    );
    await done.future.timeout(timeout, onTimeout: () {});
    await sub.cancel();
    return parseRtspReply(latin1.decode(buf.toBytes()));
  } catch (_) {
    return null;
  } finally {
    s?.destroy();
  }
}
