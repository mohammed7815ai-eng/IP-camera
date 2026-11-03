import 'dart:io';

import 'package:flutter/material.dart';

import '../ai/detection.dart';
import '../alarm/alarm.dart';
import '../alarm/notifier.dart';
import '../services/app_state.dart';
import 'recordings_page.dart';

/// Arm/disarm, alarm inbox, plate watchlist and allowlist.
class AlarmsPage extends StatelessWidget {
  const AlarmsPage({super.key, required this.state});
  final AppState state;

  String _when(DateTime t) => '${ymd(t)} ${hms(t)}';

  @override
  Widget build(BuildContext context) {
    final center = AlarmCenter.instance;
    return ListenableBuilder(
      listenable: center,
      builder: (context, _) {
        final s = center.settings;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Alarm system'),
            actions: [
              IconButton(tooltip: 'Stop siren', icon: const Icon(Icons.volume_off), onPressed: AlarmNotifier.instance.stopSiren),
              IconButton(tooltip: 'Mark all as seen', icon: const Icon(Icons.done_all), onPressed: center.acknowledgeAll),
            ],
          ),
          body: ListView(padding: const EdgeInsets.all(12), children: [
            SegmentedButton<ArmMode>(
              segments: const [
                ButtonSegment(value: ArmMode.disarmed, label: Text('Disarmed'), icon: Icon(Icons.shield_outlined)),
                ButtonSegment(value: ArmMode.home, label: Text('Home'), icon: Icon(Icons.home_outlined)),
                ButtonSegment(value: ArmMode.away, label: Text('Away'), icon: Icon(Icons.shield)),
              ],
              selected: {s.mode},
              onSelectionChanged: (m) => center.setMode(m.first),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(switch (s.mode) {
                ArmMode.disarmed => 'No alarms, except plates on your watchlist (silent).',
                ArmMode.home => 'Alarms only from cameras set to "Alarm in Home mode", usually outdoor ones.',
                ArmMode.away => 'Alarms from every camera with alarm triggers turned on.',
              }),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Notifications'),
              value: s.notify,
              onChanged: (v) async {
                s.notify = v;
                if (v) await AlarmNotifier.instance.requestPermission();
                await center.saveSettings();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Siren sound on this device'),
              value: s.siren,
              onChanged: (v) {
                s.siren = v;
                center.saveSettings();
              },
            ),
            _PlateList(
              title: 'Watchlist plates',
              help: 'Always alert when one of these is seen.',
              plates: s.watchlist,
              onChanged: center.saveSettings,
            ),
            _PlateList(
              title: 'Allowed plates',
              help: 'Your own cars: never raise a vehicle alarm.',
              plates: s.allowlist,
              onChanged: center.saveSettings,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Test alarm'),
              onPressed: () async {
                await AlarmNotifier.instance.requestPermission();
                await AlarmNotifier.instance.show(
                  AlarmRecord(id: 'test', time: DateTime.now(), cameraId: '', cameraName: 'Test', reason: 'Test alarm', kind: _testKind),
                  loud: s.siren,
                );
              },
            ),
            const Divider(height: 32),
            Text('Alarm history (${center.unacknowledged} new)', style: Theme.of(context).textTheme.titleMedium),
            if (center.inbox.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No alarms yet.')),
            for (final a in center.inbox)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: a.imagePath == null
                    ? const Icon(Icons.warning_amber)
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.file(File(a.imagePath!), width: 64, height: 48, fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Icon(Icons.warning_amber)),
                      ),
                title: Text(a.reason, style: TextStyle(fontWeight: a.acknowledged ? FontWeight.normal : FontWeight.w700)),
                subtitle: Text(_when(a.time)),
                trailing: a.acknowledged ? null : IconButton(icon: const Icon(Icons.check), tooltip: 'Mark as seen', onPressed: () => center.acknowledge(a)),
                onTap: () {
                  center.acknowledge(a);
                  final cam = state.cameras.where((c) => c.id == a.cameraId).firstOrNull;
                  if (cam == null || !cam.canRecord) return;
                  Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => RecordingsPage(state: state, initialCamera: cam, initialTime: a.time.subtract(const Duration(seconds: 10))),
                  ));
                },
              ),
          ]),
        );
      },
    );
  }
}

const _testKind = DetectionKind.motion;

class _PlateList extends StatefulWidget {
  const _PlateList({required this.title, required this.help, required this.plates, required this.onChanged});
  final String title, help;
  final List<String> plates;
  final Future<void> Function() onChanged;
  @override
  State<_PlateList> createState() => _PlateListState();
}

class _PlateListState extends State<_PlateList> {
  final _c = TextEditingController();

  void _add() {
    final p = normPlate(_c.text);
    if (p.isEmpty || widget.plates.contains(p)) return;
    setState(() => widget.plates.add(p));
    _c.clear();
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.title, style: Theme.of(context).textTheme.titleSmall),
        Text(widget.help, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final p in widget.plates)
            InputChip(
              label: Text(p, style: const TextStyle(fontFamily: 'monospace')),
              onDeleted: () {
                setState(() => widget.plates.remove(p));
                widget.onChanged();
              },
            ),
        ]),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _c,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(hintText: 'Add plate, e.g. ABC123', isDense: true),
              onSubmitted: (_) => _add(),
            ),
          ),
          IconButton(icon: const Icon(Icons.add), onPressed: _add),
        ]),
      ]),
    );
  }
}
