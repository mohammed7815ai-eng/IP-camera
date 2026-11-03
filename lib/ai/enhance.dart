import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

class EnhanceOptions {
  const EnhanceOptions({
    this.autoLevels = true,
    this.lowLight = true,
    this.denoise = true,
    this.sharpen = true,
    this.upscale2x = false,
    this.label = true,
  });
  final bool autoLevels, lowLight, denoise, sharpen, upscale2x;

  /// Stamps "ENHANCED" in the corner so the copy is never mistaken for the
  /// original recording.
  final bool label;
}

/// Enhances a JPEG off the UI thread and returns a new JPEG.
Future<Uint8List> enhanceJpeg(Uint8List jpeg, EnhanceOptions o) =>
    Isolate.run(() => enhanceJpegSync(jpeg, o));

Uint8List enhanceJpegSync(Uint8List jpeg, EnhanceOptions o) {
  var im = img.decodeImage(jpeg);
  if (im == null) throw const FormatException('Not an image');
  im = enhanceImage(im, o);
  return Uint8List.fromList(img.encodeJpg(im, quality: 92));
}

img.Image enhanceImage(img.Image src, EnhanceOptions o) {
  var im = src.convert(numChannels: 3);
  if (o.denoise) im = edgePreservingDenoise(im);
  if (o.lowLight) im = lowLightBoost(im);
  if (o.autoLevels) im = autoLevels(im);
  if (o.upscale2x) {
    im = img.copyResize(im, width: im.width * 2, height: im.height * 2, interpolation: img.Interpolation.cubic);
  }
  if (o.sharpen) im = unsharpMask(im, amount: o.upscale2x ? 0.9 : 0.6);
  if (o.label) {
    img.fillRect(im, x1: 6, y1: 6, x2: 92, y2: 26, color: img.ColorRgba8(0, 0, 0, 160));
    img.drawString(im, 'ENHANCED', font: img.arial14, x: 10, y: 9, color: img.ColorRgb8(255, 200, 0));
  }
  return im;
}

double _lum(num r, num g, num b) => 0.299 * r + 0.587 * g + 0.114 * b;

/// Stretches contrast so the darkest 0.5% becomes black and the brightest
/// 0.5% white; colours keep their balance.
img.Image autoLevels(img.Image im) {
  final hist = List<int>.filled(256, 0);
  for (final p in im) {
    hist[_lum(p.r, p.g, p.b).round().clamp(0, 255)]++;
  }
  final total = im.width * im.height;
  int pct(double f) {
    var acc = 0;
    for (var i = 0; i < 256; i++) {
      acc += hist[i];
      if (acc >= total * f) return i;
    }
    return 255;
  }

  final lo = pct(0.005), hi = pct(0.995);
  if (hi - lo < 10) return im;
  final scale = 255 / (hi - lo);
  final lut = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    lut[i] = ((i - lo) * scale).round().clamp(0, 255);
  }
  for (final p in im) {
    p
      ..r = lut[p.r.toInt()]
      ..g = lut[p.g.toInt()]
      ..b = lut[p.b.toInt()];
  }
  return im;
}

/// Brightens dark frames with a gamma curve chosen from the mean brightness.
img.Image lowLightBoost(img.Image im) {
  var sum = 0.0;
  for (final p in im) {
    sum += _lum(p.r, p.g, p.b);
  }
  final mean = sum / (im.width * im.height) / 255;
  if (mean >= 0.42 || mean <= 0.001) return im;
  final gamma = (math.log(0.45) / math.log(mean)).clamp(0.35, 1.0);
  final lut = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    lut[i] = (math.pow(i / 255, gamma) * 255).round().clamp(0, 255);
  }
  for (final p in im) {
    p
      ..r = lut[p.r.toInt()]
      ..g = lut[p.g.toInt()]
      ..b = lut[p.b.toInt()];
  }
  return im;
}

/// 5x5 bilateral filter: smooths sensor noise but keeps edges (and text on
/// number plates) sharp.
img.Image edgePreservingDenoise(img.Image src, {double sigmaColor = 22, double sigmaSpace = 1.6}) {
  final w = src.width, h = src.height;
  final inp = src.getBytes(order: img.ChannelOrder.rgb);
  final out = Uint8List(inp.length);
  final rangeLut = Float64List(256 * 3);
  for (var d = 0; d < rangeLut.length; d++) {
    rangeLut[d] = math.exp(-(d * d) / (2 * sigmaColor * sigmaColor * 3));
  }
  final spatial = Float64List(25);
  for (var dy = -2; dy <= 2; dy++) {
    for (var dx = -2; dx <= 2; dx++) {
      spatial[(dy + 2) * 5 + dx + 2] = math.exp(-(dx * dx + dy * dy) / (2 * sigmaSpace * sigmaSpace));
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = (y * w + x) * 3;
      final r0 = inp[c], g0 = inp[c + 1], b0 = inp[c + 2];
      var sr = 0.0, sg = 0.0, sb = 0.0, sw = 0.0;
      for (var dy = -2; dy <= 2; dy++) {
        final yy = (y + dy).clamp(0, h - 1);
        for (var dx = -2; dx <= 2; dx++) {
          final xx = (x + dx).clamp(0, w - 1);
          final k = (yy * w + xx) * 3;
          final r = inp[k], g = inp[k + 1], b = inp[k + 2];
          final d = (r - r0).abs() + (g - g0).abs() + (b - b0).abs();
          final wgt = spatial[(dy + 2) * 5 + dx + 2] * rangeLut[d];
          sr += r * wgt;
          sg += g * wgt;
          sb += b * wgt;
          sw += wgt;
        }
      }
      out[c] = (sr / sw).round();
      out[c + 1] = (sg / sw).round();
      out[c + 2] = (sb / sw).round();
    }
  }
  return img.Image.fromBytes(width: w, height: h, bytes: out.buffer, numChannels: 3, order: img.ChannelOrder.rgb);
}

/// Sharpens detail: original + amount x (original - blurred).
img.Image unsharpMask(img.Image im, {double amount = 0.6, int radius = 2}) {
  final blurred = img.gaussianBlur(im.clone(), radius: radius);
  final a = im.getBytes(order: img.ChannelOrder.rgb);
  final b = blurred.getBytes(order: img.ChannelOrder.rgb);
  final out = Uint8List(a.length);
  for (var i = 0; i < a.length; i++) {
    out[i] = (a[i] + amount * (a[i] - b[i])).round().clamp(0, 255);
  }
  return img.Image.fromBytes(width: im.width, height: im.height, bytes: out.buffer, numChannels: 3, order: img.ChannelOrder.rgb);
}
