import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import 'secure_http.dart';

class OnvifException implements Exception {
  OnvifException(this.message);
  final String message;
  @override
  String toString() => message;
}

class OnvifProfile {
  OnvifProfile(this.token, this.name, this.width, this.height);
  final String token;
  final String name;
  final int? width;
  final int? height;
  String get label => width != null ? '$name (${width}x$height)' : name;
}

class DiscoveredDevice {
  DiscoveredDevice(this.xaddr, this.name);
  final Uri xaddr;
  final String name;
}

const _wsse = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd';
const _wsu = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd';
const _digestType =
    'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest';
const _b64Type = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-soap-message-security-1.0#Base64Binary';

/// WS-Security UsernameToken digest: Base64(SHA1(nonce + created + password)).
/// The plain password never leaves the device.
String passwordDigest(List<int> nonce, String created, String password) {
  final bytes = <int>[...nonce, ...utf8.encode(created), ...utf8.encode(password)];
  return base64.encode(sha1.convert(bytes).bytes);
}

String _isoUtc(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year}-${two(u.month)}-${two(u.day)}T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
}

String securityHeader(String user, String password, {DateTime? now, List<int>? nonce}) {
  final n = nonce ?? List<int>.generate(16, (_) => Random.secure().nextInt(256));
  final created = _isoUtc(now ?? DateTime.now());
  final digest = passwordDigest(n, created, password);
  return '<Security s:mustUnderstand="1" xmlns="$_wsse"><UsernameToken>'
      '<Username>${_esc(user)}</Username>'
      '<Password Type="$_digestType">$digest</Password>'
      '<Nonce EncodingType="$_b64Type">${base64.encode(n)}</Nonce>'
      '<Created xmlns="$_wsu">$created</Created>'
      '</UsernameToken></Security>';
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String envelope(String body, {String header = ''}) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">'
    '<s:Header>$header</s:Header><s:Body>$body</s:Body></s:Envelope>';

Iterable<XmlElement> byLocal(XmlNode root, String local) =>
    root.descendants.whereType<XmlElement>().where((e) => e.name.local == local);

String? firstText(XmlNode root, String local) {
  final it = byLocal(root, local);
  return it.isEmpty ? null : it.first.innerText.trim();
}

/// Parses the profiles out of a GetProfiles response.
List<OnvifProfile> parseProfiles(String xml) {
  final doc = XmlDocument.parse(xml);
  return byLocal(doc, 'Profiles').map((p) {
    final res = byLocal(p, 'Resolution');
    int? w, h;
    if (res.isNotEmpty) {
      w = int.tryParse(firstText(res.first, 'Width') ?? '');
      h = int.tryParse(firstText(res.first, 'Height') ?? '');
    }
    return OnvifProfile(
      p.getAttribute('token') ?? '',
      firstText(p, 'Name') ?? (p.getAttribute('token') ?? 'Profile'),
      w,
      h,
    );
  }).where((p) => p.token.isNotEmpty).toList();
}

/// Parses MediaUri/Uri from a GetStreamUri response.
String? parseStreamUri(String xml) {
  final doc = XmlDocument.parse(xml);
  final media = byLocal(doc, 'MediaUri');
  if (media.isEmpty) return null;
  return firstText(media.first, 'Uri');
}

String? parseMediaXAddr(String xml) {
  final doc = XmlDocument.parse(xml);
  final media = byLocal(doc, 'Media');
  for (final m in media) {
    final x = firstText(m, 'XAddr');
    if (x != null && x.isNotEmpty) return x;
  }
  return null;
}

DateTime? parseDeviceUtc(String xml) {
  final doc = XmlDocument.parse(xml);
  final utc = byLocal(doc, 'UTCDateTime');
  if (utc.isEmpty) return null;
  int g(String n) => int.tryParse(firstText(utc.first, n) ?? '') ?? 0;
  return DateTime.utc(g('Year'), g('Month'), g('Day'), g('Hour'), g('Minute'), g('Second'));
}

String _faultReason(String xml) {
  try {
    final doc = XmlDocument.parse(xml);
    return firstText(doc, 'Text') ?? firstText(doc, 'faultstring') ?? 'SOAP fault';
  } catch (_) {
    return 'unexpected reply';
  }
}

/// Minimal ONVIF Profile S client: finds the media service and returns RTSP
/// stream URIs. Uses digest authentication and corrects for camera clock skew.
class OnvifClient {
  OnvifClient({
    required this.deviceUri,
    required this.username,
    required this.password,
    this.pinnedSha256,
    this.trustOnFirstUse = false,
  });

  final Uri deviceUri;
  final String username;
  final String password;
  final String? pinnedSha256;
  final bool trustOnFirstUse;

  Duration _clockOffset = Duration.zero;

  /// Fingerprint of the certificate seen on the last HTTPS call.
  String? lastFingerprint;

  SecureHttp get _http => SecureHttp(pinnedSha256: pinnedSha256, trustOnFirstUse: trustOnFirstUse);

  Future<String> _call(Uri uri, String body, {bool auth = true}) async {
    final header = auth && username.isNotEmpty
        ? securityHeader(username, password, now: DateTime.now().add(_clockOffset))
        : '';
    final res = await _http.post(
      uri,
      utf8.encode(envelope(body, header: header)),
      headers: {'Content-Type': 'application/soap+xml; charset=utf-8'},
    );
    lastFingerprint = res.fingerprint ?? lastFingerprint;
    final text = utf8.decode(res.body, allowMalformed: true);
    if (res.status == 401 || res.status == 403) {
      throw OnvifException('The camera rejected the user name or password.');
    }
    if (res.status != 200) {
      throw OnvifException('Camera error ${res.status}: ${_faultReason(text)}');
    }
    return text;
  }

  Future<void> syncClock() async {
    try {
      final xml = await _call(
        deviceUri,
        '<GetSystemDateAndTime xmlns="http://www.onvif.org/ver10/device/wsdl"/>',
        auth: false,
      );
      final dev = parseDeviceUtc(xml);
      if (dev != null && dev.year > 2000) {
        _clockOffset = dev.difference(DateTime.now().toUtc());
      }
    } on CertificatePinMismatch {
      rethrow;
    } catch (_) {
      // Some cameras require auth even here; continue with local time.
    }
  }

  Future<Uri> mediaService() async {
    final xml = await _call(
      deviceUri,
      '<GetCapabilities xmlns="http://www.onvif.org/ver10/device/wsdl"><Category>Media</Category></GetCapabilities>',
    );
    final x = parseMediaXAddr(xml);
    if (x == null) throw OnvifException('This camera does not offer an ONVIF media service.');
    final reported = Uri.parse(x);
    // Cameras often report an internal address; keep the scheme/host/port we
    // reached them on and use only the reported path.
    return deviceUri.replace(path: reported.path.isEmpty ? '/onvif/media_service' : reported.path);
  }

  Future<List<OnvifProfile>> profiles(Uri media) async {
    final xml = await _call(media, '<GetProfiles xmlns="http://www.onvif.org/ver10/media/wsdl"/>');
    final list = parseProfiles(xml);
    if (list.isEmpty) throw OnvifException('The camera reported no video profiles.');
    return list;
  }

  Future<String> streamUri(Uri media, String profileToken) async {
    final xml = await _call(
      media,
      '<GetStreamUri xmlns="http://www.onvif.org/ver10/media/wsdl">'
      '<StreamSetup><Stream xmlns="http://www.onvif.org/ver10/schema">RTP-Unicast</Stream>'
      '<Transport xmlns="http://www.onvif.org/ver10/schema"><Protocol>RTSP</Protocol></Transport></StreamSetup>'
      '<ProfileToken>${_esc(profileToken)}</ProfileToken></GetStreamUri>',
    );
    final uri = parseStreamUri(xml);
    if (uri == null || uri.isEmpty) throw OnvifException('The camera returned no stream address.');
    // Strip any credentials the camera echoed back; they are stored securely.
    final u = Uri.parse(uri);
    return u.userInfo.isEmpty ? uri : uri.replaceFirst('${u.userInfo}@', '');
  }
}

/// WS-Discovery probe for ONVIF cameras on the local network.
Future<List<DiscoveredDevice>> discoverOnvif({Duration wait = const Duration(seconds: 3)}) async {
  final msgId = 'uuid:${List.generate(16, (_) => Random().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  final probe = '<?xml version="1.0" encoding="UTF-8"?>'
      '<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" '
      'xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
      'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" '
      'xmlns:dn="http://www.onvif.org/ver10/network/wsdl">'
      '<e:Header><w:MessageID>$msgId</w:MessageID>'
      '<w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>'
      '<w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>'
      '</e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>';

  final found = <String, DiscoveredDevice>{};
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  socket.broadcastEnabled = true;
  final done = Completer<void>();
  final sub = socket.listen((ev) {
    if (ev != RawSocketEvent.read) return;
    final dg = socket.receive();
    if (dg == null) return;
    try {
      final doc = XmlDocument.parse(utf8.decode(dg.data, allowMalformed: true));
      final xaddrs = (firstText(doc, 'XAddrs') ?? '').split(RegExp(r'\s+'));
      final scopes = (firstText(doc, 'Scopes') ?? '').split(RegExp(r'\s+'));
      var name = dg.address.address;
      for (final s in scopes) {
        const marker = 'onvif://www.onvif.org/name/';
        if (s.startsWith(marker)) name = Uri.decodeComponent(s.substring(marker.length));
      }
      for (final x in xaddrs) {
        final u = Uri.tryParse(x);
        // Prefer an IPv4 address that matches the sender.
        if (u != null && u.host.isNotEmpty && !u.host.contains(':')) {
          found[u.host] = DiscoveredDevice(u, name);
          break;
        }
      }
    } catch (_) {/* ignore non-ONVIF replies */}
  });
  final data = utf8.encode(probe);
  for (var i = 0; i < 2; i++) {
    socket.send(data, InternetAddress('239.255.255.250'), 3702);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  Timer(wait, () => done.complete());
  await done.future;
  await sub.cancel();
  socket.close();
  return found.values.toList();
}
