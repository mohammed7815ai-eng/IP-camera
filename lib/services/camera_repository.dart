import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/camera.dart';
import 'secret_store.dart';

/// Persists the camera list (non-secret fields) in app preferences and the
/// secrets in the OS key store.
class CameraRepository {
  CameraRepository(this.secrets);

  static const _listKey = 'cameras.v1';
  final SecretStore secrets;

  Future<List<Camera>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_listKey);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) => Camera.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> _saveAll(List<Camera> cams) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_listKey, jsonEncode(cams.map((c) => c.toJson()).toList()));
  }

  /// Adds or replaces [camera]. A null secret leaves the stored one unchanged;
  /// an empty string removes it.
  Future<void> save(Camera camera, {String? password, String? apiKey}) async {
    final cams = await load();
    final i = cams.indexWhere((c) => c.id == camera.id);
    if (i >= 0) {
      cams[i] = camera;
    } else {
      cams.add(camera);
    }
    await _saveAll(cams);
    await _setSecret(passwordKey(camera.id), password);
    await _setSecret(apiKeyKey(camera.id), apiKey);
  }

  Future<void> _setSecret(String key, String? value) async {
    if (value == null) return;
    if (value.isEmpty) {
      await secrets.delete(key);
    } else {
      await secrets.write(key, value);
    }
  }

  Future<void> delete(String id) async {
    final cams = await load();
    cams.removeWhere((c) => c.id == id);
    await _saveAll(cams);
    await secrets.delete(passwordKey(id));
    await secrets.delete(apiKeyKey(id));
  }

  Future<void> reorder(List<Camera> cams) => _saveAll(cams);

  Future<String?> password(String id) => secrets.read(passwordKey(id));
  Future<String?> apiKey(String id) => secrets.read(apiKeyKey(id));
}
