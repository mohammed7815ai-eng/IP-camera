import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// One recorded file: `<root>/<cameraId>/<yyyyMMdd>/<HHmmss>.mkv`, named by
/// its local start time.
class Segment {
  Segment(this.file, this.start, this.end);
  final File file;
  final DateTime start;

  /// Start of the next segment, or the file's last write for the newest one.
  final DateTime end;
  Duration get length => end.difference(start);
  bool contains(DateTime t) => !t.isBefore(start) && t.isBefore(end);
}

String _two(int v) => v.toString().padLeft(2, '0');
String dayKey(DateTime t) => '${t.year}${_two(t.month)}${_two(t.day)}';
String timeKey(DateTime t) => '${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

/// Parses `yyyyMMdd` + `HHmmss` back to a local DateTime.
DateTime? parseSegmentTime(String day, String fileName) {
  final m = RegExp(r'^(\d{2})(\d{2})(\d{2})\.mkv$').firstMatch(fileName);
  final d = RegExp(r'^(\d{4})(\d{2})(\d{2})$').firstMatch(day);
  if (m == null || d == null) return null;
  return DateTime(int.parse(d[1]!), int.parse(d[2]!), int.parse(d[3]!), int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

/// Builds segments from file starts. A segment ends where the next begins,
/// unless there is a gap (camera offline), in which case it ends at its own
/// last write time.
List<Segment> segmentsFrom(List<(File, DateTime, DateTime)> files) {
  final sorted = [...files]..sort((a, b) => a.$2.compareTo(b.$2));
  final out = <Segment>[];
  for (var i = 0; i < sorted.length; i++) {
    final (f, start, modified) = sorted[i];
    var end = modified;
    if (i + 1 < sorted.length) {
      final next = sorted[i + 1].$2;
      if (next.isBefore(end) || next.difference(end).inSeconds.abs() <= 5) end = next;
    }
    if (!end.isAfter(start)) end = start.add(const Duration(seconds: 1));
    out.add(Segment(f, start, end));
  }
  return out;
}

class RecordingStore {
  RecordingStore._();
  static final RecordingStore instance = RecordingStore._();

  Directory? _root;

  Future<Directory> root() async {
    if (_root != null) return _root!;
    final sep = Platform.pathSeparator;
    final base = Platform.isAndroid
        ? (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory()
        : Directory('${(await getApplicationDocumentsDirectory()).path}${sep}HomeGuard');
    _root = Directory('${base.path}${sep}Recordings');
    await _root!.create(recursive: true);
    return _root!;
  }

  Future<File> newSegmentFile(String cameraId, DateTime start) async {
    final sep = Platform.pathSeparator;
    final dir = Directory('${(await root()).path}$sep$cameraId$sep${dayKey(start)}');
    await dir.create(recursive: true);
    return File('${dir.path}$sep${timeKey(start)}.mkv');
  }

  /// Segments of one camera that overlap the local day of [day].
  Future<List<Segment>> segmentsForDay(String cameraId, DateTime day) async {
    final sep = Platform.pathSeparator;
    final files = <(File, DateTime, DateTime)>[];
    // Include the previous day so a segment crossing midnight is found.
    for (final d in [day.subtract(const Duration(days: 1)), day]) {
      final key = dayKey(d);
      final dir = Directory('${(await root()).path}$sep$cameraId$sep$key');
      if (!await dir.exists()) continue;
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final t = parseSegmentTime(key, e.uri.pathSegments.last);
        if (t == null) continue;
        final st = await e.stat();
        if (st.size < 1024) continue;
        files.add((e, t, st.modified));
      }
    }
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    return segmentsFrom(files).where((s) => s.end.isAfter(dayStart) && s.start.isBefore(dayEnd)).toList();
  }

  /// Days (local) that have recordings for [cameraId], newest first.
  Future<List<DateTime>> daysWithRecordings(String cameraId) async {
    final dir = Directory('${(await root()).path}${Platform.pathSeparator}$cameraId');
    if (!await dir.exists()) return [];
    final days = <DateTime>[];
    await for (final e in dir.list()) {
      final m = RegExp(r'(\d{4})(\d{2})(\d{2})$').firstMatch(e.path);
      if (e is Directory && m != null) days.add(DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)));
    }
    days.sort((a, b) => b.compareTo(a));
    return days;
  }

  /// Deletes recordings older than [keepDays] per camera, then the oldest
  /// files until total size is under [maxBytes]. Never touches [active].
  Future<int> enforceRetention({required Map<String, int> keepDays, required int maxBytes, Set<String> active = const {}}) async {
    final r = await root();
    var deleted = 0;
    final all = <(File, DateTime, int)>[];
    final now = DateTime.now();
    await for (final camDir in r.list()) {
      if (camDir is! Directory) continue;
      final camId = camDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final days = keepDays[camId] ?? 30;
      final cutoff = DateTime(now.year, now.month, now.day).subtract(Duration(days: days));
      await for (final dayDir in camDir.list()) {
        if (dayDir is! Directory) continue;
        final key = dayDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
        await for (final f in dayDir.list()) {
          if (f is! File) continue;
          final t = parseSegmentTime(key, f.uri.pathSegments.last);
          if (t == null || active.contains(f.path)) continue;
          if (t.isBefore(cutoff)) {
            await _del(f);
            deleted++;
          } else {
            all.add((f, t, (await f.stat()).size));
          }
        }
        if (await dayDir.list().isEmpty) await dayDir.delete();
      }
    }
    var total = all.fold<int>(0, (s, e) => s + e.$3);
    all.sort((a, b) => a.$2.compareTo(b.$2));
    for (final (f, _, size) in all) {
      if (total <= maxBytes) break;
      await _del(f);
      total -= size;
      deleted++;
    }
    return deleted;
  }

  Future<int> totalBytes() async {
    var total = 0;
    await for (final e in (await root()).list(recursive: true)) {
      if (e is File) total += (await e.stat()).size;
    }
    return total;
  }

  Future<void> _del(File f) async {
    try {
      await f.delete();
    } catch (_) {}
  }

  /// Copies a segment to the export folder with a `.sha256` file next to it,
  /// so anyone can check the clip was not altered after export.
  Future<File> export(Segment s, String cameraName) async {
    final sep = Platform.pathSeparator;
    Directory dir;
    if (Platform.isAndroid) {
      dir = Directory('${(await root()).parent.path}${sep}Exports');
    } else {
      dir = Directory('${((await getDownloadsDirectory()) ?? (await root()).parent).path}${sep}HomeGuard exports');
    }
    await dir.create(recursive: true);
    final safe = cameraName.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    final target = File('${dir.path}$sep${safe}_${dayKey(s.start)}_${timeKey(s.start)}.mkv');
    await s.file.copy(target.path);
    final digest = sha256.convert(await target.readAsBytes());
    await File('${target.path}.sha256').writeAsString('$digest  ${target.uri.pathSegments.last}\n');
    return target;
  }
}
