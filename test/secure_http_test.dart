import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_guard/services/secure_http.dart';

// Self-signed test certificate in fixtures/ (test-only key, never shipped).
const fixtureSha256 = 'ba52f1c7600442c1f9e499e407f9eebab233adf264a64ce49dde6d1aab4ecf35';

void main() {
  late HttpServer server;
  late Uri uri;

  setUpAll(() async {
    final ctx = SecurityContext()
      ..useCertificateChain('test/fixtures/cert.pem')
      ..usePrivateKey('test/fixtures/key.pem');
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
    server.listen((r) {
      r.response.write(r.headers.value('x-api-key') == 'k1' ? 'jpeg' : 'denied');
      r.response.close();
    });
    uri = Uri.parse('https://127.0.0.1:${server.port}/snap.jpg');
  });

  tearDownAll(() => server.close(force: true));

  test('untrusted self-signed certificate is rejected by default', () async {
    expect(SecureHttp().get(uri), throwsA(isA<HandshakeException>()));
  });

  test('trust-on-first-use reports the fingerprint', () async {
    final r = await SecureHttp(trustOnFirstUse: true).get(uri);
    expect(r.fingerprint, fixtureSha256);
  });

  test('pinned certificate is accepted and headers are sent', () async {
    final r = await SecureHttp(pinnedSha256: fixtureSha256).get(uri, headers: {'X-API-Key': 'k1'});
    expect(r.status, 200);
    expect(String.fromCharCodes(r.body), 'jpeg');
  });

  test('a different pin blocks the connection', () async {
    final wrong = '00' * 32;
    expect(
      SecureHttp(pinnedSha256: wrong).get(uri),
      throwsA(anyOf(isA<HandshakeException>(), isA<CertificatePinMismatch>())),
    );
  });

  test('fingerprint formatting', () {
    expect(formatFingerprint('ab01ff'), 'AB:01:FF');
  });
}
