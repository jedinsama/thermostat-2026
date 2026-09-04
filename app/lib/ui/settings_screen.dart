/// Settings — and the secret door.
///
/// Tapping the version row SEVEN times prompts for the team passphrase.
/// Correct answer permanently unlocks "Research collector" on this device
/// (researcher phones only). Change kCollectorPassphrase before release and
/// never commit the production value to a public repo.
library settings_screen;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/app_state.dart';

const String kCollectorPassphrase = 'PAGASA-F944'; // CHANGE before release
const String kAppVersion = '1.0.0 (capstone)';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _taps = 0;
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);

  void _versionTapped() async {
    final now = DateTime.now();
    // Taps must be within 2 s of each other, or the counter resets.
    _taps = now.difference(_lastTap).inSeconds <= 2 ? _taps + 1 : 1;
    _lastTap = now;
    if (_taps < 7) {
      if (_taps >= 4) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            duration: const Duration(milliseconds: 400),
            content: Text('${7 - _taps} more…')));
      }
      return;
    }
    _taps = 0;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Research access'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Passphrase'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text == kCollectorPassphrase),
              child: const Text('Unlock')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<AppState>().unlockCollector();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Collector mode unlocked')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        ListTile(
          leading: const Icon(Icons.person),
          title: const Text('Health profile'),
          onTap: () => Navigator.pushNamed(context, '/profile'),
        ),
        ListTile(
          leading: const Icon(Icons.tune),
          title: const Text('Personal calibration'),
          subtitle: Text(state.calibration.active
              ? 'active — offset ${state.calibration.offsetC.toStringAsFixed(1)} °C '
                '(${state.calibration.responses} responses)'
              : 'learning — ${state.calibration.responses}/3 survey responses'),
        ),
        if (state.collectorUnlocked)
          ListTile(
            leading: const Icon(Icons.science, color: Colors.deepOrange),
            title: const Text('Research collector'),
            subtitle: const Text('telemetry logging — coded participants only'),
            onTap: () => Navigator.pushNamed(context, '/collector'),
          ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('Version'),
          subtitle: const Text(kAppVersion),
          onTap: _versionTapped, // ← the secret door
        ),
      ]),
    );
  }
}
