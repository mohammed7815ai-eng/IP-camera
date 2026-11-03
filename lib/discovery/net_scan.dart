import 'dart:async';
import 'dart:io';

/// Ports that cameras and video recorders commonly open, with what an open
/// port suggests about the device.
const cameraPorts = <int, String>{
  554: 'RTSP',
  8554: 'RTSP',
  10554: 'RTSP',
  80: 'Web',
  8080: 'Web',
  81: 'Web',
  88: 'Web',
  443: 'HTTPS',
  8000: 'Hikvision SDK',
  8899: 'ONVIF (XMEye)',
  5000: 'ONVIF (Yoosee)',
  2020: 'ONVIF (Tapo)',
  6688: 'ONVIF',
  34567: 'XMEye / iCSee',
  37777: 'Dahua SDK',
  9000: 'Reolink',
};

const rtspPorts = [554, 8554, 10554];
const onvifPortGuesses = [80, 8899, 5000, 2020, 8080, 6688, 8000, 81, 88];

/// True for addresses in 10/8, 172.16/12 and 192.168/16.
bool isPrivateIpv4(String ip) {
  final p = ip.split('.').map(int.tryParse).toList();
  if (p.length != 4 || p.any((e) => e == null)) return false;
  final a = p[0]!, b = p[1]!;
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}

/// The device's own private IPv4 addresses, one per network.
Future<List<String>> localIpv4Addresses() async {
  final out = <String>[];
  final seen = <String>{};
  for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false)) {
    for (final a in nic.addresses) {
      final ip = a.address;
      if (!isPrivateIpv4(ip)) continue;
      if (seen.add(subnet24(ip))) out.add(ip);
    }
  }
  return out;
}

/// `192.168.1.37` -> `192.168.1`.
String subnet24(String ip) => ip.substring(0, ip.lastIndexOf('.'));

/// Every host address of the /24 around [ip], except [ip] itself.
List<String> hostsOf(String ip) {
  final net = subnet24(ip);
  return [for (var i = 1; i < 255; i++) '$net.$i'].where((h) => h != ip).toList();
}

Future<bool> isPortOpen(String host, int port, {Duration timeout = const Duration(milliseconds: 700)}) async {
  try {
    final s = await Socket.connect(host, port, timeout: timeout);
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Checks [ports] on every host with at most [parallel] connections open at
/// once. Calls [onProgress] with (done, total). Returns open ports per host.
Future<Map<String, Set<int>>> scanPorts(
  List<String> hosts,
  Iterable<int> ports, {
  int parallel = 128,
  Duration timeout = const Duration(milliseconds: 700),
  void Function(int done, int total)? onProgress,
  bool Function()? cancelled,
}) async {
  final jobs = <(String, int)>[for (final h in hosts) for (final p in ports) (h, p)];
  final open = <String, Set<int>>{};
  var next = 0, done = 0;
  Future<void> worker() async {
    while (next < jobs.length) {
      if (cancelled?.call() ?? false) return;
      final (host, port) = jobs[next++];
      if (await isPortOpen(host, port, timeout: timeout)) (open[host] ??= <int>{}).add(port);
      done++;
      if (done % 32 == 0 || done == jobs.length) onProgress?.call(done, jobs.length);
    }
  }

  await Future.wait([for (var i = 0; i < parallel; i++) worker()]);
  return open;
}
