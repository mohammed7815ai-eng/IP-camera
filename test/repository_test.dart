import 'package:flutter_test/flutter_test.dart';
import 'package:home_guard/models/camera.dart';
import 'package:home_guard/services/camera_repository.dart';
import 'package:home_guard/services/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('secrets go to the secret store, never to preferences', () async {
    final secrets = MemorySecretStore();
    final repo = CameraRepository(secrets);
    final cam = Camera(id: 'c1', name: 'Door', kind: CameraKind.httpApi, host: 'cam', username: 'admin');
    await repo.save(cam, password: 'hunter2', apiKey: 'KEY-123');

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getKeys().map((k) => prefs.get(k).toString()).join();
    expect(raw, isNot(contains('hunter2')));
    expect(raw, isNot(contains('KEY-123')));
    expect(await repo.password('c1'), 'hunter2');
    expect(await repo.apiKey('c1'), 'KEY-123');

    final loaded = await repo.load();
    expect(loaded.single.name, 'Door');
    expect(loaded.single.kind, CameraKind.httpApi);
  });

  test('null keeps secrets, empty removes, delete wipes', () async {
    final secrets = MemorySecretStore();
    final repo = CameraRepository(secrets);
    final cam = Camera(id: 'c1', name: 'Door', kind: CameraKind.rtsp);
    await repo.save(cam, password: 'a');
    await repo.save(cam..name = 'Gate');
    expect(await repo.password('c1'), 'a');
    await repo.save(cam, password: '');
    expect(await repo.password('c1'), isNull);
    await repo.save(cam, password: 'b', apiKey: 'k');
    await repo.delete('c1');
    expect(secrets.data, isEmpty);
    expect(await repo.load(), isEmpty);
  });
}
