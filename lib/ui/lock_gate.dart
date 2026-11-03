import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../services/app_state.dart';

/// Requires Windows Hello / Android biometrics or device PIN when app lock is
/// on: at start, and when returning after more than a minute away.
class LockGate extends StatefulWidget {
  const LockGate({super.key, required this.state, required this.child});
  final AppState state;
  final Widget child;

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  final _auth = LocalAuthentication();
  bool _unlocked = false;
  bool _busy = false;
  DateTime? _pausedAt;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.addListener(_onState);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.state.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    setState(() {});
    if (widget.state.loaded && widget.state.appLock && !_unlocked && !_busy) _unlock();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) {
      _pausedAt ??= DateTime.now();
    } else if (s == AppLifecycleState.resumed) {
      final away = _pausedAt == null ? Duration.zero : DateTime.now().difference(_pausedAt!);
      _pausedAt = null;
      if (widget.state.appLock && away > const Duration(minutes: 1)) {
        setState(() => _unlocked = false);
        _unlock();
      }
    }
  }

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await _auth.authenticate(localizedReason: 'Unlock HomeGuard to view your cameras');
      if (mounted) setState(() => _unlocked = ok);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not verify: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    if (!s.loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!s.appLock || _unlocked) return widget.child;
    return Scaffold(
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.lock_outline, size: 64),
          const SizedBox(height: 16),
          const Text('HomeGuard is locked', style: TextStyle(fontSize: 20)),
          if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _unlock,
            icon: const Icon(Icons.fingerprint),
            label: const Text('Unlock'),
          ),
        ]),
      ),
    );
  }
}
