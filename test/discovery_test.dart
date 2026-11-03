import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_guard/discovery/camera_agent.dart';
import 'package:home_guard/discovery/net_scan.dart';
import 'package:home_guard/discovery/rtsp_probe.dart';
import 'package:home_guard/models/camera.dart';
import 'package:home_guard/services/onvif.dart';
import 'package:home_guard/services/stream_url.dart';

String _md5(String s) => md5.convert(utf8.encode(s)).toString();

/// A tiny fake RTSP camera. [validPath] answers 200 with an SDP; other paths
/// 404. With [digest], requests need a correct Digest login first.
Future<ServerSocket> fakeRtspCamera({
  required int port,
  required String validPath,
  String user = 'admin',
  String password = '12345678',
  bool digest = true,
  List<String>? seen,
}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port, shared: true);
  const realm = 'IP Camera';
  const nonce = 'abc123';
  server.listen((sock) {
    final buf = StringBuffer();
    sock.listen((data) {
      buf.write(latin1.decode(data));
      final text = buf.toString();
      if (!text.contains('\r\n\r\n')) return;
      final lines = text.split('\r\n');
      final uri = lines.first.split(' ')[1];
      final path = uri.substring(uri.indexOf('/', 'rtsp://'.length));
      seen?.add(path);
      final cseq = lines.firstWhere((l) => l.startsWith('CSeq')).split(':')[1].trim();
      final authLine = lines.firstWhere((l) => l.startsWith('Authorization:'), orElse: () => '');
      var authed = !digest;
      if (digest && authLine.isNotEmpty) {
        final resp = RegExp(r'response="([0-9a-f]+)"').firstMatch(authLine)?.group(1);
        final expect = _md5('${_md5('$user:$realm:$password')}:$nonce:${_md5('DESCRIBE:$uri')}');
        authed = resp == expect;
      }
      String reply;
      if (!authed) {
        reply = 'RTSP/1.0 401 Unauthorized\r\nCSeq: $cseq\r\nWWW-Authenticate: Basic realm="$realm"\r\n'
            'WWW-Authenticate: Digest realm="$realm", nonce="$nonce"\r\n\r\n';
      } else if (Uri.decodeFull(path) == validPath) {
        const sdp = 'v=0\r\nm=video 0 RTP/AVP 96\r\n';
        reply = 'RTSP/1.0 200 OK\r\nCSeq: $cseq\r\nContent-Type: application/sdp\r\nContent-Length: ${sdp.length}\r\n\r\n$sdp';
      } else {
        reply = 'RTSP/1.0 404 Not Found\r\nCSeq: $cseq\r\n\r\n';
      }
      sock.add(latin1.encode(reply));
      sock.close();
    }, onError: (_) {});
  });
  return server;
}

