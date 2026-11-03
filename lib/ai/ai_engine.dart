import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import 'detection.dart';
import 'vision_math.dart';

/// Result of decoding and preparing a frame in a background isolate.
class _Prepared {
  _Prepared(this.width, this.height, this.rgb, this.face, this.plate, this.scale, this.padX, this.padY);
  final int width, height;
  final TransferableTypedData rgb;
  final Float32List? face;
  final Float32List? plate;
  final double scale;
  final int padX, padY;
}

_Prepared _prepare((Uint8List, bool, bool) args) {
  final (jpeg, faces, plates) = args;
  final im = img.decodeImage(jpeg);
  if (im == null) throw const FormatException('Frame is not an image');
  final rgbImg = im.convert(numChannels: 3);
  Letterbox? lb;
  if (plates) lb = plateLetterbox(rgbImg);
  return _Prepared(
    rgbImg.width,
    rgbImg.height,
    TransferableTypedData.fromList([rgbImg.getBytes(order: img.ChannelOrder.rgb)]),
    faces ? faceInput(rgbImg) : null,
    lb?.data,
    lb?.scale ?? 1,
    lb?.padX ?? 0,
    lb?.padY ?? 0,
  );
}

/// Analysis of one frame plus the decoded pixels, so callers can cut crops.
class EngineResult {
  EngineResult(this.analysis, this.frame, this.boxes);
  final FrameAnalysis analysis;
  final img.Image frame;

  /// Pixel boxes, same order as [FrameAnalysis.detections].
  final List<Box> boxes;
}

/// On-device detectors, run with ONNX Runtime on Windows and Android.
///
/// * Faces: UltraFace RFB-320 (MIT).
/// * Number plates: YOLOv9-t plate detector from open-image-models (MIT).
/// * Plate reading: fast-plate-ocr CCT-XS global model (MIT).
///
/// Nothing leaves the device.
class AiEngine {
  AiEngine._();
  static final AiEngine instance = AiEngine._();

  final _ort = OnnxRuntime();
  OrtSession? _face, _plate, _ocr;
  Future<void>? _loading;
  bool _busy = false;
  String? loadError;

  bool get busy => _busy;

  Future<void> _load() => _loading ??= () async {
        try {
          _face = await _ort.createSessionFromAsset('assets/models/ultraface-rfb-320.onnx');
          _plate = await _ort.createSessionFromAsset('assets/models/yolo-v9-t-384-license-plates-end2end.onnx');
          _ocr = await _ort.createSessionFromAsset('assets/models/cct_xs_v1_global.onnx');
        } catch (e) {
          loadError = 'AI models could not be loaded: $e';
          _loading = null;
          rethrow;
        }
      }();

  /// Runs the enabled detectors on a JPEG frame. Returns null when another
  /// frame is still being analysed (frames are dropped, never queued).
  Future<EngineResult?> analyze(Uint8List jpeg, {required bool faces, required bool plates}) async {
    if (_busy || (!faces && !plates)) return null;
    _busy = true;
    try {
      await _load();
      final prep = await Isolate.run(() => _prepare((jpeg, faces, plates)));
      final w = prep.width, h = prep.height;
      final frame = img.Image.fromBytes(
        width: w,
        height: h,
        bytes: prep.rgb.materialize(),
        numChannels: 3,
        order: img.ChannelOrder.rgb,
      );
      final dets = <Detection>[];
      final boxes = <Box>[];

      if (prep.face != null) {
        final input = await OrtValue.fromList(prep.face!, [1, 3, faceInputH, faceInputW]);
        final out = await _face!.run({'input': input});
        final scores = (await out['scores']!.asFlattenedList()).cast<num>().map((e) => e.toDouble()).toList();
        final bx = (await out['boxes']!.asFlattenedList()).cast<num>().map((e) => e.toDouble()).toList();
        for (final b in decodeFaces(scores, bx, w, h)) {
          boxes.add(b);
          dets.add(Detection(kind: DetectionKind.face, x1: b.x1 / w, y1: b.y1 / h, x2: b.x2 / w, y2: b.y2 / h, score: b.score));
        }
        await input.dispose();
        for (final v in out.values) {
          await v.dispose();
        }
      }

      if (prep.plate != null) {
        final input = await OrtValue.fromList(prep.plate!, [1, 3, plateInput, plateInput]);
        final out = await _plate!.run({'images': input});
        final rows = (await out.values.first.asFlattenedList()).cast<num>().map((e) => e.toDouble()).toList();
        await input.dispose();
        for (final v in out.values) {
          await v.dispose();
        }
        final lb = Letterbox(Float32List(0), prep.scale, prep.padX, prep.padY);
        for (final b in decodePlates(rows, lb, w, h)) {
          final read = await _readPlate(crop(frame, b.expand(0.04, w, h)));
          boxes.add(b);
          dets.add(Detection(
            kind: DetectionKind.plate,
            x1: b.x1 / w,
            y1: b.y1 / h,
            x2: b.x2 / w,
            y2: b.y2 / h,
            score: b.score,
            text: read.confidence >= 0.5 ? read.text : null,
            textConfidence: read.confidence,
          ));
        }
      }
      return EngineResult(FrameAnalysis(dets, w, h, DateTime.now()), frame, boxes);
    } finally {
      _busy = false;
    }
  }

  Future<PlateText> _readPlate(img.Image plateCrop) async {
    final input = await OrtValue.fromList(ocrInput(plateCrop), [1, ocrH, ocrW, 3]);
    final out = await _ocr!.run({'input': input});
    final probs = (await out.values.first.asFlattenedList()).cast<num>().map((e) => e.toDouble()).toList();
    await input.dispose();
    for (final v in out.values) {
      await v.dispose();
    }
    return decodePlateText(probs);
  }
}
