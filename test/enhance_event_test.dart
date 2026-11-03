import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_guard/ai/detection.dart';
import 'package:home_guard/ai/enhance.dart';
import 'package:home_guard/ai/event_store.dart';
import 'package:image/image.dart' as img;

double meanLum(img.Image im) {
  var s = 0.0;
  for (final p in im) {
    s += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
  }
  return s / (im.width * im.height);
}

Detection det(DetectionKind k, [String? text]) =>
    Detection(kind: k, x1: 0, y1: 0, x2: 1, y2: 1, score: 0.9, text: text);

void main() {
  test('low light boost brightens a dark frame', () {
    final im = img.Image(width: 64, height: 48)..clear(img.ColorRgb8(30, 30, 30));
    final out = lowLightBoost(im.clone());
    expect(meanLum(out), greaterThan(meanLum(im) * 2));
  });

  test('auto levels stretches a flat image to full range', () {
    final im = img.Image(width: 100, height: 1);
    for (var x = 0; x < 100; x++) {
      im.setPixelRgb(x, 0, 100 + x ~/ 2, 100 + x ~/ 2, 100 + x ~/ 2);
    }
    final out = autoLevels(im);
    expect(out.getPixel(0, 0).r, lessThan(10));
    expect(out.getPixel(99, 0).r, greaterThan(245));
  });

  test('denoise reduces noise but keeps a hard edge', () {
    final rnd = Random(1);
    final im = img.Image(width: 40, height: 40);
    for (var y = 0; y < 40; y++) {
      for (var x = 0; x < 40; x++) {
        final base = x < 20 ? 40 : 210;
        final v = (base + rnd.nextInt(30) - 15).clamp(0, 255);
        im.setPixelRgb(x, y, v, v, v);
      }
    }
    double noise(img.Image m) {
      var s = 0.0;
      for (var y = 0; y < 40; y++) {
        for (var x = 2; x < 17; x++) {
          s += (m.getPixel(x, y).r - 40).abs();
        }
      }
      return s / (40 * 15);
    }

    final out = edgePreservingDenoise(im);
    expect(noise(out), lessThan(noise(im) * 0.6));
    expect(out.getPixel(18, 20).r, lessThan(90));
    expect(out.getPixel(21, 20).r, greaterThan(160));
  });

  test('full pipeline with 2x upscale and label', () {
    final im = img.Image(width: 32, height: 24)..clear(img.ColorRgb8(20, 20, 20));
    final jpg = img.encodeJpg(im);
    final out = img.decodeJpg(enhanceJpegSync(jpg, const EnhanceOptions(upscale2x: true)))!;
    expect(out.width, 64);
    expect(out.height, 48);
  });

  test('cooldown suppresses repeats and keys plates by text', () {
    final c = Cooldown();
    final t = DateTime(2026, 11, 3, 8);
    expect(c.allow('cam1', det(DetectionKind.face), t), isTrue);
    expect(c.allow('cam1', det(DetectionKind.face), t.add(const Duration(seconds: 5))), isFalse);
    expect(c.allow('cam2', det(DetectionKind.face), t), isTrue);
    expect(c.allow('cam1', det(DetectionKind.face), t.add(const Duration(seconds: 25))), isTrue);
    expect(c.allow('cam1', det(DetectionKind.plate, 'ABC123'), t), isTrue);
    // Same car seen by another camera a minute later is still a repeat.
    expect(c.allow('cam2', det(DetectionKind.plate, 'ABC123'), t.add(const Duration(minutes: 1))), isFalse);
    expect(c.allow('cam1', det(DetectionKind.plate, 'XYZ9'), t), isTrue);
  });
}
