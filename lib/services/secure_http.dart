import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Raised when a camera presents a different TLS certificate from the one
/// pinned when it was added. Could mean a man-in-the-middle, or a camera
/// that was reset or re-keyed.
class CertificatePinMismatch implements Exception {
  CertificatePinMismatch(this.expected, this.actual);
  final String expected;
  final String actual;
  @override
  String toString() =>
      'The camera certificate changed (expected ${short(expected)}, got ${short(actual)}). '
      'Connection blocked. If you reset the camera, edit it and trust the new certificate.';
}

String sha256Hex(List<int> der) => sha256.convert(der).toString();

/// Formats a hex fingerprint as `AB:CD:…` for people to compare.
String formatFingerprint(String hex) {
  final up = hex.toUpperCase();
  final parts = <String>[];
  for (var i = 0; i < up.length; i += 2) {
    parts.add(up.substring(i, i + 2 > up.length ? up.length : i + 2));
  }
  return parts.join(':');
}

String short(String hex) => formatFingerprint(hex.substring(0, hex.length < 16 ? hex.length : 16));

class HttpResult {
  HttpResult(this.status, this.body, this.fingerprint);
  final int status;
  final Uint8List body;

  /// SHA-256 of the server certificate, or null for plain HTTP.
  final String? fingerprint;
}

/// HTTP(S) client with certificate pinning.
///
/// * [pinnedSha256] null and [trustOnFirstUse] true: any certificate is
///   accepted once so its fingerprint can be shown to the user (setup only).
/// * [pinnedSha256] set: only that exact certificate is accepted, whether or
///   not it is signed by a public CA. Self-signed camera certificates work.
/// * Neither: normal system CA validation.
class SecureHttp {
  SecureHttp({this.pinnedSha256, this.trustOnFirstUse = false, this.timeout = const Duration(seconds: 8)});

  final String? pinnedSha256;
  final bool trustOnFirstUse;
  final Duration timeout;

  HttpClient _client() {
    final c = HttpClient()
      ..connectionTimeout = timeout
      ..userAgent = 'HomeGuard/1.0';
    c.badCertificateCallback = (X509Certificate cert, String host, int port) {
      if (trustOnFirstUse && pinnedSha256 == null) return true;
      final pin = pinnedSha256;
      return pin != null && sha256Hex(cert.der) == pin.toLowerCase();
    };
    return c;
  }

  Future<HttpResult> request(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    final client = _client();
    try {
      final req = await client.openUrl(method, uri).timeout(timeout);
      headers.forEach(req.headers.set);
      if (body != null) {
        req.contentLength = body.length;
        req.add(body);
      }
      final resp = await req.close().timeout(timeout);
      String? fp;
      final cert = resp.certificate;
      if (cert != null) {
        fp = sha256Hex(cert.der);
        final pin = pinnedSha256;
        if (pin != null && fp != pin.toLowerCase()) {
          // Drain so the socket closes cleanly, then refuse.
          await resp.drain<void>();
          throw CertificatePinMismatch(pin, fp);
        }
      }
      final bytes = await resp
          .fold<BytesBuilder>(BytesBuilder(copy: false), (b, d) => b..add(d))
          .timeout(timeout);
      return HttpResult(resp.statusCode, bytes.takeBytes(), fp);
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpResult> get(Uri uri, {Map<String, String> headers = const {}}) =>
      request('GET', uri, headers: headers);

  Future<HttpResult> post(Uri uri, List<int> body, {Map<String, String> headers = const {}}) =>
      request('POST', uri, headers: headers, body: body);
}
