import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_guard/ai/detection.dart';
import 'package:home_guard/alarm/alarm.dart';
import 'package:home_guard/alarm/notifier.dart';
import 'package:home_guard/models/camera.dart';
import 'package:home_guard/recording/camera_worker.dart';
import 'package:home_guard/recording/motion.dart';
import 'package:home_guard/recording/recording_store.dart';

Detection d(DetectionKind k, [String? text]) => Detection(kind: k, x1: 0, y1: 0, x2: 1, y2: 1, score: 0.9, text: text);

Camera cam({bool motion = true, bool faces = true, bool plates = true, bool home = false}) => Camera(
      id: 'c1',
      name: 'Drive',
      kind: CameraKind.rtsp,
      alarmMotion: motion,
      alarmFaces: faces,
      alarmPlates: plates,
      alarmWhenHome: home,
    );

void main() {
  group('alarm rules', () {
    test('disarmed: nothing, except a silent watchlist hit', () {
      final s = AlarmSettings(mode: ArmMode.disarmed, watchlist: ['abc-123']);
      final r = evaluateAlarm(s, cam(), [d(DetectionKind.motion), d(DetectionKind.plate, 'ABC123'), d(DetectionKind.face)]);
      expect(r, hasLength(1));
      expect(r.single.reason, contains('Watchlist plate ABC123'));
      expect(r.single.loud, isFalse);
    });

    test('away: all enabled triggers fire, allowed plates do not', () {
      final s = AlarmSettings(mode: ArmMode.away, allowlist: ['MY CAR1']);
      final r = evaluateAlarm(s, cam(), [d(DetectionKind.motion), d(DetectionKind.face), d(DetectionKind.plate, 'MYCAR1'), d(DetectionKind.plate, 'XYZ9')]);
      expect(r.map((e) => e.reason), ['Motion at Drive', 'Person (face) at Drive', 'Vehicle XYZ9 at Drive']);
      expect(r.every((e) => e.loud), isTrue);
    });

    test('home: only cameras marked for home mode', () {
      final s = AlarmSettings(mode: ArmMode.home);
      expect(evaluateAlarm(s, cam(), [d(DetectionKind.motion)]), isEmpty);
      expect(evaluateAlarm(s, cam(home: true), [d(DetectionKind.motion)]), hasLength(1));
    });

    test('disabled triggers stay quiet', () {
      final s = AlarmSettings(mode: ArmMode.away);
      expect(evaluateAlarm(s, cam(motion: false, faces: false, plates: false), [d(DetectionKind.motion), d(DetectionKind.face)]), isEmpty);
    });

    test('settings round-trip', () {
      final s = AlarmSettings(mode: ArmMode.home, watchlist: ['A1'], allowlist: ['B2'], siren: false);
      final back = AlarmSettings.fromJson(s.toJson());
      expect(back.mode, ArmMode.home);
      expect(back.watchlist, ['A1']);
      expect(back.allowlist, ['B2']);
      expect(back.siren, isFalse);
    });
  });

  group('event-only recording retention', () {
    File f(String n) => File(n);

    test('quiet segments are deleted, event segments kept with pre- and post-roll', () {
      final r = EventRetention();
      final deleted = <String>[];
      void rot(String n) {
        final x = r.onRotate(f(n));
        if (x != null) deleted.add(x.path);
      }

      rot('s1'); // quiet
      rot('s2'); // quiet -> s1 deleted
      r.onEvent(); // event during s3: s2 becomes pre-roll
      rot('s3'); // s3 kept
      rot('s4'); // post-roll of s3, kept
      rot('s5'); // quiet
      rot('s6'); // quiet -> s5 deleted
      expect(deleted, ['s1', 's5']);
      expect(r.onStop(f('s7')).map((e) => e.path), ['s6', 's7']);
    });
  });

  group('recording store', () {
    test('segment time parsing', () {
      expect(parseSegmentTime('20261103', '073005.mkv'), DateTime(2026, 11, 3, 7, 30, 5));
      expect(parseSegmentTime('20261103', 'x.mkv'), isNull);
    });

    test('segments end at the next start, or at last write after a gap', () {
      final t = DateTime(2026, 11, 3, 8);
      final segs = segmentsFrom([
        (File('b'), t.add(const Duration(minutes: 5)), t.add(const Duration(minutes: 7))),
        (File('a'), t, t.add(const Duration(minutes: 5, seconds: 1))),
        (File('c'), t.add(const Duration(minutes: 30)), t.add(const Duration(minutes: 35))),
      ]);
      expect(segs.map((s) => s.file.path), ['a', 'b', 'c']);
      expect(segs[0].end, t.add(const Duration(minutes: 5)));
      expect(segs[1].end, t.add(const Duration(minutes: 7))); // camera went offline
      expect(segs[1].contains(t.add(const Duration(minutes: 6))), isTrue);
      expect(segs[1].contains(t.add(const Duration(minutes: 10))), isFalse);
    });
  });

  group('motion detection', () {
    Uint8List frame(int v, {int blockAt = -1}) {
      final f = Uint8List(motionW * motionH)..fillRange(0, motionW * motionH, v);
      if (blockAt >= 0) {
        for (var y = 10; y < 20; y++) {
          for (var x = blockAt; x < blockAt + 10; x++) {
            f[y * motionW + x] = 250;
          }
        }
      }
      return f;
    }

    test('detects a moving object', () {
      final m = MotionDetector();
      expect(m.update(frame(60)), 0);
      expect(m.isMotion(m.update(frame(60))), isFalse);
      expect(m.isMotion(m.update(frame(60, blockAt: 20))), isTrue);
    });

    test('ignores a whole-picture brightness change (lights, auto exposure)', () {
      final m = MotionDetector();
      m.update(frame(60));
      expect(m.isMotion(m.update(frame(110))), isFalse);
    });
  });

  test('siren is a valid 10 s WAV', () {
    final w = sirenWav();
    expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(w.sublist(8, 12)), 'WAVE');
    expect(w.length, 44 + 10 * 22050 * 2);
  });

  test('camera recording and alarm settings round-trip', () {
    final c = Camera(id: 'x', name: 'n', kind: CameraKind.onvif, recording: RecordingMode.events, retentionDays: 30, motion: true, alarmPlates: true);
    final b = Camera.fromJson(c.toJson());
    expect(b.recording, RecordingMode.events);
    expect(b.retentionDays, 30);
    expect(b.needsWorker, isTrue);
    expect(Camera(id: 'y', name: 'n', kind: CameraKind.httpApi, recording: RecordingMode.continuous).needsWorker, isFalse);
  });
}
