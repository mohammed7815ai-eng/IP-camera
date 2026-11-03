import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_guard/services/onvif.dart';

const profilesXml = '''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema">
<s:Body><trt:GetProfilesResponse>
<trt:Profiles token="main" fixed="true"><tt:Name>MainStream</tt:Name>
<tt:VideoEncoderConfiguration token="v1"><tt:Name>v</tt:Name><tt:Resolution><tt:Width>2560</tt:Width><tt:Height>1440</tt:Height></tt:Resolution></tt:VideoEncoderConfiguration></trt:Profiles>
<trt:Profiles token="sub"><tt:Name>SubStream</tt:Name></trt:Profiles>
</trt:GetProfilesResponse></s:Body></s:Envelope>''';

const streamXml = '''<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema">
<s:Body><trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>rtsp://admin:leak@192.168.1.20:554/Streaming/Channels/101</tt:Uri></trt:MediaUri></trt:GetStreamUriResponse></s:Body></s:Envelope>''';

const capsXml = '''<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema">
<s:Body><tds:GetCapabilitiesResponse><tds:Capabilities><tt:Media><tt:XAddr>http://10.9.9.9/onvif/Media</tt:XAddr></tt:Media></tds:Capabilities></tds:GetCapabilitiesResponse></s:Body></s:Envelope>''';

const timeXml = '''<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tt="http://www.onvif.org/ver10/schema"><s:Body><GetSystemDateAndTimeResponse><SystemDateAndTime><tt:UTCDateTime><tt:Time><tt:Hour>6</tt:Hour><tt:Minute>0</tt:Minute><tt:Second>0</tt:Second></tt:Time><tt:Date><tt:Year>2026</tt:Year><tt:Month>11</tt:Month><tt:Day>3</tt:Day></tt:Date></tt:UTCDateTime></SystemDateAndTime></GetSystemDateAndTimeResponse></s:Body></s:Envelope>''';

void main() {
  test('password digest matches WS-Security definition', () {
    // Reference value computed independently: base64(sha1(nonce + created + password)).
    final d = passwordDigest(List<int>.generate(16, (i) => i), '2026-11-03T06:00:00Z', 's3cr3t!');
    expect(d, 'hBbK9JOAzH5dmOrQdRxM9HoGAFk=');
  });

  test('security header never contains the plain password', () {
    final h = securityHeader('admin', 'p@ss<word>', now: DateTime.utc(2026, 11, 3));
    expect(h, isNot(contains('p@ss')));
    expect(h, contains('<Username>admin</Username>'));
    expect(h, contains('2026-11-03T00:00:00Z'));
  });

  test('parses profiles with resolution', () {
    final p = parseProfiles(profilesXml);
    expect(p.map((e) => e.token), ['main', 'sub']);
    expect(p.first.label, 'MainStream (2560x1440)');
    expect(p.last.width, isNull);
  });

  test('parses stream uri, media xaddr and device time', () {
    expect(parseStreamUri(streamXml), 'rtsp://admin:leak@192.168.1.20:554/Streaming/Channels/101');
    expect(parseMediaXAddr(capsXml), 'http://10.9.9.9/onvif/Media');
    expect(parseDeviceUtc(timeXml), DateTime.utc(2026, 11, 3, 6));
  });

  test('full ONVIF flow against a simulated camera', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seenAuth = <bool>[];
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      seenAuth.add(body.contains('PasswordDigest'));
      String reply;
      if (body.contains('GetSystemDateAndTime')) {
        reply = timeXml;
      } else if (!body.contains('<Username>admin</Username>')) {
        req.response.statusCode = 400;
        reply = '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><s:Fault><s:Reason><s:Text>NotAuthorized</s:Text></s:Reason></s:Fault></s:Body></s:Envelope>';
      } else if (body.contains('GetCapabilities')) {
        reply = capsXml;
      } else if (body.contains('GetProfiles')) {
        reply = profilesXml;
      } else {
        expect(req.uri.path, '/onvif/Media');
        reply = streamXml;
      }
      req.response.headers.contentType = ContentType('application', 'soap+xml');
      req.response.write(reply);
      await req.response.close();
    });

    final client = OnvifClient(
      deviceUri: Uri.parse('http://127.0.0.1:${server.port}/onvif/device_service'),
      username: 'admin',
      password: 'secret',
    );
    await client.syncClock();
    final media = await client.mediaService();
    // Uses the address we reached the camera on, not the internal one it reports.
    expect(media.host, '127.0.0.1');
    expect(media.path, '/onvif/Media');
    final profiles = await client.profiles(media);
    final uri = await client.streamUri(media, profiles.first.token);
    // Echoed credentials are stripped.
    expect(uri, 'rtsp://192.168.1.20:554/Streaming/Channels/101');
    expect(seenAuth.first, isFalse); // time request is unauthenticated
    expect(seenAuth.skip(1).every((a) => a), isTrue);

    final bad = OnvifClient(deviceUri: client.deviceUri, username: 'eve', password: 'x');
    expect(bad.mediaService(), throwsA(isA<OnvifException>()));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await server.close(force: true);
  });
}
