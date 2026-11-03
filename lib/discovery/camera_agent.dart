import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../models/camera.dart';
import '../services/onvif.dart';
import '../services/stream_url.dart';
import 'net_scan.dart';
import 'rtsp_probe.dart';

enum DeviceStatus { checking, ready, needsPassword, noStream, added }

/// One device the agent found on the network.
class FoundDevice {
  FoundDevice(this.ip);
  final String ip;
  Set<int> ports = {};
  String brand = 'Unknown brand';
  String? onvifName;
  String? model;
  Uri? onvifUri;
  DeviceStatus status = DeviceStatus.checking;
  String detail = 'Checking…';

  /// Ready-to-save camera when [status] is [DeviceStatus.ready].
  Camera? camera;
  String user = 'admin';
  String password = '';

  String get title => onvifName != null && onvifName != ip ? '$onvifName ($ip)' : '$brand camera ($ip)';
}

/// Stream paths to try, best guess first, by brand. `{user}` and `{password}`
/// are filled in only while probing and when the stream is opened.
const brandPaths = <String, List<String>>{
  'Hikvision': ['/Streaming/Channels/101', '/Streaming/Channels/102', '/h264/ch1/main/av_stream'],
  'Dahua': ['/cam/realmonitor?channel=1&subtype=0', '/cam/realmonitor?channel=1&subtype=1'],
  'Reolink': ['/h264Preview_01_main', '/Preview_01_main', '/h264Preview_01_sub'],
  'TP-Link Tapo': ['/stream1', '/stream2'],
  'XMEye / iCSee': [
    '/user={user}&password={password}&channel=1&stream=0.sdp',
    '/user={user}_password={password}_channel=1_stream=0.sdp?real_stream',
  ],
  'Yoosee': ['/onvif1', '/onvif2'],
  'V380': ['/live/ch00_0', '/live/ch00_1'],
  'CamHi': ['/11', '/12'],
  'Uniview': ['/unicast/c1/s0/live', '/media/video1'],
  'Axis': ['/axis-media/media.amp'],
};

const genericPaths = ['/live', '/live/ch0', '/live/main', '/h264', '/stream0', '/ch0_0.h264', '/av0_0', '/0', '/1', '/'];

/// Paths for [brand] first, then every other known path once.
List<String> candidatePaths(String brand) {
  final out = <String>[...?brandPaths[brand]];
  for (final list in brandPaths.values) {
    for (final p in list) {
      if (!out.contains(p)) out.add(p);
    }
  }
  for (final p in genericPaths) {
    if (!out.contains(p)) out.add(p);
  }
  return out;
}

/// Guesses the maker from open ports, the web server banner and ONVIF scopes.
String guessBrand(Set<int> ports, {String web = '', String onvif = ''}) {
  final t = '$web $onvif'.toLowerCase();
  if (t.contains('hikvision') || t.contains('dnvrs-webs') || t.contains('app-webs') || t.contains('hiklook')) return 'Hikvision';
  if (t.contains('dahua') || t.contains('dhweb') || t.contains('amcrest') || t.contains('imou')) return 'Dahua';
  if (t.contains('reolink')) return 'Reolink';
  if (t.contains('tapo') || t.contains('tp-link')) return 'TP-Link Tapo';
  if (t.contains('netsurveillance') || t.contains('xmeye') || t.contains('icsee') || t.contains('xiongmai')) return 'XMEye / iCSee';
  if (t.contains('yoosee') || t.contains('gwell')) return 'Yoosee';
  if (t.contains('v380') || t.contains('macro-video')) return 'V380';
  if (t.contains('hipcam') || t.contains('camhi') || t.contains('hi3510')) return 'CamHi';
  if (t.contains('uniview') || t.contains('unv')) return 'Uniview';
  if (t.contains('axis')) return 'Axis';
  if (ports.contains(34567)) return 'XMEye / iCSee';
  if (ports.contains(37777)) return 'Dahua';
  if (ports.contains(9000)) return 'Reolink';
  if (ports.contains(2020)) return 'TP-Link Tapo';
  if (ports.contains(8000)) return 'Hikvision';
  if (ports.contains(5000) && ports.contains(554)) return 'Yoosee';
  return 'Unknown brand';
}

