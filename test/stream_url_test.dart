import 'package:flutter_test/flutter_test.dart';
import 'package:home_guard/models/camera.dart';
import 'package:home_guard/services/stream_url.dart';
import 'package:home_guard/ui/live_view.dart' show snapshotUri;

void main() {
  test('builds rtsp url with encoded credentials', () {
    final c = Camera(id: '1', name: 'a', kind: CameraKind.rtsp, host: '192.168.1.5', path: 'Streaming/Channels/101', username: 'admin', useTls: false);
    expect(buildStreamUrl(c, password: 'p@ss:w/rd'), 'rtsp://admin:p%40ss%3Aw%2Frd@192.168.1.5:554/Streaming/Channels/101');
  });

  test('rtsps uses port 322 and full URLs are accepted', () {
    final c = Camera(id: '1', name: 'a', kind: CameraKind.rtsp, host: 'cam.lan', useTls: true);
    expect(buildStreamUrl(c), 'rtsps://cam.lan:322');
    final full = Camera(id: '2', name: 'b', kind: CameraKind.rtsp, host: 'rtsp://old:creds@10.0.0.2:8554/live?ch=1', username: 'u');
    expect(buildStreamUrl(full, password: 'x'), 'rtsp://u:x@10.0.0.2:8554/live?ch=1');
  });

  test('onvif uses the resolved stream uri', () {
    final c = Camera(id: '1', name: 'a', kind: CameraKind.onvif, username: 'admin', resolvedStreamUri: 'rtsp://10.0.0.3/h264');
    expect(buildStreamUrl(c, password: 'pw'), 'rtsp://admin:pw@10.0.0.3/h264');
  });

  test('redact hides passwords', () {
    expect(redact('rtsp://admin:secret@10.0.0.3/h264'), 'rtsp://admin:••••@10.0.0.3/h264');
    expect(redact('rtsp://10.0.0.3/h264'), 'rtsp://10.0.0.3/h264');
  });

  test('snapshot uri for API cameras', () {
    final c = Camera(id: '1', name: 'a', kind: CameraKind.httpApi, host: 'cam.lan', path: 'api/snap.jpg?ch=2', useTls: true);
    expect(snapshotUri(c).toString(), 'https://cam.lan/api/snap.jpg?ch=2');
  });
}
