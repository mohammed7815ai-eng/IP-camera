import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Where snapshots are saved: Documents\HomeGuard\Snapshots on Windows, the
/// app's external files folder on Android.
Future<Directory> snapshotDir() async {
  Directory base;
  if (Platform.isAndroid) {
    base = (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
  } else {
    base = Directory('${(await getApplicationDocumentsDirectory()).path}${Platform.pathSeparator}HomeGuard');
  }
  final d = Directory('${base.path}${Platform.pathSeparator}Snapshots');
  if (!await d.exists()) await d.create(recursive: true);
  return d;
}

String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');

Future<File> saveSnapshot(String cameraName, Uint8List jpeg) async {
  final d = await snapshotDir();
  final t = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp = '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}';
  final f = File('${d.path}${Platform.pathSeparator}${_safe(cameraName)}_$stamp.jpg');
  return f.writeAsBytes(jpeg, flush: true);
}

Future<List<File>> listSnapshots() async {
  final d = await snapshotDir();
  final files = d.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.jpg')).toList()
    ..sort((a, b) => b.path.compareTo(a.path));
  return files;
}