/// Open ports that mean "probably a camera or recorder". A host with only a
/// web page (router, printer, TV) is not probed further.
bool looksLikeCamera(Set<int> ports) =>
    ports.any((p) => rtspPorts.contains(p) || const [34567, 37777, 8899, 2020, 6688, 9000].contains(p));

/// Automatic camera setup: finds cameras on the home network, works out how
/// to talk to each one (ONVIF, or RTSP with the right stream path), checks the
/// login, and hands back cameras that are ready to save.
///
/// Everything stays on the local network: only private addresses of this
/// device's own networks are scanned, and passwords are only sent to the
/// cameras found there, digest-hashed where the camera supports it.
class CameraSetupAgent extends ChangeNotifier {
  final devices = <String, FoundDevice>{};
  final log = <String>[];
  bool running = false;
  double progress = 0;
  String phase = '';
  bool _cancel = false;

  static const _net = MethodChannel('home_guard/net');

  List<FoundDevice> get sorted {
    const order = {
      DeviceStatus.ready: 0,
      DeviceStatus.needsPassword: 1,
      DeviceStatus.checking: 2,
      DeviceStatus.noStream: 3,
      DeviceStatus.added: 4,
    };
    final l = devices.values.toList()
      ..sort((a, b) {
        final s = order[a.status]!.compareTo(order[b.status]!);
        return s != 0 ? s : _ipKey(a.ip).compareTo(_ipKey(b.ip));
      });
    return l;
  }

  static int _ipKey(String ip) => ip.split('.').fold(0, (v, p) => v * 256 + (int.tryParse(p) ?? 0));

  void _say(String m) {
    log.add(m);
    notifyListeners();
  }

  void cancel() {
    _cancel = true;
    _say('Stopping…');
  }

  Future<void> run({required String user, required String password}) async {
    if (running) return;
    running = true;
    _cancel = false;
    devices.clear();
    log.clear();
    progress = 0;
    phase = 'Finding your network';
    notifyListeners();
    try {
      final mine = await localIpv4Addresses();
      if (mine.isEmpty) {
        _say('This device is not on a home Wi-Fi or wired network. Connect to the same Wi-Fi as your cameras and try again.');
        return;
      }
      _say('This device is ${mine.join(', ')}. Scanning ${mine.map((ip) => '${subnet24(ip)}.0/24').join(' and ')}.');

      // 1. ONVIF multicast search and a port scan, side by side.
      phase = 'Searching the network';
      notifyListeners();
      await holdMulticast(true);
      final onvifFuture = discoverOnvif(localAddresses: mine).catchError((Object _) => <DiscoveredDevice>[]);
      final hosts = [for (final ip in mine) ...hostsOf(ip)];
      final open = await scanPorts(
        hosts,
        cameraPorts.keys,
        cancelled: () => _cancel,
        onProgress: (d, t) {
          progress = 0.6 * d / t;
          notifyListeners();
        },
      );
      final onvif = await onvifFuture;
      await holdMulticast(false);
      if (_cancel) return;
      _say('${open.length} device(s) answered on camera ports; ${onvif.length} answered the ONVIF search.');

      for (final d in onvif) {
        final f = devices[d.xaddr.host] ??= FoundDevice(d.xaddr.host);
        f
          ..onvifUri = d.xaddr
          ..onvifName = d.name
          ..model = d.hardware;
      }
      for (final e in open.entries) {
        if (!looksLikeCamera(e.value) && !devices.containsKey(e.key)) {
          _say('Skipped ${e.key}: ports ${e.value.join(', ')} only, not a camera.');
          continue;
        }
        (devices[e.key] ??= FoundDevice(e.key)).ports = e.value;
      }
      if (devices.isEmpty) {
        _say('No cameras found. Check the camera is powered on, has finished its Wi-Fi setup in the maker\'s app, and is on the same network as this device.');
        return;
      }
      for (final d in devices.values) {
        d
          ..user = user
          ..password = password;
      }
      notifyListeners();

      // 2. Work out each camera, a few at a time.
      phase = 'Setting up cameras';
      final queue = devices.values.toList();
      var done = 0;
      Future<void> worker() async {
        while (queue.isNotEmpty && !_cancel) {
          final d = queue.removeAt(0);
          await probe(d);
          done++;
          progress = 0.6 + 0.4 * done / devices.length;
          notifyListeners();
        }
      }

      await Future.wait([for (var i = 0; i < 4; i++) worker()]);
      final ready = devices.values.where((d) => d.status == DeviceStatus.ready).length;
      _say('Done: $ready camera(s) ready to add.');
    } catch (e) {
      _say('Search stopped: ${redact(e.toString())}');
    } finally {
      await holdMulticast(false);
      running = false;
      progress = 1;
      phase = '';
      notifyListeners();
    }
  }

