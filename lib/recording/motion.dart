import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Tiny grey thumbnail used for motion detection.
const motionW = 64, motionH = 36;

Uint8List motionThumb(img.Image frame) {
  final small = img.copyResize(frame, width: motionW, height: motionH, interpolation: img.Interpolation.average);
  final out = Uint8List(motionW * motionH);
  var i = 0;
  for (final p in small) {
    out[i++] = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();
  }
  return out;
}

/// Frame-difference motion detector with a slowly adapting background, so
/// gradual light changes (clouds, dusk) do not trigger it.
class MotionDetector {
  MotionDetector({this.pixelThreshold = 25, this.areaThreshold = 0.015});

  /// Grey-level change that counts a pixel as changed.
  final int pixelThreshold;

  /// Fraction of the picture that must change (1.5% by default).
  final double areaThreshold;

  Float64List? _bg;

  /// Returns the changed fraction of the frame (0..1); motion when it is
  /// at least [areaThreshold].
  double update(Uint8List thumb) {
    final bg = _bg;
    if (bg == null || bg.length != thumb.length) {
      _bg = Float64List.fromList(thumb.map((e) => e.toDouble()).toList());
      return 0;
    }
    // Global brightness shift (auto exposure, IR switching) is removed first.
    var meanDiff = 0.0;
    for (var i = 0; i < thumb.length; i++) {
      meanDiff += thumb[i] - bg[i];
    }
    meanDiff /= thumb.length;
    var changed = 0;
    for (var i = 0; i < thumb.length; i++) {
      if ((thumb[i] - bg[i] - meanDiff).abs() > pixelThreshold) changed++;
      bg[i] = bg[i] * 0.7 + thumb[i] * 0.3;
    }
    return changed / thumb.length;
  }

  bool isMotion(double fraction) => fraction >= areaThreshold;

  void reset() => _bg = null;
}
