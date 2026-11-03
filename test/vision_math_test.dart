import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_guard/ai/vision_math.dart';
import 'package:image/image.dart' as img;

/// Raw outputs of the real ONNX models on the fixture images, recorded with
/// ONNX Runtime (Python), so decoding is checked against true model output.
final golden = jsonDecode(File('test/fixtures/golden_outputs.json').readAsStringSync()) as Map<String, dynamic>;
List<double> g(String k) => (golden[k] as List).cast<num>().map((e) => e.toDouble()).toList();

void main() {
  test('face decoding finds the astronaut face', () {
    final faces = decodeFaces(g('face_scores'), g('face_boxes'), 512, 512);
    expect(faces, hasLength(1));
    final f = faces.single;
    // Face is around x 180-268, y 62-174 in the 512x512 photo.
    expect(f.x1, closeTo(180, 12));
    expect(f.y1, closeTo(62, 12));
    expect(f.x2, closeTo(268, 12));
    expect(f.y2, closeTo(174, 12));
  });

  test('plate letterbox geometry and decoding map back to the source', () {
    final car = img.decodeJpg(File('test/fixtures/car.jpg').readAsBytesSync())!;
    final lb = plateLetterbox(car);
    expect(lb.scale, closeTo(0.6, 1e-9));
    expect(lb.padX, 0);
    expect(lb.padY, 48);
    expect(lb.data.length, 3 * 384 * 384);
    expect(lb.data[0], closeTo(114 / 255, 1e-6)); // padding row
    final plates = decodePlates(g('plate_rows'), lb, car.width, car.height);
    expect(plates, hasLength(1));
    final p = plates.single;
    // Plate drawn at 250,320 - 390,355.
    expect(p.x1, closeTo(250, 8));
    expect(p.y1, closeTo(320, 8));
    expect(p.x2, closeTo(390, 8));
    expect(p.y2, closeTo(355, 8));
  });

  test('plate text decoding', () {
    final t = decodePlateText(g('ocr_probs'));
    expect(t.text, 'ABC123');
    expect(t.confidence, greaterThan(0.9));
  });

  test('face input normalisation', () {
    final im = img.Image(width: 640, height: 480)..clear(img.ColorRgb8(255, 127, 0));
    final x = faceInput(im);
    expect(x.length, 3 * 320 * 240);
    expect(x[0], closeTo(1.0, 0.01));
    expect(x[320 * 240], closeTo(0.0, 0.01));
    expect(x[2 * 320 * 240], closeTo(-127 / 128, 0.01));
  });

  test('ocr input is 64x128 RGB bytes', () {
    final im = img.Image(width: 200, height: 50)..clear(img.ColorRgb8(10, 20, 30));
    final x = ocrInput(im);
    expect(x.length, 64 * 128 * 3);
    expect(x.sublist(0, 3), [10, 20, 30]);
  });

  test('nms keeps the strongest of overlapping boxes', () {
    final r = nms([Box(0, 0, 10, 10, 0.9), Box(1, 1, 10, 10, 0.8), Box(50, 50, 60, 60, 0.7)], 0.5);
    expect(r.map((b) => b.score), [0.9, 0.7]);
  });
}