  /// Tries again with another login for one camera.
  Future<void> retry(FoundDevice d, {required String user, required String password}) async {
    d
      ..user = user
      ..password = password
      ..status = DeviceStatus.checking
      ..detail = 'Checking…';
    notifyListeners();
    await probe(d);
    notifyListeners();
  }

  /// Android drops multicast replies unless the app holds a MulticastLock.
  static Future<void> holdMulticast(bool on) async {
    if (!Platform.isAndroid) return;
    try {
      await _net.invokeMethod<bool>(on ? 'acquireMulticast' : 'releaseMulticast');
    } catch (_) {/* older build without the channel */}
  }

  /// Works out how to connect to [d] and fills in [FoundDevice.camera].
  Future<void> probe(FoundDevice d) async {
    final ip = d.ip;
    if (d.ports.isEmpty) {
      d.ports = (await scanPorts([ip], cameraPorts.keys, parallel: 16))[ip] ?? {};
    }
    final web = await _webBanner(ip, d.ports);
    d.brand = guessBrand(d.ports, web: web, onvif: '${d.onvifName ?? ''} ${d.model ?? ''}');
    _say('$ip: ${d.brand}, open ports ${d.ports.isEmpty ? 'none' : d.ports.join(', ')}.');
    notifyListeners();

    var authRejected = false;

    // ONVIF first: it reports the exact stream address.
    final onvifPorts = <int>{
      if (d.onvifUri != null) d.onvifUri!.hasPort ? d.onvifUri!.port : 80,
      ...onvifPortGuesses.where(d.ports.contains),
    }.toList();
    for (final port in onvifPorts) {
      if (_cancel) return;
      final path = d.onvifUri != null && (d.onvifUri!.hasPort ? d.onvifUri!.port : 80) == port && d.onvifUri!.path.isNotEmpty
          ? d.onvifUri!.path
          : '/onvif/device_service';
      final device = Uri(scheme: 'http', host: ip, port: port, path: path);
      if (d.onvifUri == null && !await isOnvifEndpoint(device)) continue;
      d.detail = 'ONVIF found on port $port, logging in…';
      notifyListeners();
      try {
        final client = OnvifClient(deviceUri: device, username: d.user, password: d.password);
        await client.syncClock();
        final media = await client.mediaService();
        final profiles = await client.profiles(media);
        final uri = await client.streamUri(media, profiles.first.token);
        d.onvifUri = device;
        d.camera = Camera(
          id: const Uuid().v4(),
          name: d.onvifName != null && d.onvifName != ip ? d.onvifName! : '${d.brand == 'Unknown brand' ? 'Camera' : d.brand} ${ip.split('.').last}',
          kind: CameraKind.onvif,
          host: ip,
          port: port == 80 ? 0 : port,
          path: path,
          username: d.user,
          useTls: false,
          resolvedStreamUri: uri,
        );
        d.status = DeviceStatus.ready;
        d.detail = 'Ready: ONVIF, ${profiles.first.label}.';
        _say('$ip: ONVIF login worked, stream ${redact(uri)}.');
        return;
      } on OnvifException catch (e) {
        if (e.message.contains('user name or password')) authRejected = true;
        _say('$ip: ONVIF on port $port: ${e.message}');
      } catch (e) {
        _say('$ip: ONVIF on port $port failed (${redact(e.toString())}).');
      }
    }

    // RTSP: try the likely stream paths with the login.
    final rtspPort = rtspPorts.firstWhere(d.ports.contains, orElse: () => 0);
    if (rtspPort != 0) {
      d.detail = 'Trying stream paths…';
      notifyListeners();
      var rejected = 0, tried = 0;
      for (final template in candidatePaths(d.brand)) {
        if (_cancel) return;
        final path = fillCredentialTemplate(template, d.user, d.password);
        final r = await rtspDescribe(ip, rtspPort, path, user: d.user, password: d.password);
        if (r == null) continue;
        tried++;
        if (r.ok) {
          d.camera = Camera(
            id: const Uuid().v4(),
            name: '${d.brand == 'Unknown brand' ? 'Camera' : d.brand} ${ip.split('.').last}',
            kind: CameraKind.rtsp,
            host: ip,
            port: rtspPort == 554 ? 0 : rtspPort,
            path: template,
            username: d.user,
            useTls: false,
          );
          d.status = DeviceStatus.ready;
          d.detail = 'Ready: RTSP ${redact(template)}${r.hasVideo ? '' : ' (no video track reported)'}.';
          _say('$ip: RTSP stream found at ${redact(template)}.');
          return;
        }
        if (r.status == 401 || r.status == 403) rejected++;
      }
      if (tried > 0 && rejected == tried) authRejected = true;
      _say('$ip: RTSP on port $rtspPort answered, but none of ${candidatePaths(d.brand).length} known paths gave a stream${rejected > 0 ? ' ($rejected refused the login)' : ''}.');
    }

    if (authRejected) {
      d.status = DeviceStatus.needsPassword;
      d.detail = 'The camera refused the user name or password. Tap to try another.';
    } else {
      d.status = DeviceStatus.noStream;
      d.detail = rtspPort == 0 && onvifPorts.isEmpty
          ? 'No RTSP or ONVIF service. This camera may only work in its maker\'s cloud app.'
          : 'Camera services found, but no working stream. Add it by hand or turn on RTSP/ONVIF in its settings.';
    }
  }

