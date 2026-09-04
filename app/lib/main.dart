/// THERMOSTAT — entry point.
///
/// One APK, two faces:
///  · CONSUMER MODE (default): dashboard, risk card, surveys, SOS.
///  · COLLECTOR MODE (hidden): research logging UI — no risk output, coded
///    participant IDs, CSV export. Unlocked from Settings by tapping the
///    version row 7 times and entering the team passphrase (see
///    settings_screen.dart). The unlock persists on the researcher phones
///    only; participants never see it.
library main;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'core/app_state.dart';
import 'core/ble_client.dart';
import 'core/personal_calibration.dart';
import 'ui/collector_screen.dart';
import 'ui/dashboard_screen.dart';
import 'ui/profile_screen.dart';
import 'ui/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  assert(calibrationSelfTest(), 'calibration safety-floor self-test failed');
  final state = AppState();
  await state.load();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: state),
        Provider(create: (_) => BleClient()),
      ],
      child: const ThermostatApp(),
    ),
  );
}

class ThermostatApp extends StatelessWidget {
  const ThermostatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'THERMOSTAT',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFE65100)),
        useMaterial3: true,
      ),
      routes: {
        '/': (_) => const _Gate(),
        '/dashboard': (_) => const DashboardScreen(),
        '/profile': (_) => const ProfileScreen(),
        '/settings': (_) => const SettingsScreen(),
        '/collector': (_) => const CollectorScreen(),
      },
    );
  }
}

/// First-run gate: protocol self-test, then profile onboarding, then home.
class _Gate extends StatelessWidget {
  const _Gate();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.protocolOk) {
      // Wire-format mismatch: refuse to run rather than log wrong numbers.
      return const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text(
              'PROTOCOL SELF-TEST FAILED\n\n'
              'The telemetry decoder does not match the canonical test vector. '
              'Do not collect data with this build. Rebuild from a clean '
              'checkout and verify core/protocol.dart against firmware.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Colors.red),
            ),
          ),
        ),
      );
    }
    if (state.profile == null) return const ProfileScreen(firstRun: true);
    return const DashboardScreen();
  }
}
