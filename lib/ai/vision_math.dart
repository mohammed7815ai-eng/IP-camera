import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A detection in source-image pixel coordinates.
class Box {
  Box(this.x1, this.y1, this.x2, this.y2, this.score);
  final double x1, y1, x2, y2, score;
  double get w => x2 - x1;
  double get h => y2 - y1;
  double get area => math.max(0, w) * math.max(0, h);

  double iou(Box o) {
    final ix = math.max(0.0, math.min(x2, o.x2) - math.max(x1, o.x1));
    final iy = math.max(0.0, math.min(y2, o.y2) - math.max(y1, o.y1));
    final inter = ix * iy;
    final u = area + o.area - inter;
    return u <= 0 ? 0 : inter / u;
  }

  /// Grows the box by [f] of its size on each side, clamped to the image.
  Box expand(double f, int imgW, int imgH) => Box(
        math.max(0, x1 - w * f),
        math.max(0, y1 - h * f),
        math.min(imgW.toDouble(), x2 + w * f),
        math.min(imgH.toDouble(), y2 + h * f),
        score,
      );

  @override
  String toString() => 'Box(${x1.round()},${y1.round()},${x2.round()},${y2.round()} ${score.toStringAsFixed(2)})';
}

List<Box> nms(List<Box> boxes, double iouThreshold) {
  final sorted = [...boxes]..sort((a, b) => b.score.compareTo(a.score));
  final keep = <Box>[];
  for (final b in sorted) {
    if (keep.every((k) => k.iou(b) < iouThreshold)) keep.add(b);
  }
  return keep;
}

// ---------------------------------------------------------------- UltraFace

const faceInputW = 320, faceInputH = 240;

/// UltraFace RFB-320 input: RGB resized to 320x240, (x - 127) / 128, NCHW.
Float32List faceInput(img.Image src) {
  final r = img.copyResize(src, width: faceInputW, height: faceInputH, interpolation: img.Interpolation.linear);
  final plane = faceInputW * faceInputH;
  final out = Float32List(3 * plane);
  for (var y = 0; y < faceInputH; y++) {
    for (var x = 0; x < faceInputW; x++) {
      final p = r.getPixel(x, y);
      final i = y * faceInputW + x;
      out[i] = (p.r - 127) / 128;
      out[plane + i] = (p.g - 127) / 128;
      out[2 * plane + i] = (p.b - 127) / 128;
    }
  }
  return out;
}

/// Decodes UltraFace outputs: scores [N,2] (background, face) and boxes
/// [N,4] normalised corners.
List<Box> decodeFaces(List<double> scores, List<double> boxes, int imgW, int imgH,
    {double threshold = 0.7, double iou = 0.3}) {
  final n = scores.length ~/ 2;
  final out = <Box>[];
  for (var i = 0; i < n; i++) {
    final s = scores[i * 2 + 1];
    if (s < threshold) continue;
    out.add(Box(
      (boxes[i * 4] * imgW).clamp(0, imgW).toDouble(),
      (boxes[i * 4 + 1] * imgH).clamp(0, imgH).toDouble(),
      (boxes[i * 4 + 2] * imgW).clamp(0, imgW).toDouble(),
      (boxes[i * 4 + 3] * imgH).clamp(0, imgH).toDouble(),
      s,
    ));
  }
  return nms(out, iou).where((b) => b.w > 8 && b.h > 8).toList();
}

// ------------------------------------------------------------ Plate detector

const plateInput = 384;

class Letterbox {
  Letterbox(this.data, this.scale, this.padX, this.padY);
  final Float32List data;
  final double scale;
  final int padX, padY;
}

/// YOLOv9 input: letterboxed to 384x384 with grey (114) padding, RGB / 255, NCHW.
Letterbox plateLetterbox(img.Image src) {
  final scale = math.min(plateInput / src.width, plateInput / src.height);
  final nw = (src.width * scale).round(), nh = (src.height * scale).round();
  final padX = (plateInput - nw) ~/ 2, padY = (plateInput - nh) ~/ 2;
  final r = img.copyResize(src, width: nw, height: nh, interpolation: img.Interpolation.linear);
  const plane = plateInput * plateInput;
  final out = Float32List(3 * plane)..fillRange(0, 3 * plane, 114 / 255);
  for (var y = 0; y < nh; y++) {
    for (var x = 0; x < nw; x++) {
      final p = r.getPixel(x, y);
      final i = (y + padY) * plateInput + (x + padX);
      out[i] = p.r / 255;
      out[plane + i] = p.g / 255;
      out[2 * plane + i] = p.b / 255;
    }
  }
  return Letterbox(out, scale, padX, padY);
}

/// Decodes end-to-end YOLO rows [batch, x1, y1, x2, y2, class, score] back to
/// source pixels.
List<Box> decodePlates(List<double> rows, Letterbox lb, int imgW, int imgH, {double threshold = 0.4}) {
  final out = <Box>[];
  for (var i = 0; i + 6 < rows.length; i += 7) {
    final score = rows[i + 6];
    if (score < threshold) continue;
    double ux(double v) => ((v - lb.padX) / lb.scale).clamp(0, imgW).toDouble();
    double uy(double v) => ((v - lb.padY) / lb.scale).clamp(0, imgH).toDouble();
    out.add(Box(ux(rows[i + 1]), uy(rows[i + 2]), ux(rows[i + 3]), uy(rows[i + 4]), score));
  }
  return nms(out, 0.5);
}

// ----------------------------------------------------------------- Plate OCR

const ocrW = 128, ocrH = 64, ocrSlots = 9;
const ocrAlphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_';

/// fast-plate-ocr input: RGB uint8 [1, 64, 128, 3], stretched (no aspect keep).
Uint8List ocrInput(img.Image plateCrop) {
  final r = img.copyResize(plateCrop, width: ocrW, height: ocrH, interpolation: img.Interpolation.linear);
  final out = Uint8List(ocrW * ocrH * 3);
  var k = 0;
  for (var y = 0; y < ocrH; y++) {
    for (var x = 0; x < ocrW; x++) {
      final p = r.getPixel(x, y);
      out[k++] = p.r.toInt();
      out[k++] = p.g.toInt();
      out[k++] = p.b.toInt();
    }
  }
  return out;
}

class PlateText {
  PlateText(this.text, this.confidence);
  final String text;

  /// Lowest per-character confidence (a weak character makes the read weak).
  final double confidence;
}

/// Decodes [9 slots x 37 classes] probabilities.
PlateText decodePlateText(List<double> probs) {
  const n = ocrAlphabet.length;
  final sb = StringBuffer();
  var minConf = 1.0;
  for (var s = 0; s < ocrSlots; s++) {
    var best = 0;
    for (var c = 1; c < n; c++) {
      if (probs[s * n + c] > probs[s * n + best]) best = c;
    }
    final ch = ocrAlphabet[best];
    if (ch == '_') continue;
    sb.write(ch);
    minConf = math.min(minConf, probs[s * n + best]);
  }
  return PlateText(sb.toString(), sb.isEmpty ? 0 : minConf);
}

img.Image crop(img.Image src, Box b) => img.copyCrop(
      src,
      x: b.x1.floor(),
      y: b.y1.floor(),
      width: math.max(1, b.w.ceil()),
      height: math.max(1, b.h.ceil()),
    );