  /// Unauthenticated GetSystemDateAndTime: any SOAP answer means ONVIF.
  static Future<bool> isOnvifEndpoint(Uri device) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.postUrl(device).timeout(const Duration(seconds: 2));
      req.headers.contentType = ContentType('application', 'soap+xml', charset: 'utf-8');
      req.add(utf8.encode(envelope('<GetSystemDateAndTime xmlns="http://www.onvif.org/ver10/device/wsdl"/>')));
      final res = await req.close().timeout(const Duration(seconds: 3));
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 3));
      return body.contains('Envelope') && (body.contains('SystemDateAndTime') || body.contains('Fault'));
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Web server name and page title, used to guess the brand.
  static Future<String> _webBanner(String ip, Set<int> ports) async {
    final port = [80, 8080, 81, 88].firstWhere(ports.contains, orElse: () => 0);
    if (port == 0) return '';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.getUrl(Uri(scheme: 'http', host: ip, port: port, path: '/')).timeout(const Duration(seconds: 2));
      req.followRedirects = true;
      final res = await req.close().timeout(const Duration(seconds: 3));
      final server = res.headers.value('server') ?? '';
      final realm = res.headers.value('www-authenticate') ?? '';
      final bytes = <int>[];
      await for (final chunk in res.timeout(const Duration(seconds: 3))) {
        bytes.addAll(chunk);
        if (bytes.length > 4096) break;
      }
      return '$server $realm ${latin1.decode(bytes, allowInvalid: true)}';
    } catch (_) {
      return '';
    } finally {
      client.close(force: true);
    }
  }
}
