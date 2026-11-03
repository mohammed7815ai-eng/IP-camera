/// One thing the AI found in a frame.
enum DetectionKind { face, plate, motion }

class Detection {
  Detection({
    required this.kind,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.score,
    this.text,
    this.textConfidence,
  });

  final DetectionKind kind;

  /// Box in normalised 0..1 frame coordinates.
  final double x1, y1, x2, y2;
  final double score;

  /// Plate number, when read.
  final String? text;
  final double? textConfidence;

  String get label => switch (kind) {
        DetectionKind.face => 'Face ${(score * 100).round()}%',
        DetectionKind.plate => text == null || text!.isEmpty ? 'Plate' : text!,
        DetectionKind.motion => 'Motion',
      };
}

class FrameAnalysis {
  FrameAnalysis(this.detections, this.width, this.height, this.at);
  final List<Detection> detections;
  final int width, height;
  final DateTime at;
}