void main() {
  test('digest answer matches RFC 2617 example', () {
    // RFC 2617 section 3.5 example values, method GET.
    final h = authorizationFor(
      challenge: 'Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", '
          'opaque="5ccc069c403ebaf9f0171e9517f40e41"',
      method: 'GET',
      uri: '/dir/index.html',
      user: 'Mufasa',
      password: 'Circle Of Life',
      cnonce: '0a4f113b',
    )!;
    expect(h, contains('response="6629fae49393a05397450978507c4ef1"'));
    expect(h, contains('qop=auth'));
    expect(h, contains('opaque="5ccc069c403ebaf9f0171e9517f40e41"'));
  });

  test('basic challenge', () {
    expect(authorizationFor(challenge: 'Basic realm="x"', method: 'DESCRIBE', uri: 'u', user: 'a', password: 'b'),
        'Basic ${base64.encode(utf8.encode('a:b'))}');
  });

  test('parse RTSP reply prefers the Digest challenge', () {
    final r = parseRtspReply('RTSP/1.0 401 Unauthorized\r\nCSeq: 1\r\nWWW-Authenticate: Basic realm="a"\r\n'
        'WWW-Authenticate: Digest realm="a", nonce="n"\r\n\r\n')!;
    expect(r.status, 401);
    expect(r.headers['www-authenticate'], startsWith('Digest'));
    expect(parseRtspReply('HTTP/1.1 200 OK\r\n\r\n'), isNull);
  });

  test('credential template is filled at play time and redacted in logs', () {
    final c = Camera(
      id: '1',
      name: 'x',
      kind: CameraKind.rtsp,
      host: '192.168.1.9',
      path: '/user={user}&password={password}&channel=1&stream=0.sdp',
      username: 'admin',
      useTls: false,
    );
    final url = buildStreamUrl(c, password: 'p&ss');
    expect(url, 'rtsp://admin:p%26ss@192.168.1.9:554/user=admin&password=p%26ss&channel=1&stream=0.sdp');
    expect(redact(url), isNot(contains('p%26ss')));
    expect(redact('rtsp://admin:secret@10.0.0.3/h264'), 'rtsp://admin:••••@10.0.0.3/h264');
    expect(redact('error at rtsp://10.0.0.3/user=admin&password=hunter2&channel=1'), isNot(contains('hunter2')));
  });

  test('brand guesses and path order', () {
    expect(guessBrand({554, 34567}), 'XMEye / iCSee');
    expect(guessBrand({554, 80}, web: 'Server: App-webs/'), 'Hikvision');
    expect(guessBrand({554, 2020}), 'TP-Link Tapo');
    expect(guessBrand({554}, onvif: 'IPC-HFW1230S Dahua'), 'Dahua');
    expect(guessBrand({554}), 'Unknown brand');
    expect(candidatePaths('Reolink').first, '/h264Preview_01_main');
    final all = candidatePaths('Unknown brand');
    expect(all.toSet().length, all.length);
    expect(all, contains('/onvif1'));
    expect(looksLikeCamera({80, 443}), isFalse);
    expect(looksLikeCamera({80, 554}), isTrue);
  });

  test('private networks and /24 hosts', () {
    expect(isPrivateIpv4('192.168.1.5'), isTrue);
    expect(isPrivateIpv4('172.20.0.1'), isTrue);
    expect(isPrivateIpv4('8.8.8.8'), isFalse);
    final h = hostsOf('192.168.1.5');
    expect(h.length, 253);
    expect(h, isNot(contains('192.168.1.5')));
    expect(h.first, '192.168.1.1');
  });

  test('WS-Discovery match uses the sender address and reads the model', () {
    const xml = '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"><s:Body><d:ProbeMatches><d:ProbeMatch>'
        '<d:Scopes>onvif://www.onvif.org/name/IPCAM onvif://www.onvif.org/hardware/HI3518E</d:Scopes>'
        '<d:XAddrs>http://10.0.0.99:8899/onvif/device_service http://192.168.1.40:8899/onvif/device_service</d:XAddrs>'
        '</d:ProbeMatch></d:ProbeMatches></s:Body></s:Envelope>';
    final d = parseProbeMatch(xml, '192.168.1.40')!;
    expect(d.xaddr.toString(), 'http://192.168.1.40:8899/onvif/device_service');
    expect(d.name, 'IPCAM');
    expect(d.hardware, 'HI3518E');
    // Stale address only: trust the sender.
    final stale = parseProbeMatch(xml.replaceAll('http://192.168.1.40:8899/onvif/device_service', ''), '192.168.1.41')!;
    expect(stale.xaddr.host, '192.168.1.41');
    expect(stale.xaddr.port, 8899);
    expect(parseProbeMatch('<a/>', '1.2.3.4'), isNull);
  });

  test('port scan finds an open port on this machine', () async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final open = await scanPorts(['127.0.0.1'], [s.port, 1], parallel: 4);
    expect(open['127.0.0.1'], {s.port});
    await s.close();
  });

  test('RTSP DESCRIBE with digest login', () async {
    final cam = await fakeRtspCamera(port: 0, validPath: '/Streaming/Channels/101');
    final ok = await rtspDescribe('127.0.0.1', cam.port, '/Streaming/Channels/101', user: 'admin', password: '12345678');
    expect(ok!.status, 200);
    expect(ok.hasVideo, isTrue);
    final bad = await rtspDescribe('127.0.0.1', cam.port, '/Streaming/Channels/101', user: 'admin', password: 'wrong');
    expect(bad!.status, 401);
    final missing = await rtspDescribe('127.0.0.1', cam.port, '/nope', user: 'admin', password: '12345678');
    expect(missing!.status, 404);
    expect(await rtspDescribe('127.0.0.1', 1, '/x', timeout: const Duration(milliseconds: 300)), isNull);
    await cam.close();
  });

  test('agent sets up an iCSee-style camera end to end', () async {
    final seen = <String>[];
    final cam = await fakeRtspCamera(
      port: 8554,
      validPath: '/user=admin&password=12345678&channel=1&stream=0.sdp',
      digest: false,
      seen: seen,
    );
    final agent = CameraSetupAgent();
    final d = FoundDevice('127.0.0.1')
      ..ports = {8554, 34567}
      ..user = 'admin'
      ..password = '12345678';
    await agent.probe(d);
    expect(d.brand, 'XMEye / iCSee');
    expect(d.status, DeviceStatus.ready);
    expect(seen.length, 1, reason: 'brand-specific path tried first');
    final c = d.camera!;
    expect(c.kind, CameraKind.rtsp);
    expect(c.port, 8554);
    expect(c.path, contains('{password}'), reason: 'password never stored in settings');
    expect(buildStreamUrl(c, password: '12345678'), contains('password=12345678'));
    await cam.close();
  });

  test('agent reports a wrong password instead of guessing', () async {
    final cam = await fakeRtspCamera(port: 8554, validPath: '/Streaming/Channels/101');
    final d = FoundDevice('127.0.0.1')
      ..ports = {8554, 8000}
      ..user = 'admin'
      ..password = 'wrong';
    await CameraSetupAgent().probe(d);
    expect(d.brand, 'Hikvision');
    expect(d.status, DeviceStatus.needsPassword);
    d.password = '12345678';
    await CameraSetupAgent().probe(d);
    expect(d.status, DeviceStatus.ready);
    expect(d.camera!.path, '/Streaming/Channels/101');
    await cam.close();
  });

  test('agent finds an ONVIF camera via its SOAP endpoint', () async {
    // Fake ONVIF device service answering every call.
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      String out;
      if (body.contains('GetSystemDateAndTime')) {
        out = '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><GetSystemDateAndTimeResponse>'
            '<SystemDateAndTime/></GetSystemDateAndTimeResponse></s:Body></s:Envelope>';
      } else if (body.contains('GetCapabilities')) {
        out = '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><Capabilities><Media>'
            '<XAddr>http://10.1.1.1/onvif/media</XAddr></Media></Capabilities></s:Body></s:Envelope>';
      } else if (body.contains('GetProfiles')) {
        out = '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><GetProfilesResponse>'
            '<Profiles token="p0"><Name>main</Name></Profiles></GetProfilesResponse></s:Body></s:Envelope>';
      } else {
        out = '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><GetStreamUriResponse><MediaUri>'
            '<Uri>rtsp://127.0.0.1:554/onvif1</Uri></MediaUri></GetStreamUriResponse></s:Body></s:Envelope>';
      }
      req.response
        ..headers.contentType = ContentType('application', 'soap+xml')
        ..write(out);
      await req.response.close();
    });
    final device = Uri.parse('http://127.0.0.1:${http.port}/onvif/device_service');
    expect(await CameraSetupAgent.isOnvifEndpoint(device), isTrue);
    final d = FoundDevice('127.0.0.1')
      ..ports = {http.port}
      ..onvifUri = device
      ..onvifName = 'Garden';
    await CameraSetupAgent().probe(d);
    expect(d.status, DeviceStatus.ready);
    expect(d.camera!.kind, CameraKind.onvif);
    expect(d.camera!.resolvedStreamUri, 'rtsp://127.0.0.1:554/onvif1');
    expect(d.camera!.name, 'Garden');
    expect(d.camera!.port, http.port);
    await http.close(force: true);
  });
}
