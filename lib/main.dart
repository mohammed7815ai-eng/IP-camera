import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'ai/event_store.dart';
import 'alarm/alarm.dart';
import 'alarm/notifier.dart';
import 'recording/recording_service.dart';
import 'services/app_state.dart';
import 'services/background.dart';
import 'services/camera_repository.dart';
import 'services/secret_store.dart';
import 'ui/home_page.dart';
import 'ui/lock_gate.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final state = AppState(CameraRepository(OsSecretStore()));
  BackgroundMode.init();
  runApp(HomeGuardApp(state: state));
  _start(state);
}

Future<void> _start(AppState state) async {
  await state.init();
  await EventStore.instance.load();
  await AlarmCenter.instance.load();
  AlarmCenter.instance.onAlarm = (r, loud) => AlarmNotifier.instance.show(r, loud: loud);
  await AlarmNotifier.instance.init();
  await RecordingService.instance.attach(state);
  if (await BackgroundMode.enabled()) await BackgroundMode.start();
}

class HomeGuardApp extends StatelessWidget {
  const HomeGuardApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF1F6FEB);
    return MaterialApp(
      title: 'HomeGuard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: seed, useMaterial3: true, brightness: Brightness.dark),
      themeMode: ThemeMode.dark,
      home: LockGate(state: state, child: HomePage(state: state)),
    );
  }
}
