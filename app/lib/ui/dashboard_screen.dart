/// Consumer dashboard: full live telemetry, Risk Level Card, alarm banner,
/// survey hook, and a manual SOS.
///
/// The Risk Level Card shows the EFFECTIVE band — the worse of the rule
/// engine's present assessment and the on-device forest's 20-minute forecast
/// — and labels it "expected within ~20 minutes" whenever the forecast is
/// what raised it, so a warning is never mistaken for a description of now.
///
/// Tiles shown (everything the telemetry + rule engine can offer):
///   ambient temp (compensated) · humidity · heat index · skin temp ·
///   heart rate · SpO2 · strain (PSI /10) · pressure · wearable battery ·
///   last-update age. NaN values render as an em-dash, never as fake zeros.
library dashboard_screen;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/app_state.dart';
import '../core/ble_client.dart';
import '../core/risk_rules.dart';
import 'survey_dialog.dart';

const _bandColors = [
  Color(0xFF2E7D32), // Safe
  Color(0xFFF9A825), // Caution
  Color(0xFFEF6C00), // Extreme Caution
  Color(0xFFD84315), // Danger
  Color(0xFFB71C1C), // Extreme Danger
];

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _connecting = false;
  String _status = 'not connected';

  @override
  void initState() {
    super.initState();
    // Ask for SMS + location NOW, not during an emergency.
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => context.read<AppState>().ensureSosPermissions());
  }

  Future<void> _connect() async {
    final ble = context.read<BleClient>();
    final state = context.read<AppState>();
    setState(() => _connecting = true);
    ble.status.listen((s) => mounted ? setState(() => _status = s) : null);
    try {
      await ble.connect();
      ble.frames.listen(state.onFrame);
    } catch (_) {/* status stream already reported it */} finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  String _age(DateTime? t) {
    if (t == null) return '—';
    final s = DateTime.now().difference(t).inSeconds;
    return s < 90 ? '${s}s ago' : '${(s / 60).round()}m ago';
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final a = state.assessment;
    final f = state.latest;

    if (state.surveyPending) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => maybeShowSurvey(context));
    }

    String num(double? x, String unit, [int dp = 1]) =>
        (x == null || x.isNaN) ? '—' : '${x.toStringAsFixed(dp)}$unit';

    return Scaffold(
      appBar: AppBar(
        title: const Text('THERMOSTAT'),
        actions: [
          IconButton(
              icon: const Icon(Icons.person),
              onPressed: () => Navigator.pushNamed(context, '/profile')),
          IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () => Navigator.pushNamed(context, '/settings')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (state.alarmActive) _AlarmBanner(onStop: state.stopAlarm),
          if (state.sosStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(state.sosStatus,
                  style: const TextStyle(
                      color: Color(0xFFB71C1C), fontWeight: FontWeight.w600)),
            ),
          _RiskCard(
            band: state.effectiveBand,
            isForecast: state.alertIsForecast,
            calibrationRaised:
                a != null && a.finalBand > a.ruleBand,
          ),
          _ForecastLine(state: state),
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 12, children: [
            _Metric('Ambient',
                num(f?.compensatedAmbientC(kThermalCoupling), ' °C')),
            _Metric('Humidity', num(f?.humidityPct, ' %', 0)),
            _Metric('Heat index', num(a?.heatIndexC, ' °C')),
            _Metric('Skin temp', num(f?.skinC, ' °C')),
            _Metric('Heart rate', num(f?.hrBpm, ' bpm', 0)),
            _Metric('SpO₂', num(f?.spo2Pct, ' %', 0)),
            _Metric('Strain (PSI)',
                a == null || a.psi.isNaN ? '—' : '${a.psi.toStringAsFixed(1)} /10'),
            _Metric('Pressure', num(f?.pressureHpa, ' hPa', 0)),
            _Metric('Device batt',
                f == null ? '—' : '${f.batteryPct} %'),
            _Metric('Updated', _age(f?.receivedAt)),
          ]),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _connecting ? null : _connect,
            icon: const Icon(Icons.bluetooth),
            label: Text(_connecting ? 'connecting…' : 'Pair wearable'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFB71C1C)),
            onPressed: () => state.dispatchSos(reason: 'manual SOS button'),
            icon: const Icon(Icons.sos),
            label: const Text('Send SOS now'),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_status,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
          ),
          if (state.effectiveBand >= 1) _AdviceCard(band: state.effectiveBand),
        ],
      ),
    );
  }
}

class _AlarmBanner extends StatelessWidget {
  final VoidCallback onStop;
  const _AlarmBanner({required this.onStop});
  @override
  Widget build(BuildContext context) => Card(
        color: const Color(0xFFB71C1C),
        child: ListTile(
          leading: const Icon(Icons.notifications_active, color: Colors.white),
          title: const Text('SOS ACTIVE — emergency contact notified',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          trailing: FilledButton.tonal(
              onPressed: onStop, child: const Text("I'm OK — stop alarm")),
        ),
      );
}

class _RiskCard extends StatelessWidget {
  final int band;
  final bool isForecast;
  final bool calibrationRaised;
  const _RiskCard(
      {required this.band,
      required this.isForecast,
      required this.calibrationRaised});

  @override
  Widget build(BuildContext context) {
    final color = band >= 0 ? _bandColors[band] : Colors.blueGrey;
    return Card(
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          Text('PERSONAL HEAT RISK',
              style: TextStyle(color: Colors.white.withOpacity(.9), letterSpacing: 2)),
          const SizedBox(height: 8),
          Text(
            band >= 0 ? riskNames[band].toUpperCase() : 'AWAITING DATA',
            style: const TextStyle(
                color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          if (isForecast)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('expected within ~20 minutes',
                  style: TextStyle(
                      color: Colors.white.withOpacity(.95),
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ),
          if (calibrationRaised)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('raised by your personal calibration',
                  style: TextStyle(color: Colors.white.withOpacity(.85), fontSize: 12)),
            ),
        ]),
      ),
    );
  }
}

/// One line explaining what the ML layer is doing right now — warming up,
/// forecasting, or absent. Users should never wonder whether it is running.
class _ForecastLine extends StatelessWidget {
  final AppState state;
  const _ForecastLine({required this.state});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    if (state.forest == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text('Forecast model not installed — showing present '
            'conditions from the rule engine only.', style: style),
      );
    }
    if (!state.featureWindow.ready) {
      final m = state.featureWindow.warmupRemaining.inMinutes;
      final n = state.featureWindow.sampleCount;
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
            'Learning your baseline — forecast available in ~$m min '
            '($n readings so far).',
            style: style),
      );
    }
    final fc = state.forecast;
    if (fc == null) return const SizedBox.shrink();
    final pct = (fc.dangerProbability * 100).round();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        'Forecast (${fc.horizonMin} min ahead): ${riskNames[fc.band]} · '
        'chance of Danger or worse $pct%',
        style: style,
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label, value;
  const _Metric(this.label, this.value);
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 104,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              Text(value,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ),
      );
}

class _AdviceCard extends StatelessWidget {
  final int band;
  const _AdviceCard({required this.band});
  static const _advice = [
    '',
    'Stay hydrated. Prefer shade during midday hours.',
    'Drink water every 20 minutes. Limit strenuous activity. Seek ventilation.',
    'Move to shade NOW. Drink water. Stop strenuous activity. Loosen clothing.',
    'EMERGENCY RISK. Get to a cool place immediately. Apply water to skin. If dizzy or confused, seek medical help.',
  ];
  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(top: 16),
        child: ListTile(
          leading: const Icon(Icons.tips_and_updates),
          title: Text(_advice[band]),
        ),
      );
}
