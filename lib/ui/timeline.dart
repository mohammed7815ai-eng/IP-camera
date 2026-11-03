import 'package:flutter/material.dart';

import '../ai/detection.dart';
import '../recording/recording_store.dart';

class TimelineMark {
  TimelineMark(this.time, this.kind);
  final DateTime time;
  final DetectionKind kind;
}

Color markColor(DetectionKind k) => switch (k) {
      DetectionKind.face => const Color(0xFF4FC3F7),
      DetectionKind.plate => const Color(0xFFFFC107),
      DetectionKind.motion => const Color(0xFFEF5350),
    };

/// A 24-hour bar: recorded spans in green, events as coloured ticks, the
/// playhead in white. Tap or drag to pick a time; pinch buttons zoom.
class DayTimeline extends StatelessWidget {
  const DayTimeline({
    super.key,
    required this.day,
    required this.segments,
    required this.marks,
    required this.position,
    required this.onSeek,
    this.from = Duration.zero,
    this.span = const Duration(hours: 24),
  });

  final DateTime day;
  final List<Segment> segments;
  final List<TimelineMark> marks;
  final DateTime? position;
  final ValueChanged<DateTime> onSeek;

  /// Visible window within the day.
  final Duration from, span;

  @override
  Widget build(BuildContext context) {
    final dayStart = DateTime(day.year, day.month, day.day);
    return LayoutBuilder(builder: (context, box) {
      DateTime at(double dx) => dayStart.add(from + span * (dx / box.maxWidth).clamp(0.0, 1.0));
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => onSeek(at(d.localPosition.dx)),
        onHorizontalDragEnd: null,
        onHorizontalDragUpdate: (d) => onSeek(at(d.localPosition.dx)),
        child: CustomPaint(
          size: Size(box.maxWidth, 64),
          painter: _TimelinePainter(dayStart, from, span, segments, marks, position, Theme.of(context).colorScheme),
        ),
      );
    });
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter(this.dayStart, this.from, this.span, this.segments, this.marks, this.position, this.scheme);
  final DateTime dayStart;
  final Duration from, span;
  final List<Segment> segments;
  final List<TimelineMark> marks;
  final DateTime? position;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final start = dayStart.add(from);
    double x(DateTime t) => t.difference(start).inMilliseconds / span.inMilliseconds * size.width;
    const barTop = 18.0, barH = 22.0;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, barTop, size.width, barH), const Radius.circular(4)),
      Paint()..color = scheme.surfaceContainerHighest,
    );
    final rec = Paint()..color = const Color(0xFF43A047);
    for (final s in segments) {
      final l = x(s.start).clamp(0.0, size.width), r = x(s.end).clamp(0.0, size.width);
      if (r > l) canvas.drawRect(Rect.fromLTRB(l, barTop, r < l + 1 ? l + 1 : r, barTop + barH), rec);
    }
    for (final m in marks) {
      final mx = x(m.time);
      if (mx < 0 || mx > size.width) continue;
      canvas.drawRect(Rect.fromLTWH(mx - 1, barTop - 6, 2, 6), Paint()..color = markColor(m.kind));
    }
    // Hour labels.
    final hours = span.inHours <= 2 ? 1 : (span.inHours <= 6 ? 1 : (span.inHours <= 12 ? 2 : 3));
    for (var h = 0; h <= 24; h += hours) {
      final t = dayStart.add(Duration(hours: h));
      final hx = x(t);
      if (hx < -1 || hx > size.width + 1) continue;
      canvas.drawLine(Offset(hx, barTop + barH), Offset(hx, barTop + barH + 4), Paint()..color = scheme.outline);
      final tp = TextPainter(
        text: TextSpan(text: '${h.toString().padLeft(2, '0')}:00', style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
        textDirection: TextDirection.ltr,
      )..layout();
      final lx = (hx - tp.width / 2).clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(lx, barTop + barH + 6));
    }
    final p = position;
    if (p != null) {
      final px = x(p);
      if (px >= 0 && px <= size.width) {
        canvas.drawLine(Offset(px, 4), Offset(px, barTop + barH + 2), Paint()
          ..color = scheme.onSurface
          ..strokeWidth = 2);
      }
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter o) => true;
}
