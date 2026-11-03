import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/camera.dart';
import 'camera_repository.dart';

/// App-wide state: the camera list and a few preferences.
class AppState extends ChangeNotifier {
  AppState(this.repo);

  final CameraRepository repo;
  List<Camera> cameras = [];
  bool appLock = false;
  int gridColumns = 2;

  /// Master switch for on-device AI detection.
  bool aiEnabled = true;
  bool loaded = false;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    appLock = prefs.getBool('appLock') ?? false;
    gridColumns = prefs.getInt('gridColumns') ?? 2;
    aiEnabled = prefs.getBool('aiEnabled') ?? true;
    cameras = await repo.load();
    loaded = true;
    notifyListeners();
  }

  Future<void> saveCamera(Camera c, {String? password, String? apiKey}) async {
    await repo.save(c, password: password, apiKey: apiKey);
    cameras = await repo.load();
    notifyListeners();
  }

  Future<void> deleteCamera(String id) async {
    await repo.delete(id);
    cameras = await repo.load();
    notifyListeners();
  }

  Future<void> moveCamera(int from, int to) async {
    final c = cameras.removeAt(from);
    cameras.insert(to, c);
    await repo.reorder(cameras);
    notifyListeners();
  }

  Future<void> setAppLock(bool v) async {
    appLock = v;
    (await SharedPreferences.getInstance()).setBool('appLock', v);
    notifyListeners();
  }

  Future<void> setAiEnabled(bool v) async {
    aiEnabled = v;
    (await SharedPreferences.getInstance()).setBool('aiEnabled', v);
    notifyListeners();
  }

  Future<void> setGridColumns(int v) async {
    gridColumns = v;
    (await SharedPreferences.getInstance()).setInt('gridColumns', v);
    notifyListeners();
  }
}
