import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores camera passwords and API keys using the OS key store:
/// Android Keystore on Android, DPAPI on Windows.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class OsSecretStore implements SecretStore {
  OsSecretStore([FlutterSecureStorage? storage])
      : _s = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(),
            );

  final FlutterSecureStorage _s;

  @override
  Future<String?> read(String key) => _s.read(key: key);

  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

/// In-memory store for tests.
class MemorySecretStore implements SecretStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

String passwordKey(String cameraId) => 'cam.$cameraId.password';
String apiKeyKey(String cameraId) => 'cam.$cameraId.apikey';
